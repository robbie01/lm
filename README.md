# LM, a Lisp machine

A RISC-V computer that boots into a Lisp image. The image holds its own
compiler and assembler, and everything above the emulator, the kernel, the
collector, the compiler and the graphics, is Lisp compiled to native RV32
code.

```
$ cargo build --release
$ ./target/release/lmforge build   # compile the Lisp sources into kick.img
$ ./target/release/lm              # boot it

LM 0.1 - a lisp machine
cons space 16384k pairs, object space 65536k, code 461k used
exec: 6 tasks
type (help) for what to try

> (define (fact n) (if (< n 2) 1 (* n (fact (- n 1)))))
fact
> (fact 12)
479001600
```

The `define` was compiled to RISC-V machine code by a compiler that is itself
RISC-V machine code in the image.

## What is here

Three separable parts: a machine, a forge that builds images for it, and a
bench that checks both. The runtime binary carries neither the bootstrap
interpreter nor the tests.

| binary | |
|---|---|
| `lm` | boot an image |
| `lmforge` | compile the Lisp sources into an image, or have an image build its successor |
| `lmdev` | conformance tests, benchmarks, and tools for looking inside an image |

| the machine | |
|---|---|
| `src/cpu.rs` | token-threaded RV32IMC core with the custom opcodes |
| `src/mach.rs` `src/run.rs` | registers, memory, CSRs, traps, the outer loop |
| `src/dev/` | uart, timer, display, blitter, input, block storage, the host window |
| `src/heap.rs` `src/image.rs` | object memory and the image format |
| `src/map.rs` | the memory map and the low-memory globals |
| `src/boot.rs` | loading an image and letting it run |

| the forge | |
|---|---|
| `src/forge/hostlisp.rs` | the bootstrap interpreter |
| `src/forge/read.rs` | the bootstrap reader: lists, and nothing else |
| `src/forge/mod.rs` | the build driver, and the generator for `lisp/layout.lisp` |
| `src/forge/compact.rs` | sliding object space down on the way into an image |

| the Lisp | |
|---|---|
| `lisp/packages.lisp` | every package, and the names it exports |
| `lisp/layout.lisp` | generated: the memory map, object layouts and device registers as constants |
| `lisp/core.lisp` `lisp/runtime.lisp` `lisp/macros.lisp` | the language: lists, numbers, strings, symbols, packages, allocation |
| `lisp/bignum.lisp` `lisp/table.lisp` `lisp/stream.lisp` | arbitrary precision integers, hash tables, streams |
| `lisp/read.lisp` `lisp/print.lisp` | the reader and the printer |
| `lisp/asm.lisp` `lisp/compile.lisp` | the assembler and the compiler |
| `lisp/gc.lisp` | the collector |
| `lisp/hw.lisp` | the chips: devices, bitmaps, rastports, the blitter |
| `lisp/sys.lisp` | the kickstart: traps, fault reports, the prompt, rebuild |
| `lisp/exec.lisp` | the kernel: tasks, signals, ports, mutexes, interrupts |
| `lisp/disk.lisp` `lisp/input.lisp` `lisp/gfx.lisp` `lisp/console.lisp` | the drivers |
| `lisp/snap.lisp` | writing an image from the running machine |
| `lisp/wb.lisp` `lisp/platinum.lisp` `lisp/font.lisp` `lisp/mono.lisp` | the workbench, its appearance and its fonts |
| `lisp/ui.lisp` `lisp/explorer.lisp` | Platinum controls, and a window onto every symbol in the heap |
| `lisp/eyes.lisp` `lisp/demo.lisp` | xeyes, the demos, and the test suites typed at the prompt |
| `lisp/boot.lisp` | the three assembly stubs; run by the forge, not compiled into the image |
| `lisp/boot0.lisp` `lisp/hostio.lisp` | what the bootstrap interpreter needs before the real reader is up |

| the bench | |
|---|---|
| `src/check/cpu.rs` | processor conformance |
| `src/check/asm.rs` | the Lisp assembler against an independent Rust encoder |
| `src/check/compiler.rs` | source in, machine code out, run, compare |
| `src/check/readers.rs` | name resolution across packages |
| `src/check/inspect.rs` | what is in an image |
| `src/check/reach.rs` | what each package's symbols can reach |

## The processor

`rv32imc_zba_zbb_zbs_zicond_xlm`, machine mode, with the CSRs a kernel needs
and one custom CSR. `Xlm` is the four custom opcodes below.

Dispatch is token threaded on the opcode: no predecode and no translation
cache, so nothing has to be invalidated when the compiler writes fresh code
into the heap and jumps to it.

```
16-bit forms   tok = (op[1:0] << 3) | funct3     ->  0 .. 23
32-bit forms   tok = 32 + opcode[6:2]            -> 32 .. 63
```

Every handler ends by fetching the next instruction, computing its token and
making an explicit tail call to the next handler, so each opcode has its own
branch site. The core runs at 300 to 500 MIPS on a current host.

The timebase is the retired-instruction count, not host time, so a run is
deterministic: the same image produces the same schedule every time, down to
the instruction a task is preempted on. A windowed machine sleeps through its
idle time on the host without moving its own clock.

### Values

One 32-bit word per value:

```
w == 0          nil. Also a valid pair whose car and cdr are nil.
w & 1 == 1      fixnum, value = (i32)w >> 1. Order preserving.
w & 7 == 0      pair.   car at [w], cdr at [w+4].
w & 7 == 4      object. header at [w-4], payload from [w].
w & 7 == 2      immediate: characters, the unbound marker, eof.
```

An object header holds the type in its low eight bits and the length in
slots above them. The types are symbol, string, vector, bytes, closure,
record, float, port, bignum and code.

### The custom opcodes

Four opcodes are used. Each checks its operands as it forms an address or a
result, so the check costs no extra instructions.

**custom-0: pairs and slots.** A word load or store whose funct3 says what
the base register must be. car and cdr are offsets 0 and 4 of the same
instruction.

```
funct3 0   lref rd, off(rs1)    rs1 must be a pair (nil allowed)
funct3 1   lobj rd, off(rs1)    rs1 must be an object
funct3 2   lvar rd, off(rs1)    lobj, and the word loaded must not be the
                                unbound marker: a variable read, which traps
                                with the symbol in mtval if nothing was stored
funct3 4   sref rs2, off(rs1)   rs1 must be a pair, and not nil
funct3 5   sobj rs2, off(rs1)   rs1 must be an object
```

**custom-1: indexed access.** funct7 carries the type the object must be, 0
for any object. One instruction checks the tag, the type, that the index is
a fixnum, and the bound in the header, then forms the address.

```
funct3 bit 0   store rather than load
funct3 bit 1   byte rather than word
funct3 bit 2   the index is a five-bit immediate in the rs2 field
```

The immediate form serves every record field, closure slot and record tag.
A closure's entry point is slot 0 of a closure object, so a call loads it
with `ldxi t2, t0, 0, t-closure`, and calling anything that is not a closure
traps with a report.

**custom-2: fixnum arithmetic.** Both operands must be fixnums; the one that
is not lands in `mtval`.

```
funct7 0x00   add sub mul div rem and or xor, wrapping at 31 bits
funct7 0x20   add sub mul, trapping on overflow
funct7 0x01   sll srl sra lt ltu eq, the compares leaving a raw 0 or 1
```

`+`, `-` and `*` are the trapping forms. The trap handler widens the
operation into a bignum and resumes after the instruction, so an integer that
fits costs one instruction and one that does not costs a trap. An operand
that is a bignum takes the same route.

**custom-3: constants and tagged memory.** A fixnum against an immediate
(add, and, or, shift by a constant), and a word or byte load or store through
an address held as a fixnum.

### Traps

RISC-V leaves causes 24 to 31 to the implementation:

```
24   wrong type          the value in mtval
25   index out of range  the index in mtval
26   fixnum overflow
27   division by zero
28   stack overflow      sp went below the stack-limit CSR (0x7c0)
29   write barrier       a checked store would overwrite the unmarked
                         pointer in mtval; see the collector
```

The handler decodes the instruction at the faulting pc and names the
operation and the value:

```
> (car 5)
*** car: expected a pair, got 5, at pc 1047944
> (vector-ref "abc" 0)
*** vector-ref: expected a vector, got "abc", at pc 104a1c0
> (let ((f 5)) (f 1))
*** call: expected a function, got 5, at pc 105e7d8
> (+ nil 1)
*** +: expected a number, got nil, at pc 1053b90
> (car undefined)
*** unbound variable: undefined, at pc 10479a0
> (ackermann 5 5)
*** stack overflow at pc 10611c4, value 20f0f0
```

The stack limit is set by the scheduler at each switch, 8 KiB above the
bottom of the incoming task's stack, and is enforced only with interrupts on:
the collector and the kernel run with them off and may be entered with the
stack nearly full.

Traps nest. `mscratch` names the frame a trap saves into: the running task's
context block at the outermost level, and a frame from an array of eight
below that. A trap inside the handler is normal, because the handler's own
arithmetic may widen. Nine deep halts the machine with exit code 9.

What the machine checks and what it does not, and what would make the
unchecked path high-friction, is in [docs/memory-safety.md](docs/memory-safety.md).

## Memory

```
0x0000_0100  low-memory globals (the lg-* names in layout.lisp)
0x0000_2000  the pool: raw memory for stacks, contexts, descriptors, bitmaps' tables
0x0100_0000  code space, 16 MiB, bump allocated, swept but never moved
0x0200_0000  cons space, 128 MiB, sixteen million pairs, compacted
0x0A00_0000  object space, 64 MiB, swept in place; the forge compacts it
0x0E00_0000  scratch
0xF000_0000  device pages, 4 KiB each
```

Four registers are dedicated for the life of the machine: `gp` and `tp` are
the cons allocator's bump pointer and limit, `s1` is the running function's
code object, and `s2` is the running task.

A fresh pair is four instructions and one branch. Each task allocates out of
its own run of cons space, carved 256 KiB at a time, so the sequence needs no
lock and a timer interrupt cannot land between two tasks' stores.

## Calling

```
a0..a7        arguments 0..7; 8 and up are pushed, so argument 8 is at 0(s0)
t0            the closure being entered
t1            the argument count, raw
a0            the result
s1            the running function's code object

s0 - 4        saved ra      raw
s0 - 8        saved s0      raw
s0 - 12       the closure
s0 - 16       saved s1
s0 - 20 - 4i  local slot i
```

Every word between `sp` and the closure slot is a tagged value. Only the two
raw words sit at fixed offsets. The collector and the backtrace both depend
on this: the frame chain alone describes every frame exactly.

Compiled code holds no heap addresses. A function reaches its symbols and
constants through its code object, which the prologue loads into `s1`, so a
constant is one load and an object can move without any instruction being
patched.

**Leaves.** A function that calls nothing builds no frame: `ra` survives, no
collection can start, and no callee can clobber its locals. Its locals live
in `s3` to `s10`, its caller's code object in `s11`, and its prologue is two
instructions. About seven functions in ten are leaves. Leaf-ness is decided
from the source before code is emitted, and checked afterwards by reading the
bytes: a leaf that writes `ra` is a build failure.

**Self-calls.** A function calling its own name, with the right number of
arguments and nothing local shadowing the name, reuses the closure in its
frame and jumps past its own arity check: two instructions rather than five.
Redefining a function does not reach the self-calls already inside it, the
same bargain the open-coded operators make.

**Open coding.** `car`, `+`, `<`, `vector-ref`, record accessors and about
sixty other operators compile to their instructions when called with the
right number of arguments. A comparison in a test position becomes the
branch. Redefining one of these does not affect code already compiled
against it.

## The language

Scheme-shaped, with Common Lisp's packages and a small record facility.

**Packages.** A package is a reading concern and nothing else: the reader
resolves a bare name in the current package, then in what the packages it
uses export, and interns a new symbol if neither has it. `pkg:name` reaches
an export and `pkg::name` reaches past the interface. The compiler resolves a
global to its symbol at compile time, so packages cost the running machine
nothing. `lisp/packages.lisp` declares every package and its export list,
and is read first on both sides of the bootstrap. The current package is per
task.

**Records.** `defrecord` writes the field names down once and produces the
slot numbers, the allocator, the predicate and the accessors:

```lisp
(defrecord (window win) x y w h title refresh keys task data rp bm front)
;; win-alloc  window?  win-x  set-win-x!  ...
```

An accessor is a function, and the compiler open-codes calls to it as a
type check and one indexed instruction. Slot 0 holds the type symbol, so an
accessor handed the wrong kind of record traps naming both ends.
`(include node)` puts another record's fields first, which is how a task is
also a list node; `open` marks a record others are built on, whose accessors
check only that they have a record.

**Fluid bindings.** Variables that are per task in truth, where output goes,
where input comes from, the current package, stay ordinary globals, and
`fluid-let` binds them. A binding is a `(place . value)` pair on a stack the
task owns; the scheduler exchanges each entry with its place on every
switch, which leaves the task's value in the place while it runs and the
outer value while it does not. A new task starts holding what its creator
held. An error does not unwind, so the prompt it lands in unwinds the
bindings back to where they stood when it started.

**Symbols.** Interning gives every symbol a dense identity in its flags
word, and `lisp/table.lisp` hashes on it: open addressing over two parallel
vectors. `gensym` makes uninterned symbols, printed `#:g1`, so a macro's
temporaries do not accumulate in the obarray; the image writer drops
interned symbols that hold nothing and that nothing reaches.

**Numbers.** Fixnums are 31 bits. Arithmetic that outgrows them promotes to
a bignum and demotes when the result fits again; `(fact 50)` is exact and
`(ash 1 100)` is 2^100. Bignums are sign-magnitude with 32-bit limbs, worked
sixteen bits at a time because a Lisp value cannot hold a limb. Three
explicit families exist for code that must not promote: `wrap+`, `strict+`
and `sat+` with their `-` and `*` forms. A machine word is not a fixnum:
`peek` reads a word unsigned, `peek-signed` reads it signed, and `poke`
stores the low 32 bits of either.

**Unsafe.** The ordinary vocabulary is checked by the processor: a wrong
argument is a typed error, never a corrupted word. The raw vocabulary, the
loads and stores through an address, `%addr-of` and `%from-addr`, `%slot`,
the machine-state instructions, and the functions that hand out raw memory
such as `peek`, `poke`, `alloc-pool` and `dev-reg`, is marked: each such name
carries a bit in its symbol, and the compiler refuses a call to one, or a
reference to one as a value, unless the site is inside an `unsafe` form or
the file said `(unsafe-file)` after its `in-package`. The collector, the
kernel, the chips and the object system are unsafe files; everything else
writes `(unsafe ...)` at the place it says a raw thing, so every such place
can be found. `unsafe-names` marks a package's own raw functions. The rule
in one sentence: code that does not say it is unsafe cannot fault the
machine. What is checked and what is not is in
[docs/memory-safety.md](docs/memory-safety.md).

**Errors.** There is no condition system. `error` prints its message and
traps; the handler composes a report with a backtrace into a string, then
rewrites the faulting task's context so that it returns into the prompt's
restart on a clean stack, which prints the report. A task with no prompt
behind it ends. Nothing on the abandoned stack runs again; a mutex held
there is marked abandoned and handed on.

## The collector

Mark, then sweep in place, in slices. A collection is a cycle:

- **start**: interrupts off for one short stretch. Every task's stack is
  scanned precisely from its frame chain and its saved registers
  conservatively, the globals are pushed, and the write barrier goes on.
- **marking**: the mark stack is traced a slice at a time, about a hundred
  thousand cycles each, with interrupts on in between. The idle task does it
  when nothing else wants the processor; whoever is allocating does a share
  in proportion to what it allocates.
- **sweeping**: dead objects go into the free bins and dead runs of pairs
  become runs for the allocator, a slice at a time, the barrier off.

The write barrier is an instruction-level check in the processor (`gcmode`,
CSR 0x7c1). While it is on, a checked store (`sref`, `sobj`, `stx`, `stxi`)
that would overwrite a pointer whose mark bit is clear traps with cause 29
before writing; the handler marks that pointer and the store re-executes. So
the collector sees a snapshot: nothing reachable when the cycle began can be
lost, because the last copy of a pointer cannot be overwritten unseen.
Everything allocated during the cycle is black from the start, a run of
pairs by marking the run when it is handed out, an object when it is taken,
so nothing new needs tracing and the roots are scanned once. A plain `sw`
does not go through the barrier, which is why every store the compiler emits
into a heap object is a checked one, including a `set!` of a global.

The allocator's slow path writes a mask of the live argument registers where
the collector can read it, so a collection begun there is precise across the
allocation. A task preempted mid-expression has live values in registers
whose types nothing recorded; those thirty-two words are scanned
conservatively and whatever they reach is pinned, which only the compactor
honours.

A cycle is scheduled by budget: when allocation since the last reaches
twice the live data or 8 MiB, whichever is more. The longest stretch with
interrupts off is a slice, a few hundred thousand cycles at most, whatever
the heap holds: `lm --stats` reports it. A heap with no room left is
collected to the end on the spot, and a rebuild does not collect at all
until it writes its image.

Objects and code are never moved by the machine: the collector is written in
the language it collects, and reaches its own functions and constants
through objects. Pairs are compacted only on the way into an image, by the
three-pass compactor in gc.lisp: plan where every live pair goes, rewrite
every pointer to its destination, slide. Forwarding is not stored per pair;
each 64-byte block of cons space records where the free pointer had reached
when the walk arrived, and a lookup replays the block with a popcount over
the mark bitmap. The image collection, `gc:collect-for-image`, also drops
idle symbols from the obarray, collects, compacts, reattaches the symbols
still reachable, and blanks everything reclaimed, so the file is the size of
what is in it.

## Building an image

`lmforge build` needs no image. A reader in Rust that makes lists and
nothing else, and a small interpreter, bring up the prelude; the last file
of the prelude is `lisp/read.lisp`, the reader written in Lisp, and from
there the bootstrap reads with that. The compiler, also one of the sources,
compiles the whole system into the same heap the interpreter has been
filling. The machine's own collector then runs on the machine, the forge
slides object space down, and what is left in memory is the image.

```
boot0 layout core macros runtime hostio stream read     <- read by Rust
packages gc hw exec asm compile boot                    <- read by read.lisp
```

Everything the Rust reader touches is one flat namespace, which is why the
split falls exactly at the prelude.

`lmforge rebuild` needs an image: it boots one, types the sources at its
console, and lets the machine compile them and write its successor. The
sources go through twice. `sys:rebuild` compiles them into the running
machine, so the compiler and macros doing the work are the new ones;
`sys:genesis` compiles them again with those, every definition going into a
table for the image; `snap:save-fresh` warm-resets the machine through its
reset stub into the image's own `finish-fresh`, which gives every symbol what
the table says, collects from the image's own roots, and writes the file. The
result is a fresh image, not an updated one.

```
lmforge build                       kick.img,  880 KiB
lmforge rebuild --from kick.img     next.img
lmforge rebuild --check             compile everything twice, collect, write nothing
lmforge compact [-f IMG] [-o OUT]   slide object space down in a saved image
lmforge layout                      regenerate lisp/layout.lisp from the Rust definitions
```

`lisp/layout.lisp` is generated on every build from `src/map.rs`,
`src/mach.rs`, `src/heap.rs` and the device files, so a Lisp constant for a
memory region, an object slot, a trap cause or a device register is never
written by hand.

## Exec

An Amiga Exec, in Lisp, in one shared address space with no MMU. Tasks with
32 signal bits and `wait`/`signal`; message ports on top of signals; mutexes
that belong to the task holding them; interrupt servers on the chips' lines.
There is no ExecBase: the lists are records held in variables. Sending a
message costs a pointer on a list.

The context switch is one CSR write. The trap stub saves all 32 registers
into the block `mscratch` names and restores from there on the way out, so
switching tasks is pointing `mscratch` at another task's block. Preemption is
the timer interrupt; a task that blocks asks for a reschedule with an
`ecall`, so the switch always happens inside the handler. Which task is
running is the register `s2`.

**Signals.** Three bits are fixed: `sigf-vblank` (5), `sigf-blit` (7) and
`sigf-mutex` (8), the same bit in every task, so waking every waiter is a
walk of the wait list. Every other bit from 0 to 29 is allocated with
`alloc-signal`; bit 30 would make a mask negative.

**Servers.** A driver is a task with a port. `make-server` makes the task,
gives it its port and only then starts it; `request` sends and waits for the
answer, `send` does not wait, `notify` is an edge with no message, which is
what an interrupt server posts because a server must not allocate. A handler
that fails answers its caller with a failure and the server restarts on a
clean stack; a task that ends has everything queued on its ports answered
with failures. `spawn` makes a dependent task that ends with its parent.

**Locking.** Three ways to share, in the order to reach for them: a port,
because something one task owns cannot be raced for; a mutex, for data
several tasks share and for any section that may have to wait; and
`without-interrupts`, for what an interrupt server touches and for the
kernel's own few-instruction sections. Nothing sleeps with interrupts off:
`wait`, `reschedule`, taking a mutex and the running task ending itself are
errors there. A mutex nests for its owner, only the owner unlocks it, waiters
queue in priority order and are handed it directly, a waiter lends the owner
its priority, and a wait that would close a circle is an error naming the
circle. A task that ends holding a mutex, or whose stack an error abandons
inside `with-mutex`, has it taken away, and the next taker is told.

**Time.** `sleep` waits for a number of milliseconds of the machine's clock,
and `wait-timeout` is `wait` with a deadline, answering 0 if the time passed
first. The clock is the count of timer interrupts, `now-ms`, which runs at
the same rate whether the machine is busy or idling through a jump, and the
same on every run; `millis` is the host's clock, for pacing to the host.
Deadlines sit on one list and the timer interrupt signals whoever's has come,
so they are met within a quantum. A task that draws waits for the vertical
blank instead.

**Idle.** The idle task is always ready and runs `wfi`, so a machine where
every task is waiting costs nothing.

## Drivers and the chips

Every device is a 4 KiB page of 32-bit registers at `0xF0000000` and up:
`sys` (halt, interrupt control, entropy), `uart`, `timer`, `gfx`, `input`,
`blit`, `disk`. Their register offsets are in the generated layout.

A device is a value with an owner. Register access goes through `dev-reg`,
which refuses a task that does not hold the device, and a task that ends
gives back what it held. `sys` and `timer` are the kernel's. The uart is
reachable raw by design, for the collector, the trap handler and a rebuild.

| driver | owns | requests |
|---|---|---|
| `disk.driver` | the controller | `(read block n bytes)` `(write block n bytes)` `(flush)` `(size)` `(exclusive job)` |
| `input.driver` | keyboard and mouse | `(subscribe port)` `(unsubscribe port)` `(inject ...)`; every subscriber gets every event |
| `gfx.driver` | the display chip | `(screen w h)` `(show)` `(colours pairs)` `(present)`; wakes tasks whose blits have landed |
| `console.driver` | the serial line | `(write string)` `(read port)`; whole lines, and a prompt that sleeps between keys |

A driver sleeps on its device's interrupt and the rest of the machine runs
meanwhile. A request round trip costs about 9,700 cycles, so the unit of
work sent to a driver is a whole operation, never a primitive: tasks link
their own blitter descriptors rather than asking a driver to blit.

**Bitmaps.** A bitmap's pixels are a byte object, so a bitmap cannot be
forged from an address, an overrun stays in object space, and the collector
frees the pixels when the last reference goes. Drawing goes through a
rastport, a bitmap with an origin and a clip region.

**The blitter** is asynchronous. A task fills a descriptor from its own ring
of eight and links it onto the chain; the chip walks the chain on its own
clock, charged by bandwidth, and writes a done word back into each
descriptor. `blit-sync` waits for this task's last descriptor, sleeping on
`sigf-blit` if the wait would be long; `blit-drain` waits for the chip.
Anything that reads or writes pixels directly calls `blit-sync` first.

Details of the model are in [docs/drivers.md](docs/drivers.md).

## The workbench

`(workbench)` opens a desktop in the Platinum appearance with a shell in a
window; `(new-shell)` opens another. Each shell is a task with a prompt of
its own, reading keys from a port and printing into its window.

Every window has two bitmaps. Its owner draws into the first; the second is
what the screen is made from, and the only way from one to the other is the
owner saying part of its picture is finished (`window-damage-rect`). The
compositor runs once a frame over the damage list, front to back, writing
every pixel once, so a picture part way through being drawn is never on the
screen and a pixel the display catches early is old, never wrong. Damage is a
short list of rectangles guarded by a mutex; most damage lies inside one
window and is one copy.

A drawing task calls `present`, which hands its window over and waits for
the next frame. The input task turns events from `input.driver` into raise,
drag and close, and sends everything else to windows: keys to the front
window, a button pressed in a window's content to that window until it is
released, and the wheel to the window under the pointer. A window's events
arrive on its port as messages in the window's own coordinates, so the task
that reads a window sleeps on one port for its keys and its clicks.

Controls live in the `ui` package: a Platinum scroll bar, a push button,
and an outline, which is a list of rows with disclosure triangles that open
onto more rows. A control is a record positioned in window coordinates; the
window's task draws it through the window's rastport and hands it the
window's events.

`(explorer)` opens an outline of every package; a package opens onto its
symbols, a symbol onto its value, function and property list, and a value
onto its parts: the elements of a list or vector, the fields of a record by
name, the code and free variables of a function, the literals of a code
object. `(explore x)` opens the same outline on any object, and return or a
double click on a row opens another explorer on what the row holds. The
arrows move and open rows, and the wheel scrolls.

The interface is set in Charcoal (the Virtue strike, 12 ppem) and shells in
MS Gothic's twelve-pixel halfwidth strike, six columns by twelve rows. A
glyph is drawn with one wait for the blitter and then plain
stores.

## Try it

```
(help)                what there is
(selftest)            compile a function on the machine and time it
(room)                heap and code usage
(gc)                  collect now
(tasks)               every task, its state and its priority
(workbench)           a desktop, with a shell in a window
(new-shell)           another shell window
(eyes)                xeyes; call it more than once
(explorer)            every symbol in the heap, in a window
(explore x)           any object, opened up
(mandelbrot)          fixed point, straight to the bitmap
(life 200)            Conway, with the blitter for the copy
(balls 6)             six tasks drawing into one window
(numbers) (words) (nesting) (talking) (locking) (blitting) (devices) (drivers)
                      the test suites; each prints nothing above its last line if all is well
(save-image)          write this machine to the disk given with --disk
bye                   stop the machine
```

A saved image resumes with its memory and none of its tasks: Exec is rebuilt,
the drivers start again, and the workbench restarts on the screen it had.

## Testing and looking inside

```
lmdev all             every suite
lmdev cpu             processor conformance
lmdev asm             the Lisp assembler against an independent Rust encoder
lmdev compiler        end-to-end: source in, machine code out, run, compare
lmdev readers         name resolution: use lists, pkg:name, pkg::name
lmdev check [IMG]     boot an image headless and run the machine's own suites
lmdev bench           measure the interpreter
lmdev inspect [IMG]   what is in an image, and that code holds no heap addresses
lmdev reach [IMG]     what each package's symbols can reach
lmdev eval EXPR       compile and run one expression
lmdev repl            a prompt on the bootstrap interpreter
lmdev fuzz            random input to the machine, the image loader and the
                      bootstrap interpreter (--target, --seconds, --seed, --replay)
lmforge rebuild --check   compile every source on the machine twice, then collect
```

The fuzzer's targets are the parts that take bytes from outside and handle
them with `unsafe`: random registers and code on a fresh machine, random
bytes as an image, random text through the bootstrap reader and evaluator
with the prelude loaded. Every input is written to `target/fuzz/last-*.bin`
before it runs, so a crash leaves its input behind for `--replay`. The
cargo-fuzz targets under `fuzz/` drive the same functions with coverage
guidance (`cargo fuzz run exec|image|lisp`); they need libFuzzer, which
links on Linux and macOS but not on Windows.

The machine's own suites are Lisp, typed at the prompt. `lmdev check` boots
an image headless with a scratch disk and types `(check)`, which runs every
one of them, counts, and halts the machine with the verdict as its exit
code; `lmdev all` includes it when `kick.img` is there. By hand, each suite
is a function, and `(drivers)` needs a disk:

```
lm kick.img --no-window --batch --disk scratch.disk \
   --script '(numbers)\n(talking)\n(locking)\n(blitting)\n(drivers)\nbye'
```

Instrumentation, all off by default:

```
lm --isaprof          a histogram of what executed, by opcode and custom form
lm --fnprof           which functions the instructions were spent in
lm --trace-traps      every trap the machine takes
lm --shot FILE        the final display as a PPM
LM_FNPROF=1 lmforge rebuild     the same profile of a rebuild
LM_FORGE_PROF=1 lmforge build   which interpreted function the forge spends its time in
LM_BLIT_GUARD=1       check every blit against the block it named
LM_WATCH_ADDR=hex     report every store to an address (LM_WATCH_LEN bytes)
LM_WATCH_HI=hex       report stores to one word, with the function that made them
LM_WATCH_S2=1         report every change of the running task
LM_TRACE_PAUSES=1     report, with a backtrace, every stretch with interrupts
                      off longer than a millisecond of host time
```

A screenshot of the workbench needs about four billion instructions of
`--budget` to finish drawing; a smaller budget shows a half-composited
screen.

## Known limits

- No condition system: an error abandons the stack and nothing on it runs
  again. There is no `unwind-protect`, `catch` or `dynamic-wind`.
- Floats are boxed and the compiler does no arithmetic on them.
- Bignums have no bitwise operations, and division is a bit at a time.
- Open-coded operators and self-calls do not see a redefinition.
- The machine never moves objects, code or, between images, pairs, so a
  long session can fragment the heap; holes in cons space smaller than 512
  bytes wait for the compactor, which only an image gets.
- Marking costs about 180 cycles a pair, and while a cycle is marking the
  program allocating pays for it, a dozen cycles per byte allocated.
- Thirty-two words per suspended task are scanned conservatively and pin
  what they reach.
- Calls with more than eight arguments are never tail calls.
- A rebuilt image carries the holes its replaced functions left in code
  space; `lmforge build` renormalises.

The open items, the API gaps and the performance risks are listed in
[docs/open-items.md](docs/open-items.md).
