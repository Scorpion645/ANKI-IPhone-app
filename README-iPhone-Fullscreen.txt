AnkiSync iPhone Full Screen v4 — ONE-TIME NATIVE IPA REBUILD

WHY AN IPA BUILD IS NEEDED:
The large black bands at the top and bottom of the iPhone screenshot are outside the HTML webpage. The previous native SwiftUI/UIKit layout constrained WKWebView to a smaller frame. HTML-only changes cannot expand that frame.

WHAT CHANGED:
- AnkiSyncApp.swift: fill the SwiftUI window and extend behind the safe areas.
- AnkiSyncViewController.swift: pin WKWebView to all four edges, avoid double scroll-inset adjustments.
- AnkiSync.html (based on latest Compact UI v3): give iPhone status-bar/home-indicator safe-area padding, and wrap the study action buttons within the phone width.
- Info.plist: native version 2.2 (build 5), to promote the corrected bundled HTML when upgrading over the older IPA.

WHAT DID NOT CHANGE:
- iCloud Change Journal sync, card data, card styling/color palette, review schedules, Starred Cards, Swift native iCloud file bridge, and publisher verification key.

INSTALL:
1. Export current deck/review backups and preserve the installed AnkiSync app.
2. Replace the corresponding files in your existing private GitHub build repository with this ZIP's files, preserving directory structure. (An entire clean repository can also be created from this ZIP.)
3. Commit and run Actions > Build AnkiSync unsigned IPA.
4. Download the unsigned IPA artifact and sideload it OVER your existing application, using the same bundle ID and Apple Account. Do not uninstall the old app.
5. If an old published HTML update appears again after the app upgrade, publish the accompanying Signed Fullscreen HTML v4 files into iCloud Drive / Anki / AnkiSync-Updates and select Check App Update.
6. Test on your iPhone 14 Pro Max. The dark background should cover the entire screen, with controls below the status bar and above the home indicator.

IMPORTANT: Tested by static/syntax checks only here, not compiled on macOS or verified on your iPhone. A signed IPA is not included.
