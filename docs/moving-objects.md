# Moving objects

The machine's collector compacts pairs and sweeps objects and code in place.
The forge slides object space down on the way into an image, and
`lmforge compact` does the same to an image that came off the disk, so every
path that persists an image compacts it. A long-running machine does not
compact its own object space. This note records what it would take.

## Why the machine does not move objects

The collector is written in the language it collects. It calls its functions
through symbol value cells and reaches its constants through the literal
vector of its own code object, and every one of those is an object. The
pair compactor runs plan, update, slide: the update pass rewrites every
stored pointer to its post-move address while nothing has moved, and between
the end of update and the end of slide every pointer names an address whose
contents have not arrived. Pairs survive that window because nothing in it
dereferences a pair. Objects would not, because in that window the
collector makes calls.

## What is built and switched off

gc.lisp holds a complete object compactor that nothing calls:
`gc-plan-objects` builds the per-block offset and first-object tables and
handles pins, `gc-forward-object` replays a block to compute a forwarding
address, and `gc-move-objects` slides. The one line holding it shut is
`gc-forward-value`, which forwards pairs and answers an object's own
address.

The algorithm is settled: mark-bit prefix sums with a small side table per
block, as the pair compactor uses. The heap stays walkable throughout and a
forwarding address is computable at any moment. Threading compactors, which
chain pointers through headers, are ruled out because the heap is
unwalkable mid-pass and this collector has to run out of that heap.

## The options, in order

**A low immobile region.** Make everything below a watermark immobile, and
have the forge allocate the collector's own code objects and literal vectors
there. Sliding would have put them at the bottom anyway, so protecting them
costs nothing, and the test is one address comparison. Pinning the
collector's transitive closure with `gc-pinmap` instead does not work well:
pins scattered through a sparse heap hold whole pages down.

**The slide as a stub.** Only `gc-move-objects` and `gc-forward-object`
have to be immune. Written as assembly in code space with no literal vector,
reading only the mark bitmap, the offset tables and raw memory, the mover
touches no object. It must be entered through a raw code address in a
global, as `lg-refill` and `lg-gchook` are, and it must reload `s1` on the
way out from a raw slot the update pass filled in, because the collector's
live registers are not in any frame for the update pass to rewrite.

**A nursery for objects.** The garbage in a build is macro expansions,
assembler buffers and analysis lists, all short-lived. A young-generation
copier never moves anything the collector runs out of, because the
collector is old. The pair walk that already happens every collection is
the remembered set for pair-to-object references, so a nursery collection
could ride on it. This is the only option that reduces peak usage rather
than cleaning up after it.

**Code space.** Visible only in rebuilt images, where every function the
rebuild replaced leaves a hole. Moving machine code means relocating every
`clo-entry` and `code-entry` word; intra-function jumps are pc-relative and
survive, and calls go through the closure's entry word.

## Two cautions

Peak usage is not fragmentation. A build's dead object space is memory the
build needed; the artifact should be the size of what is in it, which the
forge's slide achieves.

Measure before choosing a strategy. `lmdev reach` reports object pages by
how full they are. Before the forge compacted, a fresh image had 473 of 715
pages under a quarter full, so evacuating only the sparse pages would have
moved most of the live data anyway; the full slide was the right shape. A
long-running machine has not been measured.
