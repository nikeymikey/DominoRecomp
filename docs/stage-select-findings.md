# Stage select: what is known, and what is ruled out

Status: **unsolved**. `0x800B2D98` is not the variable a stage select needs.
Recorded so the next attempt does not repeat this one.

## The counter at 0x800B2D98

A **halfword** (`lh`/`sh`) holding the current stage number, 1-based.

Confirmed behaviour:

- Held 1 at two separate points during stage 1, and 2 during stage 2, across
  independent RAM snapshots.
- Poking it to 3 mid-stage and then finishing the stage advanced the game to
  stage 4. **This proves it drives ADVANCING, and nothing more.**
- Setting it to 4 at the title screen, verified by read-back, and then starting
  a new game still began on stage 1. Write-tracing showed nothing restored it.
  **So it is not an input to the stage-load path.**

## Code that touches it

Stage-advance routine (main EXE):

    0x800130E0  lh    $v0, 0x2d98($v0)   ; current stage
    0x800130E8  bnez  $v0, 0x80013100    ; nonzero -> advance
    0x800130F8  j     0x80013094
    0x800130FC  addiu $v0, $zero, 1      ; delay slot: "first stage = 1"
    0x80013100  addiu $v0, $v1, 1        ; else current + 1
    0x80013108  sh    $v0, 0x2d98($at)   ; store back
    0x80013110  sh    $s0, 0x3fe0($at)   ; companion field -> 0xFFFF

Save-load routine (main EXE) - the counter is unpacked from the memory-card
save block, not initialised from a constant:

    0x80030D4C ..            checksum loop over 0x800BCC0 .. +0x1FFC
    0x80030D94  bne   $v0, $a0, 0x80030eb0   ; checksum mismatch -> other path
    0x80030DA0  addiu $a3, $a3, 0x3748       ; save block copied to 0x800B3748
    0x80030DA8 ..            memcpy loop
    0x80030DE8  lbu   $v1, 0x3748($v1)       ; stage byte out of the save
    0x80030E40  sh    $v1, 0x2d98($at)       ; -> the counter

Refresher writes seen at the title screen, both **overlay** addresses, both
writing the value back unchanged: `0x800C2648` and `0x800C7268`.

## Patches tried, and why each failed

| Target | Idea | Result |
|---|---|---|
| `0x800130FC` immediate | change "first stage = 1" | Patch verified live in RAM (`24020004`), no effect: that branch needs the counter to be zero, and with a save present it never is |
| `0x800130DE8` load | replace the save's stage byte with a constant | No effect: the counter is not read by the stage-load path |

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

## Cheap alternative

F7 opens the runtime's save-state menu (slots 1-9, 0, -, =); F8 is rewind. A
slot per stage gives instant jump-to-anywhere with no reverse engineering, and
covers the testing need this work was meant to serve.
