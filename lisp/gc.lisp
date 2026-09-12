;;; gc.lisp - the collector.
;;;
;;; Mark, then compact the pairs and sweep the objects in place. Roots are
;;; found precisely from the frame chain; only the register set of a task
;;; suspended mid-expression is scanned conservatively, and whatever those
;;; words reach is pinned for the cycle.
;;;
;;; Pairs move and objects do not, because this collector is written in the
;;; language it collects: it reaches its functions through symbol value cells
;;; and its constants through the literal vector of its own code object, and
;;; every one of those is an object. Moving them would leave the collector
;;; unable to run. Pairs are safe because nothing between updating and sliding
;;; dereferences one, and pairs are where the space is.
;;;
;;; Moving anything is possible because compiled code contains no heap
;;; addresses: a function reaches its symbols and constants through the
;;; literal vector in s1. The Exec pool is a separate heap, raw, unmoving and
;;; never scanned, holding stacks, register contexts and command blocks.
;;;
;;; Cons space is handed out in runs: the inline allocator bumps a pointer
;;; inside a run and only crossing to the next one costs a call.
;;;
;;; Nothing in this file may allocate. `let` and `while` are free; `%cons` is
;;; not, and anything that conses would recurse into the condition being
;;; handled.

(in-package gc)

;; ---------------------------------------------------------------- geometry
(define gc-heap-lo cons-base)
(define gc-heap-hi obj-limit)
;; One mark bit per eight bytes of heap, in scratch memory above fast-base.
(define gc-bitmap fast-base)
(define gc-bitmap-size (%lsh (%- gc-heap-hi gc-heap-lo) -6))
;; A second bitmap of the same shape for objects that must not move because
;; something found them by guessing.
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
(define *gc-count* 0)
(define *t-clear* 0)
(define *t-roots* 0)
(define *t-drain* 0)
(define *t-code* 0)
(define *t-compact* 0)
(define *t-obj* 0)
(define *t-plan* 0)
(define *t-upd* 0)
(define *t-mv* 0)
(define *t-blank* 0)
(define *t-mark* 0)
(define *gc-cycles* 0)
(define *gc-verbose* nil)
;; A full extra pass over the live pairs after every compaction, reporting
;; pointers that still name a pair above the new top. Off unless debugging.
(define *gc-check* nil)

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

(defsubst (gc-marked? p) (%bit-ref gc-bitmap (gc-bit-index p)))
(defsubst (gc-mark! p) (%bit-set! gc-bitmap (gc-bit-index p)))
(defsubst (gc-pinned? p) (%bit-ref gc-pinmap (gc-bit-index p)))
(defsubst (gc-pin! p) (%bit-set! gc-pinmap (gc-bit-index p)))

;; The maps are cleared with the blitter, and only as far as the two
;; allocation pointers reach: a mark can only land below them.
(define gc-clear-w 1024)

(define (gc-map-byte p) (%lsh (%- p gc-heap-lo) -6))

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

(define (gc-clear-map base)
  (let ((c0 (gc-map-byte cons-base))
        (c1 (%+ (gc-map-byte (%ld-fixnum lg-cons-ptr)) 1))
        (o0 (gc-map-byte obj-base))
        (o1 (%+ (gc-map-byte (%ld-fixnum lg-obj-ptr)) 1)))
    (gc-fill-bytes (%+ base c0) (%- c1 c0))
    (gc-fill-bytes (%+ base o0) (%- o1 o0)))
  nil)

(defsubst (gc-bit? map i) (%bit-ref map i))

;; ---------------------------------------------------------------- skipping
;; A word of the mark bitmap covers thirty-two pairs, or 256 bytes of heap.
;; Where that word is zero the whole run is dead and the three passes over
;; cons space step over it. Each pass walks a pointer into the bitmap beside
;; its pointer into the heap, four bytes of map to 256 of heap. The 256 is
;; written into the loops because a literal compiles to one instruction where
;; a global costs two loads.
;;
;; The word is read as two halves on purpose: a tagged load drops bit 31, so
;; a map word of 0x80000000, only the last pair of the run live, would read
;; as zero and the pair would be lost. `%ld-half` is a zero-extending load
;; and cannot lose a bit.
(defsubst (gc-run-dead? mp)
  (if (%= 0 (%ld-half mp)) (%= 0 (%ld-half (%+ mp 2))) nil))

;; The clears are blits, and a blit is not finished when it returns; marking
;; must not start until they have landed.
(define (gc-clear-bitmap)
  (gc-clear-map gc-bitmap)
  (gc-clear-map gc-pinmap)
  (blit-wait-ring *gc-blit-ring*))

;; ---------------------------------------------------------------- marking
;; Is this word something the heap could have handed out? Asked about tagged
;; values and about arbitrary words found on a stack, so it must never say
;; yes to something it would then dereference wrongly: an object has to lie
;; below the allocation pointer and carry a header with a plausible type.
(defsubst (gc-heap-pointer? v)
  (cond
   ((%cons? v)
    (let ((p (%addr-of v)))
      (if (%>= p cons-base) (%< p (%ld-fixnum lg-cons-ptr)) nil)))
   ((%object? v)
    (let ((p (%- (%addr-of v) 4)))
      (if (%>= p obj-base)
          (if (%< p (%ld-fixnum lg-obj-ptr))
              (let ((ty (%logand (%ld-fixnum p) 255)))
                (if (%>= ty 1) (%<= ty 10) nil))
              nil)
          nil)))
   (else nil)))

;; Where the mark bit for this value lives: a pair marks at the pair, an
;; object at its header.
(defsubst (gc-block-of v)
  (if (%cons? v) (%addr-of v) (%- (%addr-of v) 4)))

;; Open-coded: the mark phase asks this twice for every live pair.
(defsubst (gc-push v)
  (if (gc-heap-pointer? v)
      (let ((b (gc-block-of v)))
        (if (gc-marked? b)
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

(define (gc-drain)
  (while (%> *mark-sp* 0)
    (set! *mark-sp* (%- *mark-sp* 1))
    (let ((v (%ld-word (%+ gc-stack (%lsh *mark-sp* 2)))))
      (if (%cons? v)
          (begin (gc-push (%car v)) (gc-push (%cdr v)))
          (gc-scan-object v)))))

;; ---------------------------------------------------------------- roots
;; One pointer-bearing word, during the update pass: rewritten to where its
;; target is going.
(defsubst (gc-update-slot addr)
  (let ((v (%ld-word addr)))
    (if (gc-heap-pointer? v) (%st-word! addr (gc-forward-value v)) nil)))

;; One pointer-bearing word, in whichever pass this is. Every traversal goes
;; through here or `gc-update-slot`, so the same walk serves marking and
;; updating.
(define (gc-slot addr)
  (let ((v (%ld-word addr)))
    (if *gc-updating*
        (if (gc-heap-pointer? v) (%st-word! addr (gc-forward-value v)) nil)
        (gc-push v))))

(define (gc-scan-range lo hi)
  (let ((p (%logand lo -4)))
    (while (%< p hi)
      (gc-slot p)
      (set! p (%+ p 4)))))

;; Words that might be pointers and might be integers. Anything reached this
;; way is marked and pinned, and the word itself is never rewritten: a pinned
;; object forwards to itself, so a number that happens to look like an
;; address stays a number.
(define *pinned* 0)

(define (gc-scan-conservative lo hi)
  (let ((p (%logand lo -4)))
    (while (%< p hi)
      (let ((v (%ld-word p)))
        (if (if *gc-updating* nil (gc-heap-pointer? v))
            (begin
              (set! *pinned* (%+ *pinned* 1))
              (gc-pin! (gc-block-of v))
              (gc-push v))
            nil))
      (set! p (%+ p 4)))))

;; ---------------------------------------------------------------- stacks
;; A frame base is a word-aligned address inside the pool, where every stack
;; lives. Zero ends the walk: the reset stub leaves it in s0 before it enters
;; Lisp.
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
          (gc-slot (%+ base (%+ stub-args-off (%* 4 i))))
          nil)
      (set! i (%+ i 1)))))

;; The chain of Lisp frames, precisely. Every word from a frame's stack
;; pointer up to and including its closure slot is a tagged value; only the
;; saved return address and frame link are raw, at fixed offsets; and a
;; callee's frame base is its caller's stack pointer. So the chain alone gives
;; every frame's extent, with no stack maps.
(define (gc-scan-frames sp0 s00)
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

;; Replaced by exec.lisp once the kernel is up, to walk every task's stack.
(define (gc-extra-roots) nil)

;; Every root is named by the address of the word holding it, not by its
;; value, because the update pass has to write the new value back.
(define (gc-roots)
  (gc-slot lg-symlist)
  (gc-slot lg-obarray)
  (gc-slot lg-packages)
  (gc-slot lg-package)
  (gc-slot lg-bootlist)
  (gc-slot lg-roots)
  (gc-slot lg-toplevel)
  (gc-slot lg-errhandler)
  (gc-slot lg-traphook)
  (gc-slot lg-refill)
  (gc-slot lg-startup)
  (gc-slot lg-scratch0)
  ;; The running task is a register, so there is no slot to rewrite; it is a
  ;; record, which does not move, so marking is the whole job.
  (if *gc-updating* nil (gc-push (%this-task)))
  ;; This task's own stack, from where it stands.
  (gc-scan-frames (%stack-pointer) (%frame-pointer))
  ;; Every other task's stack and registers.
  (gc-extra-roots))

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

;; One walk over object space does both halves: live objects have their
;; pointers to pairs rewritten, dead ones are gathered into free blocks.
;; Called with `*gc-updating*` set, between the update of the pairs and their
;; move. A dead run at the very top lowers the frontier instead of becoming a
;; free block.
(define (gc-update-sweep-objects hi)
  (let ((p obj-base)
        (run 0)
        (runlen 0)
        (nfree 0))
    (gc-clear-bins)
    (while (%< p hi)
      (let ((size (obj-block-size (%ld-fixnum p))))
        ;; A zero size is a corrupt header and would spin here for ever.
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (gc-marked? p)
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

(define (gc-corrupt p)
  (uart-string "gc: corrupt object header at ")
  (uart-hex p)
  (uart-nl)
  (%halt exit-gc-corrupt))

;; ================================================================ compaction
;;
;; Sliding compaction of cons space, in four passes:
;;
;;   1. mark        done by the time this runs
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

(define *gc-updating* nil)
(define *gc-moved* 0)
(define *obj-freed* 0)
(define *gc-compacted* nil)

;; ---------------------------------------------------------------- forwarding
(defsubst (cons-block-of p) (%lsh (%- p cons-base) -6))
(defsubst (obj-block-of p) (%lsh (%- p obj-base) -10))

;; One walk over the pairs, recording the free pointer on the way into each
;; block that holds a live pair. Answers where the live region will end. A
;; dead run needs no entries: `gc-forward-cons` is only asked about live
;; pairs.
(define (gc-plan-cons hi)
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
              (if (gc-marked? q)
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
(define (gc-forward-cons p)
  (let ((b (cons-block-of p)))
    (if (gc-pinned? p)
        p
        (let ((free (%ld-fixnum (%+ gc-cons-prefix (%lsh b 2)))))
          (if (if (%= *pinned* 0) nil (gc-block-has-pins? b))
              (let ((q (%+ cons-base (%lsh b 6))))
                (while (%< q p)
                  (if (gc-marked? q)
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
(define (gc-plan-objects hi)
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
        (if (gc-marked? p)
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

(define (gc-forward-object p)
  (if (gc-pinned? p)
      p
      (let* ((b (obj-block-of p))
             (free (%ld-fixnum (%+ gc-obj-prefix (%lsh b 2))))
             (q (%ld-fixnum (%+ gc-obj-first (%lsh b 2)))))
        (while (%< q p)
          (let ((size (obj-block-size (%ld-fixnum q))))
            (if (gc-marked? q)
                (if (gc-pinned? q)
                    (if (%> (%+ q size) free) (set! free (%+ q size)) nil)
                    (set! free (%+ free size)))
                nil)
            (set! q (%+ q size))))
        free)))

(define (gc-move-objects hi)
  (let ((p obj-base) (n 0))
    (while (%< p hi)
      (let ((size (obj-block-size (%ld-fixnum p))))
        (if (gc-marked? p)
            (let ((to (gc-forward-object p)))
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
(defsubst (gc-forward-value v)
  (if (%cons? v)
      (%from-addr (gc-forward-cons (%addr-of v)))
      v))

;; Every pointer-bearing word of an object from slot `from` up to slot `to`,
;; with the push and the rewrite open-coded: this is every pointer in every
;; live object, once to mark and once to update.
(define (gc-slots base from to)
  (let ((p (%+ base (%lsh from 2)))
        (e (%+ base (%lsh to 2))))
    (if *gc-updating*
        (while (%< p e) (gc-update-slot p) (set! p (%+ p 4)))
        (while (%< p e) (gc-push (%ld-word p)) (set! p (%+ p 4))))))

;; ---------------------------------------------------------------- update
;; Every pointer inside every live pair. The roots are updated through the
;; same walkers that found them, and the objects by `gc-update-sweep-objects`.
(define (gc-update-pairs cons-hi)
  (let ((p cons-base) (mp gc-bitmap))
    (while (%< p cons-hi)
      (if (gc-run-dead? mp)
          nil
          (let ((q p) (e (%+ p 256)))
            (if (%> e cons-hi) (set! e cons-hi) nil)
            (while (%< q e)
              (if (gc-marked? q)
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
(define gc-gap-min 1024)
(define *gap-bytes* 0)       ; in holes handed to `lg-cons-free` this time
(define *cons-live* 0)       ; bytes of pairs the last collection kept

;; The walk is in address order, so the destination is a running pointer
;; rather than a lookup. It follows the rule `gc-plan-cons` uses to
;; build the table.
(define (gc-move-cons hi)
  (let ((p cons-base) (mp gc-bitmap) (free cons-base) (n 0) (live 0) (holes 0))
    (set! *run-last* 0)
    (%st-fixnum! lg-cons-free 0)
    (while (%< p hi)
      (if (gc-run-dead? mp)
          nil
          (let ((q p) (e (%+ p 256)))
            (if (%> e hi) (set! e hi) nil)
            (while (%< q e)
              (if (gc-marked? q)
                  (begin
                    (set! live (%+ live 8))
                    (if (gc-pinned? q)
                        (begin
                          (if (%>= (%- q free) gc-gap-min)
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

;; The highest cons space has ever reached. Everything between the allocation
;; pointer and this is dead and dirty; it is blanked only for an image, so
;; that the file is the size of what is in it.
(define *cons-dirty-top* 0)

(define (gc-blank lo hi)
  (let ((p lo))
    (while (%< p hi)
      (%st-fixnum! p 0)
      (set! p (%+ p 4)))))

;; ---------------------------------------------------------------- driver
;; After compaction no live pointer may name a pair above the new top. The
;; holes pinned pairs left are stepped over: they hold whatever pairs were
;; last there, garbage by construction. The chain of holes is in address
;; order, because the move built it walking upwards.
(define (gc-verify top)
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

(define (gc-compact)
  (set! *t-mark* (%cycles))
  (let* ((cons-hi (%ld-fixnum lg-cons-ptr))
         (obj-hi (%ld-fixnum lg-obj-ptr))
         (cons-top (gc-plan-cons cons-hi)))
    (if *gc-check*
        (begin
          (uart-string "  plan: hi=") (uart-hex cons-hi)
          (uart-string " top=") (uart-hex cons-top)
          (uart-string " live=") (uart-num (%lsh (%- cons-top cons-base) -3))
          (uart-nl))
        nil)
    ;; Rewrite every pointer to a pair. Nothing may follow a pair between
    ;; here and the slide.
    (set! *t-plan* (%- (%cycles) *t-mark*))
    (set! *gc-updating* t)
    (gc-roots)
    (set! *t-upd* (%cycles))
    (gc-update-pairs cons-hi)
    (set! *t-upd* (%- (%cycles) *t-upd*))
    (set! *t-obj* (%cycles))
    (set! *obj-freed* (gc-update-sweep-objects obj-hi))
    (set! *t-obj* (%- (%cycles) *t-obj*))
    (set! *gc-updating* nil)
    (set! *t-mv* (%cycles))
    (set! *gc-moved* (gc-move-cons cons-hi))
    (set! *t-mv* (%- (%cycles) *t-mv*))
    (if *gc-check* (gc-verify cons-top) nil)
    (if (%> cons-hi *cons-dirty-top*) (set! *cons-dirty-top* cons-hi) nil)
    (%st-fixnum! lg-cons-ptr cons-top)
    ;; An empty run for this task; every suspended task keeps only the cell
    ;; its run was about to use (see `gc-invalidate-runs` in exec.lisp). The
    ;; next cons finds no room and asks for a run: a hole the move left behind
    ;; a pinned pair while there are any, and fresh ground after them.
    (%st-fixnum! lg-cons-run cons-top)
    (%st-fixnum! lg-cons-run-end cons-top)
    (%st-fixnum! lg-cons-free-n (%+ (%lsh (%- cons-limit cons-top) -3)
                                     (%lsh *gap-bytes* -3)))
    (%reload-cons-run)
    (gc-invalidate-runs)
    (set! *gc-compacted* t)
    (%lsh (%- cons-limit cons-top) -3)))

;; ---------------------------------------------------------------- when
;; A collection costs the live data plus the heap it walks, and the heap it
;; walks is everything below the two frontiers. One comes when the bytes
;; allocated since the last reach twice the live data or eight megabytes,
;; whichever is more, so the heap walked stays a small multiple of what is
;; live. Live is what the last collection kept, not how high the frontiers
;; stand: a pinned pair can hold a frontier up.
(define gc-budget-min 8388608)
(define *gc-budget* gc-budget-min)    ; bytes allowed between collections
(define *gc-allocated* 0)             ; object bytes handed out since the last
(define *cons-given* 0)               ; and bytes of cons runs

(define (gc-over-budget?)
  (%> (%+ *gc-allocated* *cons-given*) *gc-budget*))

(define (gc-set-budget)
  (let ((live (%+ (%- (%- (%ld-fixnum lg-obj-ptr) obj-base) (%ld-fixnum lg-obj-free-n))
                  *cons-live*)))
    (set! *gc-allocated* 0)
    (set! *cons-given* 0)
    (set! *gc-budget* (if (%> (%* 2 live) gc-budget-min) (%* 2 live) gc-budget-min))))

;; Everything above fast-base, the maps, the mark stack and the forwarding
;; tables, is scratch that no image saves, and is rebuilt from nothing at
;; the start of every collection.
;;
;; Interrupts are off for the whole collection and put back as they were.
(define (gc-collect)
  (let ((t0 (%cycles)))
    (without-interrupts
      ;; Runs are carved out of lg-cons-ptr, so it is already above every
      ;; pair anyone has been handed; what a task has not used of its run is
      ;; simply unmarked.
      (set! *mark-sp* 0)
      (set! *pinned* 0)
      (set! *t-clear* (%- (%cycles) t0))
      (gc-clear-bitmap)
      (set! *t-clear* (%- (%- (%cycles) t0) *t-clear*))
      (set! *t-roots* (%- (%cycles) t0))
      (gc-roots)
      (set! *t-roots* (%- (%- (%cycles) t0) *t-roots*))
      (set! *t-drain* (%- (%cycles) t0))
      (gc-drain)
      (set! *t-drain* (%- (%- (%cycles) t0) *t-drain*))
      ;; Code before objects: sweeping object space writes free-list links
      ;; over dead objects' first slots, and a dead code object's first slot
      ;; is the address of the code it owns.
      (set! *t-code* (%- (%cycles) t0))
      (let ((k (gc-sweep-code))
            (c (begin (set! *t-code* (%- (%- (%cycles) t0) *t-code*))
                      (set! *t-compact* (%- (%cycles) t0))
                      (let ((v (gc-compact)))
                        (set! *t-compact* (%- (%- (%cycles) t0) *t-compact*))
                        v)))
            (o *obj-freed*))
        (gc-set-budget)
        (set! *gc-count* (%+ *gc-count* 1))
        (set! *gc-cycles* (%+ *gc-cycles* (%- (%cycles) t0)))
        (%st-fixnum! lg-gccount *gc-count*)
        ;; Straight to the serial line: no allocation inside a collection.
        (if *gc-verbose*
            (begin
              (uart-string "[gc ")
              (uart-num c)
              (uart-string " pairs, ")
              (uart-num o)
              (uart-string " bytes, ")
              (uart-num (%logand (%- (%cycles) t0) 1073741823))
              (uart-string " cycles: marking ")
              (uart-num (%+ *t-roots* *t-drain*))
              (uart-string ", pairs ")
              (uart-num (%+ *t-plan* (%+ *t-upd* *t-mv*)))
              (uart-string ", objects ")
              (uart-num *t-obj*)
              (uart-string "; ")
              (uart-num (%lsh *cons-live* -3))
              (uart-string " pairs live, next after ")
              (uart-num *gc-budget*)
              (uart-string " bytes]")
              (uart-nl))
            nil)
        c))))

;; ---------------------------------------------------------------- refill
;; How much cons space a task is given at a time: big enough that refilling
;; is rare, small enough that a task which stops allocating is not sitting on
;; much. The chunk is the task's alone until it is used up, which is what
;; makes the four-instruction allocator safe without a lock.
(define cons-chunk 262144)     ; 32768 pairs

;; Replaced by exec.lisp once there are other tasks to tell.
(define (gc-invalidate-runs) nil)

;; Called from the assembly stub when the inline allocator runs out of run.
;; Every caller-saved register was spilled on the way in, so the collector
;; can see them. A hole the last compaction left behind a pinned pair goes
;; out before any fresh ground.
(define (refill-cons)
  (without-interrupts
    (let ((p (%ld-fixnum lg-cons-ptr)))
      (if (if (gc-over-budget?)
              t
              (if (%< (%- cons-limit p) cons-chunk) (%= (%ld-fixnum lg-cons-free) 0) nil))
          (begin (gc-collect) (set! p (%ld-fixnum lg-cons-ptr)))
          nil)
      (let ((hole (%ld-fixnum lg-cons-free)))
        (if (%> hole 0)
            (begin
              (%st-fixnum! lg-cons-free (%ld-fixnum (%+ hole 4)))
              (gc-hand-out-run hole (%ld-fixnum hole)))
            (begin
              (if (%<= (%- cons-limit p) 0) (out-of-memory "cons space") nil)
              (let ((top (if (%< (%- cons-limit p) cons-chunk) cons-limit (%+ p cons-chunk))))
                (%st-fixnum! lg-cons-ptr top)
                (gc-hand-out-run p top))))))))

;; The run goes into gp and tp here, with interrupts still off, rather than
;; in the stub afterwards: the two globals are one pair for the whole
;; machine, and a task preempted between storing them and picking them up
;; would come back to whatever another task had left there.
(define (gc-hand-out-run start end)
  (set! *cons-given* (%+ *cons-given* (%- end start)))
  (%st-fixnum! lg-cons-run start)
  (%st-fixnum! lg-cons-run-end end)
  (%reload-cons-run)
  start)

;; ---------------------------------------------------------------- allocation
;; Exact fit first, then a split from the big-block list, then bump, unless
;; this collection's allowance is spent, which is answered as no room at all:
;; `alloc-object` collects and asks again.
(define (obj-take size)
  (if (%> *gc-allocated* *gc-budget*)
      0
      (let* ((gran (%lsh size -3))
             (bin (obj-bin-addr gran))
             (p (if (%< gran obj-bin-count) (%ld-fixnum bin) 0)))
        (set! *gc-allocated* (%+ *gc-allocated* size))
        (if (%> p 0)
            (begin (%st-fixnum! bin (%ld-fixnum (%+ p 4))) p)
            (obj-take-slow size gran)))))

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
              (begin (%st-fixnum! lg-obj-ptr (%+ q size)) q)
              0)))))

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

;; Compact the registry in place, keeping the entries whose code object
;; survived and handing the rest of code space back. The tail the compaction
;; leaves is cleared: those words are stale object pointers in the pool, and
;; anything reading the pool has to treat them as live.
(define (gc-sweep-code)
  (let ((r (code-registry))
        (n (%ld-fixnum lg-code-reg-n))
        (i 0)
        (keep 0)
        (freed 0))
    (while (%< i n)
      (let ((obj (%ld-word (%+ r (%lsh i 2)))))
        (if (gc-marked? (%- (%addr-of obj) 4))
            (begin
              (%st-word! (%+ r (%lsh keep 2)) obj)
              (set! keep (%+ keep 1)))
            (let ((entry (%addr-of (%ld-word (%addr-of obj))))
                  (len (%addr-of (%ld-word (%+ (%addr-of obj) 4)))))
              (if (%>= len 16)
                  (begin (code-free-block entry len) (set! freed (%+ freed len)))
                  nil))))
      (set! i (%+ i 1)))
    (let ((j keep))
      (while (%< j n)
        (%st-word! (%+ r (%lsh j 2)) 0)
        (set! j (%+ j 1))))
    (%st-fixnum! lg-code-reg-n keep)
    freed))

;; ---------------------------------------------------------------- images
;; Zeroing the inside of every free block in object space makes a page with
;; nothing live on it a page of zeroes, which the image writer skips. Far too
;; expensive for an ordinary collection.
(define (gc-blank-free-objects)
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
              (gc-blank (%+ p 8) (%+ p size))
              (set! zeroed (%+ zeroed (%- size 8))))
            nil)
        (set! p (%+ p size))))
    zeroed))

;; The same for the code that sweeping freed. A rebuild allocates its new
;; code above the old, so without this every dead byte goes into the file.
(define (gc-blank-free-code)
  (let ((p (%ld-fixnum lg-code-free)))
    (while (%> p 0)
      (let ((size (%ld-fixnum p)) (next (%ld-fixnum (%+ p 4))))
        (if (%> size 8) (gc-blank (%+ p 8) (%+ p size)) nil)
        (set! p next)))))

;; The holes pinned pairs left lie below the top of cons space and go into
;; the file: everything but the two words that make each one a run.
(define (gc-blank-cons-holes)
  (let ((r (%ld-fixnum lg-cons-free)))
    (while (%> r 0)
      (gc-blank (%+ r 8) (%ld-fixnum r))
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
  (if (%eq? (%symbol-value s) *unbound*)
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
(define (gc-detach-idle-symbols)
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
(define (gc-reattach-marked-symbols a)
  (if (%= a 0)
      0
      (let ((n (%ld-fixnum a)) (i 1) (kept 0) (ob (%ld-word lg-obarray)))
        (while (%<= i n)
          (let ((p (%ld-fixnum (%+ a (%* 4 i)))))
            (if (gc-marked? (%- p 4))
                (let* ((s (%from-addr p)) (b (symbol-bucket s)))
                  (%vector-set! ob b (%cons s (%vector-ref ob b)))
                  (%st-word! lg-symlist (%cons s (%ld-word lg-symlist)))
                  (set! kept (%+ kept 1)))
                nil))
          (set! i (%+ i 1)))
        ;; The block held raw addresses, which a conservative scan of the pool
        ;; would take for references.
        (gc-blank a (%+ a (%* 4 (%+ n 1))))
        (free-pool a)
        kept)))

;; Collect for an image: drop the idle symbols, collect, and blank what was
;; reclaimed so that the file is the size of what is in it.
;;
;; The reattached symbols' pairs came out of a run carved above the live
;; data. The run goes back to memory, where the reset stub and a resume read
;; it, and what is left of it is given back: the high-water mark drops to the
;; last pair made, so the file holds the live pairs and nothing else.
(define (gc-for-image)
  (let ((idle (gc-detach-idle-symbols)))
    (gc-collect)
    (gc-reattach-marked-symbols idle))
  (%sync-cons-run)
  (let ((top (%ld-fixnum lg-cons-run)))
    (%st-fixnum! lg-cons-ptr top)
    (%st-fixnum! lg-cons-run-end top)
    (%reload-cons-run)
    (gc-blank top *cons-dirty-top*))
  (gc-blank-cons-holes)
  (gc-blank-free-objects)
  (gc-blank-free-code))

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
  (emit-str (number->string *gc-count*))
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
  (if (%eq? (%symbol-value s) *unbound*)
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
  (set! *collector* gc-collect)
  nil)

(define (gc) (gc-collect))
