# V2 bounded retry and measurement liveness plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans inline with TDD, one final independent read-only review.

**Goal:** снизить пиковую нагрузку повторных проб и не применять результаты, полученные после остановки тестового движка или истечения бюджета.

**Architecture:** единая чистая политика повторов ограничивает ширину4 и даёт короткую паузу. Lifetime учитывает реальные ширины основного/повторного batch; абсолютный Stopwatch deadline заканчивает запросы раньше native guard. Общий verified batch проверяет deadline и обязательный процесс до/после запросов и в очереди curl, сохраняет aborted evidence и бросает ошибку до таблицы/истории.

**Tech Stack:** PS5.1/BOM, штатный curl, TEMP mocked runner и loopback без перехвата.

**Spec:** автономное продолжение v2, пользователь подтвердил «ага» после c01bff5. Реальный код tools/test.ps1 повторяет с Parallel*2 и не проверяет живость движка во время основного scan; A/B уже проверяет её после batch. Снижение игрового пинга не обещается.

## Constraints / decisions

- Base c01bff5, текущая codex/v2. Без публикации, перезапуска живого обхода/наблюдателя, изменений служб/задач/адаптеров/маршрутов. Настоящий runtime и4 личные untracked заметки не менять.
- Ruling: normal retry Width=min(4,Parallel), пауза250мс только перед непустым retry. Первая попытка сохраняет Parallel, список повторов/порог RetryMax/веса/порядок стратегий не меняются. Цена ошибки: больше волн и дольше автоподбор при множественных сбоях; собственный guard получает согласованный бюджет.
- Бюджет: main waves*MainBatches + retry waves, по Timeout+1с на волну,30с startup/cleanup,250мс retry pause; минимум120000мс, максимум1800000мс (больший расчёт отвергнуть). MainBatches=1 normal/final,2 у A/B warmup+main. Parent deadline до native guard с запасом5с, от времени до запуска.
- Normal scan/final получают свой deadline и обязательный процесс; baseline — deadline без процесса. Exit во время batch, паузы/журнала или перед остановкой — fatal EngineUnavailable, не плохой балл стратегии. Не менять A/B payload/ranking; его общий30мин deadline сохраняется.
- Частичные/CANCELLED строки остаются в journal со Stage*-aborted; слияние/таблица/история не выполняются для прерванного прогона. Аргументы TimeoutSec1..60, Parallel1..64 валидируются до import/управления обходом.

## Review focus

- Native guard не истекает раньше рассчитанного более узкого retry; не возникает бесконечной очереди при Parallel0.
- Смерть движка не даёт успешных измерений напрямую; существующий процесс/служба пользователя не затрагиваются fixtures.
- Deadline действует в очереди curl и паузе, отменяет только принадлежащие запросы; skipped target не становится попыткой.
- Попытка1 записывается до mutable merge; aborted не обновляет рейтинг/основную/историю.
- A/B сохраняет4-wide и свой общий deadline/завершение; финальная проверка ещё проверяет фактическую рабочую комбинацию.

## Task 1: Retry policy and consistent lifetime

Files: tools/test.ps1; dev/tests/retrybudgettest.ps1; related fixtures in finalchecktest/comparisonruntest if needed.

Interfaces: Get-RetryProbePolicy(Parallelism) => Width/DelayMs; Get-TestInstanceLifetimeMs(TargetCount,Parallelism,Timeout,RetryParallelism=0,MainBatches=1) => validated int ms. Get-TestProbeDeadline(LifetimeMs) => absolute ticks with5s margin.

- [x] RED width/budget/parameter boundaries, including smaller width increasing lifetime.
- [x] GREEN policy/formula and documented parameter validation; focused checks.

## Task 2: Live process/deadline gates in normal scan and final

Files: tools/test.ps1; dev/tests/retrybudgettest.ps1, curlenginetest.ps1, measurementtest.ps1, finalchecktest.ps1, run-all.ps1; README.md.

Interfaces: Assert-ProbeContext(DeadlineTicks,RequiredProcess=null); Invoke-CurlBatch adds RequiredProcess; Invoke-TestProbeBatch(Targets,PostFile,Width,DeadlineTicks,RequiredProcess,JournalFile,Metadata,Attempt,DelayMs=0) gates/journals success or aborted evidence. Existing row/merge helpers unchanged.

- [x] RED mocked raw-attempt loop (width/order/delay/liveness/deadline/aborted), actual local curl cancellation when required fake engine dies.
- [x] GREEN integrate normal scan/final and keep A/B budget accurate; preserve control/merge/context guards.
- [x] Full offline suite, independent review, ledger and local integration; skips explicit.

## Verification ledger

Pre-flight: Task2 consumes Task1 retry width and budget/deadline; A/B must request MainBatches2 while retaining existing widths/global deadline. Established dev/plans ledger and ignored dist logs. No spec questions pending; user delegated routine implementation decisions.

RED: dist/v2-retry-retrybudgettest-red.log and curlenginetest-red.log reproduce missing policy/required-process guard. GREEN: policy boundaries, deadline margin, invalid CLI before any import/control, real scan main16/retry4/250ms and raw failure→flaky merge. Engine exit before first request, during main/retry/pause prevents table entry; deadline too short for pause starts no retry. Fixture needed the same Rounds/Parallel initialization as production; no product workaround for omitted fixture globals.

Actual loopback curl cancellation with a fake engine whose HasExited follows server acceptance passes3 checks: bounded interruption, no queued launches, owned curl gone and one CANCELLED observation. Focused retrytest/measurementtest/finalchecktest/comparisonruntest/curldeadlinetest/curlcontroltest/astlint pass; A/B resource/journal behavior retained. No actual bypass/adapter/service/task touched. Full suite/review pending.

Final verification: dist/v2-retry-budget-all.log, PS5.1 dev/tests/run-all.ps1 -Offline, exit0,45 groups,0 failed groups. Native-admin Lua/store I/O/actual timer expiry remain explicit skips; developer Lua and actual loopback curl tests executed. Independent read-only review found no actionable issues or deferred minors: budget/deadline/liveness/raw evidence and owned cleanup checked. git diff --check clean.

Local codex/v2 integration only. Current engine/watcher/services/tasks/network and actual user runtime were not changed by test runners. Version remains1.9 until a separately authorized v2 release. Peak retry concurrency is reduced; no live Wi-Fi/game-latency benefit was measured. The accepted tradeoff is extra retry waves under multiple failures.
