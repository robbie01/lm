;;; sys.lisp - the kickstart proper: what the machine does when it wakes up.

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
  (emit-str "exec at ")
  (emit-str (number->hex (sysbase)))
  (emit-str ", ")
  (emit-str (number->string (task-count)))
  (emit-str " task\n"))

;; ---------------------------------------------------------------- traps
;; Everything that goes wrong arrives here, along with every interrupt.
(define trap-arity 1)
(define trap-type 2)
(define trap-oom 3)
(define trap-error 4)
(define trap-reschedule 5)

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
      (if (%= cause 11)
          (handle-ecall epc ctx)
          (fatal-trap cause epc tval ctx))))

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
            (emit-str "\ncalled a function with the wrong number of arguments, at ")
            (emit-str (number->hex epc))
            (emit-str "\n"))
           ((%= code trap-type)
            (emit-str "\ntype error at ") (emit-str (number->hex epc)) (emit-str "\n"))
           ((%= code trap-oom)
            (emit-str "\nout of memory at ") (emit-str (number->hex epc)) (emit-str "\n"))
           (else (emit-str "\nunknown ecall\n")))
          (abort-to-repl)))))

(define (fatal-trap cause epc tval ctx)
  (emit-str "\n*** ")
  (emit-str (cause-name cause))
  (emit-str " at pc ")
  (emit-str (number->hex epc))
  (emit-str ", value ")
  (emit-str (number->hex tval))
  (emit-str "\n")
  (abort-to-repl))

;; ---------------------------------------------------------------- restart
;; No unwinding yet, so an error restarts the reader loop by making the trap
;; return straight into it.
(define *repl-restart* nil)

(define (abort-to-repl)
  (if *repl-restart*
      (%funcall *repl-restart*)
      (begin (emit-str "no repl to return to; halting\n") (%halt 1))))

;; ---------------------------------------------------------------- reader
;; The machine's own reader. Text arrives from the serial port a character at
;; a time; this is the same grammar the forge's reader accepts, minus the file
;; handling.
(define *peeked* nil)

(define (read-char-or-nil)
  (if *peeked*
      (let ((c *peeked*)) (set! *peeked* nil) c)
      (let ((v (%ld32 uart-data)))
        (if (%= v -1) nil (%int->char v)))))

(define (wait-char)
  (let ((c nil))
    (while (%null? c)
      (set! c (read-char-or-nil))
      (if (%null? c) (%wait-for-input) nil))
    c))

(define (peek-char)
  (if *peeked* *peeked* (begin (set! *peeked* (wait-char)) *peeked*)))

(define (delimiter? c)
  (if (char-whitespace? c)
      t
      (if (%eq? c #\() t
          (if (%eq? c #\)) t
              (if (%eq? c #\") t (%eq? c #\;))))))

(define (skip-space)
  (let ((go t))
    (while go
      (let ((c (peek-char)))
        (cond
         ((char-whitespace? c) (wait-char))
         ((%eq? c #\;)
          (let ((d (wait-char)))
            (while (not (%eq? d #\newline)) (set! d (wait-char)))))
         (else (set! go nil)))))))

(define (read-form)
  (skip-space)
  (let ((c (peek-char)))
    (cond
     ((%eq? c #\() (wait-char) (read-list))
     ((%eq? c #\)) (wait-char) (error "unexpected )"))
     ((%eq? c #\') (wait-char) (list 'quote (read-form)))
     ((%eq? c #\`) (wait-char) (list 'quasiquote (read-form)))
     ((%eq? c #\,)
      (wait-char)
      (if (%eq? (peek-char) #\@)
          (begin (wait-char) (list 'unquote-splicing (read-form)))
          (list 'unquote (read-form))))
     ((%eq? c #\") (wait-char) (read-string-literal))
     ((%eq? c #\#) (wait-char) (read-hash))
     (else (read-atom)))))

(define (read-list)
  (let ((acc nil) (go t) (tail nil))
    (while go
      (skip-space)
      (let ((c (peek-char)))
        (cond
         ((%eq? c #\)) (wait-char) (set! go nil))
         ((if (%eq? c #\.) (dot-follows?) nil)
          (wait-char)
          (set! tail (read-form))
          (skip-space)
          (wait-char)
          (set! go nil))
         (else (set! acc (%cons (read-form) acc))))))
    (revappend acc tail)))

(define (dot-follows?)
  ;; A lone dot is the dotted-pair marker; a dot that starts a token is part
  ;; of a symbol.
  (wait-char)
  (let ((c (peek-char)))
    (if (delimiter? c)
        t
        (begin (set! *peeked* #\.) nil))))

(define (read-string-literal)
  (let ((acc nil) (go t))
    (while go
      (let ((c (wait-char)))
        (cond
         ((%eq? c #\") (set! go nil))
         ((%eq? c #\\)
          (let ((e (wait-char)))
            (set! acc (%cons (cond ((%eq? e #\n) #\newline)
                                   ((%eq? e #\t) #\tab)
                                   ((%eq? e #\r) (%int->char 13))
                                   (else e))
                             acc))))
         (else (set! acc (%cons c acc))))))
    (list->string (reverse acc))))

(define (read-hash)
  (let ((c (wait-char)))
    (cond
     ((%eq? c #\() (list->vector (read-list)))
     ((%eq? c #\\) (read-char-literal))
     ((%eq? c #\t) t)
     ((%eq? c #\f) nil)
     ((%eq? c #\x) (string->number-radix (read-token) 16))
     ((%eq? c #\b) (string->number-radix (read-token) 2))
     (else (error "unknown # syntax")))))

(define (read-char-literal)
  (let ((first (wait-char)))
    (if (char-alphabetic? first)
        (let ((name (string-append (string first) (read-token))))
          (cond ((%= 1 (%string-length name)) first)
                ((string=? name "space") #\space)
                ((string=? name "newline") #\newline)
                ((string=? name "tab") #\tab)
                ((string=? name "return") (%int->char 13))
                (else (error "unknown character name" name))))
        first)))

(define (read-token)
  (let ((acc nil) (go t))
    (while go
      (let ((c (peek-char)))
        (if (delimiter? c)
            (set! go nil)
            (set! acc (%cons (wait-char) acc)))))
    (list->string (reverse acc))))

(define (read-atom)
  (let ((tok (read-token)))
    (if (%= 0 (%string-length tok))
        (begin (wait-char) nil)
        (let ((n (string->number tok)))
          (cond (n n)
                ((string=? tok "nil") nil)
                (else (intern-string tok)))))))

(define (string->number-radix s radix)
  (let ((i 0) (n (%string-length s)) (acc 0) (neg nil))
    (if (%> n 0)
        (if (%eq? (%string-ref s 0) #\-) (begin (set! neg t) (set! i 1)) nil)
        nil)
    (while (%< i n)
      (let* ((c (%char->int (%string-ref s i)))
             (d (cond ((if (%>= c 48) (%<= c 57) nil) (%- c 48))
                      ((if (%>= c 97) (%<= c 102) nil) (%- c 87))
                      ((if (%>= c 65) (%<= c 70) nil) (%- c 55))
                      (else 99))))
        (if (%>= d radix) (error "bad digit in" s) nil)
        (set! acc (%+ (%* acc radix) d))
        (set! i (%+ i 1))))
    (if neg (%- 0 acc) acc)))

;; ---------------------------------------------------------------- eval
;; There is no interpreter on the machine. Every form typed at the REPL is
;; compiled to native code and then called - which is the whole point of the
;; image carrying its own compiler.
(define (eval-thunk form)
  ;; Compile one form as the body of a function of no arguments, then call it.
  (let* ((r (compile-function nil (list form) 'repl nil))
         (clo (make-closure (%cdr r) 0)))
    (%funcall clo)))

;; On the machine there is no boot list to add to: a top level form is simply
;; run, and a variable initialiser has already been run by compile-top.
(define (top-level-form form) (eval-thunk form))
(define (record-initialiser name expr) nil)
(define (register-macro form) nil)

(define (eval-form form) (compile-top form))
(define (eval form) (eval-form form))

;; What `compile-top` uses to work out the value of a top level variable while
;; it is compiling. On the machine that means compiling and running it, which
;; is the only kind of evaluation there is here.
(define (compile-time-eval form) (eval-thunk form))

;; On the machine a macro is a symbol with bit 0 of its flags set, whose
;; function cell holds the compiled expander the forge left there.
(define (macro-symbol? s)
  (if (%symbol? s)
      (if (%= 1 (%logand 1 (%symbol-flags s))) (%symbol-function s) nil)
      nil))

(define (macro-form? form)
  (if (%cons? form)
      (if (%symbol? (%car form)) (if (macro-symbol? (%car form)) t nil) nil)
      nil))

(define (expand-macro form)
  (let ((m (macro-symbol? (%car form))))
    (if m (apply-list m (%cdr form)) form)))

;; ---------------------------------------------------------------- repl
(define *repl-depth* 0)

(define (repl)
  (set! *repl-restart* (lambda () (repl-loop)))
  (repl-loop))

(define (repl-loop)
  (let ((go t))
    (while go
      (emit-str "\n> ")
      (let ((form (read-form)))
        (if (%eq? form 'bye)
            (begin (emit-str "\n") (set! go nil) (%halt 0))
            (let ((v (eval-form form)))
              (emit-str "\n")
              (write v)))))))

;; ---------------------------------------------------------------- kickstart
(define (run-boot-list)
  ;; The forge left a thunk for every top level form that was not a function
  ;; definition, in source order.
  (let ((l (%raw-ld lg-bootlist)))
    (while (%cons? l)
      (%funcall (%car l))
      (set! l (%cdr l)))))

(define (kickstart)
  (%raw-st! lg-traphook (%symbol-value 'handle-trap))
  (run-boot-list)
  ;; Exec comes up before anything else can want a task: the code already
  ;; running becomes task zero, and its context is the trap frame the stub has
  ;; been saving into since the machine started.
  (exec-init)
  (banner)
  (banner-exec)
  (emit-str "type (help) for what to try
")
  (if (%raw-ld lg-startup)
      (%funcall (%raw-ld lg-startup))
      nil)
  (repl)
  0)
