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

(defconstant snap-header-blocks 1)
(defconstant snap-regions 3)

;; The header is put together in the image writer's part of the collector's
;; scratch, which no allocator hands out, and each region's tag map after
;; it: a capability to it, from the kernel block's.
(define (snap-area)
  (declare unsafe)
  (unsafe (%cap-inc (kernel-ref kb-scratch) scratch-image)))

(define (region-blocks len) (%lsh (%+ len 511) -9))

;; The offset of word k of region i's entry in the header.
(defsubst (region-field i k) (%+ 12 (%+ (%lsh i 4) (%lsh k 2))))

;; Writing the image is the one place raw blocks go to the disk, and the
;; image writer is the site that says so.
(define (save-image) (unsafe (save-image-with resume-kickstart)))

(define (put-region hdr i base len)
  (%cap-st-word! hdr (region-field i 0) base)
  (%cap-st-word! hdr (region-field i 1) len)
  nil)

;; Region i of the image, as the capability the kernel block holds for it:
;; the low block, cons space and object space.
(define (snap-region i)
  (declare unsafe)
  (unsafe
  (cond ((%= i 0) (kernel-ref kb-low))
        ((%= i 1) (kernel-ref kb-cons))
        (else (kernel-ref kb-objects)))))

;; What the controller is handed to write n blocks from where `c` stands:
;; `c` narrowed to those blocks and to loading data.
(define (blocks c n)
  (%cap-and-perms (%cap-bounds c (%lsh n 9)) perm-ld))

;; The first thing that went wrong, or 0 if nothing has.
(define (first-bad bad status) (if (%= bad 0) status bad))

;; The tags of the granules of region `r` from `lo` up to `hi`, as a map
;; written through `at`, padded with zeroes to a whole block. Answers the
;; map's length in blocks.
(define (tag-map r lo hi at)
  (let ((q 0) (g (%cap-set-addr r lo)))
    (while (%< lo hi)
      (let ((byte 0) (bit 1) (e (%+ lo 64)))
        (while (%< lo e)
          (if (%< lo hi) (if (%cap-tag? (%cap-ld g 0)) (set! byte (%logior byte bit)) nil) nil)
          (set! bit (%lsh bit 1))
          (set! lo (%+ lo 8))
          (set! g (%cap-inc g 8)))
        (%cap-st-byte! at q byte)
        (set! q (%+ q 1))))
    (while (%> (%logand q 511) 0)
      (%cap-st-byte! at q 0)
      (set! q (%+ q 1)))
    (%lsh q -9)))

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
;; the first status that was not ok.
(define (save-image-with top)
  (declare unsafe)
  (unsafe
  (let* ((saved-top (kernel-ref kb-toplevel))
         (result
          (disk:exclusive
            (lambda ()
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
              (kernel-set! kb-toplevel top)
              (let ((r (write-regions)))
                (kernel-set! kb-toplevel saved-top)
                r)))))
    (report-save result))))

;; Three regions: the low block, pairs, objects, each from its base to as
;; far as its allocator has reached, each read through the kernel block's
;; capability to it and followed by its tag map, which is built in the
;; collector's scratch. The header goes out last, so that a run that is
;; interrupted leaves a file with no valid header rather than a wrong one.
;; Answers the blocks written, or minus the first status that was not ok.
;; Allocates nothing.
(define (write-regions)
  (declare unsafe)
  (unsafe
  (let* ((hdr (snap-area))
         (dev (device dev-disk))
         (maps (%cap-inc hdr 512))
         (i 0) (k snap-header-blocks) (bad 0))
    (put-region hdr 0 0 low-end)
    (put-region hdr 1 cons-base (%- (kernel-ref kb-cons-ptr) cons-base))
    (put-region hdr 2 obj-base (%- (kernel-ref kb-obj-ptr) obj-base))
    (while (%< i snap-regions)
      (let* ((base (%cap-ld-word hdr (region-field i 0)))
             (len (%cap-ld-word hdr (region-field i 1)))
             (r (snap-region i))
             (n (region-blocks len))
             (m (tag-map r base (%+ base len) maps)))
        (%cap-st-word! hdr (region-field i 2) k)
        (%cap-st-word! hdr (region-field i 3) (%+ k n))
        (set! bad (first-bad bad (disk:write-raw dev (blocks (%cap-set-addr r base) n) k n)))
        (set! bad (first-bad bad (disk:write-raw dev (blocks maps m) (%+ k n) m)))
        (set! k (%+ k (%+ n m))))
      (set! i (%+ i 1)))
    (%cap-st-word! hdr 0 snap-magic)
    (%cap-st-word! hdr 4 reset-vector)
    (%cap-st-word! hdr 8 snap-regions)
    (set! bad (first-bad bad (disk:write-raw dev (blocks hdr 1) 0 1)))
    (if (%= bad 0) k (%- 0 bad)))))

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
;; the drivers start again in `exec-init`. The tasks that were saved never
;; run again: the new Exec's lists do not hold them, and the collector
;; takes them back with their stacks. An image on the disk may have had its
;; object space slid down by the forge, so it counts a move before anything
;; can look in a table.
(define (resume-kickstart)
  (declare unsafe)
  (unsafe
  (note-move!)
  (kernel-set! kb-trap-hook (%symbol-value 'handle-trap))
  (set! *error-handler* (%symbol-value 'error-trap))
  (exec-init)
  (exec-start)
  (if *resume-fn* (%funcall *resume-fn*) nil)
  (set-current-package! (make-package "user"))
  (emit-str "\n")
  (emit-str system-name)
  (emit-str " resumed, ")
  (emit-str (number->string (%lsh (object-bytes-used) -10)))
  (emit-str "k of objects\n")
  ;; The machine's own prompt, as at a cold boot: when it says goodbye, so
  ;; does the machine, whether or not an error has restarted it since.
  (repl (lambda () (%halt exit-ok)))
  (%halt exit-ok)
  0))

;; ---------------------------------------------------------------- fresh
;; The end of a fresh rebuild. `genesis` has left in `*fresh-image*` what the
;; image is to hold, the names its sources use, and its boot list. What is
;; still to do is to make the machine hold exactly that and nothing else,
;; collect, and write it out, and none of it can be done from here:
;; everything here, this function and the prompt that called it and the task
;; it runs in, is the machine doing the building.
;;
;; So this hands over. The image's own `finish-fresh` becomes the top level,
;; what genesis left goes in the one root it looks in, and the processor is
;; reset with memory as it is: it starts again at the reset vector with the
;; root in PCC, and the reset stub mints the memory map again and enters the
;; top level on a clean stack, with no task, an empty cons run, and nothing
;; running but the image's own code.
(define (save-fresh)
  (declare unsafe)
  (unsafe
  (let* ((fresh *fresh-image*)
         (e (if fresh (table-ref (%car fresh) 'finish-fresh nil) nil)))
    (if e nil (error "save-fresh: run sys:genesis first"))
    (kernel-set! kb-roots fresh)
    (kernel-set! kb-toplevel (%vector-ref e 0))
    (%disable)
    (%set-this-task! nil)
    (reset-processor))))

;; Where the reset lands. The symbols still hold the builder's definitions,
;; so the handover itself happens in `fresh-become`, which is the builder's,
;; while the builder's code still answers; from then on every call is to the
;; image. This stack holds nothing but a number, and nothing is underneath
;; it, so the collection's roots are the image's own globals and what
;; survives is exactly the image.
(define (finish-fresh)
  (declare unsafe)
  (unsafe
  (fresh-become)
  (forget-unused-packages)
  (kernel-set! kb-package (find-package "user"))
  (collect-for-image)
  (let ((r (write-regions)))
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
          (%halt exit-ok))))))

(define (fresh-become)
  (declare unsafe)
  (unsafe
  (let* ((fresh (kernel-ref kb-roots))
         (image (%car fresh))
         (seen (cadr fresh))
         (thunks (caddr fresh))
         (all (all-symbols))
         ;; What the image gives each symbol, as a plain list: once the cells
         ;; start changing, nothing that reads a global can be trusted. A
         ;; table's empty slots are marked by a value held in a global, and
         ;; the image's marker is not this machine's.
         (entries (table->alist image))
         (unbound (%unbound)))
    (kernel-set! kb-roots nil)
    (keep-image-symbols image seen)
    ;; No trap may come while the cells change, and a collection still
    ;; marking would bring one with the first store over an unmarked pointer:
    ;; the barrier's handler is reached through those very cells. So the
    ;; cycle is finished here, after the last allocation, and none can start
    ;; again before the allocator is the image's.
    (if (busy?) (collect) nil)
    (become-image all entries unbound)
    ;; The image's own top level, trap hook and boot list, as the forge sets
    ;; them for an image it builds.
    (kernel-set! kb-toplevel (%symbol-value 'kickstart))
    (kernel-set! kb-trap-hook (%symbol-value 'handle-trap))
    (kernel-set! kb-task-exit nil)
    (%set-symbol-value! '*boot-list* thunks)
    ;; And its allocator, which the kickstart would install first thing:
    ;; nothing since the symbols changed has allocated, and from here on
    ;; anything may.
    (install-allocator)
    nil)))

;; The image's symbols: the ones its sources use, any it gives something to,
;; and each package's tag. A new obarray and a new symbol list, made with the
;; builder's allocator while that still answers; everything else goes when
;; the collector runs.
(define (keep-image-symbols image seen)
  (declare unsafe)
  (unsafe
  (dolist (p (all-packages)) (table-set! seen (%slot p pkg-tag) t))
  (let* ((n (%vector-length (kernel-ref kb-obarray)))
         (ob (make-vector n nil))
         (kept nil)
         (l (all-symbols)))
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
    (kernel-set! kb-obarray ob)
    (kernel-set! kb-symbols (reverse kept)))))

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
  (declare unsafe)
  (unsafe
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
      (set! l (%cdr l))))))
