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
naming bitmaps rather than addresses; arbitration is the chip walking a
chain of descriptors.

## The two numbers that shape the design

Measured under the workbench:

    a request round trip (send, block, reply, wake)      9,680 cycles
    a small blit, all in (clip, take a descriptor,         850 cycles
      fill it, link it)
    of which talking to the chip                           137 cycles
    one composite pass, 66 blits                       783,454 cycles

A message is eleven times a whole small blit and seventy times the part that
talks to the chip. So the unit of work sent to a driver is a whole
operation, never a primitive. Where a client needs the hardware inside its
own hot loop, messaging is the wrong tool and the safety has to come from
the arguments.

## Enforcement is scoping, not checking

A device page is reachable only by its address, and those addresses are
constants in hw.lisp. None of them is exported: no device register is named
outside that file. `mmio-base` and the device numbers are exported with the
rest of the memory map, so a program can compute a register's address and
store to it; that is the wild store, the general memory-safety problem,
which nothing here closes. There is no MMU and no supervisor by design: the
address space is safe because of what the language lets you say, and the
Rust side only observes.

A device is a value:

    (defrecord (device dv) name base owner)

`dev-reg` turns a register offset into an address only for the task that
holds the device. The owner is one of three things: `kernel` (never claimed,
reached only through hw.lisp's own functions), nil (a driver's device
nobody has claimed, usable by whoever calls, which is what keeps the machine
working before Exec is up and between a driver ending and the next one
starting), or a task (every other task is refused). `remove-task` releases
what a task held, and a resume releases every claim, because every task
that made one is gone.

## A bitmap is a value

A bitmap holds its pixels as a byte object:

    (defrecord (bitmap bm) pixels w h)
    (define (alloc-bitmap w h) (make-bitmap (make-bytes (%* w h)) w h))

`make-bitmap` checks once that `w * h` fits in the object. A bitmap cannot
be forged from an address; an overrun stays in object space, where a damaged
header is something the collector names; the collector frees the pixels
when the last reference goes, so closing a window drops it from the list
and does nothing else; and a new bitmap starts zeroed. Objects never move,
so an address taken from the pixels is good for ever, which is what lets one
be handed to the display register and the blitter.

Drawing goes through a rastport: a bitmap, an origin and a clip region.
Every rectangle is clipped to the region and the bitmap before a descriptor
is filled.

## The blitter

The chip walks a chain of descriptors in memory. A descriptor is a block of
`blit-list-size` words: source, destination, width, height, the two
strides, a value, the operation, a status word, a link, and a clip
rectangle. Each task has a ring of eight in the pool; an interrupt server
has a ring of its own.

A blit is queued by filling the next free descriptor of the ring and linking
it onto the chain. Linking follows the hardware rule: link only while the
chip is busy, then look again and start it if it went idle without taking
the new descriptor. The chip reads a descriptor's link before it writes the
descriptor's status, so a descriptor its owner sees as done is one the chip
has finished with.

The chip is asynchronous. A commit returns in a few hundred cycles; the
transfer happens on the chip's clock, charged by bandwidth: a row is a burst
with a setup cost, partial words at the ends of rows cost whole words, XOR,
AND, OR and ADD read the destination before writing it, and each descriptor
is fetched and written back. The constants are at the top of
`src/dev/blit.rs` and assume a 32-bit path at the machine's clock, about
80 MB/s. Until a transfer lands the destination holds its old contents.
When a descriptor finishes the chip writes a done word into it.

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
address, and the driver checks that the blocks fit. `exclusive` runs a job
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

- It is not memory protection. A task can write anywhere with an ordinary
  store.
- Ports have no priority, so a low-priority client's request sits in front
  of a high-priority client's.
- `wait-ports` answers the first ready port, so a busy client can starve a
  quiet one.
- A message costs about an eighth of its round trip in allocation. A driver
  on a warm path should keep a message per client rather than make one per
  call.
- Two context switches per operation more than a direct call, which is why
  the granularity rule above matters.

`(devices)` checks ownership at the prompt and `(drivers)` checks the
drivers end to end; the latter needs a disk.
