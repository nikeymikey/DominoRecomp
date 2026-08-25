# Stage select: what is known, and what is ruled out

Status: **unsolved**. `0x800B2D98` is not the variable a stage select needs.
Recorded so the next attempt does not repeat this one.

Addresses and conclusions are given; the game's own instructions are described
rather than quoted.

## The counter at 0x800B2D98

A **halfword** (accessed with `lh`/`sh`) holding the current stage number,
1-based.

Confirmed behaviour:

- Held 1 at two separate points during stage 1, and 2 during stage 2, across
  independent RAM snapshots.
- Poking it to 3 mid-stage and then finishing the stage advanced the game to
  stage 4. **This proves it drives ADVANCING, and nothing more.**
- Setting it to 4 at the title screen, verified by read-back, and then starting
  a new game still began on stage 1. Write-tracing showed nothing restored it.
  **So it is not an input to the stage-load path.**

## Code that touches it

**Stage-advance routine**, main EXE, around `0x800130E0`-`0x80013118`. It loads
the counter, branches on whether it is already non-zero, and either stores a
literal 1 (the "first stage" path, at `0x800130FC`) or stores current+1 (at
`0x80013108`). A companion field at `0x800B3FE0` is reset to `0xFFFF` two
instructions after the counter store.

**Save-load routine**, main EXE, around `0x80030D4C`-`0x80030E40`. It:

1. checksums a block at `0x800BCC0` spanning `0x1FFC` bytes;
2. branches away to `0x80030EB0` if the checksum does not match;
3. copies the save block to `0x800B3748`;
4. unpacks fields out of that block into globals - the stage byte is read from
   `0x800B3748` at `0x80030DE8` and stored to the counter at `0x80030E40`.

So the counter is never initialised from a constant. It comes from the memory
card save.

Refresher writes seen at the title screen, both **overlay** addresses, both
writing the value back unchanged: `0x800C2648` and `0x800C7268`.

## Patches tried, and why each failed

| Target | Idea | Result |
|---|---|---|
| `0x800130FC` immediate | change the "first stage" literal | Patch verified live in RAM, no effect: that branch needs the counter to be zero, and with a save present it never is |
| `0x80030DE8` load | replace the save's stage byte with a constant | No effect: the counter is not read by the stage-load path |

Both were verified as applied. The failure was the premise, not the mechanism -
`main_exe` patches work, and a patched range is routed onto the dirty-RAM
interpreter as `MOD_PACKAGES.md` describes.

## Ruled out

- The counter is not written on New Game; it is already set before the title
  screen and merely rewritten with the same value.
- It is not initialised from a constant anywhere; it comes from the save block.
- It is not restored/refreshed after an external write, so a poke does persist.
- Forcing it does not change which stage loads.

## Where to look next

The stage that loads must be selected from something else. Untried angles, in
rough order of promise:

1. `cdrom_command_history` / `cdrom_sector_history` across a stage load: the
   stage's data comes off disc, so the LBA identifies the stage. Whatever code
   computes that LBA reads the real selector.
2. `PSX_READ_WATCH` - unlike `PSX_WTRACE_BOOT`, this env var *is* read by
   `debug_server.c`. A read watch on a suspected selector would show the
   consumer directly.
3. Snapshot-diff the title screen with two saves at different stages, rather
   than diffing during play. That isolates the persistent selector from
   in-play state.
4. The overlay at `0x800C7000` writes the counter; disassembling it from
   `overlay_captures.json` may reveal the master it copies from.

## What the counter IS good for

Advancing works, and that is enough to reach any stage for overlay-capture
purposes. From a save state near the end of a stage:

    python tools/ram_hunt.py stage 4     # counter := 3
    # finish the stage -> loads stage 4

`tools/ram_hunt.py stage N` sets the counter to N-1 and verifies the read-back.
Load the save state FIRST: restoring a state rewrites RAM and discards the poke.
N must be 2..6; a counter of 0 takes the first-stage branch instead.

This is how all six stages were covered for the overlay cache, taking the
interpreter from 2,405 instructions per frame to 77.

## Cheap alternative

F7 opens the runtime's save-state menu (slots 1-9, 0, -, =); F8 is rewind. A
slot per stage gives instant jump-to-anywhere with no reverse engineering, and
covers the testing need this work was meant to serve.
