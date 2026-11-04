# V2: восстановить перезапуск из пункта1

Пользователь: пункт1 сообщает о работе, но не перезапускает обход. control-actions.log: start→не запущен, без stop; старый движок работает с12:24. Реальный сохранённый candidate на admin --dry-run возвращает1 и «A copy of winws2 is already running with the same filter». Обычная проверка без elevation сначала упиралась в обязательную low-integrity подготовку writable; это отдельное ограничение прав тестового процесса, не причина отказа меню.

Источник: официальный zapret2 v1.0.6 [nfq2/nfqws.c](https://github.com/bol-van/zapret2/blob/v1.0.6/nfq2/nfqws.c): duplicate mutex проверяется до ветки bDry. Штатный --wf-dup-check=0 отключает только этот mutex, сохраняя формирование исходного фильтра и обычную проверку параметров. Runtime запуск по-прежнему использует исходный candidate с защитой от дубликата.

Вторая причина ложного впечатления: Start-WithChecks подавляет результат Start-Bypass и независимо запускает Start-TelegramWithBypass, который пишет «Telegram: мост работает» даже после отказа запуска обхода.

## Исправление

- [x] RED: restarttest воспроизводит mutex collision в preflight и ложный успех моста через настоящий Invoke-MenuAction start на fixture.
- [x] GREEN: New-BypassArgList -DryRun включает wf-dup-check=0; Test-ConfigDry с готовым CmdLine добавляет этот флаг в конец только проверочного вызова. Start-WithChecks запускает мост лишь после успешного Start-Bypass.
- [x] Проверки: restarttest/starttest/check/drystrat/smoke; фактический admin preflight существующего фильтра проходит с сохранением PID старого процесса; неверная опция по-прежнему отклоняется. Read-only ревью.

Не менять ACL папок по первоначальной не-elevated ошибке. Не менять настройки, стратегии, игру/службу или драйвер ради проверки; реальное подтверждение выполнять только --dry-run. Уже открытое меню хранит прежние функции, поэтому для применения исправления понадобится заново открыть zapret.bat.

Уточнение проверки: native --dry-run сам по себе не является полной проверкой синтаксиса произвольного raw WinDivert выражения; этот контракт не расширяется данным исправлением. Проверяется обычное отклонение неверных CLI-параметров; генератор фильтров имеет отдельную native helper-матрицу capturetest.

RED:6 отказов (dist/v2-restart-red.log). GREEN:10 проверок, включая повтор после silent native exit, сохранение live duplicate guard и защиту во время игры. restarttest/starttest/check/drystrat/smoke/astlint/coordinatortest —7 групп exit0 на TEMP. Реальный admin Test-ConfigDry сохранённого current candidate теперь Ok=true; неверная CLI-опция отвергнута. PID36464 и StartTime действующего процесса сохранены (dist/v2-start-admin-result.json). Настоящая остановка/перезапуск службы при проверке не выполнялись.

Независимое read-only ревью: замечаний нет; подтверждены отсутствие flag leakage в live-команде, последняя позиция dry-only флага, прежняя защита игры и обе ветки меню. Parse/BOM/diff проверки в порядке. Исправление сохраняется локально в codex/v2; старое окно меню требуется открыть заново.
