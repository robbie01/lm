# Devices and drivers

A peripheral is reached through a capability to its page, which stays in
the kernel's hands. What a driver holds, and anything may hold and pass, is
a device: the page sealed with otype 5. Only the accessors generated for
each chip open a device, each for its own chip, so **a safe accessor only
ever touches a register of the device it was written for.** A driver is
the task that holds its device, and the way for anything else to reach one
is the way the rest of the system talks to anything: a message to a task.

## Four kinds of peripheral

The mechanism a peripheral gets depends on the shape of its traffic.

**Kernel-owned: `sys` and `timer`.** The timer is the scheduler's quantum
and the timebase; `sys` is interrupt control and the halt line. Their pages
stay in the kernel block, hw.lisp's functions reach them there inside
`unsafe`, and exec.lisp calls those. They have no accessors and no device.

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
capabilities; arbitration is the chip walking a chain of descriptors. Its
device is anybody's: hw.lisp takes it once, and the chip checks every
capability a descriptor hands it.

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

A device page is memory above the top of RAM, and the only way to it is its
capability. The reset stub mints one for every device, from the root, into
the kernel block, which only code inside `unsafe` can reach (see
[cheri.md](cheri.md)). `mmio-base` and the device numbers are exported with
the rest of the memory map, so a program can compute a register's address,
but an address is a number, and a number is no authority.

A device's page is a capability bounded to its 4 KiB, with LD and SD, and SC
too for the two chips with a capability register, the blitter and the disk.
A register is an ordinary load or store through it, as RVY has it: holding
a page is the authority over the device, and whatever holds one is part of
that device's trusted base. A register offset that leaves the page is a
bounds fault, never a store into the next device, and a capability store
through it writes a capability register; every other register refuses a
capability, and only the display's scan-out register and the blitter's
list register, the descriptor it is working on, hand one back.

**A device is its page sealed.** hw.lisp mints one key to otype 5, the
devices' otype, as it mints the blitter's to otype 4, and keeps it in two
closures, both unsafe names: `device-seal`, which seals a page, and
`device-open`, which unseals a device and checks that its page's base is
the one asked for, and traps otherwise. One otype serves every device: the
base is the class, which is sound while every device has a fixed address,
as on this machine, which has no PCI and plans none. A device whose address
could not be known would be sealed as a {class, page} pair instead, and
only `device-open` and the accessors' generator would change.

A driver's start takes its device, the one unsafe act in a driver:

    (let* ((dev (unsafe (device dev-disk)))
           (s (make-server "disk.driver" 10 (lambda (body) (serve dev body)))))
      ...)

**The accessors are generated.** `lmforge layout` writes lisp/devices.lisp
from the register tables in src/dev/*.rs: for the display, the input chip,
the blitter and the disk, the base of the page and, for each register, a
reader, a setter or both, by what the register does:

    (define (disk-block! dev v) (unsafe (%cap-st-word! (device-open dev disk-page-base) d-block v)))

Each opens the device it is handed for its own chip and touches one
register, both in a block of its own, which is the accessor's whole body. Handed another chip's device, or a bare
page, it traps; so a device can be passed anywhere, as an argument, in a
message or in a closure, and the worst it can do in the wrong hands is make
an accessor trap. A driver uses nothing but the accessors and the helpers
in hw.lisp built on them, and a raw page never leaves hw.lisp and the
kernel. An interrupt server captures the device it needs when it is made,
as any closure captures what it uses.

What this promises is exactly that a safe accessor only ever touches a
register of the device it was written for. It keeps a driver from touching
the wrong chip by accident; it does not keep a program from escalating on
purpose, which is what `unsafe` is for, and opening a device without an
accessor takes `unsafe`. Whoever holds a device holds as much as its chip
gives: the disk's reaches every block, so it is as much as a file system,
and the input chip's types for whoever is at the keyboard, so it is as much
as `eval`. See "Around the model" in [memory-safety.md](memory-safety.md).

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

The chips that reach memory are handed capabilities, not numbers, and
refuse what those do not cover (below). The display is handed the pixels'
capability in its scan-out register, the third capability register, by
`gfx-show`, and shows only what it lets the chip read: tagged, unsealed,
with LD, and covering every row the width, height and pitch describe. A
bitmap it may not read shows as a blank screen, and `gfx-status` says which
check failed, as a `refuse-*` code, or 0. The chip keeps the capability for
as long as it shows the bitmap, and an `LY` from the scan-out register hands
it back, which is how the collector keeps the bitmap on show alive whatever
else lets go of it.

Drawing goes through a rastport: a bitmap, an origin and a clip region.
Every rectangle is clipped to the region and the bitmap before a descriptor
is filled.

## The blitter

The chip walks a chain of descriptors in memory. A descriptor is
`blit-list-size` bytes, a field to each 8-byte slot: three capability
slots, the source, the destination and the link to the next descriptor,
each written with a capability store so that it keeps its tag; then width,
height, the two strides, a value, the operation, a line's two ends and a
done word, each a machine word in the low half of its slot, so the slot
reads as a fixnum. The list register is a capability register: a capability
store of a descriptor's capability starts the chain there, and a capability
load hands back the descriptor the chip is working on, which the
collector's roots read. Each task has a ring of eight, a vector of a slot
saying which is next, the eight descriptors after it and the task it is
for, held by the task's binding of `*blit-ring*`: a binding is anybody's
to set, so a ring made for another task is not used. The collector has
one of its own.

The chip checks what it is handed, as the processor would. It loads each
slot the way `LY` does through the descriptor's own capability, which must
cover the descriptor with LD and SD. A source needs LD and a destination SD,
and LD as well for an operation that reads it; every byte the rectangle
touches, rows and stride included, must lie inside the capability's bounds,
and for a line every byte of the box its ends make. A transfer that fails
any check is not made: its done word is `blit-refused-src` or
`blit-refused-dst` with the check that failed in the low byte, one of the
`refuse-*` codes, and the status register keeps `blit-status-refused` until
it is cleared. The descriptor completes either way, so nothing waits for a
blit that will never land. A
link that is no capability ends the chain; one the chip may not follow ends
it as refused. When it finishes a descriptor the chip clears its three
capability slots, so a finished descriptor holds no authority over anything.
Until then the descriptor's slots are a vector's, and the collector marks
through them as through any vector: a bitmap dropped while a blit into it
is still running stays alive until the blit has landed. A ring lives as
long as its task's binding, and a task that ends waits for its ring to
drain first, so no descriptor the chip has yet to finish is ever garbage.

A bitmap's pixels are handed over as their byte object's capability, moved
to the first pixel, so building a descriptor names no memory by number. A
descriptor is read by the chip once it is linked, so `blit-descriptor` and
`blit-go` stay unsafe names, and everywhere another task could read one,
a ring in a binding, the chain's tail in a global, a sleeper's descriptor on
the completion server's list, it is sealed with an otype of hw's, with a
key hw mints and keeps in its own closures: the capability to an open
descriptor exists only while it is being filled. The rectangle calls in
hw.lisp, which take bitmaps, are how everything else blits.

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
`uart-hex`, `uart-nl`) write the registers directly, each a block, and a
stream of nil means the raw line. They work before Exec exists, inside a
trap handler, and with the scheduler in pieces, and they are what the
collector and the fault reports use. `console.driver` owns the ordinary
console: it writes whole lines and owns the receive side, as the line's one
reader. It writes and reads through the raw path too, which stays open.

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
language. Every driver has the same shape:

- **The device** is taken when the driver starts, `(unsafe (device
  dev-disk))`, and handed to the handler, the poll and anything else that
  needs it.
- **Register access** is through the generated accessors, each opening the
  device for its own chip.
- **Logic**, parsing a request and keeping the driver's books, is public,
  handed the device, and called by name so that it can be patched while the
  driver runs: `serve`, `poll`, `decode`, `show-screen`.
- **The task loop is thin**: `make-server` runs `server-loop`, and the
  handler it is given calls a named step, `(lambda (body) (serve dev
  body))`.
- **Clients only send messages**, carrying data and capabilities to
  memory, never a device's page.

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
until then, so the buffer cannot be collected under it. A block number is
the whole disk's, the image's blocks included, so `read-blocks` and
`write-blocks` are declared unsafe, and the image writer is the site that
says `unsafe` to take the disk's device and write raw blocks. `exclusive`, declared unsafe
too, runs a job in the driver's task with interrupts off, with every
transfer watched rather than slept through; saving an image is one such
job, since the collection and every region's write must happen with nothing
else running.

**input.driver** (lisp/input.lisp): holds the input chip, decodes raw
events into lists and sends every subscriber a copy: `(key down ascii code
mods)`, `(key up ...)`, `(mouse moved x y)`, `(button down n x y)`,
`(button up n x y)`, `(wheel delta x y)`. A pointer event carries the
position it happened at. Where the pointer is now is not a message: the
driver keeps it in variables anybody may read. The chip has a loopback
register, so a test can type a key, and `inject` is declared unsafe, since
it types for whoever is at the keyboard.

**gfx.driver** (lisp/gfx.lisp): holds the display chip: `(screen w h)`,
`(show)` after a resume, `(colours pairs)`, `(present)`. It turns the
vertical blank on, and its interrupt server wakes tasks whose blits have
landed. It does not own drawing and does not hand out bitmaps.

**console.driver** (lisp/console.lisp): `(write string)` and `(read port)`.

**Exec** keeps `timer` and `sys` and is not a task.

Each driver is a resident: registered with `add-resident` when its file
loads, started by `exec-init` at a cold boot and again after a resume. A
driver is running exactly when `server-running?` says its server is, a task
of this Exec that has not ended, which covers a driver that ended and a
resumed image whose driver belonged to an Exec that no longer exists. While
no driver is running, a call is an error.

## A driver's life

- **Start**: `start` makes the server, and `make-server` makes the task,
  gives it its port and only then starts it, so a client that can reach the
  port is asking a running driver.
- **Run** for the driver's life. A handler that fails answers with the
  failure and the server starts again on a clean stack.
- **End** with the task. Anything a driver put outside itself, its
  interrupt server, comes back through `on-task-end`. A message to a task
  that has ended is answered with a failure at once, `remove-task` answers
  everything still queued on the dead task's ports, and a message stays on
  its port until it is answered, so the one the driver was working on is
  answered too. `request` turns a failure into an error in the caller.
  Nothing has to be given back: the device is a value, and the page stays
  in the kernel block.

## What this does not do

- Privileged code holds whole regions. The collector, the kernel and the
  image writer can write anywhere in theirs, can take any device's page,
  and can hand a chip a capability to a region; the chip then moves
  whatever that capability covers. What keeps that to those few places is
  that the kernel block and the root are unsafe names. Nothing stops
  unsafe code reaching a device a driver serves: two users of one device
  is a bug only unsafe code can write.
- A driver's port is anybody's to send to, so a safe program can send the
  request a declared call would have sent; see "Around the model" in
  [memory-safety.md](memory-safety.md). Availability is not a goal: anyone
  can send a driver garbage, and the driver answers with an error.
- Ports have no priority, so a low-priority client's request sits in front
  of a high-priority client's. `wait-ports` starts its scan one port further
  along on each call, so a busy client cannot starve a quiet one.
- A message costs about an eighth of its round trip in allocation. A driver
  on a warm path should keep a message per client rather than make one per
  call.
- Two context switches per operation more than a direct call, which is why
  the granularity rule above matters.

`(devices)` checks this at the prompt: a page is its device and no more,
the compiler will not take a page, seal one or open a device outside
`unsafe`, an address is no device, a device is its page sealed and nothing
loads or stores through it, its own accessor reads it and another chip's
traps, as does a bare page, the printer names it, no driver holds a page, a
chip refuses a sealed capability for memory, a task's registers are sealed,
and nothing reachable from any global by loading through capabilities, the
way a program that says nothing unsafe can, is a device's
page. `(drivers)` checks the drivers end to end, a disk read into a buffer
too small for it among them, and that with the driver gone there is no
disk; it needs a disk. `(blitting)` checks that the blitter refuses a
descriptor whose capabilities are too small, a number or missing a
permission, and moves nothing. `(capabilities)` checks, among the rest of
what the processor guarantees, that a device's capability is its page and
no more, and that only a capability register takes a capability.
