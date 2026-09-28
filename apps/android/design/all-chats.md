# Android All chats

The list should answer three questions at a glance: what did I pin, where did I
file a chat, and which project does it belong to?

## Hierarchy

- **Pinned** is a shortcut section with outlined cards, pin icon, and reorder
  handles. A filed pin also names its folder. Pinning does not change membership.
- **Folders** use warm folder icons, tinted headers, explicit “Folder” metadata,
  and a continuous rail joining their children. Folder names remain user-defined.
- **Projects** use initial tiles, explicit “Project” metadata, chat counts, and
  a dedicated new-chat button. Their children omit the redundant project name.
- Section headings, spacing, and icons distinguish the groups even without color.
  Counts describe the visible entries in each group; the screen total counts each
  conversation once, including pins that also appear in folders.

## Rows and interaction

Titles lead. A quieter metadata line keeps project context where needed, the host,
and recency. Only active chats show a Running badge; idle state remains available
to accessibility. Each row has a visible actions menu as well as long-press.
Existing pin order, folder membership, collapse, rename, archive, and new-chat
operations retain their shared persistence.

Search matches chat titles, project names, and folder names. Matching groups open
temporarily and show all results, leaving saved disclosure state intact. No
matches gets an explicit empty state. Empty folders remain manageable.

## Verification

Exercise actual Compose screens in the isolated E2E app on Pixel_9_API_37_1.
Inspect phone screenshots in dark and light appearances, large text, collapsed
groups, organization search, and no-results state. Verify pin/folder coexistence,
folder persistence, project disclosure, and the drawing-only running animation.
Use existing palette tokens and lazy rows so long lists remain adaptive.
