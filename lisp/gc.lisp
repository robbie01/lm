;;; gc.lisp - the collector.
;;;
;;; Mark, then sweep in place, in slices short enough that nothing waits on
;;; one. A collection is a cycle with three phases:
;;;
;;;   start     interrupts off for one short stretch: the roots are found,
;;;             every task's stack precisely and its saved registers
;;;             conservatively, and the write barrier goes on.
;;;   marking   the mark stack is traced a slice at a time, by the idle task
;;;             when the machine has nothing else to do and by whoever is
;;;             allocating when it has. Everything else runs in between.
;;;   sweeping  dead objects go into the free bins and dead runs of pairs
;;;             become runs for the allocator, a slice at a time, the barrier
;;;             off.
;;;
;;; What makes marking safe to interleave with running code is the machine's
;;; write barrier (`gcmode`, cpu.rs): while it is on, a checked store that
;;; would overwrite a pointer whose mark bit is clear traps first, and the
;;; handler marks that pointer (`barrier`). So everything reachable when the
;;; cycle began stays reachable to the collector: a pointer can be moved from
;;; place to place but not lost, because the last copy cannot be overwritten
;;; unseen. This is a snapshot: what was live at the start survives the
;;; cycle, and what was allocated during it is made black on the spot, a run
;;; of pairs by marking the whole run when it is handed out and an object by
;;; marking it when it is taken. Nothing new needs tracing, and the roots
;;; need scanning once.
;;;
;;; Pairs and objects stay where they are. The compactor below is kept for
;;; images, where a heap with no holes is worth a stopped machine.
;;;
;;; The collector is written in the language it collects: it reaches its
;;; functions through symbol value cells and its constants through the
;;; literal vector of its own code object. Nothing here may allocate. `let`
;;; and `while` are free; `%cons` is not, and anything that conses would
;;; recurse into the condition being handled. Compiled code contains no heap
;;; addresses, which is what lets the compactor move pairs; the Exec pool is
;;; a separate heap, raw, unmoving and never scanned, holding stacks,
;;; register contexts and command blocks.
;;;
;;; Cons space is handed out in runs: the inline allocator bumps a pointer
;;; inside a run and only crossing to the next one costs a call.

(in-package gc)

;; ---------------------------------------------------------------- geometry
(define gc-heap-lo cons-base)
(define gc-heap-hi obj-limit)
;; One mark bit per eight bytes of heap, in scratch memory above fast-base.
;; The write barrier reads this map, so its address is the machine's
;; (`GC_BITMAP` in map.rs): a pair's bit is at the pair, an object's at its
;; header.
(define gc-bitmap fast-base)
(define gc-bitmap-size (%lsh (%- gc-heap-hi gc-heap-lo) -6))
;; A second bitmap of the same shape for objects that must not move because
;; something found them by guessing. Only the compactor reads it.
(define gc-pinmap (%+ gc-bitmap gc-bitmap-size))
(define gc-stack (%+ gc-pinmap gc-bitmap-size))
(define gc-stack-cap 262144)
(define gc-stack-end (%+ gc-stack (%lsh gc-stack-cap 2)))

;; Forwarding is not stored per object. Each block of the heap records where
;; the free pointer had reached when the compacting walk arrived at it, and a
;; lookup replays the few objects between that boundary and the one asked
;; about. A cons block is eight pairs, which is one byte of the mark bitmap,
;; so the replay is a popcount.
(define cons-block-bytes 64)
(define gc-cons-prefix gc-stack-end)
(define gc-cons-blocks (%lsh (%- cons-limit cons-base) -6))
(define obj-block-bytes 1024)
(define gc-obj-prefix (%+ gc-cons-prefix (%lsh gc-cons-blocks 2)))
(define gc-obj-blocks (%lsh (%- obj-limit obj-base) -10))
(define gc-obj-first (%+ gc-obj-prefix (%lsh gc-obj-blocks 2)))

;; A free block in object space carries t-free in its header with its size in
;; granules of eight bytes where a live object keeps its length. The bins at
;; obj-bins are exact-fit free lists; the forge knows their layout too.

(define *mark-sp* 0)
(define *run-last* 0)
;; The bytes of the run handed out last, charged to the collector at the next
;; refill: a run is paid for once it has been used up, not when it is given.
;; Runs are per task, so exec.lisp replaces these two to keep the debt on the
;; task that was handed the run; before there are tasks, one cell does.
(define *run-owed* 0)
(define (note-run! bytes) (set! *run-owed* bytes))
(define (take-owed-run) (let ((b *run-owed*)) (set! *run-owed* 0) b))
(define *count* 0)
(define *cycles* 0)
(define *verbose* nil)
;; A full extra pass over the live pairs after every compaction, reporting
;; pointers that still name a pair above the new top. Off unless debugging.
(define *check* nil)

;; ---------------------------------------------------------------- the stub
;; Layout of the frame the cons refill stub builds. It sits between two Lisp
;; frames and is not one: a live-register mask, the eight argument registers,
;; then ra and the temporaries, which are raw and must not be traced.
(define stub-mask-off 0)
(define stub-args-off 4)     ; a0..a7
(define stub-raw-off 36)     ; ra, t0..t6
(define stub-frame-size 72)

;; ---------------------------------------------------------------- mark bits
(defsubst (gc-bit-index p) (%lsh (%- p gc-heap-lo) -3))

(defsubst (marked? p) (%bit-ref gc-bitmap (gc-bit-index p)))
(defsubst (gc-mark! p) (%bit-set! gc-bitmap (gc-bit-index p)))
(defsubst (gc-pinned? p) (%bit-ref gc-pinmap (gc-bit-index p)))
(defsubst (gc-pin! p) (%bit-set! gc-pinmap (gc-bit-index p)))

(define (gc-map-byte p) (%lsh (%- p gc-heap-lo) -6))

(defsubst (gc-unmark! p)
  (let ((a (%+ gc-bitmap (%lsh (gc-bit-index p) -3))))
    (%st-byte! a (%logand (%ld-byte a) (%lognot (%lsh 1 (%logand (gc-bit-index p) 7)))))))

;; Every bit for the heap from `lo` up to `hi`, set or cleared: whole words
;; where it can, single bits at the edges.
(define (fill-bits lo hi on)
  (let ((i (gc-bit-index lo)) (e (gc-bit-index hi)))
    (while (if (%< i e) (%> (%logand i 31) 0) nil)
      (if on (gc-mark! (%+ lo (%lsh (%- i (gc-bit-index lo)) 3)))
          (gc-unmark! (%+ lo (%lsh (%- i (gc-bit-index lo)) 3))))
      (set! i (%+ i 1)))
    (while (%<= (%+ i 32) e)
      (%st-fixnum! (%+ gc-bitmap (%lsh i -3)) (if on -1 0))
      (set! i (%+ i 32)))
    (while (%< i e)
      (if on (gc-mark! (%+ lo (%lsh (%- i (gc-bit-index lo)) 3)))
          (gc-unmark! (%+ lo (%lsh (%- i (gc-bit-index lo)) 3))))
      (set! i (%+ i 1)))))

;; A run of pairs handed out while marking is black from the start.
(define (mark-range lo hi) (fill-bits lo hi t))
(define (clear-range lo hi) (fill-bits lo hi nil))

;; Bytes `b0` up to `b1` of the mark map, zeroed: whole words where it can.
;; A screen-sized bitmap is twelve thousand bytes of map.
(define (clear-map-bytes b0 b1)
  (while (if (%< b0 b1) (%> (%logand b0 3) 0) nil)
    (%st-byte! (%+ gc-bitmap b0) 0)
    (set! b0 (%+ b0 1)))
  (while (%<= (%+ b0 4) b1)
    (%st-fixnum! (%+ gc-bitmap b0) 0)
    (set! b0 (%+ b0 4)))
  (while (%< b0 b1)
    (%st-byte! (%+ gc-bitmap b0) 0)
    (set! b0 (%+ b0 1))))

;; The maps are cleared with the blitter, a byte per 64 bytes of heap, whole
;; words at a time so that no stale bit is left beside a live one. Only an
;; image collection does this: it waits for the chip, behind whatever the
;; screen has queued.
(define gc-clear-w 1024)

;; n bytes of zero at `at`, as rows the blitter can take, through the
;; collector's own descriptor ring.
(define (gc-fill-bytes at n)
  (if (%<= n 0)
      nil
      (let* ((w (if (%< n gc-clear-w) n gc-clear-w))
             (rows (%/ (%+ n (%- w 1)) w))
             (b (gc-blit-descriptor)))
        (poke (%+ b bl-dst) at)
        (poke (%+ b bl-w) w)
        (poke (%+ b bl-h) rows)
        (poke (%+ b bl-dmod) w)
        (poke (%+ b bl-val) 0)
        (blit-go b op-fill)))
  nil)

;; The bits for the heap from `lo` up to `hi`, in `map`.
(define (clear-map-range map lo hi)
  (let ((b0 (%logand (gc-map-byte lo) -4))
        (b1 (%logand (%+ (gc-map-byte hi) 4) -4)))
    (gc-fill-bytes (%+ map b0) (%- b1 b0))))

;; Both maps, over both spaces up to their frontiers. The clears are blits,
;; and a blit is not finished when it returns; marking must not start until
;; they have landed.
(define (clear-bitmap)
  (clear-map-range gc-bitmap cons-base (%ld-fixnum lg-cons-ptr))
  (clear-map-range gc-bitmap obj-base (%ld-fixnum lg-obj-ptr))
  (clear-map-range gc-pinmap cons-base (%ld-fixnum lg-cons-ptr))
  (clear-map-range gc-pinmap obj-base (%ld-fixnum lg-obj-ptr))
  (blit-wait-ring *gc-blit-ring*))

;; ---------------------------------------------------------------- skipping
;; A word of the mark bitmap covers thirty-two pairs, or 256 bytes of heap.
;; Where that word is zero the whole run is dead and the passes over cons
;; space step over it. Each pass walks a pointer into the bitmap beside its
;; pointer into the heap, four bytes of map to 256 of heap. The 256 is
;; written into the loops because a literal compiles to one instruction where
;; a global costs two loads.
;;
;; The word is read as two halves on purpose: a tagged load drops bit 31, so
;; a map word of 0x80000000, only the last pair of the run live, would read
;; as zero and the pair would be lost. `%ld-half` is a zero-extending load
;; and cannot lose a bit.
(defsubst (gc-run-dead? mp)
  (if (%= 0 (%ld-half mp)) (%= 0 (%ld-half (%+ mp 2))) nil))

(defsubst (gc-word-live mp)
  (%+ (%popcount (%ld-half mp)) (%popcount (%ld-half (%+ mp 2)))))

;; ---------------------------------------------------------------- marking
;; `object-payload` spelled out, with a record, most of what a busy heap is
;; made of, asked about first. Every walk of object space asks this once per
;; object below the frontier.
(defsubst (obj-block-size h)
  (let ((ty (%logand h 255)) (n (%lsh h -8)))
    (cond ((%= ty t-record) (%logand (%+ (%lsh n 2) 11) -8))
          ((%= ty t-free) (%lsh n 3))
          ((%= ty t-string) (%logand (%+ n 11) -8))
          ((%= ty t-bytes) (%logand (%+ n 11) -8))
          ((%= ty t-symbol) (%logand (%+ (%lsh sym-slots 2) 11) -8))
          ((%= ty t-float) 8)
          (else (%logand (%+ (%lsh n 2) 11) -8)))))

;; Is this word something the heap could have handed out? Asked about tagged
;; values and about arbitrary words found on a stack or in a register, so it
;; must never say yes to something it would then dereference wrongly. An
;; address is held as a fixnum, which has thirty-one bits: a word with its
;; top bit set, a cycle count say, would look like an address in range once
;; the bit was lost, so the address is turned back into a word and must be
;; the word asked about. An object has to lie below the allocation pointer,
;; carry a header with a plausible type, and end below the pointer too, so
;; that a word pointing into the middle of something is not followed past
;; the heap.
(defsubst (gc-heap-pointer? v)
  (cond
   ((%cons? v)
    (let ((p (%addr-of v)))
      (if (%>= p cons-base)
          (if (%< p (%ld-fixnum lg-cons-ptr)) (%eq? (%from-addr p) v) nil)
          nil)))
   ((%object? v)
    (let ((p (%- (%addr-of v) 4)))
      (if (%>= p obj-base)
          (if (%< p (%ld-fixnum lg-obj-ptr))
              (if (%eq? (%from-addr (%+ p 4)) v)
                  (let* ((h (%ld-fixnum p)) (ty (%logand h 255)))
                    (if (%>= ty 1)
                        (if (%<= ty 10)
                            (%<= (%+ p (obj-block-size h)) (%ld-fixnum lg-obj-ptr))
                            nil)
                        nil))
                  nil)
              nil)
          nil)))
   (else nil)))

;; Where the mark bit for this value lives: a pair marks at the pair, an
;; object at its header.
(defsubst (gc-block-of v)
  (if (%cons? v) (%addr-of v) (%- (%addr-of v) 4)))

;; Open-coded: marking asks this twice for every live pair.
(defsubst (gc-push v)
  (if (gc-heap-pointer? v)
      (let ((b (gc-block-of v)))
        (if (marked? b)
            nil
            (begin
              (gc-mark! b)
              (if (%>= *mark-sp* gc-stack-cap)
                  (gc-overflow)
                  (begin
                    (%st-word! (%+ gc-stack (%lsh *mark-sp* 2)) v)
                    (set! *mark-sp* (%+ *mark-sp* 1)))))))
      nil))

(define (gc-overflow)
  (uart-string "gc: mark stack overflow")
  (uart-nl)
  (%halt exit-gc-stack))

;; Which words of an object are pointers. Marking follows them and the update
;; pass rewrites them, so there is one description of an object's shape.
(define (gc-object-slots base)
  (let* ((h (%ld-fixnum (%- base 4)))
         (ty (%logand h 255))
         (n (%lsh h -8)))
    (cond
     ((%= ty t-symbol) (gc-slots base 0 sym-slots))
     ;; strings, byte vectors and floats hold no pointers
     ((%= ty t-string) nil)
     ((%= ty t-bytes) nil)
     ((%= ty t-float) nil)
     ;; slot 0 is the sign and the rest are raw limbs, which often look like
     ;; pointers
     ((%= ty t-bignum) nil)
     ;; slots 0 and 1 are the raw entry address and byte length
     ((%= ty t-code) (gc-slots base code-name n))
     ;; slot 0 is a raw code address
     ((%= ty t-closure) (gc-slots base 1 n))
     (else (gc-slots base 0 n)))))

(define (gc-scan-object v) (gc-object-slots (%addr-of v)))

;; How much a slice traces before it lets interrupts back in. Marking costs
;; about 180 cycles a pair, so this is about a hundred thousand cycles: a
;; third of a frame of the machine's clock, a fraction of a millisecond of
;; the host's.
(define slice-bytes 4096)

;; Pop and trace until the slice is full or the stack is empty. Answers the
;; bytes traced. Runs with interrupts off: the barrier pushes from the trap
;; handler, and the two must not interleave.
(define (trace-some)
  (let ((done 0))
    (while (if (%> *mark-sp* 0) (%< done slice-bytes) nil)
      (set! *mark-sp* (%- *mark-sp* 1))
      (let ((v (%ld-word (%+ gc-stack (%lsh *mark-sp* 2)))))
        (if (%cons? v)
            (begin (gc-push (%car v)) (gc-push (%cdr v)) (set! done (%+ done 8)))
            (begin
              (gc-scan-object v)
              (set! done (%+ done (obj-block-size (%ld-fixnum (%- (%addr-of v) 4)))))))))
    done))

(define (drain)
  (while (%> *mark-sp* 0) (trace-some)))

;; ---------------------------------------------------------------- roots
;; One pointer-bearing word, during the update pass: rewritten to where its
;; target is going.
(defsubst (gc-update-slot addr)
  (let ((v (%ld-word addr)))
    (if (gc-heap-pointer? v) (%st-word! addr (forward-value v)) nil)))

;; One pointer-bearing word, in whichever pass this is. Every traversal goes
;; through here or `gc-update-slot`, so the same walk serves marking and
;; updating.
(define (slot addr)
  (let ((v (%ld-word addr)))
    (if *updating*
        (if (gc-heap-pointer? v) (%st-word! addr (forward-value v)) nil)
        (gc-push v))))

(define (gc-scan-range lo hi)
  (let ((p (%logand lo -4)))
    (while (%< p hi)
      (slot p)
      (set! p (%+ p 4)))))

;; Words that might be pointers and might be integers. Anything reached this
;; way is marked and pinned, and the word itself is never rewritten: a pinned
;; object forwards to itself, so a number that happens to look like an
;; address stays a number.
(define *pinned* 0)

(define (scan-conservative lo hi)
  (let ((p (%logand lo -4)))
    (while (%< p hi)
      (let ((v (%ld-word p)))
        (if (if *updating* nil (gc-heap-pointer? v))
            (begin
              (set! *pinned* (%+ *pinned* 1))
              (gc-pin! (gc-block-of v))
              (gc-push v))
            nil))
      (set! p (%+ p 4)))))

;; ---------------------------------------------------------------- stacks
;; A frame base is a word-aligned address inside the pool, where every stack
;; lives. Zero ends the walk: the reset stub leaves it in s0 before it enters
;; Lisp, and the trap stub does the same before it calls the handler.
(define (frame-ok? s0)
  (if (%> s0 pool-base)
      (if (%< s0 pool-limit) (%= 0 (%logand s0 3)) nil)
      nil))

(define (in-stub? ra)
  (if (%>= ra (%ld-fixnum lg-stub-lo)) (%< ra (%ld-fixnum lg-stub-hi)) nil))

;; Only the argument registers the mask says are live. The rest of the stub's
;; frame is a return address and untagged temporaries.
(define (gc-scan-stub base)
  (let ((mask (%ld-fixnum (%+ base stub-mask-off))) (i 0))
    (while (%< i 8)
      (if (%= 1 (%logand 1 (%lsh mask (%- 0 i))))
          (slot (%+ base (%+ stub-args-off (%* 4 i))))
          nil)
      (set! i (%+ i 1)))))

;; The chain of Lisp frames, precisely. Every word from a frame's stack
;; pointer up to and including its closure slot is a tagged value; only the
;; saved return address and frame link are raw, at fixed offsets; and a
;; callee's frame base is its caller's stack pointer. So the chain alone gives
;; every frame's extent, with no stack maps.
(define (scan-frames sp0 s00)
  (let ((sp sp0) (s0 s00) (go t) (guard 0))
    (while (if go (frame-ok? s0) nil)
      (set! guard (%+ guard 1))
      (if (%> guard 100000) (set! go nil) nil)
      (gc-scan-range sp (%- s0 8))
      (let ((ra (%ld-fixnum (%- s0 4)))
            (next (%ld-fixnum (%- s0 8))))
        (if (in-stub? ra)
            (begin (gc-scan-stub s0) (set! sp (%+ s0 stub-frame-size)))
            (set! sp s0))
        (set! s0 next)))))

;; A saved register block: the frames its stack pointer and frame pointer
;; name, precisely, and the registers themselves conservatively, except gp
;; and tp, which are the cons run and not values.
(define (scan-context ctx)
  (scan-frames (%ld-fixnum (%+ ctx (%* 4 reg-sp)))
               (%ld-fixnum (%+ ctx (%* 4 reg-s0))))
  (scan-conservative ctx (%+ ctx (%* 4 reg-gp)))
  (scan-conservative (%+ ctx (%* 4 reg-t0)) (%+ ctx ctx-bytes)))

;; Inside a trap, the code the trap interrupted is neither running nor on a
;; list: its registers are in the frame mscratch names, and a nested trap's
;; frame links to the one it interrupted, just past the registers.
(define (scan-trap-frames)
  (let ((depth (%ld-fixnum lg-trapdepth)) (ctx (%context)))
    (while (%> depth 0)
      (scan-context ctx)
      (set! depth (%- depth 1))
      (if (%> depth 0) (set! ctx (%ld-fixnum (%+ ctx ctx-bytes))) nil))))

;; Replaced by exec.lisp once the kernel is up, to walk every task's stack.
(define (extra-roots) nil)

;; Every root is named by the address of the word holding it, not by its
;; value, because the update pass has to write the new value back.
(define (roots)
  (slot lg-symlist)
  (slot lg-obarray)
  (slot lg-packages)
  (slot lg-package)
  (slot lg-bootlist)
  (slot lg-roots)
  (slot lg-toplevel)
  (slot lg-errhandler)
  (slot lg-traphook)
  (slot lg-refill)
  (slot lg-startup)
  (slot lg-task-exit)
  ;; The running task is a register, so there is no slot to rewrite; it is a
  ;; record, which does not move, so marking is the whole job.
  (if *updating* nil (gc-push (%this-task)))
  ;; This task's own stack, from where it stands.
  (scan-frames (%stack-pointer) (%frame-pointer))
  ;; Whatever a trap interrupted, if this is inside one.
  (scan-trap-frames)
  ;; Every other task's stack and registers.
  (extra-roots))

;; ---------------------------------------------------------------- runs
;; A run of free cons space is described in its own first cell: the end
;; address, then the next run. Handing the cell out later is fine, because
;; refill reads both words before anything is allocated from it.
(define (gc-add-run start end)
  (%st-fixnum! start end)
  (%st-fixnum! (%+ start 4) 0)
  (if (%= *run-last* 0)
      (%st-fixnum! lg-cons-free start)
      (%st-fixnum! (%+ *run-last* 4) start))
  (set! *run-last* start))

;; ---------------------------------------------------------------- obj sweep
(defsubst (obj-bin-addr gran)
  (%+ obj-bins (%lsh (if (%< gran obj-bin-count) gran 0) 2)))

;; len is in bytes and always a multiple of eight.
(define (gc-free-block start len)
  (let* ((gran (%lsh len -3))
         (bin (obj-bin-addr gran)))
    (%st-fixnum! start (%logior (%lsh gran 8) t-free))
    (%st-fixnum! (%+ start 4) (%ld-fixnum bin))
    (%st-fixnum! bin start)))

(define (gc-clear-bins)
  (let ((i 0))
    (while (%< i obj-bin-count)
      (%st-fixnum! (%+ obj-bins (%lsh i 2)) 0)
      (set! i (%+ i 1)))))

(define (gc-corrupt p)
  (uart-string "gc: corrupt object header at ")
  (uart-hex p)
  (uart-nl)
  (%halt exit-gc-corrupt))

;; One walk over object space does both halves: live objects have their
;; pointers to pairs rewritten, dead ones are gathered into free blocks.
;; Called with `*updating*` set, between the update of the pairs and their
;; move, by the compactor. A dead run at the very top lowers the frontier
;; instead of becoming a free block.
(define (update-sweep-objects hi)
  (let ((p obj-base)
        (run 0)
        (runlen 0)
        (nfree 0))
    (gc-clear-bins)
    (while (%< p hi)
      (let ((size (obj-block-size (%ld-fixnum p))))
        ;; A zero size is a corrupt header and would spin here for ever.
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (marked? p)
            (begin
              (gc-object-slots (%+ p 4))
              (if (%> runlen 0)
                  (begin (gc-free-block run runlen) (set! nfree (%+ nfree runlen)))
                  nil)
              (set! runlen 0))
            (begin
              (if (%= runlen 0) (set! run p) nil)
              (set! runlen (%+ runlen size))))
        (set! p (%+ p size))))
    (if (%> runlen 0) (%st-fixnum! lg-obj-ptr run) nil)
    (%st-fixnum! lg-obj-free-n nfree)
    nfree))

;; ================================================================ the cycle
;;
;; State that lives across slices. A cycle records the two frontiers when it
;; began: the sweep goes that far and no further, because everything above
;; was made during the cycle and is black.

(define phase-idle 0)
(define phase-marking 1)
(define phase-sweeping 2)
(define *phase* 0)

(define *cons-hi* 0)         ; the frontiers when the cycle began
(define *obj-hi* 0)
;; The map is zero wherever nothing is marked, all the time, so that a cycle
;; can begin without clearing it: the sweep clears the bits behind it, what
;; was made black while marking is cleared once the sweep is done (these are
;; those ranges), and a run or an object taken at any other time has its
;; bits cleared as it is handed out, which also disposes of any bit the
;; barrier set for a word that only looked like a pointer.
(define *clear-cons* 0)
(define *clear-cons-hi* 0)
(define *clear-obj* 0)
(define *clear-obj-hi* 0)

;; The object sweep's place, and the dead run it is in the middle of.
(define *sweep-obj* 0)
(define *sweep-run* 0)
(define *sweep-runlen* 0)
;; The cons sweep's place, in the heap and in the map, and the hole it is in
;; the middle of.
(define *sweep-cons* 0)
(define *sweep-map* 0)
(define *sweep-hole* 0)

;; What the cycle found, for the budget and the report.
(define *obj-freed* 0)       ; bytes of object space freed
(define *code-freed* 0)      ; bytes of code space freed
(define *cons-live* 0)       ; bytes of pairs kept
(define *cons-holes* 0)      ; bytes of pairs handed back as runs
(define *slices* 0)
(define *slice-max* 0)       ; the longest slice, in cycles
(define *slice-kind* 0)      ; what the current slice is doing
(define *slice-max-kind* 0)  ; and what the longest was
(define *barriers* 0)        ; barrier traps taken
(define *t-start* 0)         ; the cycle counter when the cycle began
;; instrumentation: cycles per slice kind, small holes, dead pairs inside live words, refills
(define *t-mark* 0) (define *t-code* 0) (define *t-objects* 0) (define *t-pairs* 0) (define *t-clear* 0)
(define *small-holes* 0) (define *inner-dead* 0) (define *refills* 0)

(define kind-start 1)
(define kind-mark 2)
(define kind-code 3)
(define kind-objects 4)
(define kind-pairs 5)
(define kind-clear 6)

(define (kind-name k)
  (cond ((%= k kind-start) "the start")
        ((%= k kind-mark) "marking")
        ((%= k kind-code) "the code sweep")
        ((%= k kind-objects) "the object sweep")
        ((%= k kind-pairs) "the pair sweep")
        (else "clearing")))

;; A hole in cons space worth handing out as a run. Smaller ones wait for the
;; compactor, which an image gets.
(define gap-min 512)

;; The sweep clears the mark bits behind it. The compactor wants them
;; afterwards, so a collection for an image asks for them to be kept.
(define *keep-marks* nil)

(defsubst (note-slice t0)
  (let ((d (%logand (%- (%cycles) t0) 1073741823)))
    (set! *slices* (%+ *slices* 1))
    (cond ((%= *slice-kind* kind-mark) (set! *t-mark* (%+ *t-mark* d)))
          ((%= *slice-kind* kind-code) (set! *t-code* (%+ *t-code* d)))
          ((%= *slice-kind* kind-objects) (set! *t-objects* (%+ *t-objects* d)))
          ((%= *slice-kind* kind-pairs) (set! *t-pairs* (%+ *t-pairs* d)))
          ((%= *slice-kind* kind-clear) (set! *t-clear* (%+ *t-clear* d)))
          (else nil))
    (if (%> d *slice-max*)
        (begin (set! *slice-max* d) (set! *slice-max-kind* *slice-kind*))
        nil)))

;; ---------------------------------------------------------------- start
;; Every task's run shrinks to the one cell it may be in the middle of
;; filling, which is marked; this task's run likewise. The holes the last
;; sweep left are below the frontier, where this sweep will find them again,
;; so they are dropped: every pair made from here on comes from fresh ground
;; above the frontier, marked as it is handed out.
(define (give-up-run)
  (%sync-cons-run)
  (let ((gp (%ld-fixnum lg-cons-run)) (tp (%ld-fixnum lg-cons-run-end)))
    (if (%< gp tp)
        (begin (gc-mark! gp) (%st-fixnum! lg-cons-run-end (%+ gp 8)))
        nil))
  (%reload-cons-run))

;; Interrupts off throughout: the one stretch a cycle stops the machine for.
(define (start-cycle)
  (let ((t0 (%cycles)))
    (set! *t-start* t0)
    (set! *mark-sp* 0)
    (set! *pinned* 0)
    (set! *slices* 0)
    (set! *t-mark* 0) (set! *t-code* 0) (set! *t-objects* 0) (set! *t-pairs* 0) (set! *t-clear* 0)
    (set! *small-holes* 0) (set! *inner-dead* 0)
    (set! *slice-max* 0)
    (set! *slice-kind* kind-start)
    (set! *barriers* 0)
    (set! *cons-hi* (%ld-fixnum lg-cons-ptr))
    (set! *obj-hi* (%ld-fixnum lg-obj-ptr))
    (%st-fixnum! lg-cons-free 0)
    (set! *run-last* 0)
    (invalidate-runs)
    (give-up-run)
    (set! *phase* phase-marking)
    (roots)
    (%set-gc-mode! 1)
    (note-slice t0)))

;; ---------------------------------------------------------------- barrier
;; From the trap handler: a checked store is about to overwrite `v`, whose
;; mark bit is clear. Mark it and trace it later. The bit goes on whatever
;; `v` turns out to be, because the store re-executes and must not trap
;; again; a word that only looks like a pointer marks a bit nothing reads.
(define (barrier v)
  (set! *barriers* (%+ *barriers* 1))
  (let ((x (%from-addr v)))
    (if (%= *phase* phase-marking) (gc-push x) nil)
    (gc-mark! (gc-block-of x)))
  nil)

;; ---------------------------------------------------------------- finish
;; The mark stack is empty and nothing can be pushed while interrupts are
;; off: the barrier can go off, and the sweep can begin. Code before objects:
;; sweeping object space writes free-list links over dead objects' first
;; slots, and a dead code object's first slot is the address of the code it
;; owns.
(define (finish-mark)
  (%set-gc-mode! 0)
  (set! *code-i* 0)
  (set! *code-keep* 0)
  (set! *code-n* (%ld-fixnum lg-code-reg-n))
  (set! *code-freed* 0)
  (gc-clear-bins)
  ;; What was made while marking is black and lies above the frontiers the
  ;; cycle began with; its bits come off after the sweep.
  (set! *clear-cons* *cons-hi*)
  (set! *clear-cons-hi* (%ld-fixnum lg-cons-ptr))
  (set! *clear-obj* *obj-hi*)
  (set! *clear-obj-hi* (%ld-fixnum lg-obj-ptr))
  (set! *sweep-obj* obj-base)
  (set! *sweep-run* 0)
  (set! *sweep-runlen* 0)
  (set! *obj-freed* 0)
  (set! *sweep-cons* cons-base)
  (set! *sweep-map* gc-bitmap)
  (set! *sweep-hole* 0)
  (set! *cons-live* 0)
  (set! *cons-holes* 0)
  (set! *phase* phase-sweeping))

;; ---------------------------------------------------------------- sweeping
;; Object space, a stretch at a time: dead runs become free blocks in the
;; bins, and the bits behind the sweep are cleared for the next cycle. A dead
;; run at the very top lowers the frontier, if nothing has been allocated
;; above it since the cycle began. Answers the bytes walked. A busy desktop's
;; objects are small records, a few hundred to a stretch this long, each
;; costing a bin push when it is dead.
(define sweep-obj-bytes 8192)

(define (sweep-objects-some)
  (let* ((start *sweep-obj*)
         (p start)
         (lim (%+ p sweep-obj-bytes))
         (hi (if (%< lim *obj-hi*) lim *obj-hi*))
         (run *sweep-run*)
         (runlen *sweep-runlen*)
         (nfree 0))
    (while (%< p hi)
      (let ((size (obj-block-size (%ld-fixnum p))))
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (marked? p)
            (begin
              (if (%> runlen 0)
                  (begin (gc-free-block run runlen) (set! nfree (%+ nfree runlen)))
                  nil)
              (set! runlen 0))
            (begin
              (if (%= runlen 0) (set! run p) nil)
              (set! runlen (%+ runlen size))))
        (set! p (%+ p size))))
    (if (%>= p *obj-hi*)
        (begin
          (if (%> runlen 0)
              (if (%= (%ld-fixnum lg-obj-ptr) *obj-hi*)
                  (%st-fixnum! lg-obj-ptr run)
                  (begin (gc-free-block run runlen) (set! nfree (%+ nfree runlen))))
              nil)
          (set! runlen 0)
          (set! p *obj-hi*))
        nil)
    ;; The bits behind the sweep. The byte holding `p` may hold bits for
    ;; what is still ahead, so it stays.
    (if *keep-marks*
        nil
        (let ((b0 (gc-map-byte start)) (b1 (gc-map-byte p)))
          (if (%>= p *obj-hi*) (set! b1 (%+ b1 1)) nil)
          (clear-map-bytes b0 b1)))
    (set! *sweep-obj* p)
    (set! *sweep-run* run)
    (set! *sweep-runlen* runlen)
    (set! *obj-freed* (%+ *obj-freed* nfree))
    (%- p start)))

;; Cons space, a stretch of the map at a time. A word of the map is thirty-two
;; pairs; a run of dead words is a hole, and a hole big enough becomes a run
;; for the allocator. Live pairs are counted for the budget. Each word is
;; cleared once it has been read. Answers the bytes of heap walked. A word
;; costs under a hundred cycles, so a stretch is a quarter of a megabyte of
;; pairs.
(define sweep-cons-words 1024)

(define (sweep-cons-some)
  (let* ((start *sweep-cons*)
         (p start)
         (mp *sweep-map*)
         (lim (%+ p (%* 256 sweep-cons-words)))
         (hi (if (%< lim *cons-hi*) lim *cons-hi*))
         (hole *sweep-hole*)
         (live 0)
         (holes 0))
    (while (%< p hi)
      (if (gc-run-dead? mp)
          (if (%= hole 0) (set! hole p) nil)
          (begin
            (if (%> hole 0)
                (begin
                  (if (%>= (%- p hole) gap-min)
                      (begin (gc-add-run hole p) (set! holes (%+ holes (%- p hole))))
                      (set! *small-holes* (%+ *small-holes* (%- p hole))))
                  (set! hole 0))
                nil)
            (let ((wl (%lsh (gc-word-live mp) 3)))
              (set! live (%+ live wl))
              (set! *inner-dead* (%+ *inner-dead* (%- 256 wl))))
            (if *keep-marks* nil (%st-fixnum! mp 0))))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))
    (if (%>= p *cons-hi*)
        (begin
          ;; The hole at the top: the frontier comes down to it if nothing
          ;; has been carved above since the cycle began, else it is a run.
          (if (%> hole 0)
              (if (%= (%ld-fixnum lg-cons-ptr) *cons-hi*)
                  (%st-fixnum! lg-cons-ptr hole)
                  (begin (gc-add-run hole *cons-hi*)
                         (set! holes (%+ holes (%- *cons-hi* hole)))))
              nil)
          (set! hole 0)
          (set! p *cons-hi*))
        nil)
    (set! *cons-live* (%+ *cons-live* live))
    (set! *cons-holes* (%+ *cons-holes* holes))
    (set! *sweep-cons* p)
    (set! *sweep-map* mp)
    (set! *sweep-hole* hole)
    (%- p start)))

;; The bits of what was made black while marking, a stretch at a time.
;; Answers the bytes of heap covered.
(define clear-bytes 262144)

(define (clear-cons-some)
  (let* ((lo *clear-cons*)
         (lim (%+ lo clear-bytes))
         (hi (if (%< lim *clear-cons-hi*) lim *clear-cons-hi*)))
    (if *keep-marks* nil (clear-range lo hi))
    (set! *clear-cons* hi)
    (%- hi lo)))

(define (clear-obj-some)
  (let* ((lo *clear-obj*)
         (lim (%+ lo clear-bytes))
         (hi (if (%< lim *clear-obj-hi*) lim *clear-obj-hi*)))
    (if *keep-marks* nil (clear-range lo hi))
    (set! *clear-obj* hi)
    (%- hi lo)))

;; The highest cons space has ever reached. Everything between the allocation
;; pointer and this is dead and dirty; it is blanked only for an image, so
;; that the file is the size of what is in it.
(define *cons-dirty-top* 0)

(define (finish-cycle)
  (%st-fixnum! lg-obj-free-n *obj-freed*)
  (%st-fixnum! lg-cons-free-n (%+ (%lsh (%- cons-limit (%ld-fixnum lg-cons-ptr)) -3)
                                   (%lsh *cons-holes* -3)))
  (if (%> *cons-hi* *cons-dirty-top*) (set! *cons-dirty-top* *cons-hi*) nil)
  (set-budget)
  (set! *count* (%+ *count* 1))
  (%st-fixnum! lg-gccount *count*)
  (let ((spent (%logand (%- (%cycles) *t-start*) 1073741823)))
    (set! *cycles* (%+ *cycles* spent))
    (set! *phase* phase-idle)
    (if *verbose* (report spent) nil)
    (set! *refills* 0)))

;; Straight to the serial line: no allocation inside a collection.
(define (report spent)
  (uart-string "[gc ")
  (uart-num (%- (%lsh (%- *cons-hi* cons-base) -3) (%lsh *cons-live* -3)))
  (uart-string " pairs, ")
  (uart-num *obj-freed*)
  (uart-string " object bytes, ")
  (uart-num *code-freed*)
  (uart-string " code bytes freed; ")
  (uart-num (%lsh *cons-live* -3))
  (uart-string " pairs live; ")
  (uart-num *slices*)
  (uart-string " slices, longest ")
  (uart-num *slice-max*)
  (uart-string " of ")
  (uart-num spent)
  (uart-string " cycles in ")
  (uart-string (kind-name *slice-max-kind*))
  (uart-string ", ")
  (uart-num *barriers*)
  (uart-string " barrier traps; next after ")
  (uart-num *budget*)
  (uart-string " bytes]")
  (uart-nl)
  (uart-string "  [phases: mark ") (uart-num *t-mark*)
  (uart-string " code ") (uart-num *t-code*)
  (uart-string " objects ") (uart-num *t-objects*)
  (uart-string " pairs ") (uart-num *t-pairs*)
  (uart-string " clear ") (uart-num *t-clear*)
  (uart-string "; small holes ") (uart-num *small-holes*)
  (uart-string " bytes, dead in live words ") (uart-num *inner-dead*)
  (uart-string " bytes, refills since last ") (uart-num *refills*)
  (uart-string "]")
  (uart-nl))

;; ---------------------------------------------------------------- stepping
(define (busy?) (if (%= *phase* phase-idle) nil t))

;; One slice of whatever the cycle is doing, interrupts off for its length.
;; Answers the cycles it took.
(define (step)
  (without-interrupts
    (let ((t0 (%cycles)))
      (cond ((%= *phase* phase-marking)
             (set! *slice-kind* kind-mark)
             (trace-some)
             (if (%= *mark-sp* 0) (finish-mark) nil))
            ((%= *phase* phase-sweeping)
             (cond ((%< *code-i* *code-n*)
                    (set! *slice-kind* kind-code) (sweep-code-some))
                   ((%< *sweep-obj* *obj-hi*)
                    (set! *slice-kind* kind-objects) (sweep-objects-some))
                   ((%< *sweep-cons* *cons-hi*)
                    (set! *slice-kind* kind-pairs) (sweep-cons-some))
                   ((%< *clear-cons* *clear-cons-hi*)
                    (set! *slice-kind* kind-clear) (clear-cons-some))
                   ((%< *clear-obj* *clear-obj-hi*)
                    (set! *slice-kind* kind-clear) (clear-obj-some))
                   (else (finish-cycle))))
            (else nil))
      (if (busy?) (note-slice t0) nil)
      (%logand (%- (%cycles) t0) 1073741823))))

;; Whether interrupts are on, without changing them.
(define (interrupts-on?)
  (let ((was (%disable)))
    (%restore-interrupts was)
    (%= was 1)))

;; Called by whoever is about to allocate `bytes`: the collector keeps pace
;; with allocation by spending some cycles for every byte allocated, starting
;; a cycle when the budget says so. Marking costs about twenty cycles a byte
;; and the budget lets twice the live data be allocated before the next
;; cycle, so a dozen cycles a byte finishes a cycle in time with room to
;; spare. The slices are interruptible in between, so this is not a pause;
;; what a big allocation owes is capped and carried over, so it is not a
;; long one either. A caller already inside a critical section gets two
;; slices at most: the rest waits for one that is not. The idle task does
;; whatever is left.
(define pace-cycles 12)
(define pace-max-slices 64)
(define *debt* 0)

(define (pace bytes)
  (if (if (%= *phase* phase-idle) (over-budget?) nil)
      (begin (without-interrupts (if (%= *phase* phase-idle) (start-cycle) nil))
             (set! *debt* 0))
      nil)
  (if (busy?)
      (let ((n 0) (cap (if (interrupts-on?) pace-max-slices 2)))
        (set! *debt* (%+ *debt* (%* pace-cycles bytes)))
        (while (if (%> *debt* 0) (if (busy?) (%< n cap) nil) nil)
          (set! *debt* (%- *debt* (%+ (step) 1)))
          (set! n (%+ n 1))))
      nil)
  nil)

;; The whole of a cycle now, interrupts off: for an image, and for a heap
;; with no room left.
(define (collect)
  (without-interrupts
    (if (%= *phase* phase-idle) (start-cycle) nil)
    (while (busy?) (step)))
  nil)

;; ---------------------------------------------------------------- when
;; A collection costs the live data plus the heap it walks, and the heap it
;; walks is everything below the two frontiers. One comes when the bytes
;; allocated since the last reach twice the live data or eight megabytes,
;; whichever is more, so the heap walked stays a small multiple of what is
;; live.
(define budget-min 8388608)
(define *budget* budget-min)    ; bytes allowed between collections
(define *gc-allocated* 0)             ; object bytes handed out since the last
(define *cons-given* 0)               ; and bytes of cons runs

(define (over-budget?)
  (%> (%+ *gc-allocated* *cons-given*) *budget*))

(define (set-budget)
  (let ((live (%+ (%- (%- (%ld-fixnum lg-obj-ptr) obj-base) (%ld-fixnum lg-obj-free-n))
                  *cons-live*)))
    (set! *gc-allocated* 0)
    (set! *cons-given* 0)
    (set! *budget* (if (%> (%* 2 live) budget-min) (%* 2 live) budget-min))))

;; ---------------------------------------------------------------- refill
;; How much cons space a task is given at a time: big enough that refilling
;; is rare, small enough that a task which stops allocating is not sitting on
;; much. The chunk is the task's alone until it is used up, which is what
;; makes the four-instruction allocator safe without a lock.
(define cons-chunk 262144)     ; 32768 pairs

;; Replaced by exec.lisp once there are other tasks to tell.
(define (invalidate-runs) nil)

;; The run goes into gp and tp here, with interrupts still off, rather than
;; in the stub afterwards: the two globals are one pair for the whole
;; machine, and a task preempted between storing them and picking them up
;; would come back to whatever another task had left there. A run handed out
;; while marking is black from the start; at any other time its bits are
;; cleared, which is what keeps the map zero above the frontier.
(define (hand-out-run start end)
  (set! *refills* (%+ *refills* 1))
  (set! *cons-given* (%+ *cons-given* (%- end start)))
  (note-run! (%- end start))
  (if (%= *phase* phase-marking) (mark-range start end) (clear-range start end))
  (%st-fixnum! lg-cons-run start)
  (%st-fixnum! lg-cons-run-end end)
  (%reload-cons-run)
  start)

;; A hole the sweep left, else fresh ground. Answers nil when there is
;; neither. Interrupts off.
(define (next-run)
  (let ((hole (%ld-fixnum lg-cons-free)))
    (if (%> hole 0)
        (begin
          (%st-fixnum! lg-cons-free (%ld-fixnum (%+ hole 4)))
          (if (%= (%ld-fixnum lg-cons-free) 0) (set! *run-last* 0) nil)
          (hand-out-run hole (%ld-fixnum hole))
          t)
        (let ((p (%ld-fixnum lg-cons-ptr)))
          (if (%< (%- cons-limit p) 8)
              nil
              (let ((top (if (%< (%- cons-limit p) cons-chunk) cons-limit (%+ p cons-chunk))))
                (%st-fixnum! lg-cons-ptr top)
                (hand-out-run p top)
                t))))))

;; Called from the assembly stub when the inline allocator runs out of run.
;; Every caller-saved register was spilled on the way in, so the collector
;; can see them. The collector gets its share of work first, with interrupts
;; as they were; then the run, with them off. The share is for the run just
;; used up, whatever its size: a sweep hole of a few pairs is not a chunk,
;; and a task's first run is paid for when it asks for its second, so a
;; fresh task is not stalled on its first cons by a collection in progress.
(define (refill-cons)
  (pace (take-owed-run))
  (without-interrupts
    (if (next-run)
        nil
        (begin
          (collect)
          (if (next-run) nil (out-of-memory "cons space"))))))

;; ---------------------------------------------------------------- allocation
;; Exact fit first, then a split from the big-block list, then bump. Answers
;; 0 when there is no room at all, and `alloc-object` collects and asks
;; again. Interrupts off. A block taken while marking is black from the
;; start.
(define (obj-take size)
  (let* ((gran (%lsh size -3))
         (bin (obj-bin-addr gran))
         (p (if (%< gran obj-bin-count) (%ld-fixnum bin) 0)))
    (set! *gc-allocated* (%+ *gc-allocated* size))
    (let ((got (if (%> p 0)
                   (begin (%st-fixnum! bin (%ld-fixnum (%+ p 4))) p)
                   (obj-take-slow size gran))))
      (if (if (%> got 0) (%= *phase* phase-marking) nil) (gc-mark! got) nil)
      got)))

(define (obj-take-slow size gran)
  (let ((prev 0)
        (p (%ld-fixnum obj-bins))
        (found 0))
    (while (if (%= found 0) (%> p 0) nil)
      (let ((have (%lsh (%lsh (%ld-fixnum p) -8) 3)))
        (if (%>= have size)
            (begin
              (if (%= prev 0)
                  (%st-fixnum! obj-bins (%ld-fixnum (%+ p 4)))
                  (%st-fixnum! (%+ prev 4) (%ld-fixnum (%+ p 4))))
              (if (%>= (%- have size) 8)
                  (gc-free-block (%+ p size) (%- have size))
                  nil)
              (set! found p))
            (begin (set! prev p) (set! p (%ld-fixnum (%+ p 4)))))))
    (if (%> found 0)
        found
        (let ((q (%ld-fixnum lg-obj-ptr)))
          (if (%<= (%+ q size) (%ld-fixnum lg-obj-end))
              (begin
                (%st-fixnum! lg-obj-ptr (%+ q size))
                ;; Fresh ground: only the header's bit is ever read, and it
                ;; must be clear unless marking sets it (see `obj-take`).
                (if (%= *phase* phase-marking) nil (gc-unmark! q))
                q)
              0)))))

;; ================================================================ compaction
;;
;; Sliding compaction of cons space, for images, in four passes:
;;
;;   1. mark        done by the time this runs: a whole cycle has finished
;;   2. plan        where every live pair is going, recording the free pointer
;;                  at each block boundary so that any pair's destination can
;;                  be replayed cheaply
;;   3. update      rewrite every pointer, in the roots and the live objects,
;;                  to where its target is going
;;   4. move        slide the pairs down
;;
;; Updating before moving is what makes this work without a forwarding word
;; per pair: while pass 3 runs, everything is still where the bitmap says.
;;
;; A pinned pair does not move and pushes the free pointer past itself, so
;; the free pointer is never above the pair being considered, and pass 4 can
;; copy upwards through memory without overwriting anything it has not yet
;; moved.
;;
;; Objects do not move. This collector is written in the language it
;; collects, and between updating and moving it calls functions and reaches
;; constants through objects whose pointers have already been rewritten.
;; docs/moving-objects.md lists the ways round that.

(define *updating* nil)
(define *moved* 0)

;; ---------------------------------------------------------------- forwarding
(defsubst (cons-block-of p) (%lsh (%- p cons-base) -6))
(defsubst (obj-block-of p) (%lsh (%- p obj-base) -10))

;; One walk over the pairs, recording the free pointer on the way into each
;; block that holds a live pair. Answers where the live region will end. A
;; dead run needs no entries: `forward-cons` is only asked about live
;; pairs.
(define (plan-cons hi)
  (let ((p cons-base) (mp gc-bitmap) (free cons-base) (blk 0))
    (%st-fixnum! gc-cons-prefix cons-base)
    (while (%< p hi)
      (if (gc-run-dead? mp)
          nil
          (let ((q p) (e (%+ p 256)))
            (if (%> e hi) (set! e hi) nil)
            (while (%< q e)
              (let ((b (cons-block-of q)))
                (if (%< blk b)
                    (begin (set! blk b)
                           (%st-fixnum! (%+ gc-cons-prefix (%lsh b 2)) free))
                    nil))
              (if (marked? q)
                  (if (gc-pinned? q)
                      (if (%> (%+ q 8) free) (set! free (%+ q 8)) nil)
                      (set! free (%+ free 8)))
                  nil)
              (set! q (%+ q 8)))))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))
    free))

;; A block is eight pairs, which is one byte of the pin map, and the block
;; index is that byte's index.
(defsubst (gc-block-has-pins? b)
  (%> (%ld-byte (%+ gc-pinmap b)) 0))

;; Where a live pair is going: the block's entry plus eight bytes for every
;; live pair ahead of it in the block. That count is a popcount of the mark
;; bits below this one in a single byte. A pinned pair inside the block
;; breaks the rule, and then the block is replayed the way the plan walked
;; it.
(define (forward-cons p)
  (let ((b (cons-block-of p)))
    (if (gc-pinned? p)
        p
        (let ((free (%ld-fixnum (%+ gc-cons-prefix (%lsh b 2)))))
          (if (if (%= *pinned* 0) nil (gc-block-has-pins? b))
              (let ((q (%+ cons-base (%lsh b 6))))
                (while (%< q p)
                  (if (marked? q)
                      (if (gc-pinned? q)
                          (if (%> (%+ q 8) free) (set! free (%+ q 8)) nil)
                          (set! free (%+ free 8)))
                      nil)
                  (set! q (%+ q 8)))
                free)
              (%+ free
                  (%lsh (%popcount
                         (%logand
                          (%ld-byte (%+ gc-bitmap b))
                          (%- (%lsh 1 (%logand (%lsh (%- p gc-heap-lo) -3) 7)) 1)))
                        3)))))))

;; ---- an object compactor, built and not used ----
;; Objects could be slid the same way. What stops it is not the algorithm but
;; the window between update and move, during which the collector itself
;; calls functions and reaches constants through objects whose pointers have
;; already been rewritten. docs/moving-objects.md lists the ways round that.
(define (plan-objects hi)
  (let ((p obj-base) (free obj-base) (blk 0))
    (%st-fixnum! gc-obj-prefix obj-base)
    (%st-fixnum! gc-obj-first obj-base)
    (while (%< p hi)
      (let ((b (obj-block-of p)))
        (while (%< blk b)
          (set! blk (%+ blk 1))
          (%st-fixnum! (%+ gc-obj-prefix (%lsh blk 2)) free)
          (%st-fixnum! (%+ gc-obj-first (%lsh blk 2)) p)))
      (let ((size (obj-block-size (%ld-fixnum p))))
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (marked? p)
            (if (gc-pinned? p)
                (if (%> (%+ p size) free) (set! free (%+ p size)) nil)
                (set! free (%+ free size)))
            nil)
        (set! p (%+ p size))))
    (let ((last (obj-block-of hi)))
      (while (%< blk last)
        (set! blk (%+ blk 1))
        (%st-fixnum! (%+ gc-obj-prefix (%lsh blk 2)) free)
        (%st-fixnum! (%+ gc-obj-first (%lsh blk 2)) p)))
    free))

(define (forward-object p)
  (if (gc-pinned? p)
      p
      (let* ((b (obj-block-of p))
             (free (%ld-fixnum (%+ gc-obj-prefix (%lsh b 2))))
             (q (%ld-fixnum (%+ gc-obj-first (%lsh b 2)))))
        (while (%< q p)
          (let ((size (obj-block-size (%ld-fixnum q))))
            (if (marked? q)
                (if (gc-pinned? q)
                    (if (%> (%+ q size) free) (set! free (%+ q size)) nil)
                    (set! free (%+ free size)))
                nil)
            (set! q (%+ q size))))
        free)))

(define (move-objects hi)
  (let ((p obj-base) (n 0))
    (while (%< p hi)
      (let ((size (obj-block-size (%ld-fixnum p))))
        (if (marked? p)
            (let ((to (forward-object p)))
              (if (%= to p)
                  nil
                  (begin
                    (let ((i 0))
                      (while (%< i size)
                        (%st-word! (%+ to i) (%ld-word (%+ p i)))
                        (set! i (%+ i 4))))
                    (set! n (%+ n 1)))))
            nil)
        (set! p (%+ p size))))
    n))

;; Pairs move; objects answer their own address.
(defsubst (forward-value v)
  (if (%cons? v)
      (%from-addr (forward-cons (%addr-of v)))
      v))

;; Every pointer-bearing word of an object from slot `from` up to slot `to`,
;; with the push and the rewrite open-coded: this is every pointer in every
;; live object, once to mark and once to update.
(define (gc-slots base from to)
  (let ((p (%+ base (%lsh from 2)))
        (e (%+ base (%lsh to 2))))
    (if *updating*
        (while (%< p e) (gc-update-slot p) (set! p (%+ p 4)))
        (while (%< p e) (gc-push (%ld-word p)) (set! p (%+ p 4))))))

;; ---------------------------------------------------------------- update
;; Every pointer inside every live pair. The roots are updated through the
;; same walkers that found them, and the objects by `update-sweep-objects`.
(define (update-pairs cons-hi)
  (let ((p cons-base) (mp gc-bitmap))
    (while (%< p cons-hi)
      (if (gc-run-dead? mp)
          nil
          (let ((q p) (e (%+ p 256)))
            (if (%> e cons-hi) (set! e cons-hi) nil)
            (while (%< q e)
              (if (marked? q)
                  (begin (gc-update-slot q) (gc-update-slot (%+ q 4)))
                  nil)
              (set! q (%+ q 8)))))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))))

;; ---------------------------------------------------------------- move
;; A pinned pair stays where it is, so the pairs below it slide away and
;; leave a hole up to the pin. A hole worth having becomes a run on
;; `lg-cons-free`, which `refill-cons` hands out before fresh ground; the
;; hole's first cell can take the run's description as soon as the walk
;; reaches the pin, since nothing will be moved into it.
(define *gap-bytes* 0)       ; in holes handed to `lg-cons-free` this time

;; The walk is in address order, so the destination is a running pointer
;; rather than a lookup. It follows the rule `plan-cons` uses to
;; build the table.
(define (move-cons hi)
  (let ((p cons-base) (mp gc-bitmap) (free cons-base) (n 0) (live 0) (holes 0))
    (set! *run-last* 0)
    (%st-fixnum! lg-cons-free 0)
    (while (%< p hi)
      (if (gc-run-dead? mp)
          nil
          (let ((q p) (e (%+ p 256)))
            (if (%> e hi) (set! e hi) nil)
            (while (%< q e)
              (if (marked? q)
                  (begin
                    (set! live (%+ live 8))
                    (if (gc-pinned? q)
                        (begin
                          (if (%>= (%- q free) gap-min)
                              (begin (gc-add-run free q)
                                     (set! holes (%+ holes (%- q free))))
                              nil)
                          (if (%> (%+ q 8) free) (set! free (%+ q 8)) nil))
                        (begin
                          (if (%= free q)
                              nil
                              (begin
                                (%st-word! free (%ld-word q))
                                (%st-word! (%+ free 4) (%ld-word (%+ q 4)))
                                (set! n (%+ n 1))))
                          (set! free (%+ free 8)))))
                  nil)
              (set! q (%+ q 8)))))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))
    (set! *cons-live* live)
    (set! *gap-bytes* holes)
    n))

(define (blank lo hi)
  (let ((p lo))
    (while (%< p hi)
      (%st-fixnum! p 0)
      (set! p (%+ p 4)))))

;; ---------------------------------------------------------------- driver
;; After compaction no live pointer may name a pair above the new top. The
;; holes pinned pairs left are stepped over: they hold whatever pairs were
;; last there, garbage by construction. The chain of holes is in address
;; order, because the move built it walking upwards.
(define (verify top)
  (let ((p cons-base) (bad 0) (first 0) (hole (%ld-fixnum lg-cons-free)))
    (while (%< p top)
      (if (%= p hole)
          (begin (set! p (%ld-fixnum hole))
                 (set! hole (%ld-fixnum (%+ hole 4))))
          (let ((a (%ld-word p)) (d (%ld-word (%+ p 4))))
            (if (if (%cons? a) (%>= (%addr-of a) top) nil)
                (begin (if (%= first 0) (set! first p) nil) (set! bad (%+ bad 1)))
                nil)
            (if (if (%cons? d) (%>= (%addr-of d) top) nil)
                (begin (if (%= first 0) (set! first p) nil) (set! bad (%+ bad 1)))
                nil)
            (set! p (%+ p 8)))))
    (uart-string "  verify: ")
    (uart-num bad)
    (uart-string " dangling, first at ")
    (uart-hex first)
    (uart-nl)
    bad))

;; Right after a whole cycle, whose mark bits and pins are still those of
;; the heap as it stands: nothing has been allocated in between. Interrupts
;; off throughout. Afterwards the maps are stale everywhere below the
;; frontiers, and the next cycle clears them whole.
(define (compact)
  (let* ((cons-hi (%ld-fixnum lg-cons-ptr))
         (obj-hi (%ld-fixnum lg-obj-ptr))
         (cons-top (plan-cons cons-hi)))
    (if *check*
        (begin
          (uart-string "  plan: hi=") (uart-hex cons-hi)
          (uart-string " top=") (uart-hex cons-top)
          (uart-string " live=") (uart-num (%lsh (%- cons-top cons-base) -3))
          (uart-nl))
        nil)
    ;; Rewrite every pointer to a pair. Nothing may follow a pair between
    ;; here and the slide.
    (set! *updating* t)
    (roots)
    (update-pairs cons-hi)
    (set! *obj-freed* (update-sweep-objects obj-hi))
    (set! *updating* nil)
    (set! *moved* (move-cons cons-hi))
    (if *check* (verify cons-top) nil)
    (if (%> cons-hi *cons-dirty-top*) (set! *cons-dirty-top* cons-hi) nil)
    (%st-fixnum! lg-cons-ptr cons-top)
    ;; An empty run for this task; every suspended task keeps only the cell
    ;; its run was about to use (see `invalidate-runs` in exec.lisp). The
    ;; next cons finds no room and asks for a run: a hole the move left behind
    ;; a pinned pair while there are any, and fresh ground after them.
    (%st-fixnum! lg-cons-run cons-top)
    (%st-fixnum! lg-cons-run-end cons-top)
    (%st-fixnum! lg-cons-free-n (%+ (%lsh (%- cons-limit cons-top) -3)
                                     (%lsh *gap-bytes* -3)))
    (%reload-cons-run)
    (invalidate-runs)
    (set-budget)
    (%lsh (%- cons-limit cons-top) -3)))

;; ---------------------------------------------------------------- code space
;; Code is collected but not moved: this collector runs as compiled code, and
;; sliding the function it is standing in is not possible. Liveness needs no
;; special rule: a closure holds its code object, a frame holds its closure,
;; and a running function's literal vector is its own code object in s1.
;;
;; The registry of code objects is a plain array in the pool, not a list in
;; the heap: a list would be a root, and a root would keep every version of
;; every function alive.

(define code-registry-max 65536)

(define (code-registry)
  (let ((r (%ld-fixnum lg-code-reg)))
    (if (%> r 0)
        r
        (let ((a (alloc-pool (%lsh code-registry-max 2))))
          (%st-fixnum! lg-code-reg a)
          (%st-fixnum! lg-code-reg-n 0)
          a))))

(define (register-code obj)
  (without-interrupts
  (let ((r (code-registry))
        (n (%ld-fixnum lg-code-reg-n)))
    (if (%>= n code-registry-max)
        (error "code registry full")
        nil)
    (%st-word! (%+ r (%lsh n 2)) obj)
    (%st-fixnum! lg-code-reg-n (%+ n 1))
    obj)))

;; Free blocks describe themselves: size first, then the next block.
(define (code-take size)
  (let ((prev 0) (p (%ld-fixnum lg-code-free)) (got 0))
    (while (if (%= got 0) (%> p 0) nil)
      (let ((have (%ld-fixnum p)) (next (%ld-fixnum (%+ p 4))))
        (if (%>= have size)
            (begin
              (if (%= prev 0)
                  (%st-fixnum! lg-code-free next)
                  (%st-fixnum! (%+ prev 4) next))
              ;; the tail stays a block if it can hold a header
              (if (%>= (%- have size) 16)
                  (code-free-block (%+ p size) (%- have size))
                  nil)
              (set! got p))
            (begin (set! prev p) (set! p next)))))
    got))

(define (code-free-block p size)
  (%st-fixnum! p size)
  (%st-fixnum! (%+ p 4) (%ld-fixnum lg-code-free))
  (%st-fixnum! lg-code-free p)
  (%st-fixnum! lg-code-free-n (%+ (%ld-fixnum lg-code-free-n) size)))

;; A free list and a bump pointer, like object space.
(define (alloc-code nbytes)
  (without-interrupts
  (let* ((size (%logand (%+ nbytes 7) -8))
         (p (code-take size)))
    (if (%> p 0)
        (begin (%st-fixnum! lg-code-free-n (%- (%ld-fixnum lg-code-free-n) size)) p)
        (let ((q (%ld-fixnum lg-code-ptr)))
          (if (%> (%+ q size) (%ld-fixnum lg-code-end))
              (out-of-memory "code space")
              nil)
          (%st-fixnum! lg-code-ptr (%+ q size))
          q)))))

;; Compact the registry in place, a stretch at a time, keeping the entries
;; whose code object survived and handing the rest of code space back. The
;; entries are those the registry held when marking finished; anything
;; registered since sits above them, unmarked but not this cycle's business,
;; and is moved down behind the survivors at the end. The tail that leaves
;; is cleared: those words are stale object pointers in the pool, and
;; anything reading the pool has to treat them as live. A code object made
;; while marking is black, like any other object, so it is kept. Answers
;; the entries walked.
(define *code-i* 0)
(define *code-keep* 0)
(define *code-n* 0)
(define sweep-code-entries 1024)

(define (sweep-code-some)
  (let* ((r (code-registry))
         (n *code-n*)
         (start *code-i*)
         (i start)
         (keep *code-keep*)
         (lim (%+ i sweep-code-entries))
         (hi (if (%< lim n) lim n))
         (freed 0))
    (while (%< i hi)
      (let ((obj (%ld-word (%+ r (%lsh i 2)))))
        (if (marked? (%- (%addr-of obj) 4))
            (begin
              (%st-word! (%+ r (%lsh keep 2)) obj)
              (set! keep (%+ keep 1)))
            (let ((entry (%addr-of (%ld-word (%addr-of obj))))
                  (len (%addr-of (%ld-word (%+ (%addr-of obj) 4)))))
              (if (%>= len 16)
                  (begin (code-free-block entry len) (set! freed (%+ freed len)))
                  nil))))
      (set! i (%+ i 1)))
    (if (%>= i n)
        (let ((now (%ld-fixnum lg-code-reg-n)) (j n))
          (while (%< j now)
            (%st-word! (%+ r (%lsh keep 2)) (%ld-word (%+ r (%lsh j 2))))
            (set! keep (%+ keep 1))
            (set! j (%+ j 1)))
          (set! j keep)
          (while (%< j now)
            (%st-word! (%+ r (%lsh j 2)) 0)
            (set! j (%+ j 1)))
          (%st-fixnum! lg-code-reg-n keep))
        nil)
    (set! *code-i* i)
    (set! *code-keep* keep)
    (set! *code-freed* (%+ *code-freed* freed))
    (%- i start)))

;; ---------------------------------------------------------------- images
;; Zeroing the inside of every free block in object space makes a page with
;; nothing live on it a page of zeroes, which the image writer skips. Far too
;; expensive for an ordinary collection.
(define (blank-free-objects)
  (let ((p obj-base)
        (hi (%ld-fixnum lg-obj-ptr))
        (zeroed 0))
    (while (%< p hi)
      (let* ((h (%ld-fixnum p))
             (size (obj-block-size h)))
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (%= (%logand h 255) t-free)
            ;; words 0 and 1 are the block's size and its place on the chain
            (begin
              (blank (%+ p 8) (%+ p size))
              (set! zeroed (%+ zeroed (%- size 8))))
            nil)
        (set! p (%+ p size))))
    zeroed))

;; The same for the code that sweeping freed. A rebuild allocates its new
;; code above the old, so without this every dead byte goes into the file.
(define (blank-free-code)
  (let ((p (%ld-fixnum lg-code-free)))
    (while (%> p 0)
      (let ((size (%ld-fixnum p)) (next (%ld-fixnum (%+ p 4))))
        (if (%> size 8) (blank (%+ p 8) (%+ p size)) nil)
        (set! p next)))))

;; The holes pinned pairs left lie below the top of cons space and go into
;; the file: everything but the two words that make each one a run.
(define (blank-cons-holes)
  (let ((r (%ld-fixnum lg-cons-free)))
    (while (%> r 0)
      (blank (%+ r 8) (%ld-fixnum r))
      (set! r (%ld-fixnum (%+ r 4))))))

;; ---- idle symbols ----
;; An image carries every symbol the reader ever interned, and most of them
;; are the names of local variables: unbound, unreferenced, and in the way of
;; every lookup that walks their bucket. Before an image is collected the
;; idle ones are taken out of the obarray and the symbol list. The collection
;; then keeps the ones something still refers to, a quoted symbol in
;; compiled code or a record's tag, and those go back afterwards. The rest are
;; garbage, and a later read of the same name interns a fresh symbol.
;;
;; The candidates wait in a pool block while the collection runs, because
;; the pool is not scanned: a list of them on the stack would be a root.

(define (symbol-idle? s)
  (if (%eq? (%symbol-value s) (%unbound))
      (if (%symbol-function s)
          nil
          (if (%symbol-plist s)
              nil
              (if (symbol-exported? s) nil (if (symbol-package s) t nil))))
      nil))

(define (symbol-bucket s)
  (%mod (qualified-hash (package-name (symbol-package s)) (%symbol-name s))
        (%vector-length (%ld-word lg-obarray))))

;; Splice every idle symbol out of a list, in place, allocating nothing.
(define (drop-idle-symbols l)
  (let ((head l))
    (while (if (%cons? head) (symbol-idle? (%car head)) nil)
      (set! head (%cdr head)))
    (let ((prev head))
      (while (%cons? prev)
        (let ((next (%cdr prev)))
          (if (if (%cons? next) (symbol-idle? (%car next)) nil)
              (%set-cdr! prev (%cdr next))
              (set! prev next)))))
    head))

;; Answers a pool block holding the count and then the addresses of the
;; detached symbols, or 0 when there are none.
(define (detach-idle-symbols)
  (let ((n 0) (l (%ld-word lg-symlist)))
    (while (%cons? l)
      (if (symbol-idle? (%car l)) (set! n (%+ n 1)) nil)
      (set! l (%cdr l)))
    (if (%= n 0)
        0
        (let ((a (alloc-pool (%* 4 (%+ n 1)))) (i 1))
          (set! l (%ld-word lg-symlist))
          (while (%cons? l)
            (let ((s (%car l)))
              (if (symbol-idle? s)
                  (begin
                    (%st-fixnum! (%+ a (%* 4 i)) (%addr-of s))
                    (set! i (%+ i 1)))
                  nil))
            (set! l (%cdr l)))
          (%st-fixnum! a n)
          (let ((ob (%ld-word lg-obarray)) (k 0) (nb (%vector-length (%ld-word lg-obarray))))
            (while (%< k nb)
              (%vector-set! ob k (drop-idle-symbols (%vector-ref ob k)))
              (set! k (%+ k 1))))
          (%st-word! lg-symlist (drop-idle-symbols (%ld-word lg-symlist)))
          a))))

;; After the collection: the mark bits are still those of the collection
;; just done, and objects do not move, so a detached symbol's bit says
;; whether anything reached it.
(define (reattach-marked-symbols a)
  (if (%= a 0)
      0
      (let ((n (%ld-fixnum a)) (i 1) (kept 0) (ob (%ld-word lg-obarray)))
        (while (%<= i n)
          (let ((p (%ld-fixnum (%+ a (%* 4 i)))))
            (if (marked? (%- p 4))
                (let* ((s (%from-addr p)) (b (symbol-bucket s)))
                  (%vector-set! ob b (%cons s (%vector-ref ob b)))
                  (%st-word! lg-symlist (%cons s (%ld-word lg-symlist)))
                  (set! kept (%+ kept 1)))
                nil))
          (set! i (%+ i 1)))
        ;; The block held raw addresses, which a conservative scan of the pool
        ;; would take for references.
        (blank a (%+ a (%* 4 (%+ n 1))))
        (free-pool a)
        kept)))

;; Collect for an image: drop the idle symbols, collect, compact the pairs,
;; and blank what was reclaimed so that the file is the size of what is in
;; it. The pin map holds every guess a cycle ever made, so it is cleared
;; before the cycle whose pins the compactor will honour; and the mark map
;; is cleared afterwards, because the pairs it described have moved.
;;
;; The reattached symbols' pairs come out of a run carved above the live
;; data: the holes the compactor left behind pinned pairs are put out of the
;; allocator's reach for that step, because a run taken from one of them
;; lies below live pairs, and the high-water mark is about to be dropped to
;; the last pair made. The run goes back to memory, where the reset stub and
;; a resume read it, and what is left of it is given back, so the file holds
;; the live pairs and nothing else.
(define (collect-for-image)
  (let ((idle (detach-idle-symbols)))
    (without-interrupts
      (clear-bitmap)
      (set! *keep-marks* t)
      (collect)
      (compact)
      (set! *keep-marks* nil)
      (let ((holes (%ld-fixnum lg-cons-free)) (last *run-last*))
        (%st-fixnum! lg-cons-free 0)
        (set! *run-last* 0)
        (reattach-marked-symbols idle)
        (%sync-cons-run)
        (let ((top (%ld-fixnum lg-cons-run)))
          (%st-fixnum! lg-cons-ptr top)
          (%st-fixnum! lg-cons-run-end top)
          (%reload-cons-run)
          (blank top *cons-dirty-top*))
        (%st-fixnum! lg-cons-free holes)
        (set! *run-last* last))
      (clear-bitmap)))
  (blank-cons-holes)
  (blank-free-objects)
  (blank-free-code))

;; ---------------------------------------------------------------- reporting
(define (room)
  (emit-str "cons free ")
  (emit-str (number->string (%ld-fixnum lg-cons-free-n)))
  (emit-str " of ")
  (emit-str (number->string (%lsh (%- cons-limit cons-base) -3)))
  (emit-str ", object bytes used ")
  (emit-str (number->string (%- (%ld-fixnum lg-obj-ptr) obj-base)))
  (emit-str ", code bytes used ")
  (emit-str (number->string
             (%- (%- (%ld-fixnum lg-code-ptr) code-base) (%ld-fixnum lg-code-free-n))))
  (emit-str ", collections ")
  (emit-str (number->string *count*))
  (if (busy?) (emit-str ", one in progress") nil)
  (newline)
  ;; The pool is the other heap: raw, unmoving, where stacks and command
  ;; blocks come from, and the one that runs out quietly.
  (emit-str "pool bytes claimed ")
  (emit-str (number->string (pool-used)))
  (emit-str ", free ")
  (emit-str (number->string (pool-free-bytes)))
  (emit-str " of ")
  (emit-str (number->string (%- pool-limit pool-base)))
  (newline)
  nil)

;; ---------------------------------------------------------------- namespaces
;; A package the forge needed and the machine cannot use: boot.lisp and
;; hostio.lisp are read by the forge and never compiled, so the packages they
;; declare reach the machine holding nothing. Dropping them before the image
;; is collected keeps them out of the file, and the test is what they hold.

(define (symbol-holds-anything? s)
  (if (%eq? (%symbol-value s) (%unbound))
      (if (%symbol-function s) t (if (%symbol-plist s) t nil))
      t))

(define (package-in-use? p)
  (let ((l (%ld-word lg-symlist)) (used nil))
    (while (%cons? l)
      (let ((s (%car l)))
        (if (%eq? (symbol-package s) p)
            (if (symbol-holds-anything? s) (set! used t) nil)
            nil))
      (set! l (if used nil (%cdr l))))
    used))

(define (mine? p s) (%eq? (symbol-package s) p))

;; Splice this package's symbols out of a list, in place, allocating nothing.
(define (drop-symbols-of p l)
  (let ((head l))
    (while (if (%cons? head) (mine? p (%car head)) nil)
      (set! head (%cdr head)))
    (let ((prev head))
      (while (%cons? prev)
        (let ((next (%cdr prev)))
          (if (if (%cons? next) (mine? p (%car next)) nil)
              (%set-cdr! prev (%cdr next))
              (set! prev next)))))
    head))

;; Out of the obarray, the symbol list and the package list. The symbols go
;; when the collector next runs, unless something still holds one.
(define (forget-package p)
  (let* ((ob (%ld-word lg-obarray))
         (n (%vector-length ob))
         (i 0))
    (while (%< i n)
      (%vector-set! ob i (drop-symbols-of p (%vector-ref ob i)))
      (set! i (%+ i 1))))
  (%st-word! lg-symlist (drop-symbols-of p (%ld-word lg-symlist)))
  (%st-word! lg-packages (remove-eq p (%ld-word lg-packages)))
  p)

;; Answers the names dropped.
(define (forget-unused-packages)
  (let ((dropped nil))
    (dolist (p (list-copy (all-packages)))
      (if (package-in-use? p)
          nil
          (begin (forget-package p)
                 (set! dropped (%cons (package-name p) dropped)))))
    dropped))

;; What the prelude's `alloc-object` calls. The kickstart installs these
;; before anything can allocate. The functions themselves, not lambdas
;; wrapping them: a closure would have to be allocated first.
(define (install-allocator)
  (set! *object-allocator* obj-take)
  (set! *collector* collect)
  (set! *pacer* pace)
  nil)

;; A whole collection now, at the prompt: a cycle driven to its end, with
;; interrupts on between the slices, so the rest of the machine goes on
;; running. Answers the free pairs.
(define (gc)
  (without-interrupts (if (%= *phase* phase-idle) (start-cycle) nil))
  (while (busy?) (step))
  (%ld-fixnum lg-cons-free-n))
