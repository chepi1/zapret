# Сторонние компоненты

В сборку входят файлы других проектов без изменений. У каждого своя лицензия.

| Файлы | Проект | Лицензия |
|---|---|---|
| `bin\winws2.exe`, `lua\zapret-lib.lua`, `lua\zapret-antidpi.lua`, `lua\zapret-auto.lua`, `windivert\quic_initial_ietf.txt` | [zapret2](https://github.com/bol-van/zapret2) v1.0.6 © bol-van | MIT — [LICENSE-zapret2.txt](LICENSE-zapret2.txt) |
| `bin\WinDivert.dll`, `bin\WinDivert64.sys` | [WinDivert](https://github.com/basil00/WinDivert) © basil00, из релиза zapret2 v1.0.6 | LGPL-3.0 или GPL-2.0 на выбор |
| `bin\cygwin1.dll` | [Cygwin](https://cygwin.com) 3.4.10, из релиза zapret2 v1.0.6 | LGPL-3.0 (исходники — cygwin.com) |
| `fake\*.bin`, `lists\list-general.txt`, `lists\list-google.txt`, `lists\list-exclude.txt`, `lists\ipset-all.txt`, `lists\ipset-exclude.txt`, `lists\hosts-flowseal.txt` | [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) 1.10.4 © Flowseal | MIT — [LICENSE-flowseal.txt](LICENSE-flowseal.txt) |
| `tools\dpi-suite.json` | [dpi-checkers](https://github.com/hyperion-cs/dpi-checkers) © hyperion-cs | Apache-2.0 |

`strategies\*.txt` — стратегии Flowseal и примеры из документации zapret2, переведённые в формат этой сборки.

По кнопке (Инструменты → 8) сборка скачивает [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) © Flowseal (MIT) с его страницы релизов в `runtime\tg-ws-proxy`. В архиве и репозитории его нет.

SHA-256 файлов zapret2 — в [CHECKSUMS.txt](CHECKSUMS.txt): их можно сверить с официальным релизом zapret2.

Внешние сервисы, к которым обращаются скрипты, все по HTTPS:
- **ipwho.is**, запасной **ipinfo.io** — провайдер и страна при проверке подключения, где находятся серверы в трекере;
- **GitHub** — свежие списки Flowseal и номера новых версий;
- **hyperion-cs.github.io** — актуальный набор хостингов для проверки 16–20 КБ.
