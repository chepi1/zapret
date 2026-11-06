# zapret 2.0

**YouTube, Discord and Telegram in one Windows package.** Built on bol-van's [zapret2](https://github.com/bol-van/zapret2), with [Flowseal strategies](https://github.com/Flowseal/zapret-discord-youtube), ISP-specific strategy selection and the official [TG WS Proxy](https://github.com/Flowseal/tg-ws-proxy). **The interface is in Russian.**

[Download](https://github.com/chepi1/zapret/releases/latest) · [Changelog](CHANGELOG.md) · [Russian documentation](README.md)

[![tests](https://github.com/chepi1/zapret/actions/workflows/tests.yml/badge.svg)](https://github.com/chepi1/zapret/actions/workflows/tests.yml)

YouTube and Discord traffic uses your direct ISP connection. Telegram has a separately enabled local proxy with WebSocket and CF/H2 fallback paths. Start `zapret.bat` to check your connection, run the bypass and select a strategy.

## Features

- **34 strategies**, including all 22 Flowseal 1.10.4 profiles ported to zapret2. Dedicated profiles for sites, video and Discord voice.
- **Strategy selection for your ISP.** Checks service availability, stalled transfers and effects on ordinary sites and Steam. Retries failed probes, explains the primary-strategy decision and uses compatible run history.
- **Per-server rotation.** Separate rings for sites, YouTube and Discord; successful alternatives are remembered across restarts. Games retain their standard ring.
- **Bundled Telegram support.** Official Flowseal TG WS Proxy v1.11.4, without installing Python. Tools → 8 manages it. Existing port/secret settings survive updates; private files stay in `runtime/tgws`.
- **Checked startup and recovery.** Configuration and the complete WinDivert filter are validated before stopping the current bypass. A failed replacement can trigger one checked attempt to restore the last confirmed configuration. Background changes are deferred while a game is open.
- **Wi-Fi and proxy context.** Detects Happ, system proxies, TUN, route and DNS state. Changed network/settings/files invalidate stale test results. Observed Wi-Fi interruptions suspend strategy learning.
- **Diagnostics.** Connection and service checks, a connection tracker, ISP testing and shareable reports. HTTPS timings and game-address measurements are kept separate.
- **Windows service and updates.** Optional startup service, scheduled tuning, SHA-256-checked updates, preserved personal settings/lists and journal-based recovery from interrupted updates.
- **Refreshed console.** Light pink and lilac accents, familiar actions 1–7, notifications on 8 and text that adapts to narrow windows.

Results depend on your ISP and strategy. Take-Two and Steam/Valve exclusions are preserved. Reduced game latency is not promised: routes, load and Wi-Fi still affect it.

## Quick start

1. Download `zapret-v2.0.zip` from [Releases](https://github.com/chepi1/zapret/releases/latest) and unpack it to a simple path, e.g. `C:\zapret`.
2. Fully quit VPNs, proxy clients and game boosters before selecting a strategy.
3. Run `zapret.bat` (asks for administrator rights): **5** — connection check, **1** — start, **3** — strategy test.
4. **6 → 6** installs the Windows startup service. **7 → 8** manages Telegram support.
5. For an existing installation, **6 → 9** updates from GitHub and preserves personal state.

If a driver or executable is blocked, inspect your antivirus history and the startup error. Tools → 4 creates a report for troubleshooting.

## Components and privacy

- Core: official zapret2 v1.0.6. Telegram: official Flowseal TG WS Proxy v1.11.4. Bundled binaries are SHA-256-pinned; see [CHECKSUMS.txt](CHECKSUMS.txt) and [third-party notices](THIRD-PARTY-NOTICES.md).
- Code directories are protected for Administrators and SYSTEM. The package does not install root certificates.
- Service requests include ISP lookup, GitHub updates/lists, diagnostic DNS and test targets. The optional Telegram component connects through its upstream Telegram/CF/H2 paths.
- Settings and logs stay in `runtime`. Shareable reports mask the final part of your public IP, Windows username and Telegram proxy secrets. Detailed native logs and the learned host list require separate consent.
- Developer strategy tests use isolated input snapshots and private learning state. Network/settings/source changes reject application of the result. CPU/memory comparisons and HTTPS timings do not measure game RTT.

## Contact and licenses

Contact: Telegram [@chepi1](https://t.me/chepi1), Discord `chepi228`. For a bug, attach a report from Tools → 4 or the ISP check from Tools → 3.

Project code, zapret2 and Flowseal components use MIT; WinDivert and Cygwin use LGPL. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
