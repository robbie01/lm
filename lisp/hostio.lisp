;;; hostio.lisp - build-time only.
;;;
;;; The forge prints and reads files while it compiles. None of this goes into
;;; the image; the machine gets print.lisp instead. The names below are the
;;; ones core.lisp and runtime.lisp call, defined again here so that the forge
;;; has its own version of each. Read by the bootstrap reader, so everything
;;; lands in the prelude.

(in-package lm)

(define (write x) (%write x))
(define (display x) (%display x))
(define (newline) (%newline))
(define (print x) (%write x) (%newline) x)
(define (princ x) (%display x) x)
(define (error . args) (%apply %error args))
(define (gensym-1) (%gensym))
(define (cycles) 0)

;; The forge allocates straight out of the heap it is building.
(define (make-string-n n) (%make-string n))
(define (make-bytes-n n) (%make-bytes n))
(define (make-vector-n n fill) (%make-vector n fill))
(define (intern-string s) (%intern s))

(define (compile-time-eval form) (%eval form))

;; A top level form that is not a definition becomes a thunk on the boot list,
;; and a variable initialiser an assignment on the same list; the image runs
;; them in order when it starts.
(define (top-level-form form) (add-boot-thunk form))
(define (record-initialiser name expr)
  (add-boot-thunk (list 'set! name expr)))
(define (register-macro form) (%eval form))

;; A macro is whatever the bootstrap interpreter has recorded.
(define (macro-form? form)
  (if (%cons? form)
      (if (%symbol? (%car form)) (%macro? (%car form)) nil)
      nil))
(define (expand-macro form) (%macroexpand-1 form))
(define (alloc-object type len) (%alloc-obj type len))
(define (alloc-code n) (%alloc-code n))

(define *compile-trace* nil)

;; The machine's own reader, running interpreted: the forge has no reader of
;; its own past the one that got this far.
(define (compile-file path)
  (let ((forms (read-forms-from-string (%read-file path))))
    (dolist (f forms)
      (if *compile-trace*
          (begin
            (%display path) (%display ": ")
            (%display (if (%cons? f) (if (%cons? (cadr f)) (caadr f) (cadr f)) f))
            (%display "  pairs=")
            (%display (%lsh (%- (%ld-fixnum lg-cons-ptr) cons-base) -3))
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
