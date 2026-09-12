;;; snap.lisp - writing the machine back out.
;;;
;;; A running system can write itself to the disk and be booted again later
;;; with everything it had learned still in it. Nothing is serialised: the
;;; regions go out as raw bytes and come back at the same addresses, which
;;; works because nothing in this machine moves between a save and a resume.
;;;
;;; The file starts with one block describing the regions, then the regions
;;; themselves, each rounded up to a whole number of blocks.

(in-package snap)

(define snap-magic 827542860)     ; "LMS1" as a little-endian word
(define snap-header-blocks 1)

(define (region-blocks len) (%lsh (%+ len 511) -9))

(define (save-image) (save-image-with (%symbol-value 'resume-kickstart)))

(define (put-region hdr i base len start)
  (poke (%+ hdr (%+ 12 (%* i 12))) base)
  (poke (%+ hdr (%+ 16 (%* i 12))) len)
  (poke (%+ hdr (%+ 20 (%* i 12))) start)
  nil)

;; The first thing that went wrong, or 0 if nothing has.
(define (first-bad bad status) (if (%= bad 0) status bad))

;; Everything from the collection to the last block written is one critical
;; section, and nothing inside it allocates: another task could otherwise
;; allocate out of a free block this is blanking, and an allocation inside
;; the section could call the collector. So the header block is claimed
;; first and the five regions are written out by hand.
;;
;; The section runs in the disk driver's task: a transfer inside a section
;; with interrupts off can only be watched, and only the task holding the
;; controller may do that. `disk-exclusive` runs the job there, and this
;; task sleeps until it answers with the blocks written, or minus the first
;; status that was not ok.
(define (save-image-with top)
  (let* ((hdr (alloc-pool 512))
         (saved-top (%ld-word lg-toplevel))
         (result
          (disk-exclusive
            (lambda ()
              ;; Collect first and blank what was reclaimed: afterwards the
              ;; live pairs are one block at the bottom of cons space and
              ;; everything above it is zero, which is what makes an image
              ;; small.
              (gc-for-image)
              ;; And nothing in flight on the blitter. A descriptor saved
              ;; with its status at pending would come back to a chip that
              ;; was reset and will never write it back.
              (blit-drain)
              ;; A resumed image re-enters through `top` rather than through
              ;; the boot list: every global it would have set is already set.
              (%st-word! lg-toplevel top)
              (let ((r (write-regions hdr)))
                (%st-word! lg-toplevel saved-top)
                r)))))
    (report-save result)))

;; Five regions: low memory, the pool, code, pairs, objects, each from its
;; base to as far as its allocator has reached. The header goes out last, so
;; that a run that is interrupted leaves a file with no valid header rather
;; than a wrong one. Answers the blocks written, or minus the first status
;; that was not ok. Allocates nothing.
(define (write-regions hdr)
  (let* ((l0 4096)
         (l1 (%- (%ld-fixnum lg-poolptr) pool-base))
         (l2 (%- (%ld-fixnum lg-code-ptr) code-base))
         (l3 (%- (%ld-fixnum lg-cons-ptr) cons-base))
         (l4 (%- (%ld-fixnum lg-obj-ptr) obj-base))
         (k0 snap-header-blocks)
         (k1 (%+ k0 (region-blocks l0)))
         (k2 (%+ k1 (region-blocks l1)))
         (k3 (%+ k2 (region-blocks l2)))
         (k4 (%+ k3 (region-blocks l3)))
         (bad 0))
    (poke hdr snap-magic)
    (poke (%+ hdr 4) (%ld-fixnum lg-imgentry))
    (poke (%+ hdr 8) 5)
    (put-region hdr 0 0 l0 k0)
    (put-region hdr 1 pool-base l1 k1)
    (put-region hdr 2 code-base l2 k2)
    (put-region hdr 3 cons-base l3 k3)
    (put-region hdr 4 obj-base l4 k4)
    (set! bad (first-bad bad (disk-write-raw 0 k0 (region-blocks l0))))
    (set! bad (first-bad bad (disk-write-raw pool-base k1 (region-blocks l1))))
    (set! bad (first-bad bad (disk-write-raw code-base k2 (region-blocks l2))))
    (set! bad (first-bad bad (disk-write-raw cons-base k3 (region-blocks l3))))
    (set! bad (first-bad bad (disk-write-raw obj-base k4 (region-blocks l4))))
    (set! bad (first-bad bad (disk-write-raw hdr 0 1)))
    (if (%= bad 0) (%+ k4 (region-blocks l4)) (%- 0 bad))))

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
;; every device claim is stale: the drivers start again in `exec-init` and
;; claim theirs afresh.
(define (resume-kickstart)
  (%st-word! lg-traphook (%symbol-value 'handle-trap))
  (%st-word! lg-errhandler (%symbol-value 'error-trap))
  (release-all-devices)
  (exec-init)
  (exec-start)
  (if *resume-fn* (%funcall *resume-fn*) nil)
  (set-current-package! (make-package "user"))
  (emit-str "\n")
  (emit-str system-name)
  (emit-str " resumed, ")
  (emit-str (number->string (%lsh (%- (%ld-fixnum lg-code-ptr) code-base) -10)))
  (emit-str "k of code\n")
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
;; task, and nothing running but the image's own code.
(define (save-fresh)
  (let* ((fresh *fresh-image*)
         (e (if fresh (table-ref (%car fresh) 'finish-fresh nil) nil)))
    (if e nil (error "save-fresh: run sys:genesis first"))
    (%st-word! lg-roots fresh)
    (%st-word! lg-toplevel (%vector-ref e 0))
    (%disable)
    (%set-this-task! nil)
    ;; The reset stub starts bumping pairs from what these two words say.
    (%sync-cons-run)
    ;; A closure whose entry is the reset stub: the one way into it from
    ;; compiled code, which only ever jumps through a closure.
    (let ((c (alloc-object t-closure 2)))
      (%st-fixnum! (%addr-of c) (%ld-fixnum lg-imgentry))
      (%funcall c))))

;; Where the reset lands. The symbols still hold the builder's definitions,
;; so the handover itself happens in `fresh-become`, which is the builder's,
;; while the builder's code still answers; from then on every call is to the
;; image. This stack holds nothing but a number, and nothing is underneath
;; it, so the collection's roots are the image's own globals and what
;; survives is exactly the image.
(define (finish-fresh)
  (let ((hdr (fresh-become)))
    (forget-unused-packages)
    (%st-word! lg-package (find-package "user"))
    (gc-for-image)
    (let ((r (write-regions hdr)))
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

;; Answers the address of a block to write the file's header from.
(define (fresh-become)
  (let* ((fresh (%ld-word lg-roots))
         (image (%car fresh))
         (seen (cadr fresh))
         (thunks (caddr fresh))
         (all (%ld-word lg-symlist))
         ;; What the image gives each symbol, as a plain list: once the cells
         ;; start changing, nothing that reads a global can be trusted. A
         ;; table's empty slots are marked by a value held in a global, and
         ;; the image's marker is not this machine's.
         (entries (table->alist image))
         (unbound *unbound*)
         (macro-bit sym-macro)
         ;; Claimed now, above where the pool is about to end: in memory for
         ;; the write, and not in the file.
         (hdr (alloc-pool 512)))
    (%st-word! lg-roots nil)
    (keep-image-symbols image seen)
    (become-image all entries unbound macro-bit)
    ;; The image's own globals, as the forge sets them for an image it builds.
    (%st-word! lg-toplevel (%symbol-value 'kickstart))
    (%st-word! lg-refill (%symbol-value 'refill-cons))
    (%st-word! lg-traphook (%symbol-value 'handle-trap))
    (%st-word! lg-bootlist thunks)
    (%st-word! lg-errhandler nil)
    (%st-word! lg-startup nil)
    (%st-word! lg-scratch0 nil)
    ;; And its allocator, which the kickstart would install first thing:
    ;; nothing since the symbols changed has allocated, and from here on
    ;; anything may.
    (install-allocator)
    ;; The pool as the forge lays it out, its scratch, the stacks and the
    ;; code registry, and not what this machine carved from it since.
    (let ((reg-block (%- (%ld-fixnum lg-code-reg) 8)))
      (%st-fixnum! lg-poolptr (%+ reg-block (%ld-fixnum reg-block)))
      (%st-fixnum! lg-pool-free 0))
    hdr))

;; The image's symbols: the ones its sources use, any it gives something to,
;; and each package's tag. A new obarray and a new symbol list, made with the
;; builder's allocator while that still answers; everything else goes when
;; the collector runs.
(define (keep-image-symbols image seen)
  (dolist (p (all-packages)) (table-set! seen (%slot p pkg-tag) t))
  (let* ((n (%vector-length (%ld-word lg-obarray)))
         (ob (make-vector n nil))
         (kept nil)
         (l (%ld-word lg-symlist)))
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
    (%st-word! lg-obarray ob)
    (%st-word! lg-symlist (reverse kept))))

;; Every symbol is emptied, and then takes what the image gives it: its
;; value, and a function only if that is a macro's expander. The compiler's
;; notes on the rest, every property list and every export are made again by
;; the boot list.
;;
;; This runs while the cells it would reach anything through are changing
;; underneath it, so it reaches nothing: everything it needs arrives as an
;; argument, and everything it does is open coded. It allocates nothing.
(define (become-image all entries unbound macro-bit)
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
        (if (%vector-ref e 2)
            (%set-symbol-flags! s (%logior (%symbol-flags s) macro-bit))
            nil))
      (set! l (%cdr l)))))
