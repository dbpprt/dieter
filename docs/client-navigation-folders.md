# Client navigation folders

Android and macOS have separate folders for projects and standalone chats.
These folders organize navigation locally. Filing a chat does not move it to a
different project, change its execution owner, or change its pin. Deleting a
folder returns its contents to the ordinary lists without deleting resources.

On Android, create chat folders from **All chats** and project folders from
**Spaces**. Long-press a chat and choose **Move to folder**; use the folder button
on a project to file it. Either picker also offers **No folder** and **New
folder**. Folder menus rename or delete the folder. Expansion is remembered;
search temporarily reveals matching contents without changing that preference.
Pinned chats remain in Pinned and can also appear in their assigned folder.

## Persistence boundary

`NavigationFolderPreferences` holds the portable model and
`NavigationFolderStore` owns Android persistence. The two scopes use the Mac
keys `DieterSidebarProjectFolders` and `DieterAllChatsFolders`. Android stores
JSON strings in the private `dieter_navigation_layout` preferences; Mac stores
JSON data in its application defaults. Each value is an ordered array:

```json
[
  {
    "id": "stable-folder-uuid",
    "name": "Research",
    "itemIDs": ["stable-resource-id"],
    "isExpanded": true
  }
]
```

Folder and membership order are significant. An item belongs to at most one
folder in its scope. Rename preserves identity. Blank names and duplicate names
(case and accent insensitive) are rejected by editing controls. Unavailable,
filtered, or archived resource IDs are retained so temporary absence does not
rewrite a layout. Folder lists are projected against currently visible data.

This matches the current Mac shape as preparation for client storage. There is
no network synchronization or server-side folder operation yet. A future sync
layer needs account scoping, conflict/deletion semantics, and migration from
these local values; it must preserve stable folder/resource IDs and keep layout
separate from daemon-owned project and conversation mutations.

## Focused Android verification

The UI test uses the existing separate fixture application with a repository
that rejects network operations. It preserves the signed-in Android app and
requires only the visible emulator:

```sh
ANDROID_SERIAL=emulator-5554 apps/android/gradlew --project-dir apps/android \
  -Pdieter.screenTestBuildType=screenFixture \
  -Pandroid.testInstrumentationRunnerArguments.class=com.dbpprt.dieter.ui.NavigationFoldersTest \
  :app:testScreenFixtureUnitTest :app:connectedScreenFixtureAndroidTest
```
