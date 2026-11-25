;;; snap.lisp - writing the machine back out.
;;;
;;; A running system can write itself to the disk and be booted again later
;;; with everything it had learned still in it. Nothing is serialised: the
;;; regions go out as raw bytes and come back at the same addresses, which
;;; works because nothing in this machine moves between a save and a resume.
;;;
;;; The bytes are not the whole of memory: every granule's tag is kept out of
;;; band, and a transfer to the disk carries none of them. So each region goes
;;; out with a map of its tags, one bit per eight bytes, from which the loader
;;; makes every pointer a pointer again.
;;;
;;; The file starts with one block describing the regions:
;;;
;;;   word 0          the magic, "LMS2", `snap-magic` in the layout
;;;   word 1          the entry address
;;;   word 2          the number of regions
;;;   12 + 16i        region i: its base, its length in bytes, the first block
;;;                   of its bytes, the first block of its tag map
;;;
;;; then each region's bytes and its tag map, each rounded up to a whole
;;; number of blocks. Bit j of byte k of a tag map is the tag of the granule
;;; at base + 8(8k + j).

(in-package snap)
(unsafe-file)

(defconstant snap-header-blocks 1)
(defconstant snap-regions 4)

;; The header is put together in the collector's scratch memory, which no
;; allocator hands out, and each region's tag map after it.
(defconstant snap-header gc-scratch)
(defconstant snap-tag-map (%+ gc-scratch 512))

(define (region-blocks len) (%lsh (%+ len 511) -9))

;; Word k of region i's entry in the header.
(defsubst (region-field hdr i k) (%+ hdr (%+ 12 (%+ (%lsh i 4) (%lsh k 2)))))

(define (save-image) (save-image-with (%symbol-value 'resume-kickstart)))

(define (put-region hdr i base len)
  (poke (region-field hdr i 0) base)
  (poke (region-field hdr i 1) len)
  nil)

;; What the controller is handed to write n blocks from `base`: the root
;; narrowed to those blocks and to loading data.
(define (blocks-at base n)
  (%cap-and-perms (%cap-bounds (%from-addr base) (%lsh n 9)) perm-ld))

;; The first thing that went wrong, or 0 if nothing has.
(define (first-bad bad status) (if (%= bad 0) status bad))

;; The tags of the granules from `lo` up to `hi`, as a map at `at`, padded
;; with zeroes to a whole block. Answers the map's length in blocks.
(define (tag-map lo hi at)
  (let ((q at))
    (while (%< lo hi)
      (let ((byte 0) (bit 1) (e (%+ lo 64)))
        (while (%< lo e)
          (if (%< lo hi) (if (%cap-tag? (%ld-cap lo)) (set! byte (%logior byte bit)) nil) nil)
          (set! bit (%lsh bit 1))
          (set! lo (%+ lo 8)))
        (%st-byte! q byte)
        (set! q (%+ q 1))))
    (while (%> (%logand (%- q at) 511) 0)
      (%st-byte! q 0)
      (set! q (%+ q 1)))
    (%lsh (%- q at) -9)))

;; Everything from the collection to the last block written is one critical
;; section, and nothing inside it allocates: another task could otherwise
;; allocate out of a free block this is blanking, and an allocation inside
;; the section could call the collector. So the regions are written out by
;; hand, from scratch memory.
;;
;; The section runs in the disk driver's task, so that no transfer of the
;; driver's is in flight under it, and a transfer inside a section with
;; interrupts off can only be watched. `disk:exclusive` runs the job there,
;; and this task sleeps until it answers with the blocks written, or minus
;; the first status that was not ok. The job writes through a page of the
;; controller's of its own, made from the root.
(define (save-image-with top)
  (let* ((saved-top (%ld-cap lg-toplevel))
         (result
          (disk:exclusive
            (lambda ()
              ;; Every task there is, for the resumed image to give back
              ;; their stacks: none can start or end until this returns.
              (set! *saved-tasks* (task-snapshot))
              ;; Collect first and blank what was reclaimed: afterwards the
              ;; live pairs are one block at the bottom of cons space and
              ;; everything above it is zero, which is what makes an image
              ;; small.
              (collect-for-image)
              ;; And nothing in flight on the blitter. A descriptor saved
              ;; with its status at pending would come back to a chip that
              ;; was reset and will never write it back.
              (blit-drain)
              ;; A resumed image re-enters through `top` rather than through
              ;; the boot list: every global it would have set is already set.
              (%st-cap! lg-toplevel top)
              (let ((r (write-regions (device-page dev-disk))))
                (%st-cap! lg-toplevel saved-top)
                (set! *saved-tasks* nil)
                r)))))
    (report-save result)))

;; The tasks of the machine that saved, in the image it wrote, and nil
;; anywhere else.
(define *saved-tasks* nil)

;; Four regions: low memory, the pool, pairs, objects, each from its base to
;; as far as its allocator has reached, each followed by its tag map,
;; which is built in the collector's scratch memory. The header goes out
;; last, so that a run that is interrupted leaves a file with no valid header
;; rather than a wrong one. Answers the blocks written, or minus the first
;; status that was not ok. Allocates nothing, and writes through `page`, the
;; controller's.
(define (write-regions page)
  (put-region snap-header 0 0 low-end)
  (put-region snap-header 1 pool-base (%- (%ld-word lg-poolptr) pool-base))
  (put-region snap-header 2 cons-base (%- (%ld-word lg-cons-ptr) cons-base))
  (put-region snap-header 3 obj-base (%- (%ld-word lg-obj-ptr) obj-base))
  (let ((i 0) (k snap-header-blocks) (bad 0))
    (while (%< i snap-regions)
      (let* ((base (peek (region-field snap-header i 0)))
             (len (peek (region-field snap-header i 1)))
             (n (region-blocks len))
             (m (tag-map base (%+ base len) snap-tag-map)))
        (poke (region-field snap-header i 2) k)
        (poke (region-field snap-header i 3) (%+ k n))
        (set! bad (first-bad bad (disk:write-raw page (blocks-at base n) k n)))
        (set! bad (first-bad bad (disk:write-raw page (blocks-at snap-tag-map m) (%+ k n) m)))
        (set! k (%+ k (%+ n m))))
      (set! i (%+ i 1)))
    (poke snap-header snap-magic)
    (poke (%+ snap-header 4) reset-vector)
    (poke (%+ snap-header 8) snap-regions)
    (set! bad (first-bad bad (disk:write-raw page (blocks-at snap-header 1) 0 1)))
    (if (%= bad 0) k (%- 0 bad))))

(define (report-save result)
  (if (%< result 0)
      (error "save-image: the disk answered" (%- 0 result)
             (if (%= result -1) "- no disk attached; start with --disk FILE" ""))
      (begin
        (emit-str "saved ")
        (emit-str (number->string result))
        (emit-str " blocks\n")
        result)))

;; Everything the boot list would set up is already in the image. Exec is
;; rebuilt, because the task that saved is not the task that resumes, and
;; the drivers start again in `exec-init`, each taking its page afresh. The
;; tasks that were saved never run again, so their stacks and contexts go
;; back to the pool first.
(define (resume-kickstart)
  (%st-cap! lg-traphook (%symbol-value 'handle-trap))
  (%st-cap! lg-errhandler (%symbol-value 'error-trap))
  (reap-saved-tasks *saved-tasks*)
  (set! *saved-tasks* nil)
  (exec-init)
  (exec-start)
  (if *resume-fn* (%funcall *resume-fn*) nil)
  (set-current-package! (make-package "user"))
  (emit-str "\n")
  (emit-str system-name)
  (emit-str " resumed, ")
  (emit-str (number->string (%lsh (object-bytes-used) -10)))
  (emit-str "k of objects\n")
  (repl)
  0)

;; ---------------------------------------------------------------- fresh
;; The end of a fresh rebuild. `genesis` has left in `*fresh-image*` what the
;; image is to hold, the names its sources use, and its boot list. What is
;; still to do is to make the machine hold exactly that and nothing else,
;; collect, and write it out, and none of it can be done from here:
;; everything here, this function and the prompt that called it and the task
;; it runs in, is the machine doing the building.
;;
;; So this hands over. The image's own `finish-fresh` becomes the top level,
;; what genesis left goes in the one root it looks in, and the machine
;; restarts through its reset stub with memory as it is: a clean stack, no
;; task, an empty cons run, and nothing running but the image's own code.
(define (save-fresh)
  (let* ((fresh *fresh-image*)
         (e (if fresh (table-ref (%car fresh) 'finish-fresh nil) nil)))
    (if e nil (error "save-fresh: run sys:genesis first"))
    (%st-cap! lg-roots fresh)
    (%st-cap! lg-toplevel (%vector-ref e 0))
    (%disable)
    (%set-this-task! nil)
    ;; A closure whose entry is the reset stub, with the root's authority,
    ;; which the stub needs: the one way into it from compiled code, which
    ;; only ever jumps through a closure.
    (let ((c (alloc-object t-closure clo-free)))
      (%set-slot! c clo-entry (%cap-set-addr (%root) reset-vector))
      (%funcall (%cap-seal-closure c)))))

;; Where the reset lands. The symbols still hold the builder's definitions,
;; so the handover itself happens in `fresh-become`, which is the builder's,
;; while the builder's code still answers; from then on every call is to the
;; image. This stack holds nothing but a number, and nothing is underneath
;; it, so the collection's roots are the image's own globals and what
;; survives is exactly the image.
(define (finish-fresh)
  (fresh-become)
  (forget-unused-packages)
  (%st-cap! lg-package (find-package "user"))
  (collect-for-image)
  (let ((r (write-regions (device-page dev-disk))))
    (if (%< r 0)
        (begin
          (uart-string "fresh image: the disk answered ")
          (uart-num (%- 0 r))
          (uart-nl)
          (%halt exit-error))
        (begin
          (uart-string "fresh image: ")
          (uart-num r)
          (uart-string " blocks")
          (uart-nl)
          (%halt exit-ok)))))

(define (fresh-become)
  (let* ((fresh (%ld-cap lg-roots))
         (image (%car fresh))
         (seen (cadr fresh))
         (thunks (caddr fresh))
         (all (%ld-cap lg-symlist))
         ;; What the image gives each symbol, as a plain list: once the cells
         ;; start changing, nothing that reads a global can be trusted. A
         ;; table's empty slots are marked by a value held in a global, and
         ;; the image's marker is not this machine's.
         (entries (table->alist image))
         (unbound (%unbound)))
    (%st-cap! lg-roots nil)
    (keep-image-symbols image seen)
    ;; No trap may come while the cells change, and a collection still
    ;; marking would bring one with the first store over an unmarked pointer:
    ;; the barrier's handler is reached through those very cells. So the
    ;; cycle is finished here, after the last allocation, and none can start
    ;; again before the allocator is the image's.
    (if (busy?) (collect) nil)
    (become-image all entries unbound)
    ;; The image's own globals, as the forge sets them for an image it builds.
    (%st-cap! lg-toplevel (%symbol-value 'kickstart))
    (%st-cap! lg-traphook (%symbol-value 'handle-trap))
    (%st-cap! lg-bootlist thunks)
    (%st-cap! lg-errhandler nil)
    (%st-cap! lg-startup nil)
    (%st-cap! lg-task-exit nil)
    ;; And its allocator, which the kickstart would install first thing:
    ;; nothing since the symbols changed has allocated, and from here on
    ;; anything may.
    (install-allocator)
    ;; The pool as the forge lays it out, its scratch, the stacks and the
    ;; trap frames, which end with the boot context, and not what this
    ;; machine carved from it since.
    (%st-word! lg-poolptr (%+ (%ld-word lg-trapsave) ctx-bytes))
    (%st-word! lg-pool-free 0)
    nil))

;; The image's symbols: the ones its sources use, any it gives something to,
;; and each package's tag. A new obarray and a new symbol list, made with the
;; builder's allocator while that still answers; everything else goes when
;; the collector runs.
(define (keep-image-symbols image seen)
  (dolist (p (all-packages)) (table-set! seen (%slot p pkg-tag) t))
  (let* ((n (%vector-length (%ld-cap lg-obarray)))
         (ob (make-vector n nil))
         (kept nil)
         (l (%ld-cap lg-symlist)))
    (while (%cons? l)
      (let ((s (%car l)))
        (if (if (%slot s sym-package) (if (table-has? seen s) t (table-has? image s)) nil)
            (let ((b (%mod (qualified-hash (package-name (%slot s sym-package))
                                           (%symbol-name s))
                           n)))
              (%vector-set! ob b (%cons s (%vector-ref ob b)))
              (set! kept (%cons s kept)))
            nil))
      (set! l (%cdr l)))
    (%st-cap! lg-obarray ob)
    (%st-cap! lg-symlist (reverse kept))))

;; Every symbol is emptied, and then takes what the image gives it: its
;; value, a function only if that is a macro's expander, and the flags that
;; say it is a macro or a constant. The compiler's
;; notes on the rest, every property list and every export are made again by
;; the boot list.
;;
;; This runs while the cells it would reach anything through are changing
;; underneath it, so it reaches nothing: everything it needs arrives as an
;; argument, and everything it does is open coded. It allocates nothing.
(define (become-image all entries unbound)
  (let ((l all))
    (while (%cons? l)
      (let ((s (%car l)))
        (%set-symbol-value! s unbound)
        (%set-symbol-function! s nil)
        (%set-symbol-plist! s nil)
        (%set-symbol-flags! s (%logand (%symbol-flags s) -256)))
      (set! l (%cdr l))))
  (let ((l entries))
    (while (%cons? l)
      (let ((s (%car (%car l)))
            (e (%cdr (%car l))))
        (%set-symbol-value! s (%vector-ref e 0))
        (%set-symbol-function! s (%vector-ref e 1))
        (%set-symbol-flags! s (%logior (%symbol-flags s) (%vector-ref e 2))))
      (set! l (%cdr l)))))
