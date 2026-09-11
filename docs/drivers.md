# Every peripheral owned by a process

A plan, and now a record of building it: every phase below is done, and what
each one turned up on the way is written beside it.

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

(Measured before the blitter had a chain. Since phase 4 a composite pass is
783,454 cycles, and a small blit costs the task that issues it about 850
cycles all in: clipping 189, taking a descriptor 156, filling it 212, linking
it 137. The argument below only gets stronger: a message is now eleven times a
whole small blit, and seventy times the part that talks to the chip.)

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

**4. Shared, and made safe by its arguments rather than by its owner: `blit`.**
Sixty-six times a frame, from several tasks at once, into disjoint memory.
Safety comes from the thing a blit names being a *value with an extent* rather
than an address, which is done. Arbitration is a separate question and only
arises once the chip is genuinely asynchronous, which is a phase of its own
below.

## Enforcement is scoping, not checking

An earlier draft of this section proposed a table in the *machine*: one entry
per device page holding the owning task, checked in `do_load` and `do_store`
against `s2`, faulting when they disagree. It was cheap - three thousandths of
one per cent of memory traffic - and it would have worked.

It was also an MMU. A range check against a per-page permission, keyed on the
current protection domain. No translation, but the same category, and it buys
its safety by making this a machine with a supervisor instead of a machine
where one address space is safe because of what the language will let you say.
That is a different machine, and not the one being built.

It also contradicted the lesson from the bitmap, written down two sections
below and then ignored here: **the fix for "this API lets you name something
you do not own" is to make the thing a value, not to add a checker.**

So, the same move again, and it turns out most of it is already done.

**A device page is reachable only by naming its address**, and those addresses
are constants in hw.lisp. Of the seven, four - `sys`, `timer`, `uart`, `disk` -
are not exported at all: outside that file there is no way to say where they
are. Three leak exactly one name each:

    gfx     gfx-ctrl     exec.lisp, to turn the vblank interrupt on
    input   inp-ctrl     exec.lisp, to enable the device
    blit    blt-list     the store that commits a blit

That is the entire hole. Not "any code can reach any device" - that was true
of the *idea* of the machine and false of the code, and the difference matters
because it means there is nothing to build here, only three names to take
back. And each of the three is taken back by the driver phase that owns that
chip: `gfx.driver` needs `gfx-ctrl`, `input.driver` needs `inp-ctrl`, and the
blitter's commit store is one line inside `blit-go`.

**All three are back now**, in phases 3, 5 and 6: no device register is named
outside hw.lisp. What is left is arithmetic. `mmio-base` and the device
numbers are exported with the rest of the memory map, so a program can still
compute a register's address and store to it - which is the wild store below,
and this plan does not pretend to close it.

**A device becomes a value**, on the bitmap's pattern:

    (defrecord (device dv) name base owner)
    (define (dev-poke d reg v) ...)   ; checks (%eq? (dv-owner d) (this-task))
    (define (dev-peek d reg) ...)

One comparison, in the language, raising a Lisp error with a backtrace rather
than a machine fault - and no way to reach a chip without holding the device
it belongs to. Claiming sets the owner; `rem-task` releases, so a driver that
dies does not lock its peripheral out of the machine.

**What this does not catch, honestly.** A wild store - a computed address that
lands in a device page by accident - goes straight through, where the machine
check would have caught it. That is the general memory-safety problem, which
this plan does not solve and did not solve with the table either; a wild store
into RAM is just as fatal and far more likely. When one is being hunted, that
is what the Rust-side watches are for.

Which is the line this project keeps arriving at and should probably state
outright: **the Rust side observes and the language enforces.** `LM_BLIT_GUARD`,
`LM_WATCH_S2`, `LM_WATCH_ADDR` and the profiler are all off by default and cost
nothing when off, and between them they have found every hard bug here. None of
them is load bearing. Putting enforcement down there would make the machine
depend on its emulator for its semantics, and this machine is supposed to be
describable without one.

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

## The blitter becomes a real asynchronous device

**The asynchronous part is done.** It used to finish every transfer inside
the store that started it: `B_STATUS` always read idle, and the completion
interrupt would have fired after the work was over. Now:

- A commit marks the chip busy until `now + cost`. Nothing moves yet.
- The copy happens in one go at the *end* of that window. Until then the
  destination holds its old contents, so code that reads pixels it has only
  just asked for sees the old ones. That is deliberate: real hardware would
  show a torn picture, and either is wrong in a way you notice.
- When a command finishes, the chip writes a done word back into the command
  block it came from (word 12). A task waits for *its own* pixels by reading
  its own block, rather than waiting for the chip to go idle - which would
  mean waiting behind the compositor, which keeps the chip busy about half the
  time.
- `blit-drain` waits for the chip to be free; `blit-sync` waits for this
  task's last command. `bm-plot` and `bm-point` sync for you. Anything that
  computes pixel addresses itself has to call `blit-sync` first - the WaitBlit
  rule.

Measured: a pixel read straight after a fill returns the old value and the
new one after `blit-sync`; a full-screen fill's commit returns after about 750
cycles instead of 786,432, and four other tasks got the processor while it
ran. `(blitting)` at the prompt checks all of this.

It found a bug on its first run, which is what it was for. `blit-go` marked
the block pending before waiting for the chip, but waiting is what lets the
task's *previous* command finish - and finishing writes that command's done
into the same block. So the second of two back-to-back blits ran with its
block already saying done. The collector clears its maps with four fills
through one block, so its wait returned early and marking read bits that had
not been cleared. It surfaced as a load from address minus four in
`gc-object-slots`, only when enough had been allocated for the last fill to
still be running. Pending is now set after the wait, with the chip known idle.

The descriptor chain and the cost model are built too: see *The three
changes*, and phase 4 in the sequence.

That is worth fixing for a reason beyond tidiness: the target is eventually an
FPGA SoC, and this is the one part of the machine whose model is not
predictive of hardware.

### Why keep a blitter at all

Because it is what real parts in this class do. STM32's DMA2D, NXP's PXP and
Renesas's DRW2D are all 2D blitters shipping in MCUs driving LCDs, and every
SoC has generic memory-to-memory DMA (ARM PL330, Xilinx AXI CDMA). Large SoCs
avoid the copy instead, by compositing at scanout with overlay planes in the
display controller - which is worth wanting later, and does not replace a
blitter: it does not handle arbitrary z-order over many windows, offscreen
drawing, or scrolling inside a window.

The argument that matters on this target is not parallelism, it is **bus
efficiency**. On PSRAM a CPU copy loop pays first-word latency per access; a
DMA engine amortises it over a burst. The blitter wins on a single-issue
machine with no cache even when nothing overlaps.

### What overlap actually needs

PSRAM is a single shared port. HyperRAM at 166 MHz DDR x8 is about 332 MB/s
peak and nearer 200-230 MB/s once latency is paid. If the CPU fetches from the
same PSRAM, the CPU and the blitter interleave bus cycles and very little real
overlap happens. Overlap becomes real when the CPU can run without the bus,
which is a cache in block RAM or code in tightly coupled memory - a CPU
decision, not a blitter one, and one to make before assuming the overlap is
there.

At 1024x768 8bpp and 60 Hz the budget is:

    scanout, read                                 47 MB/s
    full-screen composite, read and write         94 MB/s
    graphics total                               141 MB/s
    left for the CPU out of ~220 MB/s             ~80 MB/s

So **damage-rect compositing stops being an optimisation and becomes a
requirement**. The damage tracking already exists; on real hardware it is what
makes the design fit.

### The three changes

**All three are built.** The second came first, as the asynchronous part
above; the other two are phase 4.

**1. The command block becomes a descriptor with a `next` pointer.** The
register is already called `blt-list` and already takes the address of a block
in memory; make the chip walk the chain rather than run one block. This is
what scatter-gather DMA does, and it turns queueing into a hardware property:
a driver appends a descriptor and the chip picks it up without the CPU being
involved at all.

**2. The chip becomes a state machine that advances with the cycle counter.**
`B_STATUS` reads busy while a chain is running, `INT_BLIT` fires when it drains.
No interlock on the destination - reading a region the blitter is writing
returns whatever is there, the same as real hardware - and keeping clients off
that region is the driver's job, not the chip's.

**3. The cost model becomes bandwidth rather than a flat byte per cycle.**
`rows x (setup + bytes_per_row / bytes_per_cycle)`, with the read-modify-write
operations - XOR, AND, MASK - costing about double because they read before
they write, and an extra burst at each end of a row that does not start on a
burst boundary. The point is that the emulator should predict the FPGA rather
than flatter it.

Measured on the workbench with two shells, a full-screen composite pass:
2,310,890 cycles before, 783,454 after. The pass no longer waits on the chip
at all - issuing it takes 750,016 of those cycles, and the chip finishes about
33,000 cycles after the last blit is queued. What is left is the processor's
own work, the region arithmetic and clipping, which is where to look next.

### Considered and shelved: composing at scanout

The alternative to copying is not copying: give the display chip a short list
of where each window's pixels live and what position it occupies, and have it
read from the right one as it walks each line. The finished image never exists
in memory. That removes the compositor's traffic entirely - about 94 MB/s of
the 141 - because the chip has to read every pixel once anyway and compositing
is a second read plus a write on top.

Shelved, deliberately:

- It is a hardware compositor. That is a much bigger thing to build than a
  blitter, and it is the first step onto the GPU road rather than a tweak to
  the display.
- It does not remove any work. Real parts support a few layers, not arbitrary
  overlapping windows, so the blitter path has to exist anyway for everything
  the layers cannot do. It is additive.
- The real-time constraint is unforgiving in a way copying is not. The chip
  reads ahead of the beam, and every time a line crosses from one window to
  the next it has to start reading somewhere else and wait for memory. Too
  many crossings on one line and the picture tears. A compositor that is late
  merely drops a frame.

The display stays a plain framebuffer: one block of memory, scanned out in
order. Revisit only if memory bandwidth turns out to be the binding constraint
on real hardware, and only after damage-rect compositing has been measured
there - that is the cheaper answer to the same problem and it already exists.

### What this does to the software

This is the change that makes a graphics driver *necessary* rather than
merely tidy. An asynchronous chip needs an owner to run the queue:

- The driver owns the descriptor chain and appends to it.
- Completion raises `INT_BLIT`; the server marks descriptors done and signals
  whichever clients were waiting.
- A client that does not need the pixels yet does not wait at all. A client
  that does waits on its own signal, along with everything else it waits on.

The cost only works if clients queue rather than call, and phase 4 made that
sharper. A composite pass is now 783,454 cycles for 66 blits, about 11,900
each:

    request per blit, blocking      9,680 cycles     81%
    send per blit, queued           ~2,500 cycles    21%
    link a descriptor, no message      137 cycles     1%

So a message per blit is out, even a queued one. What a graphics driver can
own is the rules of the chain and its completion signals; clients go on
linking their own descriptors, and talk to the driver once a frame, not once
a blit.

`bm-blit-rect` and friends keep their shape. What changes underneath is that
filling a descriptor and appending it replaces filling a block and storing its
address, and the fill is still a task's own memory, so the per-task command
block argument is unchanged.

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

**Built**, as described, in lisp/console.lisp. The raw functions in
runtime.lisp are unchanged and unchecked. console.driver holds the line - its
claim on the serial device is bookkeeping, saying who reads it, and refuses
the raw path nothing - writes whole lines, and owns the receive side, so the
prompt on the serial line sleeps on a port between keys instead of spinning.
The prompt's stream collects a line and hands it over whole. Wherever handing
it over is impossible - in a trap handler, with interrupts off, before the
driver is up - it writes what it has collected raw and carries on raw, so
nothing comes out of order; and it hands over what it has before it waits for
input, or the prompt would sit in a buffer. Input arrives a burst at a time:
one key, or a whole script.

A rebuild is the case that shaped it most. `(rebuild)` redefines the kernel
while it reads its own sources from the console, so it must not wait on a
driver. Its output goes raw for the duration, and its input is already in the
stream: the whole script arrived as one burst before the rebuild began.

The first rebuild after the split stopped dead anyway, and the reason is
worth keeping. stream.lisp is one of the sources, and compiling it runs
`(define *in* nil)`. Before, that set the rebuild's input to what it already
was, the raw line. Now it cut the rebuild off from the stream holding the
rest of its sources, and left it waiting on a serial port the driver had
already emptied. `rebuild` holds on to its stream now and puts it back before
every form.

## What each driver is

A driver is a task with a port. Its request vocabulary is a small language,
and the point of writing it down is that it is a *language* - the things a
client can ask for - rather than a set of registers a client pokes.

**disk.driver. Built**, in lisp/disk.lisp. `(read block n bytes)`, `(write
block n bytes)`, `(flush)`, `(size)` and `(exclusive job)`. Synchronous to the
caller, asynchronous to the device: the driver sleeps on the completion
interrupt, and the client sleeps on its reply. A transfer names a byte object,
never an address, and the driver checks that the blocks fit - the bitmap
lesson again, since a disk read is a write into memory.

**input.driver. Built**, in lisp/input.lisp. Owns the input device, decodes
raw events into lists and sends every subscriber a copy: `(key down ascii code
mods)`, `(mouse moved x y)`, `(button down n x y)`, `(wheel delta x y)`.
Before, reading an event took it off the chip, so only one task could listen,
and that task had to decode the raw words itself. Where the pointer is now is
not a message: the driver keeps the latest position in variables anybody can
read.

**gfx.driver. Built**, in lisp/gfx.lisp. Owns the display chip: `(screen w
h)`, `(show)` after a resume, `(colours pairs)` for the palette, and
`(present)`. It also owns blit completion: a task whose blit is still running
sleeps, and the blitter's interrupt wakes it. It does not own drawing - tasks
go on linking their own descriptors, since a message costs as much as eleven
small blits - and it does not hand out bitmaps: since a bitmap became a byte
object, allocating one is already safe, and a message per window would buy
nothing. The compositor stays a client, in wb.lisp.

**Exec** keeps `timer` and `sys` and is not a task.

## Ownership lifecycle

- **Claim** at driver start, before the driver publishes its port. A client
  that can reach the port can rely on the driver owning the device. Built:
  `claim-device-for` claims on the new task's behalf before it first runs.
- **Release** on driver exit. `rem-task` must release everything the task
  owned, or a crashed driver locks its peripheral out of the machine for good.
  Built: devices come back through `release-devices-of`, and anything else a
  driver holds - its interrupt server - through `on-task-end`.
- **Death.** A driver dying with clients blocked on its port used to leave
  them blocked for ever. Built, the better of the two ways: a message to a
  task that has ended is answered with a failure at once, `rem-task` answers
  everything still queued on the dead task's ports, and a message stays on
  its port until it is answered, so the one the driver was working on is
  answered too. A handler that fails answers with the failure and the server
  starts again on a clean stack. `request` turns a failure into an error in
  the caller.
- **Before Exec**, s2 is zero and there is no task to own anything. The rule
  that came out of building it: a driver's device starts unowned, and while
  nobody holds it, whoever calls does the work directly. That covers the
  boot before Exec, the stretch between a driver dying and the next one
  starting, and a rebuild - which is how `save-rebuilt` writes an image with
  no driver running.

## Sequence

Each step lands on its own and the machine works after each one.

**0. The catalogue. Done** - it was a grep, not a runtime table. Four devices
are already unreachable outside hw.lisp and three leak one name each, listed
above.

**1. A device is a value. Done.** A `device` record holds the page's base
and an owner; register names are offsets, and `(dev-reg d off)` is the only
way to turn one into an address. `sys` and `timer` are converted.

One correction to the plan as written: Exec cannot "claim" `sys` and `timer`
and be checked against the running task, because Exec is not a task - it runs
inside whichever task called it, or inside the trap handler with the
interrupted task still in s2. So the owner is one of three things: `kernel`
(never claimed, not checked, reached only through hw.lisp's functions and not
exported), nil (a driver's device nobody has claimed yet, usable by whoever
holds it, which keeps pre-driver code working), or a task (claimed; every
other task is refused). `rem-task` releases what a dying task held, and a
resume releases every claim, because every task that made one is gone.
`(devices)` checks it.

**2. disk.driver. Done.** The controller is asynchronous now, like the
blitter: a command latches, the status reads busy until its time is up, and
the bytes move at the end. `disk.driver` is a resident - Exec starts it at a
cold boot and again after a resume - that holds the disk, sleeps on the
completion interrupt, and answers requests. Saving an image is a request: the
collection and every region's write run in the driver's task with interrupts
off, the transfers watched rather than slept through, and the task that asked
sleeps until it is done.

Three things turned up on the way, and none of them is about the disk:

- **`error` halted the machine.** The slot it calls through had never been
  filled in, so every error message on the machine was followed by a halt.
  It traps now and goes where a type error goes: a backtrace, then the prompt
  or the end of the task.
- **A caller could be left blocked for ever.** Fixed as described under
  *Death* above.
- **A task woken by an interrupt waited for the next tick** even when it
  outranked the task that was running. The interrupt handler now switches on
  the way out, which is what Exec does, and it is why the driver answers when
  the disk does rather than up to a quantum later.

`(drivers)` checks all of it, and lmdev checks the controller on its own.

**3. input.driver. Done.** A resident task with a decode vocabulary, as
above. `inp-ctrl` is back inside hw.lisp and no client reads the chip: the
workbench gets messages, and xeyes reads the position the driver keeps. Two
general pieces came with it. A server can have work that arrives as an edge
rather than a message: its device's interrupt notifies the server's own port,
and `server-poll!` runs on every wake, so a driver has one blocker and still
hears both its device and its clients. And the chip has a loopback register,
so `(drivers)` can type a key and watch two listeners both receive it.

One trap on the way: the words an event is made of are symbols, and a symbol
read in one package is not the symbol of the same name read in another. The
first version sent `input::key` to a workbench comparing against `wb::key`,
and every event would have been ignored. The vocabulary is exported from
`input` now, so there is one `key`.

**- Bitmaps. Done**, and it took the place of a phase that was going to build
a registry in the chip. See *a bitmap is a type, not an address*. Nothing
downstream depends on it any more, which is why the numbering below moved up.

**4. The blitter's descriptor chain and cost model. Done.** The chip walks
the `next` word, so a blit is queued by linking it onto the last one:
`blit-go` no longer waits for the chip to be idle, only for its own
descriptor to be free. Each task has a ring of eight descriptors, for the
reason given when this was planned - the chip reads a descriptor when it
reaches it, so one cannot be refilled until the chip has finished it.

The linking is written the way it has to be on hardware, where the chip runs
while the processor links: link only while the chip is busy, then look again
and start it if it went idle without taking the new descriptor. And the chip
reads a descriptor's link before it writes its status, so a descriptor its
owner sees as done is one the chip has entirely finished with.

The cost is bandwidth now: a row is a burst with a setup cost, partial words
at the ends are whole words, XOR, AND, OR and ADD read the destination before
writing it, and each descriptor is fetched and written back. The constants
are at the top of blit.rs and assume a 32-bit path at the machine's clock,
about 80 MB/s, to be replaced by measurements from the real part. MASK is
costed as a copy, not a read-modify-write as this plan first said: skipping
transparent bytes is what byte enables on a write are for.

**5. gfx.driver. Done.** A resident task that holds the display chip.
`gfx-ctrl` is back inside hw.lisp, and Exec no longer touches the display to
get its frame clock: the driver turns the vertical blank on. Clients ask for
screens and palettes, and the workbench's twenty-two palette writes are one
request.

The part this plan called completion signals: `blit-sync` used to spin on
the status register. Now it spins briefly - a small blit is done before a
sleep could be arranged - and then sleeps on a signal. The chip can raise its
line after every descriptor as well as at the end of the chain, and does
while anybody is asleep; the driver's interrupt server wakes whoever's
descriptor is done. The chip reads its control register when a descriptor
finishes, not when it started, so a task that asks to be woken is woken by
the transfer that was already running when it asked. With interrupts off, or
inside an interrupt server, waiting is still a spin, because nothing could
wake a sleeper.

Two things came out of it. `wait-vblank` had not been the kernel's since the
first commit: demo.lisp defined one of its own, and since the prompt's
package uses exec the name was the same symbol - so the demo's version, which
polls the frame counter and sleeps the processor in between, replaced Exec's
for every task, the compositor included. Now the compositor waits on a
signal like everything else. And bitmap allocation did not move behind the
driver, for the reason under *gfx.driver* above.

**6. The blitter's chain register. Done.** The blitter is a device value like
the others, owned by the kernel because every task blits. `blt-list`,
`blt-status` and `blt-ctrl` are taken out of it through `dev-reg`, once, and
none of them is exported: the only way onto the chain is `blit-go`. The last
of the three names is back.

There is no flag day. Each phase takes one address out of circulation and
leaves the machine strictly harder to misuse than it was.

**7. The console split. Done.** See *The uart is the honest exception*. The
whole suite now reaches the host through console.driver a line at a time, and
a self-hosting rebuild, which must not go through it, still works.

## What this does not fix, and one thing it makes worse

- **It is not memory protection, on purpose.** A task can still write anywhere
  with an ordinary store. Closing that means a supervisor, and the point of
  this machine is that one address space is safe because of what the language
  will let you say - so the peripherals are closed by making them values that
  have to be held, and the language is left open.
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
  blocked on a dead driver get an error rather than silence. Built: `(drivers)`
  does the last three, and `(devices)` the first two.
- The blitter registry test went with the registry. What replaced it is
  structural: a blit names bitmaps, a bitmap is a byte object that knows its
  length, and every rectangle is clipped to it before a descriptor is filled,
  so the command that corrupted the machine three sessions running cannot be
  written through the API at all. What is left is hw.lisp's own arithmetic,
  which `LM_BLIT_GUARD` checks when asked.
- And the negative test, the one that is run every day: the workbench, two
  shells, a line typed through input.driver, a collection, a save through
  disk.driver, every line of output through console.driver - and nothing
  reported. That is the suite, and it takes about a second.
