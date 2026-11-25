# LM, a Lisp machine

A RISC-V computer with CHERI capabilities, RVY, that boots into a Lisp image. The
image holds its own compiler and assembler, and everything above the
emulator, the kernel, the collector, the compiler and the graphics, is Lisp
compiled to native RV32 code.

The capability is the Lisp pointer. Every value in the machine is a
capability: an address, bounds, permissions, and a tag bit no program can
set. The tag is the difference between a pointer and a number, so nothing
ever has to guess which a word is. The bounds are the object, so a store
past the end of a vector is a fault, not a write into its neighbour.
Sealing is the closure: a closure can be called and cannot be opened, so
its environment is its own. There is one address space and no MMU, and
everything in it is reached through a capability somebody was handed,
except by way of the root, the one capability to all of memory. Only code
compiled `unsafe` may use the root, because `unsafe` is the processor's SR
permission.

```
$ cargo build --release
$ ./target/release/lmforge build   # compile the Lisp sources into kick.img
$ ./target/release/lm              # boot it

LM 0.1 - a lisp machine
cons space 8192k pairs, object space 65536k, 1600k used
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
| `src/cap.rs` | capabilities: the format, the bounds encoding, and the operations on them, shared by the processor, the forge and the bench |
| `src/cpu.rs` | token-threaded RV32IMC core in RVY's capability mode, with the Lisp instructions |
| `src/mach.rs` `src/run.rs` | capability registers, tagged memory, CSRs and the capabilities they hold, traps, the outer loop |
| `src/dev/` | uart, timer, display, blitter, input, block storage, the host window and the box filter it draws the display with |
| `src/heap.rs` `src/image.rs` | object memory, and the image format with its tags |
| `src/map.rs` | the memory map and the kernel block's slots |
| `src/boot.rs` | loading an image and letting it run |

| the forge | |
|---|---|
| `src/forge/hostlisp.rs` | the bootstrap interpreter |
| `src/forge/read.rs` | the bootstrap reader: lists, and nothing else |
| `src/forge/mod.rs` | the build driver, and the generator for `lisp/layout.lisp` |
| `src/forge/compact.rs` | sliding object space, machine code and all, down on the way into an image |

| the Lisp | |
|---|---|
| `lisp/packages.lisp` | every package, and the names it exports |
| `lisp/layout.lisp` | generated: the memory map, object layouts, permissions, kinds and device registers as constants |
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
| `lisp/boot.lisp` | the reset and trap stubs, in assembly; run by the forge, not compiled into the image |
| `lisp/boot0.lisp` `lisp/hostio.lisp` | what the bootstrap interpreter needs before the real reader is up |

| the bench | |
|---|---|
| `src/check/cpu.rs` | processor conformance |
| `src/check/asm.rs` `src/rvenc.rs` | the Lisp assembler against an independent Rust encoder |
| `src/check/compiler.rs` | source in, machine code out, run, compare |
| `src/check/readers.rs` | name resolution across packages |
| `src/check/display.rs` | the window's box filter, on this host's GPU, against its definition |
| `src/check/inspect.rs` | what is in an image |
| `src/check/reach.rs` | what each package's symbols can reach |

## The processor

RV32IMC with Zba, Zbb, Zbs and Zicond; RVY, the RISC-V CHERI extension, as
RV32Y in machine mode and always in capability mode, with a capability
encoding of LM's own; and Xlm, the Lisp instructions below. The CSRs are
those a kernel needs and five custom ones: the stack limit, the barrier's
switch, its two maps and the root. [docs/cheri.md](docs/cheri.md)
is the reference for all of it, and [docs/rvy.md](docs/rvy.md) says which
RVY this is and every place LM departs from it, and why.

Dispatch is token threaded on the opcode: no predecode and no translation
cache, so nothing has to be invalidated when the compiler writes fresh code
into the heap and jumps to it.

```
16-bit forms   tok = (op[1:0] << 3) | funct3     ->  0 .. 23
32-bit forms   tok = 32 + opcode[6:2]            -> 32 .. 63
```

Every handler ends by fetching the next instruction, computing its token and
making an explicit tail call to the next handler, so each opcode has its own
branch site. Each register caches where its capability reaches, its bounds
clipped to RAM, so a checked load or store is one mask test and one range
comparison. The core runs at about 300 MIPS on a current host.

The timebase is the retired-instruction count, not host time, so a run is
deterministic: the same image produces the same schedule every time, down to
the instruction a task is preempted on. A windowed machine sleeps through its
idle time on the host without moving its own clock, unless a key, a button
or the wheel wakes it.

### Capabilities

A capability is 64 bits and a tag. Memory keeps one tag bit per 8-byte
granule of RAM, out of band, where no load or store of data can reach it.

```
bits 31..0    the address
bits 63..32   metadata:
  31 LD  load data            27 LM  load mutable
  30 SD  store data           26 EX  execute
  29 LC  load capabilities    25 SR  system registers: RVY's ASR
  28 SC  store capabilities   24 SE  seal and unseal
                              23 HD  headed: a Lisp object
  22..19  otype: 0 unsealed, 1 sentry, 2 closure, 3.. sealed with a key
  18..0   bounds, CHERI Concentrate with a 10-bit mantissa
```

The instructions read and clear the permissions in RVY's bit field, where
LD, SD, LC, LM, EX and SR are R, W, C, LM, X and ASR, SE is S and U, and SC
and HD are Xlm's. Every length below 256 bytes is exact at any base; a
larger region is exact at the alignment `yamask` gives for its length, and
the allocators pad and align to it. A load through an authority without LC
drops the tag of what it loads, and one without LM takes SD, SC and LM off
it, so a read-only list hands out read-only tails. A capability store keeps
the tag only through an authority with SC, any other store clears the tags
it touches, and every integer instruction writes an untagged result: a
pointer cannot be made from its bits.

### Values

```
untagged, metadata 0     fixnum: the address field, 32 bits signed
untagged, metadata 1..5  character, the unbound marker, eof, void, the default marker
tagged, the nil cell     nil
tagged, no HD, 16 bytes  pair: car at 0, cdr at 8
tagged, HD               object: header in the granule below the base, payload in the bounds
tagged, HD, otype 2      a closure, sealed
tagged, anything else    a raw capability: an entry or a return address, a stack,
                         a device page, a cons run
```

nil is a capability to the 16 bytes at address 0, which hold nil twice, with
LD and LC and nothing else: `(car nil)` is nil because the cell says so, and
`(set-car! nil 1)` is refused because the capability says so. `eq?` is
exact equality of tag, metadata and address; a character and a fixnum with
the same payload differ in metadata.

An object's header word 0 holds the type in its low eight bits and the
length in elements above them; word 1 is zero. The capability to an object
is bounded to its payload and has HD, so the header is outside the bounds
and no holder of the object can write it. The types are symbol, string,
vector, bytes, closure, record, float, port, bignum, code and text, a
function's machine code. A string, a byte object or a text holds bytes, and
its capability has LD and SD only, so no capability can be stored in one;
every other type holds values in 8-byte slots.

### The instructions

RVY's own instructions sit on RVY-A (`0x7b`): reading a capability's
fields, setting its address and bounds, clearing permissions, sealing and
unsealing, building one from bits, and `ly` and `sy`, which move a whole
capability with its tag. The base loads, stores and jumps take a capability
as their base and check its tag, seal, permissions and bounds. A jump
leaves a sentry in its link register, a capability that can only be jumped
to, so a return address cannot be written through or moved. Where RVY
clears a tag rather than trapping, so does the machine: bounds a capability
does not allow, or a permission changed on a sealed one, leave the result
untagged, and the first use of it traps.

The Lisp instructions, Xlm, sit on custom-0 (`0x0b`), the opcode RVY leaves
to its extensions. Each is one capability operation and one check of what
kind of value its operand holds, made as it uses it, so the check costs no
extra instructions.

**References.** `lref` and `sref` load and store through a pair, nil allowed
for a load and refused for a store; `car` and `cdr` are offsets 0 and 8 of
the same instruction. `lvar` reads a symbol's slot and traps naming the
symbol if it holds the unbound marker. `jcl` calls a closure. `vkind`
answers what kind of value a register holds. `lhdr` reads an object's
length, checking its type. `beqx` and `bnex` branch on exact identity, so a
null test is `beqx rs, tp`. `npair` carves the next pair out of the cons
run, and `sealcl` seals a closure object.

**Indexed access.** funct7 carries the form and the type the object must
be, 0 for any object. One instruction checks the type in the header, that
the index is a fixnum, and the bound, then forms the address, which the
capability's own bounds check again. The value forms move 8-byte slots and
the byte forms move bytes of a string or a byte object, each refusing the
other kind; the immediate forms take an index of 0 to 31 in the
instruction.

**Fixnums.** Every operand must be untagged with metadata 0; the one that
is not traps. Add, subtract, multiply, divide, remainder, the logical
operations, shifts and compares, with immediate forms of add, and, or and
shift, and `retag`, which turns a character into its code and back.

```
add sub mul             wrapping at 32 bits
addo subo mulo faddio   trapping on overflow
lt ltu eq               leave the fixnum 0 or 1
```

`+`, `-` and `*` are the trapping forms. The trap handler widens the
operation into a bignum and resumes after the instruction, so an integer that
fits costs one instruction and one that does not costs a trap. An operand
that is a bignum takes the same route.

### Authority

At reset PCC and `mtvec` are the root: every permission over the whole
address space. The reset stub, the one piece of code at a fixed address,
turns the memory map into capabilities, once, from the root, which it reads
from a read-only CSR of Xlm's: nil, the kernel block, which goes in
`mscratch`, and in the kernel block a capability to each region, the low
block, cons space, object space, the mark bitmap, the object-start map and
the collector's scratch, one to every otype, and each device's page. It
gives the write barrier the two maps, points `mtvec` at the trap stub's
entry and enters the top level on the boot stack, holding nothing it minted
but nil.

From then on the machine reaches memory only through capabilities. The
collector, the allocator, the assembler, Exec and the image writer know
addresses, and follow one through their region's capability with its
address set; a load or store whose base is `x0` is an illegal instruction.
The root is read again only by `peek` and `poke`, the explorer's and the
printer's raw views, and the escape hatch that opens a sealed closure.

SR is the privilege, RVY's ASR. Writing a CSR, reading a privileged one, the
root's and `mscratch`'s among them, and `mret` are illegal instructions
without SR in PCC. The compiler gives a code object's entry SR when its
source was compiled `unsafe`, and no other. So reaching the root, the
kernel block or the machine's state is a permission the processor checks
on every instruction that does it.

### Traps

RISC-V leaves causes 24 to 31 to the implementation, and Xlm's are there;
32 to 34 are RVY's:

```
24   wrong type           mtval: the register holding the value
25   index out of range   mtval: the register holding the index, 32 for an immediate
26   fixnum overflow
27   division by zero
28   cons run used up     mtval: the register npair was given, gp
29   write barrier        a store would overwrite a pointer to an unmarked
                          object; mtval: the store's register, and the
                          granule's offset in it; see the collector
30   stack overflow       sp moved below the stack-limit CSR (0x7c0)
32   capability fault on the pc     mtval: the instruction, or a jump's target
33   capability fault on a load     mtval: the address
34   capability fault on a store    mtval: the address
```

The handler decodes the instruction at the faulting pc, reads the value
from the register the cause names, or for a capability fault the register
the instruction took its authority from, in the saved context, asks it what
refused, and names the operation and the value:

```
> (car 5)
*** car: expected a pair, got 5, at pc 919198c
> (vector-ref "abc" 0)
*** vector-ref: expected a vector, got "abc", at pc 91921e6
> (let ((f 5)) (f 1))
*** call: expected a function, got 5, at pc 91902ee
> (+ nil 1)
*** +: expected a number, got nil, at pc 91931f4
> (car undefined)
*** unbound variable: undefined, at pc 91939f6
> (set-car! nil 1)
*** set-car!: nil has no cell, at pc 91941c6
> (vector-ref (make-vector 3 0) 5)
*** vector-ref: index 5 is outside a vector of 3, at pc 914cfdc
> (define w (%cap-and-perms (vector 1 2 3) (lognot perm-sd)))
w
> (vector-set! w 0 9)
*** vector-set!: #(1 2 3) is read-only, at pc 9195746
> (%cap-ld-word (make-bytes 8) 8)
*** load: outside the bounds of #<bytes 8>, at pc 9195f88
> (define (deep n) (+ 1 (deep (+ n 1))))
deep
> (deep 0)
*** stack overflow at pc 9196826, value 9033fd0
```

Each report is followed by a backtrace.

The stack limit is set by the scheduler at each switch, 8 KiB above the
bottom of the incoming task's stack, or a quarter of a smaller one, and is
enforced only with interrupts on: the collector and the kernel run with them
off and may be entered with the stack nearly full. Below the limit `sp` is
still bounded to its task's stack, so nothing beneath a stack can be
written whatever the limit says.

The limit is a number, an address in the stack: it is no authority, only
where a task is stopped. The authority is `sp`.

Traps nest. The kernel block's frame names the frame a trap saves into: the
running task's context at the outermost level, and below that one of eight
frames, objects the forge made and a vector in the kernel block holds. A trap inside the
handler is normal, because the handler's own arithmetic may widen and its
own pairs may use up the cons run. Nine deep halts the machine with exit
code 9.

What the processor guarantees, what `unsafe` still means and what is
unchecked is in [docs/memory-safety.md](docs/memory-safety.md).

## Memory

```
0x0000_0000  the nil cell, 16 bytes
0x0000_0800  the reset stub, 1 KiB, where the processor starts
0x0100_0000  cons space, 128 MiB, eight million pairs
0x0900_0000  object space, 64 MiB: the kernel block first, then every
             object, machine code, stacks and register contexts among them,
             swept in place; the forge compacts it
0x0D00_0000  the mark bitmap, the object-start map, the collector's scratch
0xF000_0000  device pages, 4 KiB each
```

The low block is the first 4 KiB, nil's cell and the reset stub, and an
image saves it whole; nothing lies between it and cons space, which starts
at 16 MiB so that its runs fall on round boundaries. The map is the
emulator's, the forge's and the reset stub's: the machine holds it as
capabilities, and names nothing in it by number.

Everything the machine hands out is a pair or an object, and the collector
is the only thing that frees one.

Machine code is an object like any other. A function's code is a text, a
byte object no capability can be stored in, and what reaches it is its
entry, a capability with EX bounded exactly to the code, and the return
addresses into it. The collector keeps a text for as long as one of those
is held, by the rule it keeps every object by, and frees it when none is: a
function defined again and again leaves the heap as it was. Nothing in the
machine stands at a fixed address but the reset stub, which the processor
needs to find with nothing else set up; it lies in the low block, which an
image saves whole. The trap stub is a text like the rest, and `mtvec` its
entry, which the reset stub loads from the kernel block.

A stack is an object too, a `t-stack`, and so is a task's register
context, a `t-context` of thirty-two slots. The boot stack, the trap stack,
the boot context and the frames for nested traps are objects the forge
makes, which the kernel block holds and the stubs load.

The kernel block is the kernel's own state, one object, a `t-kernel`, the
first in object space, which `mscratch` names: the trap stub's frame,
depth and parked registers, the roots of the world (the obarray, the
symbol list, the packages), the heap's frontiers and free bins, and the
capabilities the reset stub mints. Its slots are the `kb-*` names in
layout.lisp. Lisp state that is not the kernel's is in ordinary globals.

Every slot is 8 bytes: a value slot of an object, a frame slot, a saved
register. Tags exist for RAM only: of the device registers, only the chips'
three capability registers take one, and only the display's scan-out
register hands one back.

## Calling

```
a0..a7    arguments 0..7; 8 and up are pushed, so argument 8 is at 0(s0)
t0        the closure being entered, unsealed by the jcl that entered it
t1        the argument count, an integer
a0        the result
ra        the return sentry
sp s0     the stack and the frame: capabilities to the task's stack
gp        the cons run: bounded to the task's run, at its next free pair
tp        nil, for the life of the machine
s1        the running function's code object
s2        the running task

s0 + 8k       argument 8 + k
s0 - 8        saved ra       a sentry
s0 - 16       saved s0       a stack capability; NULL at the bottom
s0 - 24       the closure
s0 - 32       saved s1
s0 - 40 - 8i  local slot i
```

Every slot of a frame says by its tag whether it holds a pointer, so the
collector scans a stack with no stack maps; the frame chain is there for the
backtrace.

Compiled code holds no heap addresses. A function reaches its symbols and
constants through its code object, which the prologue loads into `s1`, so a
constant is one `ly` and an object can move without any instruction being
patched. A code object's entry capability has EX, SR if the source was
`unsafe`, and bounds that are exactly its text; a jump within the code is
relative to it, so the text can move too.

**Closures are sealed.** The compiler makes a closure, copies its captured
values in and seals it with `sealcl`: anyone may seal their own closure,
and nothing opens one but calling it. A call is `jcl ra, t0`, which checks
that `t0` is a sealed closure, leaves it unsealed in `t0` for the callee,
links a sentry and jumps to the entry capability in slot 0, all in one
instruction. A call to a global function is four: the symbol from `s1`, its
value through `lvar`, the count, `jcl`. Calling anything that is not a
closure traps naming it. The free variables are reachable only by the
closure's own code, and by the printer and the explorer through the escape
hatch.

**The cons run.** A pair is four instructions and no branch:

```
npair a0, gp        ; the pair: the next sixteen bytes of the run
yaddi gp, gp, 16
sy    car, 0(a0)
sy    cdr, 8(a0)
```

`npair`'s check is the limit check. When the run is used up `npair` traps
naming `gp`; the trap handler hands the task a fresh run without
allocating, writes it into the saved `gp` and the live one, and the
instruction runs again. Each task allocates out of its own run, so the
sequence needs no lock and a timer interrupt cannot land between two tasks'
stores. A task starts on an empty run, bounded to no bytes, and its first
pair asks for a real one: 4 KiB, and each run after it twice the last, up
to 256 KiB, carved where its bounds are exact. A task that makes a few
pairs and ends takes a few pairs' worth of cons space, and a busy one
refills seldom.

**Leaves.** A function that calls nothing builds no frame: `ra` survives, and
no callee can clobber its locals. Its locals live in `s3` to `s10`, its
caller's code object in `s11`, and its prologue after the arity check is two
instructions. A leaf may cons, since a pair is no call; a collection begun
in the refill sees every register exactly. Leaf-ness is decided from the
source before code is emitted, and checked afterwards by reading the bytes:
a leaf that writes `ra` is a build failure. An open-coded operator reads a
leaf's locals in their registers and can write its result straight into
one, so `(set! i (+ i 1))` is one `faddio` on its register.

**Self-calls.** A function calling its own name, with the right number of
arguments and nothing local shadowing the name, reloads the unsealed closure
from its frame and jumps past its own arity check: two instructions rather
than four. Redefining a function does not reach the self-calls already
inside it, the same bargain the open-coded operators make.

**Open coding.** `car`, `+`, `<`, `vector-ref`, record accessors and about
fifty other operators compile to their instructions when called with the
right number of arguments. A comparison in a test position becomes the
branch, and a `while` tests at the bottom, so a turn of a loop is its body
and one branch back. Redefining one of these does not affect code already compiled
against it. A name given by `defconstant`, which every name in the generated
layout is, compiles to its value, as an `li` or an instruction's immediate, so
defining it again with another value, or assigning to it, is an error.

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
check only that they have a record. A fresh record's slots hold nil.

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

**Numbers.** Fixnums are 32-bit machine integers, two's complement with no
tag: `li a0, 5` makes the fixnum 5, and a word loaded from memory is a
fixnum. Arithmetic that outgrows them promotes to a bignum and demotes when
the result fits again; `(fact 50)` is exact and `(ash 1 100)` is 2^100.
Bignums are sign-magnitude with 32-bit limbs held as fixnums, worked sixteen
bits at a time so that a partial product fits a word. Three explicit
families exist for code that must not promote: `wrap+`, `strict+` and `sat+`
with their `-` and `*` forms. `peek` reads a word as a fixnum and `poke`
stores one.

**Unsafe.** The ordinary vocabulary works on capabilities the program was
handed, and the processor checks every use: a wrong argument, an index past
the end, a store through a read-only reference is a report naming the
value, never a corrupted word. The raw vocabulary is what reaches memory by
number or touches the machine's state: `%root`, the loads and stores
through it, `%kernel` and the kernel block's slots, `%slot`, the CSR and
context operations, `open-closure`, and the functions that reach memory by
number or hand out a device's page, such as `peek`, `poke` and
`device-page`. Each such name carries a bit in
its symbol, and the compiler refuses a call to one, or a reference to one as
a value, unless the site is inside an `unsafe` form or the file said
`(unsafe-file)` after its `in-package`:

```
> (%root)
error: unsafe: not inside an unsafe form: %root in repl
> (unsafe (%root))
#<capability 0x0 [0x0,0x100000000) rwRWmxseh>
```

Code that says `unsafe` is placed with SR in its entry capability, and code
that does not is placed without it, so the processor refuses the raw act to
code that never said it even if the compiler were bypassed. The operations on
a capability already held, reading its fields, loading and storing within
its bounds, narrowing it, dropping permissions, sealing a closure, are safe
and unmarked: they cannot reach past what was handed over. The collector,
the kernel, the chips, the trap handler, the image writer, the core
runtime, the bignums and the compiler are unsafe files; everything else
writes `(unsafe ...)` at the place it says a raw thing, about forty sites,
so every such place can be found. `unsafe-names` marks a package's own raw
functions. The rule in one sentence: code that does not say it is unsafe
reaches only what it was handed.

**Errors.** There is no condition system. `error` prints its message and
traps; the handler composes a report with a backtrace into a string, then
rewrites the faulting task's context so that it returns into the prompt's
restart on a clean stack, which prints the report. A task with no prompt
behind it ends. Nothing on the abandoned stack runs again; a mutex held
there is marked abandoned and handed on.

## The collector

Mark, then sweep in place, in slices. A collection is a cycle:

- **start**: interrupts off for one short stretch. Every task gives up its
  cons run, the roots are pushed, and the write barrier goes on.
- **marking**: the mark stack is traced a slice at a time, about four
  thousand bytes, with interrupts on in between. The idle task does it when
  nothing else wants the processor; whoever is allocating does a share in
  proportion to what it allocates.
- **sweeping**: dead objects go into the free bins and dead runs of pairs
  become runs for the allocator, a slice at a time, the barrier off.

The collector is precise everywhere, because the machine is: a granule holds
a pointer if and only if its tag is set, and only a capability store sets
one. The roots are the kernel block's values, the bitmap the display is
showing, which its scan-out register hands back, and the tagged granules of
every stack in use from its stack pointer to its top and of every register
context in use: the running task's stack, the contexts of the traps in
progress, and every suspended task's. The collector reaches the heap, its
maps and its scratch through the capabilities the reset stub minted for
them, and knows only addresses within them. Marking an object is pushing every tagged granule
of its payload; the type matters only to skip strings, byte objects and
texts, which hold none, and stacks and contexts, whose slots in use the
roots have scanned and whose other slots hold whatever an earlier call or a
long-dead register left there. A stack or a context is kept by what holds
it, a task, the kernel block, a frame pointer into it, like any object,
and freed with its task. Nothing is guessed, so nothing is pinned. What the
port to capabilities took away: the allocator's mask of live registers, the
conservative scan of a suspended task's registers and the pins it left, and
the rule that kept every word between `sp` and the closure slot a tagged
value.

A tagged capability keeps alive the block its base lies in, whatever its
length: based in cons space without HD, the pair at its base rounded down to
16; based in object space, the object whose block holds the granule below its
base, found by an object-start map beside the mark bitmap. A capability
narrowed to a car or to a vector's slot keeps its pair or its vector, and the
processor's barrier and both compactors follow the same rule. An entry or a
return address keeps its function's text alive the same way, with nothing
to say which code object the text belongs to: the code object is kept by
the closures and frames that hold it. A stack pointer or a frame pointer
keeps its stack the same way. A device page is somebody else's; a task's
cons run keeps at most the one pair at its base.

Free memory holds no tags. The sweep zeroes every dead object that could
hold a pointer and every dead stretch of pairs, so an allocator's stores
into a fresh block never meet an old pointer, and every tag inside an
allocated block is a pointer to something that exists. A frame's local
slots are not cleared on entry, so a slot an earlier call left tagged is
scanned with the rest: at most some floating garbage.

The write barrier is an instruction-level check in the processor (`gcmode`,
CSR 0x7c1). While it is on, any store of any width, checked or raw, that
would overwrite a tagged granule in cons or object space whose object is
unmarked traps with cause 29 before writing, naming the granule by the
store's register and its offset there; the handler reads the old value
through the store's own capability, marks its object, and the store
re-executes. The processor reads the mark bitmap and the object-start map
through capabilities in two CSRs. So the collector sees a snapshot: nothing
reachable when the cycle began can be lost, because the last copy of a
pointer cannot be overwritten unseen. A store into a stack, a context or
the kernel block is let through: one in use was scanned whole when the cycle began, so what it
held then is marked already, and a frame pushed or a register saved since
over a stale pointer loses nothing. Without that a context switch, which
saves thirty-one registers, and every call that pushes a frame would trap
over whatever an earlier one left, and asking which object holds each
granule would cost a rebuild a quarter of its time. The store's authority
says it instead: a stack pointer, a frame pointer and a context's
capability are based at the payload of their object, whose header, at an
object start, says what it is, which is two loads. Everything allocated during the cycle is black from the
start, a run of pairs by marking the run when it is handed out, an object
when it is taken, so nothing new needs tracing and the roots are scanned
once.

A walk of object space finds garbage the sweep has not reached yet as well
as what is live, and an object it hands out, such as the code object a
backtrace looks up for a return address whose function has been defined
again, is reachable again behind the snapshot's back. So a walk that hands
out an object shades it first (`gc::shade`). While marking, the object is
marked and pushed, as the barrier does, and traced with the rest. While
sweeping, one the sweep has not reached that is not marked was garbage
when the cycle began, and is not handed out at all, because what only it
held may be freed already; the walk passes over it as it would once the
sweep had freed it.

A cycle is scheduled by budget: when allocation since the last reaches
twice the live data or 8 MiB, whichever is more. The longest stretch with
interrupts off is a slice, a few hundred thousand cycles at most, whatever
the heap holds: `lm --stats` reports it. A heap with no room left is
collected to the end on the spot. A fresh rebuild finishes any cycle still
marking before the image's definitions replace the builder's, because the
barrier's handler is reached through the very symbols being replaced.

Objects, machine code among them, are never moved by the machine: the
collector is written in the language it collects, and runs in and reaches
its own functions and constants through objects. Pairs are compacted only on the way into an image, by the
compactor in gc.lisp: plan where every live pair goes, rewrite every
capability to a pair to its destination with the same permissions and
offset, slide. The tags say exactly where every pointer is, so the rewrite
is a walk over memory. Forwarding is not stored per pair; each word of the
mark bitmap, 256 bytes of cons space, records where the free pointer had
reached when the walk arrived, and a lookup adds a popcount over the word.
The image collection, `gc:collect-for-image`, also drops idle symbols from
the obarray, collects, compacts, reattaches the symbols still reachable, and
blanks everything reclaimed, so the file is the size of what is in it.

## Building an image

`lmforge build` needs no image. A reader in Rust that makes lists and
nothing else, and a small interpreter, bring up the prelude; the last file
of the prelude is `lisp/read.lisp`, the reader written in Lisp, and from
there the bootstrap reads with that. The compiler, also one of the sources,
compiles the whole system into the same heap the interpreter has been
filling. The heap is tagged from the first pair: the interpreter's values
are the same capabilities the machine's are. The machine's own collector then
runs on the machine, the forge slides object space down, code and all,
re-deriving every capability into a block that moves from the root with its
permissions and seal, return addresses included, and what is left in memory
is the image. The file is the 4 KiB pages
that hold something, each with its 512 tag bits.

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
the table says, collects from the image's own roots, and writes the file.
The forge then slides object space down in it and blanks the stacks and
frames the stubs stand on, which a fresh image writes before it reads. The
result is a fresh image, not an updated one.

```
lmforge build                       kick.img, 1.2 MiB
lmforge rebuild --from kick.img     next.img
lmforge rebuild --check             compile everything twice, collect, write nothing
lmforge compact [-f IMG] [-o OUT]   slide object space down in a saved image;
                                    --fresh blanks the stubs' stacks and frames too
lmforge layout                      regenerate lisp/layout.lisp from the Rust definitions
```

`lisp/layout.lisp` is generated on every build from `src/map.rs`,
`src/mach.rs`, `src/heap.rs`, `src/cap.rs` and the device files, so a Lisp
constant for a memory region, an object slot, a permission, a trap cause or
a device register is never written by hand.

## Exec

An Amiga Exec, in Lisp, in one shared address space with no MMU. Tasks with
32 signal bits and `wait`/`signal`; message ports on top of signals; mutexes
that belong to the task holding them; interrupt servers on the chips' lines.
There is no ExecBase: the lists are records held in variables. Sending a
message costs a pointer on a list.

The context switch is one store. The trap stub saves all 32 registers,
tags and all, into the context the kernel block's frame names and restores
from there on the way out, so switching tasks is pointing the frame at
another task's context. Preemption is the timer interrupt; a task that
blocks asks for a reschedule with an `ecall`, so the switch always happens
inside the handler. Which task is running is the register `s2`. A task's
stack and its context are objects, and the task holds each as a capability
bounded exactly to it, sealed with an otype of the kernel's, whose key the
kernel mints when it starts and keeps in its own closures: a task record
is anybody's to read, and its frames and saved registers are nobody's but
the kernel's. When nothing holds the task, the collector takes back all
three; a task that ends lets go of them at the switch that takes it off
the processor.

**Signals.** Four bits are fixed: `sigf-vblank` (5), `sigf-blit` (7),
`sigf-mutex` (8) and `sigf-timer` (9), the same bit in every task, so waking
every waiter is a walk of the wait list. Every other bit from 0 to 30 is
allocated with `alloc-signal`; bit 31 would make a mask negative.

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

A device page lies outside RAM, and the only way to it is its capability,
which the reset stub mints for every device and the kernel block holds.
Possession is ownership: `device-page`, an unsafe name, hands out a
capability bounded exactly to a device's page, with LD and SD, and LC and
SC for the three chips with a capability register, and a register is one
load or store through it, so a register offset past the page is a bounds fault, not
a store into the next device. A driver makes its page once, when it starts,
and keeps it in its own closures, which are sealed; no global or record holds
it, so no other task can name it, and it lives and ends with the driver,
with nothing to give back. `sys`, `timer` and the blitter are the kernel's,
reached through the page each use takes from the kernel block. The uart is reachable raw
by design, for the collector, the trap handler and a rebuild.

| driver | holds | requests |
|---|---|---|
| `disk.driver` | the controller | `(read block n bytes)` `(write block n bytes)` `(flush)` `(size)` `(exclusive job)` |
| `input.driver` | keyboard and mouse | `(subscribe port)` `(unsubscribe port)` `(inject ...)`; every subscriber gets every event |
| `gfx.driver` | the display chip | `(screen w h)` `(show)` `(colours pairs)` `(present)`; wakes tasks whose blits have landed |
| `console.driver` | the serial line | `(write string)` `(read port)`; whole lines, and a prompt that sleeps between keys |

A driver sleeps on its device's interrupt and the rest of the machine runs
meanwhile. A request round trip costs about 7,000 cycles, so the unit of
work sent to a driver is a whole operation, never a primitive: tasks link
their own blitter descriptors rather than asking a driver to blit.

**Bitmaps.** A bitmap's pixels are a byte object: a capability with LD and
SD bounded exactly to the pixels. A bitmap cannot be forged from an address,
a store outside it is a bounds fault, and the collector frees the pixels
when the last reference goes. Drawing goes through a rastport, a bitmap with
an origin and a clip region.

**The blitter** is asynchronous. A task fills a descriptor from its own ring
of eight, a vector its binding holds, and links it onto the chain; the chip
walks the chain on its own clock, charged by bandwidth, and writes a done
word back into each descriptor. A descriptor's source, destination and link
are capabilities, a bitmap's pixels among them, and the chip refuses a
transfer they do not cover, moving nothing and saying why in the done word;
the disk controller likewise takes its buffer as a capability. The
collector marks through a ring as through any vector, so what a blit in
flight names stays alive until it lands, and a task that ends waits for its
ring first. A descriptor is what the chip acts on, so taking and linking
one are unsafe names, and the rectangle calls in hw.lisp, which take
bitmaps, are how everything else blits. `blit-sync` waits for this task's
last descriptor, sleeping on `sigf-blit` if the wait would be long;
`blit-drain` waits for the chip. Anything that reads or writes pixels
directly calls `blit-sync` first.

Details of the model are in [docs/drivers.md](docs/drivers.md).

**The host window** is winit and wgpu. The window keeps the main thread and
the machine runs on a thread of its own: at a vertical blank the machine
takes the input that has arrived, the first time it stops to wait after one
it hands over the frame, which then holds what the compositor drew in answer
to the blank, and a key, a button or the wheel wakes an idle machine at
once. A frame no different from the last is not handed over, so an idle
desktop costs the host next to nothing. The window draws at the display's
pace, so dragging or resizing it does not stop the machine. The display is
drawn as large as the window allows without changing its shape, with a box
filter: a window pixel is the average of the display's pixels over its
square, each counting for the area it covers, and averaged as light. At a
whole-number scale that copies the display's pixels; at any other every
display pixel still covers the same area of the window, and only the window
pixels across an edge between two are a mixture of them. `--scale N` opens
the window at N times the display's size as the desktop scales sizes, and
makes it that again whenever the display changes size, as it does when the
workbench starts; and `WGPU_BACKEND=vulkan`, `dx12`, `metal` or `gl`
chooses what it draws with.

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
object, and any pointer onto its capability: address, bounds, permissions
and seal. A sealed closure is opened through the escape hatch. `(explore x)`
opens the same outline on any object, and return or a double click on a row
opens another explorer on what the row holds. The arrows move and open rows,
and the wheel scrolls.

The interface is set in Charcoal (the Virtue strike, 12 ppem) and shells in
MS Gothic's twelve-pixel halfwidth strike, six columns by twelve rows. A
glyph is drawn with one wait for the blitter and then stores into the
pixels' byte object; the UI stack says `unsafe` nowhere.

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
(capabilities)        the test suites; each prints nothing above its last line if all is well
(check)               every suite, counted; the machine halts with the verdict
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
lmdev display         the window's box filter on this host's GPU, pixel for pixel
                      against its definition
lmdev check [IMG]     boot an image headless and run the machine's own suites
lmdev bench           how many instructions a second the processor runs
lmdev inspect [IMG]   what is in an image, that code holds no heap addresses,
                      and that no capability names what is not there
lmdev reach [IMG]     what each package's symbols can reach
lmdev eval EXPR       compile and run one expression
lmdev repl            a prompt on the bootstrap interpreter
lmdev fuzz            random input to the machine, the image loader and the
                      bootstrap interpreter (--target, --seconds, --seed, --replay)
lmforge rebuild --check   compile every source on the machine twice, then collect
```

`lmdev compiler` runs compiled code on capabilities: the entry is entered
with `jcl` from the registers a task would hold, and the cases check sealed
closures, refused writes to nil, exact `eq?`, the 32-bit fixnum boundary and
the capability intrinsics.

The fuzzer's targets are the parts that take bytes from outside and handle
them with `unsafe`: random registers, capabilities among them, and random
code on a fresh machine; random bytes as an image; random text through the
bootstrap reader and evaluator with the prelude loaded. Every input is
written to `target/fuzz/last-*.bin` before it runs, so a crash leaves its
input behind for `--replay`. The cargo-fuzz targets under `fuzz/` drive the
same functions with coverage guidance (`cargo fuzz run exec|image|lisp`);
they need libFuzzer, which links on Linux and macOS but not on Windows.

The machine's own suites are Lisp, typed at the prompt. `lmdev check` boots
an image headless with a scratch disk and types `(check)`, which runs every
one of them, counts, and halts the machine with the verdict as its exit
code; `lmdev all` includes it when `kick.img` is there. By hand, each suite
is a function, and `(drivers)` needs a disk:

```
lm kick.img --no-window --batch --disk scratch.disk \
   --script '(numbers)\n(talking)\n(locking)\n(blitting)\n(drivers)\n(capabilities)\nbye'
```

`(capabilities)` checks what the processor guarantees: that nil is the
read-only cell at address 0 and not the number 0, that a number is untagged
and a pointer is bounded to its object, that identity is the whole
capability, that a dropped permission stays dropped, that a load or store
past the bounds of a byte object, a narrowed capability or a device page is
refused, that a closure is sealed and only calling it or the escape hatch
opens it, that the compiler refuses `%slot` outside `unsafe` and the
processor refuses it on a sealed closure, that a pointer cannot be made from
its bits, that a capability store keeps the tag and a word store clears
it, that `x0` is no authority even to code with SR, that the root and the
kernel block take SR to read, that the write barrier names what a store
would overwrite by its register and offset, and that a function defined a
hundred times over leaves the code and the objects in use as they were
once the collector has run, while an entry still held keeps its text, and
that a walk which finds that text's old code object keeps it if the cycle
is marking and passes over it if the cycle is sweeping.
`(devices)` checks that the display refuses a number for a bitmap and
keeps the bitmap it shows alive when nothing else holds it.

Instrumentation, all off by default:

```
lm --isaprof          a histogram of what executed, by opcode and custom form
lm --fnprof           which functions the instructions were spent in
lm --trace-traps      every trap the machine takes
lm --shot FILE        the final display as a PPM
LM_FNPROF=1 lmforge rebuild     the same profile of a rebuild
LM_ISAPROF=1 lmforge rebuild    the same histogram of a rebuild
LM_TRACE_TRAPS=1 lmforge rebuild  every trap a rebuild takes
LM_FORGE_PROF=1 lmforge build   which interpreted function the forge spends its time in
LM_WATCH_ADDR=hex     report every store to an address (LM_WATCH_LEN bytes)
LM_WATCH_HI=hex       report stores to one word, with the function that made them
LM_WATCH_S2=1         report every change of the running task
LM_TRACE_PAUSES=1     report, with a backtrace, every stretch with interrupts
                      off longer than a millisecond of host time
cargo run --release --example latency -- type|explorer|wheel|drag [GAP] [N]
                      wall time from scripted host input to the changed frame,
                      through the run loop and pacing a window gets
```

A screenshot of the workbench needs about eight million instructions of
`--budget`; a smaller budget shows the screen before the compositor has
drawn it.

## Known limits

- No condition system: an error abandons the stack and nothing on it runs
  again. There is no `unwind-protect`, `catch` or `dynamic-wind`.
- Floats are boxed and the compiler does no arithmetic on them.
- Bignums have no bitwise operations, and division is a bit at a time.
- Open-coded operators and self-calls do not see a redefinition.
- The machine never moves objects, machine code among them, or, between
  images, pairs, so a long session can fragment the heap; holes in cons
  space smaller than 512 bytes wait for the compactor, which only an image
  gets.
- Marking costs about 220 cycles a pair, and while a cycle is marking the
  program allocating pays for it.
- Calls with more than eight arguments are never tail calls.
- Nothing is freed by hand, so a capability always names the block it was
  made for; an address held as a number does not, and `unsafe` code that
  makes one a capability again reaches whatever is there now.
- The root is everything. Code compiled `unsafe` can make any capability,
  including one that writes an object's header or opens any closure.
- `eq?` is exact: two capabilities to the same object with different
  permissions are different values.
- A frame's local slots are not cleared, so a pointer an earlier call left
  in one is a root until something overwrites it.

The open items, the API gaps and the performance risks are listed in
[docs/open-items.md](docs/open-items.md).
