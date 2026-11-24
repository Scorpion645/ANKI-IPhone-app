AnkiSync iCloud Change Journal v1 — CONTROLLED PILOT
===================================================

This is a NEW sync protocol using immutable per-device JSON records under:
    iCloud Drive / Anki / AnkiSync-Changes / deck-<id> /
The original .apkg files are NOT overwritten by this protocol.

PREPARE
1. Export and keep a separate .apkg backup from EACH device. You previously
   had 357 due on iPad and 378 on iPhone; DO NOT discard either copy.
2. Use a disposable test .apkg first, imported identically on both devices.
   Do not enable the real MA Sleep deck until its existing differences are reconciled.
3. Never combine old "Enable Sync" (full .apkg overwrite) and new journal sync.
   The updated interface disables old automatic .apkg sync when it initializes.

WINDOWS PC
1. Extract the PC ZIP outside iCloud Drive.
2. Close all older AnkiSync launchers listening on port 47621.
3. Double-click Start-AnkiSync-on-PC.cmd. Python 3 required; no pip modules.
4. Use Chrome or Edge at http://127.0.0.1:47621/.
5. The launcher uses E:\ICLOUD\iCloudDrive\Anki. Only loopback connections are allowed.

IPHONE / IPAD
1. Native Swift bridge changes require one new IPA build via your existing
   GitHub Actions workflow. Install OVER the previous app using the same bundle ID.
2. Connect iCloud Drive / Anki inside the app.
3. The signed update ZIP can be copied to AnkiSync-Updates AFTER the new IPA
   is installed; it contains the same journal-compatible HTML.
4. Old IPAs cannot access AnkiSync-Changes. HTML updates alone are insufficient.

FIRST TEST
1. Import the SAME disposable .apkg on both devices.
2. On iPad, tap Enable iCloud Changes. Confirm the one-time initialization.
3. Wait for the AnkiSync-Changes folder to finish appearing on iPhone.
4. On iPhone, tap Enable iCloud Changes. It will refuse if starting cards or
   review schedules differ. Never approve a replacement merely to silence an error.
5. Rate one test card Good on iPad. Wait for iCloud to deliver the small event.
6. Tap Check Changes on iPhone (or leave it open; it checks every ~15 seconds).
7. Verify EXACT dueAt and lastReviewedAt. Then edit a DIFFERENT card on iPhone
   and verify it arrives on iPad.
8. Finally, try editing the same field differently on both: it must STOP with
   a conflict and keep both versions. Export backups for manual resolution.

IMPORTANT LIMITS
- iCloud Drive transfer latency is not guaranteed, even with both apps open.
- No continuous background execution on suspended iPhone/iPad apps.
- Conflicting same-field edits and initially mismatched decks are HELD, not
  automatically reconciled. Both versions remain untouched for review.
- The FIRST manifest is a full snapshot, not a repeated .apkg export;
  subsequent files record changed card fields only.
- Card order changes and whole-deck tile deletion are not synchronized in v1.
- This pilot has JavaScript simulation and Windows local API tests; a real
  iPhone/iPad native build and iCloud transfer still need verification.
- No new cloud database, login, or Firebase is used.
- Leave AnkiSync-Changes alone; records are immutable. Do not move or rename it.

This source retains the original GitHub Actions build configuration.
