# V2: проверять полный фильтр до остановки обхода

> Исполнение inline через superpowers:executing-plans: RED → GREEN → целевые проверки → независимое read-only ревью → локальный коммит.

**Goal:** неверный raw/собранный WinDivert фильтр не должен разрешать остановку работающего обхода или замену службы.

**Основание:** при исправлении пункта1 настоящий v1.0.6 admin --dry-run принял неизвестное поле raw filter и вернул0. В [nfqws.c v1.0.6](https://github.com/bol-van/zapret2/blob/v1.0.6/nfq2/nfqws.c) выход bDry происходит до WinDivertOpen. Там же --wf-save сохраняет полное сформированное выражение и выходит до duplicate mutex/перехвата; проверка списков и параметров уже выполнена.

**Architecture:** Test-ConfigDry экспортирует ровно свой candidate через временный nonce wf-save и затем вызывает WinDivertHelperCompileFilter на NETWORK layer. Native helper получает исходные байты без снятия BOM/перекодирования, object=NULL/objLen0 и не открывает драйвер. Собственная C#5 обёртка tools/filtercheck.cs загружается один раз; каждый вызов явно использует DLL данного пакета, безопасные LoadLibraryEx search flags, копирует ошибку до FreeLibrary и освобождает buffer/module в finally. Отдельный Test-CaptureFilter в capture.ps1 возвращает Ok/Output/Position. Ошибка CLI, timeout, отсутствующий/пустой экспорт, ошибка загрузки DLL/компилятора закрывают preflight. Временный файл удаляется в finally. Код C# входит в composition fingerprint и штатный ZIP.

API: [официальный header WinDivert2.2.2](https://github.com/basil00/WinDivert/blob/v2.2.2/include/windivert.h), [документация](https://github.com/basil00/WinDivert/blob/v2.2.2/doc/windivert.html). Добавляются только функции существующей DLL, не бинарники/зависимости. Для x64 DLL launcher должен однозначно выбирать Windows PowerShell x64, включая вызов из WoW64.

**Границы:** PS5.1/C#5, UTF8 BOM для PS; защита duplicate mutex отключена только у проверки, live candidate неизменяем. Без реальной остановки службы, перехвата, настройки Wi-Fi и публикации. Не обещать исправление driver-busy/античита или снижение RTT. Это проверка текущего candidate, не согласованный immutable snapshot всех внешних файлов после проверки. Четыре личные untracked заметки не трогать.

- [x] RED: реальный Test-ConfigDry принимает плохой raw filter; реальный Start-BypassCore на таком candidate доходит до stop spy. Проверить валидный фильтр и cleanup.
- [x] GREEN: native compiler wrapper, export/cleanup и ошибка до stop; fingerprint C# и надёжный x64 launcher.
- [x] Проверить NULL/empty/NUL, повреждённый/недоступный DLL, native syntax error/position, missing export/timeout, сохранение live-флагов и границы командной строки.
- [x] filtertest/restarttest/starttest/check/capturetest/drystrat/astlint/smoke и полный offline при интеграции; read-only ревью.

## Результат

Начальный RED3 отказа; отдельный BOM RED2 отказа после замечания ревью. Исправлена проверка исходных байтов. Независимое PS5-ревью подтвердило5/5 native byte cases: valid/BOM/NUL/invalid byte/empty, ABI/lifetime и порядок экспорта; открытых замечаний нет. Root filtertest покрывает также stop-spy, cleanup, x64 выбор из System32/SysWOW64, missing export/timeout и fingerprint.

Полный финальный run-all -Offline:49 групп, exit0, dist/v2-filter-preflight-final-all.log. Первый прогон остановился только на старом smoke-fixture, который видел реальный EasyAntiCheat_EOS; fixture изолирован scoped Get-RunningGames без изменения production policy. Native admin-only Lua/store/timer paths пропущены как раньше; helper WinDivert и PowerShell fixtures реально исполнены без драйвера. git diff --check чистый. Действующий обход/служба/адаптеры не перезапускались. Локальное сохранение, без публикации.
