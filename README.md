# AnkiSync iOS — v1.1 repair and native iCloud autosave

**This is source for GitHub Actions to build an unsigned IPA, not a compiled IPA.** Keep the same bundle ID and signing method to update the existing app. This build has passed JavaScript syntax validation, Swift parser validation, and simulated browser interaction tests, but **has not been compiled with Xcode or tested on a real iPad/iPhone.** Original iCloud .apkg auto-saving is newly implemented and must be tested with a copy of a small deck before trusting it with valuable data.

## Issues corrected

1. **Delete buttons and confirmation dialogs:** `WKWebView` now has a `WKUIDelegate` handling JavaScript `confirm`, `alert`, and `prompt`. Without this, confirmations could silently fail on the installed app.
2. **Link Original for Autosave:** The first IPA was intentionally read-only. The new native bridge can link a file inside your previously authorized iCloud Drive/Anki folder. It validates the `.apkg`, writes and verifies a SHA-256 recovery copy in the app's private Application Support storage **before enabling any original-file write**, and tracks the original SHA-256.
3. **Connection indicators:** The green dot is now driven by the actual native linked/active status. Simply importing a deck does **not** turn the dot green.
4. **Autosave:** Normal decks schedule native original-file saves 120 seconds after changes. Starred Cards schedules export after 5 seconds. `Save Now` performs a manual native save. The original ZIP entries are retained when adding review and card-state snapshots.
5. **Conflict prevention:** Each save checks that the original `.apkg` still matches the SHA-256 of the linked version. An external edit, missing recovery copy, or failed write pauses autosave instead of proceeding with an unchecked overwrite.
6. **Starred Cards:** Its tile shares the main layout, status indicator, action row, and colors of other decks; specialized actions and subject groups are in a collapsed section. Deleting Starred Cards deletes **only the in-app collection** and not original cards or any iCloud files.

## Update the existing GitHub repository

Only these three files need to be **replaced with their updated versions at the same paths**:

- `AnkiSync/Sources/AnkiSyncViewController.swift`
- `AnkiSync/Resources/AnkiSync.html`
- `AnkiSync/Info.plist`

The full ZIP also includes the existing `project.yml` and `.github/workflows/build-ipa.yml`, so it can be used to refresh the entire source tree.

1. **Before updating**, open your installed AnkiSync app and save/export any decks with edits or review progress that aren't already safely backed up. Take separate backups of existing `.apkg` files.
2. In your existing GitHub repository, update the three files **without moving them or creating duplicate folders**. GitHub Desktop/Git is an easy way to preserve paths. Commit the changes to `main`.
3. Open **Actions → Build AnkiSync unsigned IPA → Run workflow**.
4. After the workflow succeeds, open the run and download artifact `AnkiSync-unsigned-IPA`; extract the `.ipa` from its ZIP.
5. Update the existing iPhone/iPad installation using the sideloading tool you already used, using the **same Apple Account and bundle ID**. Do not uninstall your old app first; uninstalling can remove its local decks, bookmarks, and recovery copies. Updates do not always preserve local data with every sideloading setup, so maintain external `.apkg` backups regardless.

## First-time iCloud linking

1. On iPhone/iPad, tap **Connect iCloud Anki** and select the `iCloud Drive/Anki` folder if it is not already authorized.
2. Open or import **MA Sleep** or **Starred Cards** from that folder.
3. On that deck tile press **Link Original for Autosave**. A confirmation shows the exact file path. The app verifies an internal recovery copy before displaying the **green dot**.
4. Try **Save Now** on a *disposable test .apkg first*. Check its content/size via Files or another device, and check that the saved AnkiSync review state can be read. Verify **Refresh** and deletion separately.
5. The **garbage** icon deletes only the in-app deck after confirmation. **It does not delete the original `.apkg` file in iCloud Drive.** Starred deletion also preserves all cards in their source decks.
6. The **Recovery** button opens the iOS share sheet to export the verified original backup. Save the exported copy somewhere outside the app container so it survives app removal.
7. The **Pause** button disables future native original-file saves. To enable it again, use Link Original for Autosave and authorize/verify the file again.

## Safety and limitations

- **New native iCloud writes have not been tested end-to-end on an Apple device.** File Provider permissions and coordinated atomic replacement may behave differently across iCloud providers and iOS versions. Treat autosave as experimental until independently verified. Do **not** make your only copy of a deck writable from this version.
- The native recovery copy is stored in the app's private Application Support directory, **not in the iCloud folder**. It can be erased if the app is uninstalled or sideloading recreates its container. Always keep another exported `.apkg` backup accessible outside the app.
- The first write and every subsequent write are contingent on the original archive retaining its recorded SHA-256 and the original recovery snapshot being intact; otherwise autosave pauses. No automatic merge is performed if another device has updated the file. Refresh and explicitly relink after resolving changes.
- The app still uses online CDN libraries for some of its HTML functions. It does not bundle all dependencies for full offline support.
- A file's access permission can expire; reconnect the iCloud folder when requested.
- Native transfers still cap individual `.apkg` files at 512 MiB. Very large decks with images may require memory and storage headroom.
- The seven-day free-signing renewal rule is unchanged. Re-sign with the same identity as previously to retain the app container when possible.

## Included files

- `AnkiSync/Resources/AnkiSync.html` — original AnkiSync interface with narrow native-only integration and consistent deck tile.
- `AnkiSync/Sources/AnkiSyncViewController.swift` — WKWebView, functional confirmation dialogs, authorized iCloud access, verified recovery backups, SHA-256 guarded file writes.
- `AnkiSync/Sources/AnkiSyncApp.swift` — SwiftUI wrapper unchanged.
- `AnkiSync/Info.plist` — updated to version 1.1 (build 2).
- `project.yml`, `.github/workflows/build-ipa.yml` — unchanged cloud IPA build configuration.

## Native recovery data and file access

Use your already selected iCloud Drive folder only. Each auto-save uses `NSFileCoordinator`, and file hashes are calculated with CryptoKit SHA-256. The app's original Anki database entries remain within the `.apkg`; the AnkiSync review/card state is added as separate JSON entries. All writes are explicitly linked per deck; opening/importing is read-only until linked.
