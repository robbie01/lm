;;; sys.lisp - the kickstart: traps, fault reports, the restart, the prompt,
;;; and what the machine does when it wakes up.

(in-package sys)

;; ---------------------------------------------------------------- banner
(define system-name "LM")
(define system-version "0.1")

(define (banner)
  (emit-str "\n")
  (emit-str system-name)
  (emit-str " ")
  (emit-str system-version)
  (emit-str " - a lisp machine\n")
  (emit-str "cons space ")
  (emit-str (number->string (%lsh (%- cons-limit cons-base) -14)))
  (emit-str "k pairs, object space ")
  (emit-str (number->string (%lsh (%- obj-limit obj-base) -10)))
  (emit-str "k, ")
  (emit-str (number->string (%lsh (object-bytes-used) -10)))
  (emit-str "k used\n")
  nil)

(define (banner-exec)
  (emit-str "exec: ")
  (emit-str (number->string (task-count)))
  (emit-str (if (%= (task-count) 1) " task" " tasks"))
  (newline))

;; ---------------------------------------------------------------- contexts
;; The registers a trap saved, reached through the capability to the block
;; they were saved in. Slot 0 is the pc, where x0 would be, and slots 1..31
;; are x1..x31, eight bytes each; `reg-<name>` for each comes from the
;; generated layout. A slot holds what the register held, tag and all, so an
;; integer reads back as a fixnum and a pointer as the value it was.
;;
;; A context is the whole of what the code it saved was holding, its stack
;; and its cons run among it, and the trap handler hands none of it to a
;; name a program could define again: these are open-coded and unsafe, and
;; so is every function here that is handed a context, a register's value,
;; or a frame.
(defsubst (ctx-off n) (%* value-bytes n))
(defsubst (ctx-ref ctx n) (declare unsafe) (%cap-ld ctx (ctx-off n)))
(defsubst (ctx-set! ctx n v) (declare unsafe) (%cap-st! ctx (ctx-off n) v))

;; What an instruction read from register n: x0 reads as 0, whatever slot 0
;; holds.
(defsubst (ctx-operand ctx n) (declare unsafe) (if (%= n 0) 0 (ctx-ref ctx n)))

;; Moving the saved pc past the instruction is what makes a trap resume after
;; it rather than run it again.
(defsubst (step-past ctx n)
  (declare unsafe)
  (ctx-set! ctx reg-pc (%cap-inc (ctx-ref ctx reg-pc) n)))

;; Whether the code the context saved has SR: the code of an `unsafe` block,
;; which may hold anything at all.
(defsubst (sr-code? ctx)
  (declare unsafe)
  (%= perm-sr (%logand (%cap-perms (ctx-ref ctx reg-pc)) perm-sr)))

;; ---------------------------------------------------------------- traps
;; Everything that goes wrong arrives here, along with every interrupt. The
;; cause numbers, the interrupt numbers and the exit codes come from the
;; generated layout.

(define (cause-name c)
  (cond ((%= c cause-misaligned-fetch) "misaligned fetch")
        ((%= c cause-fetch-fault) "instruction access fault")
        ((%= c cause-illegal) "illegal instruction")
        ((%= c cause-breakpoint) "breakpoint")
        ((%= c cause-misaligned-load) "misaligned load")
        ((%= c cause-load-fault) "load access fault")
        ((%= c cause-misaligned-store) "misaligned store")
        ((%= c cause-store-fault) "store access fault")
        ((%= c cause-ecall) "ecall")
        ((%= c cause-wrong-type) "wrong type")
        ((%= c cause-range) "index out of range")
        ((%= c cause-overflow) "fixnum overflow")
        ((%= c cause-divzero) "division by zero")
        ((%= c cause-run) "cons run used up")
        ((%= c cause-barrier) "write barrier")
        ((%= c cause-stack) "stack overflow")
        ((%= c cause-cap-fetch) "capability fault on the pc")
        ((%= c cause-cap-load) "capability fault on a load")
        ((%= c cause-cap-store) "capability fault on a store")
        (else "trap")))

;; The stub hands over mcause as it is: the interrupt flag is bit 31, which
;; makes an interrupt's cause negative.
(define (interrupt? c) (%< c 0))
(define (interrupt-number c) (%logand c 31))

;; How deep traps may nest before the handler is taken to be faulting in a
;; loop. The stub has this many frames for traps inside traps: `trap-nest-max`
;; in boot.lisp, which is not in the image.
(defconstant trap-nest-limit 8)

(define (trap-spiral cause epc tval)
  (unsafe
  (uart-string "\n*** the trap handler is faulting in a loop: ")
  (uart-string (cause-name cause))
  (uart-string " at pc ")
  (uart-hex epc)
  (uart-string ", value ")
  (uart-hex tval)
  (uart-nl)
  (%halt exit-trap-spiral)))

;; The stub passes mcause, the pc and mtval as integers, and the capability
;; to the frame it saved the registers into.
(define (handle-trap cause epc tval ctx)
  (declare unsafe)
  (unsafe
  (if (%>= (kernel-ref kb-depth) trap-nest-limit) (trap-spiral cause epc tval) nil)
  (if (cons-refill? cause tval)
      (refill-run ctx)
      (begin
        (if (interrupt? cause)
            (handle-interrupt (interrupt-number cause) ctx)
            ;; The barrier first: while a collection is marking it is the
            ;; commonest trap by far, and the store that took it is waiting to
            ;; re-execute.
            (cond ((%= cause cause-barrier) (barrier tval ctx))
                  ((%= cause cause-ecall) (handle-ecall epc ctx))
                  ((%= cause cause-wrong-type)
                   (if (try-widen epc ctx) nil (check-trap cause epc tval ctx)))
                  ((%= cause cause-range) (check-trap cause epc tval ctx))
                  ((%= cause cause-overflow)
                   (if (try-widen epc ctx) nil (check-trap cause epc tval ctx)))
                  ((%= cause cause-divzero) (check-trap cause epc tval ctx))
                  ((%= cause cause-run) (check-trap cause epc tval ctx))
                  ((if (%>= cause cause-cap-fetch) (%<= cause cause-cap-store) nil)
                   (capability-trap cause epc tval ctx))
                  ((%= cause cause-illegal) (illegal-trap epc tval ctx))
                  (else (fatal-trap cause epc tval ctx))))
        (keep-cons-run ctx)))))

;; ---------------------------------------------------------------- the cons run
;; The inline allocator carves the next pair out of gp with `npair`, and when
;; the run is used up that traps naming gp. It is the refill, not an error,
;; and it is dealt with before anything here conses: every pair the handler
;; made would come out of the run that has just run out.
(define (cons-refill? cause tval)
  (if (%= cause cause-run) (%= tval reg-gp) nil))

;; The collector hands over a fresh run, collecting first if it has to, and
;; takes no pair to do it. The run goes into the saved gp, which the stub
;; puts back and the task resumes with at the same instruction, and into the
;; live one, so that nothing is left holding the run that ran out.
(define (refill-run ctx)
  (declare unsafe)
  (unsafe
  (let ((run (refill-cons-run)))
    (%set-cons-run! run)
    (ctx-set! ctx reg-gp run)
    nil)))

;; The handler conses out of the cons run of the task it interrupted, and the
;; stub restores the gp it saved on the way in. So the run goes back into the
;; frame as the handler left it, or the task would hand out the handler's
;; pairs a second time. That frame is `ctx` whatever else happened here: a
;; task switch points `mscratch` at the next task's frame and leaves this one
;; to be resumed later, with this run.
(define (keep-cons-run ctx)
  (declare unsafe)
  (unsafe
  (ctx-set! ctx reg-gp (%cons-run))
  nil))

;; ------------------------- the instruction that trapped
;; The report says which operation failed and what it was handed: the
;; instruction is at the saved pc, and every register it named is in the
;; saved context. The pc is a number, and the instruction is read at it
;; through object space's capability, where every function's code is, or
;; the low block's, where the reset stub is; a pc anywhere else has no
;; instruction to read, and reads as 0. An instruction is only aligned to
;; two bytes, and a compressed one is the low half alone.
(define (insn-at pc)
  (declare unsafe)
  (unsafe
  (let ((space (cond ((if (%>= pc obj-base) (%<= pc (%- obj-limit 4)) nil) (kernel-ref kb-objects))
                     ((if (%>= pc 0) (%<= pc (%- low-end 4)) nil) (kernel-ref kb-low))
                     (else nil))))
    (if space
        (let* ((at (%cap-set-addr space pc))
               (lo (%logior (%cap-ld-byte at 0) (%lsh (%cap-ld-byte at 1) 8))))
          (if (%= (%logand lo 3) 3)
              (%logior lo (%lsh (%logior (%cap-ld-byte at 2) (%lsh (%cap-ld-byte at 3) 8)) 16))
              lo))
        0))))

;; The fields, open-coded: which register the handler reads, or writes a
;; widened result into, is what they say.
(defsubst (compressed? w) (if (%= (%logand w 3) 3) nil t))
(defsubst (insn-op w)  (%logand w 127))
(defsubst (insn-rd w)  (%logand (%lsh w -7) 31))
(defsubst (insn-f3 w)  (%logand (%lsh w -12) 7))
(defsubst (insn-rs1 w) (%logand (%lsh w -15) 31))
(defsubst (insn-rs2 w) (%logand (%lsh w -20) 31))
(defsubst (insn-f7 w)  (%logand (%lsh w -25) 127))

;; The I-type and S-type immediates, sign-extended as the processor reads
;; them.
(defsubst (insn-imm-i w) (%ash w -20))
(defsubst (insn-imm-s w) (%logior (%lsh (%ash w -25) 5) (%logand (%lsh w -7) 31)))

;; Xlm's fixnum immediates: the operation in imm[11:10], and a ten-bit
;; signed immediate below it.
(defsubst (fixi-op w) (%logand (%lsh w -30) 3))
(defsubst (fixi-imm w) (%ash (%lsh w 2) -22))

;; Whether an instruction is Xlm's, in its R-type group, and if so its
;; funct7.
(defsubst (xlm-r? w) (if (%= (insn-op w) op-xlm) (%= (insn-f3 w) 6) nil))

;; The value a fault names by its register. Register 0 is x0, which reads as
;; NULL, the integer 0; its slot in the context holds the pc.
(defsubst (fault-value ctx reg)
  (declare unsafe)
  (if (if (%> reg 0) (%< reg 32) nil) (ctx-ref ctx reg) 0))

;; What the report says of the value in register `reg`. Code that says
;; nothing unsafe holds only what it was handed, and a value of its is
;; written as the printer writes it. The registers a program never names, its
;; return address, stack, frame, code object and cons run, and every register
;; of code with SR, may hold what no program was handed, so a capability
;; there is named by its fields, which are numbers and hand nothing on.
(define (emit-held ctx reg)
  (declare unsafe)
  (unsafe
  (let ((v (fault-value ctx reg)))
    (if (if (%cap-tag? v)
            (if (%null? v)
                nil
                (if (sr-code? ctx)
                    t
                    (if (%= reg reg-ra) t
                        (if (%= reg reg-sp) t
                            (if (%= reg reg-gp) t
                                (if (%= reg reg-tp) t
                                    (if (%= reg reg-s0) t (%= reg reg-s1))))))))
            nil)
        (emit-capability-fields (%addr-of v) (%cap-base v) (cap-top-hex v)
                                (%cap-perms v) (%cap-otype v))
        (write v)))))

;; ------------------------- naming the operation
(define (pair-op-name w)
  (if (%= (insn-f3 w) 1)
      (if (%= (insn-imm-s w) 0) "set-car!" "set-cdr!")
      (if (%= (insn-imm-i w) 0) "car" "cdr")))

(define (length-op-name ty)
  (cond ((%= ty t-vector) "vector-length")
        ((%= ty t-string) "string-length")
        ((%= ty t-bytes) "bytes-length")
        (else "length")))

;; Indexed access: funct7 is the form, store, byte and immediate, above the
;; type the object must be.
(define (index-type w) (%logand (insn-f7 w) 15))
(define (index-form w) (%lsh (insn-f7 w) -4))

(define (index-op-name w)
  (let ((ty (index-type w))
        (store (%= 1 (%logand (index-form w) 1))))
    (cond ((%= ty t-vector) (if store "vector-set!" "vector-ref"))
          ((%= ty t-string) (if store "string-set!" "string-ref"))
          ((%= ty t-bytes) (if store "bytes-set!" "bytes-ref"))
          (else (if store "set-slot!" "slot")))))

;; `fop`, by funct7: the eight operations, their trapping forms 8 above
;; them, then the shifts and the comparisons.
(define (arith-op-name k)
  (cond ((%= k 0) "+") ((%= k 1) "-") ((%= k 2) "*") ((%= k 3) "/")
        ((%= k 4) "rem") ((%= k 5) "logand") ((%= k 6) "logior")
        (else "logxor")))

(define (fop-name f7)
  (cond ((%>= f7 #x13) (if (%= f7 #x15) "=" "<"))
        ((%>= f7 #x10) (if (%= f7 #x11) "lsh" "ash"))
        ((%>= f7 8) (arith-op-name (%- f7 8)))
        (else (arith-op-name f7))))

;; `retag`: the kind the operand must be in funct7's low five bits, the
;; metadata it is given in the rs2 field.
(define (retag? w) (if (xlm-r? w) (%= (%logand (insn-f7 w) #x60) #x40) nil))
(define (retag-from w) (%logand (insn-f7 w) 31))
(define (retag-to w) (insn-rs2 w))

(define (retag-name w)
  (cond ((if (%= (retag-from w) 1) (%= (retag-to w) 0) nil) "char->integer")
        ((if (%= (retag-from w) 0) (%= (retag-to w) 1) nil) "integer->char")
        (else "retag")))

;; The R-type group by funct7: fop, fshi, jcl, vkind, lhdr, sealcl, npair
;; and retag.
(define (xlm-r-op-name w)
  (let ((f7 (insn-f7 w)))
    (cond ((%< f7 #x18) (fop-name f7))
          ((%< f7 #x1b) (if (%= f7 #x19) "lsh" "ash"))
          ((%= f7 #x20) "call")
          ((%= f7 #x22) (length-op-name (insn-rs2 w)))
          ((%= f7 #x23) "make-closure")
          ((%= f7 #x24) "cons")
          ((retag? w) (retag-name w))
          (else "instruction"))))

;; Xlm by funct3: lref, sref, lvar, beqx, bnex, the fixnum immediates, the
;; R-type group and indexed access.
(define (xlm-op-name w)
  (let ((f (insn-f3 w)))
    (cond ((%< f 2) (pair-op-name w))
          ((%= f 2) "variable")
          ((%< f 5) "compare")
          ((%= f 5) (cond ((%= (fixi-op w) 2) "logand") ((%= (fixi-op w) 3) "logior") (else "+")))
          ((%= f 6) (xlm-r-op-name w))
          (else (index-op-name w)))))

;; RVY's own, by funct3.
(define (rvy-op-name w)
  (let ((f (insn-f3 w)))
    (cond ((%= f 1) "load")
          ((%= f 2) "store")
          ((%= f 4) "capability offset")
          ((%= f 5) "capability bounds")
          (else "capability operation"))))

;; Quadrants 0 and 2 hold the compressed loads and stores, funct3 2 and 3
;; loading and 6 and 7 storing; quadrant 2's funct3 4 is the register jumps.
(define (compressed-op-name w)
  (let ((q (%logand w 3)) (f (%logand (%lsh w -13) 7)))
    (cond ((%= q 1) "instruction")
          ((%>= f 6) "store")
          ((%>= f 4) (if (%= q 2) "jump" "instruction"))
          ((%>= f 2) "load")
          (else "instruction"))))

;; What an instruction does, said the way the source says it where the
;; source has a word for it.
(define (op-name w)
  (if (compressed? w)
      (compressed-op-name w)
      (let ((op (insn-op w)))
        (cond ((%= op op-xlm) (xlm-op-name w))
              ((%= op op-rvy) (rvy-op-name w))
              ((%= op op-load) "load")
              ((%= op op-store) "store")
              ((if (%= op op-jalr) t (%= op op-jal)) "jump")
              ((%= op op-sys) "machine instruction")
              (else "instruction")))))

;; ------------------------- naming the value
;; Tags make every value say what it is, so whatever a register held is
;; printed as the printer prints it, a raw capability included.
(define (emit-a-or-an ctx reg)
  (declare unsafe)
  (unsafe
  (let ((sym (fault-value ctx reg)))
    (if (%symbol? sym)
        (begin
          (emit-str (if (if (%> (%string-length (%symbol-name sym)) 0)
                            (string-index "aeiou" (%string-ref (%symbol-name sym) 0))
                            nil)
                        "an "
                        "a "))
          (emit-str (%symbol-name sym)))
        (emit-held ctx reg)))))

(define (type-name ty)
  (cond ((%= ty t-vector) "a vector")
        ((%= ty t-string) "a string")
        ((%= ty t-bytes) "a byte vector")
        ((%= ty t-symbol) "a symbol")
        ((%= ty t-closure) "a function")
        ((%= ty t-record) "a record")
        ((%= ty t-code) "a code object")
        ((%= ty t-bignum) "a bignum")
        ((%= ty t-port) "a port")
        (else "an object")))

;; ------------------------- wrong type, out of range, arithmetic
;; An Xlm instruction checks its operand as it uses it. `lref` takes nil,
;; which reads as a pair of nils; `sref` refuses it, because nil has no cell
;; to write. `lvar` traps on the unbound marker naming the symbol's
;; register, `jcl` on anything that is not a closure, and `npair` on
;; anything that is not a cons run with a pair left in it.
(define (emit-ref-fault w ctx reg)
  (declare unsafe)
  (unsafe
  (let ((f (insn-f3 w)) (f7 (insn-f7 w)) (v (fault-value ctx reg)))
    (cond
     ((%= f 2)
      (if (%symbol? v)
          (begin (emit-str "unbound variable: ") (emit-str (%symbol-name v)))
          (begin (emit-str "variable: expected a symbol, got ") (emit-held ctx reg))))
     ((%< f 2)
      (emit-str (pair-op-name w))
      (cond ((%null? v) (emit-str ": nil has no cell"))
            ((%cons? v)
             (emit-str (if (%= f 1) ": the pair is read-only" ": the pair cannot be read")))
            (else (emit-str ": expected a pair, got ") (emit-held ctx reg))))
     ((%= f7 #x20)
      (emit-str "call: ")
      ;; A name nothing was ever stored in holds the unbound marker.
      (if (%eq? v (%unbound))
          (emit-str "undefined function")
          (begin (emit-str "expected a function, got ") (emit-held ctx reg))))
     ((%= f7 #x22)
      (emit-str (length-op-name (insn-rs2 w)))
      (emit-str ": expected ")
      (emit-str (type-name (insn-rs2 w)))
      (emit-str ", got ")
      (emit-held ctx reg))
     ((%= f7 #x24) (emit-str "cons: no pair is left in ") (emit-held ctx reg))
     (else (emit-str (op-name w)) (emit-str ": expected a closure object, got ") (emit-held ctx reg))))))

;; Both operands are still in the registers the instruction named, so the
;; report can say what was indexed as well as what with. The immediate form
;; keeps the index in the rs2 field, and a wrong type there can only be the
;; object's.
(define (emit-index-fault w cause tval ctx)
  (declare unsafe)
  (unsafe
  (let* ((ty (index-type w))
         (f (index-form w))
         (imm (%= 4 (%logand f 4)))
         (obj (ctx-ref ctx (insn-rs1 w)))
         (wanted (if (if (%= ty 0) (%= 2 (%logand f 2)) nil)
                     "a string or byte vector"
                     (type-name ty))))
    (emit-str (index-op-name w))
    (cond
     ((%= cause cause-range)
      (emit-str ": index ")
      (if imm (write (insn-rs2 w)) (emit-held ctx (insn-rs2 w)))
      (emit-str " is outside ") (emit-str wanted)
      (emit-str " of ") (emit-str (number->string (%obj-len obj))))
     ((if imm t (%= tval (insn-rs1 w)))
      (emit-str ": expected ") (emit-str wanted)
      (emit-str ", got ") (emit-held ctx (insn-rs1 w)))
     (else
      (emit-str ": index is not a number, it is ") (emit-held ctx (insn-rs2 w)))))))

;; Whether an Xlm instruction is a fixnum operation: the immediates, `fop`,
;; `fshi` and `retag`.
(define (fixnum-op? w)
  (if (%= (insn-op w) op-xlm)
      (cond ((%= (insn-f3 w) 5) t)
            ((%= (insn-f3 w) 6) (if (%< (insn-f7 w) #x1b) t (retag? w)))
            (else nil))
      nil))

;; `try-widen` has already had its chance, so a bignum reaching here means
;; this operator has no bignum form, not that the operand was the wrong kind
;; of thing.
(define (emit-arith-fault w cause ctx reg)
  (declare unsafe)
  (unsafe
  (emit-str (op-name w))
  (cond
   ((%= cause cause-divzero) (emit-str ": division by zero"))
   ((%= cause cause-overflow) (emit-str ": the result does not fit in a fixnum"))
   ((retag? w)
    (emit-str (if (%= (retag-from w) 1) ": expected a character, got " ": expected a number, got "))
    (emit-held ctx reg))
   ((%bignum? (fault-value ctx reg)) (emit-str ": no bignum form, given ") (emit-held ctx reg))
   (else (emit-str ": expected a number, got ") (emit-held ctx reg)))))

;; Causes 24 to 28. A wrong type, an index out of range or a cons run with
;; nothing left names the register that held the offending value, and the
;; instruction at the pc says what the value was for.
(define (check-trap cause epc tval ctx)
  (declare unsafe)
  (unsafe
  (fault-report epc ctx
    (lambda ()
      (let ((w (insn-at epc)))
        (cond ((if (%= (insn-op w) op-xlm) (%= (insn-f3 w) 7) nil) (emit-index-fault w cause tval ctx))
              ((fixnum-op? w) (emit-arith-fault w cause ctx tval))
              ((if (%= (insn-op w) op-xlm) (if (%= cause cause-wrong-type) t (%= cause cause-run)) nil)
               (emit-ref-fault w ctx tval))
              (else (emit-str (op-name w)) (emit-str ": ") (emit-str (cause-name cause)))))))))

;; ------------------------- capability faults
;; Causes 32, 33 and 34 say that a check on the pc, on a load's authority or
;; on a store's refused, and `mtval` says the address it refused. Which
;; capability that was is the instruction's to say, and why is that
;; capability's: asked about the access, it is untagged, sealed, missing
;; the permission, or not wide enough.

;; The register a load or a store takes as its authority: the base, or the
;; object of an Xlm access.
(defsubst (access-authority w)
  (if (compressed? w)
      (if (%= (%logand w 3) 2) reg-sp (%+ 8 (%logand (%lsh w -7) 7)))
      (insn-rs1 w)))

;; The register a jump takes its target from, or nil for one relative to the
;; pc: `jalr`, and `c.jr` and `c.jalr`, which name it where rd would be.
(defsubst (jump-register w)
  (cond ((compressed? w)
         (if (%= (%logand w 3) 2) (if (%= (%logand (%lsh w -13) 7) 4) (insn-rd w) nil) nil))
        ((%= (insn-op w) op-jalr) (insn-rs1 w))
        (else nil)))

(define (capability-trap cause epc tval ctx)
  (declare unsafe)
  (unsafe
  (fault-report epc ctx
    (lambda ()
      (let ((w (insn-at epc)))
        (if (%= cause cause-cap-fetch)
            (emit-fetch-fault w epc tval ctx)
            (emit-access-fault w (access-authority w) (%= cause cause-cap-store) tval ctx)))))))

;; Whether the capability stores data, or loads it, at all.
(defsubst (stores-data? c) (%= perm-sd (%logand (%cap-perms c) perm-sd)))
(defsubst (loads-data? c) (%= perm-ld (%logand (%cap-perms c) perm-ld)))
(defsubst (executes? c) (%= perm-ex (%logand (%cap-perms c) perm-ex)))

;; A register's value as the report names it, and as the capability it is
;; where the printer could not read it.
(define (emit-value ctx reg)
  (declare unsafe)
  (unsafe
  (let ((v (fault-value ctx reg)))
    (if (if (%cap-tag? v) (if (loads-data? v) nil t) nil)
        (emit-capability-fields (%addr-of v) (%cap-base v) (cap-top-hex v)
                                (%cap-perms v) (%cap-otype v))
        (emit-held ctx reg)))))

(define (emit-sealed otype)
  (cond ((%= otype otype-closure) (emit-str " is a sealed function: only calling it opens it"))
        ((%= otype otype-sentry) (emit-str " is a sealed entry: only jumping to it opens it"))
        (else (emit-str " is sealed"))))

;; `sp` is bounded to its task's stack, so writing below the bottom is a
;; capability fault even where the stack limit has not caught it.
(define (emit-access-fault w reg store a ctx)
  (declare unsafe)
  (unsafe
  (let ((v (fault-value ctx reg)))
    (if (if (%= reg reg-sp) (if (%cap-tag? v) (%< a (%cap-base v)) nil) nil)
        (emit-str "stack overflow: below the bottom of the stack")
        (begin
          (emit-str (op-name w))
          (emit-str ": ")
          (cond
           ((if (%cap-tag? v) nil t) (emit-value ctx reg) (emit-str " is not a pointer"))
           ((%cap-sealed? v) (emit-value ctx reg) (emit-sealed (%cap-otype v)))
           ((if store (if (stores-data? v) nil t) nil)
            (if (%null? v) (emit-str "nil has no cell") (begin (emit-value ctx reg) (emit-str " is read-only"))))
           ((if store nil (if (loads-data? v) nil t)) (emit-value ctx reg) (emit-str " cannot be read"))
           (else (emit-str "outside the bounds of ") (emit-value ctx reg))))))))

;; What refused a jump's target: the capability it was to run under, the
;; value `v` of register `reg`, or with `reg` nil a closure's entry.
(define (emit-entry-refusal ctx reg v)
  (declare unsafe)
  (unsafe
  (cond ((if (%cap-tag? v) nil t) (emit-entry ctx reg v) (emit-str " is not a pointer"))
        ((%cap-sealed? v) (emit-entry ctx reg v) (emit-sealed (%cap-otype v)))
        ((if (executes? v) nil t) (emit-entry ctx reg v) (emit-str " is not code"))
        (else (emit-str "outside the bounds of ") (emit-entry ctx reg v)))))

(define (emit-entry ctx reg v)
  (declare unsafe)
  (unsafe
  (if reg
      (emit-value ctx reg)
      (emit-capability-fields (%addr-of v) (%cap-base v) (cap-top-hex v) (%cap-perms v) (%cap-otype v)))))

;; The pc itself refused at the fetch, a jump or a branch out of its code,
;; or a jump or a call to a capability that cannot run there.
(define (emit-fetch-fault w epc t ctx)
  (declare unsafe)
  (unsafe
  (let ((reg (if (%= t epc) nil (jump-register w))))
    (cond
     ((%= t epc)
      (emit-str (if (executes? (ctx-ref ctx reg-pc))
                    "the pc has run off the end of its code"
                    "the pc is not in code")))
     (reg (emit-str "jump: ") (emit-entry-refusal ctx reg (fault-value ctx reg)))
     ((if (xlm-r? w) (%= (insn-f7 w) #x20) nil)
      (emit-str "call: the entry of ")
      (emit-held ctx (insn-rs1 w))
      (emit-str " cannot run: ")
      (emit-entry-refusal ctx nil (%cap-ld (open-closure (fault-value ctx (insn-rs1 w))) 0)))
     (else (emit-str (op-name w)) (emit-str ": the target is outside the code"))))))

;; An illegal instruction. Without SR in the pc the privileged instructions
;; are illegal: a CSR and `mret`. A load or a store through x0, which RVY
;; reserves, is illegal with SR or without: memory is reached through a
;; capability, and x0 is none.
(defsubst (privileged-insn? w)
  (if (compressed? w) nil (%= (insn-op w) op-sys)))

(define (illegal-trap epc tval ctx)
  (declare unsafe)
  (unsafe
  (if (if (privileged-insn? tval) (not (%= perm-sr (%logand (%cap-perms (ctx-ref ctx reg-pc)) perm-sr))) nil)
      (fault-report epc ctx
        (lambda ()
          (emit-str (op-name tval))
          (emit-str ": privileged operation in code compiled without unsafe")))
      (fatal-trap cause-illegal epc tval ctx))))

;; ---------------------------------------------------------------- widening
;; Overflow and mixed-mode arithmetic both arrive as traps, and neither is an
;; error. `+`, `-` and `*` emit the trapping forms of the fixnum instructions,
;; and every fixnum instruction refuses an operand that is not one, so a sum
;; that outgrows 32 bits and a sum with a bignum in it both stop here, and
;; both are the same operation done in a width that fits.
;;
;; Only the one instruction is emulated. A comparison leaves the fixnum 0 or
;; 1 and the instructions after it turn that into `t` or `nil`; an arithmetic
;; instruction leaves a number. The trap returns to the instruction after
;; this one and the rest of the sequence runs as compiled.
;;
;; A trap costs around ten times what the allocation inside it costs, so the
;; fast path is one instruction that asks nothing.
(defsubst (widenable? v) (if (%fixnum? v) t (%bignum? v)))

;; The register form's funct7, its trapping forms folded onto the wrapping
;; ones: what the operation is in a width that fits, or nil where it has no
;; such form.
(define (widened-op f7 x y)
  (let ((k (if (if (%>= f7 8) (%< f7 #x10) nil) (%- f7 8) f7)))
    (cond ((%= k 0) (generic-add x y))
          ((%= k 1) (generic-sub x y))
          ((%= k 2) (generic-mul x y))
          ((%= k 3) (generic-quotient x y))
          ((%= k 4) (generic-remainder x y))
          ((%= k #x13) (if (%< (generic-cmp x y) 0) 1 0))
          ((%= k #x15) (if (%= (generic-cmp x y) 0) 1 0))
          (else nil))))

;; `faddi` and `faddio` add their immediate; `fop` takes both operands from
;; registers. Only numbers go on to the arithmetic.
(define (widened w ctx)
  (declare unsafe)
  (unsafe
  (let ((f (insn-f3 w))
        (x (ctx-operand ctx (insn-rs1 w))))
    (cond ((%= f 5)
           (let ((y (fixi-imm w)))
             (if (if (%< (fixi-op w) 2) (widenable? x) nil) (generic-add x y) nil)))
          ((%= f 6)
           (let ((y (ctx-operand ctx (insn-rs2 w))))
             (if (if (%<= (insn-f7 w) #x15) (if (widenable? x) (widenable? y) nil) nil)
                 (widened-op (insn-f7 w) x y)
                 nil)))
          (else nil)))))

;; Slot zero of the context is the saved pc, not register x0, so an
;; instruction that writes x0 has nowhere to put an answer. The compiler
;; emits none; this keeps a corrupt word read as an instruction from
;; scribbling on the pc.
(define (try-widen epc ctx)
  (declare unsafe)
  (unsafe
  (let ((w (insn-at epc)))
    (if (if (%= (insn-op w) op-xlm) (if (%> (insn-rd w) 0) (%>= (insn-f3 w) 5) nil) nil)
        (let ((v (widened w ctx)))
          (if v
              (begin (ctx-set! ctx (insn-rd w) v) (step-past ctx 4) t)
              nil))
        nil))))

;; ---------------------------------------------------------------- ecalls
;; The compiler emits `ecall` for the conditions it detects inline, with the
;; reason in a7. The saved pc is stepped over the instruction first: the stub
;; reloads `mepc` from the context on its way out.
(define (handle-ecall epc ctx)
  (declare unsafe)
  (unsafe
  (step-past ctx 4)
  (let ((code (ctx-ref ctx reg-a7)))
    (if (%= code ecall-reschedule)
        ;; A task asking to be switched out. Returning from here resumes
        ;; whichever task the scheduler picked.
        (switch-tasks)
        (abort-to-repl ctx
         (compose-report
          (lambda ()
          (cond
           ((%= code ecall-arity)
            ;; t0 still holds the closure that was about to be entered, opened
            ;; by the `jcl` that entered it, and t1 the count it was handed.
            (emit-str "\ncalled ")
            (emit-callee (ctx-ref ctx reg-t0))
            (let ((n (ctx-ref ctx reg-t1)))
              (emit-str " with ")
              (emit-str (number->string n))
              (emit-str (if (%= n 1) " argument" " arguments")))
            (emit-str ", at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code ecall-unsafe)
            ;; A name given as data was to be resolved outside `unsafe`, and
            ;; the name is unsafe. The symbol is in a0.
            (emit-str "\n*** ")
            (emit-held ctx reg-a0)
            (emit-str " is unsafe: given as data it names nothing outside an unsafe form, at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code ecall-record)
            ;; A record accessor was handed the wrong kind of record. It left
            ;; the tag it wanted in t3 and what it was given in a0.
            (emit-str "\nexpected ")
            (emit-a-or-an ctx reg-t3)
            (emit-str ", got ")
            (emit-held ctx reg-a0)
            (emit-str ", at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code ecall-oom)
            (emit-str "\nout of memory at ") (emit-str (number->hex epc)) (emit-str "\n"))
           ;; `error` has already said what went wrong. What is left is
           ;; where, and the restart.
           ((%= code ecall-error) nil)
           (else (emit-str "\nunknown ecall\n")))
          (backtrace-from-context epc ctx))))))))

;; ---------------------------------------------------------------- backtrace
;; Every prologue saves its return address, its caller's frame and its own
;; closure in the slots the compiler names `ra-slot`, `link-slot` and
;; `clo-slot` below s0. So a backtrace needs no side table: the slots that
;; make a frame make the trace, and a frame's line is named by the closure
;; that built it. The pc a trap interrupted may be in a leaf or a prologue,
;; with no frame of its own, so its line is named by the code object whose
;; text it is in: the one in s1 once the prologue has loaded it, and
;; otherwise the one a walk of object space finds. The frame pointer is a
;; capability to the stack, and NULL at the bottom.
(defconstant backtrace-limit 24)

;; The closure a call was about to enter.
(define (emit-callee f)
  (declare unsafe)
  (unsafe
  (if (%closure? f) (emit-code-label (%slot f clo-code)) (emit-str "a non-function"))))

;; A frame link the trace may follow: a stack capability, unsealed, that
;; loads values, aligned to a slot, with the four fixed slots below it inside
;; its bounds. NULL, the link at the bottom of every stack, is not one, and
;; neither is anything else a broken frame could hold. The trace is printed
;; from inside the trap handler, where a fault would stop the machine.
(defconstant frame-link-perms (%logior perm-ld perm-lc))

(defsubst (frame-readable? f)
  (if (%cap-tag? f)
      (if (%cap-sealed? f)
          nil
          (if (%= frame-link-perms (%logand (%cap-perms f) frame-link-perms))
              (if (%= 0 (%logand (%addr-of f) 7))
                  (if (%>= (%- (%addr-of f) 32) (%cap-base f)) (%<= (%addr-of f) (%cap-top f)) nil)
                  nil)
              nil))
      nil))

;; The code object whose text the pc is in, or nil: `s1` if that is the one.
(define (code-of pc s1)
  (declare unsafe)
  (unsafe
  (cond ((%cap-tag? pc)
         (if (if (code-object? s1) (%= (%cap-base (%cap-ld s1 0)) (%cap-base pc)) nil)
             s1
             (code-object-at (%cap-base pc))))
        (else nil))))

;; The code object of the closure that built the frame `f`, or nil.
(defsubst (frame-code f)
  (declare unsafe)
  (let ((clo (%cap-ld f compiler::clo-slot)))
    (if (%object? clo)
        (if (%= (%obj-type clo) t-closure) (%cap-ld clo (%* value-bytes clo-code)) nil)
        nil)))

;; The function a code object's code runs as: its own, or for an island the
;; function it belongs to, whose frame it runs on.
(defsubst (code-owner code)
  (declare unsafe)
  (let ((name (%cap-ld code (%* value-bytes code-name))))
    (if (if (%cons? name) (%eq? (%car name) 'unsafe) nil)
        (%cap-ld code (%* value-bytes code-lits))
        code)))

;; Whether the function whose code object is `code` built the frame `f`.
(defsubst (frame-built-by? f code)
  (declare unsafe)
  (let ((built (frame-code f)))
    (if (if code built nil) (%= (%cap-base built) (%cap-base (code-owner code))) nil)))

;; A line of the trace: the code object, which names its function, and the
;; address, a number.
(define (emit-frame-line at code)
  (emit-str "  ")
  (emit-code-label code)
  (emit-str " at ")
  (emit-str (number->hex at))
  (emit-str "\n"))

;; A leaf has no frame, and neither has a function stopped in its prologue:
;; s0 is still its caller's frame, and ra is where it returns to in the
;; caller. So the first line is the function at the pc, then each frame:
;; the pc or return address in the function that built it.
(define (print-backtrace pc ra s0 s1)
  (declare unsafe)
  (unsafe
  (emit-str "backtrace:\n")
  (let ((f s0) (p pc) (i 0) (code (code-of pc s1)) (first nil))
    ;; The pc's own frame, or its island's function's, is named by the code
    ;; the pc is in.
    (if (if (frame-readable? f) (frame-built-by? f code) nil)
        (set! first code)
        (begin (emit-frame-line (%addr-of pc) code) (set! p ra)))
    (while (if (%< i backtrace-limit) (frame-readable? f) nil)
      (emit-frame-line (%addr-of p) (if first first (frame-code f)))
      (set! first nil)
      (set! p (%cap-ld f compiler::ra-slot))
      (set! f (%cap-ld f compiler::link-slot))
      (set! i (%+ i 1)))
    (if (frame-readable? f) (emit-str "  ...\n") nil))))

;; The saved pc is the capability PCC was, so its bounds are the code's.
(define (backtrace-from-context epc ctx)
  (declare unsafe)
  (unsafe
  (print-backtrace (%cap-set-addr (ctx-ref ctx reg-pc) epc)
                   (ctx-ref ctx reg-ra)
                   (ctx-ref ctx reg-s0)
                   (ctx-ref ctx reg-s1))))

;; One line for the fault, made by `what`, and the trace below it.
(define (fault-report epc ctx what)
  (declare unsafe)
  (unsafe
  (abort-to-repl ctx
    (compose-report
      (lambda ()
        (emit-str "\n*** ")
        (%funcall what)
        (emit-str ", at pc ")
        (emit-str (number->hex epc))
        (emit-str "\n")
        (backtrace-from-context epc ctx))))))

(define (fatal-trap cause epc tval ctx)
  (declare unsafe)
  (unsafe
  (abort-to-repl ctx
    (compose-report
      (lambda ()
        (emit-str "\n*** ")
        (emit-str (cause-name cause))
        (emit-str " at pc ")
        (emit-str (number->hex epc))
        (emit-str ", value ")
        (emit-str (number->hex tval))
        (emit-str "\n")
        (backtrace-from-context epc ctx))))))

;; ---------------------------------------------------------------- reports
;; A fault is reported by the task it happened in, once that task is back on
;; its feet, not by the trap handler. The handler runs with interrupts off:
;; it cannot wait, cannot take a lock, and a report goes to the task's own
;; output, which in a window is drawing. So the handler writes the report
;; into a string, and the restart prints it after it has unwound the task's
;; bindings, on its own stack, with interrupts on.
;;
;; The same move keeps a broken output from taking the machine down: if
;; printing the last report is what faulted, this one goes to the serial
;; line.
(define *printing-report* nil)   ; the task printing one, if any

(define (compose-report thunk)
  (declare unsafe)
  (let ((acc nil))
    (fluid-let ((*out* (lambda (c) (set! acc (%cons c acc)))))
      (%funcall thunk))
    (let ((s (list->string (reverse acc))))
      (if (if *printing-report* (%eq? *printing-report* (%this-task)) nil)
          (begin (set! *printing-report* nil) (uart-string s) nil)
          s))))

(define (print-report reports)
  (let ((r (if (%cons? reports) (%car reports) nil)))
    (if r
        (begin
          (set! *printing-report* (%this-task))
          (emit-str r)
          (set! *printing-report* nil))
        nil))
  nil)

;; ---------------------------------------------------------------- restart
;; An error abandons the stack it happened on. The restart is a return, not
;; a call: the interrupted context is rewritten to look as though the prompt
;; had just been entered on a clean stack, and the trap stub puts it back.
;; Starting a task does the same thing for the same reason.
(define *repl-restart* nil)

;; Two things sys.lisp cannot know because Exec is compiled after it: whose
;; stack to restart on, and what to do with a task that faults without a
;; prompt to go back to. Exec fills these in when it starts.
(define *stack-top-fn* nil)
(define *task-abort-fn* nil)
(define *return-addr-fn* nil)
;; Exec keeps state that an abort walks out of and has to put back: a switch
;; it owed, whether it is inside an interrupt server, the mutexes the task
;; held.
(define *abort-cleanup-fn* nil)
;; What a resumed image has to put back that is not memory: devices, and
;; whatever was running them. The workbench fills this in.
(define *resume-fn* nil)

;; What `error` calls once it has printed its message: a trap, so that the
;; rest happens where every other failure goes.
(define (error-trap args)
  (unsafe (%ecall ecall-error)))

;; A task restarts on its own stack, which is a capability standing at its
;; top. Before there are tasks, on the boot stack, which the kernel block
;; holds the same way.
(define (restart-stack)
  (declare unsafe)
  (unsafe
  (if *stack-top-fn*
      (%funcall *stack-top-fn*)
      (kernel-ref kb-boot-stack))))

;; Where a restarted closure returns to when it finally does: on the machine
;; the sentry for the task exit stub, so a prompt in a window that is
;; dismissed ends its task. Before there are tasks, NULL.
(define (restart-ra)
  (if *return-addr-fn* (%funcall *return-addr-fn*) 0))

;; A context that is to start in a closure starts here: one `jcl` that keeps
;; no link, which calls the closure in t0 as a tail call does, leaving it
;; the return address the context holds. So nothing has to open the closure
;; to start it; `jcl` does, as it does for every call. Made at the
;; kickstart, before anything can need it, and kept here, which keeps its
;; text; declared, not initialised, so that the boot list leaves it be.
(define *enter-stub*)

(define (build-enter-stub)
  (declare unsafe)
  (unsafe
  (let ((a (make-assembler)))
    (i-jcl a $zero $t0)
    (set! *enter-stub* (place a)))))

;; A call to a closure set up by hand in a context: the closure goes in t0,
;; still sealed, and the pc is the enter stub. The closure takes one
;; argument if one is given, the report of the fault that brought it here.
;; Nothing the abandoned code left in a register survives except the task in
;; s2 and its cons run in gp, and the NULL left in s0 is the bottom of the
;; new stack.
(define (enter-closure ctx f sp . arg)
  (declare unsafe)
  (unsafe
  (let ((r 1))
    (while (%< r 32)
      (if (if (%= r reg-gp) t (%= r reg-s2)) nil (ctx-set! ctx r 0))
      (set! r (%+ r 1)))
    (ctx-set! ctx reg-pc *enter-stub*)                         ; pc = the stub
    (ctx-set! ctx reg-t0 f)                                    ; t0 = the closure
    (if (%cons? arg)
        (begin (ctx-set! ctx reg-a0 (%car arg))                ; a0 = the argument
               (ctx-set! ctx reg-t1 1))                        ; t1 = one of them
        (ctx-set! ctx reg-t1 0))                               ; t1 = no arguments
    (ctx-set! ctx reg-sp sp)                                   ; a whole stack
    (ctx-set! ctx reg-ra (restart-ra))                         ; where it ends up
    (ctx-set! ctx reg-tp nil))                                 ; and nil, as ever
  nil))

;; Nothing is unwound: the stack the fault happened on is abandoned where it
;; stands, so the interrupt state is re-established rather than restored, or
;; an error inside `without-interrupts` would leave the machine deaf.
;;
;; An error inside the trap handler itself, in an interrupt server or in the
;; widening of an arithmetic trap, has no task to restart: the frame this
;; trap saved belongs to the handler, and the outer trap would never finish.
;; The machine stops and says so.
(define (abort-to-repl ctx . report)
  (declare unsafe)
  (unsafe
  (let ((r (if (%cons? report) (%car report) nil)))
    (if (%> (kernel-ref kb-depth) 1)
        (begin
          (uart-string "\n*** error inside the trap handler\n")
          (if r (uart-string r) nil)
          (%halt exit-error))
        nil)
    (%enable-after-trap)
    (if *abort-cleanup-fn* (%funcall *abort-cleanup-fn*) nil)
    (cond (*repl-restart* (enter-closure ctx *repl-restart* (restart-stack) r))
          ;; A task with no prompt behind it stops being a task.
          (*task-abort-fn* (enter-closure ctx *task-abort-fn* (restart-stack) r))
          (else (if r (uart-string r) nil)
                (uart-string "no prompt to return to; halting\n")
                (%halt exit-error))))))

;; ---------------------------------------------------------------- eval
;; There is no interpreter on the machine. A form is compiled to native code
;; as the body of a function of no arguments, and called.
(define (eval-thunk form)
  (let ((clo (unsafe
              (let ((r (compile-function nil (list form) 'repl nil)))
                (%cap-seal-closure (make-closure (%cdr r) 0))))))
    (%funcall clo)))

;; A top level form is normally run. During a rebuild it is also compiled
;; onto the boot list of the image being made; during genesis it only goes
;; on the boot list, because this machine has already run it, in the rebuild
;; before.
(define *recording* nil)

(define (top-level-form form)
  (cond (*image* (add-boot-thunk form))
        (*recording* (%funcall (add-boot-thunk form)))
        (else (eval-thunk form))))

;; compile-top has already given the variable its value; this is so that the
;; image being built gives it that value again when it boots.
(define (record-initialiser form)
  (if (if *recording* t *image*) (add-boot-thunk form) nil))

(define (register-macro form) nil)

;; ---------------------------------------------------------------- rebuild
;; The machine compiling its own successor. Source arrives on the console;
;; every form is compiled into a fresh boot list until the sentinel, and then
;; the image can be written out. The compiler being recompiled is the
;; compiler doing the compiling, and calls go through symbol value cells, so
;; the new one takes over partway through and finishes the job.
(define (rebuild)
  ;; Preemption stays off until the image this writes boots: the sources
  ;; going past redefine the kernel a timer interrupt would need.
  (preemption-off)
  ;; Output goes to the raw serial line for the whole rebuild: the console
  ;; stream hands a line to the console driver and waits for the answer, and
  ;; a rebuild is redefining the kernel that waiting depends on. Input keeps
  ;; coming from the stream, which is put back before every form, because
  ;; compiling stream.lisp resets `*in*`.
  (set! *out* nil)
  (set! *boot-thunks* nil)
  (set! *recording* t)
  (let ((in *in*) (await *await*) (go t) (n 0))
    (while go
      (set! *in* in)
      (set! *await* await)
      (set! *out* nil)
      (let ((form (read-toplevel)))
        (if (%eq? form 'rebuild-end)
            (set! go nil)
            (begin (compile-top form) (set! n (%+ n 1))))))
    (set! *recording* nil)
    (emit-str "rebuilt ")
    (emit-str (number->string n))
    (emit-str " forms\n")
    n))

;; ---------------------------------------------------------------- genesis
;; The second half of a fresh rebuild. `rebuild` has just compiled the
;; sources into this machine, so the compiler, the macros and whatever a
;; compile-time evaluation calls are the new ones. Now the same sources go
;; through a second time, and every definition is kept for the image instead
;; of being installed here; see `*image*` in compile.lisp. The image is
;; compiled entirely by the new compiler and holds nothing this machine had
;; before.
;;
;; The names the sources use are noted as they are read, so that the image
;; keeps exactly those symbols. `snap:save-fresh` does the rest, from what
;; this leaves in `*fresh-image*`: the table, the names, and the boot list.
(define *fresh-image* nil)
(define *genesis-trace* nil)

(define (genesis)
  (set! *out* nil)
  (set! *boot-thunks* nil)
  (set! *names-seen* (make-table))
  (set! *image* (make-table))
  (let ((go t) (n 0))
    (while go
      (let ((form (read-toplevel)))
        ;; A file's `in-package` has to take effect before the next form is
        ;; read. `rebuild` runs every top level form as it goes; this only
        ;; records them, so it acts on the package forms itself.
        (act-on-package-form form)
        (if *genesis-trace*
            (begin
              (write (if (%cons? form) (if (%cons? (%cdr form)) (cadr form) form) form))
              (emit-str "\n"))
            nil)
        (if (%eq? form 'rebuild-end)
            (set! go nil)
            (begin (compile-top form) (set! n (%+ n 1))))))
    (set! *fresh-image* (list *image* *names-seen* (reverse *boot-thunks*)))
    (set! *image* nil)
    (set! *names-seen* nil)
    (emit-str "compiled ")
    (emit-str (number->string n))
    (emit-str " forms for a fresh image\n")
    n))

(define (eval form) (compile-top form))

;; What `compile-top` uses to work out the value of a top level variable
;; while it is compiling: on the machine, compiling and running it.
(define (compile-time-eval form) (eval-thunk form))

;; On the machine a macro is a symbol with the macro bit of its flags set,
;; whose function cell holds the compiled expander. The function slot holds
;; either an expander or the compiler's note of how to open-code a call, and
;; the bit tells them apart.
(define (macro-symbol? s)
  (if (%symbol? s)
      (if (%= sym-macro (%logand sym-macro (%symbol-flags s)))
          (%symbol-function s)
          nil)
      nil))

(define (macro-form? form)
  (if (%cons? form)
      (if (%symbol? (%car form)) (if (macro-symbol? (%car form)) t nil) nil)
      nil))

;; The expander takes the form's arguments as one list.
(define (expand-macro form)
  (let ((m (macro-symbol? (%car form))))
    (if m (%funcall m (%cdr form)) form)))

;; ---------------------------------------------------------------- repl
;; Where the bindings stand here is what an error unwinds to: the prompt's
;; own streams and package survive it, and whatever the form that failed had
;; bound on top of them does not. `then` runs when the prompt says goodbye,
;; however it got there: after an error the prompt runs on as the restart.
(define (repl . then)
  (let ((mark (task-binds))
        (done (if (%cons? then) (%car then) nil)))
    (set! *repl-restart*
          (lambda report
            (unwind-binds-to! mark)
            (print-report report)
            (repl-loop)
            (if done (%funcall done) nil)))
    (repl-loop)
    (if done (%funcall done) nil)))

;; Swallow the newline the reader stopped short of, so that what the form
;; prints starts on a line of its own. Never blocks: if the character has not
;; arrived, the next read skips it as whitespace.
(define (finish-line)
  (let ((c (read-char-or-nil)) (go t))
    (while go
      (cond ((%null? c) (set! go nil))
            ((%eq? c #\newline) (set! go nil))
            ((char-whitespace? c) (set! c (read-char-or-nil)))
            (else (set! *peeked* c) (set! go nil))))
    nil))

(define (repl-loop)
  (let ((go t))
    (while go
      (emit-str "\n> ")
      (let ((form (read-toplevel)))
        (finish-line)
        (if (%eq? form 'bye)
            (begin (emit-str "\n") (set! go nil))
            (let ((v (eval form)))
              (emit-str "\n")
              (write v)))))
    nil))

;; ---------------------------------------------------------------- kickstart
;; The forge left a thunk for every top level form that was not a function
;; definition, in source order. Declared, not initialised: a `(define ...
;; nil)` would put on the boot list a `(set! ... nil)` that emptied it.
(define *boot-list*)

;; Run before the first prompt, if it is set.
(define *startup* nil)

(define (run-boot-list)
  (let ((l *boot-list*))
    (while (%cons? l)
      (%funcall (%car l))
      (set! l (%cdr l)))))

(define (kickstart)
  (declare unsafe)
  (unsafe
  ;; The allocator first: the first thing the boot list does is allocate.
  (install-allocator)
  ;; The object-start map is scratch memory, which no image carries: built
  ;; here, while nothing waits on interrupts, rather than in the first
  ;; collection's start, which would hold them off for the whole walk.
  (ensure-starts)
  (build-enter-stub)
  (kernel-set! kb-trap-hook (%symbol-value 'handle-trap))
  (set! *error-handler* (%symbol-value 'error-trap))
  (run-boot-list)
  ;; Exec comes up before anything can want a task: the code already running
  ;; becomes task zero, and its context is the trap frame the stub has been
  ;; saving into since the machine started.
  (exec-init)
  (exec-start)
  (banner)
  (banner-exec)
  (emit-str "type (help) for what to try\n")
  (if *startup* (%funcall *startup*) nil)
  ;; A prompt starts in user, whatever package the boot list left the reader
  ;; in.
  (set-current-package! (make-package "user"))
  ;; The first prompt is the machine's own: when it says goodbye, so does the
  ;; machine. One in a window is a task, and only ends its task.
  (repl (lambda () (%halt exit-ok)))
  (%halt exit-ok)
  0))

;; This sets a context's registers.
