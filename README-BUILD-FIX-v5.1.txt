AnkiSync iPhone 14 Pro Max — Build Recovery v5.1 (storyboard-free)

WHY THIS PACKAGE EXISTS
The previous v5 launch screen used LaunchScreen.storyboard and a strict check for its compiled .storyboardc file. GitHub's actual build-error log was not available; that failure has not been conclusively diagnosed.

This fallback uses Apple's supported UILaunchScreen Info.plist dictionary, instead of compiling a storyboard. The Swift app, WebView, bundled HTML, iCloud bridge, UI styling, and review/sync algorithms are IDENTICAL to the previous v4 source. The original bundle identifier is preserved.

FILES YOU NEED TO CHANGE IN YOUR EXISTING GITHUB REPOSITORY
  AnkiSync/Info.plist
  project.yml
  .github/workflows/build-ipa.yml
Also DELETE the old AnkiSync/Resources/LaunchScreen.storyboard from your repository if present (it is not used by the new project.yml).

ALTERNATIVELY: upload the contents of the FULL source ZIP to your repo root, preserving the directory structure. Do not upload the ZIP itself or nest the source inside an extra folder.

THEN
  Actions > Build AnkiSync unsigned IPA > Run workflow
  When successful: open the run > Artifacts > AnkiSync-unsigned-IPA.
  Sideload over the current app using the same signing identity and bundle identifier. DO NOT uninstall the existing app first.
  No signed HTML update or iPad IPA upgrade is required for this launch-screen-only change.

IF IT FAILS AGAIN
  Open the failed run. Open the RED failed job step and copy the first error line (not just the final exit code). Also download the AnkiSync-build-diagnostics artifact if offered. Share that log so the precise cause can be corrected. If the workflow fails before Xcode runs, a build log may not exist; the failing step still reports why.

SAFETY/TESTING
  The source plist, YAML project reference, and Swift/HTML syntax have been checked locally, but this environment does not have Xcode. A successful GitHub IPA build and letterbox repair on the actual iPhone remain unverified.
