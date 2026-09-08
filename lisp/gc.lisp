;;; gc.lisp - the collector.
;;;
;;; Mark and sweep, conservative over stacks, and nothing ever moves.
;;;
;;; Not moving is the whole design. Compiled code embeds the addresses of
;;; symbols and quoted constants directly in the instruction stream; the Exec
;;; kernel holds raw pointers to tasks and messages in a shared address space;
;;; the framebuffer is a raw pointer the display hardware reads. A copying
;;; collector would have to cooperate with every one of those. A non-moving one
;;; has to cooperate with none of them, and in exchange it can be conservative
;;; about stacks - which is what lets compiled code keep live values in
;;; registers and spill them anywhere it likes, with no stack maps at all.
;;;
;;; Cons space is swept into a chain of contiguous RUNS rather than a list of
;;; individual cells, which is what keeps allocation at four instructions and a
;;; predictable branch: the fast path bumps a pointer inside a run, and only
;;; crossing from one run to the next costs a call.
;;;
;;; Nothing in this file may allocate. `let` and `while` are free, `%cons` is
;;; not, and calling anything that conses would be a recursion into the very
;;; condition being handled.

;; ---------------------------------------------------------------- geometry
(define gc-heap-lo cons-base)
(define gc-heap-hi obj-limit)
;; One mark bit per eight bytes of heap.
(define gc-bitmap fast-base)
(define gc-bitmap-size (%lsh (%- gc-heap-hi gc-heap-lo) -6))
(define gc-stack (%+ gc-bitmap gc-bitmap-size))
(define gc-stack-cap 262144)
(define gc-stack-end (%+ gc-stack (%lsh gc-stack-cap 2)))

;; Free blocks in object space carry this type in their header, with the block
;; size in granules of eight bytes where a live object keeps its length.
(define t-free 0)
;; Exact-fit free lists, one per granule count, in reserved low memory just
;; above the Lisp global block. Entry 0 holds everything too big to have its
;; own list.
(define obj-bins #x200)
(define obj-bin-count 64)

(define *mark-sp* 0)
(define *run-last* 0)
(define *gc-count* 0)
(define *gc-cycles* 0)
(define *gc-verbose* nil)

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

(define (gc-clear-bitmap)
  ;; A word at a time; the bitmap is over a megabyte.
  (let ((p gc-bitmap) (e (%+ gc-bitmap gc-bitmap-size)))
    (while (%< p e)
      (%st32! p 0)
      (set! p (%+ p 4)))))

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
                (if (%>= ty 1) (%<= ty 9) nil))
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

(define (gc-scan-object v)
  (let* ((h (%ld32 (%- (%addr-of v) 4)))
         (ty (%logand h 255))
         (n (%lsh h -8)))
    (cond
     ((%= ty t-symbol)
      (gc-push (%slot v 0))
      (gc-push (%slot v 1))
      (gc-push (%slot v 2))
      (gc-push (%slot v 3))
      (gc-push (%slot v 4)))
     ;; strings, byte vectors and floats hold no pointers
     ((%= ty t-string) nil)
     ((%= ty t-bytes) nil)
     ((%= ty t-float) nil)
     ((%= ty t-closure)
      ;; Slot 0 is a raw code address, not a value. Following it would be a
      ;; bug; code space is not collected.
      (let ((i 1))
        (while (%< i n)
          (gc-push (%slot v i))
          (set! i (%+ i 1)))))
     (else
      (let ((i 0))
        (while (%< i n)
          (gc-push (%slot v i))
          (set! i (%+ i 1))))))))

(define (gc-drain)
  (while (%> *mark-sp* 0)
    (set! *mark-sp* (%- *mark-sp* 1))
    (let ((v (%raw-ld (%+ gc-stack (%lsh *mark-sp* 2)))))
      (if (%cons? v)
          (begin (gc-push (%car v)) (gc-push (%cdr v)))
          (gc-scan-object v)))))

;; ---------------------------------------------------------------- roots
(define (gc-scan-range lo hi)
  ;; Conservative: every aligned word in the range is offered to the marker,
  ;; which ignores anything that is not a plausible heap pointer. Retaining a
  ;; little garbage is the price of never needing a stack map.
  (let ((p (%logand lo -4)))
    (while (%< p hi)
      (gc-push (%raw-ld p))
      (set! p (%+ p 4)))))

;; Overridden once Exec is running, to walk every task's stack.
(define (gc-extra-roots) nil)

(define (gc-roots)
  (gc-push (%raw-ld lg-symlist))
  (gc-push (%raw-ld lg-obarray))
  (gc-push (%raw-ld lg-bootlist))
  (gc-push (%raw-ld lg-roots))
  (gc-push (%raw-ld lg-toplevel))
  (gc-push (%raw-ld lg-errhandler))
  (gc-push (%raw-ld lg-traphook))
  ;; The whole Exec pool, conservatively.
  ;;
  ;; This one range covers everything that is not a heap object: the boot
  ;; stack, the trap stack, every task's stack and saved register context, and
  ;; every Exec structure that carries a Lisp value - a message body, a task's
  ;; function, a port's name. A task suspended anywhere at all has its live
  ;; values somewhere in here, and this finds them without the compiler having
  ;; to describe a single stack frame.
  (gc-scan-range pool-base (%global lg-poolptr))
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

;; ---------------------------------------------------------------- collect
(define (gc-collect)
  (let ((t0 (%cycles)))
    (%disable)
    (set! *mark-sp* 0)
    (gc-clear-bitmap)
    (gc-roots)
    (gc-drain)
    (let ((c (gc-sweep-cons))
          (o (gc-sweep-objects)))
      (set! *gc-count* (%+ *gc-count* 1))
      (set! *gc-cycles* (%+ *gc-cycles* (%- (%cycles) t0)))
      (%set-global! lg-gccount *gc-count*)
      (%enable)
      (if *gc-verbose*
          (begin
            (uart-string "[gc ")
            (uart-num-raw c)
            (uart-string " pairs, ")
            (uart-num-raw o)
            (uart-string " bytes, ")
            (uart-num-raw (%- (%cycles) t0))
            (uart-string " cycles]")
            (uart-nl))
          nil)
      c)))

;; ---------------------------------------------------------------- refill
;; Called from the assembly stub when the inline allocator runs out of run.
;; Every caller-saved register was spilled to the stack on the way in, so the
;; collector's conservative scan can see them.
(define (refill-cons)
  (let ((r (%global lg-cons-free)))
    (if (%= r 0)
        (begin
          (gc-collect)
          (set! r (%global lg-cons-free))
          (if (%= r 0) (out-of-memory "cons space") nil))
        nil)
    ;; Take the run: its first cell describes it, and is then free to hand out.
    (let ((end (%ld32 r))
          (next (%ld32 (%+ r 4))))
      (%set-global! lg-cons-free next)
      (%set-global! lg-cons-run r)
      (%set-global! lg-cons-run-end end)
      (if (%> end (%global lg-cons-ptr))
          (%set-global! lg-cons-ptr end)
          nil)
      r)))

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

(define (alloc-object type len)
  (let* ((size (%logand (%+ (%+ 4 (object-payload type len)) 7) -8))
         (p (obj-take size)))
    (if (%= p 0)
        (begin
          (gc-collect)
          (set! p (obj-take size))
          (if (%= p 0) (out-of-memory "object space") nil))
        nil)
    (%st32! p (%logior (%lsh len 8) type))
    (let ((i 4))
      (while (%< i size)
        (%st32! (%+ p i) 0)
        (set! i (%+ i 4))))
    (%from-addr (%+ p 4))))

;; Code space is a plain bump allocator and is never collected. Compiled code
;; is reachable only through the closures that point at it, and freeing it
;; would mean knowing that nothing has baked its address into an instruction -
;; which is exactly the thing this design gives up in exchange for never
;; having to move anything.
(define (alloc-code nbytes)
  (let ((p (%global lg-code-ptr))
        (size (%logand (%+ nbytes 7) -8)))
    (if (%> (%+ p size) (%global lg-code-end))
        (out-of-memory "code space")
        nil)
    (%set-global! lg-code-ptr (%+ p size))
    p))


;; Collect, then blank what was reclaimed.
;;
;; Used by the forge, once, just before it writes the image. Mark and sweep
;; does not compact, so the free pairs stay exactly where they were and the
;; image would carry every page the compiler ever touched. Zeroing them does
;; not move anything - it just makes the pages empty, and the image writer
;; skips empty pages. The result is an image the size of what is actually in
;; it rather than the size of the high water mark.
;;
;; Far too expensive to do on an ordinary collection, which is why it is a
;; separate entry point.
(define (gc-for-image)
  (gc-collect)
  (let ((r (%global lg-cons-free)) (zeroed 0))
    (while (%> r 0)
      (let ((end (%ld32 r))
            (next (%ld32 (%+ r 4)))
            (p 0))
        (set! p r)
        (while (%< p end)
          (%st32! p 0)
          (%st32! (%+ p 4) 0)
          (set! p (%+ p 8)))
        (set! zeroed (%+ zeroed (%lsh (%- end r) -3)))
        ;; Put the run header back: the chain has to survive its own scrubbing.
        (%st32! r end)
        (%st32! (%+ r 4) next)
        (set! r next)))
    zeroed))

;; ---------------------------------------------------------------- reporting
(define (room)
  (uart-string "cons free ")
  (uart-num (%global lg-cons-free-n))
  (uart-string " of ")
  (uart-num (%lsh (%- cons-limit cons-base) -3))
  (uart-string ", object bytes used ")
  (uart-num (%- (%global lg-obj-ptr) obj-base))
  (uart-string ", code bytes used ")
  (uart-num (%- (%global lg-code-ptr) code-base))
  (uart-string ", collections ")
  (uart-num *gc-count*)
  (uart-nl)
  nil)

(define (gc) (gc-collect))
