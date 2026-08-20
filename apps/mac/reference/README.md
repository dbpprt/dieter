# macOS design references

These 22 transparent PNGs are extracted losslessly from the 13-page
`Board Mac SwiftUI app.pdf`. They cover the desktop Board, Chats, standalone
conversation, subagent, menu-bar, notification, settings, creation, archive,
schedule, and file-management flows.

Regenerate them with a Python environment that provides `pypdf`:

```sh
python3 -m pip install -r apps/mac/design/requirements.txt
python3 apps/mac/design/extract_reference_images.py \
  "$HOME/Downloads/Board Mac SwiftUI app.pdf"
```

The extractor assigns explicit semantic filenames and fails if the page or
embedded-image structure changes, so a refreshed PDF cannot silently scramble
the references.
