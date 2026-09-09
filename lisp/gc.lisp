;;; gc.lisp - the collector.
;;;
;;; Mark, then compact the pairs. Roots are found precisely.
;;;
;;; Pairs move and objects do not, and the division is about who is doing the
;;; collecting rather than about how hard either would be. This collector is
;;; written in the language it collects: it reaches its functions through
;;; symbol value cells and its constants through the literal vector of its own
;;; code object, and every one of those is an object. Moving them would be
;;; sawing off the branch it is sitting on. Pairs are safe because nothing
;;; between updating and sliding ever dereferences one - and pairs are where
;;; the space is, a few million against a few thousand objects.
;;;
;;; Moving anything at all is only possible because compiled code contains no
;;; heap addresses: a function reaches its symbols and constants through the
;;; literal vector in s1, so an object can move without an instruction being
;;; patched. Roots come from the frame chain rather than from stack maps,
;;; because a Lisp frame is uniformly typed. What is left conservative is the
;;; register set of a task suspended mid-expression, and whatever those thirty
;;; two words reach is pinned for the cycle.
;;;
;;; The Exec pool is a different heap entirely - raw, unmoving, never scanned -
;;; and that is where stacks, task structures and bitmaps live, which is what
;;; lets the display hardware read a bitmap and the kernel pass pointers around
;;; without the collector needing to know.
;;;
;;; Cons space is swept into a chain of contiguous RUNS rather than a list of
;;; individual cells, which is what keeps allocation at four instructions and a
;;; predictable branch: the fast path bumps a pointer inside a run, and only
;;; crossing from one run to the next costs a call.
;;;
;;; Nothing in this file may allocate. `let` and `while` are free, `%cons` is
;;; not, and calling anything that conses would be a recursion into the very
;;; condition being handled.

(in-package gc)

;; ---------------------------------------------------------------- geometry
(define gc-heap-lo cons-base)
(define gc-heap-hi obj-limit)
;; One mark bit per eight bytes of heap.
(define gc-bitmap fast-base)
(define gc-bitmap-size (%lsh (%- gc-heap-hi gc-heap-lo) -6))
;; A second bitmap of the same shape, for objects that must not move because
;; something found them by guessing rather than by knowing.
(define gc-pinmap (%+ gc-bitmap gc-bitmap-size))
(define gc-stack (%+ gc-pinmap gc-bitmap-size))
(define gc-stack-cap 262144)
(define gc-stack-end (%+ gc-stack (%lsh gc-stack-cap 2)))

;; Forwarding is not stored per object - there is nowhere to put it without
;; growing every pair by half. Instead each block of the heap records where
;; the free pointer had reached when the compacting walk arrived at it, and a
;; lookup replays the few objects between that boundary and the one asked
;; about. Blocks are small enough that the replay is short and numerous enough
;; that the tables stay well under a megabyte.
(define gc-popcount-table gc-stack-end)
(define cons-block-bytes 512)                ; 64 pairs
(define gc-cons-prefix (%+ gc-popcount-table 256))
(define gc-cons-blocks (%lsh (%- cons-limit cons-base) -9))
(define obj-block-bytes 1024)
(define gc-obj-prefix (%+ gc-cons-prefix (%lsh gc-cons-blocks 2)))
(define gc-obj-blocks (%lsh (%- obj-limit obj-base) -10))
(define gc-obj-first (%+ gc-obj-prefix (%lsh gc-obj-blocks 2)))

;; `t-free`, `obj-bins` and `obj-bin-count` come from layout.lisp: a free block
;; carries t-free in its header with the block size in granules of eight bytes
;; where a live object keeps its length, and the bins are exact-fit free lists
;; the forge has to know about too, because it compacts object space on the way
;; into an image.

(define *mark-sp* 0)
(define *run-last* 0)
(define *gc-count* 0)
(define *gc-cycles* 0)
(define *gc-verbose* nil)
;; Costs a full extra pass over the live pairs, so it is off unless something
;; is being debugged. When on, it is the fastest way to tell a mis-forwarded
;; pointer from a missing root.
(define *gc-check* nil)

;; ---------------------------------------------------------------- the stub
;; Layout of the frame the cons refill stub builds. It sits between two Lisp
;; frames on the stack and is not one itself, so the walker has to know its
;; shape: a live-register mask, the eight argument registers, then ra and the
;; temporaries, which are raw and must never be traced.
(define stub-mask-off 0)
(define stub-args-off 4)     ; a0..a7
(define stub-raw-off 36)     ; ra, t0..t6
(define stub-frame-size 72)

;; ---------------------------------------------------------------- mark bits
(define (gc-bit-index p) (%lsh (%- p gc-heap-lo) -3))

(define (gc-marked? p)
  (let ((i (gc-bit-index p)))
    (%= 1 (%logand 1 (%lsh (%ld8 (%+ gc-bitmap (%lsh i -3)))
                           (%- 0 (%logand i 7)))))))

(define (gc-mark! p)
  (let* ((i (gc-bit-index p))
         (a (%+ gc-bitmap (%lsh i -3))))
    (%st8! a (%logior (%ld8 a) (%lsh 1 (%logand i 7))))))

(define (gc-pinned? p)
  (let ((i (gc-bit-index p)))
    (%= 1 (%logand 1 (%lsh (%ld8 (%+ gc-pinmap (%lsh i -3)))
                           (%- 0 (%logand i 7)))))))

(define (gc-pin! p)
  (let* ((i (gc-bit-index p))
         (a (%+ gc-pinmap (%lsh i -3))))
    (%st8! a (%logior (%ld8 a) (%lsh 1 (%logand i 7))))))

(define (gc-clear-map base)
  (let ((p base) (e (%+ base gc-bitmap-size)))
    (while (%< p e)
      (%st32! p 0)
      (set! p (%+ p 4)))))

;; A byte-at-a-time population count. There is no such instruction in the
;; base integer set, and the usual bit-twiddling constants do not fit in a
;; thirty-bit fixnum, so a small table is both simpler and faster.
(define (gc-build-popcount)
  (let ((i 0))
    (while (%< i 256)
      (let ((n 0) (b i))
        (while (%> b 0)
          (set! n (%+ n (%logand b 1)))
          (set! b (%lsh b -1)))
        (%st8! (%+ gc-popcount-table i) n))
      (set! i (%+ i 1)))))

(define (popcount-byte b) (%ld8 (%+ gc-popcount-table b)))

(define (gc-bit? map i)
  (%= 1 (%logand 1 (%lsh (%ld8 (%+ map (%lsh i -3))) (%- 0 (%logand i 7))))))

(define (gc-clear-bitmap)
  (gc-clear-map gc-bitmap)
  (gc-clear-map gc-pinmap))

;; ---------------------------------------------------------------- marking
;; Is this word something the heap could have handed out? Used both for real
;; tagged values and for arbitrary words found on a stack, so it must never
;; say yes to something it would then dereference wrongly.
(define (gc-heap-pointer? v)
  (cond
   ((%cons? v)
    (let ((p (%addr-of v)))
      (if (%>= p cons-base) (%< p (%global lg-cons-ptr)) nil)))
   ((%object? v)
    (let ((p (%- (%addr-of v) 4)))
      (if (%>= p obj-base)
          (if (%< p (%global lg-obj-ptr))
              ;; A header with a plausible type: a stray stack word that
              ;; happens to look like an object pointer would otherwise send
              ;; the scanner into nonsense.
              (let ((ty (%logand (%ld32 p) 255)))
                (if (%>= ty 1) (%<= ty 10) nil))
              nil)
          nil)))
   (else nil)))

(define (gc-block-of v)
  ;; Where the mark bit for this value lives: a pair marks at the pair, an
  ;; object marks at its header.
  (if (%cons? v) (%addr-of v) (%- (%addr-of v) 4)))

(define (gc-push v)
  (if (gc-heap-pointer? v)
      (let ((b (gc-block-of v)))
        (if (gc-marked? b)
            nil
            (begin
              (gc-mark! b)
              (if (%>= *mark-sp* gc-stack-cap)
                  (gc-overflow)
                  (begin
                    (%raw-st! (%+ gc-stack (%lsh *mark-sp* 2)) v)
                    (set! *mark-sp* (%+ *mark-sp* 1)))))))
      nil))

(define (gc-overflow)
  (uart-string "gc: mark stack overflow")
  (uart-nl)
  (%halt 4))

(define (gc-slots base from to)
  (let ((i from))
    (while (%< i to)
      (gc-slot (%+ base (%* 4 i)))
      (set! i (%+ i 1)))))

;; Which words of an object are pointers. Used by both passes: marking follows
;; them, and the update pass rewrites them, so there is one description of an
;; object's shape rather than two that could disagree.
(define (gc-object-slots base)
  (let* ((h (%ld32 (%- base 4)))
         (ty (%logand h 255))
         (n (%lsh h -8)))
    (cond
     ((%= ty t-symbol) (gc-slots base 0 sym-slots))
     ;; strings, byte vectors and floats hold no pointers
     ((%= ty t-string) nil)
     ((%= ty t-bytes) nil)
     ((%= ty t-float) nil)
     ;; slots 0 and 1 are the raw entry address and byte length; from the
     ;; name on it is all tagged
     ((%= ty t-code) (gc-slots base code-name n))
     ;; slot 0 is a raw code address; following it would be a bug
     ((%= ty t-closure) (gc-slots base 1 n))
     (else (gc-slots base 0 n)))))

(define (gc-scan-object v) (gc-object-slots (%addr-of v)))

(define (gc-drain)
  (while (%> *mark-sp* 0)
    (set! *mark-sp* (%- *mark-sp* 1))
    (let ((v (%raw-ld (%+ gc-stack (%lsh *mark-sp* 2)))))
      (if (%cons? v)
          (begin (gc-push (%car v)) (gc-push (%cdr v)))
          (gc-scan-object v)))))

;; ---------------------------------------------------------------- roots
(define (gc-slot addr)
  ;; One pointer-bearing word. Every traversal goes through here, so the same
  ;; walk serves both passes: marking follows the pointer, updating rewrites
  ;; it to wherever the object is going.
  (let ((v (%raw-ld addr)))
    (if *gc-updating*
        (if (gc-heap-pointer? v) (%raw-st! addr (gc-forward-value v)) nil)
        (gc-push v))))

(define (gc-scan-range lo hi)
  (let ((p (%logand lo -4)))
    (while (%< p hi)
      (gc-slot p)
      (set! p (%+ p 4)))))

;; Words that might be pointers and might be integers. Kept apart from the
;; precise path on purpose: anything reached this way gets marked, but once
;; the collector can move things it must not rewrite these words, because a
;; number that happens to look like an address is still a number.
(define *pinned* 0)

(define (gc-scan-conservative lo hi)
  (let ((p (%logand lo -4)))
    (while (%< p hi)
      (let ((v (%raw-ld p)))
        ;; Anything found this way is pinned, which is also what makes it safe
        ;; to leave the word alone during the update pass: a pinned object
        ;; forwards to itself, so an integer that merely looks like a pointer
        ;; is never rewritten into something else.
        (if (if *gc-updating* nil (gc-heap-pointer? v))
            (begin
              (set! *pinned* (%+ *pinned* 1))
              (gc-pin! (gc-block-of v))
              (gc-push v))
            nil))
      (set! p (%+ p 4)))))

;; ---------------------------------------------------------------- stacks
(define (frame-ok? s0)
  ;; A frame base has to be a word-aligned address inside the pool, where all
  ;; the stacks live. Zero ends the walk, which is what the reset stub leaves
  ;; in s0 before it enters Lisp.
  (if (%> s0 pool-base)
      (if (%< s0 pool-limit) (%= 0 (%logand s0 3)) nil)
      nil))

(define (in-stub? ra)
  (if (%>= ra (%global lg-stub-lo)) (%< ra (%global lg-stub-hi)) nil))

(define (gc-scan-stub base)
  ;; Only the argument registers the mask says are live. The rest of the
  ;; stub's frame is a return address and temporaries holding untagged
  ;; intermediates, and tracing those is exactly the mistake to avoid.
  (let ((mask (%ld32 (%+ base stub-mask-off))) (i 0))
    (while (%< i 8)
      (if (%= 1 (%logand 1 (%lsh mask (%- 0 i))))
          (gc-slot (%+ base (%+ stub-args-off (%* 4 i))))
          nil)
      (set! i (%+ i 1)))))

(define (gc-scan-frames sp0 s00)
  ;; Walk the chain of Lisp frames.
  ;;
  ;; No stack maps are needed, because a Lisp frame is uniformly typed: every
  ;; word from its stack pointer up to and including the closure slot is a
  ;; tagged value - locals, spilled temporaries, pushed arguments, the saved
  ;; literal vector. Only the saved return address and frame link are raw, and
  ;; they sit at fixed offsets. And a callee frame base is its caller stack
  ;; pointer, so the chain alone gives every frame extent.
  (let ((sp sp0) (s0 s00) (go t) (guard 0))
    (while (if go (frame-ok? s0) nil)
      (set! guard (%+ guard 1))
      (if (%> guard 100000) (set! go nil) nil)
      (gc-scan-range sp (%- s0 8))
      (let ((ra (%ld32 (%- s0 4)))
            (next (%ld32 (%- s0 8))))
        (if (in-stub? ra)
            (begin (gc-scan-stub s0) (set! sp (%+ s0 stub-frame-size)))
            (set! sp s0))
        (set! s0 next)))))

;; Overridden once Exec is running, to walk every task's stack.
(define (gc-extra-roots) nil)   ; replaced by exec.lisp once the kernel is up

(define (gc-roots)
  ;; Every root is named by the ADDRESS of the word holding it, not by its
  ;; value. Marking only needs the value, but the update pass has to write the
  ;; new one back, and a root that is only ever read is a root that still
  ;; points into the old heap after everything has moved.
  (gc-slot lg-symlist)
  (gc-slot lg-obarray)
  ;; Without these the packages are collected out from under the reader, and
  ;; the next name it reads lands in a package nobody else can see.
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
  ;; The instance this task is running as lives in a register, so there is no
  ;; slot to rewrite - but it still has to be marked, or the application would
  ;; be collected out from under itself. Instances are records, and records do
  ;; not move, so marking is the whole of the job.
  (if *gc-updating* nil (gc-push (%instance)))
  ;; This task's own stack, walked precisely from where it stands.
  (gc-scan-frames (%stack-pointer) (%frame-pointer))
  ;; Every other task, and every Exec structure holding a Lisp value.
  (gc-extra-roots))

;; ---------------------------------------------------------------- cons sweep
(define (gc-add-run start end)
  ;; A run is described in its own first cell: the end address, then the next
  ;; run. Handing the cell out later is fine, because refill reads both words
  ;; into registers before anything is allocated from it.
  (%st32! start end)
  (%st32! (%+ start 4) 0)
  (if (%= *run-last* 0)
      (%set-global! lg-cons-free start)
      (%st32! (%+ *run-last* 4) start))
  (set! *run-last* start))

(define lg-cons-live-top lg-scratch1)

(define (gc-sweep-cons)
  (let ((p cons-base)
        (hi (%global lg-cons-ptr))
        (run 0)
        (live-top cons-base)
        (nfree 0))
    (set! *run-last* 0)
    (%set-global! lg-cons-free 0)
    (while (%< p hi)
      (if (gc-marked? p)
          (begin
            (if (%> run 0)
                (begin (gc-add-run run p) (set! nfree (%+ nfree (%lsh (%- p run) -3))))
                nil)
            (set! run 0)
            (set! live-top (%+ p 8)))
          (if (%= run 0) (set! run p) nil))
      (set! p (%+ p 8)))
    ;; The tail of the swept region runs straight into the part of cons space
    ;; that has never been touched, so they become one run.
    (if (%= run 0) (set! run (if (%< hi cons-limit) hi 0)) nil)
    (if (%> run 0)
        (begin
          (gc-add-run run cons-limit)
          (set! nfree (%+ nfree (%lsh (%- cons-limit run) -3))))
        nil)
    (%set-global! lg-cons-free-n nfree)
    ;; Where the live pairs stop. Everything above this is free, which is what
    ;; lets a snapshot leave it out entirely.
    (%set-global! lg-cons-live-top live-top)
    nfree))

;; ---------------------------------------------------------------- obj sweep
(define (obj-block-size h)
  (let ((ty (%logand h 255)) (n (%lsh h -8)))
    (if (%= ty t-free)
        (%lsh n 3)
        (%logand (%+ (%+ 4 (object-payload ty n)) 7) -8))))

(define (obj-bin-addr gran)
  (%+ obj-bins (%lsh (if (%< gran obj-bin-count) gran 0) 2)))

(define (gc-free-block start len)
  ;; len is in bytes and is always a multiple of eight.
  (let* ((gran (%lsh len -3))
         (bin (obj-bin-addr gran)))
    (%st32! start (%logior (%lsh gran 8) t-free))
    (%st32! (%+ start 4) (%ld32 bin))
    (%st32! bin start)))

(define (gc-clear-bins)
  (let ((i 0))
    (while (%< i obj-bin-count)
      (%st32! (%+ obj-bins (%lsh i 2)) 0)
      (set! i (%+ i 1)))))

(define (gc-sweep-objects)
  (let ((p obj-base)
        (hi (%global lg-obj-ptr))
        (run 0)
        (runlen 0)
        (nfree 0))
    (gc-clear-bins)
    (while (%< p hi)
      (let ((size (obj-block-size (%ld32 p))))
        ;; A zero size would be a corrupt header, and would spin here forever.
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (gc-marked? p)
            (begin
              (if (%> runlen 0)
                  (begin (gc-free-block run runlen) (set! nfree (%+ nfree runlen)))
                  nil)
              (set! run 0)
              (set! runlen 0))
            (begin
              (if (%= runlen 0) (set! run p) nil)
              (set! runlen (%+ runlen size))))
        (set! p (%+ p size))))
    (if (%> runlen 0)
        (begin (gc-free-block run runlen) (set! nfree (%+ nfree runlen)))
        nil)
    (%set-global! lg-obj-free-n nfree)
    nfree))

(define (gc-corrupt p)
  (uart-string "gc: corrupt object header at ")
  (uart-hex-raw p)
  (uart-nl)
  (%halt 5))


;; ================================================================ compaction
;;
;; Sliding compaction, in four passes over the heap.
;;
;;   1. mark            (already done by the time we get here)
;;   2. forwarding      work out where every live object is going, and record
;;                      the free pointer at each block boundary so that the
;;                      answer for any one object can be replayed cheaply
;;   3. update          rewrite every pointer, in the roots and in the live
;;                      objects, to point at where its target is going
;;   4. move            slide the objects down
;;
;; Updating before moving is what makes this work without a forwarding word
;; per object: while pass 3 runs, everything is still where the bitmap says
;; it is.
;;
;; A pinned object does not move, and pushes the free pointer past itself.
;; That is why the free pointer is never above the object being considered,
;; and why pass 4 can copy strictly upwards through memory without ever
;; overwriting something it has not yet moved.

(define *gc-updating* nil)
(define *gc-moved* 0)
(define *gc-compacted* nil)

;; ---------------------------------------------------------------- forwarding
(define (cons-block-of p) (%lsh (%- p cons-base) -9))
(define (obj-block-of p) (%lsh (%- p obj-base) -10))

(define (gc-plan-cons hi)
  ;; One walk over the pairs, recording the free pointer as it crosses each
  ;; block boundary. Answers the address the live region will end at.
  (let ((p cons-base) (free cons-base) (blk 0))
    (%st32! gc-cons-prefix cons-base)
    (while (%< p hi)
      (let ((b (cons-block-of p)))
        (while (%< blk b)
          (set! blk (%+ blk 1))
          (%st32! (%+ gc-cons-prefix (%lsh blk 2)) free)))
      (if (gc-marked? p)
          (if (gc-pinned? p)
              (if (%> (%+ p 8) free) (set! free (%+ p 8)) nil)
              (set! free (%+ free 8)))
          nil)
      (set! p (%+ p 8)))
    ;; Every block above the live region starts where the walk finished.
    (while (%< blk (%- gc-cons-blocks 1))
      (set! blk (%+ blk 1))
      (%st32! (%+ gc-cons-prefix (%lsh blk 2)) free))
    free))

(define (gc-forward-cons p)
  (let* ((b (cons-block-of p))
         (start (%+ cons-base (%lsh b 9)))
         (free (%ld32 (%+ gc-cons-prefix (%lsh b 2))))
         (q start))
    (if (gc-pinned? p)
        p
        (begin
          ;; The common case is a block with nothing pinned in it, where the
          ;; answer is just the free pointer plus eight bytes for every live
          ;; pair before this one.
          (if (gc-block-has-pins? start)
              (begin
                (while (%< q p)
                  (if (gc-marked? q)
                      (if (gc-pinned? q)
                          (if (%> (%+ q 8) free) (set! free (%+ q 8)) nil)
                          (set! free (%+ free 8)))
                      nil)
                  (set! q (%+ q 8)))
                free)
              (%+ free (%lsh (gc-count-marks start p) 3)))))))

(define (gc-block-has-pins? start)
  ;; Sixty-four pairs is sixty-four bits, which is eight bytes of the pin map.
  (let ((a (%+ gc-pinmap (%lsh (%lsh (%- start gc-heap-lo) -3) -3)))
        (i 0)
        (any nil))
    (while (%< i 8)
      (if (%> (%ld8 (%+ a i)) 0) (begin (set! any t) (set! i 8)) (set! i (%+ i 1))))
    any))

(define (gc-count-marks from to)
  ;; Live pairs in [from, to), both inside one block. Whole bytes of the
  ;; bitmap come from the table; the ragged tail is counted a bit at a time.
  (let ((i (%lsh (%- from gc-heap-lo) -3))
        (e (%lsh (%- to gc-heap-lo) -3))
        (n 0))
    (while (%<= (%+ i 8) e)
      (set! n (%+ n (popcount-byte (%ld8 (%+ gc-bitmap (%lsh i -3))))))
      (set! i (%+ i 8)))
    (while (%< i e)
      (if (gc-bit? gc-bitmap i) (set! n (%+ n 1)) nil)
      (set! i (%+ i 1)))
    n))

(define (gc-plan-objects hi)
  (let ((p obj-base) (free obj-base) (blk 0))
    (%st32! gc-obj-prefix obj-base)
    (%st32! gc-obj-first obj-base)
    (while (%< p hi)
      (let ((b (obj-block-of p)))
        (while (%< blk b)
          (set! blk (%+ blk 1))
          (%st32! (%+ gc-obj-prefix (%lsh blk 2)) free)
          (%st32! (%+ gc-obj-first (%lsh blk 2)) p)))
      (let ((size (obj-block-size (%ld32 p))))
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (gc-marked? p)
            (if (gc-pinned? p)
                (if (%> (%+ p size) free) (set! free (%+ p size)) nil)
                (set! free (%+ free size)))
            nil)
        (set! p (%+ p size))))
    (while (%< blk (%- gc-obj-blocks 1))
      (set! blk (%+ blk 1))
      (%st32! (%+ gc-obj-prefix (%lsh blk 2)) free)
      (%st32! (%+ gc-obj-first (%lsh blk 2)) p))
    free))

(define (gc-forward-object p)
  (if (gc-pinned? p)
      p
      (let* ((b (obj-block-of p))
             (free (%ld32 (%+ gc-obj-prefix (%lsh b 2))))
             (q (%ld32 (%+ gc-obj-first (%lsh b 2)))))
        (while (%< q p)
          (let ((size (obj-block-size (%ld32 q))))
            (if (gc-marked? q)
                (if (gc-pinned? q)
                    (if (%> (%+ q size) free) (set! free (%+ q size)) nil)
                    (set! free (%+ free size)))
                nil)
            (set! q (%+ q size))))
        free)))

(define (gc-forward-value v)
  ;; Pairs move. Objects do not, and answer their own address.
  (if (%cons? v)
      (%from-addr (gc-forward-cons (%addr-of v)))
      v))

;; ---------------------------------------------------------------- update
(define (gc-update-live cons-hi obj-hi)
  ;; Every pointer inside every live object. The roots are done separately,
  ;; through the same walkers that found them in the first place.
  (let ((p cons-base))
    (while (%< p cons-hi)
      (if (gc-marked? p)
          (begin (gc-slot p) (gc-slot (%+ p 4)))
          nil)
      (set! p (%+ p 8))))
  (let ((p obj-base))
    (while (%< p obj-hi)
      (let ((size (obj-block-size (%ld32 p))))
        (if (gc-marked? p) (gc-object-slots (%+ p 4)) nil)
        (set! p (%+ p size))))))

;; ---------------------------------------------------------------- move
(define (gc-move-cons hi)
  (let ((p cons-base) (n 0))
    (while (%< p hi)
      (if (gc-marked? p)
          (let ((to (gc-forward-cons p)))
            (if (%= to p)
                nil
                (begin
                  (%raw-st! to (%raw-ld p))
                  (%raw-st! (%+ to 4) (%raw-ld (%+ p 4)))
                  (set! n (%+ n 1)))))
          nil)
      (set! p (%+ p 8)))
    n))

(define (gc-move-objects hi)
  (let ((p obj-base) (n 0))
    (while (%< p hi)
      (let ((size (obj-block-size (%ld32 p))))
        (if (gc-marked? p)
            (let ((to (gc-forward-object p)))
              (if (%= to p)
                  nil
                  (begin
                    (let ((i 0))
                      (while (%< i size)
                        (%raw-st! (%+ to i) (%raw-ld (%+ p i)))
                        (set! i (%+ i 4))))
                    (set! n (%+ n 1)))))
            nil)
        (set! p (%+ p size))))
    n))

(define (gc-blank lo hi)
  ;; Whatever is above the live data is not merely free, it is blanked. That
  ;; costs one pass and makes the pages empty, which is what lets an image be
  ;; the size of what is in it rather than the size of the high water mark.
  (let ((p lo))
    (while (%< p hi)
      (%st32! p 0)
      (set! p (%+ p 4)))))

;; ---------------------------------------------------------------- driver
(define (gc-verify top)
  ;; After compaction no live pointer may name a pair above the new top: such
  ;; a pointer was either never updated or was updated wrongly, and either way
  ;; it now names whatever the slide happened to leave there.
  (let ((p cons-base) (bad 0) (first 0))
    (while (%< p top)
      (let ((a (%raw-ld p)) (d (%raw-ld (%+ p 4))))
        (if (if (%cons? a) (%>= (%addr-of a) top) nil)
            (begin (if (%= first 0) (set! first p) nil) (set! bad (%+ bad 1)))
            nil)
        (if (if (%cons? d) (%>= (%addr-of d) top) nil)
            (begin (if (%= first 0) (set! first p) nil) (set! bad (%+ bad 1)))
            nil))
      (set! p (%+ p 8)))
    (uart-string "  verify: ")
    (uart-num-raw bad)
    (uart-string " dangling, first at ")
    (uart-hex-raw first)
    (uart-nl)
    bad))

(define (gc-compact)
  ;; Pairs are compacted; objects are swept in place.
  ;;
  ;; This is not squeamishness about variable sizes, it is about who is doing
  ;; the collecting. This collector is written in the language it collects: it
  ;; calls functions through symbol value cells, and reaches its own constants
  ;; through the literal vector of its own code object. Every one of those is
  ;; an object. Move them and the collector loses the ability to run, halfway
  ;; through running - it would be sawing off the branch while sitting on it.
  ;;
  ;; Pairs are safe because nothing between updating and sliding dereferences
  ;; one, and pairs are where the space is: a few million of them against a
  ;; few thousand objects.
  (let* ((cons-hi (%global lg-cons-ptr))
         (obj-hi (%global lg-obj-ptr))
         (cons-top (gc-plan-cons cons-hi)))
    (if *gc-check*
        (begin
          (uart-string "  plan: hi=") (uart-hex-raw cons-hi)
          (uart-string " top=") (uart-hex-raw cons-top)
          (uart-string " live=") (uart-num-raw (%lsh (%- cons-top cons-base) -3))
          (uart-nl))
        nil)
    ;; Rewrite every pointer to a pair, in the roots and in the live objects.
    ;; Nothing may follow a pair between here and the slide below.
    (set! *gc-updating* t)
    (gc-roots)
    (gc-update-live cons-hi obj-hi)
    (set! *gc-updating* nil)
    (set! *gc-moved* (gc-move-cons cons-hi))
    (if *gc-check* (gc-verify cons-top) nil)
    (gc-blank cons-top cons-hi)
    (%set-global! lg-cons-ptr cons-top)
    ;; An empty run, for this task and for every other. Nobody is holding a
    ;; pointer into the heap that just slid out from under them: the next cons
    ;; anybody does finds no room and asks for a fresh chunk.
    (%set-global! lg-cons-run cons-top)
    (%set-global! lg-cons-run-end cons-top)
    (%set-global! lg-cons-free 0)
    (%set-global! lg-cons-free-n (%lsh (%- cons-limit cons-top) -3))
    (%reload-cons-run)
    (gc-invalidate-runs)
    (set! *gc-compacted* t)
    (%lsh (%- cons-limit cons-top) -3)))

;; ---------------------------------------------------------------- collect
(define *gc-ready* nil)

;; The popcount table, the mark bitmap and the mark stack all live above
;; fast-base, which no image saves - they are scratch, rebuilt on demand. The
;; flag saying the table has been built is an ordinary Lisp global, and that
;; one does get saved. An image written without this call comes back claiming
;; a table it does not have, and the collector then computes forwarding
;; addresses out of a page of zeroes: everything still looks like a pointer,
;; and nothing points where it used to.
(define (gc-forget-scratch) (set! *gc-ready* nil))

(define (gc-collect)
  ;; Interrupts are off for the whole of this and back on afterwards only if
  ;; they were on before. The collector used to end by turning them on
  ;; unconditionally, which quietly reopened the critical section of anybody
  ;; who was holding Disable and happened to allocate.
  (let ((t0 (%cycles)))
    (without-interrupts
      (if *gc-ready* nil (begin (gc-build-popcount) (set! *gc-ready* t)))
      ;; No need to ask any task how far it has got: runs are carved out of
      ;; lg-cons-ptr, so that is already above every pair anyone has been
      ;; handed. What is left unused inside a task's run is simply unmarked,
      ;; and the compaction closes it up like any other gap.
      (set! *mark-sp* 0)
      (set! *pinned* 0)
      (gc-clear-bitmap)
      (gc-roots)
      (gc-drain)
      ;; Code before objects. Sweeping object space writes free-list links over
      ;; dead objects' headers and first slots, and a dead code object's first
      ;; slot is the address of the code it owns - read it afterwards and the
      ;; code sweeper frees whatever the link happened to look like.
      (let ((k (gc-sweep-code))
            (c (gc-compact))
            (o (gc-sweep-objects)))
        (set! *gc-count* (%+ *gc-count* 1))
        (set! *gc-cycles* (%+ *gc-cycles* (%- (%cycles) t0)))
        (%set-global! lg-gccount *gc-count*)
        ;; Reporting stays inside: it is off unless something is being debugged,
        ;; and it writes to the uart directly rather than allocating a string.
        (if *gc-verbose*
            (begin
              (uart-string "[gc ")
              (uart-num-raw c)
              (uart-string " pairs, ")
              (uart-num-raw o)
              (uart-string " bytes, ")
              (uart-num-raw (%logand (%- (%cycles) t0) 1073741823))
              (uart-string " cycles]")
              (uart-nl))
            nil)
        c))))

;; ---------------------------------------------------------------- refill
;; Called from the assembly stub when the inline allocator runs out of run.
;; Every caller-saved register was spilled to the stack on the way in, so the
;; collector's conservative scan can see them.
;; How much a task is given at a time. Big enough that refilling is rare and
;; small enough that a task which stops allocating is not sitting on much.
(define cons-chunk 262144)     ; 32768 pairs

;; Replaced by exec.lisp once there are other tasks to tell.
(define (gc-invalidate-runs) nil)

(define (refill-cons)
  ;; This task's run is used up, so carve it another out of the unclaimed
  ;; ground above lg-cons-ptr - which is the frontier, and therefore the high
  ;; water mark the collector sweeps to. Only when there is not enough left to
  ;; carve is it worth collecting.
  ;;
  ;; The chunk is this task's alone until it is exhausted. That is the whole
  ;; reason it exists: the four-instruction allocator is not atomic, and a run
  ;; shared between tasks would hand the same cell to two of them.
  (without-interrupts
    (let ((p (%global lg-cons-ptr)))
      (if (%< (%- cons-limit p) cons-chunk)
          (begin (gc-collect) (set! p (%global lg-cons-ptr)))
          nil)
      (if (%<= (%- cons-limit p) 0) (out-of-memory "cons space") nil)
      (let ((top (if (%< (%- cons-limit p) cons-chunk) cons-limit (%+ p cons-chunk))))
        (%set-global! lg-cons-ptr top)
        (%set-global! lg-cons-run p)
        (%set-global! lg-cons-run-end top)
        p))))

;; ---------------------------------------------------------------- allocation
(define (obj-take size)
  ;; Exact fit first, then split from the big-block list, then bump.
  (let* ((gran (%lsh size -3))
         (bin (obj-bin-addr gran))
         (p (if (%< gran obj-bin-count) (%ld32 bin) 0)))
    (if (%> p 0)
        (begin (%st32! bin (%ld32 (%+ p 4))) p)
        (obj-take-slow size gran))))

(define (obj-take-slow size gran)
  ;; Walk the oversized list looking for something to cut down.
  (let ((prev 0)
        (p (%ld32 obj-bins))
        (found 0))
    (while (if (%= found 0) (%> p 0) nil)
      (let ((have (%lsh (%lsh (%ld32 p) -8) 3)))
        (if (%>= have size)
            (begin
              ;; unlink
              (if (%= prev 0)
                  (%st32! obj-bins (%ld32 (%+ p 4)))
                  (%st32! (%+ prev 4) (%ld32 (%+ p 4))))
              ;; return the tail of the block, if the split is worth keeping
              (if (%>= (%- have size) 8)
                  (gc-free-block (%+ p size) (%- have size))
                  nil)
              (set! found p))
            (begin (set! prev p) (set! p (%ld32 (%+ p 4)))))))
    (if (%> found 0)
        found
        ;; Nothing on the lists: take fresh ground.
        (let ((q (%global lg-obj-ptr)))
          (if (%<= (%+ q size) (%global lg-obj-end))
              (begin (%set-global! lg-obj-ptr (%+ q size)) q)
              0)))))

;; ---------------------------------------------------------------- code space
;;
;; Code is collected but not moved. Not moved for the same reason objects are
;; not: this collector runs as compiled code, and sliding the function it is
;; standing in would end the discussion. Collected because redefining a
;; function at the prompt orphans the old one, and without this a long session
;; would leak every version of everything it had ever compiled.
;;
;; Liveness needs no special rule. A closure holds its code object, a frame
;; holds its closure, and a running function's literal vector is its own code
;; object sitting in s1 - so anything executing, anything on any stack, and
;; anything callable is reachable already.
;;
;; The registry is a plain array in the pool rather than a list in the heap.
;; A list would have to be a root, and a root would keep every code object
;; alive forever, which is precisely the opposite of the point.

(define code-registry-max 65536)

(define (code-registry)
  (let ((r (%global lg-code-reg)))
    (if (%> r 0)
        r
        (let ((a (alloc-pool (%lsh code-registry-max 2))))
          (%set-global! lg-code-reg a)
          (%set-global! lg-code-reg-n 0)
          a))))

(define (register-code obj)
  (without-interrupts
  (let ((r (code-registry))
        (n (%global lg-code-reg-n)))
    (if (%>= n code-registry-max)
        (error "code registry full")
        nil)
    (%raw-st! (%+ r (%lsh n 2)) obj)
    (%set-global! lg-code-reg-n (%+ n 1))
    obj)))

;; Free blocks describe themselves: size first, then the next block.
(define (code-take size)
  (let ((prev 0) (p (%global lg-code-free)) (got 0))
    (while (if (%= got 0) (%> p 0) nil)
      (let ((have (%ld32 p)) (next (%ld32 (%+ p 4))))
        (if (%>= have size)
            (begin
              (if (%= prev 0)
                  (%set-global! lg-code-free next)
                  (%st32! (%+ prev 4) next))
              ;; Keep the tail if it is big enough to hold a header.
              (if (%>= (%- have size) 16)
                  (code-free-block (%+ p size) (%- have size))
                  nil)
              (set! got p))
            (begin (set! prev p) (set! p next)))))
    got))

(define (code-free-block p size)
  (%st32! p size)
  (%st32! (%+ p 4) (%global lg-code-free))
  (%set-global! lg-code-free p)
  (%set-global! lg-code-free-n (%+ (%global lg-code-free-n) size)))

(define (alloc-code nbytes)
  ;; Code space has a free list and a bump pointer, the same shape as object
  ;; space and with the same requirement.
  (without-interrupts
  (let* ((size (%logand (%+ nbytes 7) -8))
         (p (code-take size)))
    (if (%> p 0)
        (begin (%set-global! lg-code-free-n (%- (%global lg-code-free-n) size)) p)
        (let ((q (%global lg-code-ptr)))
          (if (%> (%+ q size) (%global lg-code-end))
              (out-of-memory "code space")
              nil)
          (%set-global! lg-code-ptr (%+ q size))
          q)))))

(define (gc-sweep-code)
  ;; Compact the registry in place, keeping the entries whose code object
  ;; survived and handing the rest of code space back.
  (let ((r (code-registry))
        (n (%global lg-code-reg-n))
        (i 0)
        (keep 0)
        (freed 0))
    (while (%< i n)
      (let ((obj (%raw-ld (%+ r (%lsh i 2)))))
        (if (gc-marked? (%- (%addr-of obj) 4))
            (begin
              (%raw-st! (%+ r (%lsh keep 2)) obj)
              (set! keep (%+ keep 1)))
            (let ((entry (%addr-of (%raw-ld (%addr-of obj))))
                  (len (%addr-of (%raw-ld (%+ (%addr-of obj) 4)))))
              (if (%>= len 16)
                  (begin (code-free-block entry len) (set! freed (%+ freed len)))
                  nil))))
      (set! i (%+ i 1)))
    ;; Clear the tail the compaction left behind. Those words are dead, but
    ;; they are object pointers sitting in the pool, and the pool is scanned
    ;; without types: anything reading it has to treat a stale entry as a live
    ;; reference and keep whatever it names exactly where it is.
    (let ((j keep))
      (while (%< j n)
        (%raw-st! (%+ r (%lsh j 2)) 0)
        (set! j (%+ j 1))))
    (%set-global! lg-code-reg-n keep)
    freed))


;; Collect, then blank what was reclaimed.
;;
;; Used by the forge, once, just before it writes the image.
;;
;; Pairs need nothing done to them: they are compacted, and the collector
;; already blanks everything above the live data. Objects are never moved, so
;; what the build threw away is still sitting where it fell, and the image
;; carries every page the compiler ever touched. Zeroing the inside of every
;; free block does not move anything - it just makes a page of nothing into a
;; page of zeroes, which the image writer skips.
;;
;; It only wins on a page with nothing live on it at all. One survivor holds a
;; whole page down; that is what compacting object space would fix, and this
;; is what can be had without it.
;;
;; Far too expensive to do on an ordinary collection, which is why it is a
;; separate entry point.
(define (gc-blank-free-objects)
  (let ((p obj-base)
        (hi (%global lg-obj-ptr))
        (zeroed 0))
    (while (%< p hi)
      (let* ((h (%ld32 p))
             (size (obj-block-size h)))
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (%= (%logand h 255) t-free)
            ;; Words 0 and 1 are the block's size and its place on the bin
            ;; chain: the free list has to survive its own scrubbing.
            (begin
              (gc-blank (%+ p 8) (%+ p size))
              (set! zeroed (%+ zeroed (%- size 8))))
            nil)
        (set! p (%+ p size))))
    zeroed))

(define (gc-for-image)
  (gc-collect)
  (gc-blank-free-objects))

;; ---------------------------------------------------------------- reporting
(define (room)
  ;; This one goes to whatever the caller is talking to, unlike the collector's
  ;; own messages: it is a question somebody asked, not a report from inside a
  ;; collection.
  (emit-str "cons free ")
  (emit-str (number->string (%global lg-cons-free-n)))
  (emit-str " of ")
  (emit-str (number->string (%lsh (%- cons-limit cons-base) -3)))
  (emit-str ", object bytes used ")
  (emit-str (number->string (%- (%global lg-obj-ptr) obj-base)))
  (emit-str ", code bytes used ")
  (emit-str (number->string
             (%- (%- (%global lg-code-ptr) code-base) (%global lg-code-free-n))))
  (emit-str ", collections ")
  (emit-str (number->string *gc-count*))
  (newline)
  ;; The pool is the other heap: raw, unmoving, and nothing to do with the
  ;; collector, but it is where stacks and bitmaps come from and it is the one
  ;; that runs out quietly.
  (emit-str "pool bytes claimed ")
  (emit-str (number->string (pool-used)))
  (emit-str ", free ")
  (emit-str (number->string (pool-free-bytes)))
  (emit-str " of ")
  (emit-str (number->string (%- pool-limit pool-base)))
  (newline)
  nil)

;; ---------------------------------------------------------------- namespaces
;; A package the forge needed and the machine cannot use.
;;
;; boot.lisp and hostio.lisp are read by the forge and never compiled into an
;; image, so the packages they declare reach the machine holding nothing at
;; all: a name, a use list, and a few symbols bound to nothing. Dropping them
;; before the image is collected is what keeps them out of the file - and the
;; test is what they hold rather than a list of names kept somewhere, so a
;; package that stops being used stops being carried without anyone noticing.

(define (symbol-holds-anything? s)
  (if (%eq? (%symbol-value s) *unbound*)
      (if (%symbol-function s) t (if (%symbol-plist s) t nil))
      t))

(define (package-in-use? p)
  (let ((l (%raw-ld lg-symlist)) (used nil))
    (while (%cons? l)
      (let ((s (%car l)))
        (if (%eq? (symbol-package s) p)
            (if (symbol-holds-anything? s) (set! used t) nil)
            nil))
      (set! l (if used nil (%cdr l))))
    used))

(define (mine? p s) (%eq? (symbol-package s) p))

(define (drop-symbols-of p l)
  ;; Splice this package's symbols out of a list, in place. `remove-if` would
  ;; say it in one line and allocate a closure for every obarray bucket, at
  ;; the exact moment the image is about to be written - and objects are never
  ;; moved, so a closure made here is a hole in the file that nothing can
  ;; close. Splicing allocates nothing at all.
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

(define (forget-package p)
  ;; Out of the obarray, out of the symbol list, out of the package list. The
  ;; symbols go when the collector next runs, unless something is still
  ;; holding one - which is what uninterning means anywhere else too.
  (let* ((ob (%raw-ld lg-obarray))
         (n (%vector-length ob))
         (i 0))
    (while (%< i n)
      (%vector-set! ob i (drop-symbols-of p (%vector-ref ob i)))
      (set! i (%+ i 1))))
  (%raw-st! lg-symlist (drop-symbols-of p (%raw-ld lg-symlist)))
  (%raw-st! lg-packages (remove-eq p (%raw-ld lg-packages)))
  p)

(define (forget-unused-packages)
  ;; The names dropped, for whoever wants to say so.
  (let ((dropped nil))
    (dolist (p (list-copy (all-packages)))
      (if (package-in-use? p)
          nil
          (begin (forget-package p)
                 (set! dropped (%cons (package-name p) dropped)))))
    dropped))

(define (install-allocator)
  ;; What the prelude's `alloc-object` calls. It cannot name these itself, so
  ;; the kickstart puts them in place before anything has a chance to
  ;; allocate - which is before the boot list, since the first thing the boot
  ;; list does is make a package.
  ;;
  ;; The functions themselves, not lambdas wrapping them: a closure would have
  ;; to be allocated, and allocating is the thing that does not work yet.
  (set! *object-allocator* obj-take)
  (set! *collector* gc-collect)
  nil)


(define (gc) (gc-collect))
