;;; print.lisp - the machine's own printer and reader.
;;;
;;; Everything here is compiled into the image. It is what the REPL uses, and
;;; it is deliberately written against a "put one character" function so the
;;; same printer serves the serial console, a string, or later a window.

(in-package lm)

;; ---------------------------------------------------------------- streams
;; A stream is three closures: put a character, take one or answer nil, and
;; block until there might be one. The printer was always written against the
;; first of those; giving the reader the same shape is what lets a REPL run in
;; a window as readily as on the serial line.
;;
;; They are three globals rather than one object because every character read
;; and written goes through them, and because that makes the default - nil,
;; meaning the serial port - free. What makes them per task is the scheduler,
;; which saves them into the outgoing task and loads the incoming one's, the
;; same way it does the registers.
(define *out* nil)
(define *in* nil)
(define *wait* nil)

(define (out-char n) (%st32! uart-data n))

(define (uart-char)
  (let ((v (%ld32 uart-data)))
    (if (%= v -1) nil (%int->char v))))

(define (emit-ch c)
  (if *out* (%funcall *out* c) (out-char c)))

;; A character if one is ready, nil otherwise. Never blocks.
(define (get-char)
  (if *in* (%funcall *in*) (uart-char)))

;; Give the machine to somebody else until input might have arrived.
(define (await-char)
  (if *wait* (%funcall *wait*) (%wait-for-input)))

(define (make-stream put get wait) (vector put get wait))
(define (stream-put s) (%vector-ref s 0))
(define (stream-get s) (%vector-ref s 1))
(define (stream-wait s) (%vector-ref s 2))

(define (current-stream) (make-stream *out* *in* *wait*))

(define (use-stream! s)
  (set! *out* (%vector-ref s 0))
  (set! *in* (%vector-ref s 1))
  (set! *wait* (%vector-ref s 2))
  s)

;; The serial line, named so it can be switched back to.
(define (console-stream) (make-stream nil nil nil))

(define (emit-str s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (emit-ch (%char->int (%string-ref s i)))
      (set! i (%+ i 1)))
    s))

(define (newline) (emit-ch 10) nil)
(define (space) (emit-ch 32) nil)

;; Collect output into a string instead of sending it anywhere.
(define (with-output-to-string thunk)
  (let ((acc nil) (saved *out*))
    (set! *out* (lambda (c) (set! acc (%cons (%int->char c) acc))))
    (%funcall thunk)
    (set! *out* saved)
    (list->string (reverse acc))))

;; ---------------------------------------------------------------- printing
;; ---------------------------------------------------------------- names
;; Every compiled function carries its name in its code object, which is what
;; lets a printed function and a backtrace line both say who they are. These
;; emit rather than build a string, so that reporting an error allocates
;; nothing: a handler that conses is a handler that can fail while explaining
;; a failure.
(define (code-object? v)
  (if (%object? v)
      (if (%>= (%addr-of v) obj-base)
          (if (%< (%addr-of v) obj-limit) (%= (%obj-type v) t-code) nil)
          nil)
      nil))

(define (emit-name n)
  ;; A symbol for a named function; (lambda . home) for one that never had a
  ;; name, so that even an anonymous frame says where it came from.
  (cond ((%null? n) (emit-str "anonymous"))
        ((%cons? n) (emit-str "lambda in ") (emit-name (%cdr n)))
        ((%symbol? n) (emit-str (%symbol-name n)))
        (else (emit-str "anonymous"))))

(define (emit-code-label c)
  (if (code-object? c) (emit-name (%slot c code-name)) (emit-str "?")))

;; Short if the package we are in would read this name back as this symbol,
;; and qualified otherwise - with two colons for one that was never exported,
;; which is the reader's own spelling for reaching past an interface.
(define (print-symbol x)
  (let ((name (%symbol-name x)))
    (if (%eq? (find-visible (current-package) name) x)
        (emit-str name)
        (let ((p (symbol-package x)))
          (emit-str (if p (package-name p) "?"))
          (emit-str (if (symbol-exported? x) ":" "::"))
          (emit-str name)))))

(define (write-char-name c)
  (let ((n (%char->int c)))
    (emit-str "#\\")
    (cond ((%= n 32) (emit-str "space"))
          ((%= n 10) (emit-str "newline"))
          ((%= n 9) (emit-str "tab"))
          ((%= n 13) (emit-str "return"))
          (else (emit-ch n)))))

(define (write-string-quoted s)
  (emit-ch 34)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (let ((c (%char->int (%string-ref s i))))
        (cond ((%= c 34) (emit-ch 92) (emit-ch 34))
              ((%= c 92) (emit-ch 92) (emit-ch 92))
              ((%= c 10) (emit-ch 92) (emit-ch 110))
              (else (emit-ch c))))
      (set! i (%+ i 1))))
  (emit-ch 34))

(define (print-obj x quoted depth)
  (cond
   ((%> depth 32) (emit-str "..."))
   ((%null? x) (emit-str "nil"))
   ((%fixnum? x) (emit-str (number->string x)))
   ((%char? x) (if quoted (write-char-name x) (emit-ch (%char->int x))))
   ((%cons? x) (print-list x quoted depth))
   ((%object? x)
    (let ((ty (%obj-type x)))
      (cond
       ((%= ty t-symbol) (print-symbol x))
       ((%= ty t-string) (if quoted (write-string-quoted x) (emit-str x)))
       ((%= ty t-vector) (print-vector x quoted depth))
       ((%= ty t-closure)
        (emit-str "#<function ")
        (emit-code-label (%slot x clo-code))
        (emit-ch 62))
       ((%= ty t-bytes)
        (emit-str "#<bytes ")
        (emit-str (number->string (%obj-len x)))
        (emit-ch 62))
       ((%= ty t-record)
        (if (package? x)
            (begin (emit-str "#<package ") (emit-str (package-name x)) (emit-ch 62))
            (print-record x quoted depth)))
       (else (emit-str "#<object>")))))
   (else (emit-str "#<immediate>"))))

(define (print-list x quoted depth)
  ;; (quote x) reads better as 'x, and the compiler prints a lot of quoted
  ;; forms when something goes wrong.
  (if (if (%eq? (%car x) 'quote) (if (%cons? (%cdr x)) (%null? (cddr x)) nil) nil)
      (begin (emit-ch 39) (print-obj (cadr x) quoted (%+ depth 1)))
      (begin
        (emit-ch 40)
        (let ((p x) (n 0) (go t))
          (while go
            (if (%> n 0) (space) nil)
            (if (%> n 512)
                (begin (emit-str "...") (set! go nil))
                (begin
                  (print-obj (%car p) quoted (%+ depth 1))
                  (set! p (%cdr p))
                  (set! n (%+ n 1))
                  (cond ((%null? p) (set! go nil))
                        ((%cons? p) nil)
                        (else
                         (emit-str " . ")
                         (print-obj p quoted (%+ depth 1))
                         (set! go nil)))))))
        (emit-ch 41))))

(define (print-vector v quoted depth)
  (emit-str "#(")
  (let ((i 0) (n (%vector-length v)))
    (while (%< i n)
      (if (%> i 0) (space) nil)
      (print-obj (%vector-ref v i) quoted (%+ depth 1))
      (set! i (%+ i 1))))
  (emit-ch 41))

(define (print-record r quoted depth)
  (emit-str "#[")
  (let ((i 0) (n (%obj-len r)))
    (while (%< i n)
      (if (%> i 0) (space) nil)
      (print-obj (%slot r i) quoted (%+ depth 1))
      (set! i (%+ i 1))))
  (emit-ch 93))

(define (write x) (print-obj x t 0) x)
(define (display x) (print-obj x nil 0) x)
(define (print x) (write x) (newline) x)
(define (princ x) (display x) x)

(define (write-to-string x) (with-output-to-string (lambda () (write x))))
(define (display-to-string x) (with-output-to-string (lambda () (display x))))

;; ---------------------------------------------------------------- errors
;; No condition system yet: an error prints what it knows and hands control to
;; the error hook, which the REPL sets to something that unwinds.
(define (error . args)
  (emit-str "error: ")
  (let ((first t))
    (dolist (a args)
      (if first (set! first nil) (space))
      (if (%string? a) (emit-str a) (write a))))
  (newline)
  (let ((h (%raw-ld lg-errhandler)))
    (if h (%funcall h args) (%halt 1))))

(define (warn . args)
  (emit-str "warning: ")
  (dolist (a args) (if (%string? a) (emit-str a) (write a)) (space))
  (newline))

;; ---------------------------------------------------------------- apply
;; Spreading a list into registers cannot be written as a loop, because there
;; is no way to index the argument registers. Eight cases cover the calling
;; convention exactly.
(define (apply-list f args)
  (let ((n (length args)))
    (cond
     ((%= n 0) (%funcall f))
     ((%= n 1) (%funcall f (%car args)))
     ((%= n 2) (%funcall f (%car args) (cadr args)))
     ((%= n 3) (%funcall f (%car args) (cadr args) (caddr args)))
     ((%= n 4) (%funcall f (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args)))
     ((%= n 5) (%funcall f (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args)
                         (nth 4 args)))
     ((%= n 6) (%funcall f (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args)
                         (nth 4 args) (nth 5 args)))
     ((%= n 7) (%funcall f (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args)
                         (nth 4 args) (nth 5 args) (nth 6 args)))
     ((%= n 8) (%funcall f (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args)
                         (nth 4 args) (nth 5 args) (nth 6 args) (nth 7 args)))
     (else (error "apply: more than eight arguments")))))

;; ---------------------------------------------------------------- gensym
(define *gensym-count* 0)

(define (gensym-1)
  (set! *gensym-count* (%+ *gensym-count* 1))
  (intern-string (string-append "g" (number->string *gensym-count*))))

;; ---------------------------------------------------------------- clock
(define (cycles) (%cycles))
