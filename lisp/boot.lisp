;;; boot.lisp - the three stubs that have to be assembly.
;;;
;;; Run by the forge and not compiled into the image: this file emits code
;;; that goes into the image. Each stub does something before or after any
;;; Lisp function could be running: set up the stack, save every register, or
;;; return through mret.
;;;
;;; The register save area they use has the same shape as an Exec task
;;; context. Taking a trap and switching tasks are the same operation seen
;;; from two directions.

;; Declared here rather than in packages.lisp: the machine has no use for a
;; namespace that only the forge reads.
(defpackage boot use lm gc hw asm compiler sys exec)
(in-package boot)
(unsafe-file)
(export '(build-boot-code reserve-reset))

;; ---------------------------------------------------------------- context
;; 32 words: word 0 is the pc, words 1..31 are x1..x31. `ctx-words`,
;; `ctx-bytes` and the `reg-*` names come from the generated layout.
(define (ctx-off n) (%* 4 n))

(define trap-save 0)      ; filled in below, in the pool
(define trap-stack 0)
(define boot-stack 0)

;; Frames for traps taken inside the trap handler; see `emit-trap-stub`. The
;; stride is a frame plus its link word, rounded up to a power of two so that
;; indexing is a shift: the stub has no register to spare for a multiply.
;; `trap-nest-limit` in sys.lisp is the same number.
(define trap-nest-stride 256)
(define trap-nest-max 8)
(define trap-nest 0)

;; ---------------------------------------------------------------- reset
;; Placed at the base of code space, where the processor starts fetching.
(define (emit-reset-stub)
  (let ((a (make-assembler)))
    ;; A stack to stand on.
    (i-li a $sp (%+ boot-stack boot-stack-size))
    (i-sw-abs a $sp lg-stacktop $t0)
    (i-li a $t0 boot-stack)
    (i-sw-abs a $t0 lg-stackbot $t1)
    ;; The current cons run, which the inline allocator bumps through.
    (i-lw a $gp $zero lg-cons-run)
    (i-lw a $tp $zero lg-cons-run-end)
    ;; Where traps go, and where they save registers.
    (i-li a $t0 trap-save)
    (i-csrrw a $zero csr-mscratch $t0)
    (i-li a $t0 (asm-origin *trap-asm*))
    (i-csrrw a $zero csr-mtvec $t0)
    ;; Enter Lisp. s0 is zeroed first: it is the frame link, and a zero there
    ;; tells the collector it has reached the bottom of the stack.
    (i-mv a $s0 $zero)
    (i-lw a $t0 $zero lg-toplevel)
    (i-li a $t1 0)
    (i-lw a $t2 $t0 0)
    (i-call-reg a $t2)
    ;; If it comes back, stop the machine with whatever it returned.
    (i-srai a $t0 $a0 1)
    (i-li a $t1 mmio-base)
    (i-sw a $t0 $t1 0)
    (label a 'spin)
    (i-j a 'spin)
    (place-at a *reset-addr*)
    a))

;; ---------------------------------------------------------------- allocator
;; Called from the inline cons when the current run is used up. Every
;; caller-saved register is pushed before the collector can run, and the
;; frame is laid out the way gc.lisp expects: the live mask first, then the
;; eight argument registers, then the return address and the temporaries. The
;; stack walker steps over the second half and takes only the masked part of
;; the first, which is what keeps the collector precise across an allocation.
(define arg-regs (list $a0 $a1 $a2 $a3 $a4 $a5 $a6 $a7))
(define raw-regs (list $ra $t0 $t1 $t2 $t3 $t4 $t6))

(define (emit-cons-refill)
  (let* ((a (make-assembler))
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
    ;; refill-cons takes a run off the free list, collecting first if it has
    ;; to, and installs it in gp and tp itself before it lets interrupts back
    ;; in.
    (i-lw a $t0 $zero lg-refill)
    (i-li a $t1 0)
    (i-lw a $t2 $t0 0)
    (i-call-reg a $t2)
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
    (place a)
    (%st-fixnum! lg-stub-lo (asm-origin a))
    (%st-fixnum! lg-stub-hi (%+ (asm-origin a) (asm-len a)))
    a))

;; ---------------------------------------------------------------- traps
;; Saves the complete machine state, calls the Lisp handler on a private
;; stack, then puts the state back and returns through mret. The whole
;; context is one block, so the scheduler switches tasks by pointing mscratch
;; at a different one.
;;
;; mscratch names the frame a trap saves its registers into: the running
;; task's context block when nothing is in progress, and a frame out of
;; `trap-nest` when a trap is taken inside the handler. That happens whenever
;; the handler's own arithmetic outgrows a fixnum, since `+` is a trapping
;; instruction. `lg-trapdepth` counts the traps in progress.
(define (emit-trap-stub)
  (let ((a (make-assembler))
        (outer (gensym-label "trap-outer"))
        (keepsp (gensym-label "trap-keepsp"))
        (nolink (gensym-label "trap-nolink"))
        (over (gensym-label "trap-over")))
    ;; Swap the frame pointer into t0, which gives one register to work with
    ;; and destroys nothing: t0's own value is in mscratch now.
    (i-csrrw a $t0 csr-mscratch $t0)
    ;; Working out which frame needs a second register, and there is nowhere
    ;; to put one yet. It goes in a fixed cell for the dozen instructions it
    ;; takes; nothing in between can fault, so the cell cannot be re-entered.
    (i-sw a $t1 $zero lg-traptmp)
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 1)
    (i-sw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)                  ; the depth before this trap
    (i-beqz a $t1 outer)                   ; nothing in progress: the task's block

    ;; Nested. Take a frame out of the array and record the one we came from,
    ;; so the way out can put it back.
    (i-addi a $t1 $t1 -1)                  ; index from zero
    (i-addi a $t1 $t1 (%- 0 trap-nest-max))
    (i-bge a $t1 $zero over)
    (i-addi a $t1 $t1 trap-nest-max)
    (i-slli a $t1 $t1 8)                   ; times trap-nest-stride
    (i-sw a $t0 $zero lg-traptmp2)         ; the frame we came from
    (i-li a $t0 trap-nest)
    (i-add a $t0 $t0 $t1)
    (i-lw a $t1 $zero lg-traptmp2)
    (i-sw a $t1 $t0 ctx-bytes)             ; the link, just past the registers

    (label a outer)
    ;; t0 is the frame. Everything except t0 and t1, both of which are parked.
    (let ((r 1))
      (while (%< r 32)
        (if (if (%= r reg-t0) t (%= r reg-t1))
            nil
            (i-sw a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-lw a $t1 $zero lg-traptmp)
    (i-sw a $t1 $t0 (ctx-off reg-t1))
    ;; and t0's own value, which has been in mscratch since the swap
    (i-csrrw a $t1 csr-mscratch $t0)
    (i-sw a $t1 $t0 (ctx-off reg-t0))
    (i-csrrs a $t1 csr-mepc $zero)
    (i-sw a $t1 $t0 (ctx-off reg-zero))

    ;; A stack of its own, so a fault caused by a broken stack pointer can
    ;; still be reported, but only at the outermost level: a nested trap is
    ;; already on the trap stack, and resetting it would cut the handler it
    ;; interrupted off from its own frames.
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)
    (i-bnez a $t1 keepsp)
    (i-li a $sp (%+ trap-stack trap-stack-size))
    (label a keepsp)

    ;; mcause has the interrupt flag in bit 31, which a fixnum cannot hold, so
    ;; the flag is moved down to bit 6 and the cause number kept in the low
    ;; five bits.
    (i-csrrs a $t2 csr-mcause $zero)
    (i-srli a $t3 $t2 25)
    (i-andi a $t3 $t3 64)
    (i-andi a $a0 $t2 31)
    (i-or a $a0 $a0 $t3)
    (i-slli a $a0 $a0 1)
    (i-ori a $a0 $a0 1)
    ;; The two addresses are narrowed to thirty bits so they stay fixnums;
    ;; they are only used to say where something went wrong.
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
    ;; The context the handler is given is this trap's frame, which mscratch
    ;; names.
    (i-csrrs a $a3 csr-mscratch $zero)
    (i-slli a $a3 $a3 1)
    (i-ori a $a3 $a3 1)
    ;; The handler's frames end here. Its caller's frame pointer is in the
    ;; saved context, and the collector finds the interrupted code's frames
    ;; through that (`scan-trap-frames` in gc.lisp) rather than by walking
    ;; from one stack into another.
    (i-li a $s0 0)
    (i-lw a $t0 $zero lg-traphook)
    (i-li a $t1 4)
    (i-lw a $t2 $t0 0)
    (i-call-reg a $t2)

    ;; ---- and back ----
    ;; The handler may have edited the frame, which is how a task switch and
    ;; resuming past an ecall both work, and may have pointed mscratch at a
    ;; different task's block.
    (i-csrrs a $t0 csr-mscratch $zero)
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)
    (i-sw a $t1 $zero lg-trapdepth)
    (i-beqz a $t1 nolink)
    ;; Returning into a handler that is still in progress: give it its frame
    ;; back, so that its own way out finds what it expects.
    (i-lw a $t2 $t0 ctx-bytes)
    (i-csrrw a $zero csr-mscratch $t2)
    (label a nolink)

    (i-lw a $ra $t0 (ctx-off reg-zero))
    (i-csrrw a $zero csr-mepc $ra)
    ;; gp and tp go back with everything else: they are this task's cons run,
    ;; and a run is per task because the inline allocator stores into the
    ;; cell at gp and bumps it afterwards, which an interrupt can land in the
    ;; middle of. The handler conses out of the same run and hands it back
    ;; into the frame before returning (`keep-cons-run` in sys.lisp), so what
    ;; goes back is the run as the handler left it.
    (let ((r 1))
      (while (%< r 32)
        (if (%= r reg-t0) nil (i-lw a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-lw a $t0 $t0 (ctx-off reg-t0))
    (i-mret a)

    ;; Traps all the way down: something in the handler faults on every
    ;; attempt. Stop the machine rather than write over frames still in use.
    (label a over)
    (i-li a $t0 mmio-base)
    (i-li a $t1 exit-trap-spiral)
    (i-sw a $t1 $t0 0)

    (place a)
    a))

;; ---------------------------------------------------------------- assembly
(define boot-stack-size 262144)
(define trap-stack-size 65536)
(define *trap-asm* nil)
(define *reset-asm* nil)
(define *refill-asm* nil)

(define reset-reserve 256)
(define *reset-addr* 0)

;; Step one, before any Lisp is compiled: claim the reset vector. Code space
;; is a bump allocator and the processor starts at its base, so whatever is
;; allocated first is what runs first.
(define (reserve-reset)
  (set! *reset-addr* (%alloc-code reset-reserve))
  (set! trap-save (%alloc-pool ctx-bytes))
  (set! trap-nest (%alloc-pool (%* trap-nest-stride trap-nest-max)))
  (set! trap-stack (%alloc-pool trap-stack-size))
  (set! boot-stack (%alloc-pool boot-stack-size))
  (%st-fixnum! lg-trapsave trap-save)
  (%st-fixnum! lg-stacktop (%+ boot-stack boot-stack-size))
  (%st-fixnum! lg-stackbot boot-stack)
  *reset-addr*)

;; Step two, once everything else has been compiled and the entry point is
;; known.
(define (build-boot-code)
  (set! *refill-asm* (emit-cons-refill))
  (set! *trap-asm* (emit-trap-stub))
  (%st-fixnum! lg-gchook (asm-origin *refill-asm*))
  (set! *reset-asm* (emit-reset-stub))
  (list *reset-addr*
        (asm-origin *trap-asm*)
        (asm-origin *refill-asm*)))
