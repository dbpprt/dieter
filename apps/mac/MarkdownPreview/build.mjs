import {build} from 'esbuild';
import {readFile, readdir, mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const directory = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(directory, '../Sources/DieterMac/Resources/MarkdownPreview');
const check = process.argv.includes('--check');
const result = await build({
  absWorkingDir: directory,
  entryPoints: ['src/app.js'],
  outdir: output,
  bundle: true,
  splitting: false,
  format: 'iife',
  platform: 'browser',
  target: ['safari17.4'],
  minify: true,
  legalComments: 'inline',
  write: false,
  logLevel: 'warning',
});

const files = new Map(result.outputFiles.map(file => [path.basename(file.path), file.contents]));
files.set('index.html', await readFile(path.join(directory, 'src/index.html')));

// Include every installed production dependency, including the dependencies
// already embedded in Mermaid's published chunks. Keep their complete license
// and notice files rather than only SPDX names or a generated attribution list.
const lock = JSON.parse(await readFile(path.join(directory, 'package-lock.json'), 'utf8'));
const notices = ['Dieter Markdown preview — third-party licenses',
  'Generated from package-lock.json by MarkdownPreview/build.mjs.\n'];
for (const [relative, entry] of Object.entries(lock.packages).sort(([a], [b]) => a.localeCompare(b, 'en'))) {
  if (!relative || entry.dev) continue;
  const packageDirectory = path.join(directory, relative);
  const metadata = JSON.parse(await readFile(path.join(packageDirectory, 'package.json'), 'utf8'));
  notices.push(`\n${'='.repeat(78)}\n${metadata.name}@${metadata.version}\nLicense: ${metadata.license ?? 'See license below'}\n`);
  const licenseFiles = (await readdir(packageDirectory)).filter(name => /^(licen[cs]e|copying|notice)([.-].*)?$/i.test(name)).sort();
  if (!licenseFiles.length) throw new Error(`No license file for ${metadata.name}; supply its upstream license before bundling.`);
  for (const filename of licenseFiles) {
    notices.push(`--- ${filename} ---\n${await readFile(path.join(packageDirectory, filename), 'utf8')}`);
  }
}
files.set('LICENSES.txt', notices.join('\n'));

if (!check) await mkdir(output, {recursive: true});
for (const [filename, contents] of files) {
  const destination = path.join(output, filename);
  if (check) {
    const existing = await readFile(destination);
    if (!existing.equals(Buffer.from(contents))) throw new Error(`${filename} is stale. Run npm run build in apps/mac/MarkdownPreview.`);
  } else {
    await writeFile(destination, contents);
  }
}
console.log(`${check ? 'Verified' : 'Built'} ${files.size} offline Markdown preview resources.`);
