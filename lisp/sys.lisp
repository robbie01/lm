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

(define cause-wrong-type 24)
(define cause-range 25)
(define cause-overflow 26)
(define cause-divzero 27)
(define cause-stack 28)     ; the stack pointer went below the task's limit

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
        ((%= c cause-stack) "stack overflow")
        (else "trap")))

;; The trap stub hands over the cause with the interrupt flag moved from bit
;; 31 down to bit 6, because bit 31 does not fit in a fixnum.
(define cause-interrupt-bit 64)
(define (interrupt? c) (%>= c cause-interrupt-bit))
(define (interrupt-number c) (%logand c 31))

(define int-software 3)
(define int-timer 7)
(define int-external 11)

;; How deep traps may nest before the handler is taken to be faulting in a
;; loop. The stub has eight frames for traps inside traps (`trap-nest-max` in
;; boot.lisp, which is not in the image), and running out of them used to end
;; in a jump through a garbage frame pointer: an illegal instruction somewhere
;; unrelated, and a machine that stopped with nothing said.
(define trap-nest-limit 8)

(define (trap-spiral cause epc tval)
  (uart-string "\n*** the trap handler is faulting in a loop: ")
  (uart-string (cause-name cause))
  (uart-string " at pc ")
  (uart-hex-raw epc)
  (uart-string ", value ")
  (uart-hex-raw tval)
  (uart-nl)
  (%halt 3))

(define (handle-trap cause epc tval ctx)
  (if (%>= (%ld-fixnum lg-trapdepth) trap-nest-limit) (trap-spiral cause epc tval) nil)
  (if (interrupt? cause)
      (handle-interrupt (interrupt-number cause) ctx)
      (cond ((%= cause 11) (handle-ecall epc ctx))
            ((%= cause cause-wrong-type)
             (if (try-widen epc ctx) nil (check-trap cause epc tval ctx)))
            ((%= cause cause-range) (check-trap cause epc tval ctx))
            ((%= cause cause-overflow)
             (if (try-widen epc ctx) nil (check-trap cause epc tval ctx)))
            ((%= cause cause-divzero) (check-trap cause epc tval ctx))
            (else (fatal-trap cause epc tval ctx))))
  (keep-cons-run ctx))

;; The handler conses out of the cons run of the task it interrupted - gp and
;; tp are only registers, and nothing changes them on the way in - but the stub
;; puts back the gp and tp it saved on the way in. So every pair the handler
;; made went out a second time as soon as the task consed again: the same cell,
;; two owners. Usually nobody noticed, because what a fault report makes is
;; garbage by the time it has been printed. In a window it is not garbage. The
;; report draws, drawing damages, and the damage list belongs to the compositor
;; - so `(ackermann 5 5)` in a shell overflowed its stack, said so correctly,
;; and then the restarted prompt consed over the damage list and took the
;; compositor down, or ran into an illegal instruction on the way.
;;
;; So the run goes back into the frame it was saved in, as the handler left
;; it. That frame is `ctx` whatever else happened here: a task switch points
;; mscratch at the next task's frame and leaves this one to be resumed later,
;; with this run. A collection in the handler empties the run, and the task
;; comes back to an empty run and asks for a fresh chunk - where before it
;; came back to its old one, which the compaction had just filled with live
;; pairs.
(define (keep-cons-run ctx)
  (%sync-cons-run)
  (%st-word! (ctx-reg ctx reg-gp) (%ld-word lg-cons-run))
  (%st-word! (ctx-reg ctx reg-tp) (%ld-word lg-cons-run-end))
  nil)

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
(define (insn-rd w)  (%logand (%lsh w -7) 31))

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
        ((%= ty t-bignum) (emit-str "a bignum"))
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
         (obj (trap-raw ctx (insn-rs1 w)))
         (idx (if (%= 4 (%logand f 4))
                  (insn-rs2 w)
                  (trap-raw ctx (insn-rs2 w)))))
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
   ;; `try-widen` has already had its chance, so a bignum reaching here means
   ;; this operator has no bignum form yet rather than that the operand was
   ;; the wrong kind of thing. Saying "expected a number" about a number is
   ;; the sort of message that costs somebody an hour.
   ((%bignum? (%from-addr tval))
    (emit-str ": no bignum form yet, given ") (emit-value tval))
   (else (emit-str ": expected a number, got ") (emit-value tval))))

;; ---------------------------------------------------------------- widening
;; Overflow and mixed-mode arithmetic both arrive as traps, and neither is an
;; error. `+`, `-` and `*` emit the trapping forms of the fixnum instructions,
;; and every fixnum instruction refuses an operand that is not one - so a sum
;; that outgrows thirty-one bits and a sum with a bignum in it both stop here,
;; and both are simply the same operation done in a width that fits.
;;
;; Only the one instruction is emulated. A comparison writes a raw zero or one
;; and the instructions after it turn that into `t` or `nil`; an arithmetic
;; instruction writes a tagged value. Either way the trap returns to the
;; instruction after this one and the rest of the sequence runs as compiled.
;;
;; The cost of this is a trap, which is around ten times what the allocation
;; inside it costs - so the thing to avoid is arriving here at all, which is
;; why the fast path is one instruction that asks nothing.
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
    ;; instruction rather than run it again and trap forever.
    (if ok (%st-fixnum! ctx (%+ epc 4)) nil)
    ok))

(define (try-widen epc ctx)
  (let ((w (%ld-fixnum epc)))
    (if (%= (insn-op w) op-fixnum)
        (let ((rd (insn-rd w))
              (x (trap-raw ctx (insn-rs1 w)))
              (y (trap-raw ctx (insn-rs2 w))))
          ;; Slot zero of the context is the saved pc, not register x0, so an
          ;; instruction that writes to x0 has nowhere to put an answer. The
          ;; compiler emits none, and this is here so that a corrupt word read
          ;; as an instruction cannot scribble on the return address.
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

;; The compiler emits `ecall` for the handful of conditions it detects inline,
;; with the reason in a7. Resuming past it means stepping mepc over the
;; instruction, which is why the handler is handed the saved context.
(define (handle-ecall epc ctx)
  ;; Step the saved pc over the ecall first: the stub reloads mepc from the
  ;; context on its way out, so this is what makes the trap return to the
  ;; instruction after it rather than run it again.
  (%st-fixnum! ctx (%+ epc 4))
  ;; a7 holds the reason. %ld-fixnum already yields it as a number.
  (let ((code (%ld-fixnum (%+ ctx (%* 4 17)))))
    (if (%= code trap-reschedule)
        ;; Not an error at all: a task asking to be switched out. Returning
        ;; from here resumes whichever task the scheduler picked.
        (switch-tasks)
        (abort-to-repl ctx
         (compose-report
          (lambda ()
          (cond
           ((%= code trap-arity)
            ;; t0 still holds the closure that was about to be entered and t1
            ;; the count it was handed, so the report can name both.
            (emit-str "\ncalled ")
            (emit-callee (trap-raw ctx reg-t0))
            (let ((n (trap-reg ctx reg-t1)))
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
            (emit-a-or-an (trap-raw ctx reg-t3))
            (emit-str ", got ")
            (emit-object (trap-raw ctx reg-a0))
            (emit-str ", at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code trap-oom)
            (emit-str "\nout of memory at ") (emit-str (number->hex epc)) (emit-str "\n"))
           ;; `error` has already said what went wrong. All that is left is
           ;; where, and the restart.
           ((%= code trap-error) nil)
           (else (emit-str "\nunknown ecall\n")))
          ;; The arity check is in the callee prologue, before it has loaded
          ;; its own literal vector, so s0 and s1 still describe the caller.
          ;; Starting the walk at the return address rather than at the ecall
          ;; makes the first line name the call site, which is the one place
          ;; worth looking.
          (if (%= code trap-arity)
              (backtrace-from-context (trap-reg ctx reg-ra) ctx)
              (backtrace-from-context epc ctx))))))))

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
      (let ((ra (%ld-fixnum (%- f 4))))
        ;; The allocator refill stub sits between two Lisp frames without a
        ;; frame of its own, so the chain steps straight over it; say so
        ;; rather than silently losing the fact that we were allocating.
        (if (in-stub? ra) (emit-str "  (allocating)\n") nil)
        (set! p ra))
      (set! c (%ld-word (%- f 16)))
      (set! f (%ld-fixnum (%- f 8)))
      (set! i (%+ i 1)))
    (if (if go (frame-ok? f) nil) (emit-str "  ...\n") nil)))

;; The registers a trap saved. x8 is s0, the frame base of whatever was
;; running; x9 is s1, its code object.
;;
;; Word 0 of the block is the pc and words 1..31 are x1..x31, which is what
;; the stub writes; `reg-<name>` for each of them is generated with the rest
;; of the layout, so nothing here counts words.
(define (ctx-pc c) (%+ c 0))
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
        ;; The machine refuses any store into its first eight bytes, because
        ;; those are what car and cdr of nil read. Somebody treated nil as a
        ;; pair of their own, and the address alone would not say so.
        (if (if (%= cause 7) (%< tval 8) nil)
            (emit-str ", which is nil's cell")
            nil)
        (emit-str "\n")
        (backtrace-from-context epc ctx)))))

;; ---------------------------------------------------------------- reports
;; A fault is reported by the task it happened in, once that task is back on
;; its feet - not by the trap handler. The handler runs with interrupts off and
;; half the world saved: it cannot wait, cannot take a lock, and has no business
;; drawing, and a report goes to the task's own output, which in a window is
;; drawing. So the handler writes the report into a string, and the restart
;; prints it after it has unwound the task's bindings, on its own stack, with
;; interrupts on.
;;
;; The same move keeps a broken output from taking the machine down. With
;; `*out*` bound to something that faults - once it was bound to a stream,
;; where the stream's output function belonged - the report of the fault went
;; to the same place and faulted again, eight traps deep, until the stub ran
;; out of frames. Now the report is written where nothing can fault, and
;; printed through whatever `*out*` is once the binding that broke it is gone.
(define *printing-report* nil)   ; the task printing one, if any

(define (compose-report thunk)
  (let ((acc nil))
    (fluid-let ((*out* (lambda (c) (set! acc (%cons c acc)))))
      (%funcall thunk))
    (let ((s (list->string (reverse acc))))
      (if (if *printing-report* (%eq? *printing-report* (%this-task)) nil)
          ;; This fault came from printing the last report: the task's own
          ;; output is what is broken, so this one goes to the serial line.
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
;; Exec keeps state that an abort walks out of and has to put back - a switch
;; it owed, whether it thinks it is inside an interrupt server, the mutexes the
;; task was holding - and only Exec knows where that lives.
(define *abort-cleanup-fn* nil)
;; What a resumed image has to put back that is not memory: devices, and
;; whatever was running them. The workbench fills this in.
(define *resume-fn* nil)

;; What `error` calls once it has printed its message: a trap, so that the
;; rest happens where every other failure goes - a backtrace from the saved
;; registers, then the prompt, or the end of the task. The slot print.lisp
;; reads it from was never filled in before, so every `error` on the machine
;; used to halt the machine.
(define (error-trap args) (%ecall trap-error))

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

;; The closure is entered with one argument, if one is given: the report of the
;; fault that brought it here - see `compose-report`.
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

(define (abort-to-repl ctx . report)
  ;; There is no unwinding here: the stack the fault happened on is abandoned
  ;; where it stands, and nothing on it gets a chance to put anything back. So
  ;; the interrupt state is re-established rather than restored. Without this,
  ;; an error inside `without-interrupts` would leave the machine deaf for as
  ;; long as it ran.
  ;;
  ;; The report goes to the restart, which prints it: see `compose-report`.
  (%enable-after-trap)
  (if *abort-cleanup-fn* (%funcall *abort-cleanup-fn*) nil)
  (let ((r (if (%cons? report) (%car report) nil)))
    (cond (*repl-restart* (enter-closure ctx *repl-restart* (restart-stack) r))
          ;; A task with no prompt behind it does not get to take the machine
          ;; down with it; it just stops being a task.
          (*task-abort-fn* (enter-closure ctx *task-abort-fn* (restart-stack) r))
          (else (if r (uart-string r) nil)
                (uart-string "no repl to return to; halting\n")
                (%halt 1)))))

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
;; its compiler and a machine building its successor. During genesis it only
;; goes on the boot list: the image runs it when it boots, and this machine
;; has run it already, in the rebuild before.
(define *recording* nil)

(define (top-level-form form)
  (cond (*image* (add-boot-thunk form))
        (*recording* (%funcall (add-boot-thunk form)))
        (else (eval-thunk form))))

(define (record-initialiser name expr)
  ;; compile-top has already given the variable its value; this is so that the
  ;; image being built gives it that value again when it boots.
  (if (if *recording* t *image*) (add-boot-thunk (list 'set! name expr)) nil))

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
  ;; Output goes to the raw serial line for the whole rebuild. The console
  ;; stream hands a line to console.driver and waits for the answer, and a
  ;; rebuild is redefining the kernel that waiting depends on, one define at a
  ;; time. Input keeps coming from the stream: everything a rebuild reads was
  ;; typed before it started, and arrived in the stream as one burst.
  (set! *out* nil)
  (set! *boot-thunks* nil)
  (set! *recording* t)
  ;; And the stream the sources come from is held here and put back before
  ;; every form. stream.lisp is one of the sources, and compiling it sets `*in*`
  ;; to nil - which used to be what it was anyway, the raw line, and is now a
  ;; line the console driver has already emptied into this stream. Without
  ;; this a rebuild reads as far as stream.lisp and then waits for ever on a
  ;; serial port with nothing left in it.
  (let ((in *in*) (await *await*) (go t) (n 0))
    (while go
      (set! *in* in)
      (set! *await* await)
      (set! *out* nil)
      (let ((form (read-form)))
        (if (%eq? form 'rebuild-end)
            (set! go nil)
            (begin (compile-top form) (set! n (%+ n 1))))))
    (set! *recording* nil)
    (emit-str "rebuilt ")
    (emit-str (number->string n))
    (emit-str " forms\n")
    n))

;; ---------------------------------------------------------------- genesis
;; The second half of a fresh rebuild. `rebuild` has just compiled the sources
;; into this machine, so the compiler, the macros and whatever a compile-time
;; evaluation calls are all the new ones. Now the same sources go through a
;; second time, and every definition is kept for the image instead of being
;; installed here - see `*image*` in compile.lisp. So the image is compiled
;; entirely by the new compiler, and it holds nothing this machine had before:
;; not the definitions the rebuild replaced, not what was typed at a prompt.
;;
;; The names the sources use are noted as they are read, so that the image
;; can keep exactly those symbols. `snap:save-fresh` does the rest, from what
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
      (let ((form (read-form)))
        ;; A file's `in-package` has to take effect before the next form is
        ;; read. `rebuild` gets that for nothing, because it runs every top
        ;; level form as it goes; this one only records them, so it acts on
        ;; the package forms itself, as the reader's own `read-next` does.
        (act-on-package-form form)
        (if *genesis-trace*
            (begin
              (write (if (%cons? form) (if (%cons? (%cdr form)) (cadr form) form) form))
              (emit-str "\n"))
            nil)
        (if (%eq? form 'rebuild-end)
            (set! go nil)
            (begin (compile-top form) (set! n (%+ n 1))))))
    ;; And the prompt goes back to running what it is given.
    (set! *fresh-image* (list *image* *names-seen* (reverse *boot-thunks*)))
    (set! *image* nil)
    (set! *names-seen* nil)
    (emit-str "compiled ")
    (emit-str (number->string n))
    (emit-str " forms for a fresh image\n")
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

(define (repl . then)
  ;; Where the bindings stand here is what an error unwinds to: the prompt's
  ;; own streams and package survive it, and whatever the form that failed had
  ;; bound on top of them does not.
  ;;
  ;; `then` is what saying goodbye does, and it has to happen however the
  ;; prompt got to the goodbye. After an error the prompt runs on as the
  ;; restart, on a fresh stack whose bottom ends the task - so the machine's
  ;; own prompt used to go on running after `bye` whenever anything had gone
  ;; wrong in it first, and a script that had hit an error never ended.
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
  (let ((l (%ld-word lg-bootlist)))
    (while (%cons? l)
      (%funcall (%car l))
      (set! l (%cdr l)))))

(define (kickstart)
  ;; Before anything else, the boot list included: the first thing the boot
  ;; list does is allocate.
  (install-allocator)
  (%st-word! lg-traphook (%symbol-value 'handle-trap))
  (%st-word! lg-errhandler (%symbol-value 'error-trap))
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
  (if (%ld-word lg-startup)
      (%funcall (%ld-word lg-startup))
      nil)
  ;; A prompt starts in user, whatever package the boot list happened to leave
  ;; the reader in on its way through.
  (set-current-package! (make-package "user"))
  ;; The first prompt is the machine's own: when it says goodbye, so does the
  ;; machine. One in a window is a task, and only ends its task.
  (repl (lambda () (%halt 0)))
  (%halt 0)
  0)
