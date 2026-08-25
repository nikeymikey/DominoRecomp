# No One Can Stop Mr. Domino — Recompiled

<!-- retcomm-readme-metrics -->
[![GitHub downloads (all assets, all releases)](https://img.shields.io/github/downloads/TechnicallyComputers/DominoRecomp/total)](https://github.com/TechnicallyComputers/DominoRecomp/releases)
[![GitHub downloads (latest release)](https://img.shields.io/github/downloads/TechnicallyComputers/DominoRecomp/latest/total)](https://github.com/TechnicallyComputers/DominoRecomp/releases/latest)
[![GitHub release](https://img.shields.io/github/v/release/TechnicallyComputers/DominoRecomp)](https://github.com/TechnicallyComputers/DominoRecomp/releases/latest)
<!-- /retcomm-readme-metrics -->

Static recompilation of **No One Can Stop Mr. Domino** (USA, `SLUS-00804`) built on
[psxrecomp](https://github.com/mstan/psxrecomp) and
[recomp-ui](https://github.com/mstan/recomp-ui).

Static recompilation of No One Can Stop Mr. Domino (USA) via PSXRecomp

| | |
|---|---|
| Serial | SLUS-00804 |
| Players | 2 |
| Region | NTSC-U |
| Publisher | Acclaim Entertainment |
| Year | 1998 |

Scaffolded with the New Project Layout. See
`psxrecomp/docs/GAME_PROJECT_SETUP.md` for the full flow.

<!-- retcomm-readme-launcher -->
## RetComM Launcher

You can run this title **standalone** (release zip + the built-in recomp-ui
Generate & Build flow), or manage installs, updates, ROM/BIOS wiring, and queued
builds more intuitively with
**[RetComM Launcher](https://github.com/TechnicallyComputers/RetComM-Launcher)** —
the Retro Compilation Manager hub for self-compiling recomps.

[Downloads](https://github.com/TechnicallyComputers/RetComM-Launcher/releases) ·
[Full README & features](https://github.com/TechnicallyComputers/RetComM-Launcher#readme)

<p align="center">
  <img src="https://raw.githubusercontent.com/TechnicallyComputers/RetComM-Launcher/main/docs/screenshots/hub-and-game-launcher.png" alt="RetComM hub with a background build, next to a title’s recomp-ui launcher" width="720">
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/TechnicallyComputers/RetComM-Launcher/main/docs/screenshots/queue-and-background-build.png" alt="Background cmake build with titles queued" width="720">
</p>

RetComM checks for updates, rebuilds with existing build data when possible,
shares the portable toolchain used by per-title launchers, and automates
BIOS/ROM/save plumbing so you are not stuck repeating each game’s wizard by hand.
<!-- /retcomm-readme-launcher -->

## Legal

You must own the original game. Disc images under `disc/` are gitignored and
must never be committed. Retail BIOS dumps are not redistributed; OpenBIOS is
used for Generate unless you supply your own SCPH locally.

Default app icon: `assets/psxrecomp.ico` (and `.png` / `.svg`) — RetComM-themed controller mark from `psxrecomp/assets/`. Windows builds embed it via `APP_ICON`.

Optional box art under `launcher_assets/img/` may come from
[libretro-thumbnails](https://github.com/libretro-thumbnails/libretro-thumbnails)
(`Named_Boxarts`); see `BOXART_SOURCE.txt` when present.

## Quick start (Windows / MSVC)

Prerequisites on `PATH`: **CMake 3.20+**, **Python 3**, **Git**, and ideally
**Ninja** (`winget install Ninja-build.Ninja`) — the emitter build prefers it.
Run from a **x64 Native Tools Command Prompt for VS 2022** so CMake finds MSVC.

```powershell
cd C:\psxrecomp_projects\DominoRecomp
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
```

That wrapper does submodule sync → `psxrecomp_cli.py generate` (which builds the
emitters itself if they are missing) → `psxrecomp_cli.py rebuild`, and prints the
path to `Domino_Recompiled.exe`.

> **The runtime is built with clang, not MSVC.** psxrecomp's runtime sources use
> GNU C extensions — designated-initializer ranges (`[0 ... N] =`) in `sio.c`,
> `__attribute__` in `mdec.c` — which `cl.exe` cannot parse (C2059/C2143/C2146).
> Step 3 therefore uses the portable **cmake-clang-v1** pack that the CLI fetches
> automatically, the same toolchain upstream CI and RetComM use. MSVC is still
> needed for step 2's emitter build (C++20, no GNU extensions).

Useful flags:

| Flag | Effect |
|------|--------|
| `-Bios C:\path\SCPH1001.BIN` | Generate the retail BIOS backend too (otherwise bundled OpenBIOS) |
| `-Disc C:\path\game.cue` | Override the disc path from `game.toml` |
| `-Config RelWithDebInfo` | Optimized build with symbols (never use Debug) |
| `-SkipGenerate` | Rebuild only, when `generated/` is already current |
| `-KeepGoing 10` | Pass `-k 10` to Ninja so one run surfaces many errors |
| `-Clean` | Wipe `build-release` first |
| `-Msvc` | Force cl.exe (unsupported; expected to fail) |

Equivalent by hand:

```powershell
git submodule update --init --recursive
python psxrecomp\psxrecomp_cli.py generate --config game.toml --project-root .
python psxrecomp\psxrecomp_cli.py ensure-toolchain --project-root .
python psxrecomp\psxrecomp_cli.py rebuild --config game.toml --project-root . `
  --build-dir build-release --target psx-runtime --exe-basename Domino_Recompiled --no-pgo
```

`game.toml` points at the disc by **relative** path
(`..\No One Can Stop Mr. Domino (USA)\...cue`), so the dump stays outside this
repo and is never committed.

## Quick start (dev)

```bash
git submodule update --init --recursive
./psxrecomp/tools/ci/build_emitters.sh
python3 psxrecomp/psxrecomp_cli.py generate \
  --config game.toml --project-root . --disc disc/<your>.cue
cmake -S . -B build-release -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-release --target psx-runtime
```

Zip prefix for CI artifacts: `domino`.

## Symbols

Progressive map: `symbols.toml` → `python3 tools/sync_symbols.py` →
`psx_symbols.h` (`PSX_FN_*`). See `psxrecomp/docs/SYMBOLS.md`.

## Framework pins

Submodule gitlinks (`psxrecomp`, optional `recomp-ui`, nested `recomp-net`)
are authoritative. `framework_pins.txt` is an optional scaffold snapshot;
release CI logs SHAs with `record_pins.sh` but builds whatever the gitlinks
resolve to. Bump submodules deliberately — do not float on `main`/`master`
in release CI.

<!-- retcomm-readme-raid -->
---

<p align="center">
  <sub><b>R.A.I.D. — Retro AI Development</b> · a Discord for AI-assisted retro reverse-engineering, decomp &amp; recomp</sub>
</p>

<p align="center">
  <a href="https://discord.gg/Ad9BwSzctP"><img src=".github/raid-discord.png" alt="Join the Retro AI Development (R.A.I.D.) Discord" width="200"></a>
</p>
<!-- /retcomm-readme-raid -->
