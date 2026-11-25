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
(export '(build-boot-code reserve-stub-memory))

;; ---------------------------------------------------------------- context
;; 32 capability slots of 8 bytes: slot 0 is the pc, slots 1..31 are x1..x31.
;; `ctx-bytes` and the `reg-*` names come from the generated layout.
(define (ctx-off n) (%* value-bytes n))

;; The capabilities the stubs keep in CSRs, `mtvec`, `mscratch`, `mepc` and
;; DDC, are read whole by a CSR read and written whole by `csrrw`. nil has
;; `perms-nil`: it may load and nothing else, which keeps it the same
;; capability whatever it is loaded through, because a load through an
;; authority without LM clears SD, SC and LM and nil has none of them. A
;; stack and a run of cons space load and store values, which is
;; `perms-pair`.

;; Frames for traps taken inside the trap handler; see `emit-trap-stub`.
;; `trap-nest-limit` in sys.lisp is the same number.
(define trap-nest-max 8)

;; cd <- the root, in `root`, narrowed to the `len` bytes at `base` with the
;; permissions of a pair, standing at `base`. t1 is the scratch register.
(define (emit-region a cd root base len)
  (i-li a $t1 base)
  (i-yaddrw a cd root $t1)
  (i-li a $t1 len)
  (i-ybndsw a cd cd $t1)
  (i-li a $t1 (%lognot perms-pair))
  (i-ypermc a cd cd $t1))

;; cd <- the root, in `root`, standing at the integer address `addr`.
(define (emit-at a cd root addr)
  (i-li a $t1 addr)
  (i-yaddrw a cd root $t1))

;; ---------------------------------------------------------------- reset
;; Placed at the reset vector, where the processor starts fetching. PCC, DDC
;; and `mtvec` are the root and every other register is NULL. DDC keeps the
;; root, because addressing memory by number is the privileged code's. nil
;; and the empty cons run are made from it here; the boot stack, the boot
;; context and the trap stub's entry are objects, kept in low globals so
;; that they are roots and move with object space when the forge slides it.
(define (emit-reset-stub)
  (let ((a (make-assembler)))
    (i-csrrs a $t0 csr-ddc $zero)
    ;; nil: the cell at address 0, read only, whose car and cdr are nil.
    (i-yaddrw a $tp $t0 $zero)
    (i-li a $t1 16)
    (i-ybndsw a $tp $tp $t1)
    (i-li a $t1 (%lognot perms-nil))
    (i-ypermc a $tp $tp $t1)
    (i-sy a $tp $zero 0)
    (i-sy a $tp $zero 8)
    ;; A stack to stand on, at its top.
    (i-ly a $sp $zero lg-boot-stack)
    ;; Where traps save registers, and where they go.
    (i-ly a $t2 $zero lg-trapsave)
    (i-csrrw a $zero csr-mscratch $t2)
    (i-ly a $t2 $zero lg-trap-entry)
    (i-csrrw a $zero csr-mtvec $t2)
    ;; An empty cons run, the one `empty-cons-run` in gc.lisp makes: the first
    ;; pair traps, and the trap handler hands out a real run.
    (emit-region a $gp $t0 cons-base 0)
    ;; No task yet, and no caller: a NULL frame pointer is the bottom of the
    ;; stack.
    (i-mv a $s2 $tp)
    (i-mv a $s0 $zero)
    ;; Enter Lisp.
    (i-ly a $t0 $zero lg-toplevel)
    (i-li a $t1 0)
    (i-jcl a $ra $t0)
    ;; If it comes back, stop the machine with whatever it returned. The
    ;; forge returns here from what it runs on the machine.
    (label a 'back)
    (i-csrrs a $t0 csr-ddc $zero)
    (emit-at a $t0 $t0 mmio-base)
    (i-sw a $a0 $t0 0)
    (label a 'spin)
    (i-j a 'spin)
    (if (%> (asm-len a) reset-reserve) (error "boot: the reset stub outgrew its reservation") nil)
    (place-at a reset-vector)
    a))

;; ---------------------------------------------------------------- traps
;; Saves the complete machine state, calls the Lisp handler on a private
;; stack, then puts the state back and returns through mret. The whole
;; context is one block, so the scheduler switches tasks by pointing
;; `mscratch` at a different one.
;;
;; `mscratch` names the frame a trap saves its registers into: the running
;; task's context block when nothing is in progress, and one of the frames
;; in `lg-trap-nest` when a trap is taken inside the handler. That happens
;; whenever the handler's own arithmetic outgrows a fixnum, since `+` is a
;; trapping instruction, and whenever it uses up the cons run.
;; `lg-trapdepth` counts the traps in progress.
;;
;; Every register is saved and restored as a capability, so the tags go back
;; as they came. The stub is a text like any function's, and runs on
;; `mtvec`, its entry, which has SR; it reaches the low globals through DDC
;; with x0 as the base. Its entry is kept in `lg-trap-entry`, where the reset stub
;; finds it and the collector sees it.
(define (emit-trap-stub)
  (let ((a (make-assembler))
        (outer (gensym-label "trap-outer"))
        (keepsp (gensym-label "trap-keepsp"))
        (nolink (gensym-label "trap-nolink"))
        (over (gensym-label "trap-over")))
    (set-asm-privileged! a t)
    ;; Swap the frame into t0, which gives one register to work with and
    ;; destroys nothing: t0's own value is in `mscratch` now.
    (i-csrrw a $t0 csr-mscratch $t0)
    ;; Working out which frame needs a second register, and there is nowhere
    ;; to put one yet. It goes in a fixed slot for the dozen instructions it
    ;; takes; nothing in between can fault, so the slot cannot be re-entered.
    (i-sy a $t1 $zero lg-traptmp)
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 1)
    (i-sw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)                  ; the depth before this trap
    (i-beqz a $t1 outer)                   ; nothing in progress: the task's block

    ;; Nested. Take this depth's frame out of the vector and record the one
    ;; we came from, so the way out can put it back.
    (i-addi a $t1 $t1 -1)                  ; index from zero
    (i-addi a $t1 $t1 (%- 0 trap-nest-max))
    (i-bge a $t1 $zero over)
    (i-addi a $t1 $t1 trap-nest-max)
    (i-slli a $t1 $t1 3)                   ; a slot of the vector
    (i-sy a $t0 $zero lg-traptmp2)         ; the frame we came from
    (i-ly a $t0 $zero lg-trap-nest)
    (i-yadd a $t0 $t0 $t1)
    (i-ly a $t0 $t0 0)                     ; this frame
    (i-ly a $t1 $zero lg-traptmp2)
    (i-sy a $t1 $t0 ctx-bytes)             ; the link, just past the registers

    (label a outer)
    ;; t0 is the frame. Everything except t0 and t1, both of which are parked.
    (let ((r 1))
      (while (%< r 32)
        (if (if (%= r reg-t0) t (%= r reg-t1))
            nil
            (i-sy a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-ly a $t1 $zero lg-traptmp)
    (i-sy a $t1 $t0 (ctx-off reg-t1))
    ;; and t0's own value, which has been in `mscratch` since the swap
    (i-csrrw a $t1 csr-mscratch $t0)
    (i-sy a $t1 $t0 (ctx-off reg-t0))
    (i-csrrs a $t1 csr-mepc $zero)
    (i-sy a $t1 $t0 (ctx-off reg-pc))

    ;; A stack of its own, so a fault caused by a broken stack pointer can
    ;; still be reported, but only at the outermost level: a nested trap is
    ;; already on the trap stack, and resetting it would cut the handler it
    ;; interrupted off from its own frames.
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)
    (i-bnez a $t1 keepsp)
    (i-ly a $sp $zero lg-trap-stack)
    (label a keepsp)

    ;; The handler takes mcause, the pc and mtval as integers, and the frame.
    ;; `mepc` reads as a capability, and an integer instruction leaves its
    ;; address.
    (i-csrrs a $a0 csr-mcause $zero)
    (i-csrrs a $a1 csr-mepc $zero)
    (i-addi-w a $a1 $a1 0)
    (i-csrrs a $a2 csr-mtval $zero)
    (i-csrrs a $a3 csr-mscratch $zero)
    ;; The handler's frames end here. The interrupted code's frame pointer
    ;; and stack pointer are in the saved context, where the collector finds
    ;; its stack (`each-trap-context` in gc.lisp).
    (i-mv a $s0 $zero)
    (i-ly a $t0 $zero lg-traphook)
    (i-li a $t1 4)
    (i-jcl a $ra $t0)

    ;; ---- and back ----
    ;; The handler may have edited the frame, which is how a task switch and
    ;; resuming past an ecall both work, and may have pointed `mscratch` at a
    ;; different task's block.
    (i-csrrs a $t0 csr-mscratch $zero)
    (i-lw a $t1 $zero lg-trapdepth)
    (i-addi a $t1 $t1 -1)
    (i-sw a $t1 $zero lg-trapdepth)
    (i-beqz a $t1 nolink)
    ;; Returning into a handler that is still in progress: give it its frame
    ;; back, so that its own way out finds what it expects.
    (i-ly a $t2 $t0 ctx-bytes)
    (i-csrrw a $zero csr-mscratch $t2)
    (label a nolink)

    (i-ly a $ra $t0 (ctx-off reg-pc))
    (i-csrrw a $zero csr-mepc $ra)
    ;; gp goes back with everything else: it is this task's cons run, and a
    ;; run is per task because the inline allocator narrows a pair out of gp
    ;; and moves gp past it afterwards, which an interrupt can land in the
    ;; middle of. The handler conses out of the same run and hands it back
    ;; into the frame before returning (`keep-cons-run` in sys.lisp), so what
    ;; goes back is the run as the handler left it.
    (let ((r 1))
      (while (%< r 32)
        (if (%= r reg-t0) nil (i-ly a r $t0 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-ly a $t0 $t0 (ctx-off reg-t0))
    (i-mret a)

    ;; Traps all the way down: something in the handler faults on every
    ;; attempt. Stop the machine rather than write over frames still in use.
    (label a over)
    (i-csrrs a $t0 csr-ddc $zero)
    (emit-at a $t0 $t0 mmio-base)
    (i-li a $t1 exit-trap-spiral)
    (i-sw a $t1 $t0 0)

    (%st-cap! lg-trap-entry (place a))
    a))

;; ---------------------------------------------------------------- assembly
(define boot-stack-size 262144)
(define trap-stack-size 65536)

;; A stack object, as a capability to its slots standing at its top.
(define (stack-object bytes)
  (let ((s (%cap-and-perms (alloc-object t-stack (%lsh bytes -3)) perms-pair)))
    (%cap-set-addr s (%cap-top s))))

;; Step one, before any Lisp is compiled: what the stubs stand on, the boot
;; stack, the trap stack, the boot context and a frame for each depth of
;; trap inside a trap, one slot longer than a context for its link. Each is
;; an object, made by the forge's allocator, which aligns it for exact
;; bounds, and kept in a low global, which the stubs load it from and which
;; makes it a root. Exec makes the boot context and the boot stack task
;; zero's.
(define (reserve-stub-memory)
  (%st-cap! lg-boot-stack (stack-object boot-stack-size))
  (%st-cap! lg-trap-stack (stack-object trap-stack-size))
  (%st-cap! lg-trapsave (alloc-object t-context ctx-slots))
  (let ((nest (make-vector-n trap-nest-max nil)) (i 0))
    (while (%< i trap-nest-max)
      (%vector-set! nest i (alloc-object t-context (%+ ctx-slots 1)))
      (set! i (%+ i 1)))
    (%st-cap! lg-trap-nest nest)))

;; Step two, once everything else has been compiled and the entry point is
;; known: the trap stub, then the reset stub, which loads the trap stub's
;; entry. Answers the address the reset stub stops the machine at, which is
;; where the forge has what it runs on the machine return to.
(define (build-boot-code)
  (emit-trap-stub)
  (%+ reset-vector (label-offset (emit-reset-stub) 'back)))
