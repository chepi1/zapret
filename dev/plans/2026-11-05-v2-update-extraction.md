# V2 reject partial update extraction

> Inline superpowers:executing-plans; authorized autonomous code-only v2 development. No real service/network changes or publication.

**Goal:** a failed or timed-out ZIP extraction cannot stop the working bypass or publish a partially extracted update, even when the downloaded bytes match the supplied archive digest.

**Finding:** Install-ZapretUpdate discards tar's exit code. A ZIP may extract the three legacy header files before another entry fails CRC, pass the subsequent presence/version check, and reach Stop-BypassCore.

**Implementation:** run system tar through existing bounded Invoke-Native with ConvertTo-WinCmdLine and120s deadline. Nonzero exit or TimedOut rejects before Get-UpdatePlan/transaction/stop. Preserve old package/settings and surface native extraction output. Keep existing SHA256 and version/header checks; this does not introduce a full new archive format or live rollback.

- [x] RED: real late-entry ZIP CRC error after header extraction; old updater still stopped/applied it. Four failing assertions dist/v2-update-archive-red.log. Only download/OS actions mocked on TEMP installations.
- [x] GREEN: bounded extraction result enforced; CRC and latezero timeout preserve old code/running bypass before stop, valid archive still installs. dist/v2-update-archive-green.log exit0.
- [x] Final54 offline groups exit0, dist/v2-final54-all.log; git diff check, local preview and actual v1.9 updater success path both PASS in dist/v2-legacy-upgrade.log. No live service/network changes or publication. Local commit next.

Review focus: stderr redirection cannot hide the status, timeout cannot become success, no stop or target write before extraction success; real tar args/path spaces and existing transaction behavior.

Ruling: retain the authenticated release ZIP contract and current planner. This bounded fix prevents an observed partial-extraction path; it does not assert semantic completeness of an arbitrary publisher-created archive or survival of every live startup failure.
