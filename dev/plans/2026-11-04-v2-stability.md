# V2 capture and Wi-Fi learning stability plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans inline with TDD and one final independent read-only review.

**Goal:** исключить заведомо необрабатываемый UDP до userspace и не обучать автосмену на соединениях, затронутых подтверждённым разрывом Wi-Fi.

**Architecture:** чистый ограниченный компилятор небольшого списка Take-Two создаёт согласованные статические исключения профилей и AND-фильтр WinDivert только для исходящего IPv4 UDP. Отдельный локальный link-guard heartbeat сообщает Lua о подтверждённых разрывах; затронутые соединения исключаются из детекторов, затем новые соединения снова учатся. Существующий network-context protocol3 не меняется.

**Tech Stack:** Windows PowerShell5.1/BOM, Lua, WinDivertHelperCompileFilter/EvalFilter без открытия драйвера, TEMP fixtures.

**Spec:** пользователь одобрил приоритеты из предыдущего сообщения и автономную реализацию. Приоритет1 — безопасное сокращение перехвата; приоритет2 — защита обучения. Измеренное снижение игрового пинга не обещается.

## Global constraints / decisions

- Существующий codex/v2, base efec02d; без публикации, запуска живого теста, перезапусков обхода/служб, изменений Wi-Fi/маршрутов/задач. Личные untracked заметки и настоящий runtime не трогать.
- Не сужать динамические порты игр вслепую и не исключать Valve/Steam relay. На первом этапе только сети, уже исключённые во всех профилях.
- Ruling: только небольшой корректный IPv4 список Take-Two (до32 уникальных CIDR) компилируется в фиксированный launch snapshot для профилей и драйвера; IPv6/неподдерживаемые/пустые/большие списки сохраняют прежнюю файловую обработку без kernel optimization. Причина: обе ступени должны иметь одинаковые исключения. Цена ошибки: изменения этого внутреннего списка требуют нового запуска; пользовательские динамические списки не компилируются.
- Ruling: подтверждение Wi-Fi — OperationalStatus переход ранее активного Wi-Fi либо WLAN8003 того же интерфейса со шлюзом. Простой HTTP/ICMP timeout, ошибка чтения или событие другого адаптера не считаются разрывом. Защитное окно20с, публикация существующим наблюдателем каждые5с, чтение Lua не чаще1с. Цена ошибки: до20с задержки обучения; событие, не замеченное наблюдателем/журналом, не защищено задним числом.
- Link heartbeat protocol1: `1 <stamp> <eventEpoch> <pauseUntil>\n`, до64bytes, freshness10с, stamp после старта Lua, future/malformed/expired не блокируют обычный detector. Только фиксированное имя link-guard.txt; внешних запросов/SSID/IP в записи нет.
- Изменённый eventEpoch помечает старые соединения непригодными для обучения; начатые во время паузы также исключены навсегда. Новые соединения после паузы снова используют обычные детекторы. Рабочая стратегия и память не очищаются только из-за link guard.

## Review focus

- Kernel filter не задевает TCP/inbound/IPv6/соседние CIDR, и сохраняет QUIC/Discord/игровые пути.
- Нет расхождения kernel/profile snapshot при последующем редактировании исходного списка; fallback не теряет валидные нестандартные списки.
- Неответ ICMP/HTTP или Wi-Fi Direct не превращается в бесконечный запрет автосмены.
- Поздний отказ старого соединения после восстановления не меняет память; стабильная сеть продолжает учиться.
- Дублирующийся watcher не затирает marker; сбой/старение watcher автоматически снимает паузу, clock skew не продлевает её бесконечно.

## Task 1: Bounded UDP capture exclusions

Files: tools/capture.ps1, tools/lib.ps1, dev/tests/capturetest.ps1, dev/tests/capture-filter.py, dev/tests/check.ps1.

Interfaces: Get-CaptureExclusion(string[] Lines) returns null or Count/Cidrs/IpArgument/Filter; no I/O. New-BypassArgList reads bounded bundled list and applies both outputs together, otherwise keeps file reference.

- [x] RED: missing helper/kernel optimization; fallback, canonical bounds and actual native filter packet matrix.
- [x] GREEN: implement compiler and matched profile snapshot; native dry-run/filter helper tests.
- [x] Focused capturetest/check/profiletest/astlint; local integration with ledger.

## Task 2: Wi-Fi disruption learning guard

Files: tools/linkguard.ps1, tools/netwatch.ps1, tools/lib.ps1, lua/autoring.lua, dev/tests/linkguardtest.ps1, dev/tests/linkguardtest.lua, dev/tests/lua-unit.py, dev/tests/watchtest.ps1.

Interfaces: Get-WifiLinkObservation(TrackedIds=[]) produces Known/Interfaces(Id,Up,HasGateway), only routed Wi-Fi and retained tracked interfaces; Get-WifiWatchScope(State,Observation) scopes WLAN events; Get-WifiDisconnectEpoch(Ids,Now) reads only recent bounded local events; Get-WifiInterruptionState(State,Observation,EventEpoch,Now) pure reducer; Get-LinkGuardRecord(State,Now) produces bounded protocol1. Native Lua parser and cached generation/lease gate are opt-in via :link_guard=link-guard.txt on learning profiles only. Task1 shares only lib imports/input hash; no functional dependency.

- [x] RED: link transition/scoped event/unknown/expiry tests and real Lua detector integration.
- [x] GREEN: implement local observer/reducer/atomic publisher and connection tainting.
- [x] Focused tests, full offline suite, independent review; record skips and local integration.

## Verification ledger

Pre-flight: shared interfaces — lib.ps1 imports capture/linkguard and fingerprints both; Task2 leaves Task1 profile exclusion contract intact. Existing network-context protocol3 and legacy Lua calls remain compatible. Tests use TEMP package copies. Plan and ledger follow existing dev/plans convention; no separate workspace artifacts are needed outside ignored dist.

Task1 complete (base efec02d, local capture commit): RED missing compiler in dist/v2-capture-red.log; GREEN capturetest and80 actual native packet cases in dist/v2-capture-capturetest.log. check/profiletest/astlint exit0; command line26546 chars. Bundled engine exports complete before/after filters with --wf-save in --dry-run; WinDivert DLL compiles/evaluates them without opening the driver. First candidate used group negation rejected by the real filter parser; De Morgan field tests match the documented grammar and pass exact boundary/TCP/inbound/IPv6 matrix. Files, malformed/mixed/large fallback, and later source edits verified. No live traffic intercepted and no measured latency claim.

Task1 committed479c59a. Task2 base479c59a: RED missing reducer/parser in dist/v2-linkguard-red.log and v2-linkguard-lua-red.log. GREEN pure PS/event-XML tests plus real Lua detector integration; actual TEMP watcher loop publishes both markers from mocked observations. Duplicate watcher cannot overwrite either marker. Focused watchtest/watchluatest/contexttest/check/astlint exit0, CLI26624 chars. Native traffic interception and adapter disconnects were not performed.

Real read-only API check exposed21 Windows Wi-Fi interface records, mostly inactive/virtual; the first16-total-interface cap returned Unknown incorrectly. RED fixture with25 inactive virtual adapters plus Wi-Fi Direct captured it. Corrected observation retains routed Wi-Fi and explicitly tracked interfaces, with active scopes first; cap applies to relevant interfaces. dist/v2-linkguard-virtual-green.log passes; actual API then reports Known=true,1 relevant/scoped interface. No raw interface identities exported and no event log enabled. Observer query failure remains Unknown.

Final verification: dist/v2-stability-all.log, PS5.1 dev/tests/run-all.ps1 -Offline, exit0,41 groups,0 failed groups. Includes80 actual native packet-filter cases and developer Lua integration for generation/taint/expiry; native-admin Lua/store I/O/actual guard timer expiry remain explicit skips. No live Wi-Fi disruption, bypass restart, routing or adapter changes. In a separate3-call local observation sample, cold wall169ms and warm13–15ms; CPU counters are coarse, not a game benchmark. Existing5s watcher cadence retained.

Final independent read-only review of efec02d through current Task2 found no actionable findings or deferred minors. Checked real circular nocheck semantics, immutable capture exclusions, heartbeat bounds, event scope, old-connection tainting and private marker contents. git diff --check clean. Current engine/watcher processes are not hot-reloaded or restarted by this development phase; activation on a later controlled startup/update must account for already-running watcher versions. Changes retained locally in codex/v2, no v2 publication.

Sources inspected: [bol-van manual](https://github.com/bol-van/zapret2/blob/master/docs/manual.md), blob c5dd63257fde6eeda5dadb92c951f88ecc749e94; [WinDivert helpers](https://github.com/basil00/WinDivert/blob/master/doc/windivert.html), blob eab15d9fd0a8570dfbbd63fa4c4e4102f37ad6c8. Microsoft Windows administrative guidance identifies WLAN8003 as successful disconnection; tests use XML InterfaceGuid, never localized message text.
