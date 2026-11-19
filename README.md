# AnkiSync iOS companion — source and cloud IPA build

**Status:** Source package assembled and statically checked. NOT compiled, signed, or tested on an Apple device. There is no IPA inside this ZIP. The GitHub Actions workflow builds an **unsigned IPA** on a macOS runner. Sideloadly subsequently signs it for installation using your regular Apple Account.

## Features included in this first version

- Preserves the supplied AnkiSync HTML/CSS/study logic as the displayed UI.
- Presents the HTML in a native WKWebView on iPhone and iPad.
- Native **Connect iCloud Anki** control to choose your iCloud Drive/Anki directory once.
- Retains a security-scoped folder bookmark; asks for reauthorization if it becomes invalid.
- Native **iCloud Decks** button imports an APKG from that folder.
- On ordinary deck Refresh, reopens the latest APKG from that folder without a file picker.
- Independent Starred Cards Open/Refresh tries to read its own APKG from the authorized folder.
- Native bridge is READ ONLY. App does **not** silently write to original APKG files. Existing Save As and browser-local progress paths remain unchanged.

## Build an unsigned .ipa without installing Xcode yourself

1. Create a **private** GitHub repository to protect any content included in your customized HTML.
2. Upload all files and folders from this ZIP *preserving directory structure*, including `.github/workflows/build-ipa.yml` (this is a hidden folder on some systems). GitHub Desktop or Git is the easiest way to upload nested folders; you can also use GitHub web upload where supported.
3. In the GitHub repository choose **Actions** → **Build AnkiSync unsigned IPA** → **Run workflow**.
4. Once the workflow succeeds, open the workflow run and download the **AnkiSync-unsigned-IPA** artifact. Extract the downloaded ZIP; inside is `AnkiSync-unsigned.ipa`.
5. On your Windows PC install Sideloadly from https://sideloadly.io/ and connect your iPad/iPhone. Select the IPA, sign with your usual Apple Account, and install it. Follow Sideloadly's current instructions for any device-specific Apple trust/Developer Mode prompts.
6. Refresh/re-sign roughly every 7 days using Sideloadly. Use a consistent bundle ID and avoid uninstalling the app, which may erase its local database/bookmark.

**Do not upload your Apple password, certificates, provisioning profile, or device backups to this GitHub repository.** The GitHub workflow builds only an unsigned IPA.

## First run

1. Launch AnkiSync on the iPhone/iPad.
2. Tap **Connect iCloud Anki**, select the actual **iCloud Drive / Anki** folder in Files, and grant folder access.
3. Use **iCloud Decks** to import `MA Sleep.apkg` (once). If a deck is already present in the app's storage, that step may not be necessary.
4. On that deck's tile tap **Refresh**. Future presses read the source APKG from the connected folder directly.
5. If the file has moved or folder access has expired, tap **Connect iCloud Anki** to reconnect. iCloud files must be downloaded/available to Files when accessed.

## Safety, known limitations

- The app has not yet been built in a real Xcode environment, so cloud compilation errors may require a small correction.
- Native file transfers are chunked and currently capped at 512 MiB per APKG; extremely large decks may be slow or exceed device memory.
- Existing AnkiSync HTML loads libraries/fonts from online CDNs. This first wrapper still needs internet access for those assets. Full offline dependencies are not bundled.
- Browser-local persistence within WKWebView and the security bookmark behavior must be tested on your actual devices; they are not guaranteed until verified.
- **Refresh reimports the source APKG and can replace unsaved local changes/review progress.** Export a backup before refreshing. There is no background conflict resolution.
- The native bridge is read-only; no automatic saving/overwriting of original iCloud APKG files is implemented in this version.
- Keeping an app sideloaded under a free Apple Account typically needs re-signing every 7 days. Avoid deleting the app when renewing, to preserve local data.
- Your existing Safari AnkiSync storage is **not** automatically migrated into this app. Import decks or exported backups separately.
- Apple iOS security-scoped bookmarks can become stale or lose access as File Provider state or permissions change. Reconnect in that case.

## Structure

- `AnkiSync/Resources/AnkiSync.html`: original AnkiSync HTML with a small native-only bridge added; no theme or study changes intended.
- `AnkiSync/Sources`: SwiftUI application shell + WKWebView and security-scoped directory reader.
- `AnkiSync/Info.plist`: iOS app settings.
- `project.yml`: XcodeGen app project spec.
- `.github/workflows/build-ipa.yml`: cloud macOS compilation and unsigned IPA artifact.

## References

- Apple Directory Access: https://developer.apple.com/documentation/uikit/providing-access-to-directories
- Apple WWDC19 File Management: https://developer.apple.com/videos/play/wwdc2019/719/
- Apple WKScriptMessageHandler: https://developer.apple.com/documentation/webkit/wkscriptmessagehandler
- Sideloadly FAQ: https://sideloadly.io/faq.html
