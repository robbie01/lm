;;; hostio.lisp - build-time only.
;;;
;;; The forge needs to print and to read files while it is compiling. None of
;;; this is compiled into the image; the machine gets print.lisp instead, which
;;; does the same jobs against the serial port and the heap rather than against
;;; the host's stdio. This file exists so that core.lisp can stay compilable.

;; The prelude, like everything else the bootstrap reader reads - and that is
;; what makes this file work at all. The names below are the names core.lisp
;; and runtime.lisp use; defining them again here is how the forge ends up
;; with its own version of each.
(in-package lm)

(define (write x) (%write x))
(define (display x) (%display x))
(define (newline) (%newline))
(define (print x) (%write x) (%newline) x)
(define (princ x) (%display x) x)
(define (error . args) (%apply %error args))
(define (gensym-1) (%gensym))
(define (cycles) 0)

;; The forge allocates straight out of the heap it is building, so the runtime
;; helpers can be satisfied with the primitives rather than with compiled code.
(define (make-string-n n) (%make-string n))
(define (make-bytes-n n) (%make-bytes n))
(define (make-vector-n n fill) (%make-vector n fill))
(define (intern-string s) (%intern s))

(define (compile-time-eval form) (%eval form))

;; While the forge is building, a top level form that is not a definition
;; becomes a thunk on the boot list, and a variable initialiser becomes an
;; assignment on that same list. The image re-runs them in order when it
;; starts, which is what makes a saved heap a saved *running system*.
(define (top-level-form form) (add-boot-thunk form))
(define (record-initialiser name expr)
  (add-boot-thunk (list 'set! name expr)))
(define (register-macro form) (%eval form))

;; At build time a macro is whatever the bootstrap interpreter has recorded.
(define (macro-form? form)
  (if (%cons? form)
      (if (%symbol? (%car form)) (%macro? (%car form)) nil)
      nil))
(define (expand-macro form) (%macroexpand-1 form))
(define (alloc-object type len) (%alloc-obj type len))
(define (alloc-code n) (%alloc-code n))

;; Reading source files is the forge's job; the machine has no filesystem.
(define *compile-trace* nil)

(define (compile-file path)
  ;; read-forms-from-string is the machine's own reader, running here. The
  ;; forge has no reader of its own past the one that got this far.
  (let ((forms (read-forms-from-string (%read-file path))))
    (dolist (f forms)
      (if *compile-trace*
          (begin
            (%display path) (%display ": ")
            (%display (if (%cons? f) (if (%cons? (cadr f)) (caadr f) (cadr f)) f))
            (%display "  pairs=")
            (%display (%lsh (%- (%global lg-cons-ptr) cons-base) -3))
            (%newline)
            (%flush))
          nil)
      (compile-top f))
    (length forms)))

(define (print-report label n)
  (%display label)
  (%display " ")
  (%display n)
  (%newline))
