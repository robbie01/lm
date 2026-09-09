;;; snap.lisp - writing the machine back out.
;;;
;;; The kickstart is an image, and this is the other half of that: a running
;;; system can write itself to the disk and be booted again later with
;;; everything it had learned still in it. Nothing is serialised - the regions
;;; go out as raw bytes and come back at the same addresses, which is only
;;; possible because nothing in this machine ever moves.
;;;
;;; The file starts with one block describing the regions, then the regions
;;; themselves, each rounded up to a whole number of blocks.

(in-package snap)

(define snap-magic 827542860)     ; "LMS1" as a little-endian word
(define snap-header-blocks 1)

(define (region-blocks len) (%lsh (%+ len 511) -9))

(define (save-image) (save-image-with (%symbol-value 'resume-kickstart)))

;; An image built by a rebuild starts from the beginning rather than resuming:
;; the boot list the rebuild recorded is exactly what it has to run.
(define (save-rebuilt)
  (%raw-st! lg-bootlist (reverse compiler:*boot-thunks*))
  (save-image-with (%symbol-value 'kickstart)))

(define (put-region hdr i base len start)
  (poke (%+ hdr (%+ 12 (%* i 12))) base)
  (poke (%+ hdr (%+ 16 (%* i 12))) len)
  (poke (%+ hdr (%+ 20 (%* i 12))) start)
  nil)

(define (save-image-with top)
  ;; Everything from the collection to the last block written is one critical
  ;; section, and nothing inside it allocates.
  ;;
  ;; Both halves of that matter. Outside a critical section, another task can
  ;; allocate an object out of a free block this is in the middle of blanking,
  ;; or collect and undo `gc-forget-scratch`, or mutate saved data to point at
  ;; a pair above the top being written. And allocating *inside* one is the
  ;; same problem by another door: a cons that happens to exhaust the current
  ;; run calls the collector, from within the stretch that was supposed to be
  ;; indivisible. So the header block is claimed first and the five regions are
  ;; written out by hand rather than through a list.
  (let ((hdr (alloc-pool 512))
        (saved-top (%raw-ld lg-toplevel))
        (written 0))
    (without-interrupts
      ;; Collect before saving, and blank what was reclaimed. Whatever the
      ;; machine has been doing since it booted is mostly garbage by now, and
      ;; there is no sense writing it to disk. Compacting first is what makes
      ;; an image small: afterwards the live pairs are one contiguous block at
      ;; the bottom of cons space, and everything above it has been blanked.
      (gc-for-image)
      ;; What is about to be written does not include the collector's scratch
      ;; memory, so the image must not come back believing it is set up.
      (gc-forget-scratch)
      ;; A resumed image re-enters through here rather than through the boot
      ;; list: every global it would have set is already set.
      (%raw-st! lg-toplevel top)
      ;; Five regions: low memory, the Exec pool, code, pairs, objects.
      (let* ((l0 4096)
             (l1 (%- (%global lg-poolptr) pool-base))
             (l2 (%- (%global lg-code-ptr) code-base))
             (l3 (%- (%global lg-cons-ptr) cons-base))
             (l4 (%- (%global lg-obj-ptr) obj-base))
             (k0 snap-header-blocks)
             (k1 (%+ k0 (region-blocks l0)))
             (k2 (%+ k1 (region-blocks l1)))
             (k3 (%+ k2 (region-blocks l2)))
             (k4 (%+ k3 (region-blocks l3))))
        (set! written (%+ k4 (region-blocks l4)))
        (poke hdr snap-magic)
        (poke (%+ hdr 4) (%global lg-imgentry))
        (poke (%+ hdr 8) 5)
        (put-region hdr 0 0 l0 k0)
        (put-region hdr 1 pool-base l1 k1)
        (put-region hdr 2 code-base l2 k2)
        (put-region hdr 3 cons-base l3 k3)
        (put-region hdr 4 obj-base l4 k4)
        (disk-write 0 k0 (region-blocks l0))
        (disk-write pool-base k1 (region-blocks l1))
        (disk-write code-base k2 (region-blocks l2))
        (disk-write cons-base k3 (region-blocks l3))
        (disk-write obj-base k4 (region-blocks l4))
        ;; The header goes out last, so a run that is interrupted leaves a file
        ;; that simply does not have a valid header rather than a wrong one.
        (disk-write hdr 0 1)
        (%raw-st! lg-toplevel saved-top)
        nil))
    (emit-str "saved ")
    (emit-str (number->string written))
    (emit-str " blocks
")
    written))

(define (resume-kickstart)
  ;; Everything the boot list would set up is already in the image. Exec is
  ;; rebuilt, because the task that saved is not the task that resumes.
  (%raw-st! lg-traphook (%symbol-value 'handle-trap))
  (exec-init)
  (exec-start)
  (set-current-package! (make-package "user"))
  (emit-str "\n")
  (emit-str system-name)
  (emit-str " resumed, ")
  (emit-str (number->string (%lsh (%- (%global lg-code-ptr) code-base) -10)))
  (emit-str "k of code\n")
  (repl)
  0)
