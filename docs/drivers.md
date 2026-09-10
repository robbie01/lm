# Every peripheral owned by a process

A plan. Nothing here is built yet.

The goal is that a peripheral has exactly one owner, that reaching one you do
not own is impossible rather than merely discouraged, and that the mechanism
for reaching one is the mechanism the rest of the system already uses to talk
to anything: a message to a task.

## What is wrong now

Any code can reach any device. `poke` takes an address, the device pages are
addresses, and nothing looks at who is calling. Concretely:

- **The blitter writes anywhere in RAM.** It takes a destination and a stride
  and copies rows. A wrong stride does not draw a wrong picture, it writes
  across whatever follows the bitmap - a task's saved registers, in the case
  that took three sessions to find. There is no bound on it anywhere.
- **Device registers are shared mutable state.** Two contexts programming one
  chip interleave. The blitter avoids this only because its command lives in
  memory and each task fills its own block, which is ownership by disjointness
  and works - but it is a property of that one chip, not a rule.
- **Interrupt servers can touch anything.** They run with the world half
  saved. `blit-block` now refuses them, which is a check in one accessor
  rather than a property of the system.
- **The catalogue is small and already concentrated**, which is what makes
  this worth doing now rather than later:

      sys     halt, debug, interrupt enable/request     hw.lisp
      timer   mtime, mtimecmp                           hw.lisp
      uart    serial console                            gc, runtime, stream
      gfx     display base, mode, vblank irq            hw.lisp, exec.lisp
      input   keyboard and mouse events                 hw.lisp, exec.lisp
      blit    the blitter                               hw.lisp
      disk    block storage                             hw.lisp

## The two numbers that shape the design

Measured on this machine, under the workbench:

    a request round trip (send, block, reply, wake)      9,680 cycles
    a small blit (8x8 fill, through bm-fill-rect)          169 cycles
    one composite pass                              2,310,890 cycles
    blits in one composite pass                             66

So a message is **fifty-seven times** a small blit. Routing each blit of a
composite through a driver would cost 639,000 cycles on a 2,310,000 cycle
frame - twenty-eight per cent - to serialise work that is already disjoint.

And a message *per frame* costs 0.4% of that frame.

**That is the whole design constraint.** The unit of work sent to a driver has
to be a whole operation, never a primitive. Where a client needs the hardware
inside its own hot loop, messaging is the wrong tool and something else has to
carry the safety.

A second number says where that something else goes: at 66 blits a frame and
one MMIO store per blit, device-register traffic is about four thousand stores
a second against a hundred and forty million cycles - **three thousandths of
one per cent of memory traffic**. A check on the MMIO path is free.

## The model: four kinds of peripheral

The mistake would be to make everything a server and pay 9,680 cycles for a
fill. Peripherals differ, and the rule for which mechanism a peripheral gets
is about the *shape of its traffic*, not about taste.

**1. Kernel-owned: `sys`, `timer`.**
These are Exec. The timer is the scheduler's quantum and the system timebase;
`sys` is interrupt enable and the halt line. They are not drivers and should
not be tasks - a driver task cannot schedule itself. Rule: only exec.lisp
touches them, enforced the same way as everything else, with the kernel as the
owner.

**2. Driver-owned, request and reply: `disk`, and the mode-setting half of
`gfx`.**
Traffic is infrequent and each operation is large. A block read is thousands of
cycles of its own; 9,680 on top is noise. These are the easy, unambiguous wins
and should be done first.

**3. Driver-owned, notify: `input`, vblank, disk completion.**
The driver posts an edge to a client port - `notify`, no allocation, safe from
an interrupt server - and the client wakes on its own signal mask along with
everything else it is waiting for. Input is already half of this.

**4. Capability-shared: `blit`.**
Sixty-six times a frame from several tasks at once, into disjoint memory. The
fast path has to stay direct. Safety comes from a bound the *chip* enforces,
below.

## Enforcement: the machine checks, using s2

The strong part of this plan, and the part that is only available because of
what this machine already is.

There is no MMU. On an ordinary machine that would end the discussion:
ownership would be convention, checked in accessors that a determined caller
can walk around, and unenforceable from an interrupt server or from compiled
code that predates the rule. Here, **s2 holds the running task**, always, as a
register - the trap stub saves and restores it with everything else, and
`LM_WATCH_S2` exists precisely because that invariant is load bearing.

So the machine can answer "who is doing this?" on any instruction, with a
register read.

**The mechanism.** A table in the machine, one entry per device page, holding
the owning task (a tagged pointer, or zero for the kernel). `do_load` and
`do_store` already test `is_mmio(a)` and dispatch by page. Add: if the page has
an owner and `m.x[18]` is not that owner, take a fault naming the device and
the task. One index and one compare on a path that is three thousandths of one
per cent of memory traffic.

Zero means "the kernel", and before Exec exists s2 *is* zero, so the boot path
and the collector are the kernel by construction rather than by exception.

What this buys over a Lisp-side check in the accessor:

- It cannot be walked around. Not by `poke`, not by compiled code from an
  older image, not by an interrupt server, not by a bug that computes a device
  address by accident.
- It is checked at the *hardware* boundary, so the report says which device
  and which task, at the instruction that did it - not three seconds later
  somewhere unrelated.
- It costs nothing on any path that is not already talking to a device.

**Claiming.** A device register in `sys`: write a device number to claim it for
the running task, write again to release. Claiming an owned device faults.
This is itself an MMIO operation, so the rule that governs it is the rule it
implements.

## The blitter: a bitmap is a type, not an address

**This part is done.** It replaces an earlier draft of this plan that had the
*chip* keep a registry of bitmaps and check every command against it. That was
convoluted and it was not hardware anybody would build. The answer was in
software and it was smaller.

A bitmap used to be a record of three fixnums - `addr`, `w`, `h` - where
`addr` came from `alloc-pool`. Two things followed from that, and both were
bad:

- **The pixels lived in the pool**, interleaved with task control blocks,
  stacks and blitter command blocks. A rectangle that ran off the end did not
  look wrong, it wrote over the scheduler. That is not a colourful way of
  putting it; it is what happened, for three sessions.
- **The constructor took a raw address.** `(make-bitmap 0 9999 9999)` was a
  legal call, and what it returned was a licence to write over the whole
  machine. Nothing in the type system, such as it is, could tell that from a
  real bitmap.

Now the pixels are a **byte object** and the bitmap holds the object:

    (defrecord (bitmap bm) pixels w h)
    (define (alloc-bitmap w h) (make-bitmap (make-bytes (%* w h)) w h))

`make-bitmap` checks that the pixels are a byte object and that `w * h` fits
inside it, once, at construction. Everything downstream can then trust the
`w` and `h` beside it, and the existing clipping - which was already correct -
becomes an argument rather than a hope: a clipped rectangle is inside `w x h`,
`w x h` is inside the buffer, and the buffer is an object with a header saying
so.

What it bought:

- **A bitmap cannot be forged.** The only way to get one is to allocate one.
- **An overrun is contained.** Object space, not the pool: the worst it
  reaches is another object, and a damaged object header is something the
  collector notices and names.
- **The collector frees them, which fixed a real bug.** `window-close` used to
  `free-pool` the pixels and null the field. The compositor reads window
  bitmaps outside any critical section, so it could be part way through that
  window - reading memory that had just been given away, or asking a null
  bitmap how wide it was. Both are gone: closing a window now just drops it
  from the list, a compositor holding the old list draws one more stale frame
  from a bitmap that is still perfectly valid, and the pixels go when the last
  reference does. Thirty open-and-close cycles reclaim 2.4 MB and report
  nothing.
- **New windows start black** rather than showing whatever the pool last had
  in them, because `make-bytes` zero-fills and `alloc-pool` did not.

None of this works if objects move. They do not - this collector compacts
pairs and sweeps objects in place - so an address taken out of a byte object
is good for ever, which is what lets one be handed to the display register and
to the blitter. That is a real constraint on the collector now, and it is
written down in gc.lisp for a different reason: the collector is written in
the language it collects and cannot move the objects it is standing on.

**What is left.** `bm-at` still hands a raw address to the command block, so
inside hw.lisp it is still possible to get the arithmetic wrong; that is four
call sites rather than an open capability. And `make-bitmap` will accept any
byte object, so a bitmap over some *other* byte object is still expressible -
a much smaller hole than a bitmap over an arbitrary integer, and it closes by
making `alloc-bitmap` the only sanctioned way in if it ever matters.

The general form of the lesson is worth keeping, because it applies to every
peripheral below: **the fix for "this API lets you name something you do not
own" is usually to make the thing a value with an extent, not to add a
checker.** The registry was a checker.

## The uart is the honest exception

It is used by the collector, by the panic path, and by the REPL, and it has to
work before Exec exists, inside a trap handler, and after the scheduler has
stopped being trustworthy. A device you can only reach by asking a task is
useless in exactly the situations you most need it.

So: **the raw uart stays kernel-owned and unchecked**, and is documented as
the debug and panic device. Ordinary console output goes through a console
server that owns nothing but the queue. AmigaOS drew the same line, between
`serial.device` and the raw `kprintf` that works when nothing else does; the
mistake would be pretending one mechanism can be both.

## What each driver is

A driver is a task with a port. Its request vocabulary is a small language,
and the point of writing it down is that it is a *language* - the things a
client can ask for - rather than a set of registers a client pokes.

**disk.driver** — `(read block n into)`, `(write block n from)`, `(flush)`.
Synchronous to the caller, asynchronous to the device: the driver blocks on
the completion interrupt, and the client blocks on its reply.

**input.driver** — owns the input device. Decodes raw events into typed
messages and publishes them to subscriber ports: `(key down code)`, `(mouse
moved x y)`, `(button down n x y)`. Today every client would have to decode the
raw device itself, which is why there was only ever one.

**gfx.driver** — owns the display registers, the screen bitmap, and the
blitter registry. `(open-screen w h)`, `(bitmap w h)` answering a bitmap the
caller owns, `(free-bitmap b)`, `(damage b rect)`. The compositor is either
this task or its only client.

**Exec** keeps `timer` and `sys` and is not a task.

## Ownership lifecycle

- **Claim** at driver start, before the driver publishes its port. A client
  that can reach the port can rely on the driver owning the device.
- **Release** on driver exit. `rem-task` must release everything the task
  owned, or a crashed driver locks its peripheral out of the machine for good.
  This is the same shape as `reap-task` freeing a stack, and belongs beside it.
- **Death.** A driver dying with clients blocked on its port leaves them
  blocked for ever. Two honest options: let it happen and require drivers to be
  restarted deliberately, or have `rem-task` reply an error to every message
  still queued on a port the dead task owned. The second is better and is not
  much code.
- **Before Exec**, s2 is zero and every device is the kernel's. The transition
  is a driver claiming a device that the kernel owned, which needs a rule for
  when the kernel is allowed to give one up: after `exec-init`, and not
  otherwise.

## Sequence

Each step lands on its own and the machine works after each one.

**0. The table, reporting only.** Device ownership in the machine, claims from
Lisp, and violations reported rather than faulted - the way `LM_BLIT_GUARD`
works now. Claim nothing yet. Then run the workbench, the demos and the
collector, and read the list of who touches what. This is the step that finds
out whether the catalogue above is complete, and it is cheap.

**1. Kernel devices.** Exec claims `sys` and `timer`. Move the few stragglers
out of hw.lisp. Small, and it proves the mechanism on the least interesting
device.

**2. disk.driver.** The whole model, end to end, on the peripheral where
nothing is hot and nothing else depends on the answer.

**3. input.driver.** Already a port; this makes it a task with a decode
vocabulary. Removes the last direct `input-pending` / `input-event` from
clients, and gives the workbench a reason to stop being the only listener.

**4. The bitmap registry.** In the chip, checked, reported only. Register the
screen, window bitmaps and the collector's scratch. Run everything and see
what falls outside.

**5. gfx.driver.** Owns the display and the registry. Bitmap allocation and
freeing move behind it, which is what fixes `window-close`.

**6. Enforcement on.** Reports become faults, for devices and for the
registry. This is a one-line change and it is the entire point; everything
before it is making the machine ready to survive it.

**7. The console split.** Raw uart for panics and the collector; a console
server for everything else.

## What this does not fix, and one thing it makes worse

- **It is not memory protection.** A task can still write anywhere with an
  ordinary store. This plan closes the peripherals, which are the paths where a
  small mistake becomes an arbitrary write; it does not close the language.
- **Priority inversion.** A driver runs at one priority. A low-priority
  client's request sits in front of a high-priority client's until the driver
  gets to it. Exec has priorities and the port has none. Worth knowing about
  before it bites; a priority-ordered message list is the usual answer and
  `enqueue` already sorts by priority.
- **`wait-ports` is not fair.** It answers the first ready port, so a busy
  client can starve a quiet one at a driver with several ports. Go shuffles.
- **A message is 9,680 cycles and about an eighth of that is allocating the
  message.** Drivers on a warm path should keep a preallocated message per
  client rather than making one per call. Worth doing before, not after,
  something depends on the latency.
- **Two more context switches per operation** than a direct call, which is the
  price of the model and is why the granularity rule above is not a detail.

## How we will know it worked

- `(drivers)` at the prompt, beside `(talking)`: claim a device, watch a
  non-owner fault, watch a driver die and its device come free, watch a client
  blocked on a dead driver get an error rather than silence.
- The blitter registry test is the one that matters: a deliberately wild blit -
  the exact command that corrupted the machine three sessions running - has to
  fault at the instruction, name the task, and leave the machine alive.
- And the negative test, which is the one that will actually be run every day:
  the workbench, four windows, the Mandelbrot and a collection, with
  enforcement on and nothing reported.
