;;; print.lisp - the printer.
;;;
;;; Everything here is compiled into the image. It is what the REPL prints
;;; with, and it is written against the "put one character" half of a stream,
;;; so the same printer serves the serial console, a string, and a window.

(in-package lm)

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
       ((%= ty t-record)
        (cond
         ((package? x)
          (emit-str "#<package ") (emit-str (package-name x)) (emit-ch #\>))
         ;; An instance is a tag and a version followed by whatever it holds,
         ;; and what it holds is frequently the window it is drawn in, which
         ;; holds the instance back. Printing the name is the useful half and
         ;; the half that terminates.
         ((if (%>= (%obj-len x) 2)
              (if (%symbol? (%slot x 0)) (%fixnum? (%slot x 1)) nil)
              nil)
          (emit-ch #\#) (emit-ch #\<)
          (emit-str (%symbol-name (%slot x 0)))
          (emit-ch #\>))
         (else (print-record x quoted depth))))
       (else (emit-str "#<object>")))))
   (else (emit-str "#<immediate>"))))

(define (print-list x quoted depth)
  ;; (quote x) reads better as 'x, and the compiler prints a lot of quoted
  ;; forms when something goes wrong.
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

(define (print-record r quoted depth)
  (emit-str "#[")
  (let ((i 0) (n (%obj-len r)))
    (while (%< i n)
      (if (%> i 0) (space) nil)
      (print-obj (%slot r i) quoted (%+ depth 1))
      (set! i (%+ i 1))))
  (emit-ch #\]))

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
  (let ((h (%ld-word lg-errhandler)))
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
  ;; The counter is what makes the name unique, so reading and bumping it is
  ;; one act: two tasks that both read the old value make two symbols with the
  ;; same name, which is the one thing a gensym must never be.
  (let ((n (without-interrupts
             (set! *gensym-count* (%+ *gensym-count* 1))
             *gensym-count*)))
    (intern-string (string-append "g" (number->string n)))))

;; ---------------------------------------------------------------- clock
(define (cycles) (%cycles))
