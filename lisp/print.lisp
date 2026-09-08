;;; print.lisp - the machine's own printer and reader.
;;;
;;; Everything here is compiled into the image. It is what the REPL uses, and
;;; it is deliberately written against a "put one character" function so the
;;; same printer serves the serial console, a string, or later a window.

;; ---------------------------------------------------------------- sinks
;; A sink is a closure taking one character code. The serial port is the
;; default and the one that works earliest in the boot.
(define *out* nil)

(define (out-char n) (%st32! uart-data n))

(define (emit-ch c)
  (if *out* (%funcall *out* c) (out-char c)))

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
       ((%= ty t-symbol) (emit-str (%symbol-name x)))
       ((%= ty t-string) (if quoted (write-string-quoted x) (emit-str x)))
       ((%= ty t-vector) (print-vector x quoted depth))
       ((%= ty t-closure)
        (emit-str "#<function ")
        (emit-str (number->hex (%from-addr (%raw-ld (%addr-of x)))))
        (emit-ch 62))
       ((%= ty t-bytes)
        (emit-str "#<bytes ")
        (emit-str (number->string (%obj-len x)))
        (emit-ch 62))
       ((%= ty t-record) (print-record x quoted depth))
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
