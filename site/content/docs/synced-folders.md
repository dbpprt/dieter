---
title: "Synced folders"
linkTitle: "Synced folders"
description: "Keep a folder the same on your machines and phones, so files you drop on your phone reach your agents and their reports reach you."
group: "Workflows"
weight: 27
slug: "synced-folders"
---

A synced folder is a named folder that Dieter keeps the same on several of your
devices: the machines that run a daemon, and your Android phones and iPhones.
Drop a PDF into the folder on your phone, and it appears on your Mac mini,
where an agent can read it. An agent writes a report into the folder, and it
appears on your phone and in Finder on your Mac. Edit a file on one device, and
every other device gets the new version.

The most common setup is a pair of folders:

- **Inbox.** _Upload only_ on your phone, with _Remove from this device_ after
  upload. Files you add, or share to Dieter with **Save to folder…**, go to
  your machines and then leave the phone. Link the folder to a project so its
  agents know where to look.
- **Reports.** _Download only_ on your phone. Agents write their results into
  it, and they appear on your phone without you asking.

## How it works

```text
 Mac mini (daemon) ◀══ syncs directly ══▶ Linux box (daemon)
   ▲  Mac app: "This Mac", Reveal in Finder     ▲
   │ home                                       │ home
 Pixel 9                                      iPhone
```

- **Daemons are the hubs.** Every folder has at least one machine that runs a
  daemon. Those machines sync with each other directly, with no leader.
- **Phones sync with one machine, their home machine.** By default Dieter
  picks it for you: a machine it can reach directly, otherwise the one it
  reached most recently. If that machine is offline, the phone uses another
  member. Phones never sync with each other and are never the only copy.
- **A Mac takes part through its daemon.** If your Mac runs a daemon, the
  folder lives on that daemon. The Mac app shows it as **This Mac** and offers
  **Reveal in Finder**. The Mac app has no sync engine of its own. On a Mac
  without a daemon you can create, manage and browse folders, but the Mac keeps
  no copy; install the daemon to keep one.
- **Definitions are shared, paths are not.** A folder's name, rules, trash
  setting, deletion guard and linked project reach all your machines, like
  project metadata. Where the folder lives on a machine stays on that machine.
- **Content stays between your devices.** Files travel only between the
  folder's members, over the same end-to-end encrypted connections as
  everything else. The gateway relays ciphertext and stores nothing. It can see
  when your devices sync and roughly how much.

A machine notices changes right away on Linux. On macOS it notices new,
removed and renamed files right away, and edits inside an existing file within
about a minute. Every machine also rescans the whole folder, every hour by
default. A phone
scans the folder at the start of every sync and every 30 seconds while Dieter
is open.

## Create a folder and add machines

On **Android, iPhone and iPad**, open **More › Folders** and tap **Add folder**:

1. Create a folder, or join one that already exists.
2. Pick the machine that keeps it and the folder's location on that machine.
3. Pick where it lives on this device (see [On your phone](#on-your-phone)).
4. Pick the direction, then review and add it.

On the **Mac**, choose **Folders** in the sidebar. To keep a copy on this Mac,
open **Settings › Folders**, choose **Add this Mac to a folder** and pick a
folder in Finder. The Mac app hands that path to the daemon running on the
same Mac.

A folder's **Devices** list shows every member, its direction and its last
sync. From any device you can add a machine, change a member's direction or
remove it. The [command line](#command-line) does the same.

### Where a folder can live on a machine

Pick any folder on the machine, with these exceptions. Dieter refuses:

- `/`, your home folder itself, and system folders;
- Dieter's own data folder (`DIETER_HOME`, usually `~/.dieter`), anything
  inside it and anything that contains it;
- a folder that overlaps another synced folder on the same machine;
- a registered checkout, or any folder inside one. Git already keeps working
  trees in sync.

Dieter warns you about other Git working trees and about network or removable
disks.

### Adding a folder that already has files

When the folder you add already contains files, Dieter compares them with the
synced folder. Equal files are adopted, and files that exist only there are
added. For files that differ, you choose:

- **Merge** (the default) keeps both versions. The one changed most recently
  keeps the name, and the other becomes a [conflict copy](#conflicts).
- **Adopt folder contents** moves your differing files to the machine's trash
  first, and the synced folder's version wins.

Preview the plan before you decide; the CLI prints it with `--dryrun`.

### Settings of a machine's copy

| Setting              | Options                                                  |
| -------------------- | -------------------------------------------------------- |
| Location             | Set when you add the machine; it can't be changed later  |
| Direction            | Two-way, Upload only, Download only; Paused              |
| Watch for changes    | On (default) or off; see below                           |
| Full rescan          | Every 15 min, 1 h (default), 6 h or 24 h                 |
| Bandwidth limit      | Unlimited by default                                     |
| Concurrent transfers | 1 to 8; 4 by default                                     |
| Quarantine (macOS)   | On by default; see [Agents](#agents-and-linked-projects) |

Linux machines watch the folder with inotify and scan it in full at the rescan
interval; when the watch limit is reached they fall back to a scan every
minute. macOS machines check the folder about once a minute.

To move a folder to another location on a machine, remove the machine from the
folder and add it again with the new location. Removing a machine stops
syncing there; its files stay on disk.

## On your phone

### Where files live

On **Android**, choose a location when you add the folder:

- **Shared folder** (the default). A folder you pick, for example
  `Documents/Dieter/Inbox`. Other apps, such as your file manager or a scanner
  app, see and edit it. Android 11 and later don't let you pick the top of a
  storage volume or the `Download` folder itself.
- **Private to Dieter.** Dieter's own app storage. You reach the files only in
  Dieter's file browser and through the share sheet.

On **iPhone and iPad**, every folder lives in the Files app under **On My
iPhone** (or **On My iPad**) **› Dieter › _Folder name_**. Other apps open and
edit files there in place. The files stay readable for background syncs once
you have unlocked the device after a restart.

A file that is larger than your _Download automatically_ limit, or that you
freed to save space, stays listed with a cloud badge in the folder's **Files**
list. Tap it to download it, then open or share it. A file that isn't
downloaded is never a deletion: the other devices keep it.

### Folder sync settings

**Settings › Folder sync** sets the defaults for every folder on this phone or
tablet. They stay on this device.

| Setting                    | Android                                                                                                   | iPhone and iPad                                                                         | Default                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------- |
| **Folder sync**            | On or Off for every folder                                                                                | Same                                                                                    | On once you add a folder          |
| **Sync in the background** | Every 15 min, 30 min, 1 h, 6 h, 12 h or 24 h; Only while Dieter is open; Manual only                      | Often, About hourly, About every 6 hours, Daily; Only while Dieter is open; Manual only | 1 h (Android), About hourly (iOS) |
| **While Dieter is open**   | Sync when opened; Upload my changes right away; Keep in sync live                                         | Same                                                                                    | All on                            |
| **Network**                | Wi-Fi and unmetered only; Any network; Any network, large files on Wi-Fi only                             | Same                                                                                    | Wi-Fi and unmetered only          |
| ↳ _Large file threshold_   | 10 MB, 25 MB, 100 MB                                                                                      | Same                                                                                    | 25 MB                             |
| ↳ _Respect Data Saver_     | Follows Android Data Saver                                                                                | _Respect Low Data Mode_                                                                 | On                                |
| ↳ _Never while roaming_    | Skips syncs while roaming                                                                                 | Not available; choose Wi-Fi only instead                                                | On                                |
| **Power**                  | Only while charging; Pause in Battery Saver; Pause below 10%, 20% or 30%; Never                           | Only while charging; Pause in Low Power Mode; Pause below a battery level               | Pause in saver mode and below 20% |
| **Download automatically** | Files up to 10 MB, 25 MB, 100 MB or 1 GB; All files; Nothing (on demand only)                             | Same                                                                                    | Files up to 25 MB                 |
| **Storage limit**          | 1, 2, 5, 10 or 25 GB, or No limit; plus _Keep at least 1 GB free_                                         | Same                                                                                    | 2 GB; keep 1 GB free              |
| **Free up space**          | Removes downloaded files that are safe on a machine; they stay listed and download on tap                 | Same                                                                                    |                                   |
| **Notifications**          | Conflicts; Needs attention (deletion guard, location lost, limit reached); Sync finished                  | Same                                                                                    | Conflicts and Needs attention on  |
| **Status**                 | Last sync, next sync (estimate), files and bytes waiting to upload and download, cellular data this month | Same                                                                                    |                                   |

**iOS decides when background syncs run.** The interval you pick is a
preference. iOS chooses the exact time based on battery, network and how often
you use Dieter, so a sync can come later than you asked, or not at all for a
while when you rarely open the app. A short background sync moves the list of
changes and small files first; larger backlogs wait for a longer run, often
while the phone charges. **Sync now** keeps going after you leave the app (iOS
26 and later show its progress). Background syncs reach your machines only
while the iPhone is unlocked: the device key that proves it is your phone
lives in the Secure Enclave and works only then. To be sure a folder is
current, open Dieter.

**Android runs at the interval you pick** (15 minutes at the shortest), and
only when the network, battery and storage allow it. **Sync now** with large files
runs as a data transfer with a progress notification. Android 15 and later
allow such transfers at most 6 hours a day; Dieter stops cleanly and continues
later.

Every sync handles folders and deletions first, then files from the smallest
to the largest, so a large video never holds up a text file.

### Settings for each folder on this device

Open a folder and scroll to **On this device**. Each override starts at _Use
device setting_.

| Setting                              | Options                                                                                                                      |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| **Direction**                        | Two-way, Download only, Upload only, Paused                                                                                  |
| **After upload**                     | Upload only: _Keep on this device_ or _Remove from this device_ (frees the space; the file isn't deleted anywhere else)      |
| **Location**                         | Android: _Shared folder…_ or _Private to Dieter_. iOS: always _On My iPhone › Dieter › Name_                                 |
| **Sync interval**                    | The device setting, or its own interval (for example _Inbox_ every 15 min, _Archive_ daily); the shortest active one is used |
| **Network / Download automatically** | Override the device settings                                                                                                 |
| **Home machine**                     | Auto, or one machine that is a member                                                                                        |
| **Remove from this device**          | _Keep files_ (stop syncing and leave them) or _Delete local copy_ (only on this device)                                      |

## Directions

| Direction                        | Sends your changes | Applies other devices' changes |
| -------------------------------- | :----------------: | :----------------------------: |
| **Two-way**                      |        Yes         |              Yes               |
| **Upload only** (send-only)      |        Yes         |               No               |
| **Download only** (receive-only) |         No         |              Yes               |
| **Paused**                       |         No         |               No               |

A phone or machine set to **Download only** doesn't send what you change
there. The folder shows **Local changes**: _Revert_ downloads the folder's
version again, _Keep_ leaves your version on this device only.

A member set to **Upload only** doesn't apply changes made elsewhere. When it
falls behind, the folder shows **Not in sync**: _Override folder_ sends this
device's versions to every member as the newest ones.

## Conflicts

Dieter doesn't trust clocks to decide whether one version of a file replaces
another. Each file carries a record of which devices changed it. When two
devices change the same file before either has seen the other's change, Dieter
keeps both versions. One keeps the name, and the other becomes a conflict copy
beside it:

```text
Budget.xlsx
Budget (conflict, Pixel 9, 2026-11-13 14.12.05).xlsx
```

The conflict copy names the device that made that version and when, in UTC.
The version with the later modification time keeps the name; every device
picks the same one. A conflict copy is an ordinary file that syncs to every
member. Open both, keep what you need and delete the other. The folder's
**Conflicts** list offers _Keep this_ and _Keep that_. A file keeps at most 5
conflict copies; older ones go to the trash.

- **An edit beats a delete.** If one device deletes a file while another
  changes it, the file comes back with the change.
- **A folder beats a file.** If one device creates a folder where another
  created a file of the same name, the folder wins and the file becomes a
  conflict copy.
- **Names that differ only in case**, such as `Notes.md` and `notes.md`, can't
  both exist on a case-insensitive disk (macOS by default, many SD cards). The
  second one shows as **Can't sync here** on that device. Nothing is
  overwritten.

## Deletions, the deletion guard and the trash

When you delete a file on a member that sends its changes, every member that
applies other devices' changes deletes it too.

**The deletion guard** stops accidents such as an emptied folder or a script
gone wrong. When one batch would delete more than 100 files, or more than 30% of the
folder (at least 10 files), the device pauses with **Confirm deletion of 412
files**. Check the list, then choose **Apply** to delete them or **Restore** to
bring them back. The guard checks deletions found on a device before they are
sent, and deletions from other devices before they are applied. A folder's
**Deletion guard** setting is _Default_, _Strict_ (more than 10 files or 10%,
at least 3) or _Off_.

**Deletions settle first.** A machine records a deletion only after the file
has been gone for about three seconds, so a large deletion that is still in
progress (such as `rm -rf` on a big directory) is judged as one batch.

**A missing folder is not a deletion.** If a member's folder disappears, its
disk is unmounted or replaced, or Dieter loses access to it on Android, that
member pauses with **Folder location unavailable**. It never deletes anything
on the other devices because of it.

**The trash lives on your machines.** When a machine deletes or replaces a file
because of a change from another device, it keeps the old version in its trash
(inside `DIETER_HOME`, never inside the folder). Phones delete directly, but
every machine that is a member keeps the old version, so you can restore a file
from any device in the folder's **Recently deleted** list.

- The trash keeps files for 30 days by default. A folder's **Trash** setting
  is _Off_, _7_, _30_ or _90_ days.
- It uses at most 10% of the disk or 20 GiB per folder.
- When the folder is on another disk than `DIETER_HOME`, the machine copies
  files into the trash within that quota. When it can't, it warns that the
  trash is unavailable.

## Rules

Rules decide which files sync. Each rule is `-PATTERN` to exclude or
`+PATTERN` to include, matched against the path inside the folder:

- `*` matches any characters, including `/`. `?` matches one character, and
  `[abc]` one of a set.
- A pattern matches the whole path from the top of the folder. `-*.log`
  excludes log files at any depth; `-notes.txt` excludes only the top-level
  `notes.txt`. Add `-*/notes.txt` to exclude it in every subfolder.
- Rules are checked in order, and the last matching rule wins. A path that no
  rule matches is included.
- An excluded folder excludes everything inside it, whatever later rules say.
  To keep one file of a folder, exclude its contents instead:
  `-build/*`, then `+build/keep.txt`.

New folders start with rules that exclude system and editor clutter at any
depth: `.DS_Store`, `._*`, `Thumbs.db`, `desktop.ini`, `~$*`, `*.tmp` and
`*.swp`. You can edit or remove them. `.git` and files whose names start with
`.dieter-transfer-` never sync, whatever the rules say. A folder has at most
64 rules.

## Limits

| Limit                                      | Value                                                                   |
| ------------------------------------------ | ----------------------------------------------------------------------- |
| Folders per account                        | 64                                                                      |
| Members per folder                         | 16, at least one of them a machine                                      |
| Phones and tablets per machine, per folder | 16                                                                      |
| Files and folders in one folder            | 100,000 on a machine; 25,000 on a phone                                 |
| File size                                  | 64 GiB; phones also follow _Download automatically_                     |
| Path length                                | 4,096 bytes; each name at most 255 bytes                                |
| Rules                                      | 64 per folder                                                           |
| Transfers at once                          | 4 per folder and 8 per machine; 2 per phone                             |
| Conflict copies                            | 5 per file                                                              |
| Trash                                      | 30 days by default; at most 10% of the disk or 20 GiB per folder        |
| Deletion guard                             | More than 100 files or 30% of the folder (at least 10) in one batch     |
| Free space                                 | Downloads stop below 1 GiB or 5% free; phones also keep their own limit |

Large files resume after an interruption, and a changed large file transfers
only the parts that changed.

## Agents and linked projects

Link a folder to a project in its **Folder settings**. On the machines that are
members, that project's conversations then learn the folder: their
instructions name it, give its path on that machine and its direction, and say
that files you add on your devices appear there and files the agent writes
there reach your Mac and phones. At most 8 folders are listed. Folders that
aren't linked are never mentioned to agents.

Agents can read a folder's status, rescan it, restore files from the trash and
copy files in and out. They can't create, change, archive, add or remove
folders or members, change a direction, confirm or undo held deletions, or
empty the trash. Dieter refuses those requests from an agent's turn, so a
misled agent can't, for example, sync your SSH keys to your phone.

Agents run as your user, so treat this as a guard against mistakes, not as
isolation. An agent can still write any file into a folder it can reach, and
that file reaches your devices. On macOS machines, files that arrive from
another device get the same quarantine flag as AirDrop and browser downloads,
so macOS checks a program before it runs for the first time. You can turn this
off per machine.

## What isn't synced

- Symbolic links, sockets and devices. They are skipped and listed in the
  folder's status; the rest of the folder still syncs.
- Other disks mounted inside the folder. They are skipped and listed.
- Ownership, permissions, ACLs, extended attributes, hard links and sparse
  files. Only a file's executable bit syncs, between machines.
- `.git` folders and `.dieter-transfer-` files.
- Registered checkouts, which can't be a folder's location.

Empty folders do sync. Dieter doesn't merge the contents of two edits; it keeps
both versions. Folders can't be shared with other accounts, and there are no
web links.

## Troubleshooting

**Folder location unavailable.** The folder is missing, its disk is unmounted
or was replaced, or Dieter lost access to it. Reconnect the disk or restore the
folder and the member resumes. On Android, pick the folder again in **On this
device › Location**. If you moved the folder on purpose, remove the member and
add it again at the new location.

**Can't sync here.** This device can't store a file under its name: it differs
only in case from another file on a case-insensitive disk, or it contains
characters such as `\ : * ? " < > |`, or ends in a dot or a space, which SD
cards formatted as FAT or exFAT don't allow. Rename the file on another device.

**Waiting for Wi-Fi**, **Paused: Low Power Mode**, **Storage limit reached.**
Your Folder sync settings don't allow a sync right now. The folder continues
when conditions change. To sync now, connect to Wi-Fi or a charger, or change
the setting.

**Confirm deletion of N files.** The deletion guard is holding deletions. Check
the list, then choose **Apply** or **Restore**.

**Too many files for this phone.** The folder has more entries than a phone
keeps. Exclude large subfolders with rules, or keep the folder on a machine
only.

**A file doesn't appear on iPhone.** iOS hasn't run a background sync yet.
Open Dieter, or tap **Sync now**.

## Command line

Every app action has a `dieter folder` command. `FOLDER` is the folder's ID
or name. Commands that act on one machine's copy (`attach`, `detach`, `pause`,
`resume`, `status`, `rescan`, `deletions`, `trash`) run on the machine you
select with global `--machine`, or on your local daemon. A path you attach is
a path on that machine; write it out in full, because your shell expands `~`
on your own computer. See `dieter folder --help` and the
[CLI reference](/docs/cli-reference/) for every flag.

Create a folder and add two machines:

```sh
dieter folder create Reports --rule '-*.log' --project PROJECT --trash-days 90
dieter --machine studio folder attach Reports /Users/alex/Reports --dryrun
dieter --machine studio folder attach Reports /Users/alex/Reports --mode two-way --join merge
dieter --machine box folder attach Reports /srv/reports --mode receive-only
dieter folder list
dieter folder show Reports
```

`attach --dryrun` prints the plan without changing anything: the files that
would be adopted, added, kept as conflict copies or moved to the trash.
`--join adopt` chooses _Adopt folder contents_. Modes are `two-way`,
`send-only` (upload only) and `receive-only` (download only).

Change the folder, pause a machine's copy, or stop syncing there:

```sh
dieter folder update Reports --name "Agent reports" --delete-guard strict
dieter folder update Reports --rule '-*.log' --rule '-build/*' --rule '+build/keep.txt'
dieter --machine box folder pause Reports
dieter --machine box folder resume Reports
dieter --machine box folder detach Reports       # files stay on disk
dieter folder archive Reports                     # every member stops; files stay
```

`update --rule` replaces all of the folder's rules with the ones you give;
`--clear-rules` removes them and `--unlink-project` removes the project link.
`create` takes the same `--delete-guard`, and `--no-default-rules` starts
without the default rules.

Show or change a machine's copy:

```sh
dieter --machine box folder member Reports
dieter --machine box folder member Reports --mode receive-only --concurrency 2 \
  --bandwidth-limit 1048576 --rescan 3600 --watch true --quarantine false
```

Check a machine's copy and handle what needs attention:

```sh
dieter --machine studio folder status Reports
dieter --machine studio folder rescan Reports
dieter --machine studio folder deletions Reports --restore     # or --apply
dieter --machine studio folder trash list Reports
dieter --machine studio folder trash restore Reports ITEM_ID
dieter --machine studio folder trash purge Reports ITEM_ID     # without an ID: the whole trash
```

`status` shows the state, the files and bytes still to sync, conflict copies,
paths this machine can't store, held deletions and the last 100 errors. Add
`--format json` for scripts.

Copy files into or out of a machine's copy with the
[file transfer](/docs/file-transfers/) commands and `--folder`. A file you copy
in syncs to the other members like any other change:

```sh
dieter --machine studio file cp --folder Inbox remote:scan.pdf ./scan.pdf
dieter --machine studio file cp --folder Reports ./summary.pdf remote:2026-11/summary.pdf
dieter --machine studio file list --folder Reports 2026-11
```

The other `dieter file` commands (`list`, `read`, `save`, `create`, `move`,
`delete`, `stat`, `scan`) also take `--folder`. The apps use the same calls to
browse a folder's copy on another machine.

`dieter folder index`, `dieter folder blocks` and `dieter folder client`
inspect the sync protocol and register phones; you don't need them for
everyday use.
