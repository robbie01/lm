;;; explorer.lisp - a window onto every symbol in the heap.
;;;
;;; `(explorer)` opens an outline of the packages. A package opens onto its
;;; symbols, a symbol onto its value, function and property list, and a
;;; value onto its parts: the elements of a list or vector, the fields of a
;;; record by name, the code and free variables of a function, the literals
;;; of a code object. `(explore x)` opens the same outline on any object.
;;; Double-clicking a row, or pressing return on it, opens a new explorer on
;;; what the row holds.
;;;
;;; Every value is a capability, and every pointer's row opens first onto
;;; what its capability says: the address, the bounds, the permissions and the
;;; seal. A raw capability, a code entry, a stack or a device page, is nothing
;;; but that, and opens onto it in full.

(in-package explorer)

(defconstant label-max 96)

;; ---------------------------------------------------------------- capabilities
(define perm-names
  (list (%cons perm-ld "LD") (%cons perm-sd "SD") (%cons perm-lc "LC")
        (%cons perm-sc "SC") (%cons perm-lm "LM") (%cons perm-ex "EX")
        (%cons perm-sr "SR") (%cons perm-se "SE") (%cons perm-hd "HD")))

;; Tagged, and neither nil, a pair nor an object, as the processor tells them
;; apart. HD alone does not make an object: the root has every permission,
;; and its base has no header below it.
(define (raw-capability? x)
  (if (%cap-tag? x)
      (if (%null? x)
          nil
          (if (%cons? x) nil (if (%object? x) nil t)))
      nil))

(define (hex n) (string-append "0x" (number->hex n)))

(define (perms-string c)
  (let ((ps (%cap-perms c)) (s nil))
    (dolist (pn perm-names)
      (if (%= 0 (%logand ps (%car pn)))
          nil
          (set! s (if s (string-append s " " (%cdr pn)) (%cdr pn)))))
    (if s s "none")))

(define (seal-string c)
  (if (%cap-sealed? c)
      (let ((o (%cap-otype c)))
        (cond ((%= o otype-sentry) "sealed as a sentry")
              ((%= o otype-closure) "sealed as a closure")
              (else (string-append "sealed with otype " (number->string o)))))
      "unsealed"))

;; The address, the bounds and the permissions, as the printer shows them.
(define (cap-summary c)
  (with-output-to-string (lambda () (emit-cap-summary c))))

;; `%cap-len` reads a length of 2^31 or more as negative, and saturates the
;; root's, 2^32, at 0xffffffff.
(define (length-string c)
  (let ((n (%cap-len c)))
    (cond ((%= n -1) "4294967296")
          ((%< n 0) (number->string (+ n 4294967296)))
          (else (number->string n)))))

(define (fact name s) (list (string-append name ": " s) nil nil))

(define (capability-parts c)
  (list (fact "address" (hex (%addr-of c)))
        (fact "base" (hex (%cap-base c)))
        (fact "top" (string-append "0x" (cap-top-hex c)))
        (fact "length" (length-string c))
        (fact "permissions" (perms-string c))
        (fact "seal" (seal-string c))))

;; ---------------------------------------------------------------- printing
;; What a row says about an object: its printed form, cut to fit.
(define (brief x)
  (let ((s (write-to-string x)))
    (if (%> (string-length s) label-max)
        (string-append (substring s 0 label-max) "...")
        s)))

(define (labelled name x) (string-append name ": " (brief x)))

;; ---------------------------------------------------------------- parts
;; Whether a value opens onto anything: every pointer but nil does, onto its
;; capability at least, and no number does.
(define (has-parts? x) (if (%null? x) nil (%cap-tag? x)))

(define (part name x) (list (labelled name x) x (has-parts? x)))

(define (symbol-parts s)
  (let ((acc nil))
    (if (%eq? (symbol-value s) (%unbound))
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
  (unsafe
  (let ((acc nil) (l (%ld-cap lg-symlist)))
    (while (%cons? l)
      (if (%eq? (symbol-package (%car l)) p) (set! acc (%cons (%car l) acc)) nil)
      (set! l (%cdr l)))
    (sort acc symbol<?))))

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
        (set! acc (%cons (part name (%record-ref r i)) acc)))
      (if (%cons? fields) (set! fields (%cdr fields)) nil)
      (set! i (%+ i 1)))
    (reverse acc)))

;; A closure is sealed, so that only its own code can read what it holds. The
;; explorer opens it through the escape hatch: the root, at the closure
;; otype, is authority to unseal it. The opened capability stays here; the
;; rows hold what is in its slots.
(define (closure-parts c)
  (unsafe
  (let* ((o (open-closure c))
         (acc (reverse (list (part "entry" (%slot o clo-entry))
                             (part "code" (%slot o clo-code)))))
         (i clo-free)
         (n (%obj-len o)))
    (while (%< i n)
      (set! acc (%cons (part (string-append "free " (number->string (%- i clo-free)))
                             (%slot o i))
                       acc))
      (set! i (%+ i 1)))
    (reverse acc))))

;; The entry is a capability to the machine code, so its length is the
;; code's.
(define (code-parts c)
  (unsafe
  (let* ((entry (%slot c code-entry))
         (acc (reverse (list (fact "bytes" (number->string (%cap-len entry)))
                             (part "entry" entry)
                             (part "name" (%slot c code-name)))))
         (i code-lits)
         (n (%obj-len c)))
    (while (%< i n)
      (set! acc (%cons (part (string-append "literal " (number->string (%- i code-lits)))
                             (%slot c i))
                       acc))
      (set! i (%+ i 1)))
    (reverse acc))))

;; A pointer's parts start with what its capability says, and a sealed
;; one's with its seal on the row after.
(define (parts x)
  (if (raw-capability? x)
      (capability-parts x)
      (let ((ps (cond ((%cons? x) (list-parts x))
                      ((%vector? x) (vector-parts x))
                      ((%symbol? x) (symbol-parts x))
                      ((%closure? x) (closure-parts x))
                      ((code-object? x) (code-parts x))
                      ((package? x) (package-parts x))
                      ((%record? x) (record-parts x))
                      (else nil))))
        (if (%cap-tag? x)
            (%cons (fact "capability" (cap-summary x))
                   (if (%cap-sealed? x) (%cons (fact "seal" (seal-string x)) ps) ps))
            ps))))

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
;; window before there is somewhere for it to go. Every event waiting is
;; taken before the outline is drawn again, and it is drawn once for all of
;; them: a drawing costs more than a frame, and a wheel or a held key sends
;; events faster than that, which drawn one by one would go on scrolling
;; long after the hand had stopped.
(define (explorer-task win ol)
  (set-win-port! win (make-port nil 0))
  (while t
    (let ((ev (window-wait-event win)) (changed nil))
      (while ev
        (let ((r (ui:outline-event ol ev)))
          (cond ((%null? r) nil)
                ((%eq? r 'changed) (set! changed t))
                ((%cons? r)
                 (redraw win ol)
                 (set! changed nil)
                 (let ((x (ui:rw-object (%cdr r))))
                   (if (has-parts? x) (explore x) nil)))
                (else nil)))
        (set! ev (window-event win)))
      (if changed (redraw win ol) nil))))

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
