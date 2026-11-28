AnkiSync native source baseline — 2.3.2 (build 8)

This is a development backup, NOT an installation requirement.
Based on the supplied GitHub ZIP, with the signed Clear Sync Status HTML bundled.
The original HTML signature was verified against the Swift pinned public key.
The duplicate UILaunchScreen property was normalized; bundle version advanced so
a future IPA build will load its newer trusted bundled HTML. Bundle identifier,
Swift source, workflow and synchronization protocol are unchanged.

No automatic publisher takeover or mobile archive publishing has been enabled.
Do not replace the current working IPA or publisher role files for this baseline.
The project needs Xcode/GitHub Actions to build and device testing before release.
Do not change the app identifier or signing identity without planning data migration.

Next architecture: a server-authoritative conditional commit of a verified immutable
archive reference, or iCloud Drive-only immutable archive backups with a designated
publisher retaining the canonical .apkg. A local iCloud checksum is not a global lock.
