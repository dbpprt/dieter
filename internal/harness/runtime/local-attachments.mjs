import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export async function promptWithLocalAttachments(request) {
  if (!request.attachments?.length) return request.prompt;
  const attachmentRoot = join(request.runtimeRoot, 'attachments', request.sessionId);
  await mkdir(attachmentRoot, { recursive: true });
  const paths = [];
  for (const [index, attachment] of request.attachments.entries()) {
    const match = /^data:([^;,]+);base64,([A-Za-z0-9+/=]+)$/.exec(attachment.url || '');
    if (!match) throw new Error('Dieter received an invalid local attachment');
    const safeName = String(attachment.filename || `attachment-${index + 1}`)
      .replace(/[^A-Za-z0-9._-]+/g, '-')
      .replace(/^\.+/, '') || `attachment-${index + 1}`;
    const path = join(attachmentRoot, `${request.responseMessageId}-${index + 1}-${safeName}`);
    await writeFile(path, Buffer.from(match[2], 'base64'), { mode: 0o600 });
    paths.push(path);
  }
  const text = String(request.prompt || '').trim();
  const guidance = [
    'The user attached files to this message. Inspect them with your local image/file tools when relevant:',
    ...paths.map(path => `- ${path}`),
  ].join('\n');
  return text ? `${text}\n\n${guidance}` : guidance;
}
