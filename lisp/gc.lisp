;;; gc.lisp - the collector.
;;;
;;; Mark, then sweep in place, in slices short enough that nothing waits on
;;; one. A collection is a cycle with three phases:
;;;
;;;   start     interrupts off for one short stretch: every task gives up its
;;;             run of cons space, the roots are pushed, and the write barrier
;;;             goes on.
;;;   marking   the mark stack is traced a slice at a time, by the idle task
;;;             when the machine has nothing else to do and by whoever is
;;;             allocating when it has. Everything else runs in between.
;;;   sweeping  dead objects go into the free bins and dead runs of pairs
;;;             become runs for the allocator, a slice at a time, the barrier
;;;             off.
;;;
;;; The collector is precise because the machine is: a granule of memory, eight
;;; bytes, holds a pointer if and only if its tag is set. The roots are the
;;; tagged granules of low memory, of every stack from its stack pointer to its
;;; top, and of every saved register context. Marking an object is pushing
;;; every tagged granule of its payload.
;;;
;;; A tagged capability keeps alive the block its base lies in. With HD it
;;; is an object, its header in the granule below its base. Without, one
;;; based in cons space keeps the pair at its base rounded down to sixteen,
;;; whatever its length, so a capability narrowed to a car or a cdr keeps its
;;; pair; one based in object space keeps the object whose block holds the
;;; granule below its base, found by the object-start map, so one narrowed to
;;; a slot keeps its vector. Code, with EX, keeps alive the code object that
;;; owns its block. Everything else, a stack, a device, a pool block, is
;;; somebody else's. A task's cons run keeps the pair at its base: at most
;;; one pair of floating garbage.
;;;
;;; What makes marking safe to interleave with running code is the machine's
;;; write barrier (`gcmode`): while it is on, any store that would overwrite a
;;; tagged granule in cons or object space whose object is unmarked traps
;;; first, and the handler marks that object (`barrier`). So everything
;;; reachable when the cycle began stays reachable to the collector: a pointer
;;; can be moved from place to place but not lost, because the last copy
;;; cannot be overwritten unseen. This is a snapshot: what was live at the
;;; start survives the cycle, and what was allocated during it is made black
;;; on the spot, a run of pairs by marking the whole run when it is handed out
;;; and an object by marking it when it is taken. Nothing new needs tracing,
;;; and the roots need scanning once.
;;;
;;; Free memory holds no tags. The sweep zeroes every dead object that could
;;; hold a pointer and every dead stretch of pairs, so an allocator's stores
;;; into a fresh block never meet an old pointer and never trip the barrier,
;;; and every tag inside an allocated block is a pointer to something that
;;; exists. Stale pointers sit in two places nothing reads them from: a dead
;;; pair that shares its word of the mark map with a live one, which is not
;;; handed out until the whole word is dead, and a frame's slots, which hold
;;; whatever an earlier call left there until their function writes them.
;;; Such a slot is scanned with the rest, so an object's header is checked
;;; before it is believed, and a stale slot costs at most some floating
;;; garbage.
;;;
;;; Pairs and objects stay where they are. The pair compactor below runs on
;;; the way into an image, where a heap with no holes is worth a stopped
;;; machine.
;;;
;;; The collector is written in the language it collects: it reaches its
;;; functions through symbol value cells and its constants through its own
;;; code object. Nothing here may allocate. `let` and `while` are free;
;;; `%cons` is not, and anything that conses would recurse into the condition
;;; being handled. The Exec pool is a separate heap, raw, unmoving and never
;;; traced, holding stacks, register contexts and command blocks; only the
;;; stacks and contexts in it are roots, and only from their owners.

(in-package gc)
(unsafe-file)

;; ---------------------------------------------------------------- geometry
(define gc-heap-lo cons-base)
(define gc-heap-hi obj-limit)
;; One mark bit per eight bytes of heap, in scratch memory at `gc-bitmap`:
;; bit i of the word at index i/32. The write barrier reads this map, so its
;; address is the machine's and comes from the generated layout: a pair's bit
;; is the bit of its first granule, an object's the bit of its header.
(define gc-bitmap-size (%lsh (%- gc-heap-hi gc-heap-lo) -6))
;; The object-start map, one bit per granule of object space at `obj-starts`,
;; set at the header of every block the allocator hands out and cleared when
;; the sweep finds the block dead: how a capability based inside a payload
;; finds its object. It lives in scratch memory, which an image does not
;; carry, so the first collection on a machine builds it (`ensure-starts`).
;; The barrier reads it too.
(define obj-starts-size (%lsh (%- obj-limit obj-base) -6))
;; The mark stack holds the address of each block pushed: a pair's, or an
;; object's header. Cons space lies below object space, so the address says
;; which it is.
(define gc-stack (%+ obj-starts-ready 8))
(define gc-stack-cap 262144)
(define gc-stack-end (%+ gc-stack (%lsh gc-stack-cap 2)))

;; Forwarding is not stored per pair. A word of the mark map covers 256 bytes
;; of cons space, sixteen pairs, and the compactor records where the free
;; pointer had reached when its walk arrived at each word; a lookup adds the
;; live pairs ahead in the same word, which is a popcount.
(define gc-cons-prefix gc-stack-end)
(define gc-cons-words (%lsh (%- cons-limit cons-base) -8))
;; The rest of scratch memory, where the image writer builds its tag maps.
(define gc-scratch (%+ gc-cons-prefix (%lsh gc-cons-words 2)))

;; A free block in object space carries t-free in its header with its size in
;; granules where a live object keeps its length, and the address of the next
;; free block in its first slot. The bins at obj-bins, one 8-byte slot each,
;; are exact-fit free lists; the forge knows their layout too.

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
(define *verbose* nil)

;; The cycles since `t0`, which the counter's wrapping does not disturb.
(defsubst (cycles-since t0)
  (%logand (%- (%cycles) t0) most-positive-fixnum))

;; ---------------------------------------------------------------- mark bits
(defsubst (gc-bit-index p) (%lsh (%- p gc-heap-lo) -3))

(defsubst (marked? p) (%bit-ref gc-bitmap (gc-bit-index p)))
(defsubst (gc-mark! p) (%bit-set! gc-bitmap (gc-bit-index p)))

(define (gc-map-byte p) (%lsh (%- p gc-heap-lo) -6))

(defsubst (gc-unmark! p)
  (let ((a (%+ gc-bitmap (%lsh (gc-bit-index p) -3))))
    (%st-byte! a (%logand (%ld-byte a) (%lognot (%lsh 1 (%logand (gc-bit-index p) 7)))))))

;; ---------------------------------------------------------------- starts
(defsubst (start-index p) (%lsh (%- p obj-base) -3))
(defsubst (start-set! p) (%bit-set! obj-starts (start-index p)))
(defsubst (start-clear! p)
  (let ((a (%+ obj-starts (%lsh (start-index p) -3))))
    (%st-byte! a (%logand (%ld-byte a) (%lognot (%lsh 1 (%logand (start-index p) 7)))))))

;; The nearest object start at or below `a`, an address in object space; 0
;; when there is none.
(define (object-start-at a)
  (if (%bit-ref obj-starts (start-index a)) a (object-start-below a)))

(define (object-start-below a)
  (let* ((i (start-index a))
         (w (%lsh i -5))
         (k (%logand i 31))
         (bits (%ld-word (%+ obj-starts (%lsh w 2)))))
    (if (%< k 31) (set! bits (%logand bits (%lognot (%lsh -1 (%+ k 1))))) nil)
    (while (if (%= bits 0) (%> w 0) nil)
      (set! w (%- w 1))
      (set! bits (%ld-word (%+ obj-starts (%lsh w 2)))))
    (if (%= bits 0)
        0
        (let ((n 31))
          (while (%= 0 (%logand bits (%lsh 1 n))) (set! n (%- n 1)))
          (%+ obj-base (%lsh (%+ (%lsh w 5) n) 3))))))

;; Every bit for the heap from `lo` up to `hi` cleared: whole words of the map
;; where it can, single bits at the edges.
(define (clear-range lo hi)
  (while (if (%< lo hi) (%> (%logand lo 255) 0) nil)
    (gc-unmark! lo)
    (set! lo (%+ lo 8)))
  (while (%<= (%+ lo 256) hi)
    (%st-word! (%+ gc-bitmap (gc-map-byte lo)) 0)
    (set! lo (%+ lo 256)))
  (while (%< lo hi)
    (gc-unmark! lo)
    (set! lo (%+ lo 8))))

;; Every pair from `lo` up to `hi` marked: the bit of each pair's first
;; granule, which is every other bit of the map. A run handed out while
;; marking is black from the start.
(define (mark-pairs lo hi)
  (while (if (%< lo hi) (%> (%logand lo 255) 0) nil)
    (gc-mark! lo)
    (set! lo (%+ lo 16)))
  (while (%<= (%+ lo 256) hi)
    (%st-word! (%+ gc-bitmap (gc-map-byte lo)) #x55555555)
    (set! lo (%+ lo 256)))
  (while (%< lo hi)
    (gc-mark! lo)
    (set! lo (%+ lo 16))))

;; Bytes `b0` up to `b1` of the map at `map`, zeroed: whole words where it
;; can.
(define (clear-map-bytes-at map b0 b1)
  (while (if (%< b0 b1) (%> (%logand b0 3) 0) nil)
    (%st-byte! (%+ map b0) 0)
    (set! b0 (%+ b0 1)))
  (while (%<= (%+ b0 4) b1)
    (%st-word! (%+ map b0) 0)
    (set! b0 (%+ b0 4)))
  (while (%< b0 b1)
    (%st-byte! (%+ map b0) 0)
    (set! b0 (%+ b0 1))))

(define (clear-map-bytes b0 b1) (clear-map-bytes-at gc-bitmap b0 b1))

;; The map is cleared with the blitter, a byte per 64 bytes of heap, whole
;; words at a time so that no stale bit is left beside a live one. Only an
;; image collection does this: it waits for the chip, behind whatever the
;; screen has queued.
(define gc-clear-w 1024)

;; n bytes of zero at `at`, as rows the blitter can take, through the
;; collector's own descriptor ring. The chip is handed the root narrowed to
;; the rows and to storing data.
(define (gc-fill-bytes at n)
  (if (%<= n 0)
      nil
      (let* ((w (if (%< n gc-clear-w) n gc-clear-w))
             (rows (%/ (%+ n (%- w 1)) w))
             (b (gc-blit-descriptor)))
        (%cap-st! b bl-dst (%cap-and-perms (%cap-bounds (%from-addr at) (%* rows w)) perm-sd))
        (%cap-st-word! b bl-w w)
        (%cap-st-word! b bl-h rows)
        (%cap-st-word! b bl-dmod w)
        (%cap-st-word! b bl-val 0)
        (blit-go b op-fill)))
  nil)

;; The bits for the heap from `lo` up to `hi`.
(define (clear-map-range lo hi)
  (let ((b0 (%logand (gc-map-byte lo) -4))
        (b1 (%logand (%+ (gc-map-byte hi) 4) -4)))
    (gc-fill-bytes (%+ gc-bitmap b0) (%- b1 b0))))

;; The map over both spaces up to their frontiers. The clears are blits, and
;; a blit is not finished when it returns, so this waits for them to land.
(define (clear-bitmap)
  (clear-map-range cons-base (%ld-word lg-cons-ptr))
  (clear-map-range obj-base (%ld-word lg-obj-ptr))
  (blit-wait-ring *gc-blit-ring*))

;; ---------------------------------------------------------------- skipping
;; A word of the mark map covers sixteen pairs, 256 bytes of heap. Where that
;; word is zero the whole stretch is dead and the passes over cons space step
;; over it. Each pass walks a pointer into the map beside its pointer into
;; the heap, four bytes of map to 256 of heap. The 256 is written into the
;; loops because a literal compiles to one instruction where a global costs
;; two loads.
(defsubst (gc-run-dead? mp) (%= 0 (%ld-word mp)))

(defsubst (gc-word-pairs mp) (%popcount (%ld-word mp)))

;; Every granule from `lo` up to `hi` zeroed, which also clears its tag.
(define (blank lo hi)
  (while (%< lo hi)
    (%st-cap! lo 0)
    (set! lo (%+ lo 8))))

;; ---------------------------------------------------------------- objects
;; The bytes a block occupies, header included, from its header word: a free
;; block counts granules; an object is the header granule and its payload,
;; rounded to the length its capability's bounds can represent and then to a
;; whole granule. `object-payload` in runtime.lisp is the allocator's half of
;; the same rule. A record, most of what a busy heap is made of, is asked
;; about first.
(defsubst (obj-block-size h)
  (let ((ty (%logand h 255)) (n (%lsh h -8)))
    (cond ((%= ty t-record) (%+ 8 (%logand (%+ (%rrl (%lsh n 3)) 7) -8)))
          ((%= ty t-free) (%lsh n 3))
          (else (%+ 8 (%logand (%+ (%rrl (object-payload ty n)) 7) -8))))))

;; Strings and byte vectors hold no tags, and a free block's are cleared.
(defsubst (may-hold-tags? ty)
  (cond ((%= ty t-free) nil)
        ((%= ty t-string) nil)
        ((%= ty t-bytes) nil)
        (else t)))

;; ---------------------------------------------------------------- references
;; The header of the object whose payload starts at `base`, or 0 when there is
;; none. A stale stack slot can name an object that has since been freed and
;; its memory reused, so the header must lie below the frontier, be a number
;; and not a pointer, have a live object's type, and describe an object that
;; ends below the frontier too.
(define (object-header base)
  (let ((h (%- base 8)) (top (%ld-word lg-obj-ptr)))
    (if (%>= h obj-base)
        (if (%< h top)
            (if (%cap-tag? (%ld-cap h))
                0
                (let* ((w (%ld-word h)) (ty (%logand w 255)))
                  (if (%>= ty t-symbol)
                      (if (%<= ty t-code)
                          (if (%<= (%+ h (obj-block-size w)) top) h 0)
                          0)
                      0)))
            0)
        0)))

;; The code object that owns the block whose code starts at `base`, or nil.
;; A code block's header is two granules below its code: its size, then its
;; code object once registered (see `alloc-code`).
(define (code-object-at base)
  (if (%>= base (%+ code-base 16))
      (if (%< base (%ld-word lg-code-ptr))
          (let ((o (%ld-cap (%- base 8))))
            (if (%cap-tag? o) (if (%= 0 (%logand (%cap-perms o) perm-hd)) nil o) nil))
          nil)
      nil))

;; The header of that code object, or 0.
(define (code-owner base)
  (let ((o (code-object-at base)))
    (if o (object-header (%cap-base o)) 0)))

;; The object whose block holds the granule below `base`, which any
;; capability based in object space keeps: its header, or 0. For an object's
;; own capability that granule is its header, a start. Otherwise the nearest
;; start below may be an object that ends before a free block, so the block
;; must reach the granule. A headed capability whose base was moved is no
;; different: it is the header below, not the slot, that is believed.
(defsubst (interior-object base)
  (let ((a (%- base 8)))
    (if (%bit-ref obj-starts (start-index a))
        (object-header base)
        (interior-object-slow a))))

(define (interior-object-slow a)
  (let ((h (object-start-below a)))
    (if (%= h 0)
        0
        (if (%< a (%+ h (obj-block-size (%ld-word h))))
            (object-header (%+ h 8))
            0))))

;; The map, built from a walk of object space when it is not already right:
;; scratch memory is zero when a machine starts, whatever image it starts
;; from. Every block that is not free is a start.
(define (ensure-starts)
  (if (%= (%ld-word obj-starts-ready) obj-starts-magic)
      nil
      (let ((top (%ld-word lg-obj-ptr)) (p obj-base))
        (clear-map-bytes-at obj-starts 0 (%lsh (%- (%+ top 63) obj-base) -6))
        (while (%< p top)
          (let* ((w (%ld-word p)) (size (obj-block-size w)))
            (if (%<= size 0) (gc-corrupt p) nil)
            (if (%= (%logand w 255) t-free) nil (start-set! p))
            (set! p (%+ p size))))
        (%st-word! obj-starts-ready obj-starts-magic))))

;; Where the mark bit for a tagged capability lives: the pair its base lies
;; in, the header of the object its base lies in, a code capability's code
;; object's header; or 0 when the capability is not the collector's.
(define (gc-block-of v)
  (let ((base (%cap-base v)) (perms (%cap-perms v)))
    (cond ((%> base obj-base)
           (if (%<= base obj-limit) (interior-object base) 0))
          ((%>= base cons-base)
           (if (%> (%logand perms perm-hd) 0)
               0
               (if (%< base (%ld-word lg-cons-ptr)) (%logand base -16) 0)))
          ((%> (%logand perms perm-hd) 0) 0)
          ((%> (%logand perms perm-ex) 0) (code-owner base))
          (else 0))))

;; Open-coded: marking asks this for every granule of every live block.
(defsubst (gc-push v)
  (if (%cap-tag? v)
      (let ((b (gc-block-of v)))
        (if (%= b 0)
            nil
            (if (marked? b)
                nil
                (begin
                  (gc-mark! b)
                  (if (%>= *mark-sp* gc-stack-cap)
                      (gc-overflow)
                      (begin
                        (%st-word! (%+ gc-stack (%lsh *mark-sp* 2)) b)
                        (set! *mark-sp* (%+ *mark-sp* 1))))))))
      nil))

(define (gc-overflow)
  (uart-string "gc: mark stack overflow")
  (uart-nl)
  (%halt exit-gc-stack))

;; Every tagged granule from `lo` up to `hi`.
(define (scan-granules lo hi)
  (while (%< lo hi)
    (gc-push (%ld-cap lo))
    (set! lo (%+ lo 8))))

;; How much a slice traces before it lets interrupts back in: a few thousand
;; bytes, on the order of a hundred thousand cycles.
(define slice-bytes 4096)

;; Pop and trace until the slice is full or the stack is empty. Answers the
;; bytes traced. Runs with interrupts off: the barrier pushes from the trap
;; handler, and the two must not interleave.
(define (trace-some)
  (let ((done 0))
    (while (if (%> *mark-sp* 0) (%< done slice-bytes) nil)
      (set! *mark-sp* (%- *mark-sp* 1))
      (let ((b (%ld-word (%+ gc-stack (%lsh *mark-sp* 2)))))
        (if (%< b obj-base)
            (begin
              (gc-push (%ld-cap b))
              (gc-push (%ld-cap (%+ b 8)))
              (set! done (%+ done 16)))
            (let* ((w (%ld-word b)) (size (obj-block-size w)))
              (if (may-hold-tags? (%logand w 255)) (scan-granules (%+ b 8) (%+ b size)) nil)
              (set! done (%+ done size))))))
    done))

;; ---------------------------------------------------------------- roots
;; A stack, from its stack pointer to its top: every granule above the stack
;; pointer belongs to a frame and says what it holds. The stack pointer is a
;; capability bounded to the task's whole stack, so its top is the stack's.
(define (scan-stack sp)
  (if (%cap-tag? sp)
      (scan-granules (%logand (%addr-of sp) -8) (%cap-top sp))
      nil))

;; A saved register context, given by its address: its thirty-two slots, the
;; pc and x1 to x31, and the stack its saved sp names.
(define (scan-context ctx)
  (let ((a (%addr-of ctx)))
    (scan-granules a (%+ a ctx-bytes))
    (scan-stack (%ld-cap (%+ a (%lsh reg-sp 3))))))

;; Inside a trap, the code the trap interrupted is neither running nor on a
;; list: its registers are in the context MScratchC names, and a nested trap's
;; context links to the one it interrupted, just past the registers. `fn` is
;; called on each.
(define (each-trap-context fn)
  (let ((depth (%ld-word lg-trapdepth)) (ctx (%addr-of (%context))))
    (while (%> depth 0)
      (%funcall fn ctx)
      (set! depth (%- depth 1))
      (if (%> depth 0) (set! ctx (%addr-of (%ld-cap (%+ ctx ctx-bytes)))) nil))))

;; A context a trap saved. A trap inside the handler interrupted code on the
;; trap stack, which `roots` scans from where it stands, so only a context
;; on another stack has its stack scanned here.
(define (scan-trap-context ctx)
  (let* ((a (%addr-of ctx)) (sp (%ld-cap (%+ a (%lsh reg-sp 3)))))
    (scan-granules a (%+ a ctx-bytes))
    (if (%= (%cap-base sp) (%cap-base (%stack-pointer))) nil (scan-stack sp))))

;; Replaced by exec.lisp once the kernel is up, to scan every other task's
;; context with `scan-context`.
(define (extra-roots) nil)

;; What the blitter holds for blits it has not finished: every tagged granule
;; of every task's descriptor ring (see `*blit-rings*`).
(define (scan-blit-rings)
  (let ((p *blit-rings*))
    (while (%cons? p)
      (scan-granules (%car p) (%+ (%car p) blit-ring-bytes))
      (set! p (%cdr p)))))

;; Low memory holds the globals, each an 8-byte slot holding a value or a
;; number, so every tagged granule below the pool is a root.
(define (roots)
  (scan-granules 0 pool-base)
  (scan-blit-rings)
  (gc-push (%this-task))
  ;; This task's own stack, from where it stands.
  (scan-stack (%stack-pointer))
  ;; Whatever a trap interrupted, if this is inside one.
  (each-trap-context scan-trap-context)
  ;; Every other task.
  (extra-roots))

;; ---------------------------------------------------------------- runs
;; A task's cons run is its `gp`: a capability bounded to the run, its
;; address the next free pair. The run with nothing in it is bounded to no
;; bytes, so the first pair cut from it faults and asks for a real one; it
;; is not sixteen bytes long, so it is not a pair either.
(define (empty-cons-run)
  (%cap-and-perms (%cap-bounds-exact (%from-addr cons-base) 0) perms-pair))

;; The run a saved context holds is given up: the task's next pair faults and
;; asks for a fresh one. A pair it was in the middle of making is in a
;; register as a pair capability, and is kept like any other.
(define (drop-context-run ctx)
  (%st-cap! (%+ (%addr-of ctx) (%lsh reg-gp 3)) (empty-cons-run)))

;; Replaced by exec.lisp once there are other tasks to tell.
(define (invalidate-runs) nil)

;; Every run in the machine given up: this task's, any a trap interrupted, and
;; every other task's. What was left of them lies below the frontier, where
;; the sweep finds it.
(define (give-up-runs)
  (%set-cons-run! (empty-cons-run))
  (each-trap-context drop-context-run)
  (invalidate-runs))

;; A run of free cons space is described in its own first pair: the end
;; address, then the next run. Handing the pair out later is fine, because
;; `next-run` reads both before anything is allocated from it.
(define (gc-add-run start end)
  (%st-cap! start end)
  (%st-cap! (%+ start 8) 0)
  (if (%= *run-last* 0)
      (%st-word! lg-cons-free start)
      (%st-cap! (%+ *run-last* 8) start))
  (set! *run-last* start))

;; ---------------------------------------------------------------- obj sweep
(defsubst (obj-bin-addr gran)
  (%+ obj-bins (%lsh (if (%< gran obj-bin-count) gran 0) 3)))

;; `len` is in bytes and a multiple of eight. A block of one granule is all
;; header, with no slot to link it by, so it is left for the sweep to join to
;; its neighbours.
(define (gc-free-block start len)
  (let ((gran (%lsh len -3)))
    (%st-cap! start (%logior (%lsh gran 8) t-free))
    (if (%>= gran 2)
        (let ((bin (obj-bin-addr gran)))
          (%st-cap! (%+ start 8) (%ld-word bin))
          (%st-cap! bin start))
        nil)))

(define (gc-clear-bins)
  (let ((i 0))
    (while (%< i obj-bin-count)
      (%st-cap! (%+ obj-bins (%lsh i 3)) 0)
      (set! i (%+ i 1)))))

(define (gc-corrupt p)
  (uart-string "gc: corrupt object header at ")
  (uart-hex p)
  (uart-nl)
  (%halt exit-gc-corrupt))

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
;; bits cleared as it is handed out.
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
  (let ((d (cycles-since t0)))
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
;; Interrupts off throughout: the one stretch a cycle stops the machine for.
;; The holes the last sweep left are below the frontier, where this sweep
;; will find them again, so they are dropped, and every run is given up:
;; every pair made from here on comes from fresh ground above the frontier,
;; marked as it is handed out.
(define (start-cycle)
  (let ((t0 (%cycles)))
    (set! *t-start* t0)
    (set! *mark-sp* 0)
    (set! *slices* 0)
    (set! *t-mark* 0) (set! *t-code* 0) (set! *t-objects* 0) (set! *t-pairs* 0) (set! *t-clear* 0)
    (set! *small-holes* 0) (set! *inner-dead* 0)
    (set! *slice-max* 0)
    (set! *slice-kind* kind-start)
    (set! *barriers* 0)
    (set! *cons-hi* (%ld-word lg-cons-ptr))
    (set! *obj-hi* (%ld-word lg-obj-ptr))
    (%st-word! lg-cons-free 0)
    (set! *run-last* 0)
    (give-up-runs)
    (ensure-starts)
    (set! *phase* phase-marking)
    (roots)
    (%set-gc-mode! 1)
    (note-slice t0)))

;; ---------------------------------------------------------------- barrier
;; The block whose mark bit the processor's barrier reads for `v`, by the
;; rule `Machine::referent` keeps: in cons space the pair at its base rounded
;; down, if it has no HD; in object space the nearest start at or below the
;; granule before its base.
(define (barrier-block v)
  (let ((base (%cap-base v)))
    (cond ((%< base cons-base) 0)
          ((%< base cons-limit)
           (if (%= 0 (%logand (%cap-perms v) perm-hd)) (%logand base -16) 0))
          ((%> base obj-limit) 0)
          ((%> base obj-base) (object-start-at (%- base 8)))
          (else 0))))

;; From the trap handler: a store is about to overwrite the granule at
;; `addr`, which holds a pointer to an unmarked object. Mark it and trace it
;; later. The bit goes on wherever the processor looks for it, the
;; capability's base or the header below it, because the store re-executes
;; and must not trap again. Allocates nothing.
(define (barrier addr)
  (set! *barriers* (%+ *barriers* 1))
  (let ((v (%ld-cap addr)))
    (if (%cap-tag? v)
        (let ((b (barrier-block v)))
          (if (%= *phase* phase-marking) (gc-push v) nil)
          (if (%>= b gc-heap-lo) (if (%< b gc-heap-hi) (gc-mark! b) nil) nil))
        nil))
  nil)

;; ---------------------------------------------------------------- finish
;; The mark stack is empty and nothing can be pushed while interrupts are
;; off: the barrier can go off, and the sweep can begin. Code before objects:
;; the object sweep zeroes dead objects, and a dead code object's first slot
;; is the capability to the code it owns.
(define (finish-mark)
  (%set-gc-mode! 0)
  (set! *code-i* 0)
  (set! *code-keep* 0)
  (set! *code-n* (%ld-word lg-code-reg-n))
  (set! *code-freed* 0)
  (gc-clear-bins)
  ;; What was made while marking is black and lies above the frontiers the
  ;; cycle began with; its bits come off after the sweep.
  (set! *clear-cons* *cons-hi*)
  (set! *clear-cons-hi* (%ld-word lg-cons-ptr))
  (set! *clear-obj* *obj-hi*)
  (set! *clear-obj-hi* (%ld-word lg-obj-ptr))
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
;; Object space, a stretch at a time: dead objects are zeroed, so that their
;; tags go, and dead runs become free blocks in the bins; the bits behind the
;; sweep are cleared for the next cycle. A dead run at the very top lowers the
;; frontier, if nothing has been allocated above it since the cycle began.
;; Answers the bytes walked.
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
      (let* ((w (%ld-word p)) (size (obj-block-size w)))
        ;; A zero size is a corrupt header and would spin here for ever.
        (if (%<= size 0) (gc-corrupt p) nil)
        (if (marked? p)
            (begin
              (start-set! p)
              (if (%> runlen 0)
                  (begin (gc-free-block run runlen) (set! nfree (%+ nfree runlen)))
                  nil)
              (set! runlen 0))
            (begin
              (start-clear! p)
              (if (may-hold-tags? (%logand w 255)) (blank (%+ p 8) (%+ p size)) nil)
              (if (%= runlen 0) (set! run p) nil)
              (set! runlen (%+ runlen size))))
        (set! p (%+ p size))))
    (if (%>= p *obj-hi*)
        (begin
          (if (%> runlen 0)
              (if (%= (%ld-word lg-obj-ptr) *obj-hi*)
                  (%st-word! lg-obj-ptr run)
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

;; Cons space, a stretch of the map at a time. A word of the map is sixteen
;; pairs; a run of dead words is a hole, zeroed as it is walked, and a hole
;; big enough becomes a run for the allocator. Live pairs are counted for the
;; budget. Each word is cleared once it has been read. The last word may
;; reach past the frontier the cycle began with, into pairs made since, so
;; nothing past that frontier is zeroed. Answers the bytes of heap walked.
(define sweep-cons-words 512)

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
          (begin
            (blank p (if (%< (%+ p 256) *cons-hi*) (%+ p 256) *cons-hi*))
            (if (%= hole 0) (set! hole p) nil))
          (begin
            (if (%> hole 0)
                (begin
                  (if (%>= (%- p hole) gap-min)
                      (begin (gc-add-run hole p) (set! holes (%+ holes (%- p hole))))
                      (set! *small-holes* (%+ *small-holes* (%- p hole))))
                  (set! hole 0))
                nil)
            (let ((wl (%lsh (gc-word-pairs mp) 4)))
              (set! live (%+ live wl))
              (set! *inner-dead* (%+ *inner-dead* (%- 256 wl))))
            (if *keep-marks* nil (%st-word! mp 0))))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))
    (if (%>= p *cons-hi*)
        (begin
          ;; The hole at the top: the frontier comes down to it if nothing
          ;; has been carved above since the cycle began, else it is a run.
          (if (%> hole 0)
              (if (%= (%ld-word lg-cons-ptr) *cons-hi*)
                  (%st-word! lg-cons-ptr hole)
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
;; pointer and this is dead; it is blanked only for an image, so that the
;; file is the size of what is in it.
(define *cons-dirty-top* 0)

(define (finish-cycle)
  (%st-word! lg-obj-free-n *obj-freed*)
  (%st-word! lg-cons-free-n (%+ (%lsh (%- cons-limit (%ld-word lg-cons-ptr)) -4)
                                (%lsh *cons-holes* -4)))
  (if (%> *cons-hi* *cons-dirty-top*) (set! *cons-dirty-top* *cons-hi*) nil)
  (set-budget)
  (set! *count* (%+ *count* 1))
  (%st-word! lg-gccount *count*)
  (let ((spent (cycles-since *t-start*)))
    (set! *phase* phase-idle)
    (if *verbose* (report spent) nil)
    (set! *refills* 0)))

;; Straight to the serial line: no allocation inside a collection.
(define (report spent)
  (uart-string "[gc ")
  (uart-num (%- (%lsh (%- *cons-hi* cons-base) -4) (%lsh *cons-live* -4)))
  (uart-string " pairs, ")
  (uart-num *obj-freed*)
  (uart-string " object bytes, ")
  (uart-num *code-freed*)
  (uart-string " code bytes freed; ")
  (uart-num (%lsh *cons-live* -4))
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
      (cycles-since t0))))

;; Called by whoever is about to allocate `bytes`: the collector keeps pace
;; with allocation by spending some cycles for every byte allocated, starting
;; a cycle when the budget says so. The budget lets twice the live data be
;; allocated before the next cycle, so a dozen cycles a byte finishes a cycle
;; in time with room to spare. The slices are interruptible in between, so
;; this is not a pause; what a big allocation owes is capped and carried
;; over, so it is not a long one either. A caller already inside a critical
;; section gets two slices at most: the rest waits for one that is not. The
;; idle task does whatever is left.
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
  (let ((live (%+ (%- (%- (%ld-word lg-obj-ptr) obj-base) (%ld-word lg-obj-free-n))
                  *cons-live*)))
    (set! *gc-allocated* 0)
    (set! *cons-given* 0)
    (set! *budget* (if (%> (%* 2 live) budget-min) (%* 2 live) budget-min))))

;; ---------------------------------------------------------------- refill
;; How much cons space a task is given at a time: big enough that refilling
;; is rare, small enough that a task which stops allocating is not sitting on
;; much. The run is the task's alone until it is used up, which is what makes
;; the four-instruction allocator safe without a lock. Fresh ground is carved
;; on boundaries of this size, where a run's bounds are exact.
(define cons-chunk 262144)     ; 16384 pairs

;; The run from `start` up to `end`, as a capability: bounded exactly, so the
;; stretch is cut down to what the processor can represent, its base rounded
;; up and its length down to the alignment `%ram` names. A run handed out
;; while marking is black from the start; at any other time its bits are
;; cleared, which is what keeps the map zero above the frontier. Interrupts
;; off.
(define (hand-out-run start end)
  (let* ((m (%ram (%- end start)))
         (b (%logand (%+ start (%lognot m)) m))
         (len (%logand (%- end b) m)))
    (set! *refills* (%+ *refills* 1))
    (set! *cons-given* (%+ *cons-given* len))
    (note-run! len)
    (if (%= *phase* phase-marking) (mark-pairs b (%+ b len)) (clear-range b (%+ b len)))
    (%cap-and-perms (%cap-bounds-exact (%from-addr b) len) perms-pair)))

;; A hole the sweep left, else fresh ground up to the next chunk boundary.
;; Answers nil when there is neither. A piece of fresh ground too small to be
;; worth a run is stepped over; it lies below the frontier, where the next
;; sweep finds it. Interrupts off.
(define (next-run)
  (let ((hole (%ld-word lg-cons-free)))
    (if (%> hole 0)
        (let ((end (%ld-word hole)))
          (%st-word! lg-cons-free (%ld-word (%+ hole 8)))
          (if (%= (%ld-word lg-cons-free) 0) (set! *run-last* 0) nil)
          (hand-out-run hole end))
        (let* ((p (%ld-word lg-cons-ptr))
               (top (%logand (%+ p cons-chunk) (%- 0 cons-chunk))))
          (if (%< (%- top p) gap-min)
              (begin (set! p top) (set! top (%+ top cons-chunk)))
              nil)
          (if (%> top cons-limit) (set! top cons-limit) nil)
          (if (%< (%- top p) gap-min)
              nil
              (begin
                (%st-word! lg-cons-ptr top)
                (hand-out-run p top)))))))

;; The trap handler calls this when a task's run is used up: a length fault
;; on `gp`. It answers the task's next run, which the handler writes into the
;; saved `gp` and the live one before it retries the instruction. The
;; collector's share of work comes first, paid for the run just used up,
;; whatever its size: a task's first run is paid for when it asks for its
;; second, so a fresh task is not stalled on its first cons by a collection
;; in progress. Never allocates a pair: the run it would come from is the
;; one that is used up.
(define (refill-cons-run)
  (pace (take-owed-run))
  (without-interrupts
    (let ((run (next-run)))
      (if run
          run
          (begin
            (collect)
            (set! run (next-run))
            (if run run (out-of-memory "cons space")))))))

;; ---------------------------------------------------------------- allocation
;; What `alloc-object` calls, with interrupts off: the address of a block of
;; `size` bytes whose payload, a granule past its start, satisfies the
;; alignment mask `m`; or 0 when there is no room at all, and `alloc-object`
;; collects and asks again. A block taken while marking is black from the
;; start; at any other time its bit is cleared.
(define (obj-take size m)
  (let* ((align (%- 0 m))
         (h (if (%<= align 8) (obj-take-any size) (obj-take-aligned size align))))
    (if (%> h 0)
        (begin
          (set! *gc-allocated* (%+ *gc-allocated* size))
          (start-set! h)
          (if (%= *phase* phase-marking) (gc-mark! h) (gc-unmark! h)))
        nil)
    h))

;; A payload with an alignment of its own: a block big enough to hold the
;; object wherever the alignment falls, carved so that what is in front of
;; the object and behind it go back as free blocks.
(define (obj-take-aligned size align)
  (let* ((want (%+ size (%- align 8)))
         (p (obj-take-any want)))
    (if (%= p 0)
        0
        (let* ((h (%- (%logand (%+ p (%+ 8 (%- align 1))) (%- 0 align)) 8))
               (end (%+ h size)))
          (if (%> h p) (gc-free-block p (%- h p)) nil)
          (if (%< end (%+ p want)) (gc-free-block end (%- (%+ p want) end)) nil)
          h))))

;; Exact fit first, then a split from the big-block list, then bump.
(define (obj-take-any size)
  (let* ((gran (%lsh size -3))
         (bin (obj-bin-addr gran))
         (p (if (%< gran obj-bin-count) (%ld-word bin) 0)))
    (if (%> p 0)
        (begin (%st-cap! bin (%ld-word (%+ p 8))) p)
        (obj-take-slow size))))

(define (obj-take-slow size)
  (let ((prev 0)
        (p (%ld-word obj-bins))
        (found 0))
    (while (if (%= found 0) (%> p 0) nil)
      (let ((have (%lsh (%lsh (%ld-word p) -8) 3))
            (next (%ld-word (%+ p 8))))
        (if (%>= have size)
            (begin
              (if (%= prev 0)
                  (%st-cap! obj-bins next)
                  (%st-cap! (%+ prev 8) next))
              (if (%>= (%- have size) 8)
                  (gc-free-block (%+ p size) (%- have size))
                  nil)
              (set! found p))
            (begin (set! prev p) (set! p next)))))
    (if (%> found 0)
        found
        (let ((q (%ld-word lg-obj-ptr)))
          (if (%<= (%+ q size) (%ld-word lg-obj-end))
              (begin (%st-word! lg-obj-ptr (%+ q size)) q)
              0)))))

;; ================================================================ compaction
;;
;; Sliding compaction of cons space, for images, in four passes:
;;
;;   1. mark        done by the time this runs: a whole cycle has finished
;;   2. plan        where every live pair is going, recording the free pointer
;;                  at each word of the map so that any pair's destination is
;;                  a popcount away
;;   3. update      rewrite every pointer to a pair, wherever it is, to where
;;                  the pair is going
;;   4. move        slide the pairs down
;;
;; Updating before moving is what makes this work without a forwarding word
;; per pair: while pass 3 runs, everything is still where the map says. The
;; tags say exactly where every pointer is, so pass 3 is a walk over memory:
;; low memory and the pool, where the globals, stacks and contexts are; the
;; live pairs; and object space, whose free blocks hold no tags.
;;
;; Objects do not move. This collector is written in the language it
;; collects, and between updating and moving it calls functions and reaches
;; constants through objects. docs/moving-objects.md lists the ways round
;; that.

;; One walk over the map, recording the free pointer on the way into each
;; word that holds a live pair. Answers where the live pairs will end.
(define (plan-cons hi)
  (let ((p cons-base) (mp gc-bitmap) (free cons-base))
    (while (%< p hi)
      (if (gc-run-dead? mp)
          nil
          (begin
            (%st-word! (%+ gc-cons-prefix (%- mp gc-bitmap)) free)
            (set! free (%+ free (%lsh (gc-word-pairs mp) 4)))))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))
    free))

;; Where the live pair at `p` is going: its word's entry plus sixteen bytes
;; for every live pair ahead of it in the word.
(define (forward-cons p)
  (let* ((i (gc-bit-index p))
         (w (%lsh (%lsh i -5) 2)))
    (%+ (%ld-word (%+ gc-cons-prefix w))
        (%lsh (%popcount (%logand (%ld-word (%+ gc-bitmap w))
                                  (%- (%lsh 1 (%logand i 31)) 1)))
              4))))

;; Every capability into a pair below `cons-hi` in the granules from `lo` up
;; to `hi`, rewritten: derived afresh where the pair is going, with the same
;; permissions, bounds and offset relative to the pair, so a capability
;; narrowed to a car or a cdr moves with its pair. A pointer to a pair that is
;; not marked is in dead memory, a stack slot below its frame, and is left as
;; it is; so is one reaching past its pair, a run, which is given up after.
(define (update-range lo hi cons-hi)
  (while (%< lo hi)
    (let ((v (%ld-cap lo)))
      (if (%cap-tag? v)
          (let* ((b (%cap-base v)) (p (%logand b -16)) (len (%cap-len v)))
            (if (%= 0 (%logand (%cap-perms v) perm-hd))
                (if (%>= b cons-base)
                    (if (%< b cons-hi)
                        (if (%<= (%+ (%- b p) len) 16)
                            (if (marked? p)
                                (let ((to (%+ (forward-cons p) (%- b p))))
                                  (%st-cap! lo (%cap-set-addr
                                                (%cap-and-perms (%cap-bounds-exact (%from-addr to) len)
                                                                (%cap-perms v))
                                                (%+ to (%cap-offset v)))))
                                nil)
                            nil)
                        nil)
                    nil)
                nil))
          nil))
    (set! lo (%+ lo 8))))

;; The pointers inside the live pairs: every word of the map with a pair in
;; it, both granules of each of its sixteen pairs.
(define (update-pairs cons-hi)
  (let ((p cons-base) (mp gc-bitmap))
    (while (%< p cons-hi)
      (if (gc-run-dead? mp) nil (update-range p (%+ p 256) cons-hi))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))))

;; The walk is in address order, so the destination is a running pointer
;; rather than a lookup. It follows the rule `plan-cons` uses to build the
;; table. A pair is copied a granule at a time with its tags.
(define (move-cons hi)
  (let ((p cons-base) (mp gc-bitmap) (free cons-base))
    (while (%< p hi)
      (if (gc-run-dead? mp)
          nil
          (let ((q p) (e (%+ p 256)))
            (if (%> e hi) (set! e hi) nil)
            (while (%< q e)
              (if (marked? q)
                  (begin
                    (if (%= free q)
                        nil
                        (begin
                          (%st-cap! free (%ld-cap q))
                          (%st-cap! (%+ free 8) (%ld-cap (%+ q 8)))))
                    (set! free (%+ free 16)))
                  nil)
              (set! q (%+ q 16)))))
      (set! p (%+ p 256))
      (set! mp (%+ mp 4)))
    (set! *cons-live* (%- free cons-base))))

;; Right after a whole cycle, whose mark bits are still those of the heap as
;; it stands: nothing has been allocated in between. Interrupts off
;; throughout. Afterwards every live pair is below the new top, everything
;; above it is zero, there are no holes, and every run has been given up.
;; The map is stale everywhere below the frontiers; the caller clears it.
(define (compact)
  (let* ((cons-hi (%ld-word lg-cons-ptr))
         (top (plan-cons cons-hi)))
    ;; Rewrite every pointer to a pair. Nothing may follow a pair between
    ;; here and the end of the slide.
    (update-range 0 (%ld-word lg-poolptr) cons-hi)
    (update-pairs cons-hi)
    (update-range obj-base (%ld-word lg-obj-ptr) cons-hi)
    (move-cons cons-hi)
    (blank top cons-hi)
    (if (%> cons-hi *cons-dirty-top*) (set! *cons-dirty-top* cons-hi) nil)
    (%st-word! lg-cons-ptr top)
    (%st-word! lg-cons-free 0)
    (set! *run-last* 0)
    (%st-word! lg-cons-free-n (%lsh (%- cons-limit top) -4))
    (give-up-runs)
    (set-budget)
    (%lsh (%- cons-limit top) -4)))

;; ---------------------------------------------------------------- code space
;; Code is collected but not moved: this collector runs as compiled code, and
;; sliding the function it is standing in is not possible. A code block is
;; kept by its code object, and its code object by anything that holds it: a
;; closure, a frame's saved s1, a literal. A code capability, a return
;; address or an entry, keeps the code object too, through the block's
;; header:
;;
;;   entry - 16    the block's size in bytes, header included
;;   entry - 8     the code object that owns it, once registered
;;   entry         the machine code
;;
;; Blocks are whole multiples of sixteen bytes, so every piece left over when
;; one is carved can be a free block: its size, then the next free block.
;;
;; The registry of code objects is a plain array in the pool, not a list in
;; the heap: a list would be a root, and a root would keep every version of
;; every function alive.

(define code-registry-max 65536)
(define code-registry-bytes (%lsh code-registry-max 3))

(define (code-registry)
  (let ((r (%ld-word lg-code-reg)))
    (if (%> r 0)
        r
        (let ((a (%addr-of (alloc-pool code-registry-bytes))))
          (%st-word! lg-code-reg a)
          (%st-word! lg-code-reg-n 0)
          a))))

;; Code space has no headers to walk, so the collector finds code through the
;; registry, and a code capability finds its code object through the block.
(define (register-code obj)
  (without-interrupts
  (let ((r (code-registry))
        (n (%ld-word lg-code-reg-n)))
    (if (%>= n code-registry-max)
        (error "code registry full")
        nil)
    (%st-cap! (%+ r (%lsh n 3)) obj)
    (%st-word! lg-code-reg-n (%+ n 1))
    ;; Slot 0 is the entry, whose base is the code.
    (%st-cap! (%- (%cap-base (%ld-cap (%cap-base obj))) 8) obj)
    obj)))

;; The first free block of at least `want` bytes, off the list, or 0.
(define (code-take want)
  (let ((prev 0) (p (%ld-word lg-code-free)) (got 0))
    (while (if (%= got 0) (%> p 0) nil)
      (let ((have (%ld-word p)) (next (%ld-word (%+ p 8))))
        (if (%>= have want)
            (begin
              (if (%= prev 0)
                  (%st-word! lg-code-free next)
                  (%st-cap! (%+ prev 8) next))
              (%st-word! lg-code-free-n (%- (%ld-word lg-code-free-n) have))
              (set! got p))
            (begin (set! prev p) (set! p next)))))
    got))

(define (code-free-block p size)
  (%st-cap! p size)
  (%st-cap! (%+ p 8) (%ld-word lg-code-free))
  (%st-word! lg-code-free p)
  (%st-word! lg-code-free-n (%+ (%ld-word lg-code-free-n) size)))

;; Fresh ground: `want` bytes off the top of code space.
(define (code-bump want)
  (let ((q (%ld-word lg-code-ptr)))
    (if (%> (%+ q want) (%ld-word lg-code-end))
        (out-of-memory "code space")
        nil)
    (%st-word! lg-code-ptr (%+ q want))
    q))

;; Room for `nbytes` of machine code, answered as the address the code goes
;; at: aligned as `%ram` asks for that length, so that a capability bounded
;; exactly to it is representable, with at least `(%rrl nbytes)` bytes there.
;; A free block first, then bump; what is in front of the block and behind
;; it goes back on the free list. The block's tail past `nbytes` is zeroed,
;; so a reused block carries nothing of the code it held before into an
;; image.
(define (alloc-code nbytes)
  (without-interrupts
  (let* ((size (%+ 16 (%logand (%+ (%rrl nbytes) 15) -16)))
         (align (let ((a (%- 0 (%ram nbytes)))) (if (%< a 16) 16 a)))
         (want (%+ size (%- align 16)))
         (p (code-take want))
         (have (if (%> p 0) (%ld-word p) want)))
    (if (%= p 0) (set! p (code-bump want)) nil)
    (let* ((at (%logand (%+ p (%+ 16 (%- align 1))) (%- 0 align)))
           (start (%- at 16))
           (end (%+ start size)))
      (if (%> start p) (code-free-block p (%- start p)) nil)
      (if (%< end (%+ p have)) (code-free-block end (%- (%+ p have) end)) nil)
      (%st-cap! start size)
      (%st-cap! (%+ start 8) 0)
      (blank (%logand (%+ at nbytes) -8) end)
      at))))

;; Compact the registry in place, a stretch at a time, keeping the entries
;; whose code object survived and handing the rest of code space back. The
;; entries are those the registry held when marking finished; anything
;; registered since sits above them, unmarked but not this cycle's business,
;; and is moved down behind the survivors at the end. The tail that leaves is
;; zeroed. A code object made while marking is black, like any other object,
;; so it is kept. Answers the entries walked.
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
      (let ((obj (%ld-cap (%+ r (%lsh i 3)))))
        (if (marked? (%- (%cap-base obj) 8))
            (begin
              (%st-cap! (%+ r (%lsh keep 3)) obj)
              (set! keep (%+ keep 1)))
            (let ((entry (%ld-cap (%cap-base obj))))
              (if (%cap-tag? entry)
                  (let* ((b (%- (%cap-base entry) 16)) (size (%ld-word b)))
                    (code-free-block b size)
                    (set! freed (%+ freed size)))
                  nil))))
      (set! i (%+ i 1)))
    (if (%>= i n)
        (let ((now (%ld-word lg-code-reg-n)) (j n))
          (while (%< j now)
            (%st-cap! (%+ r (%lsh keep 3)) (%ld-cap (%+ r (%lsh j 3))))
            (set! keep (%+ keep 1))
            (set! j (%+ j 1)))
          (blank (%+ r (%lsh keep 3)) (%+ r (%lsh now 3)))
          (%st-word! lg-code-reg-n keep))
        nil)
    (set! *code-i* i)
    (set! *code-keep* keep)
    (set! *code-freed* (%+ *code-freed* freed))
    (%- i start)))

;; ---------------------------------------------------------------- images
;; Zeroing the inside of every free block in object space makes a page with
;; nothing live on it a page of zeroes, which the image writer skips. Far too
;; expensive for an ordinary collection. Answers the bytes zeroed.
(define (blank-free-objects)
  (let ((p obj-base)
        (hi (%ld-word lg-obj-ptr))
        (zeroed 0))
    (while (%< p hi)
      (let* ((h (%ld-word p))
             (size (obj-block-size h)))
        (if (%<= size 0) (gc-corrupt p) nil)
        ;; granules 0 and 1 are the block's size and its place on the chain
        (if (if (%= (%logand h 255) t-free) (%> size 16) nil)
            (begin
              (blank (%+ p 16) (%+ p size))
              (set! zeroed (%+ zeroed (%- size 16))))
            nil)
        (set! p (%+ p size))))
    zeroed))

;; The same for the code that sweeping freed. A rebuild allocates its new
;; code above the old, so without this every dead byte goes into the file.
(define (blank-free-code)
  (let ((p (%ld-word lg-code-free)))
    (while (%> p 0)
      (let ((size (%ld-word p)) (next (%ld-word (%+ p 8))))
        (blank (%+ p 16) (%+ p size))
        (set! p next)))))

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
;; the pool is not traced: a list of them on the stack would be a root.

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
        (%vector-length (%ld-cap lg-obarray))))

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

;; Answers a pool block holding the count and then the detached symbols, or
;; nil when there are none.
(define (detach-idle-symbols)
  (let ((n 0) (l (%ld-cap lg-symlist)))
    (while (%cons? l)
      (if (symbol-idle? (%car l)) (set! n (%+ n 1)) nil)
      (set! l (%cdr l)))
    (if (%= n 0)
        nil
        (let* ((block (alloc-pool (%lsh (%+ n 1) 3)))
               (a (%addr-of block))
               (i 1))
          (set! l (%ld-cap lg-symlist))
          (while (%cons? l)
            (let ((s (%car l)))
              (if (symbol-idle? s)
                  (begin
                    (%st-cap! (%+ a (%lsh i 3)) s)
                    (set! i (%+ i 1)))
                  nil))
            (set! l (%cdr l)))
          (%st-cap! a n)
          (let* ((ob (%ld-cap lg-obarray)) (k 0) (nb (%vector-length ob)))
            (while (%< k nb)
              (%vector-set! ob k (drop-idle-symbols (%vector-ref ob k)))
              (set! k (%+ k 1))))
          (%st-cap! lg-symlist (drop-idle-symbols (%ld-cap lg-symlist)))
          block))))

;; After the collection: the mark bits are still those of the collection
;; just done, and objects do not move, so a detached symbol's bit says
;; whether anything reached it.
(define (reattach-marked-symbols block)
  (if block
      (let* ((a (%addr-of block)) (n (%ld-word a)) (i 1) (ob (%ld-cap lg-obarray)))
        (while (%<= i n)
          (let ((s (%ld-cap (%+ a (%lsh i 3)))))
            (if (marked? (%- (%cap-base s) 8))
                (let ((b (symbol-bucket s)))
                  (%vector-set! ob b (%cons s (%vector-ref ob b)))
                  (%st-cap! lg-symlist (%cons s (%ld-cap lg-symlist))))
                nil))
          (set! i (%+ i 1)))
        (blank a (%+ a (%lsh (%+ n 1) 3)))
        (free-pool block))
      nil))

;; Collect for an image: drop the idle symbols, collect, compact the pairs,
;; and blank what was reclaimed so that the file is the size of what is in
;; it. A cycle already under way is finished first, because the compactor
;; reads the marks of a cycle that kept them from its start.
;;
;; The reattached symbols' pairs come out of a run carved at the new top,
;; the only free cons space the compactor leaves. Afterwards the frontier
;; comes down to the first pair not made and the run is given up, so the
;; file holds the live pairs and nothing else, and the image starts with an
;; empty run. Answers the bytes of free object space blanked.
(define (collect-for-image)
  (let ((idle (detach-idle-symbols)))
    (without-interrupts
      (if (busy?) (collect) nil)
      (set! *keep-marks* t)
      (collect)
      (compact)
      (set! *keep-marks* nil)
      (reattach-marked-symbols idle)
      (let ((run (%cons-run)))
        (if (%> (%cap-len run) 0) (%st-word! lg-cons-ptr (%addr-of run)) nil))
      (%set-cons-run! (empty-cons-run))
      (%st-word! lg-cons-free-n (%lsh (%- cons-limit (%ld-word lg-cons-ptr)) -4))
      (blank (%ld-word lg-cons-ptr) *cons-dirty-top*)
      (clear-bitmap)))
  (blank-free-code)
  (blank-free-objects))

;; ---------------------------------------------------------------- reporting
(define (room)
  (emit-str "cons free ")
  (emit-str (number->string (%ld-word lg-cons-free-n)))
  (emit-str " of ")
  (emit-str (number->string (%lsh (%- cons-limit cons-base) -4)))
  (emit-str ", object bytes used ")
  (emit-str (number->string (%- (%ld-word lg-obj-ptr) obj-base)))
  (emit-str ", code bytes used ")
  (emit-str (number->string
             (%- (%- (%ld-word lg-code-ptr) code-base) (%ld-word lg-code-free-n))))
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
  (let ((l (%ld-cap lg-symlist)) (used nil))
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
  (let* ((ob (%ld-cap lg-obarray))
         (n (%vector-length ob))
         (i 0))
    (while (%< i n)
      (%vector-set! ob i (drop-symbols-of p (%vector-ref ob i)))
      (set! i (%+ i 1))))
  (%st-cap! lg-symlist (drop-symbols-of p (%ld-cap lg-symlist)))
  (%st-cap! lg-packages (remove-eq p (%ld-cap lg-packages)))
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
  (%ld-word lg-cons-free-n))

;; These take raw addresses or hand out raw memory.
(unsafe-names (quote (alloc-code register-code refill-cons-run scan-context drop-context-run)))
