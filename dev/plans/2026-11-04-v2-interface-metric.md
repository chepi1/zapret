# V2: учитывать метрику интерфейса в контексте сети

> Исполнение: superpowers:executing-plans, один небольшой этап RED → GREEN → проверка → read-only ревью → локальный коммит.

**Goal:** смена приоритета Wi-Fi/TUN при неизменных адресах и RouteMetric должна инвалидировать результаты подбора и подтверждение сетевой памяти.

**Architecture:** Get-NetworkObservation уже получает InterfaceMetric внутри Get-NetRoute. Включить её в канонический route-компонент network-v4 без дополнительных CIM-запросов. При недоступном/некорректном значении значимого маршрута возвращать существующий Unknown вместо доверенного неполного ключа. Служебные и собственные DHCP host routes остаются отфильтрованы до проверки.

**Tech Stack:** Windows PowerShell5.1, текущие NetTCPIP и .NET, без новых зависимостей.

**Основание:** tools/netstate.ps1 учитывает только RouteMetric. [Microsoft Get-NetRoute](https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netroute?view=windowsserver2022-ps) определяет приоритет сравнимых маршрутов суммой RouteMetric и InterfaceMetric. Read-only проверка на этой машине подтверждает настоящее свойство InterfaceMetric у route-объектов; адреса не сохранялись в отчёт.

**Границы:** автономное продолжение v2 по поручению пользователя. Только код/fixture-проверки в TEMP, без изменения маршрутов, адаптеров, текущего обхода и версии1.9; без публикации. Четыре личные untracked заметки не добавлять. Ключ остаётся непрозрачным; нет обещаний снижения игрового RTT.

## Этап

- [x] RED: расширить contexttest существующим fixture InterfaceMetric; отдельно проверить IPv4, IPv6 и split-TUN при том же RouteMetric; пользовательский и machine ключи, запрет применения старых измерений и инвалидирование heartbeat.
- [x] RED: недоступная/некорректная метрика → Unknown, ноль допустим, служебные и собственные host routes не влияют; порядок и канонический вид сохраняются.
- [x] GREEN: network-v4 и uint32-кодирование метрики каждого значимого маршрута.
- [x] Проверки: contexttest, watchtest, historytest, rankcontexttest, proxytest, netstatetest, healthtest, astlint/check; read-only настоящее PS5-наблюдение; независимое ревью.

Миграция: новый ключ несовместим с прежним неполным отпечатком. Существующие сравнения уже отвергают старый ключ без стирания истории/подсказок. Heartbeat требует два согласованных свежих наблюдения как прежде. Метрика IPv4/IPv6 берётся из каждого соответствующего route-объекта, дополнительного запроса Get-NetIPInterface нет.

## Проверки

- RED: contexttest exit1,14 проверок выявили неизменный ключ после смены метрики, ложное доверие недоступной метрике и принятие старых измерений (dist/v2-interface-metric-red.log).
- GREEN: contexttest exit0,38 проверок; дополнительно подтверждены канонический числовой вид, весь диапазон uint32 и независимость от порядка маршрутов (dist/v2-interface-metric-green.log).
- watchtest/historytest/rankcontexttest/proxytest/netstatetest/healthtest/astlint/check — восемь отдельных групп exit0 на TEMP-копиях. Повторять полный набор Lua/стратегий не требовалось: в этих путях изменений нет, check проверил штатные native dry-run конфигурации; CLI27087.
- Настоящее read-only наблюдение Windows PowerShell5.1.26100.9818: user/machine Known=true и Stable=true, scopes отличаются. InterfaceMetric — нативное CIM Property uint, а не ScriptProperty со скрытым запросом. В логах только логические результаты без адресов (dist/v2-interface-metric-native-observation.json).

Решение исполнителя: использовать существующее поле route-объекта, не добавляя отдельный запрос Get-NetIPInterface; наблюдение остаётся локальным и не меняет приоритет маршрутов само.

Независимое read-only ревью: открытых замечаний нет. Дополнительно40 проверок в памяти настоящего Windows PowerShell5.1.26100.9818 — exit0, включая Machine/IPv4/IPv6, недоступную метрику, canonical uint32 и разделение пространств ключей. BOM и git diff --check в порядке. Изменение сохраняется локально в codex/v2; ветка не публикуется.
