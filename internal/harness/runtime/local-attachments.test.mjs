import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { promptWithLocalAttachments } from './local-attachments.mjs';

test('materializes attachments inside the session runtime and references them in the prompt', async () => {
  const runtimeRoot = await mkdtemp(join(tmpdir(), 'dieter-attachment-'));
  try {
    const prompt = await promptWithLocalAttachments({
      prompt: 'Inspect both files',
      runtimeRoot,
      sessionId: 'card-one',
      responseMessageId: 'response-one',
      attachments: [
        { filename: '../../wire.png', url: 'data:image/png;base64,cG5nIGZpeHR1cmU=' },
        { filename: 'notes.txt', url: 'data:text/plain;base64,aGVsbG8=' },
      ],
    });
    const attachmentRoot = join(runtimeRoot, 'attachments', 'card-one');
    const imagePath = join(attachmentRoot, 'response-one-1--..-wire.png');
    const notesPath = join(attachmentRoot, 'response-one-2-notes.txt');
    assert.match(prompt, /^Inspect both files\n\nThe user attached files/);
    assert.ok(prompt.includes(imagePath));
    assert.equal(await readFile(imagePath, 'utf8'), 'png fixture');
    assert.equal(await readFile(notesPath, 'utf8'), 'hello');
    assert.equal((await stat(imagePath)).mode & 0o777, 0o600);
  } finally {
    await rm(runtimeRoot, { recursive: true, force: true });
  }
});

test('rejects an attachment that is not a base64 data URL', async () => {
  const runtimeRoot = await mkdtemp(join(tmpdir(), 'dieter-attachment-'));
  try {
    await assert.rejects(
      promptWithLocalAttachments({
        runtimeRoot,
        sessionId: 'card-one',
        responseMessageId: 'response-one',
        attachments: [{ filename: 'remote.txt', url: 'https://example.test/remote.txt' }],
      }),
      /invalid local attachment/,
    );
  } finally {
    await rm(runtimeRoot, { recursive: true, force: true });
  }
});
