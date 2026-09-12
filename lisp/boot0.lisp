;;; boot0.lisp - two no-op package forms for the bootstrap.
;;;
;;; The forge reads the prelude with a reader that knows nothing about
;;; packages, so `in-package` and `defpackage` mean nothing until read.lisp
;;; defines the real ones. These let the prelude's files carry the same
;;; header as every other source. Read by the forge only; never compiled.

(defmacro in-package (name) nil)
(defmacro defpackage words nil)
