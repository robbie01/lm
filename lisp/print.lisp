;;; print.lisp - the printer.
;;;
;;; Compiled into the image; what the prompt prints with. Written against the
;;; "put one character" half of a stream, so it serves the serial console, a
;;; string and a window alike.

(in-package lm)

;; ---------------------------------------------------------------- names
;; A compiled function carries its name in its code object, so a printed
;; function and a backtrace line say the same thing. These emit rather than
;; build a string: reporting an error must not allocate.
(define (code-object? v)
  (if (%object? v)
      (if (%>= (%addr-of v) obj-base)
          (if (%< (%addr-of v) obj-limit) (%= (%obj-type v) t-code) nil)
          nil)
      nil))

;; A symbol for a named function; (lambda . home) for one that never had a
;; name, so an anonymous frame still says where it came from.
(define (emit-name n)
  (cond ((%null? n) (emit-str "anonymous"))
        ((%cons? n) (emit-str "lambda in ") (emit-name (%cdr n)))
        ((%symbol? n) (emit-str (%symbol-name n)))
        (else (emit-str "anonymous"))))

(define (emit-code-label c)
  (if (code-object? c) (emit-name (%slot c code-name)) (emit-str "?")))

;; Bare if the current package would read the name back as this symbol,
;; qualified otherwise, with two colons for one that was never exported. An
;; uninterned symbol prints as #:name.
(define (print-symbol x)
  (let ((name (%symbol-name x)))
    (if (%eq? (find-visible (current-package) name) x)
        (emit-str name)
        (let ((p (symbol-package x)))
          (if p
              (begin
                (emit-str (package-name p))
                (emit-str (if (symbol-exported? x) ":" "::")))
              (emit-str "#:"))
          (emit-str name)))))

(define (write-char-name c)
  (emit-str "#\\")
  (cond ((%eq? c #\space) (emit-str "space"))
        ((%eq? c #\newline) (emit-str "newline"))
        ((%eq? c #\tab) (emit-str "tab"))
        ((%eq? c (%int->char 13)) (emit-str "return"))
        ((%eq? c #\backspace) (emit-str "backspace"))
        (else (emit-ch c))))

(define (write-string-quoted s)
  (emit-ch #\")
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (let ((c (%string-ref s i)))
        (cond ((%eq? c #\") (emit-ch #\\) (emit-ch #\"))
              ((%eq? c #\\) (emit-ch #\\) (emit-ch #\\))
              ((%eq? c #\newline) (emit-ch #\\) (emit-ch #\n))
              (else (emit-ch c))))
      (set! i (%+ i 1))))
  (emit-ch #\"))

(define (print-obj x quoted depth)
  (cond
   ((%> depth 32) (emit-str "..."))
   ((%null? x) (emit-str "nil"))
   ((%fixnum? x) (emit-str (number->string x)))
   ((%char? x) (if quoted (write-char-name x) (emit-ch x)))
   ((%cons? x) (print-list x quoted depth))
   ((%object? x)
    (let ((ty (%obj-type x)))
      (cond
       ((%= ty t-bignum) (emit-str (bignum->string x)))
       ((%= ty t-symbol) (print-symbol x))
       ((%= ty t-string) (if quoted (write-string-quoted x) (emit-str x)))
       ((%= ty t-vector) (print-vector x quoted depth))
       ((%= ty t-closure)
        (emit-str "#<function ")
        (emit-code-label (%slot x clo-code))
        (emit-ch #\>))
       ((%= ty t-bytes)
        (emit-str "#<bytes ")
        (emit-str (number->string (%obj-len x)))
        (emit-ch #\>))
       ((%= ty t-float) (emit-str "#<float>"))
       ((%= ty t-record)
        (cond
         ((package? x)
          (emit-str "#<package ") (emit-str (package-name x)) (emit-ch #\>))
         (else (print-record x quoted depth))))
       (else (emit-str "#<object>")))))
   (else (print-immediate x))))

;; The immediates that are not characters: the marker of a variable with no
;; value, the end of a file, and no value at all.
(define (print-immediate x)
  (let ((w (%addr-of x)))
    (cond ((%= w (%logior (%lsh imm-unbound 3) 2)) (emit-str "#<unbound>"))
          ((%= w (%logior (%lsh imm-eof 3) 2)) (emit-str "#<eof>"))
          ((%= w (%logior (%lsh imm-void 3) 2)) (emit-str "#<void>"))
          (else (emit-str "#<immediate ") (emit-str (number->hex w)) (emit-ch #\>)))))

;; (quote x) prints as 'x.
(define (print-list x quoted depth)
  (if (if (%eq? (%car x) 'quote) (if (%cons? (%cdr x)) (%null? (cddr x)) nil) nil)
      (begin (emit-ch #\') (print-obj (cadr x) quoted (%+ depth 1)))
      (begin
        (emit-ch #\()
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
        (emit-ch #\)))))

(define (print-vector v quoted depth)
  (emit-str "#(")
  (let ((i 0) (n (%vector-length v)))
    (while (%< i n)
      (if (%> i 0) (space) nil)
      (print-obj (%vector-ref v i) quoted (%+ depth 1))
      (set! i (%+ i 1))))
  (emit-ch #\)))

;; A record at top level prints every slot. Inside something else it prints as
;; its type: records point at each other, a task at its parent, every node
;; at its neighbours, and following them would print the whole kernel.
(define (print-record r quoted depth)
  (emit-str "#[")
  (if (%> depth 0)
      (begin
        (if (%> (%obj-len r) 0) (print-obj (%slot r 0) quoted (%+ depth 1)) nil)
        (emit-str " ..."))
      (let ((i 0) (n (%obj-len r)))
        (while (%< i n)
          (if (%> i 0) (space) nil)
          (print-obj (%slot r i) quoted (%+ depth 1))
          (set! i (%+ i 1)))))
  (emit-ch #\]))

(define (write x) (print-obj x t 0) x)
(define (display x) (print-obj x nil 0) x)
(define (print x) (write x) (newline) x)
(define (princ x) (display x) x)

(define (write-to-string x) (with-output-to-string (lambda () (write x))))
(define (display-to-string x) (with-output-to-string (lambda () (display x))))

;; ---------------------------------------------------------------- errors
;; There is no condition system. An error prints what it knows and traps, and
;; the trap handler prints a backtrace and restarts the prompt, or ends the
;; task.
(define (error . args)
  (emit-str "error: ")
  (let ((first t))
    (dolist (a args)
      (if first (set! first nil) (space))
      (if (%string? a) (emit-str a) (write a))))
  (newline)
  (let ((h (%ld-word lg-errhandler)))
    (if h (%funcall h args) (%halt exit-error))))

(define (warn . args)
  (emit-str "warning: ")
  (dolist (a args) (if (%string? a) (emit-str a) (write a)) (space))
  (newline))

;; ---------------------------------------------------------------- gensym
(define *gensym-count* 0)

;; An uninterned symbol, so a macro's temporaries do not accumulate in the
;; obarray. Reading and bumping the counter is one act, or two tasks could
;; make two symbols with one name.
(define (gensym-1)
  (let ((n (without-interrupts
             (set! *gensym-count* (%+ *gensym-count* 1))
             *gensym-count*)))
    (make-symbol (string-append "g" (number->string n)))))

;; ---------------------------------------------------------------- clock
(define (cycles) (%cycles))
