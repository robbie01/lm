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
  (emit-str (number->string (%lsh (%- cons-limit cons-base) -13)))
  (emit-str "k pairs, object space ")
  (emit-str (number->string (%lsh (%- obj-limit obj-base) -10)))
  (emit-str "k, code ")
  (emit-str (number->string (%lsh (%- (%ld-fixnum lg-code-ptr) code-base) -10)))
  (emit-str "k used\n")
  nil)

(define (banner-exec)
  (emit-str "exec: ")
  (emit-str (number->string (task-count)))
  (emit-str (if (%= (task-count) 1) " task" " tasks"))
  (newline))

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
        ((%= c cause-stack) "stack overflow")
        (else "trap")))

;; The trap stub hands over the cause with the interrupt flag moved from bit
;; 31 down to bit 6, because bit 31 does not fit in a fixnum.
(define cause-interrupt-bit 64)
(define (interrupt? c) (%>= c cause-interrupt-bit))
(define (interrupt-number c) (%logand c 31))

;; How deep traps may nest before the handler is taken to be faulting in a
;; loop. The stub has this many frames for traps inside traps: `trap-nest-max`
;; in boot.lisp, which is not in the image.
(define trap-nest-limit 8)

(define (trap-spiral cause epc tval)
  (uart-string "\n*** the trap handler is faulting in a loop: ")
  (uart-string (cause-name cause))
  (uart-string " at pc ")
  (uart-hex epc)
  (uart-string ", value ")
  (uart-hex tval)
  (uart-nl)
  (%halt exit-trap-spiral))

(define (handle-trap cause epc tval ctx)
  (if (%>= (%ld-fixnum lg-trapdepth) trap-nest-limit) (trap-spiral cause epc tval) nil)
  (if (interrupt? cause)
      (handle-interrupt (interrupt-number cause) ctx)
      (cond ((%= cause cause-ecall) (handle-ecall epc ctx))
            ((%= cause cause-wrong-type)
             (if (try-widen epc ctx) nil (check-trap cause epc tval ctx)))
            ((%= cause cause-range) (check-trap cause epc tval ctx))
            ((%= cause cause-overflow)
             (if (try-widen epc ctx) nil (check-trap cause epc tval ctx)))
            ((%= cause cause-divzero) (check-trap cause epc tval ctx))
            (else (fatal-trap cause epc tval ctx))))
  (keep-cons-run ctx))

;; The handler conses out of the cons run of the task it interrupted, and the
;; stub restores the gp and tp it saved on the way in. So the run goes back
;; into the frame as the handler left it, or the task would hand out the
;; handler's pairs a second time. That frame is `ctx` whatever else happened
;; here: a task switch points mscratch at the next task's frame and leaves
;; this one to be resumed later, with this run.
(define (keep-cons-run ctx)
  (%sync-cons-run)
  (%st-word! (ctx-reg ctx reg-gp) (%ld-word lg-cons-run))
  (%st-word! (ctx-reg ctx reg-tp) (%ld-word lg-cons-run-end))
  nil)

;; ------------------------- the instructions that check their operands
;; car, cdr and their setters check a tag; the indexed accesses check a tag,
;; a type and a bound; the fixnum instructions check both operands. The
;; report says which operation it was and what it was handed: the instruction
;; is at the saved pc, and every register it named is in the saved context.
(define (insn-f3 w)  (%logand (%lsh w -12) 7))
(define (insn-f7 w)  (%logand (%lsh w -25) 127))
(define (insn-rs1 w) (%logand (%lsh w -15) 31))
(define (insn-rs2 w) (%logand (%lsh w -20) 31))
(define (insn-op w)  (%logand w 127))
(define (insn-rd w)  (%logand (%lsh w -7) 31))

;; The stub narrows mtval to thirty bits so it survives as a fixnum. Every
;; address fits, and so does any fixnum small enough to be worth printing;
;; the rest come back as a word.
(define (emit-value w)
  (let ((tag (%logand w 7)))
    (cond ((%= w 0) (emit-str "nil"))
          ((%= (%logand w 1) 1)
           (let ((v (%ash w -1)))
             (emit-str (number->string (if (%>= v 268435456)
                                           (%- v 536870912)
                                           v)))))
          ((%= tag 2) (write (%from-addr w)))
          ((and (%= tag 4) (%>= w obj-base) (%< w obj-limit))
           (write (%from-addr w)))
          (else (emit-str (number->hex w))))))

;; A value the handler is about to print may be a word that only looks like
;; a pointer, so it is checked before the printer is allowed near it.
(define (safe-object? v)
  (if (%object? v)
      (if (%>= (%addr-of v) obj-base) (%< (%addr-of v) obj-limit) nil)
      nil))

(define (emit-a-or-an sym)
  (if (%symbol? sym)
      (begin
        (emit-str (if (if (%> (%string-length (%symbol-name sym)) 0)
                          (string-index "aeiou" (%string-ref (%symbol-name sym) 0))
                          nil)
                      "an "
                      "a "))
        (emit-str (%symbol-name sym)))
      (emit-object sym)))

(define (emit-object v)
  (if (safe-object? v) (write v) (emit-value (%addr-of v))))

(define (emit-type-name ty)
  (cond ((%= ty t-vector) (emit-str "a vector"))
        ((%= ty t-string) (emit-str "a string"))
        ((%= ty t-bytes) (emit-str "a byte vector"))
        ((%= ty t-symbol) (emit-str "a symbol"))
        ((%= ty t-closure) (emit-str "a function"))
        ((%= ty t-record) (emit-str "a record"))
        ((%= ty t-code) (emit-str "a code object"))
        ((%= ty t-bignum) (emit-str "a bignum"))
        (else (emit-str "an object"))))

;; custom-0 is one load and one store, so which operation it was is the
;; offset: car is slot 0 and cdr is slot 4 of the same instruction. Anything
;; else is a slot access the compiler generated. Only the low bits of the
;; offset are read, because the instruction word arrives through
;; `%ld-fixnum`, which drops bit 31.
(define (insn-imm-i w) (%logand (%lsh w -20) 2047))
(define (insn-imm-s w) (%logand (%lsh w -7) 31))

(define (emit-pair-op w)
  (let ((f (insn-f3 w)))
    (if (%= (%logand f 4) 4)
        (let ((o (insn-imm-s w)))
          (cond ((%= f 5) (emit-str "set-slot!"))
                ((%= o 0) (emit-str "set-car!"))
                ((%= o 4) (emit-str "set-cdr!"))
                (else (emit-str "set-slot!"))))
        (let ((o (insn-imm-i w)))
          (cond ((%= f 1) (emit-str "slot"))
                ((%= o 0) (emit-str "car"))
                ((%= o 4) (emit-str "cdr"))
                (else (emit-str "slot")))))))

(define (emit-index-op ty f)
  (cond ((%= ty t-closure) (emit-str "call"))
        ((%= ty t-vector) (emit-str (if (%= f 0) "vector-ref" "vector-set!")))
        ((%= ty t-string) (emit-str (if (%= f 2) "string-ref" "string-set!")))
        ((%= ty t-bytes)  (emit-str (if (%= f 2) "bytes-ref" "bytes-set!")))
        (else (emit-str (if (%= (%logand f 1) 1) "set-slot!" "slot")))))

;; nil reads as a pair of nils but has no cell to write to, so the store
;; side rejects it and gets its own sentence.
(define (emit-pair-fault w tval)
  (emit-pair-op w)
  (cond
   ((%= (%logand (insn-f3 w) 1) 1)
    (emit-str ": expected an object, got ") (emit-value tval))
   ((%= tval 0) (emit-str ": nil has no cell to write"))
   (else (emit-str ": expected a pair, got ") (emit-value tval))))

;; Both operands are still in the registers the instruction named, so the
;; report can say what was indexed as well as what with. The immediate form
;; keeps the index in the instruction, where the rs2 field is the index
;; itself.
(define (emit-index-fault w ctx)
  (let* ((ty (insn-f7 w))
         (f (insn-f3 w))
         (obj (trap-raw ctx (insn-rs1 w)))
         (idx (if (%= 4 (%logand f 4))
                  (insn-rs2 w)
                  (trap-raw ctx (insn-rs2 w)))))
    (emit-index-op ty (%logand f 3))
    (cond
     ;; Calling a name nothing was ever stored in: the value is the unbound
     ;; marker, an immediate.
     ((if (%= ty t-closure) (%eq? obj *unbound*) nil)
      (emit-str ": undefined function"))
     ((not (safe-object? obj))
      (emit-str ": expected ") (emit-type-name ty)
      (emit-str ", got ") (emit-value (%addr-of obj)))
     ;; `call` is the entry-point load the call sequence does, and reaching
     ;; here means the thing being called was an object of the wrong sort.
     ((%= ty t-closure)
      (emit-str ": expected a function, got ") (emit-object obj))
     ((if (%> ty 0) (not (%= (%obj-type obj) ty)) nil)
      (emit-str ": expected ") (emit-type-name ty)
      (emit-str ", got ") (emit-object obj))
     ((not (%fixnum? idx))
      (emit-str ": index is not a number, it is ") (emit-value (%addr-of idx)))
     (else
      (emit-str ": index ") (emit-str (number->string idx))
      (emit-str " is outside ") (emit-type-name ty)
      (emit-str " of ") (emit-str (number->string (%obj-len obj)))))))

;; Which arithmetic instruction this was, said the way the source says it.
;; The register forms are custom-2, in two banks by funct7; the forms with a
;; constant are custom-3, which also carries the two tagged memory accesses.
(define (fixnum-op-name w)
  (let ((f (insn-f3 w)))
    (if (%= (insn-f7 w) 1)
        (cond ((%= f 0) "ash") ((%= f 1) "lsh") ((%= f 2) "ash")
              ((%= f 5) "=") (else "<"))
        (cond ((%= f 0) "+") ((%= f 1) "-") ((%= f 2) "*") ((%= f 3) "/")
              ((%= f 4) "rem") ((%= f 5) "logand") ((%= f 6) "logior")
              (else "logxor")))))

(define (tagged-op-name w)
  (let ((f (insn-f3 w)))
    (cond ((%= f 0) "+") ((%= f 1) "logand") ((%= f 2) "logior")
          ((%= f 3) "ash") ((%= f 4) "peek") ((%= f 5) "peek8")
          ((%= f 6) "poke") (else "poke8"))))

;; `try-widen` has already had its chance, so a bignum reaching here means
;; this operator has no bignum form, not that the operand was the wrong kind
;; of thing.
(define (emit-arith-fault name cause tval)
  (emit-str name)
  (cond
   ((%= cause cause-divzero) (emit-str ": division by zero"))
   ((%= cause cause-overflow)
    (emit-str ": the result does not fit in a fixnum"))
   ((%bignum? (%from-addr tval))
    (emit-str ": no bignum form, given ") (emit-value tval))
   (else (emit-str ": expected a number, got ") (emit-value tval))))

;; ---------------------------------------------------------------- widening
;; Overflow and mixed-mode arithmetic both arrive as traps, and neither is an
;; error. `+`, `-` and `*` emit the trapping forms of the fixnum instructions,
;; and every fixnum instruction refuses an operand that is not one, so a sum
;; that outgrows 31 bits and a sum with a bignum in it both stop here, and
;; both are the same operation done in a width that fits.
;;
;; Only the one instruction is emulated. A comparison writes a raw zero or
;; one and the instructions after it turn that into `t` or `nil`; an
;; arithmetic instruction writes a tagged value. The trap returns to the
;; instruction after this one and the rest of the sequence runs as compiled.
;;
;; A trap costs around ten times what the allocation inside it costs, so the
;; fast path is one instruction that asks nothing.
(defsubst (widenable? v) (if (%fixnum? v) t (%bignum? v)))

(define (widen-arith w epc ctx x y)
  (let ((rd (insn-rd w))
        (f3 (insn-f3 w))
        (f7 (insn-f7 w))
        (ok t))
    (if (%= f7 1)
        ;; the compare group: `flt` and `feq` leave a raw flag behind
        (cond ((%= f3 3) (%st-fixnum! (ctx-reg ctx rd)
                                      (if (%< (generic-cmp x y) 0) 1 0)))
              ((%= f3 5) (%st-fixnum! (ctx-reg ctx rd)
                                      (if (%= (generic-cmp x y) 0) 1 0)))
              (else (set! ok nil)))
        (cond ((%= f3 0) (%st-word! (ctx-reg ctx rd) (generic-add x y)))
              ((%= f3 1) (%st-word! (ctx-reg ctx rd) (generic-sub x y)))
              ((%= f3 2) (%st-word! (ctx-reg ctx rd) (generic-mul x y)))
              ((%= f3 3) (%st-word! (ctx-reg ctx rd) (generic-quotient x y)))
              ((%= f3 4) (%st-word! (ctx-reg ctx rd) (generic-remainder x y)))
              (else (set! ok nil))))
    ;; Stepping the saved pc is what makes the trap resume after the
    ;; instruction rather than run it again.
    (if ok (%st-fixnum! ctx (%+ epc 4)) nil)
    ok))

(define (try-widen epc ctx)
  (let ((w (%ld-fixnum epc)))
    (if (%= (insn-op w) op-fixnum)
        (let ((rd (insn-rd w))
              (x (trap-raw ctx (insn-rs1 w)))
              (y (trap-raw ctx (insn-rs2 w))))
          ;; Slot zero of the context is the saved pc, not register x0, so an
          ;; instruction that writes x0 has nowhere to put an answer. The
          ;; compiler emits none; this keeps a corrupt word read as an
          ;; instruction from scribbling on the return address.
          (if (%= rd 0)
              nil
              (if (if (widenable? x) (widenable? y) nil)
                  (widen-arith w epc ctx x y)
                  nil)))
        nil)))

(define (check-trap cause epc tval ctx)
  (abort-to-repl ctx
    (compose-report
      (lambda ()
        (let ((w (%ld-fixnum epc)))
          (emit-str "\n*** ")
          (cond
           ((%= (insn-op w) op-index) (emit-index-fault w ctx))
           ((%= (insn-op w) op-fixnum)
            (emit-arith-fault (fixnum-op-name w) cause tval))
           ((%= (insn-op w) op-tagged)
            (emit-arith-fault (tagged-op-name w) cause tval))
           (else (emit-pair-fault w tval)))
          (emit-str ", at pc ")
          (emit-str (number->hex epc))
          (emit-str "\n")
          (backtrace-from-context epc ctx))))))

;; The compiler emits `ecall` for the conditions it detects inline, with the
;; reason in a7. The saved pc is stepped over the instruction first: the stub
;; reloads mepc from the context on its way out.
(define (handle-ecall epc ctx)
  (%st-fixnum! ctx (%+ epc 4))
  (let ((code (trap-reg ctx reg-a7)))
    (if (%= code ecall-reschedule)
        ;; A task asking to be switched out. Returning from here resumes
        ;; whichever task the scheduler picked.
        (switch-tasks)
        (abort-to-repl ctx
         (compose-report
          (lambda ()
          (cond
           ((%= code ecall-arity)
            ;; t0 still holds the closure that was about to be entered and t1
            ;; the count it was handed.
            (emit-str "\ncalled ")
            (emit-callee (trap-raw ctx reg-t0))
            (let ((n (trap-reg ctx reg-t1)))
              (emit-str " with ")
              (emit-str (number->string n))
              (emit-str (if (%= n 1) " argument" " arguments")))
            (emit-str ", at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code ecall-record)
            ;; A record accessor was handed the wrong kind of record. It left
            ;; the tag it wanted in t3 and what it was given in a0.
            (emit-str "\nexpected ")
            (emit-a-or-an (trap-raw ctx reg-t3))
            (emit-str ", got ")
            (emit-object (trap-raw ctx reg-a0))
            (emit-str ", at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code ecall-oom)
            (emit-str "\nout of memory at ") (emit-str (number->hex epc)) (emit-str "\n"))
           ;; `error` has already said what went wrong. What is left is
           ;; where, and the restart.
           ((%= code ecall-error) nil)
           (else (emit-str "\nunknown ecall\n")))
          ;; The arity check is in the callee's prologue, before it has
          ;; loaded its own code object, so s0 and s1 still describe the
          ;; caller. Starting the walk at the return address makes the first
          ;; line name the call site.
          (if (%= code ecall-arity)
              (backtrace-from-context (trap-reg ctx reg-ra) ctx)
              (backtrace-from-context epc ctx))))))))

;; ---------------------------------------------------------------- backtrace
;; Every prologue saves its caller's frame base at s0-8 and its caller's code
;; object, which carries the name, at s0-16. So a backtrace needs no side
;; table: the words that make a frame make the trace.
(define backtrace-limit 24)

;; The closure a call was about to enter.
(define (emit-callee f)
  (if (%closure? f) (emit-code-label (%slot f clo-code)) (emit-str "a non-function")))

(define (print-backtrace s0 code pc)
  (emit-str "backtrace:\n")
  (let ((f s0) (c code) (p pc) (i 0) (go t))
    (while (if go (if (%< i backtrace-limit) (frame-ok? f) nil) nil)
      (emit-str "  ")
      (emit-code-label c)
      (emit-str " at ")
      (emit-str (number->hex p))
      (emit-str "\n")
      (let ((ra (%ld-fixnum (%- f 4))))
        ;; The allocator's refill stub sits between two Lisp frames without a
        ;; frame of its own, so the chain steps over it.
        (if (in-stub? ra) (emit-str "  (allocating)\n") nil)
        (set! p ra))
      (set! c (%ld-word (%- f 16)))
      (set! f (%ld-fixnum (%- f 8)))
      (set! i (%+ i 1)))
    (if (if go (frame-ok? f) nil) (emit-str "  ...\n") nil)))

;; The registers a trap saved. Word 0 of the block is the pc and words 1..31
;; are x1..x31; `reg-<name>` for each comes from the generated layout.
(define (ctx-pc c) c)
(define (ctx-reg c n) (%+ c (%* 4 n)))

(define (trap-reg ctx n) (%ld-fixnum (ctx-reg ctx n)))
(define (trap-raw ctx n) (%ld-word (ctx-reg ctx n)))

(define (backtrace-from-context epc ctx)
  (print-backtrace (trap-reg ctx reg-s0) (trap-raw ctx reg-s1) epc))

(define (fatal-trap cause epc tval ctx)
  (abort-to-repl ctx
    (compose-report
      (lambda ()
        (emit-str "\n*** ")
        (emit-str (cause-name cause))
        (emit-str " at pc ")
        (emit-str (number->hex epc))
        (emit-str ", value ")
        (emit-str (number->hex tval))
        ;; The machine refuses any store into its first eight bytes, which
        ;; are what car and cdr of nil read.
        (if (if (%= cause cause-store-fault) (%< tval 8) nil)
            (emit-str ", which is nil's cell")
            nil)
        (emit-str "\n")
        (backtrace-from-context epc ctx)))))

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
(define (error-trap args) (%ecall ecall-error))

;; A task restarts on its own stack. Before there are tasks, on the boot
;; stack.
(define (restart-stack)
  (if *stack-top-fn* (%funcall *stack-top-fn*) (%ld-fixnum lg-stacktop)))

;; Where a restarted closure returns to when it finally does: on the machine
;; the task exit stub, so a prompt in a window that is dismissed ends its
;; task.
(define (restart-ra)
  (if *return-addr-fn* (%funcall *return-addr-fn*) 0))

;; The closure is entered with one argument, if one is given: the report of
;; the fault that brought it here.
(define (enter-closure ctx f sp . arg)
  (%st-fixnum! (ctx-reg ctx reg-zero) (%ld-fixnum (%addr-of f)))  ; pc = its entry
  (%st-word! (ctx-reg ctx reg-t0) f)                   ; t0 = the closure
  (if (%cons? arg)
      (begin (%st-word! (ctx-reg ctx reg-a0) (%car arg))    ; a0 = the argument
             (%st-fixnum! (ctx-reg ctx reg-t1) 1))          ; t1 = one of them
      (%st-fixnum! (ctx-reg ctx reg-t1) 0))                 ; t1 = no arguments
  (%st-fixnum! (ctx-reg ctx reg-sp) sp)                    ; a whole stack
  (%st-fixnum! (ctx-reg ctx reg-ra) (restart-ra))          ; where it ends up
  (%st-fixnum! (ctx-reg ctx reg-s0) 0)                     ; and no caller
  nil)

;; Nothing is unwound: the stack the fault happened on is abandoned where it
;; stands, so the interrupt state is re-established rather than restored, or
;; an error inside `without-interrupts` would leave the machine deaf.
;;
;; An error inside the trap handler itself, in an interrupt server or in the
;; widening of an arithmetic trap, has no task to restart: the frame this
;; trap saved belongs to the handler, and the outer trap would never finish.
;; The machine stops and says so.
(define (abort-to-repl ctx . report)
  (let ((r (if (%cons? report) (%car report) nil)))
    (if (%> (%ld-fixnum lg-trapdepth) 1)
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
                (%halt exit-error)))))

;; ---------------------------------------------------------------- eval
;; There is no interpreter on the machine. A form is compiled to native code
;; as the body of a function of no arguments, and called.
(define (eval-thunk form)
  (let* ((r (compile-function nil (list form) 'repl nil))
         (clo (make-closure (%cdr r) 0)))
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
(define (record-initialiser name expr)
  (if (if *recording* t *image*) (add-boot-thunk (list 'set! name expr)) nil))

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
(define *repl-depth* 0)

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
;; definition, in source order.
(define (run-boot-list)
  (let ((l (%ld-word lg-bootlist)))
    (while (%cons? l)
      (%funcall (%car l))
      (set! l (%cdr l)))))

(define (kickstart)
  ;; The allocator first: the first thing the boot list does is allocate.
  (install-allocator)
  (%st-word! lg-traphook (%symbol-value 'handle-trap))
  (%st-word! lg-errhandler (%symbol-value 'error-trap))
  (run-boot-list)
  ;; Exec comes up before anything can want a task: the code already running
  ;; becomes task zero, and its context is the trap frame the stub has been
  ;; saving into since the machine started.
  (exec-init)
  (exec-start)
  (banner)
  (banner-exec)
  (emit-str "type (help) for what to try\n")
  (if (%ld-word lg-startup)
      (%funcall (%ld-word lg-startup))
      nil)
  ;; A prompt starts in user, whatever package the boot list left the reader
  ;; in.
  (set-current-package! (make-package "user"))
  ;; The first prompt is the machine's own: when it says goodbye, so does the
  ;; machine. One in a window is a task, and only ends its task.
  (repl (lambda () (%halt exit-ok)))
  (%halt exit-ok)
  0)
