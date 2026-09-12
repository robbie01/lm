;;; explorer.lisp - a window onto every symbol in the heap.
;;;
;;; `(explorer)` opens an outline of the packages. A package opens onto its
;;; symbols, a symbol onto its value, function and property list, and a
;;; value onto its parts: the elements of a list or vector, the fields of a
;;; record by name, the code and free variables of a function, the literals
;;; of a code object. `(explore x)` opens the same outline on any object.
;;; Double-clicking a row, or pressing return on it, opens a new explorer on
;;; what the row holds.

(in-package explorer)

(define label-max 96)

;; ---------------------------------------------------------------- printing
;; What a row says about an object: its printed form, cut to fit.
(define (brief x)
  (let ((s (cond ((code-object? x)
                  (string-append "#<code " (display-to-string (%slot x code-name)) ">"))
                 ((package? x) (string-append "#<package " (package-name x) ">"))
                 (else (write-to-string x)))))
    (if (%> (string-length s) label-max)
        (string-append (substring s 0 label-max) "...")
        s)))

(define (labelled name x) (string-append name ": " (brief x)))

;; ---------------------------------------------------------------- parts
;; Whether an object opens onto anything.
(define (has-parts? x)
  (cond ((%null? x) nil)
        ((%cons? x) t)
        ((%vector? x) (%> (%vector-length x) 0))
        ((%symbol? x) t)
        ((%closure? x) t)
        ((code-object? x) t)
        ((%record? x) t)
        (else nil)))

(define (part name x) (list (labelled name x) x (has-parts? x)))

(define (symbol-parts s)
  (let ((acc nil))
    (if (%eq? (symbol-value s) *unbound*)
        nil
        (set! acc (%cons (part "value" (symbol-value s)) acc)))
    (if (symbol-function s)
        (set! acc (%cons (part "function" (symbol-function s)) acc))
        nil)
    (if (symbol-plist s)
        (set! acc (%cons (part "plist" (symbol-plist s)) acc))
        nil)
    (set! acc (%cons (list (string-append "package: "
                                          (if (symbol-package s)
                                              (package-name (symbol-package s))
                                              "none"))
                           (symbol-package s)
                           (if (symbol-package s) t nil))
                     acc))
    (reverse acc)))

(define (symbol<? a b) (string<? (symbol-name a) (symbol-name b)))

(define (package-symbols p)
  (let ((acc nil) (l (%ld-word lg-symlist)))
    (while (%cons? l)
      (if (%eq? (symbol-package (%car l)) p) (set! acc (%cons (%car l) acc)) nil)
      (set! l (%cdr l)))
    (sort acc symbol<?)))

(define (package-parts p)
  (map (lambda (s) (list (symbol-name s) s t)) (package-symbols p)))

(define (list-parts x)
  (let ((acc nil) (i 0) (l x))
    (while (if (%cons? l) (%< i 500) nil)
      (set! acc (%cons (part (number->string i) (%car l)) acc))
      (set! i (%+ i 1))
      (set! l (%cdr l)))
    (cond ((%cons? l) (set! acc (%cons (list "..." nil nil) acc)))
          ((%null? l) nil)
          (else (set! acc (%cons (part "." l) acc))))
    (reverse acc)))

(define (vector-parts v)
  (let ((acc nil) (i 0) (n (min2 (%vector-length v) 500)))
    (while (%< i n)
      (set! acc (%cons (part (number->string i) (%vector-ref v i)) acc))
      (set! i (%+ i 1)))
    (if (%< n (%vector-length v)) (set! acc (%cons (list "..." nil nil) acc)) nil)
    (reverse acc)))

;; A record's fields by name when its shape is known, by index otherwise.
(define (record-parts r)
  (let* ((shape (record-shape (record-tag r)))
         (fields (if shape (shape-fields shape) nil))
         (n (%obj-len r))
         (acc nil)
         (i 1))
    (while (%< i n)
      (let ((name (if (%cons? fields)
                      (symbol-name (%car fields))
                      (number->string i))))
        (set! acc (%cons (part name (%slot r i)) acc)))
      (if (%cons? fields) (set! fields (%cdr fields)) nil)
      (set! i (%+ i 1)))
    (reverse acc)))

(define (closure-parts c)
  (let ((acc (list (part "code" (%slot c clo-code))))
        (i clo-free)
        (n (%obj-len c)))
    (while (%< i n)
      (set! acc (%cons (part (string-append "free " (number->string (%- i clo-free)))
                             (%slot c i))
                       acc))
      (set! i (%+ i 1)))
    (reverse acc)))

(define (code-parts c)
  (let ((acc (list (list (string-append "entry: " (number->hex (%ld-fixnum (%addr-of c)))) nil nil)
                   (list (string-append "bytes: " (number->string (%ld-fixnum (%+ (%addr-of c) 4)))) nil nil)
                   (part "name" (%slot c code-name))))
        (i code-lits)
        (n (%obj-len c)))
    (while (%< i n)
      (set! acc (%cons (part (string-append "literal " (number->string (%- i code-lits)))
                             (%slot c i))
                       acc))
      (set! i (%+ i 1)))
    (reverse acc)))

(define (parts x)
  (cond ((%cons? x) (list-parts x))
        ((%vector? x) (vector-parts x))
        ((%symbol? x) (symbol-parts x))
        ((%closure? x) (closure-parts x))
        ((code-object? x) (code-parts x))
        ((package? x) (package-parts x))
        ((%record? x) (record-parts x))
        (else nil)))

;; ---------------------------------------------------------------- the window
(define *count* 0)

(define (open-explorer title roots)
  (if (%null? *screen*) (error "explorer: start the workbench first") nil)
  (let* ((n *count*)
         (win (make-window (%+ 60 (%* (%mod n 6) 30)) (%+ 50 (%* (%mod n 6) 24)) 480 340 title))
         (ol (ui:make-outline (win-inner-x win) (win-inner-y win)
                              (win-inner-w win) (win-inner-h win)
                              roots parts)))
    (set! *count* (%+ n 1))
    (set-win-data! win ol)
    (set-win-refresh! win (lambda (w) (ui:draw-outline ol (window-rastport w))))
    (set-win-task! win (add-task "explorer" 0 (lambda () (explorer-task win ol))))
    (window-open win)
    win))

(define (redraw win ol)
  (ui:draw-outline ol (window-rastport win))
  (window-damage-rect win (win-inner-x win) (win-inner-y win)
                      (win-inner-w win) (win-inner-h win)))

;; The task makes its own port first, so that nothing can be sent to the
;; window before there is somewhere for it to go.
(define (explorer-task win ol)
  (set-win-port! win (make-port nil 0))
  (while t
    (let* ((ev (window-wait-event win))
           (r (ui:outline-event ol ev)))
      (cond ((%null? r) nil)
            ((%eq? r 'changed) (redraw win ol))
            ((%cons? r)
             (redraw win ol)
             (let ((x (ui:rw-object (%cdr r))))
               (if (has-parts? x) (explore x) nil)))
            (else nil)))))

;; Every package, and under each one its symbols.
(define (explorer)
  (open-explorer "Symbols"
                 (map (lambda (p) (list (package-name p) p t))
                      (sort (all-packages)
                            (lambda (a b) (string<? (package-name a) (package-name b)))))))

;; Any object, open at the top.
(define (explore x)
  (let ((win (open-explorer (brief x) (list (list (brief x) x (has-parts? x))))))
    (let ((ol (win-data win)))
      (if (has-parts? x) (ui:expand! ol (%car (ui:ol-roots ol))) nil)
      (redraw win ol))
    win))
