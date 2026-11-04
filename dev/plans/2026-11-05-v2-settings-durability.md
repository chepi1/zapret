# V2 settings durability and migration checks

> Execute inline using superpowers:executing-plans; user requested autonomous v2 completion. Code-only, existing codex/v2 checkout; do not touch live settings or service.

**Goal:** settings.ini readers see a complete old or new file; failed saves preserve the old settings, and v1.9 personal state survives installation of the packaged v2 code.

**Architecture:** Save-Settings keeps the existing sorted UTF8-no-BOM/CRLF format. It writes a unique sibling with CreateNew, Flush(true), then publishes with File.Replace (NullString backup) or File.Move. Exceptions propagate and only the owned temporary file is cleaned. No change to locking policy or user options. Migration test exercises the real package builder/update planner/file transaction on an isolated representative v1.9 tree with service/network actions absent.

**Constraints:** Windows PowerShell5.1, preserve PS BOM, no new dependency or runtime module. No atomicity claims across settings plus engine restart, no promise of survival of physical disk failure. Do not alter the actual running installation. Version remains unreleased until final packaging step.

- [x] RED: deterministic injected partial low-level Write-TextNoBom failure destroys old settings (dist/v2-settings-failure-red.log). Real concurrent writer/reader processes and full-file hashes cover the reader contract; pin sorted bytes, no BOM, existing/new file and locked-target failure cleanup.
- [x] GREEN: Save-Settings atomic sibling write + flush/replace, registered settingstest, dist/v2-settings-green.log:10 checks including real concurrent reader/writer and foreign temp preservation.
- [x] Migration/package integration: real built archive over representative v1.9 fixture preserves settings/user lists/reports/history/Flowseal freshness, installs dependencies, removes only explicitly retired strategies, passes installed native CLI/filter preflight. Stronger rollback/byte assertions dist/v2-migration-bytes-target.log exit0.
- [x] Offline suite:52 groups exit0 dist/v2-package-settings-all.log; one scoped fresh read-only reviewer, no open C/I/M. Local preparation commit alongside packaging.

Review focus: Windows share-delete reader handles, failure before/after temporary creation, old/new file ownership and ACL behavior, source user state retained by Get-UpdatePlan, retired selected strategy fallback without resetting unrelated options.

Ruling: keep transaction-wide crash recovery in existing recovery.ps1; do not introduce a second last-good runtime engine mechanism without a bounded immutable configuration snapshot. This phase protects settings and proves file migration, not live engine rollback.

Ruling: concurrency stress alone passed on the old writer (285 reads), so it is not a reliable RED. Inject partial-write failure at the existing text-writer seam, retain real-process concurrency as regression coverage. Keep the existing text writer for format compatibility, then reopen/Flush(true) before publishing the reserved sibling; extra opens occur only when saving settings.

Final review: Important test gap fixed by ordering existing lib replacement before the injected later failure and witnessing code replacement/new engine dependency before rollback. Minor text-only preservation gap fixed with per-file SHA256 plus UTF8 BOM settings and UTF16 report fixtures; byte identity is asserted after failure and success. Reviewer independently confirmed retained share-delete old handle, fresh new handle, unchanged protected SDDL and partial .NET MethodInvocationException propagation even with caller EAP Continue. Updated target tests passed; no live actions.

Ruling: no new serialization for independent settings writers; caller coordination remains unchanged. NTFS/PS5.1 is verified, FAT/exFAT/SMB and physical power failure are not acceptance claims. Migration fixture validates the current planner/file transaction, not the old1.9 installer process or a live Windows service upgrade.
