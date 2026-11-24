AnkiSync iPhone 14 Pro Max — LETTERBOX / BLACK BAND FIX v5

DIAGNOSIS
The screenshot shows the app filling the entire width but only approximately 3:2 of the height.
That closely matches legacy iPhone 320x480 compatibility mode (black letterbox bands).
Version 4 expanded WKWebView but could not expand the app's system-provided viewport.

FIX — MINIMAL NATIVE CHANGES
1. NEW AnkiSync/Resources/LaunchScreen.storyboard — a true adaptive Xcode launch storyboard.
2. AnkiSync/Info.plist — explicitly sets UILaunchStoryboardName=LaunchScreen; bumps version to 2.3 (6).
3. project.yml — includes the storyboard as a resource.
4. .github/workflows/build-ipa.yml — fails the IPA build if launch storyboard is absent from the compiled app.

NO CHANGES to AnkiSync.html, the Swift files, card formatting, review algorithms, or iCloud sync.
The existing full-screen safe area code from v4 is retained unchanged.

HOW TO INSTALL (ONE IPA REBUILD)
1. Keep your existing AnkiSync installation and back up important decks/review progress.
2. In your GitHub source repository update:
   - AnkiSync/Info.plist
   - AnkiSync/Resources/LaunchScreen.storyboard [NEW]
   - project.yml
   - .github/workflows/build-ipa.yml [recommended build check]
   Alternatively upload the complete contents of this ZIP to a clean repo.
3. Commit files to main, run Actions > Build AnkiSync unsigned IPA.
4. Ensure run succeeds and shows LaunchScreen.storyboardc verification in the Package unsigned IPA step.
5. Download the resulting IPA; sideload over existing AnkiSync app using the SAME signing account/bundle ID.
   DO NOT delete the installed app first (may erase local progress).
6. Force-close and reopen AnkiSync. It should now use modern iPhone height, with HTML safe-area padding.
7. No iCloud AnkiSync.html or AnkiSync.sig update is needed: the HTML content is unchanged from v4.

If it still letterboxes: please provide screenshot of the GitHub workflow build log showing
"Verified modern iPhone LaunchScreen.storyboardc" and the installed IPA version.

TESTS
Verified Info.plist key, storyboard XML, XcodeGen YAML source reference and workflow checks.
No macOS Xcode build or device test was possible in this environment. The change is expected
from the established iOS launch-screen/compatibility relationship, but not guaranteed until tested.
