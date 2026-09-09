# Moving objects

*Written 2026-09-08, after the forge learned to compact object space on the way
into an image. This is the part that was left undone, and why.*

## Where things stand

Object space is written by an allocator that never moves anything. The machine's
collector marks, sweeps objects in place, and compacts only pairs. `gc.lisp`
gives the reason in full:

> This collector is written in the language it collects: it calls functions
> through symbol value cells, and reaches its own constants through the literal
> vector of its own code object. Every one of those is an object. Move them and
> the collector loses the ability to run, halfway through running.

The forge is under no such obligation, so `src/forge/compact.rs` slides object
space down on the way into an image, and `lmforge compact` does the same to one
that came off the disk. That covers every path that persists an image —
`build`, `rebuild`, and by hand — and a fresh `kick.img` is now 949 KiB with
object space 100% live.

**So compaction is, for now, a concern for persisted images only.** A long-lived
running machine has never yet been the thing that hurt. Everything below is
therefore *someday* work, and the ordering reflects that.

## What is already built and switched off

`gc.lisp` contains a complete object compactor that nothing calls:

- `gc-plan-objects` — builds the per-block offset table and the per-block
  first-object table, handling pins.
- `gc-forward-object` — replays a block to get a forwarding address.
- `gc-move-objects` — slides.

The one line holding it shut:

```lisp
(define (gc-forward-value v)
  ;; Pairs move. Objects do not, and answer their own address.
  (if (%cons? v)
      (%from-addr (gc-forward-cons (%addr-of v)))
      v))
```

This is not a build-it problem. It is a *when is it safe to turn on* problem.

## The algorithm question is settled

The classical sliding-compaction families:

| family | cost | fits here? |
|---|---|---|
| LISP 2 | a forwarding word per object | no — costs space in every object |
| break tables (Haddon & Waite 1967) | table rolled through the gaps | workable, fiddly |
| threading (Fisher / Jonkers / Morris) | none, but headers temporarily hold pointer chains | **no** — the heap is unwalkable mid-pass, and this collector has to run out of that heap |
| mark-bit prefix sums (Abuaiadh 2004; the Compressor, Kermany & Petrank 2006) | a small side table per block | **yes** — heap stays walkable, forwarding computable at any moment |

The last is what `gc-plan-objects` / `gc-forward-object` implement, and what
the pair compactor already uses in anger. Nothing about the algorithm needs
revisiting.

## The real problem, precisely

`gc-compact` runs **plan → update → slide**. The update pass rewrites every
stored pointer to its *post-move* address while nothing has moved yet. Between
the end of update and the end of slide, the world is systematically wrong:
every pointer names an address whose contents have not arrived.

Pairs survive that window because nothing in it dereferences a pair. Objects do
not, because in that window the collector makes function calls — and a call
goes through a symbol value cell, and a constant through the literal vector in
`s1`, and both are objects whose pointers the update pass has just rewritten.

The window is the whole problem, and it is small. That is what makes this
tractable.

## The options, in the order they should be tried

### 1. A low immobile region

Make *below a watermark* mean immobile, and arrange for the collector's own code
objects and literal vectors to live down there. Allocation order is the forge's
to choose. Then the collector's own working set costs nothing to protect,
because sliding would have put it at the bottom anyway, and the test is one
address comparison rather than an enumeration nobody can verify by reading.

This subsumes the obvious alternative — pin the collector's transitive closure
using the existing `gc-pinmap` — which fails for a measurable reason: pins
scattered through a sparse heap hold whole pages down. The compaction of a
*live* image already demonstrates this. 35 words in the Exec pool pinned 35
objects, one of them near the top, and the compacted span did not shrink at all;
only blanking the holes underneath the pin recovered the file size.

### 2. The slide as a stub

Only `gc-move-objects` and `gc-forward-object` have to be immune. Plan and
update are ordinary Lisp running on a consistent heap. Written as assembly in
code space with no literal vector, reading only the mark bitmap, the offset
tables and raw memory, the mover touches no object at all and nothing needs
pinning. `boot.lisp` already emits three stubs for exactly this class of reason;
this is the fourth.

Two sharp edges:

- It must be entered through a **raw code address in a global**, the way
  `lg-refill` and `lg-gchook` are, not through a symbol — by then the symbol's
  cell names an address whose contents have not arrived.
- The collector's **live registers** are not in any frame for the update pass to
  rewrite. `s1` in particular. The stub has to reload it on the way out from a
  raw slot the update pass filled in.

### 3. A nursery for objects

The 2.5 MB of garbage in a build is macro expansions, assembler buffers and
analysis lists — textbook short-lived. The part that makes this fit:

**The self-reference problem only applies to old objects.** A young-generation
copier never moves anything the collector runs out of, because the collector is
old.

Normally the price is a write barrier for old→young pointers. Here pairs are
already marked and compacted on every cycle, so the existing pair walk *is* the
remembered set for pair→object references, and a nursery collection could ride
on the collection that already happens.

This attacks the cause rather than the symptom, and it is the only item here
that would reduce the build's *peak* rather than clean up after it.

### 4. Code space

Visible only in rebuilt images, where code is 42% live: every function the
rebuild replaced left a hole. Moving machine code means finding every call site,
which is a different problem from moving data and wants its own note. Until
then, `lmforge build` renormalises.

## Two cautions

**Peak usage is not fragmentation.** 2.5 MB dead in a fresh build is not
evidence that the allocator fragments badly — the build genuinely needed that
memory, and Johnstone & Wilson (1998) is worth re-reading before anyone
concludes otherwise. What was being fixed is an artifact that should be the size
of what is in it, not an allocator that misbehaves.

**Measure before choosing a strategy.** `lmdev reach` reports object pages by
how full they are. Before compaction, a fresh image had 473 of 715 pages under a
quarter full — so sparse that evacuating only the sparse ones (Immix's
opportunistic defragmentation) would have moved 348 KiB of the 411 KiB live.
There was no cheap 80/20 to design for; the full slide was the right shape. That
may not be true of a long-running machine, which is the case none of this has
measured yet.
