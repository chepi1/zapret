# Contextual ring memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** убрать сериализацию и запись файлов из детектора пакетов современной конфигурации, ограничить возраст и размер подсказок.

**Architecture:** `lua/ring-store.lua` управляет LRU, TTL и общим таймером сохранения; `autoring.lua` отвечает за сеть и решения детекторов. Старый CLI без context сохраняет совместимость. Пакетный путь меняет только RAM и ставит таймер. Один callback публикует не более одного снимка; сеть/состав перепроверяются перед записью.

**Tech Stack:** bundled Lua/zapret2 timer API, PS5.1 с BOM, dev-only lupa для локальной синтетики. Новых пользовательских зависимостей нет.

**Spec:** `dev/research/2026-11-03-v2-review.md`, P1: контекстная TTL/LRU память, ограниченная атомарная запись; основной план `dev/plans/2026-11-03-v2.md`.

## Global Constraints

- Официальные бинарники, версия1.9 и опубликованный ZIP не меняются. Изменения остаются в codex/v2.
- Не перехватывать живой трафик, не менять службы, задачи, Wi-Fi/Happ и сетевые настройки.
- Без свежего network+composition разрешены RAM и обычная адаптация, но не запись на диск.
- При потере последних несохранённых подсказок после hard kill следующий запуск адаптируется заново; это кэш, не настройки.
- Не выдавать синтетические времена за игровой пинг или доказательство ускорения WinDivert.

## Decisions

Ruling: пользователь многократно поручил делать v2 самостоятельно и пропустить ожидание вопросов. Для этого этапа выбираю существующие Lua/PS5.1 и совместимость старого CLI; отдельного решения пользователя не требуется.

Ruling: guarded memory format `# ring-store-v2`, затем key/index/confirmed-epoch/used-epoch. TTL30суток с последнего подтверждения; будущие времена не доверяются. До2000 записей в RAM и256КБ на диске, сохраняются самые свежие по LRU. Неизвестный формат guarded-файла не перезаписывается. Изменение Lua уже меняет composition filename, поэтому старая память не притворяется свежей. Старый CLI без context остаётся на прежнем пути; цена — два явно различимых режима для совместимости.

Ruling: первый dirty change ждёт5секунд, последующие изменения не отодвигают deadline. Общий таймер1с записывает не более одного готового круга за callback. Ошибка записи/rename даёт30с backoff; отсутствие timer API оставляет RAM. Задержка сохранения и возможная потеря последних подсказок — цена отсутствия дискового I/O в детекторе.

## Review Focus

- Сеть/состав изменились после обучения, но до timer: отложенная запись не выполняется.
- Full cache: вытесняется только LRU, новые записи не стирают все удачные подсказки.
- Expired/future/invalid/oversized state: не становится достоверной подсказкой; неизвестный формат сохраняется без перезаписи.
- Rename/write/timer отказывает: старый файл сохраняется, RAM работает, retry ограничен; timer callback не бросает наружу.
- Изменения идут непрерывно: сохранение не откладывается бесконечно и не делает burst из всех кругов в одном callback.

### Task 1: Store and integration

- [x] Добавить failing Lua fixtures для отсутствия синхронной записи, batching, двух dirty кругов, TTL/LRU, лимита байт, ошибок и потери контекста. Запустить, Expected: FAIL на отсутствии ring_store.
- [x] Реализовать `ring_store.new(options)`, `store:get(key)`, `store:put(key,index)`; options содержат file/validate, опциональные меньшие лимиты для fixture. Нативный timer callback и atomic temp+rename выполняются отдельно от packet path.
- [x] Подключить helper перед autoring во всех owning launchers/tests. Современный guarded ring_mem использует store; перед flush force-read watchdog. Старые соединения и preview по-прежнему не записывают память.
- [x] Снять детерминированную синтетику до/после с одинаковыми событиями, сохранить workload/counts/CPU. Expected: при burst обучения новый packet path не пишет файл; timer делает один снимок, сохраняя тот же выбор стратегии. Нагрузка детерминированна, случайного seed нет.
- [x] Прогнать новые Lua fixtures, profile/dry-run, astlint/check и полный offline suite. Native admin skip обозначить явно.
- [x] Один независимый read-only review этапа; исправления Important red→green. Ledger результата и отдельный локальный коммит, без публикации.

Pre-flight: единственные общие интерфейсы — Lua init list (builder + native/dev tests) и свежесть watchdog (autoring). SourceHash уже включает все Lua. Guarded native fixtures должны использовать новый формат и управляемые таймеры; legacy native luatest сохраняет прежние проверки.

## Execution ledger

Task 1: complete, BASE29ecff4. Новые store unit27 и интеграционные watch26 проходят в lupa2.6/Lua5.4. Red→green: модуль отсутствовал (v2-ring-store-red.log), прежний detector писал синхронно (v2-ring-integration-red.log), неполный temp заменял старый снимок (v2-ring-partial-red.log). Добавлены проверка прочитанного temp и атомарный rename. Все пути работают с виртуальными FS/пакетами в unit, физический перехват не запускался.

Final review: один отдельный read-only reviewer, P2 — timer_set повторялся при каждом изменении после отказа. Исправлено общим30с cooldown, red→green v2-ring-review-red.log / v2-ring-review-storeluatest-green.log. Собственная регрессия выявила накопление obsolete stores и задержку активного снимка: store:discard() убирает сильную ссылку из pending при смене revision, red→green v2-ring-cancel-red.log / v2-ring-review-watchluatest-green.log. Непрерывное обучение не передвигает первый deadline. Повторного reviewer не запускали: fix pass подтверждён fixtures и общим suite.

Ruling: сетевой snapshot уже обновляется не реже1с при активных пакетах; epoch переиспользуется для TTL/LRU вместо дополнительных os.time на каждом подтверждении. Timer перед сохранением force-read обновляет и epoch, и сеть/состав. Цена — гранулярность TTL до1с, не изменение30д срока. Регрессия из1000 подтверждений сначала показала повторные чтения часов, затем прошла: v2-ring-clock-red.log и -watchluatest-green.log.

Сверена совместимость штатного API по pinned zapret2v1.0.6: [nfq2/lua.c](https://github.com/bol-van/zapret2/blob/v1.0.6/nfq2/lua.c), Git blob61e4027949b145b185a9098b23a02a40b9803b72; [nfq2/timer.c](https://github.com/bol-van/zapret2/blob/v1.0.6/nfq2/timer.c), blobe2940a8bdf50fd3516e6850283c3c2b0352e5471. Поддерживается callback-функция и повторная постановка одноимённого oneshot внутри callback. Это чтение owning source, не выполненный native I/O тест.

Результат dev/memorybench.py — dist/v2-ring-memory-bench.json, исходники с SHA256, baseline29ecff4, 7 повторов.1000 обученных хостов: baseline1000 виртуальных writefile, current0 во время обучения/1 после таймера; сохранены все1000 выборов стратегии. Медиана burst wall74.746→9.026мс, фоновой публикации0.261→0.853мс.10000 повторных подтверждений28.666→32.731мс: горячий путь этой модели немного дороже. Прирост Lua heap после GC109.8→374.7КиБ — метаданные стоят дополнительно~265КиБ/1000 записей. CPU-time в JSON дискретный; ноль не означает отсутствие работы. Это синтетика без физического диска/сети, не скорость WinDivert и не игровой пинг. Ruling: принимаю небольшой расход RAM/повторного доступа ради TTL/LRU и удаления синхронных полных перезаписей; живые целевые нагрузки всё ещё обязательны перед stable.

Итоговый общий прогон после всех product changes: dist/v2-ring-store-verified-all.log exit0, 28 offline-групп, native dry-run34 стратегий и mixed ring проходят. Native luatest, реальный lifetime timeout и новый storeiotest с настоящим event-loop/rename локально пропущены без elevated token. Storeiotest добавлен в admin-ветку с --wf-raw=false и ограниченным15с процессом, для CI/приёмки. Никакие реальные службы/задачи/сеть не менялись. Релиз не собирался/не публиковался; оставшиеся v2 этапы — целостный snapshot, семантика всех22 импортов, Wi-Fi A/B и игровые/сон/сервисные прогоны.
