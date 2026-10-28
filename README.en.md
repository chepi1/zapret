# zapret

[![tests](https://github.com/chepi1/zapret/actions/workflows/tests.yml/badge.svg)](https://github.com/chepi1/zapret/actions/workflows/tests.yml)

DPI bypass for **NBA 2K27**, **Discord** and **YouTube** on Windows, for Russian ISPs. Built on bol-van's [zapret2](https://github.com/bol-van/zapret2) (winws2) with all strategies of [Flowseal zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) ported to zapret2. **The interface is in Russian.**

It is not a VPN or a proxy: traffic goes directly from your IP, the bypass only injects a few fake packets at the start of connections, so in-game ping stays the same.

## Why

Many Russian ISPs freeze connections to foreign hosting (AWS, Cloudflare, Hetzner and others) after the first 16–20 KB. NBA 2K game servers and Easy Anti-Cheat live there: the game lets you into the City but kicks you out of matches. Discord and YouTube are blocked separately. One bypass covers all of it.

## Features

- 27 strategies: all 22 Flowseal strategies, 3 from bol-van's docs, 2 "soft" variants that don't break Akamai sites.
- **Autotest** picks the best strategy for your ISP: it checks the 16–20 KB freeze on 36 hosting providers, Discord, YouTube, SoundCloud, 2K and EAC servers, and **harm** — whether ordinary unblocked sites (and Steam) stop working. Score = passed − harm.
- Per-server strategy rotation (`circular`), with separate rings for sites, YouTube, Discord and games.
- 2K's own servers (Take-Two) are never touched: desync there breaks Easy Anti-Cheat.
- Tools: match tracker, game address scanner, ISP check report, one-file report, diagnostics, excluding a game from the bypass by the tracker log, "direct" routing rules for proxy clients (Happ etc.).
- Checks the PC for VPN, proxies, game boosters (ExitLag…), another bypass, broken IPv6, Flowseal hosts entries; warns when Steam or Discord got stuck on a proxy that was turned off.
- Scheduled autotune, list updates, Windows notifications, in-menu update from GitHub releases (SHA-256 verified).

## Quick start

1. Download the archive from [Releases](https://github.com/chepi1/zapret/releases) and unpack it to a simple path, e.g. `C:\zapret`.
2. Add the folder to your antivirus exclusions (`WinDivert64.sys` is a packet capture driver, often a false positive).
3. Fully quit VPNs, proxy clients and game boosters.
4. Run `zapret.bat` (asks for admin rights), then: **5** — PC check, **1** — start, **3** — autotest.
5. **6 → 6** installs the service to start with Windows.

## Security and privacy

- zapret2 files are verified against the official release SHA-256 before every start; code folders are locked to Administrators and SYSTEM.
- No telemetry. Network requests (HTTPS only): ipwho.is / ipinfo.io (ISP and country), GitHub (Flowseal lists, new versions, updates), web.telegram.org (when the Telegram bridge is on), hyperion-cs.github.io (test hosting set), the autotest targets.
- Reports hide the last octet of your IP and your Windows user name.

## License

MIT for this project's code. zapret2 © bol-van (MIT), Flowseal strategies and lists (MIT), WinDivert and Cygwin (LGPL) — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Contact: Telegram [@chepi1](https://t.me/chepi1), Discord `chepi228`.
