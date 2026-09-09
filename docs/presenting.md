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

## What it costs, measured

Memory, on this machine:

| | bytes |
|---|---|
| the screen, 640x400 at 8bpp | 256,000 |
| a shell window's bitmap, 380x200 | 76,000 |
| an eyes window's bitmap, 130x95 | 12,350 |
| what a window costs *today* | 65,784 — almost all of it the 64 KiB task stack |
| the Exec pool | 16,769,024 |

So a backing store roughly doubles what a shell window costs and adds a fifth
to what an eyes window costs, and ten buffered shells would be 760 KiB, or 4.5%
of the pool. On memory grounds this is not a difficult decision.

Bandwidth is the one that bites. The blitter is charged one cycle per pixel and
the machine runs at 20 MHz, so a frame is 333,333 cycles and:

```
full screen  640x400   256,767 cycles    77% of a frame
shell        380x200    76,767            23%
eyes         130x95     13,117             4%
```

**Compositing the whole screen every frame does not fit.** Compositing only what
changed does, easily: the four-eyes workbench is 54% of a frame even if every
window redraws at once, and in practice only the two small windows move, which
is 7%.

## Would an old system have done this?

No, and each of them tells you why in its API.

- **Classic Mac OS (QuickDraw, 1984)** — no backing store at all. A GrafPort
  has a `visRgn` and a `clipRgn`, you draw straight at the screen, and when a
  window is uncovered you get an update event and repaint it yourself. That is
  the entire reason `BeginUpdate`/`EndUpdate` exists. On a 128K Mac the screen
  was 21,888 bytes — **17% of the machine**.
- **AmigaOS (Intuition and Layers, 1985)** — three choices per window, and the
  middle one is the interesting one. `SIMPLE_REFRESH` stores nothing and sends
  the app a refresh message. `SMART_REFRESH` stores **only the obscured parts**,
  as a bitmap per hidden ClipRect. `SUPER_BITMAP` gives the app a full bitmap
  of its own. So the Amiga had full backing stores — as the expensive option an
  application opted into, with "buffer only what is hidden" as the default
  compromise. Its screen was 81,920 bytes of 512 KiB chip RAM, **16%**.
- **X11 (1987)** — `backing_store` is a window attribute the server is free to
  ignore, and servers generally did. Expose events instead.
- **NeXTSTEP (1989)** — where it turns over. Windows are `Nonretained`,
  `Retained` or `Buffered`, and buffered — a full offscreen buffer composited
  by the Window Server — is the normal choice. The screen was 232,960 bytes of
  8 MiB, **2.8%**.
- **Mac OS X 10.0 (2001, Quartz)** and **Windows Vista (2006, DWM)** — every
  window buffered, always, no option.

The flip happens when the screen stops being a meaningful fraction of memory.
Here it is 1.5% of the pool and 0.1% of RAM, which puts this machine past NeXT
and comfortably in the buffer-everything era **on memory**. On bandwidth it is
back in 1985: 20 MHz cannot composite a screen sixty times a second.

Which gives the design: **buffer per window like NeXT, composite only damage
like the Amiga.** The Amiga's cleverness of storing only the obscured
rectangles was a response to 512 KiB and is not worth copying; its refusal to
redraw the whole screen is a response to the clock, and that constraint is
still here.

One thing worth being honest about: on Amiga and Mac the application that drew
outside its window was the single application you were running. Here it is one
of seven preemptively scheduled tasks in a shared address space, and today it
draws into the screen bitmap through a clipping region that has to be correct.
A window bitmap does not *prevent* a task poking the screen — nothing can,
without an MMU — but it removes the ordinary path by which drawing escapes,
which is where both of the graphics bugs found in this session came from.

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
