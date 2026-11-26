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
  (if (%object? v) (%= (%obj-type v) t-code) nil))

;; A symbol for a named function; (lambda . home) for one that never had a
;; name, so an anonymous frame still says where it came from; and (unsafe k
;; . name) for the island of a function's kth unsafe block.
(define (emit-name n)
  (cond ((%null? n) (emit-str "anonymous"))
        ((if (%cons? n) (%eq? (%car n) 'unsafe) nil)
         (emit-name (cddr n))
         (emit-str ", unsafe block ")
         (emit-digits (cadr n)))
        ((%cons? n) (emit-str "lambda in ") (emit-name (%cdr n)))
        ((%symbol? n) (emit-str (%symbol-name n)))
        (else (emit-str "anonymous"))))

;; A small number's digits, without making a string.
(define (emit-digits k)
  (if (%>= k 10) (emit-digits (%/ k 10)) nil)
  (emit-ch (%int->char (%+ 48 (%rem k 10)))))

(define (emit-code-label c)
  (unsafe
  (if (code-object? c) (emit-name (%slot c code-name)) (emit-str "?"))))

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

;; A character with neither a name nor a glyph is written as its code in
;; hex, #\x0, which the reader takes back.
(define (write-char-name c)
  (emit-str "#\\")
  (let ((n (%char->int c)))
    (cond ((%eq? c #\space) (emit-str "space"))
          ((%eq? c #\newline) (emit-str "newline"))
          ((%eq? c #\tab) (emit-str "tab"))
          ((%= n 13) (emit-str "return"))
          ((%eq? c #\backspace) (emit-str "backspace"))
          ((if (%> n 32) (%< n 127) nil) (emit-ch c))
          (else (emit-ch #\x) (emit-str (number->hex n))))))

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
   ((%closure? x) (print-function x))
   ((%object? x)
    (let ((ty (%obj-type x)))
      (cond
       ((%= ty t-bignum) (emit-str (bignum->string x)))
       ((%= ty t-symbol) (print-symbol x))
       ((%= ty t-string) (if quoted (write-string-quoted x) (emit-str x)))
       ((%= ty t-vector) (print-vector x quoted depth))
       ((%= ty t-bytes)
        (emit-str "#<bytes ")
        (emit-str (number->string (%obj-len x)))
        (emit-ch #\>))
       ((%= ty t-float) (emit-str "#<float>"))
       ((%= ty t-code) (emit-str "#<code ") (emit-code-label x) (emit-ch #\>))
       ((%= ty t-port) (emit-str "#<port>"))
       ((%= ty t-record)
        (cond
         ((package? x)
          (emit-str "#<package ") (emit-str (package-name x)) (emit-ch #\>))
         (else (print-record x quoted depth))))
       (else (emit-str "#<object>")))))
   ((%cap-tag? x) (print-capability x))
   (else (print-immediate x))))

;; A closure is sealed, and only its own code may look inside it, by being
;; called. The printer opens it through the escape hatch, the root's
;; authority over the closure otype, to reach its code object and so its
;; name.
(define (print-function x)
  (unsafe
  (let ((c (if (%cap-sealed? x) (open-closure x) x)))
    (emit-str "#<function ")
    (emit-code-label (%slot c clo-code))
    (emit-ch #\>))))

;; A capability that is not a Lisp value: code, a stack, a device, a cons
;; run. Its address, its bounds, what it permits and how it is sealed:
;;
;;   #<capability 0x2040 [0x2000,0x3000) rwRWm>
;;   #<capability 0x10002a4 [0x1000200,0x1000400) xs sentry>
;;
;; A device, a page sealed with the devices' otype, is named by its page's
;; base: #<device disk>.
(define (print-capability x)
  (let ((name (if (%cap-sealed? x)
                  (if (%= (%cap-otype x) otype-device) (device-name x) nil)
                  nil)))
    (if name
        (begin (emit-str "#<device ") (emit-str name) (emit-ch #\>))
        (print-raw-capability x))))

(define (print-raw-capability x)
  (emit-str "#<capability ")
  (emit-cap-summary x)
  (if (%cap-sealed? x)
      (if (%= (%cap-otype x) otype-sentry)
          (emit-str " sentry")
          (begin (emit-str " sealed ") (emit-str (number->string (%cap-otype x)))))
      nil)
  (emit-ch #\>))

;; The address, the bounds and the permissions: 0x2040 [0x2000,0x3000) rwRWm.
(define (emit-cap-summary x)
  (emit-str "0x")
  (emit-str (number->hex (%addr-of x)))
  (emit-str " [0x")
  (emit-str (number->hex (%cap-base x)))
  (emit-str ",0x")
  (emit-str (cap-top-hex x))
  (emit-str ") ")
  (emit-perms (%logand (%cap-perms x) perms-all)))

;; `%cap-top` saturates, so a top of 2^32, the root's, reads as 0xffffffff.
;; A capability that really ends there is shorter than 256 bytes, because a
;; longer one's top is aligned.
(define (cap-top-saturated? x)
  (if (%= (%cap-top x) -1)
      (let ((n (%cap-len x))) (if (%< n 0) t (%> n 255)))
      nil))

(define (cap-top-hex x)
  (if (cap-top-saturated? x) "100000000" (number->hex (%cap-top x))))

;; Each permission as a letter, in the order of the bits: r and w to load and
;; store data, R and W capabilities, m load mutable, x execute, s the system
;; registers, e seal and unseal, h headed.
(define perm-letters
  (list (%cons perm-ld "r") (%cons perm-sd "w") (%cons perm-lc "R") (%cons perm-sc "W")
        (%cons perm-lm "m") (%cons perm-ex "x") (%cons perm-sr "s") (%cons perm-se "e")
        (%cons perm-hd "h")))

(define (emit-perms p)
  (if (%= p 0)
      (emit-ch #\-)
      (dolist (e perm-letters)
        (if (%= 0 (%logand p (%car e))) nil (emit-str (%cdr e))))))

;; The immediates that are not characters, told apart by their metadata: the
;; marker of a variable with no value, the end of a file, no value at all,
;; and the marker of an argument not given. Anything else untagged is data
;; that is not a Lisp value, shown as its metadata and its address.
(define (print-immediate x)
  (let ((m (%cap-high x)))
    (cond ((%= m imm-unbound) (emit-str "#<unbound>"))
          ((%= m imm-eof) (emit-str "#<eof>"))
          ((%= m imm-void) (emit-str "#<void>"))
          ((%= m imm-default) (emit-str "#<default>"))
          (else (emit-str "#<immediate 0x")
                (emit-str (number->hex m))
                (emit-str " 0x")
                (emit-str (number->hex (%addr-of x)))
                (emit-ch #\>)))))

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
        (if (%> (%obj-len r) 0) (print-obj (%record-ref r 0) quoted (%+ depth 1)) nil)
        (emit-str " ..."))
      (let ((i 0) (n (%obj-len r)))
        (while (%< i n)
          (if (%> i 0) (space) nil)
          (print-obj (%record-ref r i) quoted (%+ depth 1))
          (set! i (%+ i 1)))))
  (emit-ch #\]))

(define (write x) (print-obj x t 0) x)
(define (display x) (print-obj x nil 0) x)
(define (print x) (write x) (newline) x)
(define (princ x) (display x) x)

(define (write-to-string x) (with-output-to-string (lambda () (write x))))
(define (display-to-string x) (with-output-to-string (lambda () (display x))))

;; ---------------------------------------------------------------- errors
;; There is no condition system. An error prints what it knows and calls the
;; error handler, which the kickstart sets to trap, and the trap handler
;; prints a backtrace and restarts the prompt, or ends the task. Declared,
;; not initialised, so the boot list does not empty it; until there is one,
;; an error stops the machine.
(define *error-handler*)

(define (error . args)
  (unsafe
  (emit-str "error: ")
  (let ((first t))
    (dolist (a args)
      (if first (set! first nil) (space))
      (if (%string? a) (emit-str a) (write a))))
  (newline)
  (let ((h (if (%eq? (%symbol-value '*error-handler*) (%unbound)) nil *error-handler*)))
    (if h (%funcall h args) (%halt exit-error)))))

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
