# Devices and drivers

Every peripheral has one owner, reaching one you do not own is refused, and
the way to reach one is the way the rest of the system talks to anything: a
message to a task.

## Four kinds of peripheral

The mechanism a peripheral gets depends on the shape of its traffic.

**Kernel-owned: `sys` and `timer`.** The timer is the scheduler's quantum
and the timebase; `sys` is interrupt control and the halt line. Only
exec.lisp and hw.lisp touch them, and the owner recorded on the device is
the kernel.

**Driver-owned, request and reply: `disk`, and the mode-setting half of
`gfx`.** Traffic is infrequent and each operation is large, so a request
round trip is noise beside the operation.

**Driver-owned, notify: `input`, the vertical blank, disk completion.** The
driver's interrupt server posts an edge to a port with `notify`, which
allocates nothing, and the client wakes on its own signal mask along with
everything else it is waiting for.

**Shared, and made safe by its arguments: `blit`.** Sixty or more blits a
frame from several tasks into disjoint memory. Safety comes from a blit
naming bitmaps rather than addresses, and the chip being handed their
capabilities; arbitration is the chip walking a chain of descriptors.

## The two numbers that shape the design

Measured under the workbench, before the port to capabilities:

    a request round trip (send, block, reply, wake)      9,680 cycles
    a small blit, all in (clip, take a descriptor,         850 cycles
      fill it, link it)
    of which talking to the chip                           137 cycles
    one composite pass, 66 blits                       783,454 cycles

A message was eleven times a whole small blit and seventy times the part
that talks to the chip. After the port a round trip at the prompt, to a
server that answers at once, is 7,060 cycles, which changes nothing below.
The unit of work sent to a driver is a whole operation, never a primitive.
Where a client needs the hardware inside its own hot loop, messaging is the
wrong tool and the safety has to come from the arguments.

## Enforcement is the processor

A device page is memory above the top of RAM, and the only way to it is by
number. Naming memory by number is a privilege: an integer load or store
goes through DDC and needs SR, which only code compiled `unsafe` has (see
[cheri.md](cheri.md)). `mmio-base` and the device numbers are exported with
the rest of the memory map, so a program can compute a register's address,
but an address is a number, and a program that says nothing unsafe can
store only through capabilities it was handed. None of those reaches a
device.

A device is a value:

    (defrecord (device dv) name base owner)

The record holds the page's address as a number, which is no authority.
`dev-page` makes the authority, only for the task that holds the device: a
capability bounded exactly to the device's page, with LD, SD and SC and
nothing else. `dev-ld` and `dev-st!` load and store a register through it,
and a capability store through it writes a capability register; every
other register refuses a capability, and no register hands one out. A
register offset that leaves the page is a bounds fault, never a store into
the next device. The capability is made afresh for each use and never
stored: a record field or a global can be read by anyone who can name it,
so a device capability kept in one would be a device anybody could reach.
Making one is a few instructions and allocates nothing, which is what lets
the trap handler and interrupt servers use the same path. `dev-page` and
the functions that reach memory by number are unsafe names.

The owner is one of three things: `kernel` (never claimed, reached only
through hw.lisp's own functions), nil (a driver's device nobody has claimed,
usable by whoever calls, which is what keeps the machine working before
Exec is up and between a driver ending and the next one starting), or a task
(every other task is refused). `remove-task` releases what a task held, and
a resume releases every claim, because every task that made one is gone.

## A bitmap is a value

A bitmap holds its pixels as a byte object:

    (defrecord (bitmap bm) pixels w h)
    (define (alloc-bitmap w h) (make-bitmap (make-bytes (%* w h)) w h))

`make-bitmap` checks once that `w * h` fits in the object. The pixels are a
capability with LD and SD whose bounds are exactly the pixels, so a bitmap
cannot be forged from an address, and a store the processor makes outside
it is a bounds fault. Glyphs, plots and the demos that walk a bitmap store
into the pixels at `bm-index`, with no `unsafe` anywhere. The collector
frees the pixels when the last reference goes, so closing a window drops it
from the list and does nothing else, and a new bitmap starts zeroed.

The chips that write memory are handed capabilities, not numbers, and
refuse what those do not cover (below). The display chip only reads: it is
handed the pixels' address, which is good for ever because objects never
move, and `gfx-show` takes it from a bitmap.

Drawing goes through a rastport: a bitmap, an origin and a clip region.
Every rectangle is clipped to the region and the bitmap before a descriptor
is filled.

## The blitter

The chip walks a chain of descriptors in memory. A descriptor is
`blit-list-size` bytes: three capability slots, the source, the destination
and the link to the next descriptor, each written with a capability store
so that it keeps its tag; then width, height, the two strides, a value, the
operation, a line's two ends and a done word, each a machine word. The list
register is a capability register: a capability store of a descriptor's
capability starts the chain there. Each task has a ring of eight in the
pool, and the collector has one of its own.

The chip checks what it is handed, as the processor would. It loads each
slot the way `lc` does through the descriptor's own capability, which must
cover the descriptor with LD and SD. A source needs LD and a destination SD,
and LD as well for an operation that reads it; every byte the rectangle
touches, rows and stride included, must lie inside the capability's bounds,
and for a line every byte of the box its ends make. A transfer that fails
any check is not made: its done word is `blit-refused-src` or
`blit-refused-dst` with the capability fault in the low byte, and the status
register keeps `blit-status-refused` until it is cleared. The descriptor
completes either way, so nothing waits for a blit that will never land. A
link that is no capability ends the chain; one the chip may not follow ends
it as refused. When it finishes a descriptor the chip clears its three
capability slots, so a finished descriptor holds no authority over anything.
So the tagged granules of the tasks' rings, which hw lists in `*blit-rings*`,
are exactly what blits in flight hold, and the collector takes them as
roots: a bitmap dropped while a blit into it is still running stays alive
until the blit has landed.

A bitmap's pixels are handed over as their byte object's capability, moved
to the first pixel, so building a descriptor names no memory by number. A
descriptor is pool memory that can hold capabilities, written under the
chip once it is linked, so `blit-descriptor` and `blit-go` stay unsafe
names: rings, the chain's tail and the waiting functions name descriptors
by number, and the capability to one exists only while it is being filled. The rectangle calls
in hw.lisp, which take bitmaps, are how everything else blits.

A blit is queued by filling the next free descriptor of the ring and linking
it onto the chain. Linking follows the hardware rule: link only while the
chip is busy, then look again and start it if it went idle without taking
the new descriptor. The chip reads a descriptor's link before it writes the
descriptor's done word, so a descriptor its owner sees as done is one the
chip has finished with.

The chip is asynchronous. A commit returns in a few hundred cycles; the
transfer happens on the chip's clock, charged by bandwidth: a row is a burst
with a setup cost, partial words at the ends of rows cost whole words, XOR,
AND, OR and ADD read the destination before writing it, and each descriptor
is fetched and written back. The constants are at the top of
`src/dev/blit.rs` and assume a 32-bit path to memory at the machine's clock:
the blitter is a bus master on the processor's bus, so its cost is in
processor cycles, and the machine is a 200 MHz part, so that is 800 MB/s. A
refused transfer costs only its descriptor. Until a transfer lands the
destination holds its old contents.

`blit-sync` waits for this task's last descriptor: a short spin, then a
sleep on `sigf-blit`, which `gfx.driver`'s interrupt server raises when the
descriptor is done. With interrupts off or inside an interrupt server the
wait is a spin. `blit-drain` waits for the chip to go idle. `bm-plot` and
`bm-point` sync before touching a pixel; anything else that reads or writes
pixels directly calls `blit-sync` first.

## The uart is the exception

The raw serial functions in runtime.lisp (`uart-string`, `uart-num`,
`uart-hex`, `uart-nl`) write the registers directly, and a stream of nil
means the raw line. They work before Exec exists, inside a trap handler, and
with the scheduler in pieces, and they are what the collector and the fault
reports use. `console.driver` owns the ordinary console: it writes whole
lines and owns the receive side. Its claim on the device says who is
reading the line; it does not refuse the raw path.

The prompt's stream collects a line and hands it to the driver whole.
Wherever handing it over is impossible, in a trap handler, with interrupts
off, before the driver is up, it writes what it has collected raw and
carries on raw, so nothing comes out of order. It hands over what it has
before it waits for input. Input arrives a burst at a time: one key, or a
whole pasted script, read into a 4 KiB buffer the driver keeps.

A rebuild reads its sources from the console while it redefines the kernel,
so it must not wait on the driver: its output goes raw for the duration, and
its input is already in the stream, which it puts back before every form.

## What each driver is

A driver is a task with a port, and its request vocabulary is a small
language.

**disk.driver** (lisp/disk.lisp): `(read block n bytes)`, `(write block n
bytes)`, `(flush)`, `(size)`, `(exclusive job)`. Synchronous to the caller,
asynchronous to the device: the driver sleeps on the completion interrupt
and the client sleeps on its reply. A transfer names a byte object, never an
address, and the controller is handed the object's capability: its buffer
register is a capability register, a read into the buffer needs SD and a
write from it LD, and every byte of the blocks must lie inside its bounds,
or the command moves nothing and answers `disk-refused`. A read clears the
tags of what it fills. A command takes the capability out of the register
and drops it when it ends, and its caller is blocked holding the buffer
until then, so the buffer cannot be collected under it. Nothing in
disk.lisp is unsafe. `exclusive` runs a job
in the driver's task with interrupts off, with every transfer watched rather
than slept through; saving an image is one such job, since the collection
and every region's write must happen with nothing else running.

**input.driver** (lisp/input.lisp): owns the input device, decodes raw
events into lists and sends every subscriber a copy: `(key down ascii code
mods)`, `(key up ...)`, `(mouse moved x y)`, `(button down n x y)`,
`(button up n x y)`, `(wheel delta x y)`. A pointer event carries the
position it happened at. Where the pointer is now is not a message: the
driver keeps it in variables anybody may read. The chip has a loopback
register, so a test can type a key.

**gfx.driver** (lisp/gfx.lisp): owns the display chip: `(screen w h)`,
`(show)` after a resume, `(colours pairs)`, `(present)`. It turns the
vertical blank on, and its interrupt server wakes tasks whose blits have
landed. It does not own drawing and does not hand out bitmaps.

**console.driver** (lisp/console.lisp): `(write string)` and `(read port)`.

**Exec** keeps `timer` and `sys` and is not a task.

Each driver is a resident: registered with `add-resident` when its file
loads, started by `exec-init` at a cold boot and again after a resume. A
driver is running exactly when it holds its device, which covers a driver
that ended and a resumed image whose driver belonged to an Exec that no
longer exists. While no driver holds a device, a call does the work
directly.

## Ownership lifecycle

- **Claim** before the port is published: `make-server` makes the task,
  `claim-device-for` claims on its behalf, and only then is the task
  started. A client that can reach the port can rely on the driver owning
  the device.
- **Release** when the task ends. Devices come back through
  `release-devices-of`; anything else a driver holds, its interrupt server,
  through `on-task-end`.
- **Death.** A message to a task that has ended is answered with a failure
  at once, `remove-task` answers everything still queued on the dead task's
  ports, and a message stays on its port until it is answered, so the one
  the driver was working on is answered too. A handler that fails answers
  with the failure and the server starts again on a clean stack. `request`
  turns a failure into an error in the caller.

## What this does not do

- Privileged code still names memory by number. The collector, the kernel
  and the image writer can write anywhere, and can hand a chip a capability
  made from the root; the chip then moves whatever that capability covers.
  What keeps that to those few files is that the root is an unsafe name.
- The display chip reads its picture by number. It only reads, and it is
  pointed only at a bitmap's pixels.
- Ports have no priority, so a low-priority client's request sits in front
  of a high-priority client's. `wait-ports` starts its scan one port further
  along on each call, so a busy client cannot starve a quiet one.
- A message costs about an eighth of its round trip in allocation. A driver
  on a warm path should keep a message per client rather than make one per
  call.
- Two context switches per operation more than a direct call, which is why
  the granularity rule above matters.

`(devices)` checks ownership at the prompt and `(drivers)` checks the
drivers end to end, a disk read into a buffer too small for it among them;
the latter needs a disk. `(blitting)` checks that the blitter refuses a
descriptor whose capabilities are too small, a number or missing a
permission, and moves nothing. `(capabilities)` checks, among the rest of
what the processor guarantees, that a device's capability is its page and
no more, and that only a capability register takes a capability.
