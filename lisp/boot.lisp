;;; boot.lisp - the two stubs that have to be assembly.
;;;
;;; Run by the forge and not compiled into the image: this file emits code
;;; that goes into the image. Each stub does something before or after any
;;; Lisp function could be running: make the first capabilities out of the
;;; root, save every register, or return through mret.
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
;; 32 capability slots of 8 bytes: slot 0 is the pc, slots 1..31 are x1..x31.
;; `ctx-bytes` and the `reg-*` names come from the generated layout.
(define (ctx-off n) (%* value-bytes n))

;; The special capability registers the stubs reach with `cspecialrw` are
;; the layout's `scr-*`. nil has `perms-nil`: it may load and nothing else,
;; which keeps it the same capability whatever it is loaded through, because
;; a load through an authority without LM clears SD, SC and LM and nil has
;; none of them. A stack, a frame and a run of cons space load and store
;; values, which is `perms-pair`, as `data-region` in sys.lisp gives them.

(define trap-save 0)      ; filled in below, in the pool
(define trap-stack 0)
(define boot-stack 0)

;; Frames for traps taken inside the trap handler; see `emit-trap-stub`. The
;; stride is a frame plus its link slot, rounded up to a power of two so that
;; indexing is a shift: the stub has no register to spare for a multiply.
;; `trap-nest-limit` in sys.lisp is the same number as `trap-nest-max`.
(define trap-nest-shift 9)
(define trap-nest-stride (%lsh 1 trap-nest-shift))
(define trap-nest-max 8)
(define trap-nest 0)

;; cd <- the root, in `root`, narrowed to the `len` bytes at `base` with the
;; permissions of a pair, standing at `base`. t1 is the scratch register.
(define (emit-region a cd root base len)
  (i-li a $t1 base)
  (i-csetaddr a cd root $t1)
  (i-li a $t1 len)
  (i-csetboundsexact a cd cd $t1)
  (i-li a $t1 perms-pair)
  (i-candperm a cd cd $t1))

;; cd <- the root, in `root`, standing at the integer address `addr`.
(define (emit-at a cd root addr)
  (i-li a $t1 addr)
  (i-csetaddr a cd root $t1))

;; ---------------------------------------------------------------- reset
;; Placed at the base of code space, where the processor starts fetching.
;; PCC, DDC and MTCC are the root and every other register is NULL. DDC keeps
;; the root, because addressing memory by number is the privileged code's;
;; everything else is made from it here.
(define (emit-reset-stub)
  (let ((a (make-assembler)))
    (i-cspecialrw a $t0 scr-ddc $zero)
    ;; nil: the cell at address 0, read only, whose car and cdr are nil.
    (i-csetaddr a $tp $t0 $zero)
    (i-li a $t1 16)
    (i-csetboundsexact a $tp $tp $t1)
    (i-li a $t1 perms-nil)
    (i-candperm a $tp $tp $t1)
    (i-sc a $tp $zero 0)
    (i-sc a $tp $zero 8)
    ;; A stack to stand on, bounded to itself.
    (emit-region a $sp $t0 boot-stack boot-stack-size)
    (emit-at a $sp $sp (%+ boot-stack boot-stack-size))
    ;; Where traps save registers, and where they go.
    (emit-region a $t2 $t0 trap-save ctx-bytes)
    (i-cspecialrw a $zero scr-mscratchc $t2)
    (emit-at a $t2 $t0 (asm-origin *trap-asm*))
    (i-cspecialrw a $zero scr-mtcc $t2)
    ;; An empty cons run, the one `empty-cons-run` in gc.lisp makes: the first
    ;; pair faults, and the trap handler hands out a real run.
    (emit-region a $gp $t0 cons-base 0)
    ;; No task yet, and no caller: a NULL frame pointer is the bottom of the
    ;; stack.
    (i-mv a $s2 $tp)
    (i-mv a $s0 $zero)
    ;; Enter Lisp.
    (i-lc a $t0 $zero lg-toplevel)
    (i-li a $t1 0)
    (i-jcl a $ra $t0)
    ;; If it comes back, stop the machine with whatever it returned.
    (i-cspecialrw a $t0 scr-ddc $zero)
    (emit-at a $t0 $t0 mmio-base)
    (i-sw a $a0 $t0 0)
    (label a 'spin)
    (i-j a 'spin)
    (if (%> (asm-len a) reset-reserve) (error "boot: the reset stub outgrew its reservation") nil)
    (place-at a *reset-addr*)
    a))

;; ---------------------------------------------------------------- traps
;; Saves the complete machine state, calls the Lisp handler on a private
;; stack, then puts the state back and returns through mret. The whole
;; context is one block, so the scheduler switches tasks by pointing
;; MScratchC at a different one.
;;
;; MScratchC names the frame a trap saves its registers into: the running
;; task's context block when nothing is in progress, and a frame out of
;; `trap-nest` when a trap is taken inside the handler. That happens whenever
;; the handler's own arithmetic outgrows a fixnum, since `+` is a trapping
;; instruction, and whenever it uses up the cons run. `lg-trapdepth` counts
;; the traps in progress.
;;
;; Every register is saved and restored as a capability, so the tags go back
;; as they came. The stub runs on MTCC, which is the root and has SR, and
;; reaches the low globals through DDC with x0 as the base.
(define (emit-trap-stub)
  (let ((a (make-assembler))
        (outer (gensym-label "trap-outer"))
        (keepsp (gensym-label "trap-keepsp"))
        (nolink (gensym-label "trap-nolink"))
        (over (gensym-label "trap-over")))
    ;; Swap the frame into t0, which gives one register to work with and
    ;; destroys nothing: t0's own value is in MScratchC now.
    (i-cspecialrw a $t0 scr-mscratchc $t0)
    ;; Working out which frame needs a second register, and there is nowhere
    ;; to put one yet. It goes in a fixed slot for the dozen instructions it
    ;; takes; nothing in between can fault, so the slot cannot be re-entered.
    (i-sc a $t1 $zero lg-traptmp)
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
    (i-slli a $t1 $t1 trap-nest-shift)     ; times trap-nest-stride
    (i-sc a $t0 $zero lg-traptmp2)         ; the frame we came from
    (i-li a $t0 trap-nest)
    (i-add a $t1 $t1 $t0)                  ; the address of this frame
    (i-cspecialrw a $t0 scr-ddc $zero)
    (i-csetaddr a $t0 $t0 $t1)
    (i-li a $t1 trap-nest-stride)
    (i-csetboundsexact a $t0 $t0 $t1)
    (i-li a $t1 perms-pair)
    (i-candperm a $t0 $t0 $t1)
    (i-lc a $t1 $zero lg-traptmp2)
    (i-sc a $t1 $t0 ctx-bytes)             ; the link, just past the registers

    (label a outer)
    ;; t0 is the frame. Everything except t0 and t1, both of which are parked.
    (let ((r 1))
      (while (%< r 32)
        (if (if (%= r reg-t0) t (%= r reg-t1))
            nil
            (i-sc a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-lc a $t1 $zero lg-traptmp)
    (i-sc a $t1 $t0 (ctx-off reg-t1))
    ;; and t0's own value, which has been in MScratchC since the swap
    (i-cspecialrw a $t1 scr-mscratchc $t0)
    (i-sc a $t1 $t0 (ctx-off reg-t0))
    (i-cspecialrw a $t1 scr-mepcc $zero)
    (i-sc a $t1 $t0 (ctx-off reg-pc))

    ;; A stack of its own, so a fault caused by a broken stack pointer can
    ;; still be reported, but only at the outermost level: a nested trap is
    ;; already on the trap stack, and resetting it would cut the handler it
    ;; interrupted off from its own frames.
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)
    (i-bnez a $t1 keepsp)
    (i-cspecialrw a $t2 scr-ddc $zero)
    (emit-region a $sp $t2 trap-stack trap-stack-size)
    (emit-at a $sp $sp (%+ trap-stack trap-stack-size))
    (label a keepsp)

    ;; The handler takes mcause, the pc and mtval as integers, and the frame.
    (i-csrrs a $a0 csr-mcause $zero)
    (i-csrrs a $a1 csr-mepc $zero)
    (i-csrrs a $a2 csr-mtval $zero)
    (i-cspecialrw a $a3 scr-mscratchc $zero)
    ;; The handler's frames end here. The interrupted code's frame pointer
    ;; and stack pointer are in the saved context, where the collector finds
    ;; its stack (`each-trap-context` in gc.lisp).
    (i-mv a $s0 $zero)
    (i-lc a $t0 $zero lg-traphook)
    (i-li a $t1 4)
    (i-jcl a $ra $t0)

    ;; ---- and back ----
    ;; The handler may have edited the frame, which is how a task switch and
    ;; resuming past an ecall both work, and may have pointed MScratchC at a
    ;; different task's block.
    (i-cspecialrw a $t0 scr-mscratchc $zero)
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)
    (i-sw a $t1 $zero lg-trapdepth)
    (i-beqz a $t1 nolink)
    ;; Returning into a handler that is still in progress: give it its frame
    ;; back, so that its own way out finds what it expects.
    (i-lc a $t2 $t0 ctx-bytes)
    (i-cspecialrw a $zero scr-mscratchc $t2)
    (label a nolink)

    (i-lc a $ra $t0 (ctx-off reg-pc))
    (i-cspecialrw a $zero scr-mepcc $ra)
    ;; gp goes back with everything else: it is this task's cons run, and a
    ;; run is per task because the inline allocator narrows a pair out of gp
    ;; and moves gp past it afterwards, which an interrupt can land in the
    ;; middle of. The handler conses out of the same run and hands it back
    ;; into the frame before returning (`keep-cons-run` in sys.lisp), so what
    ;; goes back is the run as the handler left it.
    (let ((r 1))
      (while (%< r 32)
        (if (%= r reg-t0) nil (i-lc a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-lc a $t0 $t0 (ctx-off reg-t0))
    (i-mret a)

    ;; Traps all the way down: something in the handler faults on every
    ;; attempt. Stop the machine rather than write over frames still in use.
    (label a over)
    (i-cspecialrw a $t0 scr-ddc $zero)
    (emit-at a $t0 $t0 mmio-base)
    (i-li a $t1 exit-trap-spiral)
    (i-sw a $t1 $t0 0)

    (place a)
    a))

;; ---------------------------------------------------------------- assembly
(define boot-stack-size 262144)
(define trap-stack-size 65536)
(define *trap-asm* nil)
(define *reset-asm* nil)

(define *reset-addr* 0)

;; The stacks and frames the stubs use, in one block of the pool, largest
;; first from a multiple of the largest. Each is then a power of two at a
;; multiple of itself, which a capability bounds exactly: the processor is
;; not there to ask while the forge runs.
(define (reserve-stub-memory)
  (let* ((nest-bytes (%* trap-nest-stride trap-nest-max))
         (total (%+ boot-stack-size (%+ trap-stack-size (%+ nest-bytes ctx-bytes))))
         (block (%alloc-pool (%+ total boot-stack-size)))
         (base (%logand (%+ block (%- boot-stack-size 1)) (%- 0 boot-stack-size))))
    (set! boot-stack base)
    (set! trap-stack (%+ boot-stack boot-stack-size))
    (set! trap-nest (%+ trap-stack trap-stack-size))
    (set! trap-save (%+ trap-nest nest-bytes))))

;; Step one, before any Lisp is compiled: claim the reset vector. Code space
;; is a bump allocator and the processor starts at its base, so whatever is
;; allocated first is what runs first. The low globals hold the boot stack
;; and the boot context as integers; Exec makes its own capabilities to them
;; for task zero.
(define (reserve-reset)
  (set! *reset-addr* (%alloc-code reset-reserve))
  (reserve-stub-memory)
  (%st-word! lg-trapsave trap-save)
  (%st-word! lg-stacktop (%+ boot-stack boot-stack-size))
  (%st-word! lg-stackbot boot-stack)
  *reset-addr*)

;; Step two, once everything else has been compiled and the entry point is
;; known. The forge takes the reset stub's address and the trap stub's.
(define (build-boot-code)
  (set! *trap-asm* (emit-trap-stub))
  (set! *reset-asm* (emit-reset-stub))
  (list *reset-addr* (asm-origin *trap-asm*)))
