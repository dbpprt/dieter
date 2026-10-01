import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createLocalSandboxProvider } from './local-sandbox.mjs';
import { createOMPSessionWithBootstrapRetry } from './omp-resilience.mjs';

// Exercise real npm against a disposable registry/cache. No public registry,
// provider credentials, or operator bootstrap installation is involved.
for (const scoped of [false, true]) {
  test(`bootstrap refreshes cached metadata${scoped ? ' with --dir' : ''} after a dependency is published`, { timeout: 30_000 }, async () => {
    const base = await mkdtemp(join(tmpdir(), 'dieter-bootstrap-cache-'));
    let provider;
    let server;
    try {
      const projectPath = join(base, 'project');
      const packagePath = join(base, 'package');
      await Promise.all([mkdir(projectPath), mkdir(packagePath)]);
      const name = '@oh-my-pi/omp-stats';
      const version = '18.4.4';
      const manifest = {
        name, version,
        // Bootstrap must keep lifecycle scripts disabled.
        scripts: { install: 'node -e "process.exit(99)"' },
      };
      await writeFile(join(packagePath, 'package.json'), JSON.stringify(manifest));
      await writeFile(join(base, 'user.npmrc'), '');
      await writeFile(join(base, 'global.npmrc'), '');
      let published = false;
      let metadataRequests = 0;
      let registry;
      let tarball;
      server = createServer((request, response) => {
        if (decodeURIComponent(request.url) === `/${name}`) {
          metadataRequests += 1;
          const current = published ? version : '18.2.11';
          response.writeHead(200, {
            'content-type': 'application/json', 'cache-control': 'public, max-age=86400',
            // npm stores full metadata (view/resolution) and abbreviated
            // metadata (package extraction) separately at the same URL.
            vary: 'accept',
          });
          response.end(JSON.stringify({
            name,
            'dist-tags': { latest: current },
            versions: { [current]: {
              ...manifest, version: current,
              dist: { tarball: `${registry}package.tgz`, integrity: `sha512-${createHash('sha512').update(tarball).digest('base64')}` },
            } },
          }));
        } else if (request.url === '/package.tgz') {
          response.writeHead(200, { 'content-type': 'application/octet-stream' });
          response.end(tarball);
        } else {
          response.writeHead(404).end('{}');
        }
      });
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      registry = `http://127.0.0.1:${server.address().port}/`;
      provider = await createLocalSandboxProvider({ root: join(base, 'runtime'), projectPath });
      const session = await provider.createSession();
      const env = {
        // `npm test` exports its own install configuration (including npm 12's
        // allow-scripts policy). Keep it out of this disposable installation.
        ...Object.fromEntries(Object.keys(process.env).filter(key => /^npm_/i.test(key)).map(key => [key, undefined])),
        npm_config_cache: join(base, 'cache'),
        npm_config_registry: registry,
        npm_config_userconfig: join(base, 'user.npmrc'),
        npm_config_globalconfig: join(base, 'global.npmrc'),
        npm_config_fetch_retries: '0',
        npm_config_fetch_timeout: '5000',
        npm_config_update_notifier: 'false',
        // A host setting must not defeat bootstrap's explicit revalidation.
        npm_config_prefer_offline: 'true',
        npm_config_proxy: '', npm_config_https_proxy: '', npm_config_noproxy: '127.0.0.1',
      };
      const run = (command, workingDirectory = projectPath) => session.run({ command, workingDirectory, env });
      const packed = await run('npm pack --ignore-scripts', packagePath);
      assert.equal(packed.exitCode, 0, packed.stderr);
      tarball = await readFile(join(packagePath, packed.stdout.trim()));
      const installPath = scoped ? join(projectPath, 'implementation') : projectPath;
      await mkdir(installPath, { recursive: true });
      await writeFile(join(installPath, 'package.json'), JSON.stringify({ private: true, dependencies: { [name]: version } }));

      // Seed npm with a package list lacking the pinned dependency version.
      const before = await run(`npm install${scoped ? ' --prefix implementation' : ''} --ignore-scripts --no-audit --no-fund --prefer-offline`);
      assert.notEqual(before.exitCode, 0);
      assert.match(before.stderr, /ETARGET/);
      const oldPackageList = await run(`npm pack ${name}@${version} --ignore-scripts --prefer-offline`);
      assert.notEqual(oldPackageList.exitCode, 0);
      assert.match(oldPackageList.stderr, /ETARGET/);
      assert(metadataRequests > 0);

      let attempts = 0;
      let requestsBeforePublish;
      const result = await createOMPSessionWithBootstrapRetry({
        packageVersion: version,
        sessionOptions: {},
        retryDelays: [1],
        waitForRetry: async () => {
          published = true;
          // A successful `npm view` is insufficient recovery: extraction can
          // still read an older abbreviated list. Reproduce that split cache.
          const viewed = await run(`npm view ${name}@${version} version --prefer-online --prefer-offline=false`);
          assert.equal(viewed.exitCode, 0, viewed.stderr);
          assert.match(viewed.stdout, new RegExp(version.replaceAll('.', '\\.')));
          requestsBeforePublish = metadataRequests;
          const staleExtraction = await run(`npm pack ${name}@${version} --ignore-scripts --prefer-offline`);
          assert.notEqual(staleExtraction.exitCode, 0);
          assert.match(staleExtraction.stderr, /ETARGET/);
          assert.equal(metadataRequests, requestsBeforePublish, 'offline extraction must demonstrate the stale abbreviated cache');
        },
        createSession: async () => {
          attempts += 1;
          const command = scoped ? 'pnpm --dir implementation install --prod --store-dir ../.pnpm-store' : 'pnpm install --prod';
          const installed = await run(command);
          if (installed.exitCode !== 0) {
            throw new Error(`Bootstrap command failed for harness 'omp' (exit ${installed.exitCode}): ${command}\n${installed.stderr}`);
          }
          return JSON.parse(await readFile(join(installPath, 'node_modules', name, 'package.json'), 'utf8'));
        },
      });
      assert.equal(attempts, 2);
      assert(metadataRequests > requestsBeforePublish, 'retry must revalidate metadata even inside its cache lifetime');
      assert.equal(result.version, version);
    } finally {
      await provider?.stopAll();
      if (server) {
        server.closeAllConnections();
        await new Promise(resolve => server.close(resolve));
      }
      await rm(base, { recursive: true, force: true });
    }
  });
}
