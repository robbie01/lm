# Memory safety

What the machine checks, what it does not, and what it would take to make
the unchecked path high-friction and constrained, so that the machine is
safe by default. This is about what the language lets you say, not about
who may say it: there is one address space, every task can reach every
symbol, and that stays.

## The principle

Safety here is scoping, not checking, as [drivers.md](drivers.md) says of
the devices: a thing is safe because the ordinary vocabulary cannot express
the unsafe act, not because a supervisor catches it. The processor does the
checking that costs nothing, in the instructions the compiler emits for the
ordinary vocabulary, and everything the ordinary vocabulary produces is a
typed error with a report, never a corrupted heap. The unsafe acts exist,
because the collector, the kernel and the drivers need them, and the whole
question is how they are named and how far they reach.

The target is one sentence: **code that does not say it is raw cannot fault
the machine.** It can get a typed error; it cannot reach a load or store
fault, cannot forge a pointer, cannot write past an object, cannot write a
heap word the collector will not see.

## What is checked today

The four custom opcodes check as they form an address, at no extra cost:

- `car`, `cdr`, `set-car!`, `set-cdr!` check the pair tag; a store refuses
  nil.
- `vector-ref`, `string-ref`, `bytes-ref` and their setters, and every
  record accessor, check the object tag, the type in the header, that the
  index is a fixnum, and the bound. A record accessor also checks the
  record's own type word.
- A call loads the entry through a typed index, so calling a non-function
  is a typed error; arity is checked in the prologue.
- Fixnum arithmetic checks both operands; `+`, `-` and `*` trap on overflow
  and are widened.
- The stack limit is a register the scheduler sets per task; a frame that
  would cross it traps before it is built.
- A store into the first eight bytes, nil's cell, is refused by the machine.
- The write barrier watches every checked store while a collection is
  marking.

There is no unchecked vector, string or byte access at all: the plain names
compile to the checked instructions and the `%` names are the same
instructions.

Every failure of the raw vocabulary, a load or store outside RAM, a
misaligned fetch, an illegal instruction, is a fatal trap: a report, a
backtrace, and the task ends. Nothing inside RAM is ever refused.

## The raw vocabulary

These are the operations that can produce an invalid access. All of them
are intrinsics in `lm`, all are exported, and all are reachable unqualified
from `user` and from every application package, because every package uses
`lm`. The `%` prefix marks them by convention; nothing enforces it.

| what | checks | on a bad argument |
|---|---|---|
| `%ld-word` `%st-word!` `%ld-half` `%st-half!` | none | reads or writes any RAM word, live heap and code included |
| `%ld-fixnum` `%st-fixnum!` `%ld-byte` `%st-byte!`, and `peek`/`poke` over them | the address is a fixnum | the same |
| `%bit-ref` `%bit-set!` | none, the bit index unbounded | the same |
| `%addr-of` | none | any pointer becomes an integer |
| `%from-addr` | none | any integer becomes a pointer, which every checked instruction then trusts |
| `%slot` `%set-slot!` | object tag and bound, any type | a closure's raw entry word read as a value |
| the symbol accessors, `%symbol-value` and the rest | object tag only | on a one-slot record, a write three words past its end |
| `%vector-length` `%string-length` `%bytes-length` | none | a fixnum's neighbour read as a header |
| `%set-context!` `%set-stack-limit!` `%set-gc-mode!` `%ecall` `%disable` `%enable` `%sync-cons-run` `%reload-cons-run` `%set-this-task!` `%halt` | none | arbitrary machine state |
| `alloc-pool` `free-pool` | a header tag on free | a freed block reused under a holder; never scanned |
| `dev-reg` and the blitter's descriptors | ownership of the device | a DMA anywhere in RAM |

Outside the kernel files these are used in snap.lisp (49 sites), demo.lisp
(46), explorer.lisp and print.lisp (walking objects with `%slot`),
bignum.lisp, and a few in the drivers and the fonts. The UI stack, wb, ui,
platinum and eyes, uses none of them: it draws through `hw`'s checked
bitmap functions, which is the design working.

The raw stores also bypass the write barrier, which is consulted only by
the checked stores. A pointer overwritten through `%st-word!` during a
mark is lost. That is fine for what the raw stores are for, pool memory,
device registers and the low globals, none of which hold heap pointers the
collector needs to see; it is the wild store into the heap that would be
wrong, and nothing today refuses it.

## Closed now

Two holes in the checked vocabulary, both in the processor:

- The indexed-access bound used the header's count as a word count for
  every type. A string or byte object counts bytes, so a word access through
  the any-type form, which is what `%slot` is, passed the check up to three
  words past the object and read or wrote there. The count is now
  converted to the size of the access.
- `-2^30 / -1` is `2^30`, the one quotient that does not fit a fixnum, and
  plain division wrapped it to `-2^30` silently. It now traps as an
  overflow and is widened, so `%/` and `quotient` agree.

## What would make it safe by default

In order of how much safety each buys for its cost.

**1. A raw vocabulary that has to be named as such.** The mark exists; make
it mean something. The compiler knows every raw intrinsic by symbol, so
refusing to open-code one unless the site says it is raw is one check in
`inline-entry`: a flag on the emitter entry, and a special form or macro
`(raw ...)` that binds a compile-time flag while its body is compiled. The
kernel files that are raw throughout, gc, hw, exec, sys, snap, bignum, the
compiler and the assembler, declare it once per file. Everything else
writes `(raw (%st-word! p v))` at the site, the way Rust writes `unsafe`,
and a `%from-addr` outside one is a compile error naming the form. This is
the Rust bargain exactly: the unsafe act is still there, it is greppable,
and it cannot be reached by accident. The bootstrap interpreter needs
nothing, since `raw` expands to `begin` for it. Cost: a table of about
forty names and thirty lines of compiler.

**2. Refuse the wild store into the heap.** The barrier already inspects
every checked store; a second mode bit in the same CSR would have the
processor refuse a plain store, `sw`, `sh`, `sb` and the tagged forms, whose
address lies in cons or object space. Compiled code never stores into a
heap object except through a checked store, so ordinary code never trips
it; the collector and the image writer, which write headers and free-list
links raw, clear the bit around their sweeps, the way they set the barrier
around a mark. Then no raw store from any task can corrupt a heap word, and
the raw stores keep their purpose, the pool and the chips. Cost: one range
test on the plain store path while the bit is set.

**3. Type the symbol accessors.** They are `lobj` loads with an offset,
checking only that the base is an object. The immediate-index form of
custom-1 checks the type and the bound in the same one instruction, so
`%symbol-value` and the rest can pass `t-symbol` and cost nothing more.
`lvar`, the variable read that also refuses the unbound marker, stays as
it is. The length forms, `%vector-length` and its two siblings, want the
same treatment: a typed load of the header.

**4. Poison the pool on free.** A freed block is reused under whoever still
holds its address, silently. Filling a freed block with an object-tagged
pointer that lies outside RAM, `#xFEEDFEEC` say, makes the first checked
use of stale memory a load fault naming the value, rather than a quiet
read of someone else's stack. The cost is a fill per free, most of them
task stacks at task end, which happens in the switch; measure before
deciding whether it can be unconditional.

**5. Make the blitter's guard the chip's behaviour.** `LM_BLIT_GUARD`
already checks that a transfer stays inside the one pool block or object
it named and prints when it does not. As the default, refusing the
transfer and setting a status bit, it turns a wrong descriptor into a
reported failure instead of a scribble across the heap. The disk engine
has the same shape: it checks the extent against RAM in 64 bits, and could
check that the address is inside a byte object, since that is all the
driver ever hands it.

**6. Audit `%from-addr`.** It is the one primitive that manufactures a
pointer, and every checked instruction downstream trusts what it made. Its
uses are few and all in the kernel; with item 1 in place they are all
inside `raw`, and the list of them is the list of places a bad pointer can
enter the checked world.

**7. State the invariant as a fuzz target.** The exec fuzzer proves random
code cannot reach the host. A Lisp-level target would generate programs
from the checked vocabulary only and assert that none reaches a fatal
trap: no load fault, no store fault, no misaligned fetch, only typed
errors. That is the sentence at the top of this note, made checkable, and
with item 1 it is checkable by construction: a program with no `raw` in it
cannot name anything that faults.

## What this is not

There is no MMU and no supervisor, by design, and this does not add one.
Every task keeps its reach into every symbol, every package and every
device it owns. The friction proposed is at the point of writing the code,
in the name it has to say, and in the processor refusing the few acts that
nothing ordinary ever needs.
