# V2 probe reliability fix plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline with TDD.

**Goal:** не выбирать стратегию на основании незавершённой передачи и изолировать прямые curl-пробы от пользовательского curlrc.

**Architecture:** единый чистый Get-ProbeTransferState в selection.ps1 используется основным тестом и лабораторией. OK требует exit0 и HTTP-код; timeout с прогрессом — FREEZE, другие ошибки передачи — FAIL, DNS6 — NA. Прямые измерительные вызовы получают -q первым аргументом. Службы/стратегии/маршруты и работающий обход агент не меняет.

**Tech Stack:** PS5.1, штатный curl; тесты actual loopback без WinDivert, BOM.

**Spec:** наблюдаемый дефект пользовательского runtime/test-attempts-20261103-194317-bf236403.jsonl + dev/plans/2026-11-03-v2.md доказательный выбор.

## Evidence and decisions

- В существующем журнале7 запросов с HTTP200/206/404 и curl28 получили StateOK (Discord, SoundCloud,2K,Clean,Oracle). Наличие HTTP-заголовка не доказывает завершённость запрошенной передачи. В test.ps1 и strategylab.ps1 ветка code!=000 стоит перед timeout/error.
- Ruling: HTTP403/404 с завершившейся передачей по-прежнему допустимы как HTTPS reachability; статус сайта не становится требованием200. Ненулевой exit не OK, включая18/23/28/56/63 и принудительную отмену. Нет вывода о причине DPI/Wi-Fi по одному timeout.
- Timeout с Down>0 — FREEZE для GET/POST; POST с Up>0/Down0 — FREEZE; timeout без прогресса — FAIL. Missing exit не0. Лаборатория использует ту же классификацию и переводит её в прежние +/F/H/5/cN.
- Изоляция -q только у прямых проб/DoH/геодиагностики/DPI suite и лаборатории, которые уже используют --noproxy. Обновления/скачивание релиза через пользовательский proxy не менять.
- Агент не запускает живой тест, службы или адаптеры. Только TEMP копии, loopback/fixtures, локальный codex/v2 коммит.

## Review focus

- Заголовок200 перед частичным телом и timeout/close не становится OK/баллом/подтверждением final replay.
- Завершённый403/404 и HEAD с Content-Length без тела не становятся ложным отказом.
- DNS/unknown exit не дают успешного нулевого состояния; успешный retry сохраняет полбалла.
- Curlrc не добавляет заголовки/URLs/перенаправления в прямые пробы; пользовательский файл не изменяется.

### Task1: Shared classification and isolated direct requests

Files: tools/selection.ps1, tools/test.ps1, tools/lib.ps1, dev/strategylab.ps1; dev/tests/curlresulttest.ps1 and curlfailuretest.ps1.

- [x] RED literal parser/score/final/lab cases and actual truncated/stalled loopback200, completed404, curlrc header isolation.
- [x] GREEN shared classifier and -q; preserve normal/retry/final contracts.
- [x] Focused checks and complete offline suite; independent review and ledger for local integration.

## Verification / review ledger

- RED before implementation: dist/v2-probe-result-red.log and dist/v2-probe-loopback-red.log reproduce the false-success and curlrc inheritance failures. GREEN: curlresulttest21 assertions and curlfailuretest10 assertions, including real system curl18/28 against a local HTTP fixture. Temporary CURL_HOME baseline proves the test config was active; finally restores the process environment.
- Full PS5.1 run: dev/tests/run-all.ps1 -Offline, dist/v2-probe-reliability-all.log, exit0,39 groups,0 failed groups. All checks use a TEMP package copy. Native-admin Lua/store I/O/actual timer expiry remain explicit skips; no live bypass, service, task or adapter changes.
- Independent read-only review of the diff against b2b9369 found no actionable issues. First-argument -q isolation, shared classification, retry/score/final paths and BOM checked. git diff --check clean.
- Ruling retained: completed403/404 remain valid transport reachability. Cost if wrong: this criterion alone cannot detect application-level denial; service functionality needs its own probe rather than requiring200 universally.
- Local codex/v2 integration only. Version, strategies, download limits, parallelism and running runtime are unchanged by this phase. These checks establish truthful probe classification, not a measured CPU, throughput or game-latency gain.

## Research pointers / scope

Primary [curl errors](https://curl.se/libcurl/c/libcurl-errors.html):18 partial transfer,28 timeout,0 successful operation. [curl -q](https://curl.se/docs/manpage.html#-q) must be first to ignore default curlrc. bol-van current blockcheck2.sh read through GitHub connector on2026-11-04, blob90a821591234cd65f4737e4da66a67bd0d1cb5ad: curl_test propagates curl exit status; CURL_PAD combines request padding with HEAD. No upstream script executed and no binary replaced.

Further optimization candidates found:190 response bodies exceed requested64KiB range, largest1025634 bytes, summed55425166 bytes. A hard download cap needs separate semantics: max-filesize may reject on Content-Length before downloading, and unknown-size limiting differs before curl8.4.0. Do not silently turn that into a passed64KiB test. Lower fake-repeat budget and adaptive shortlist/pacing require comparable live evidence, not guessed production defaults.
