# Moving objects

The machine's collector sweeps objects in place, machine code among them,
and compacts pairs only on the way into an image. The forge slides object
space down on the way into an image, and `lmforge compact` does the same to
an image that came off the disk, so every path that persists an image
compacts it. A long-running machine does not compact its own object space.
This note records what it would take.

## Why the machine does not move objects

The collector is written in the language it collects. It calls its functions
through symbol value cells, reaches its constants through its own code
object and runs in its functions' texts, and every one of those is an
object. The pair compactor runs plan,
update, slide: the update pass rewrites every capability to a pair to its
post-move address while nothing has moved, and between the end of update and
the end of slide every such capability names an address whose contents have
not arrived. Pairs survive that window because nothing in it dereferences a
pair. Objects would not, because in that window the collector makes calls.

## What the port changed

**Every pointer is found.** A granule is a pointer if and only if its tag is
set, so a compactor walks memory and rewrites exactly the tagged granules
that name a block that moves. Nothing is scanned conservatively, so nothing
is pinned, and the pin map and the pins a suspended task's registers left
are gone.

**A moved pointer is made again, not adjusted.** A capability's bounds are
part of it, so moving an object means deriving a fresh capability from the
root at the new address, with the same permissions, the same offset and the
same seal; a sealed closure is sealed again, which takes the root as the
key. Only privileged code can do it, which a mover is anyway. The new
address must also be one the object's bounds can be exact at: a block keeps
the alignment `yamask` gave it.

**Numbers are not pointers.** An address held as a fixnum, in a low global
or in a chip's register, carries no tag, and no compactor will find it. The
display register holds the address of a bitmap's pixels, which is why
drivers.md can say the address of the pixels is good for ever, and the
blitter latches the capabilities of the transfer it is making. A machine
that moved objects would have to pin byte objects a chip has been told
about, or move them only with the chips idle and their registers
rewritten.

## What is built

The forge's compactor in `src/forge/compact.rs`, which runs on a heap that
has stopped. `compact_objects` walks object space as a sequence of live
blocks and `t-free` holes, which the machine's own collection for the image
has already left, slides the live blocks down keeping each one's alignment,
and rewrites every tagged capability in memory whose block moved. Texts
move with the rest: a jump within a function is relative to it, and every
other way into code is a capability, an entry or a return sentry, which is
derived again where the text went and sealed again. A saved image's stacks
hold return sentries, and they move with their texts like any other
capability. The stacks themselves are objects, as are the register contexts
and the trap frames, and slide with the rest; a slot in one that names
nothing, left there by an earlier call or a long-dead register, loses its
tag. Nothing the machine needs at reset is outside memory: the reset stub
loads `sp`, `mscratch` and `mtvec` from `lg-boot-stack`, `lg-trapsave` and
`lg-trap-entry`, and the trap stub its stack and its nested frames from
`lg-trap-stack` and `lg-trap-nest`, every one a low global the rewrite
covers.

On the machine, the pair compactor in gc.lisp, for the image collection.
There is no object compactor in Lisp.

## The options, in order

**A low immobile region.** Make everything below a watermark immobile, and
have the forge allocate the collector's own code objects and the symbols and
objects they name there. Sliding would have put them at the bottom anyway,
so protecting them costs nothing, and the test is one address comparison.

**The slide as a stub.** Only the planning lookup and the slide have to be
immune. Written as assembly with no literals, reading only the mark bitmap,
the offset tables and raw memory through DDC, the mover touches no object
but its own text, which must not move under it: it would live in the low
immobile region, or at a fixed address as the reset stub does. It must
reload `s1`, its caller's PCC and every live register on the way out from
slots the update pass filled in, because the collector's live registers
are not in any frame for the update pass to rewrite.

**A nursery for objects.** The garbage in a build is macro expansions,
assembler buffers and analysis lists, all short-lived. A young-generation
copier never moves anything the collector runs out of, because the collector
is old. It needs a remembered set for old objects that point at young ones;
the write barrier is already a trap on every store into the heap while it is
on, and is where one would be kept. This is the only option that reduces
peak usage rather than cleaning up after it.

## Two cautions

Peak usage is not fragmentation. A build's dead object space is memory the
build needed; the artifact should be the size of what is in it, which the
forge's slide achieves.

Measure before choosing a strategy. `lmdev reach` reports object pages by
how full they are. Before the forge compacted, a fresh image had 473 of 715
pages under a quarter full, so evacuating only the sparse pages would have
moved most of the live data anyway; the full slide was the right shape. The
image `lmforge build` makes now has 1 KiB dead across its 241 object pages,
code included. A long-running machine has not been measured.
