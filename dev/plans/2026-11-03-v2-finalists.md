# V2 finalist comparison implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** получить воспроизводимый shadow-отчёт сравнения двух явно заданных стратегий без записи рейтинга или смены основной.

**Architecture:** tools/comparison.ps1 строит seeded ABBA/BAAB-план и оценивает исходные JSONL-попытки. Отдельная ветка tools/test.ps1 -CompareA ID -CompareB ID исполняет этот план через прежние PS5.1/curl/контроль процессов, в фактическом IPSet и с auto=no. dev/perfbench.ps1 повторяет оценку сохранённых данных без запуска сети/движка.

**Tech Stack:** Windows PowerShell5.1, .NET Stopwatch, штатный curl; без новых зависимостей.

**Spec:** dev/research/2026-11-03-v2-review.md P1 и dev/plans/2026-11-03-v2.md задача4. Пользователь поручил продолжать самостоятельно; выбор порогов ниже — решение исполнителя, не результат живого измерения.

## Global constraints / rulings

- Работа агента: только offline/TEMP fixtures и dry-run; не останавливать живой обход, не менять Wi-Fi/Happ/службы/задачи. Не публиковать v2.
- Существующий автоподбор и Rounds=1 сохраняются. Новый режим запускается явно с двумя различными доступными numeric ID; в разговоре показываются # name стратегий.
- Сравнение фиксированных одиночных стратегий: clone настроек с auto=no, прежний IPSet. Не выдавать это за сравнение полных адаптивных кругов. Dry-run обеих конфигураций до остановки обхода.
- План: две A/A калибровки (до/после), между ними4 сравнительных блока по умолчанию (допустимо4..12, только чётное); в каждой паре ABBA/BAAB противоположны, начальный порядок каждой пары задаёт seed. Всего24 запуска при4 блоках. На каждом запуске1 одинаковый warmup,1 первая попытка, повтор только неуспехов. Сбор ограничен30мин, после дедлайна остаётся очистка/восстановление; process lifetime ограничен прежним guard и остатком общего бюджета.
- Время каждой реальной пробы — монотонные StartedMs/ObservedMs. TLS-разницу B-A считать интерполяцией внешней пары к фактическому времени внутренних проб; среднее двух остатков даёт block delta. AA noise — максимум абсолютных отдельных остатков обеих калибровок.
- Порог на endpoint: max(10мс,5% медианы A,AA noise). Повторяемое улучшение требует delta<-порог во всех сравнительных блоках хотя бы у одного endpoint, отсутствия delta>порог у других сравнимых endpoint и сохранения всех endpoint, стабильно успешных у A с первой попытки. Дополнительный gate после review: число первых успехов B не может быть ниже A ни у одного endpoint, включая частично доступные. Каждый заранее объявленный required group (по умолчанию все группы targets) должен иметь хотя бы один полностью сравнимый endpoint. Нельзя компенсировать потерю сервиса баллами второстепенных адресов.
- Retry-success учитывается отдельно и не превращает первый FAIL в OK для оценки. Missing/NA/nonfinite/неполные времена остаются неизвестными. Результат — наблюдаемая повторяемость, без 95% CI, P95/P99 или обещаний игрового пинга. Согласованный временной шум всё ещё может мешать выводу.
- План/журнал только opaque target/network/input hashes + group/name, фактический порядок и число наблюдений; без URL/SSID/прокси-секретов. Несоответствие плана/идентичности/дубликаты/смешанный контекст даёт Invalid; недостаточные данные — Inconclusive. Ошибка записи, игра, смена контекста/файлов, умерший процесс прекращают прогон. Сохранить незавершённые свидетельства; общий finally восстанавливает прежний обход.

## Review focus

- Неравномерные интервалы/дрейф не должны порождать ложный выигрыш; менять только wall clock недостаточно для достоверного порядка.
- Повтор после первого FAIL, потерянный обязательный сервис и много второстепенных OK не дают победу B.
- Дубли/перемешанные run/network/config/slot/strategy hashes и пустые/NaN времена не становятся сравнимыми данными.
- Прерывание/ошибка журнала/оставшийся тестовый PID не публикуют rank/settings/history; finally владеет текущим PID.
- Режим без CompareA/B не запускает дополнительные A/B-пробы; shadow-reader не запускает движок/внешнюю сеть.

### Task 1: Plan, assessment and offline replay

Files: tools/comparison.ps1 (new pure helpers), dev/perfbench.ps1 (new offline reader), dev/tests/comparisontest.ps1 (new), tools/lib.ps1 import/input hash.

Interfaces: New-FinalistPlan(AId,BId,AHash,BHash,Targets,NetworkKey,InputsHash,Seed,Blocks,RunId); Get-FinalistAssessment(Plan,Rows). Assessment.Schema=1,Status,CanRecommend (shadow only),Reasons,Groups,Targets,counts/block deltas/AA noise. Journal contract remains Write-ProbeJournal with additive optional slot/kind/arm/monotonic fields.

- [x] RED: seed/balance/immutability, irregular linear drift, stable real improvement, AA noise, per-service loss, retry recovery, incomplete/nonfinite/duplicate/context contamination fixtures.
- [x] GREEN: pure plan/evaluator, bounded offline JSONL reader; focused tests through PS5.1 on TEMP.

### Task 2: Explicit shadow execution and verification

Files: tools/test.ps1, tools/selection.ps1 optional journal fields, dev/tests/comparisonruntest.ps1 (new), run-all.ps1, README.md.

Interfaces: Invoke-FinalistExperiment(Settings,Targets,PostFile,Plan,InputsParameters,NetworkBefore,ActiveProcess ref). Each actual first/retry is saved before evaluation. Optional branch exits before old history/rank/settings path. Shared finally owns ActiveProcess.

- [x] RED: actual runner with fixture process/probe boundary — full planned sequence, warmup exclusion, retry evidence, exact working settings, context/game/deadline/process/IO abort; execute branch in child to prove no ordinary scoring.
- [x] GREEN: implement optional mode; add monotonic curl metrics and journal fields, keep old parser compatible.
- [x] Focused checks, full offline integration; one independent read-only review and TDD fix for actionable Important findings.
- [x] Record evidence/limits in ledger and main plan; local commit, no publish.

## Execution ledger

BASE 022d8c1. Existing codex/v2 checkout reused. Pre-flight Task1→Task2: Plan slot identity/assessment input are the same journal schema; optional fields must be added without changing existing selection/retry/final behavior. Ruling: keep comparison pure module separate from selection; include module in existing hash so policy changes invalidate old rankings.

Task1: pure plan/evaluator/replay implemented, PS5.1/TEMP focused passes. RunId/seed/slot/network/input/strategy/target identities validated; monotonic intervals and actual observation counts retained. Synthetic nonuniform linear drift gives0 delta for identical arms, -40ms for a true40ms B gain. AA80ms noise blocks a40ms gain. Missing/NA/NaN/duplicates, slower/lost required service and retry-only recovery do not recommend. No game/ping confidence or quantile claim.

Task2: explicit mode uses both dry-run before Stop-Bypass, fixed auto=no and existing IPSet, bounded width4, per-instance guard. Runtime/control/process/network boundaries substituted only in TEMP runner fixtures. Child executes actual shadow if/exit plus following scoring sentinel: shadow exits before ordinary scoring and still executes finally; ordinary branch continues. PID ownership survives a failed stop for outer cleanup. Real file-lock write failure aborts and cleans the candidate.

First full offline run dist/v2-finalists-all.log failed only the two new suites: they assumed shared package runtime had no old rank, while earlier suites had legitimately written one. Ruling: fixtures now use a unique runtime and verify prior control-state hashes unchanged instead of assuming a clean package. This was a harness isolation issue; no runtime from the user's checkout was touched.

Independent read-only review found2 Important (P2), both reproduced and fixed in one TDD pass:

- Final batch could be fully journaled before a failed liveness/context/cleanup check, then be recommended on offline replay. New completion record is written only after every slot's successful validation and PID cleanup; includes run/context/counts plus canonical SHA256 of significant evidence fields, independent of JSONL line order. Without finalization status is Inconclusive. Modified values/stages or duplicate finalizations are Invalid. A fixture kills the mock engine after the last measured batch: all72 first attempts remain, no recommendation. Unexpected retries after an initial success are invalid for this protocol.
- Total30min was only checked between batches. An absolute Stopwatch deadline now reaches every curl batch, stops starting queued requests, cancels owned active curl, records CANCELLED observations with unknown metrics, and restricts native guard to the remaining budget. A real slow loopback HTTP fixture verifies cancellation, absence of its owned PID on return, and retained cancelled evidence. Initial default-sandbox runs returned curl exit7 before reaching the deadline (loopback inaccessible); they were not treated as proof of the regression. The same fixture passed outside the sandbox; a TEMP-only copy with the3 deadline checks removed failed all3 assertions (dist/v2-finalists-deadline-valid-red.log), then restored code passed. No external traffic or driver involved.

Final: Ruling on review's ordering wording — balance is within seeded pairs, not all neighboring blocks; pair boundaries may repeat an orientation. README/plan clarified during the planned documentation step; generator remains paired and reproducible. Additional stability ruling: gate bFirstSuccess<aFirstSuccess per endpoint, preventing a partly available service from disappearing behind a stable peer of the same group. Red→green fixture covers this. Review's permissive unknown-stage/retry observation is covered for finalized data by evidence hash and strict retry protocol. Declined to judge: none beyond live service/real Wi-Fi acceptance, explicitly outside this offline phase.

Verification: dist/v2-finalists-final-all.log exit0,34 offline groups and no failures. New pure31, runner21 and actual loopback deadline3 assertions passed. Existing selection/retry/final/context/recovery/watch/store fixtures and all34 native strategy dry-runs remain green. Native admin luatest, actual timer expiry and native store timer/file I/O were explicitly skipped, not counted as executed; developer Lua fixtures ran using the existing optional runtime. First-attempt/control parser remains compatible. git diff --check clean.

Task1: complete (BASE022d8c1, PS5.1/TEMP, final pure31 checks; complete evidence preserved). Task2: complete (full post-fix offline34 groups, review P2s red→green). Finish ruling: retain codex/v2 locally as required by the ongoing v2 plan; no merge/push/PR/release. Remaining v2 work includes native admin acceptance, live Wi-Fi/game evidence, actual engine CPU/private bytes and comparison to v1.9, semantic coverage of the remaining Flowseal profiles, immutable run snapshot and release acceptance. No v2 publication or live bypass/network/service/task changes in this phase.
