# V2 release package implementation plan

> Execute inline with superpowers:executing-plans. User explicitly requested autonomous continuation. Existing codex/v2 checkout is the working branch; no live service/network changes or publication.

**Goal:** a release includes only declared runtime files and clean user-list defaults, preserves local settings, and never destroys the previous archive on failure.

**Architecture:** a committed dev/package-files.txt allowlist works without Git. Four versioned dev/package-defaults/lists templates preserve the shared SoundCloud/Valve defaults. dev/build.ps1 streams declared inputs into a unique ZIP beside the destination using .NET ZipArchive, verifies entries and publishes with atomic File.Replace/Move. Stable ordering/timestamps make repeated builds on the same runtime byte-identical. No recursive staging copy or native tar is needed.

**Constraints:** Windows PowerShell5.1, UTF8 BOM; existing version remains1.9 until v2 release preparation. Keep all current runtime dependencies, licenses, binary hashes and game exclusions. No local runtime/autohostlist/backups/undeclared source files. Fail closed on invalid/duplicate/traversing manifest paths, reparse inputs, missing files or write errors. Source user lists must remain byte-identical after a build.

**Spec:** this bounded repair follows the observed blanket robocopy leak in dev/build.ps1; requirements above are the implementation spec. No independent speculative product feature.

## Tasks and evidence ledger

- [x] RED: buildtest seeds private files/user-list markers; original builder leaks local files/user markers and accepts missing required input (dist/v2-package-red.log).
- [x] GREEN:106-file allowlist/four clean templates, .NET ZIP builder, guarded cleanup and atomic publication; buildtest registered and developer documentation updated.
- [x] Verify buildtest and complete offline suite with settings/migration:52 groups, exit0, dist/v2-package-settings-all.log. Native admin-only Lua/store/timer paths remain explicit skips. Final builder regression log dist/v2-package-digest-final-green.log.
- [x] Final local preview: dist/v2-preview-20261105/zapret-v2.0.zip,107 entries, SHA256 fa31e2d2322084f1a8ce0debc0d17a0657f39b6ddad671b75c61db6418b4d3ca. Stable source Version remains1.9; candidate Version2.0/preview labels are applied only on a TEMP build copy. Actual tagv1.9 updater installs it on a TEMP fixture with personal-byte/restart-intent preservation, then installed native CLI/compiler preflight passes (dist/v2-legacy-upgrade.log). No publication or live controls.

Review focus: Windows case-insensitive path collisions; directory reparse points; source/default file disappearance; output locked or replacement failing; cleanup ownership and archive inclusion of tools/filtercheck.cs. Tests must exercise failures without mutating the actual working package.

Ruling: stream ZIP directly instead of retaining tar/staging — smaller failure surface, no external archiver or recursive deletion; costs a deliberate fixed-timestamp ZIP format change.

Pre-flight: manifest/defaults are builder inputs; buildtest exercises them through the real PS5 child process. No production library or live bypass interface changes.

Final review: one fresh read-only reviewer found2 Important defects. Windows trailing-dot aliases bypassed clean-list selection; RED dist/v2-package-dotted-red.log → GREEN after rejecting noncanonical components/device aliases. Post-publication SHA256 read error lost the prior output; real reviewer filesystem-watcher repro and deterministic RED dist/v2-package-digest-real-red.log → GREEN after hashing temporary ZIP before publication. No other C/I/M. Current tests also cover case aliases, missing template/source, unreadable source, linked input directory, locked destination, exact entries, owned-temp cleanup and same-input byte identity.

Ruling: builder trusts declared source files during a development build, not a hostile concurrent writer. It does not claim frozen inputs under adversarial mutation or identical compression across different .NET implementations. No live service behavior or release publication evaluated in this phase.

Ruling: package and settings/migration share run-all registration and one52-group integration run, so record them in one local preparation commit; importer fixtures/code remain a separate next phase.
