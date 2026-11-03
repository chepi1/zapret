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

Interfaces: Get-WifiLinkObservation() produces Known/Interfaces(Id,Up,HasGateway); Get-WifiWatchScope(State,Observation) scopes WLAN events; Get-WifiDisconnectEpoch(Ids,Now) reads only recent bounded local events; Get-WifiInterruptionState(State,Observation,EventEpoch,Now) pure reducer; Get-LinkGuardRecord(State,Now) produces bounded protocol1. Native Lua parser and cached generation/lease gate are opt-in via :link_guard=link-guard.txt on learning profiles only. Task1 shares only lib imports/input hash; no functional dependency.

- [ ] RED: link transition/scoped event/unknown/expiry tests and real Lua detector integration.
- [ ] GREEN: implement local observer/reducer/atomic publisher and connection tainting.
- [ ] Focused tests, full offline suite, independent review; record skips and local integration.

## Verification ledger

Pre-flight: shared interfaces — lib.ps1 imports capture/linkguard and fingerprints both; Task2 leaves Task1 profile exclusion contract intact. Existing network-context protocol3 and legacy Lua calls remain compatible. Tests use TEMP package copies. Plan and ledger follow existing dev/plans convention; no separate workspace artifacts are needed outside ignored dist.

Task1 complete (base efec02d, local capture commit): RED missing compiler in dist/v2-capture-red.log; GREEN capturetest and80 actual native packet cases in dist/v2-capture-capturetest.log. check/profiletest/astlint exit0; command line26546 chars. Bundled engine exports complete before/after filters with --wf-save in --dry-run; WinDivert DLL compiles/evaluates them without opening the driver. First candidate used group negation rejected by the real filter parser; De Morgan field tests match the documented grammar and pass exact boundary/TCP/inbound/IPv6 matrix. Files, malformed/mixed/large fallback, and later source edits verified. No live traffic intercepted and no measured latency claim.

Sources inspected: [bol-van manual](https://github.com/bol-van/zapret2/blob/master/docs/manual.md), blob c5dd63257fde6eeda5dadb92c951f88ecc749e94; [WinDivert helpers](https://github.com/basil00/WinDivert/blob/master/doc/windivert.html), blob eab15d9fd0a8570dfbbd63fa4c4e4102f37ad6c8. Microsoft Windows administrative guidance identifies WLAN8003 as successful disconnection; tests use XML InterfaceGuid, never localized message text.
