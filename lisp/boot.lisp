;;; boot.lisp - the two stubs that have to be assembly.
;;;
;;; Run by the forge and not compiled into the image: this file emits code
;;; that goes into the image. Each stub does something before or after any
;;; Lisp function could be running: turn the memory map into capabilities,
;;; save every register, or return through mret.
;;;
;;; The register save area they use has the same shape as an Exec task
;;; context. Taking a trap and switching tasks are the same operation seen
;;; from two directions.

;; Declared here rather than in packages.lisp: the machine has no use for a
;; namespace that only the forge reads.
(defpackage boot use lm gc hw asm compiler sys exec)
(in-package boot)
(export '(build-boot-code reserve-stub-memory))

;; ---------------------------------------------------------------- context
;; 32 capability slots of 8 bytes: slot 0 is the pc, slots 1..31 are x1..x31.
;; `ctx-bytes` and the `reg-*` names come from the generated layout.
(define (ctx-off n) (%* value-bytes n))

;; A slot of the kernel block, as an offset from the capability `mscratch`
;; holds. The `kb-*` names come from the generated layout.
(define (kb-off slot) (%* value-bytes slot))

;; The capabilities the stubs keep in CSRs, `mtvec`, `mscratch`, `mepc` and
;; the collector's maps, are read whole by a CSR read and written whole by
;; `csrrw`. nil has `perms-nil`: it may load and nothing else, which keeps it
;; the same capability whatever it is loaded through, because a load through
;; an authority without LM clears SD, SC and LM and nil has none of them. A
;; stack and a run of cons space load and store values, which is
;; `perms-pair`.

;; Frames for traps taken inside the trap handler; see `emit-trap-stub`.
;; `trap-nest-limit` in sys.lisp is the same number.
(define trap-nest-max 8)

;; cd <- the root, in `root`, narrowed to the `len` bytes at `base` with the
;; permissions `perms`, standing at `base`. t1 is the scratch register.
(define (emit-region a cd root base len perms)
  (i-li a $t1 base)
  (i-yaddrw a cd root $t1)
  (i-li a $t1 len)
  (i-ybndsw a cd cd $t1)
  (i-li a $t1 (%lognot perms))
  (i-ypermc a cd cd $t1))

;; The memory map, as the kernel block holds it: each region's slot, base,
;; length and permissions. `heap::memory_map` in the forge mints the same.
(define (memory-map)
  (list (list kb-low 0 low-end perm-ld)
        (list kb-cons cons-base (%- cons-limit cons-base) perms-pair)
        (list kb-objects obj-base (%- obj-limit obj-base) perms-space)
        (list kb-marks gc-bitmap gc-bitmap-bytes (%logior perm-ld perm-sd))
        (list kb-starts obj-starts obj-starts-bytes (%logior perm-ld perm-sd))
        (list kb-scratch scratch-base scratch-bytes (%logior perm-ld perm-sd))
        (list kb-seals 0 16 perm-se)))

;; A device's page: its registers, and for the chips with a capability
;; register, capabilities as well. `heap::device_page` in the forge agrees.
(define (device-perms dev)
  (if (if (%= dev dev-blit) t (if (%= dev dev-disk) t (%= dev dev-gfx)))
      (%logior (%logior perm-ld perm-sd) (%logior perm-lc perm-sc))
      (%logior perm-ld perm-sd)))

;; ---------------------------------------------------------------- reset
;; Placed at the reset vector, where the processor starts fetching, with the
;; root in PCC and `mtvec` and every other register NULL. This is where the
;; memory map becomes capabilities, once each time the machine starts: nil,
;; the kernel block, which goes in `mscratch`, every region the kernel block
;; holds, the collector's maps the barrier reads through, and every device's
;; page. The root comes from its CSR and goes no further than this stub: no
;; register holding it, or anything minted here but nil, is left for the
;; code it enters. The boot stack, the boot context and the trap stub's
;; entry are objects the kernel block holds, so that they are roots and
;; move with object space when the forge slides it.
(define (emit-reset-stub)
  (let ((a (make-assembler)))
    (i-csrrs a $t0 csr-root $zero)
    ;; nil: the cell at address 0, written through a capability that may,
    ;; then read only, its car and cdr nil.
    (emit-region a $t2 $t0 nil-cell 16 perms-pair)
    (i-li a $t1 (%lognot perms-nil))
    (i-ypermc a $tp $t2 $t1)
    (i-sy a $tp $t2 0)
    (i-sy a $tp $t2 8)
    ;; The kernel block, the first object in object space.
    (emit-region a $s1 $t0 kb-base (%* value-bytes kb-slots) perms-object)
    (i-csrrw a $zero csr-mscratch $s1)
    ;; The regions, and the collector's maps where the barrier reads them.
    (dolist (r (memory-map))
      (emit-region a $t2 $t0 (cadr r) (caddr r) (cadddr r))
      (i-sy a $t2 $s1 (kb-off (%car r))))
    (i-ly a $t2 $s1 (kb-off kb-marks))
    (i-csrrw a $zero csr-gcmarks $t2)
    (i-ly a $t2 $s1 (kb-off kb-starts))
    (i-csrrw a $zero csr-gcstarts $t2)
    ;; Every device's page, into the kernel block's vector of them.
    (i-ly a $s3 $s1 (kb-off kb-devices))
    (let ((d 0))
      (while (%< d dev-count)
        (emit-region a $t2 $t0 (%+ mmio-base (%* d dev-page-bytes)) dev-page-bytes (device-perms d))
        (i-sy a $t2 $s3 (%* value-bytes d))
        (set! d (%+ d 1))))
    ;; Where traps save registers, and where they go: no trap in progress,
    ;; and the boot context the frame.
    (i-ly a $t2 $s1 (kb-off kb-boot-frame))
    (i-sy a $t2 $s1 (kb-off kb-frame))
    (i-sy a $zero $s1 (kb-off kb-depth))
    (i-ly a $t2 $s1 (kb-off kb-trap-entry))
    (i-csrrw a $zero csr-mtvec $t2)
    ;; A stack to stand on, at its top.
    (i-ly a $sp $s1 (kb-off kb-boot-stack))
    ;; An empty cons run, the one `empty-cons-run` in gc.lisp makes: the first
    ;; pair traps, and the trap handler hands out a real run.
    (i-ly a $gp $s1 (kb-off kb-cons))
    (i-ybndsw a $gp $gp $zero)
    ;; No task yet, and no caller: a NULL frame pointer is the bottom of the
    ;; stack.
    (i-mv a $s2 $tp)
    (i-mv a $s0 $zero)
    ;; Enter Lisp, holding nothing the stub minted but nil.
    (i-ly a $t0 $s1 (kb-off kb-toplevel))
    (i-li a $t1 0)
    (i-mv a $t2 $zero)
    (i-mv a $s1 $zero)
    (i-mv a $s3 $zero)
    (i-jcl a $ra $t0)
    ;; If it comes back, stop the machine with whatever it returned. The
    ;; forge runs a function on the machine this way.
    (i-csrrs a $t0 csr-mscratch $zero)
    (i-ly a $t0 $t0 (kb-off kb-devices))
    (i-ly a $t0 $t0 (%* value-bytes dev-sys))
    (i-sw a $a0 $t0 hw::sys-halt)
    (label a 'spin)
    (i-j a 'spin)
    (if (%> (asm-len a) reset-reserve) (error "boot: the reset stub outgrew its reservation") nil)
    (place-at a reset-vector)
    a))

;; Place at a fixed address, by number, and answer the address: the reset
;; stub, which has to sit at the reset vector, where the processor starts
;; with the root in PCC. It is assembled last, because it refers to
;; everything else. The forge does this, building the image the machine
;; boots from.
(define (place-at a addr)
  (set-asm-origin! a addr)
  (resolve a)
  (let ((len (asm-len a)) (buf (asm-buf a)) (i 0))
    (while (%< i len)
      (%st-byte! (%+ addr i) (%bytes-ref buf i))
      (set! i (%+ i 1))))
  addr)

;; ---------------------------------------------------------------- traps
;; Saves the complete machine state, calls the Lisp handler on a private
;; stack, then puts the state back and returns through mret. The whole
;; context is one block, so the scheduler switches tasks by pointing the
;; kernel block's frame at a different one.
;;
;; `mscratch` names the kernel block, and the kernel block's frame names the
;; frame a trap saves its registers into: the running task's context when
;; nothing is in progress, and one of the frames in its trap nest when a
;; trap is taken inside the handler. That happens whenever the handler's own
;; arithmetic outgrows a fixnum, since `+` is a trapping instruction, and
;; whenever it uses up the cons run. Its depth counts the traps in progress.
;;
;; Every register is saved and restored as a capability, so the tags go back
;; as they came. The stub is a text like any function's, and runs on
;; `mtvec`, its entry, which has SR; it reaches the kernel block through
;; `mscratch`, which takes SR, and the kernel block holds its entry, where the
;; reset stub finds it and the collector sees it. Its stores into the kernel
;; block and into a frame are through their own capabilities, which the
;; write barrier lets through, so nothing here can trap before the registers
;; are saved.
(define (emit-trap-stub)
  (let ((a (make-assembler))
        (outer (gensym-label "trap-outer"))
        (save (gensym-label "trap-save"))
        (keepsp (gensym-label "trap-keepsp"))
        (nolink (gensym-label "trap-nolink"))
        (over (gensym-label "trap-over")))
    (set-asm-privileged! a t)
    ;; Swap the kernel block into t0, which gives one register to work with
    ;; and destroys nothing: t0's own value is in `mscratch` now.
    (i-csrrw a $t0 csr-mscratch $t0)
    ;; Working out which frame needs a second register, and there is nowhere
    ;; to put one yet but the kernel block, where it waits for the dozen
    ;; instructions it takes; nothing in between can fault, so the slot
    ;; cannot be re-entered.
    (i-sy a $t1 $t0 (kb-off kb-park))
    (i-lw a $t1 $t0 (kb-off kb-depth))
    (i-addi a $t1 $t1 1)
    (i-sw a $t1 $t0 (kb-off kb-depth))
    (i-addi a $t1 $t1 -1)                  ; the depth before this trap
    (i-beqz a $t1 outer)                   ; nothing in progress: the task's block

    ;; Nested. Take this depth's frame out of the nest and record the one we
    ;; came from in it, so the way out can put it back. That takes a third
    ;; register, parked beside the second.
    (i-addi a $t1 $t1 -1)                  ; index from zero
    (i-addi a $t1 $t1 (%- 0 trap-nest-max))
    (i-bge a $t1 $zero over)
    (i-addi a $t1 $t1 trap-nest-max)
    (i-slli a $t1 $t1 3)                   ; a slot of the vector
    (i-sy a $t2 $t0 (kb-off kb-park2))
    (i-ly a $t2 $t0 (kb-off kb-trap-nest))
    (i-yadd a $t2 $t2 $t1)
    (i-ly a $t1 $t2 0)                     ; this frame
    (i-ly a $t2 $t0 (kb-off kb-frame))     ; the frame we came from
    (i-sy a $t2 $t1 ctx-bytes)             ; the link, just past the registers
    (i-sy a $t1 $t0 (kb-off kb-frame))
    (i-ly a $t2 $t0 (kb-off kb-park2))
    (i-j a save)

    (label a outer)
    (i-ly a $t1 $t0 (kb-off kb-frame))     ; the running task's context

    (label a save)
    ;; t1 is the frame and t0 the kernel block. Everything but those two.
    (let ((r 1))
      (while (%< r 32)
        (if (if (%= r reg-t0) t (%= r reg-t1))
            nil
            (i-sy a r $t1 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-ly a $t2 $t0 (kb-off kb-park))
    (i-sy a $t2 $t1 (ctx-off reg-t1))
    ;; and t0's own value, which has been in `mscratch` since the swap
    (i-csrrw a $t2 csr-mscratch $t0)
    (i-sy a $t2 $t1 (ctx-off reg-t0))
    (i-csrrs a $t2 csr-mepc $zero)
    (i-sy a $t2 $t1 (ctx-off reg-pc))

    ;; A stack of its own, so a fault caused by a broken stack pointer can
    ;; still be reported, but only at the outermost level: a nested trap is
    ;; already on the trap stack, and resetting it would cut the handler it
    ;; interrupted off from its own frames.
    (i-lw a $t2 $t0 (kb-off kb-depth))
    (i-addi a $t2 $t2 -1)
    (i-bnez a $t2 keepsp)
    (i-ly a $sp $t0 (kb-off kb-trap-stack))
    (label a keepsp)

    ;; The handler takes mcause, the pc and mtval as integers, and the frame.
    ;; `mepc` reads as a capability, and an integer instruction leaves its
    ;; address.
    (i-csrrs a $a0 csr-mcause $zero)
    (i-csrrs a $a1 csr-mepc $zero)
    (i-addi-w a $a1 $a1 0)
    (i-csrrs a $a2 csr-mtval $zero)
    (i-mv a $a3 $t1)
    ;; The handler's frames end here. The interrupted code's frame pointer
    ;; and stack pointer are in the saved context, where the collector finds
    ;; its stack (`each-trap-context` in gc.lisp).
    (i-mv a $s0 $zero)
    (i-ly a $t0 $t0 (kb-off kb-trap-hook))
    (i-li a $t1 4)
    (i-jcl a $ra $t0)

    ;; ---- and back ----
    ;; The handler may have edited the frame, which is how a task switch and
    ;; resuming past an ecall both work, and may have pointed the kernel
    ;; block's frame at a different task's context.
    (i-csrrs a $t0 csr-mscratch $zero)
    (i-ly a $t1 $t0 (kb-off kb-frame))
    (i-lw a $t2 $t0 (kb-off kb-depth))
    (i-addi a $t2 $t2 -1)
    (i-sw a $t2 $t0 (kb-off kb-depth))
    (i-beqz a $t2 nolink)
    ;; Returning into a handler that is still in progress: give it its frame
    ;; back, so that its own way out finds what it expects.
    (i-ly a $t2 $t1 ctx-bytes)
    (i-sy a $t2 $t0 (kb-off kb-frame))
    (label a nolink)

    (i-ly a $ra $t1 (ctx-off reg-pc))
    (i-csrrw a $zero csr-mepc $ra)
    ;; gp goes back with everything else: it is this task's cons run, and a
    ;; run is per task because the inline allocator narrows a pair out of gp
    ;; and moves gp past it afterwards, which an interrupt can land in the
    ;; middle of. The handler conses out of the same run and hands it back
    ;; into the frame before returning (`keep-cons-run` in sys.lisp), so what
    ;; goes back is the run as the handler left it.
    (let ((r 1))
      (while (%< r 32)
        (if (%= r reg-t1) nil (i-ly a r $t1 (ctx-off r)))
        (set! r (%+ r 1))))
    (i-ly a $t1 $t1 (ctx-off reg-t1))
    (i-mret a)

    ;; Traps all the way down: something in the handler faults on every
    ;; attempt. Stop the machine rather than write over frames still in use,
    ;; through the system device's page, t0 still the kernel block.
    (label a over)
    (i-ly a $t0 $t0 (kb-off kb-devices))
    (i-ly a $t0 $t0 (%* value-bytes dev-sys))
    (i-li a $t1 exit-trap-spiral)
    (i-sw a $t1 $t0 hw::sys-halt)

    (kernel-set! kb-trap-entry (place a))
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
;; bounds, and kept in the kernel block, which the stubs load it from and
;; which makes it a root. Exec makes the boot context and the boot stack
;; task zero's.
(define (reserve-stub-memory)
  (kernel-set! kb-boot-stack (stack-object boot-stack-size))
  (kernel-set! kb-trap-stack (stack-object trap-stack-size))
  (let ((frame (alloc-object t-context ctx-slots)))
    (kernel-set! kb-boot-frame frame)
    (kernel-set! kb-frame frame))
  (let ((nest (make-vector-n trap-nest-max nil)) (i 0))
    (while (%< i trap-nest-max)
      (%vector-set! nest i (alloc-object t-context (%+ ctx-slots 1)))
      (set! i (%+ i 1)))
    (kernel-set! kb-trap-nest nest)))

;; Step two, once everything else has been compiled and the entry point is
;; known: the trap stub, then the reset stub, which loads the trap stub's
;; entry.
(define (build-boot-code)
  (emit-trap-stub)
  (emit-reset-stub)
  nil)
