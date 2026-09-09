;;; boot.lisp - the handful of things that have to be assembly.
;;;
;;; Run by the forge, not compiled into the image: this file *emits* the code
;;; that ends up in the image. Three stubs live here, and they exist because
;;; each one has to do something before or after any Lisp function could be
;;; running - set up the stack, save every register, or return through mret.
;;;
;;; The register save area they use is the same shape Exec will use for a task
;;; context, on purpose. Taking a trap and switching tasks are the same
;;; operation seen from two directions.

;; Declared here rather than in packages.lisp: this file is read by the forge
;; and never compiled into an image, so the machine has no use for the
;; namespace and should not be carrying it.
(defpackage boot use lm gc hw asm compiler sys exec)
(in-package boot)
(export '(build-boot-code reserve-reset))

;; ---------------------------------------------------------------- context
;; 32 words: word 0 is the pc, words 1..31 are x1..x31.
(define ctx-words 32)
(define ctx-bytes 128)
(define (ctx-off n) (%* 4 n))

(define trap-save 0)      ; filled in below, in the Exec pool
(define trap-stack 0)
(define boot-stack 0)

(define (boot-alloc-pool n) (%alloc-pool n))

;; ---------------------------------------------------------------- reset
;; The first thing assembled, so that it lands at the base of code space,
;; which is where the processor starts fetching.
(define (emit-reset-stub toplevel-global)
  (let ((a (asm-new)))
    ;; A stack to stand on.
    (i-li a $sp (%+ boot-stack boot-stack-size))
    (i-sw-abs a $sp lg-stacktop $t0)
    (i-li a $t0 boot-stack)
    (i-sw-abs a $t0 lg-stackbot $t1)
    ;; The current cons run, which the inline allocator bumps through.
    (i-lw a $gp $zero lg-cons-run)
    (i-lw a $tp $zero lg-cons-run-end)
    ;; Somewhere for traps to go, and somewhere for them to save registers.
    (i-li a $t0 trap-save)
    (i-csrrw a $zero csr-mscratch $t0)
    (i-li a $t0 (asm-origin *trap-asm*))
    (i-csrrw a $zero csr-mtvec $t0)
    ;; Enter Lisp. s0 is zeroed first: it is the frame link, and a zero there
    ;; is what tells the collector it has reached the bottom of the stack.
    (i-mv a $s0 $zero)
    (i-lw a $t0 $zero lg-toplevel)
    (i-li a $t1 0)
    (i-lw a $t2 $t0 0)
    (i-call-reg a $t2)
    ;; If it ever comes back, stop the machine with whatever it returned.
    (i-srai a $t0 $a0 1)
    (i-li a $t1 mmio-base)
    (i-sw a $t0 $t1 0)
    (asm-label a 'spin)
    (i-j a 'spin)
    (asm-place-at a *reset-addr*)
    a))

;; ---------------------------------------------------------------- allocator
;; Called from the four-instruction inline cons when the current run is used
;; up. Every caller-saved register is pushed before the collector can run, so
;; the conservative stack scan sees everything that is live - that spill is not
;; housekeeping, it is how the collector finds its roots.
(define arg-regs (list $a0 $a1 $a2 $a3 $a4 $a5 $a6 $a7))
(define raw-regs (list $ra $t0 $t1 $t2 $t3 $t4 $t6))

(define (emit-cons-refill)
  ;; The frame this builds is laid out to match what gc.lisp expects: the live
  ;; mask first, then the eight argument registers, then the return address
  ;; and the temporaries. The walker steps over the second half and takes only
  ;; the masked part of the first, which is what keeps the collector precise
  ;; across an allocation.
  (let* ((a (asm-new))
         (i 0))
    (i-addi a $sp $sp (%- 0 stub-frame-size))
    (i-sw a $t5 $sp stub-mask-off)      ; the live-register mask
    (set! i 0)
    (dolist (r arg-regs)
      (i-sw a r $sp (%+ stub-args-off (%* 4 i)))
      (set! i (%+ i 1)))
    (set! i 0)
    (dolist (r raw-regs)
      (i-sw a r $sp (%+ stub-raw-off (%* 4 i)))
      (set! i (%+ i 1)))
    ;; refill-cons takes a run off the free list, collecting first if it has to.
    (i-lw a $t0 $zero lg-refill)
    (i-li a $t1 0)
    (i-lw a $t2 $t0 0)
    (i-call-reg a $t2)
    ;; Pick up whatever run it decided on.
    (i-lw a $gp $zero lg-cons-run)
    (i-lw a $tp $zero lg-cons-run-end)
    (set! i 0)
    (dolist (r arg-regs)
      (i-lw a r $sp (%+ stub-args-off (%* 4 i)))
      (set! i (%+ i 1)))
    (set! i 0)
    (dolist (r raw-regs)
      (i-lw a r $sp (%+ stub-raw-off (%* 4 i)))
      (set! i (%+ i 1)))
    (i-lw a $t5 $sp stub-mask-off)
    (i-addi a $sp $sp stub-frame-size)
    (i-ret a)
    (asm-place a)
    (%set-global! lg-stub-lo (asm-origin a))
    (%set-global! lg-stub-hi (%+ (asm-origin a) (asm-len a)))
    a))

;; ---------------------------------------------------------------- traps
;; Saves the complete machine state, calls a Lisp handler on a private stack,
;; then puts the state back and returns through mret. Because the whole
;; context is in one contiguous block, the scheduler can switch tasks simply
;; by pointing mscratch at a different one.
(define (emit-trap-stub)
  (let ((a (asm-new)))
    ;; mscratch holds the save area. Swap it into t0 so there is a register to
    ;; work with without having destroyed anything yet.
    (i-csrrw a $t0 csr-mscratch $t0)
    (let ((r 1))
      (while (%< r 32)
        (if (%= r 5) nil (i-sw a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    ;; Recover the original t0 from mscratch, and put the save area back.
    (i-csrrw a $ra csr-mscratch $t0)
    (i-sw a $ra $t0 (ctx-off 5))
    (i-csrrs a $ra csr-mepc $zero)
    (i-sw a $ra $t0 (ctx-off 0))

    ;; A stack of its own, so a fault caused by a broken stack pointer can
    ;; still be reported.
    (i-li a $sp (%+ trap-stack trap-stack-size))
    ;; mcause has the interrupt flag in bit 31, and a fixnum has no bit 31 to
    ;; put it in: tagging the register directly would shift the flag off the
    ;; end and make every interrupt look like a store fault. So the flag is
    ;; moved down to bit 6 and the cause number kept in the low five, which
    ;; leaves a small non-negative number that survives tagging intact.
    (i-csrrs a $t2 csr-mcause $zero)
    (i-srli a $t3 $t2 25)
    (i-andi a $t3 $t3 64)
    (i-andi a $a0 $t2 31)
    (i-or a $a0 $a0 $t3)
    (i-slli a $a0 $a0 1)
    (i-ori a $a0 $a0 1)
    ;; The two addresses are narrowed to thirty bits so they stay fixnums;
    ;; they are only ever used to say where something went wrong.
    (i-csrrs a $a1 csr-mepc $zero)
    (i-slli a $a1 $a1 2)
    (i-srli a $a1 $a1 2)
    (i-slli a $a1 $a1 1)
    (i-ori a $a1 $a1 1)
    (i-csrrs a $a2 csr-mtval $zero)
    (i-slli a $a2 $a2 2)
    (i-srli a $a2 $a2 2)
    (i-slli a $a2 $a2 1)
    (i-ori a $a2 $a2 1)
    ;; The context the handler is given is whatever mscratch names right now,
    ;; not the block this stub was built against: after a task switch they are
    ;; different, and the handler edits the one that is about to be restored.
    (i-csrrs a $a3 csr-mscratch $zero)
    (i-slli a $a3 $a3 1)
    (i-ori a $a3 $a3 1)
    (i-lw a $t0 $zero lg-traphook)
    (i-li a $t1 4)
    (i-lw a $t2 $t0 0)
    (i-call-reg a $t2)

    ;; Restore. The handler may have edited the context - that is how a task
    ;; switch and how resuming past an ecall both work.
    (i-csrrs a $t0 csr-mscratch $zero)
    (i-lw a $ra $t0 (ctx-off 0))
    (i-csrrw a $zero csr-mepc $ra)
    ;; gp and tp are not restored. They are the cons allocator's run pointers,
    ;; which belong to the machine rather than to any one context: the handler
    ;; may well have collected and moved on to a different run, and putting
    ;; the interrupted task's stale pair back would hand out cells twice.
    (let ((r 1))
      (while (%< r 32)
        (if (memq r (list 3 4 5)) nil (i-lw a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-lw a $t0 $t0 (ctx-off 5))
    (i-mret a)
    (asm-place a)
    a))

;; ---------------------------------------------------------------- assembly
(define boot-stack-size 262144)
(define trap-stack-size 65536)
(define *trap-asm* nil)
(define *reset-asm* nil)
(define *refill-asm* nil)

(define reset-reserve 256)
(define *reset-addr* 0)

;; Step one, before a single line of Lisp is compiled: claim the reset vector.
;; Code space is a bump allocator and the processor starts at its base, so
;; whatever is allocated first is what runs first.
(define (reserve-reset)
  (set! *reset-addr* (%alloc-code reset-reserve))
  (set! trap-save (boot-alloc-pool ctx-bytes))
  (set! trap-stack (boot-alloc-pool trap-stack-size))
  (set! boot-stack (boot-alloc-pool boot-stack-size))
  (%set-global! lg-trapsave trap-save)
  (%set-global! lg-stacktop (%+ boot-stack boot-stack-size))
  (%set-global! lg-stackbot boot-stack)
  *reset-addr*)

;; Step two, once everything else has been compiled and the entry point is
;; known.
(define (build-boot-code)
  (set! *refill-asm* (emit-cons-refill))
  (set! *trap-asm* (emit-trap-stub))
  (%set-global! lg-gchook (asm-origin *refill-asm*))
  (set! *reset-asm* (emit-reset-stub nil))
  (list *reset-addr*
        (asm-origin *trap-asm*)
        (asm-origin *refill-asm*)))
