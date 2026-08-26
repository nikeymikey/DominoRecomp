# No One Can Stop Mr. Domino — Recompiled

A static recompilation of **No One Can Stop Mr. Domino** (USA, `SLUS-00804`),
built on [psxrecomp](https://github.com/mstan/psxrecomp) and
[recomp-ui](https://github.com/mstan/recomp-ui). The PS1 MIPS binary is
translated to C and compiled as a native x64 executable — the game runs as real
code, not under emulation.

| | |
|---|---|
| Serial | `SLUS-00804` |
| Region | NTSC-U |
| Publisher | Acclaim Entertainment (dev. ArtDink) |
| Year | 1998 |
| Framework | psxrecomp `v0.3.1-alpha-691` (pinned submodule) |

## Legal

**You must own the game.** This repository contains no disc image, no boot
executable, no BIOS, and no recompiled game code — only configuration, build
scripts and notes. Everything derived from the disc is produced on your machine
from your own dump and is gitignored.

Retail BIOS dumps are not redistributed either; the build uses the bundled,
MIT-licensed OpenBIOS unless you point it at your own `SCPH1001.BIN`.

## Status

Boots, runs at the correct speed, and all six stages are covered by the native
overlay cache.

| Interpreted instructions per frame | |
|---|---|
| No overlay cache | 2,405 |
| 437 native shards, all six stages | **77** (−97%) |

PS1 games stream code overlays from disc that a static recompiler never sees at
build time, so they fall back to an interpreter. Compiling captured overlays
into native shards is what closes that gap; the remainder is mostly code the
BIOS assembles in RAM at boot, which never existed on disc to begin with.

## Requirements

| | |
|---|---|
| CMake | 3.20+ |
| Python | 3.x |
| Git | with submodule support |
| Ninja | recommended — the emitter build prefers it |
| MSVC | for the emitters only (C++20) |
| MinGW-w64 GCC | required for overlay shards — see the note below |

The **runtime is built with clang**, not MSVC. psxrecomp's runtime sources use
GNU C extensions — designated-initializer ranges (`[0 ... N] =`) in `sio.c`,
`__attribute__` in `mdec.c` — which `cl.exe` cannot parse. The build script
fetches the portable `cmake-clang-v1` toolchain automatically, so nothing extra
is needed for that step.

Overlay shards additionally need a **real MinGW-w64 GCC** ([WinLibs](https://winlibs.com/)
is the easiest). Clang cannot build them: the generated overlay C defines
`overlay_flush_cycles()` with `dllexport` after `psx_cycles.h` has declared it
without, which GCC permits and clang rejects outright.

## Build

Clone with submodules, put your `.cue` where `game.toml` expects it (by default
a sibling directory — adjust `[game] disc` or pass `-Disc`), then:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
```

That syncs submodules, runs `psxrecomp_cli.py generate` to translate the disc
into C, and configures and builds the runtime. The first run is long — it
compiles roughly 300 MB of generated C. Output is
`build-release\Domino_Recompiled.exe`.

| Flag | Effect |
|------|--------|
| `-Bios C:\path\SCPH1001.BIN` | Also generate the retail BIOS backend |
| `-Disc C:\path\game.cue` | Override the disc path from `game.toml` |
| `-Config RelWithDebInfo` | Optimized with symbols, and enables the TCP debug server |
| `-BuildDir build-debug` | Build somewhere other than `build-release` |
| `-SkipGenerate` | Rebuild only, when `generated\` is current |
| `-Clean` | Wipe the build directory first |
| `-KeepGoing 10` | Pass `-k 10` to Ninja to surface many errors in one run |

## Growing the overlay cache

This is what takes the game from playable to fast. `game.toml` sets
`[runtime] overlay_cache = true`, so every overlay the game streams is recorded
to `overlay_captures.json` beside the exe while you play. Compiling those
captures produces native shards that load automatically on the next launch.

```powershell
# play, quit normally, then:
powershell -ExecutionPolicy Bypass -File scripts\build_overlay_cache.ps1
```

Repeat as you cover more of the game. Coverage accumulates: the runtime keeps
an immutable history in `overlay_captures.json.d\`, and the script compiles
every snapshot, so overlays that were long since overwritten in RAM are still
included.

| Flag | Effect |
|------|--------|
| `-BuildDir build-debug` | Read captures from a different build |
| `-OutDir build-release\cache` | Write shards somewhere else |
| `-Gcc C:\mingw64\bin\gcc.exe` | Pick the shard compiler explicitly |
| `-Force` | Rebuild shards that already exist |

**`overlay_captures.json` contains code read from your disc.** It is gitignored;
keep it local and never attach it to a public issue.

## Reaching every stage

Shard coverage only grows for code you actually execute, so the cache is only as
good as the ground you cover. `tools\ram_hunt.py` can warp between stages using
the game's own stage-advance path:

```powershell
# load a save state near the end of a stage (F7), then:
python tools\ram_hunt.py stage 4
# finish the stage -> loads stage 4
```

This needs a `RelWithDebInfo` build, since only that carries the TCP debug
server. The same tool snapshots and diffs RAM, traces writes with the guest PC
that made them, and pokes memory — see `--help`.

The runtime also has save states (**F7**, slots `1`–`9`, `0`, `-`, `=`) and
rewind (**F8**), which need no tooling at all.

## Notes

- [`docs/stage-select-findings.md`](docs/stage-select-findings.md) — reverse
  engineering of the stage counter: what it does, what it does not, and where a
  proper stage select would have to look instead.
- `symbols.toml` → `python tools\sync_symbols.py` → `psx_symbols.h` grows a
  progressive symbol map. See `psxrecomp/docs/SYMBOLS.md`.
- Submodule gitlinks are the authoritative framework pins;
  `framework_pins.txt` is a human-readable snapshot. Bump them deliberately.

## Credits

Built on [psxrecomp](https://github.com/mstan/psxrecomp) by mstan. Titles using
this framework can also be managed through
[RetComM Launcher](https://github.com/TechnicallyComputers/RetComM-Launcher),
which handles installs, updates and BIOS/ROM wiring across multiple recomps.

<!-- retcomm-readme-raid -->
---

<p align="center">
  <sub><b>R.A.I.D. — Retro AI Development</b> · a Discord for AI-assisted retro reverse-engineering, decomp &amp; recomp</sub>
</p>

<p align="center">
  <a href="https://discord.gg/Ad9BwSzctP"><img src=".github/raid-discord.png" alt="Join the Retro AI Development (R.A.I.D.) Discord" width="200"></a>
</p>
<!-- /retcomm-readme-raid -->
