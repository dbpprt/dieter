import { realpath, stat } from 'node:fs/promises';
import { isAbsolute, relative, resolve, sep } from 'node:path';
import { tool } from 'ai';
import { z } from 'zod';

const boundedText = max => z.string().max(max).refine(value => !/[\p{Cc}]/u.test(value), 'Control characters are not allowed');
const boundedBytes = max => boundedText(max).refine(value => Buffer.byteLength(value, 'utf8') <= max, `Maximum ${max} UTF-8 bytes`);

function contained(path) {
  return path !== '' && path !== '..' && !path.startsWith(`..${sep}`) && !isAbsolute(path)
    && !protectedPath(path);
}

function protectedPath(path) { return path.split(sep).some(part => part.toLowerCase() === '.git'); }

// The owning conversation/workspace come only from the daemon's worker request.
// They are not part of the model-visible tool arguments.
export function createContentPresentationTool(request, emit) {
  return tool({
    description: 'Request that Dieter present a file or HTTP(S) URL in the current conversation’s right workspace pane. Use this to show the user a deliverable. Files use their native renderer; URLs use the browser tab. This requests presentation and does not prove the user has viewed it. Supply exactly one path or url; paths must be within this conversation’s working tree.',
    inputSchema: z.object({
      path: boundedBytes(4096).optional(),
      url: boundedBytes(8192).optional(),
      line: z.number().int().min(1).max(10_000_000).optional(),
      title: boundedText(256).optional(),
    }).strict().refine(input => Boolean(input.path) !== Boolean(input.url), 'Supply exactly one path or url'),
    execute: async input => {
      const presentation = { ...input };
      if (input.url) {
        const url = new URL(input.url);
        if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || input.line != null) {
          throw new Error('Use an absolute HTTP(S) URL without credentials; line applies only to files');
        }
        presentation.url = url.href;
        // Match the daemon's wire limit after URL escaping, before requesting
        // presentation, so a rejected target remains a recoverable tool error.
        if (Buffer.byteLength(presentation.url, 'utf8') > 8192) throw new Error('Normalized URL exceeds the 8192-byte limit');
      } else {
        if (input.path.includes('\\')) throw new Error('File paths must use forward slashes');
        const root = await realpath(request.projectPath);
        const target = resolve(root, input.path);
        let path = relative(root, target);
        const canonicalPath = relative(root, await realpath(target));
        if (protectedPath(path) || (!isAbsolute(input.path) && !contained(path)) || !contained(canonicalPath)) {
          throw new Error('File must belong to the current conversation’s workspace');
        }
        if (!contained(path)) path = canonicalPath;
        const info = await stat(target);
        if (!info.isFile() || info.size > 5 * 1024 * 1024) throw new Error('Select a regular file no larger than 5 MiB');
        presentation.path = path.split(sep).join('/');
      }
      emit({ type: 'present-content', presentation });
      return { requested: true, conversationId: request.sessionId, ...presentation };
    },
  });
}

export const contentPresentationInstructions = 'Use present_content when you want to show the user a file or URL you have created, changed, or discussed. The tool targets only this conversation. A normal Markdown link remains a link and does not open a pane automatically. A successful result means presentation was requested, not that the user has viewed it.';
