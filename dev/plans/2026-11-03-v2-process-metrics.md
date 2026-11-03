# V2 process resource measurements implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** получать фактические CPU-time/private bytes процесса движка в shadow A/B и отдельно читать счётчики заданного PID без управления обходом.

**Architecture:** tools/processmetrics.ps1 содержит read-only snapshot и чистый расчёт окна. dev/perfprobe.ps1 читает явно заданный процесс. Новые comparison-планы используют finalists-v2/process-v1 с3 resource samples на запуск (ready/warm/end) в том же подтверждаемом JSONL. Legacy finalists-v1 и его canonical hash остаются совместимы. Затраты выводятся отдельно от прежней HTTPS-оценки.

**Tech Stack:** PS5.1/.NET Framework Process, Stopwatch; без зависимостей/сервисов/драйверов.

**Spec:** dev/plans/2026-11-03-v2.md задача4; dev/research/2026-11-03-v2-review.md стоимость движка. Пользователь поручил продолжать самостоятельно; решения ниже приняты исполнителем.

## Global constraints and decisions

- Только TEMP/fixtures для агента, без живых A/B/restart/service/task/NIC/Happ изменений. Codex/v2 локально, не публиковать v2.
- Метрики относятся к одному процессу движка, PID+ProcessStartKey (UTC ticks как exact decimal string, без потери precision в double). На импорт ничего не опрашивается. Состояние Exited/access failure сохраняет null, не вымышленный ноль; API-измеренный CPU=0 допустим и ограничен разрешением ОС.
- Snapshot: ResourceStatus Ready/Unavailable/Exited, ProcessId, ProcessStartKey, ObservedMs (Stopwatch midpoint), ReadDurationMs, CpuTotalMs, PrivateBytes, WorkingSetBytes, OsPeakWorkingSetBytes. Refresh перед memory reads. Повторная проверка identity/liveness после чтения.
- Window: >=2 последовательных Ready samples одного PID/start, монотонное время и CPU; CPU delta, wall duration, CPU% одного ядра (может>100), start/end private, observed maxima private/working set и OS peak working-set на конец. Наблюдаемый максимум3 точек не называется реальным пиком private/RAM. Отсутствующие/невалидные значения не участвуют как нули.
- Shadow: ready sample после Start-TestInstance, warm sample после одинакового прогрева+валидации, end после первых/повторных проб+валидации до Kill. Warmup и Measured окна разделены; CPU запуска до ready отдельно не оценивается. Процесс может обрабатывать фоновый трафик: это стоимость процесса в окне, не CPU на байт/пакет или игровой пинг. Самpler read wall-time не является CPU движка.
- Process-v1 требует3 samples каждого слота и полную идентичность slot/run/config/network. Unavailable counters допустимы как записанные свидетельства: HTTPS-вывод сохраняется, resource summary Unknown/Partial. Пропущенные/дублированные resource records и смешанные контексты записей и изменённый hash — Invalid. Завершающий marker после PID cleanup связывает также метрики. V1 plan не принимает resource rows; V1 probe hash не меняется. Порядок строк JSONL не является временной осью: replay использует захваченные монотонные времена и slot/phase, включая последовательность запусков между слотами.
- Сводка A/B только по Compare/Measured (не Calibration/Warmup): known/expected windows, CPU/wall sum и weighted CPU%, end-private median, sampled-private max, actual request/retry counts. Все значения descriptive, автоматическое ранжирование/порог/применение не меняются.
- dev/perfprobe.ps1: обязательные ProcessId/OutFile, duration1..30s и interval100..5000ms. Один Process object, без повторного поиска PID; только read/dispose handle, никакого Kill. CreateNew output, raw samples+window. Тесты могут запускать/останавливать только свой явно созданный TEMP child.

## Review focus

- Access denied, missing fields, early exit и OS CPU quantization не создают ложную нулевую стоимость.
- PID reuse, CPU counter decrease, reversed/nonfinite clock не склеиваются в хороший window.
- Legacy v1 replay/hash не меняется; v2 hash включает resource identity/status/metrics.
- End snapshot не публикует результат до финальной проверки/cleanup; warmup/calibration не попадают в steady summary.
- CLI sampler и обычный автоподбор не запускают/останавливают чужой процесс и не включают дополнительные пробы.

### Task 1: Counter samples, windows and read-only CLI

Files: new tools/processmetrics.ps1, dev/perfprobe.ps1, dev/tests/resourcetest.ps1, dev/tests/resourceprocesstest.ps1; lib import/input fingerprint and run-all registration.

Interfaces: Get-ProcessResourceSample(Process); Get-ProcessResourceWindow(Samples). Window.Schema1, Status Ready/Unavailable/Invalid; nullable metrics, Reasons, SampleCount. CLI output.Schema1, Samples, Window.

- [x] RED pure windows (literal deltas, >100% core, unknown/missing, reuse, decreasing CPU, time/numeric corruption) and actual TEMP child sampler.
- [x] GREEN .NET reads and pure computation; PS5.1 focused tests, no network/driver.

### Task 2: Finalists-v2 resource evidence

Files: tools/comparison.ps1, tools/test.ps1, dev/perfbench.ps1, README.md; resourcetest/comparisonruntest fixtures.

Interfaces: New-FinalistPlan(...,-MeasureResources) -> finalists-v2 with ResourcePolicy process-v1. Write-ProcessResourceJournal(Path,Metadata,Phase,Sample), Get-FinalistResourceAssessment(Plan,Rows). Get-FinalistAssessment.Resources optional summary; protocol-v1 remains supported.

- [x] RED v2 matrix/context/hash/legacy compatibility, measured-vs-warm/calibration scope and actual runner snapshots.
- [x] GREEN journal/summary/replay integration; no resource-based ranking.
- [x] Full offline suite, one independent read-only review, TDD Important fixes; ledger and local commit.

## Execution ledger

BASE7b91be5. Existing checkout reused; user has opted out of additional questions. Task1→Task2 pre-flight: samples and journal share ResourceStatus/identity/metrics, start key must remain string and legacy probe canonical fields must not grow. No conflicts.

Primary API references: [TotalProcessorTime](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.totalprocessortime?view=netframework-4.8.1), [PrivateMemorySize64](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.privatememorysize64?view=netframework-4.8.1), [Process properties](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process?view=netframework-4.8.1). PrivateMemorySize64 is the refreshed Private Bytes counter; TotalProcessorTime sums user+kernel CPU; working set is a separate physical-memory observation.

2026-11-04 execution: both missing APIs observed RED before implementation (dist/v2-resource-red.log, v2-resource-process-red.log). Pure windows pass literal60ms/2000ms=3%,200% one-core, measured0CPU, unavailable/null, negative/nonfinite/reused PID, exact low start-key digits and reversed/decreasing counters. Out-of-range PID initially escaped via int cast; RED reproduced, range guard added.

Actual PS5.1 TEMP child: positive OS-accounted CPU during400ms controlled work,32MiB held allocation observed after Refresh, PID differs from sampler host. dev/perfprobe preserves raw samples/window, never stops its observed process, refuses existing output, returns Exited/null after our fixture ends. No network/driver/service involved. This verifies the sampler, not winws throughput or lower game latency.

V2 runner RED: no resource snapshots/records in the old branch. GREEN now captures72 observations across24 launches, by the exact owned Process reference. Resource frames share the bound journal/footer, distinguish warmup3ms from measured2ms in literal runner fixtures, and offline replay reproduces16ms summed CPU for8 measured windows per arm without querying another process. Native failure/read-denial paths yield nullable costs while preserving valid HTTPS evidence. Real exclusive journal lock on the Ready record aborts before probes, cleans PID and leaves no result. Child shadow-branch harness updated to reflect the new Resources field/formatter; original exit/finally/scoring separation remains green.

Compatibility: v1 canonical probe hash literal4A2D727AAE9C51B7D1A9C99A43FD170DEA5BFE4CD2800223F308587FBD4CE8AB unchanged. V2 checks missing/duplicate phases, mixed hashes/slot identities, phase-clock enclosure of actual probes, known PID/start identity, resource count and completion hash. Unavailable samples are present records, not missing ones. Source/module fingerprint includes processmetrics.ps1. No effect on default selection/primary policy.

Independent read-only review completed. Final rulings/fix pass:

- Reviewer graded reversed JSONL transport order as P2 against ambiguous “перемешанные records” wording. Ruling: captured monotonic clocks and identities are authoritative, as in legacy replay; line order is deliberately not authoritative and canonical hashing is order-independent. Clarified “mixed contexts” in plan, preserved shuffled-file replay with literal CPU result160ms. Added the meaningful sequence guard: a next engine resource window must start after the preceding engine window ended. Overlapping windows RED then GREEN.
- Reviewer called finite inputs producing Infinity with Ready a minor robustness issue. Regraded Important data-quality defect: new offline cost reports must not trust nonfinite derived values. RED cases cover per-window CPU%, summed aggregates and median of large finite memory values. GREEN computes ratio before scaling, rejects nonfinite derivations, and uses a stable median expression. Dist/v2-resource-review-red.log and v2-resource-median-red.log record the failures; full suite verifies fixes.
- Declined live engine/game/throughput proof: intentionally remains a separate acceptance step. Actual Access Denied against a protected foreign process was not attempted; generic counter exception/null behavior verified. Full offline suite and documentation completed by root.

Verification: dist/v2-process-metrics-all.log exit0,37 offline groups,0 failures. Actual native process tests ran; existing native strategy dry-runs and developer Lua fixtures remain green. Admin-only luatest, actual guard expiry and native store timer/file I/O remain explicit skips. git diff --check clean. Task1: complete; Task2: complete. Finish ruling: retain codex/v2 locally, no merge/push/PR/release; preserve four untracked personal notes. Live bypass, services/tasks/NIC/Happ and user runtime unchanged. Remaining: actual v1.9/v2 process comparisons under comparable traffic, UI cold/warm costs, live Wi-Fi/game acceptance, full profile semantics and immutable run snapshot.
