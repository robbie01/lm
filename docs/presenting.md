# Presenting a frame

*Written 2026-09-09, after the display got a vblank interrupt server and
drawing tasks stopped spinning. This is the argument about what the interface
should have been, and what it should become.*

## What is there now

Exec reserves one signal bit — `sigf-vblank`, the same bit in every task, which
is what lets the server wake every waiter by walking the wait list instead of
keeping a registry somebody has to maintain. An interrupt server on the
display's line signals it once a frame. `(wait-vblank)` blocks on it.

That is a **clock**. A task asks to be woken at the next frame boundary.

## What it should be

A **present request**: the task says *my frame is finished, show it*, and does
not run again until the display has. The difference is direction, and it is
not cosmetic.

| | vblank signal | present |
|---|---|---|
| who speaks first | the display | the task |
| granularity | broadcast to everyone waiting | one task, one frame |
| a task with nothing to draw | wakes anyway, sixty times a second | is not waiting on the display at all |
| where the frame lives | the screen, already | the window, until the server takes it |
| what throttles you | the passage of time | the display consuming your work |

The last row is the one that matters. Under a clock, a task is rate-limited by
something that has nothing to do with what it did. Under present, back-pressure
comes from the consumer: draw faster than the display shows frames and you
block, exactly as long as you deserve to.

## Are they the same thing?

For the eyes, today, behaviourally yes. If `present` were implemented as *block
until the next frame boundary*, a task that draws every single frame could not
tell the difference. That is why it would be a mistake to add it now as a
synonym: a name that promises a handover and performs none is worse than the
honest low-level name.

They diverge for tasks that **sometimes** have nothing to draw, and that is
most tasks. A text editor with no keystroke to render should be waiting on the
keyboard, not waking sixty times a second to discover that nothing happened.
The eyes are a bad example precisely because xeyes really is a mouse poller —
it genuinely wants a clock.

## Does it depend on double buffering?

The contract does not. Two thirds of the benefit does.

- **Throttling** — "do not run me again until my frame is on screen" — works
  with no buffers at all. This is the part that is worth having immediately.
- **Compositing** — the server having a defined moment at which it assembles
  the screen out of windows — needs somewhere for a finished frame to live.
  Today every task draws straight into the one screen bitmap through its
  rastport and clipping region, so by the time it said "present" the pixels
  would already be on the glass. The word would be a promise about nothing.
- **Tearing** — same answer. A clock only makes tearing happen at a consistent
  moment. A backing store is what removes it.

So: present without buffers is a real improvement in scheduling and an empty
one in graphics.

## The order to do it in

1. **Windows own their bitmaps.** This is the prerequisite for everything
   below, and it independently fixes a whole class of bug structurally rather
   than by clipping carefully: a task that draws outside its window writes into
   its own memory instead of somebody else's window. The regions and rastports
   already in `wb.lisp` become the thing that composites rather than the thing
   that clips.
2. **`(present)`** then means what it says: hand the window's bitmap to the
   server, block until it has been composited. `wait-vblank` stays underneath
   as the mechanism, and the input task keeps using it, because polling a
   device on a clock is what that task actually wants.
3. **Damage tracking.** Once a frame is a handover, the server knows which
   windows changed and can composite only those. A screen where one small
   window is animating should not cost a full-screen assembly.
4. **Input becomes push too.** The other direction of the same idea: a shell
   waiting for a key should block on a signal raised when a key is delivered to
   its window, not wake on a clock to ask whether one arrived.

## The constrained-machine version

None of this needs to be expensive. A window bitmap is pool memory the size of
the window; the machine has 16 MiB of pool and a 640×400 screen is 250 KiB, so
a dozen windows fit comfortably. Compositing is the blitter, which already
copies rectangles at two device pokes a row. The server is one task that waits
on the vblank signal, walks the damaged list, blits, and signals the presenters
it consumed.

What it costs is one copy per window per frame that changed. What it buys is a
display that cannot be scribbled on by the wrong task, tear-free updates, and a
scheduler where being woken means having something to do.
