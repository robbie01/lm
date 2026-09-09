;;; boot0.lisp - the first thing the bootstrap reads, and nothing is up yet.
;;;
;;; The reader that reads this file knows how to make a list and nothing else:
;;; no packages, no pkg:name, no idea that `in-package` is anything but a call.
;;; That is on purpose - the reader that does know all of that is written in
;;; Lisp, in lisp/read.lisp, and something has to get far enough to run it.
;;;
;;; So every source still says which package it belongs to, and for the files
;;; the bootstrap reader reads that statement is true but inert: they are the
;;; prelude, they are one namespace, and so is it. These two no-ops let them
;;; say it anyway. read.lisp replaces them with the real ones, by which point
;;; there is an allocator to make a package out of.
;;;
;;; This file is read by the forge and never compiled into an image.

(defmacro in-package (name) nil)
(defmacro defpackage words nil)
