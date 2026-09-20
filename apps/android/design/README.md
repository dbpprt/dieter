# Android design references

The PNG files in `reference/` are the transparent mockups embedded in the
current `Native Android PWA redesign1.pdf`. They are extracted without
rendering, cropping, or recompression. The first two pages define the new
Connections and Display settings tabs. The next three define the Dieter server
connection sheet, Android notification shade, and standalone-chat subagents
tab. The remaining pages cover Spaces, board switching, creation flows,
unfolded layouts, and the core phone destinations.

Regenerate them with the bundled Codex Python runtime or any Python environment
that provides `pypdf`:

```sh
python3 apps/android/design/extract_reference_images.py \
  "$HOME/Downloads/Native Android PWA redesign1.pdf"
```

The extractor assigns stable semantic filenames explicitly so a refreshed PDF
replaces the expected references and fails loudly if its page structure
changes.

Android uses Chats and Boards as primary destinations. Tools opens a compact
panel for Terminal, Files, Schedules, Screens, and Settings. The panel uses
opaque surfaces from the selected app palette.
