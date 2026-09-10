;;; sys.lisp - the kickstart proper: what the machine does when it wakes up.

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
  (emit-str (number->string (%lsh (%- (%global lg-code-ptr) code-base) -10)))
  (emit-str "k used\n")
  nil)

(define (banner-exec)
  (emit-str "exec: ")
  (emit-str (number->string (task-count)))
  (emit-str " task")
  (newline))

;; ---------------------------------------------------------------- traps
;; Everything that goes wrong arrives here, along with every interrupt.
(define trap-arity 1)
(define trap-type 2)
(define trap-oom 3)
(define trap-error 4)
(define trap-reschedule 5)
(define trap-record 6)

(define cause-wrong-type 24)
(define cause-range 25)
(define cause-overflow 26)
(define cause-divzero 27)

(define (cause-name c)
  (cond ((%= c 0) "misaligned fetch")
        ((%= c 1) "instruction access fault")
        ((%= c 2) "illegal instruction")
        ((%= c 3) "breakpoint")
        ((%= c 4) "misaligned load")
        ((%= c 5) "load access fault")
        ((%= c 6) "misaligned store")
        ((%= c 7) "store access fault")
        ((%= c 11) "ecall")
        ((%= c cause-wrong-type) "wrong type")
        ((%= c cause-range) "index out of range")
        ((%= c cause-overflow) "fixnum overflow")
        ((%= c cause-divzero) "division by zero")
        (else "trap")))

;; The trap stub hands over the cause with the interrupt flag moved from bit
;; 31 down to bit 6, because bit 31 does not fit in a fixnum.
(define cause-interrupt-bit 64)
(define (interrupt? c) (%>= c cause-interrupt-bit))
(define (interrupt-number c) (%logand c 31))

(define int-software 3)
(define int-timer 7)
(define int-external 11)

(define (handle-trap cause epc tval ctx)
  (if (interrupt? cause)
      (handle-interrupt (interrupt-number cause) ctx)
      (cond ((%= cause 11) (handle-ecall epc ctx))
            ((%= cause cause-wrong-type) (check-trap cause epc tval ctx))
            ((%= cause cause-range) (check-trap cause epc tval ctx))
            ((%= cause cause-overflow) (check-trap cause epc tval ctx))
            ((%= cause cause-divzero) (check-trap cause epc tval ctx))
            (else (fatal-trap cause epc tval ctx)))))

;; ------------------------- the instructions that check their operands
;; car, cdr and their setters check a tag; the indexed accesses check a tag, a
;; type, and a bound. Both trap here, and the interesting part of the report is
;; not the address but which operation it was and what it was handed - all of
;; which can be read back out: the instruction is at the saved pc, and every
;; register it named is in the saved context.
(define (insn-f3 w)  (%logand (%lsh w -12) 7))
(define (insn-f7 w)  (%logand (%lsh w -25) 127))
(define (insn-rs1 w) (%logand (%lsh w -15) 31))
(define (insn-rs2 w) (%logand (%lsh w -20) 31))
(define (insn-op w)  (%logand w 127))

;; The stub narrows mtval to thirty bits so it survives as a fixnum. Every
;; address in this machine fits, and so does any fixnum small enough to be
;; worth printing; the rest come back as a word.
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

;; A value the handler is about to print may be anything at all, including a
;; word that only looks like a pointer, so it is checked before the printer
;; is allowed near it.
(define (safe-object? v)
  (if (%object? v)
      (if (%>= (%addr-of v) obj-base) (%< (%addr-of v) obj-limit) nil)
      nil))

;; "a window", "an interrupt": the report reads as a sentence either way.
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
        (else (emit-str "an object"))))

;; custom-0 is one load and one store now, so which operation it was is the
;; offset rather than the funct3: car is slot 0 and cdr is slot 4 of the same
;; instruction. Anything else is a slot access the compiler generated.
;; Only the low bits of the offset, because the instruction word arrives here
;; through `peek`, which loses bit 31 making it a fixnum. That is enough to
;; tell slot 0 from slot 4, which is all this is for.
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

(define (emit-pair-fault w tval)
  (emit-pair-op w)
  ;; nil reads as a pair of nils but has no cell to write to, so the store
  ;; side rejects it and deserves its own sentence.
  (cond
   ((%= (%logand (insn-f3 w) 1) 1)
    (emit-str ": expected an object, got ") (emit-value tval))
   ((%= tval 0) (emit-str ": nil has no cell to write"))
   (else (emit-str ": expected a pair, got ") (emit-value tval))))

(define (emit-index-fault w ctx)
  ;; Both operands are still in the registers the instruction named, so the
  ;; report can say what was indexed as well as what with - except that the
  ;; immediate form keeps the index in the instruction, where the rs2 field
  ;; is the index itself rather than the number of a register holding it.
  (let* ((ty (insn-f7 w))
         (f (insn-f3 w))
         (obj (%raw-ld (%+ ctx (ctx-word (insn-rs1 w)))))
         (idx (if (%= 4 (%logand f 4))
                  (insn-rs2 w)
                  (%raw-ld (%+ ctx (ctx-word (insn-rs2 w)))))))
    (emit-index-op ty (%logand f 3))
    (cond
     ;; Calling a name nothing was ever stored in. The value is the unbound
     ;; marker, which is an immediate and would otherwise be reported by the
     ;; branch below as the meaningless `#<immediate>`.
     ((if (%= ty t-closure) (%eq? obj *unbound*) nil)
      (emit-str ": undefined function"))
     ((not (safe-object? obj))
      (emit-str ": expected ") (emit-type-name ty)
      (emit-str ", got ") (emit-value (%addr-of obj)))
     ;; `call` is the one of these the programmer did not write: it is the
     ;; entry-point load the call sequence does, and reaching here means the
     ;; thing being called was an object of the wrong sort.
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
;; The register forms are custom-2 and split into two banks by funct7; the
;; forms with a constant are custom-3, which also carries the two tagged
;; address accesses that peek and poke compile to.
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

(define (emit-arith-fault name cause tval)
  (emit-str name)
  (cond
   ((%= cause cause-divzero) (emit-str ": division by zero"))
   ((%= cause cause-overflow)
    (emit-str ": the result does not fit in a fixnum"))
   (else (emit-str ": expected a number, got ") (emit-value tval))))

(define (check-trap cause epc tval ctx)
  (let ((w (%ld32 epc)))
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
    (backtrace-from-context epc ctx)
    (abort-to-repl ctx)))

;; The compiler emits `ecall` for the handful of conditions it detects inline,
;; with the reason in a7. Resuming past it means stepping mepc over the
;; instruction, which is why the handler is handed the saved context.
(define (handle-ecall epc ctx)
  ;; Step the saved pc over the ecall first: the stub reloads mepc from the
  ;; context on its way out, so this is what makes the trap return to the
  ;; instruction after it rather than run it again.
  (%st32! ctx (%+ epc 4))
  ;; a7 holds the reason. %ld32 already yields it as a number.
  (let ((code (%ld32 (%+ ctx (%* 4 17)))))
    (if (%= code trap-reschedule)
        ;; Not an error at all: a task asking to be switched out. Returning
        ;; from here resumes whichever task the scheduler picked.
        (switch-tasks)
        (begin
          (cond
           ((%= code trap-arity)
            ;; t0 still holds the closure that was about to be entered and t1
            ;; the count it was handed, so the report can name both.
            (emit-str "\ncalled ")
            (emit-callee (%raw-ld (%+ ctx (ctx-word 5))))
            (let ((n (%ld32 (%+ ctx (ctx-word 6)))))
              (emit-str " with ")
              (emit-str (number->string n))
              (emit-str (if (%= n 1) " argument" " arguments")))
            (emit-str ", at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code trap-type)
            (emit-str "\ntype error at ") (emit-str (number->hex epc)) (emit-str "\n"))
           ((%= code trap-record)
            ;; A record accessor was handed the wrong kind of record. It left
            ;; the tag it wanted in t3 and never touched what it was given, so
            ;; both ends can be named.
            (emit-str "\nexpected ")
            (emit-a-or-an (%raw-ld (%+ ctx (ctx-word 28))))
            (emit-str ", got ")
            (emit-object (%raw-ld (%+ ctx (ctx-word 10))))
            (emit-str ", at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code trap-oom)
            (emit-str "\nout of memory at ") (emit-str (number->hex epc)) (emit-str "\n"))
           (else (emit-str "\nunknown ecall\n")))
          ;; The arity check is in the callee prologue, before it has loaded
          ;; its own literal vector, so s0 and s1 still describe the caller.
          ;; Starting the walk at the return address rather than at the ecall
          ;; makes the first line name the call site, which is the one place
          ;; worth looking.
          (if (%= code trap-arity)
              (backtrace-from-context (trap-reg ctx 1) ctx)
              (backtrace-from-context epc ctx))
          (abort-to-repl ctx)))))

;; ---------------------------------------------------------------- backtrace
;; The frame chain the collector walks for roots also walks for blame. Every
;; prologue saves its caller frame base at s0-8 and its caller literal vector
;; - which is to say its caller code object, which carries the name - at
;; s0-16. So a backtrace needs no side table of addresses, no debug section
;; and no unwind information: the same four words that make a frame make the
;; trace.
(define backtrace-limit 24)

;; The closure a call was about to enter. Its code object is where the name
;; lives, which is the same word the backtrace reads.
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
      (let ((ra (%ld32 (%- f 4))))
        ;; The allocator refill stub sits between two Lisp frames without a
        ;; frame of its own, so the chain steps straight over it; say so
        ;; rather than silently losing the fact that we were allocating.
        (if (in-stub? ra) (emit-str "  (allocating)\n") nil)
        (set! p ra))
      (set! c (%raw-ld (%- f 16)))
      (set! f (%ld32 (%- f 8)))
      (set! i (%+ i 1)))
    (if (if go (frame-ok? f) nil) (emit-str "  ...\n") nil)))

;; The registers a trap saved. x8 is s0, the frame base of whatever was
;; running; x9 is s1, its code object. (Not ctx-reg: exec.lisp has one of
;; those and it answers the address rather than the contents.)
(define (ctx-word n) (%* 4 n))
(define (trap-reg ctx n) (%ld32 (%+ ctx (ctx-word n))))

(define (backtrace-from-context epc ctx)
  (print-backtrace (trap-reg ctx 8) (%raw-ld (%+ ctx (%* 4 9))) epc))

(define (fatal-trap cause epc tval ctx)
  (emit-str "\n*** ")
  (emit-str (cause-name cause))
  (emit-str " at pc ")
  (emit-str (number->hex epc))
  (emit-str ", value ")
  (emit-str (number->hex tval))
  (emit-str "\n")
  (backtrace-from-context epc ctx)
  (abort-to-repl ctx))

;; ---------------------------------------------------------------- restart
;; An error abandons the stack it happened on. Calling the reader from inside
;; the handler would leave it running on the trap stack, on top of the frames
;; that faulted - which works exactly once, and makes the backtrace of the
;; next error a walk through the wreckage of the last one.
;;
;; So the restart is a return, not a call: rewrite the interrupted context to
;; look as though the reader had just been entered on a clean stack, and let
;; the trap stub put it back. Starting a task does the same thing for the same
;; reason.
(define *repl-restart* nil)

;; Two things sys.lisp cannot know about because Exec is compiled after it:
;; whose stack to restart on, and what to do with a task that faults without a
;; prompt to go back to. Exec fills these in when it starts.
(define *stack-top-fn* nil)
(define *task-abort-fn* nil)
(define *return-addr-fn* nil)
;; Exec keeps nesting counts for Disable and Forbid. An abort walks out of
;; however many of those the faulting code was holding, so they have to be put
;; back to nothing - and only Exec knows where they live.
(define *abort-cleanup-fn* nil)
;; What a resumed image has to put back that is not memory: devices, and
;; whatever was running them. The workbench fills this in.
(define *resume-fn* nil)

(define (restart-stack)
  ;; A task must restart on its own stack. Putting it back on the boot task's
  ;; would be two tasks standing on one stack, which goes wrong immediately
  ;; and mysteriously.
  (if *stack-top-fn* (%funcall *stack-top-fn*) (%global lg-stacktop)))

(define (restart-ra)
  ;; Where a restarted closure returns to when it finally does. On the machine
  ;; that is the task exit stub, so a prompt in a window that is dismissed
  ;; ends its task instead of returning to nowhere.
  (if *return-addr-fn* (%funcall *return-addr-fn*) 0))

(define (enter-closure ctx f sp)
  (%st32! (%+ ctx (ctx-word 0)) (%ld32 (%addr-of f)))  ; pc = its entry
  (%raw-st! (%+ ctx (ctx-word 5)) f)                   ; t0 = the closure
  (%st32! (%+ ctx (ctx-word 6)) 0)                     ; t1 = no arguments
  (%st32! (%+ ctx (ctx-word 2)) sp)                    ; a whole stack
  (%st32! (%+ ctx (ctx-word 1)) (restart-ra))          ; where it ends up
  (%st32! (%+ ctx (ctx-word 8)) 0)                     ; and no caller
  nil)

(define (abort-to-repl ctx)
  ;; There is no unwinding here: the stack the fault happened on is abandoned
  ;; where it stands, and nothing on it gets a chance to put anything back. So
  ;; the interrupt state is re-established rather than restored. Without this,
  ;; an error inside `without-interrupts` would leave the machine deaf for as
  ;; long as it ran.
  (%enable-after-trap)
  (if *abort-cleanup-fn* (%funcall *abort-cleanup-fn*) nil)
  (cond (*repl-restart* (enter-closure ctx *repl-restart* (restart-stack)))
        ;; A task with no prompt behind it does not get to take the machine
        ;; down with it; it just stops being a task.
        (*task-abort-fn* (enter-closure ctx *task-abort-fn* (restart-stack)))
        (else (emit-str "no repl to return to; halting\n") (%halt 1))))

;; ---------------------------------------------------------------- eval
;; There is no interpreter on the machine. Every form typed at the REPL is
;; compiled to native code and then called - which is the whole point of the
;; image carrying its own compiler.
(define (eval-thunk form)
  ;; Compile one form as the body of a function of no arguments, then call it.
  (let* ((r (compile-function nil (list form) 'repl nil))
         (clo (make-closure (%cdr r) 0)))
    (%funcall clo)))

;; A top level form is normally just run: at a prompt there is no image being
;; built and nothing to remember it for. During a rebuild there is, and then
;; the same form is compiled onto the boot list of the image being made as
;; well as run here - which is the whole difference between a machine using
;; its compiler and a machine building its successor.
(define *recording* nil)

(define (top-level-form form)
  (if *recording*
      (%funcall (add-boot-thunk form))
      (eval-thunk form)))

(define (record-initialiser name expr)
  ;; compile-top has already given the variable its value; this is so that the
  ;; image being built gives it that value again when it boots.
  (if *recording* (add-boot-thunk (list 'set! name expr)) nil))

(define (register-macro form) nil)

;; ---------------------------------------------------------------- rebuild
;; The machine compiling its own successor. Source arrives on the console the
;; way anything else does; every form is compiled into a fresh boot list until
;; the sentinel, and then the image can be written out.
;;
;; Nothing here is clever. The compiler being recompiled is the compiler doing
;; the compiling, and calls go through symbol value cells, so the new one
;; takes over partway through and finishes the job. That is what self-hosting
;; is; if the new compiler is broken, the way you find out is that the build
;; goes wrong in a confusing place.
(define (rebuild)
  ;; And it does not come back on: by the time this returns, the ExecBase the
  ;; scheduler needs has been overwritten by the sources going past. The image
  ;; this writes turns preemption on for itself when it boots.
  (preemption-off)
  (set! *boot-thunks* nil)
  (set! *recording* t)
  (let ((go t) (n 0))
    (while go
      (let ((form (read-form)))
        (if (%eq? form 'rebuild-end)
            (set! go nil)
            (begin (compile-top form) (set! n (%+ n 1))))))
    (set! *recording* nil)
    (emit-str "rebuilt ")
    (emit-str (number->string n))
    (emit-str " forms\n")
    n))

(define (eval-form form) (compile-top form))
(define (eval form) (eval-form form))

;; What `compile-top` uses to work out the value of a top level variable while
;; it is compiling. On the machine that means compiling and running it, which
;; is the only kind of evaluation there is here.
(define (compile-time-eval form) (eval-thunk form))

;; On the machine a macro is a symbol with bit 0 of its flags set, whose
;; function cell holds the compiled expander the forge left there.
;; The function slot holds two different things depending on the flag: a macro
;; expander, or the compiler's note of how to open-code a call. The bit is
;; what tells them apart, and no name is ever both.
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

(define (expand-macro form)
  ;; One argument: the form's arguments, as a list. The expander was compiled
  ;; to take them that way.
  (let ((m (macro-symbol? (%car form))))
    (if m (%funcall m (%cdr form)) form)))

;; ---------------------------------------------------------------- repl
(define *repl-depth* 0)

(define (repl)
  ;; Where the bindings stand here is what an error unwinds to: the prompt's
  ;; own streams and package survive it, and whatever the form that failed had
  ;; bound on top of them does not.
  (let ((mark (task-binds)))
    (set! *repl-restart* (lambda () (unwind-binds-to! mark) (repl-loop))))
  (repl-loop))

;; Swallow the newline the reader stopped just short of, so that what the form
;; prints starts on a line of its own. Best effort and never blocking: if the
;; character has not arrived yet, the next read will skip it as whitespace,
;; which is what used to happen every time.
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
      (let ((form (read-form)))
        (finish-line)
        (if (%eq? form 'bye)
            (begin (emit-str "\n") (set! go nil))
            (let ((v (eval-form form)))
              (emit-str "\n")
              (write v)))))
    nil))

;; A prompt of its own, in a task of its own, talking to a stream of its own.
;; Everything that makes a REPL a REPL - where its characters come from, what
;; it half-read, where an error puts it back - now travels with the task, so
;; two of these do not interfere.
(define (start-repl name stream)
  (add-task name 0
            (lambda ()
              (use-stream! stream)
              (repl))))

;; ---------------------------------------------------------------- kickstart
(define (run-boot-list)
  ;; The forge left a thunk for every top level form that was not a function
  ;; definition, in source order.
  (let ((l (%raw-ld lg-bootlist)))
    (while (%cons? l)
      (%funcall (%car l))
      (set! l (%cdr l)))))

(define (kickstart)
  ;; Before anything else, the boot list included: the first thing the boot
  ;; list does is allocate.
  (install-allocator)
  (%raw-st! lg-traphook (%symbol-value 'handle-trap))
  (run-boot-list)
  ;; Exec comes up before anything else can want a task: the code already
  ;; running becomes task zero, and its context is the trap frame the stub has
  ;; been saving into since the machine started.
  (exec-init)
  ;; And preemption with it. It used to be something you turned on by hand,
  ;; which meant nothing was ever tested against it; everything that touches
  ;; shared state now takes a critical section, so there is no reason to wait
  ;; to be asked.
  (exec-start)
  (banner)
  (banner-exec)
  (emit-str "type (help) for what to try
")
  (if (%raw-ld lg-startup)
      (%funcall (%raw-ld lg-startup))
      nil)
  ;; A prompt starts in user, whatever package the boot list happened to leave
  ;; the reader in on its way through.
  (set-current-package! (make-package "user"))
  ;; The first prompt is the machine's own: when it says goodbye, so does the
  ;; machine. One in a window is a task, and only ends its task.
  (repl)
  (%halt 0)
  0)
