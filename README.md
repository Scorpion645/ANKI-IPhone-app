# AnkiSync iOS — iCloud HTML Updates (one-time IPA upgrade)

This repository uses the **existing AnkiSync interface and deck logic**. The only new feature is a native mechanism to check, verify, and install future HTML/CSS/JavaScript revisions from the `iCloud Drive / Anki / AnkiSync-Updates` folder.

## One-time iOS installation

1. **Back up and export your important decks and progress.** This update changes the native WebView's local HTML location; browser-local storage migration from the earlier IPA is not guaranteed.
2. Replace the iOS project files in your existing private GitHub repository with this package (keep the directory structure and `.github/workflows/build-ipa.yml`).
3. Run **Actions → Build AnkiSync unsigned IPA**, download its artifact, and use your existing sideloading method to update *over* the installed app. The bundle identifier remains `app.ankisync.personal.reader`.
4. Open AnkiSync on your iPhone and iPad. Choose **Connect iCloud Anki** and select the same `iCloud Drive / Anki` folder on each device. Existing folder permissions may be retained across an in-place update, but can require reauthorization.
5. Look for **Check App Update** next to the native iCloud buttons. It checks automatically when the screen launches, too.

## Future code updates — without rebuilding IPA

Use the **separate private Windows publisher kit** (do **not** upload it to GitHub):

1. Install Python and `cryptography` once: `py -m pip install cryptography`.
2. Place the future **iOS-compatible** `AnkiSync.html` (with `AnkiNativeBridge`) next to `Publish-Update.cmd`.
3. Double-click `Publish-Update.cmd`. It signs the HTML with your personal Ed25519 key and saves `AnkiSync.html` + `AnkiSync.sig` into `E:\ICLOUD sync folder\iCloudDrive\Anki\AnkiSync-Updates` (or a configurable path).
4. Once iCloud sync completes, open AnkiSync on the iPad/iPhone. Tap **Check App Update**; confirm the verified release and the interface will restart. The app also checks for available updates when launched, without interrupting an ongoing session.

The separate **Initial iCloud Release** ZIP is an optional signed starter release, not required when the IPA already contains the same HTML. You can copy its `AnkiSync-Updates` folder into your `iCloud Drive / Anki` folder to verify the publishing/verification workflow.

## Safety, storage, and limitations

- The IPA embeds only the **public** signing key; your **private** publisher key exists only in the separate publisher kit. Never upload that key to GitHub or iCloud.
- The app rejects incomplete, unsigned, altered, or incorrectly signed HTML and continues using the last working locally installed HTML when iCloud is unavailable. It does **not** download arbitrary HTML from web links.
- A verified update stays at one stable runtime path in the app's Application Support directory. The previous interface is kept locally. If an update breaks the interface, **double-tap the screen with three fingers** to open a native **Restore UI** confirmation and return to the bundled version; this does not delete your iCloud deck files.
- Publishing/updating code **does not edit `.apkg` deck files** or synchronize review states. Deck backup, autosave and cross-device conflict handling remain separate concerns.
- This does **not** bypass Apple's seven-day sideloading/re-signing requirement.
- A new IPA will still be necessary for a native Swift change (file access APIs, permissions, WebView implementation).
- This package was **syntax checked and cryptographically self-tested**, not compiled with Apple Xcode in this environment; test first on a spare copy of your deck.
