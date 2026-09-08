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

(define snap-magic 827542860)     ; "LMS1" as a little-endian word
(define snap-header-blocks 1)

(define (region-blocks len) (%lsh (%+ len 511) -9))

(define (save-image)
  ;; The allocator's current run lives in registers, so it has to be written
  ;; back to memory before the memory is what gets saved. Without this the
  ;; resumed machine would start handing out pairs it had already given away.
  (%sync-cons-run)
  ;; Collect before saving, and blank what was reclaimed. Whatever the machine
  ;; has been doing since it booted is mostly garbage by now, and there is no
  ;; sense writing it to disk.
  ;; Compacting first is what makes an image small: afterwards the live pairs
  ;; are one contiguous block at the bottom of cons space, and everything
  ;; above it has been blanked.
  (gc-for-image)
  (disable)
  (let* ((hdr (alloc-pool 512))
         (live-top (%global lg-cons-ptr))
         (saved-top (%raw-ld lg-toplevel))
         ;; Five regions: low memory, the Exec pool, code, pairs, objects.
         (regions (list (list 0 4096)
                        (list pool-base (%- (%global lg-poolptr) pool-base))
                        (list code-base (%- (%global lg-code-ptr) code-base))
                        (list cons-base (%- live-top cons-base))
                        (list obj-base (%- (%global lg-obj-ptr) obj-base))))
         (n (length regions))
         (blk snap-header-blocks)
         (i 0))
    ;; A resumed image re-enters through here rather than through the boot
    ;; list: every global it would have set is already set.
    (%raw-st! lg-toplevel (%symbol-value 'resume-kickstart))
    ;; The collection above already left the allocator pointing at the single
    ;; run above the live data, so there is nothing to arrange here.
    (poke hdr snap-magic)
    (poke (%+ hdr 4) (%global lg-imgentry))
    (poke (%+ hdr 8) n)
    (dolist (r regions)
      (poke (%+ hdr (%+ 12 (%* i 12))) (%car r))
      (poke (%+ hdr (%+ 16 (%* i 12))) (cadr r))
      (poke (%+ hdr (%+ 20 (%* i 12))) blk)
      (set! blk (%+ blk (region-blocks (cadr r))))
      (set! i (%+ i 1)))
    ;; The header goes out last, so a run that is interrupted leaves a file
    ;; that simply does not have a valid header rather than a wrong one.
    (set! blk snap-header-blocks)
    (dolist (r regions)
      (disk-write (%car r) blk (region-blocks (cadr r)))
      (set! blk (%+ blk (region-blocks (cadr r)))))
    (disk-write hdr 0 1)
    (%raw-st! lg-toplevel saved-top)
    (enable)
    (emit-str "saved ")
    (emit-str (number->string blk))
    (emit-str " blocks\n")
    blk))

(define (resume-kickstart)
  ;; Everything the boot list would set up is already in the image. Exec is
  ;; rebuilt, because the task that saved is not the task that resumes.
  (%raw-st! lg-traphook (%symbol-value 'handle-trap))
  (exec-init)
  (emit-str "\n")
  (emit-str system-name)
  (emit-str " resumed, ")
  (emit-str (number->string (%lsh (%- (%global lg-code-ptr) code-base) -10)))
  (emit-str "k of code\n")
  (repl)
  0)
