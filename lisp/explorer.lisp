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
;;;
;;; Some of what the explorer shows nobody else may hold: an unsafe name's
;;; value, a closure's entry, code and free variables, which only its own
;;; code reaches, a code object's literals, and whatever is reached through
;;; one of those. These are private. The explorer reaches them in blocks of
;;; its own and keeps them in a table each window's closures hold and
;;; nothing else does: a row of the window holds a token for a private value,
;;; never the value, and its label names the value by its kind and its
;;; capability's fields, which are numbers, so no name a program could define
;;; again is handed one. What the explorer hands its callers, `parts` and
;;; `symbol-parts`, says that a private value is there and holds nothing.

(in-package explorer)

(defconstant label-max 96)

;; ---------------------------------------------------------------- capabilities
(define perm-names
  (list (%cons perm-ld "LD") (%cons perm-sd "SD") (%cons perm-lc "LC")
        (%cons perm-sc "SC") (%cons perm-lm "LM") (%cons perm-ex "EX")
        (%cons perm-sr "SR") (%cons perm-se "SE") (%cons perm-hd "HD")))

;; Tagged, and neither nil, a pair nor an object, as the processor tells them
;; apart. HD alone does not make an object: the root and object space's own
;; capability have it, and neither is based past the start of object space,
;; where a header could be.
(defsubst (raw-capability? x)
  (if (%cap-tag? x)
      (if (%null? x)
          nil
          (if (%cons? x) nil (if (%object? x) nil t)))
      nil))

(define (hex n) (string-append "0x" (number->hex n)))

;; The fields of a capability, as numbers, which is all these are handed.
(define (perms-string ps)
  (let ((s nil))
    (dolist (pn perm-names)
      (if (%= 0 (%logand ps (%car pn)))
          nil
          (set! s (if s (string-append s " " (%cdr pn)) (%cdr pn)))))
    (if s s "none")))

(define (seal-string o)
  (cond ((%= o 0) "unsealed")
        ((%= o otype-sentry) "sealed as a sentry")
        ((%= o otype-closure) "sealed as a closure")
        (else (string-append "sealed with otype " (number->string o)))))

;; `%cap-len` reads a length of 2^31 or more as negative, and saturates the
;; root's, 2^32, at 0xffffffff.
(define (length-string n)
  (cond ((%= n -1) "4294967296")
        ((%< n 0) (number->string (+ n 4294967296)))
        (else (number->string n))))

;; The address, the bounds and the permissions, as the printer shows them.
(define (fields-summary addr base top perms)
  (with-output-to-string (lambda () (emit-cap-fields addr base top perms))))

(define (fact name s) (list (string-append name ": " s) nil nil))

(defsubst (capability-parts c)
  (list (fact "address" (hex (%addr-of c)))
        (fact "base" (hex (%cap-base c)))
        (fact "top" (string-append "0x" (cap-top-hex c)))
        (fact "length" (length-string (%cap-len c)))
        (fact "permissions" (perms-string (%cap-perms c)))
        (fact "seal" (seal-string (%cap-otype c)))))

;; ---------------------------------------------------------------- printing
;; What a row says about a value anybody may hold: its printed form, cut to
;; fit.
(define (brief x)
  (let ((s (write-to-string x)))
    (if (%> (string-length s) label-max)
        (string-append (substring s 0 label-max) "...")
        s)))

(define (labelled name x) (string-append name ": " (brief x)))

;; What a row says about a private value, which the printer is not handed:
;; an immediate as it is, nil and a symbol by name, anything else by its
;; kind and its capability's fields.
(define (kind-word ty)
  (cond ((%= ty t-vector) "a vector")
        ((%= ty t-string) "a string")
        ((%= ty t-bytes) "a byte object")
        ((%= ty t-symbol) "a symbol")
        ((%= ty t-closure) "a function")
        ((%= ty t-record) "a record")
        ((%= ty t-code) "a code object")
        ((%= ty t-bignum) "a bignum")
        ((%= ty t-float) "a float")
        ((%= ty t-context) "a register context")
        ((%= ty t-stack) "a stack")
        ((%= ty t-text) "machine code")
        ((%= ty t-kernel) "the kernel block")
        (else "an object")))

(defsubst (private-brief v)
  (cond ((if (%cap-tag? v) nil t) (write-to-string (%addr-of v)))
        ((%null? v) "nil")
        ((%symbol? v) (%symbol-name v))
        (else (string-append
               (cond ((%cons? v) "a pair")
                     ((%object? v) (kind-word (%obj-type v)))
                     (else "a capability"))
               " "
               (fields-summary (%addr-of v) (%cap-base v) (cap-top-hex v) (%cap-perms v))))))

;; ---------------------------------------------------------------- rows
;; A row is what the outline takes: (label object has-parts?). Whether a
;; value opens onto anything: every pointer but nil does, onto its
;; capability at least, and no number does.
(defsubst (has-parts? x) (if (%null? x) nil (%cap-tag? x)))

(define (part name x) (list (labelled name x) x (has-parts? x)))

;; A private value's row. With a window's table, `hold`, the row holds a
;; fresh token, and the table the value; with none, the row says the value
;; is there and holds nothing. Built from intrinsics alone: the value is
;; handed to no name a program could define again.
(define (private-part name v hold)
  (declare unsafe)
  (if hold
      (let ((token (%cons nil nil)))
        (%set-car! hold (%cons (%cons token v) (%car hold)))
        (%cons (string-append name ": " (private-brief v))
               (%cons token (%cons (has-parts? v) nil))))
      (fact name "withheld")))

;; The value a window's token stands for, or the token itself for anything
;; else.
(define (held x hold)
  (declare unsafe)
  (let ((p (if hold (%car hold) nil)) (v x) (go t))
    (while (if go (%cons? p) nil)
      (if (%eq? (%car (%car p)) x) (begin (set! v (%cdr (%car p))) (set! go nil)) (set! p (%cdr p))))
    v))

;; A slot of value `v`, private when `private` says so.
(defsubst (slot-part name v private hold)
  (declare unsafe)
  (if private (private-part name v hold) (part name v)))

;; Every cell of a symbol. Its value is private when the name is unsafe;
;; the function slot is the compiler's, a macro's expander or an intrinsic's
;; note, and that and the property list are anybody's to read.
(define (symbol-rows s hold)
  (declare unsafe)
  (let ((acc nil) (v (unsafe (%symbol-value s))))
    (if (%eq? v (%unbound))
        nil
        (set! acc (%cons (if (symbol-unsafe? s) (unsafe (private-part "value" v hold)) (part "value" v)) acc)))
    (if (%symbol-function s)
        (set! acc (%cons (part "function" (%symbol-function s)) acc))
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
  (let ((acc nil) (l (unsafe (all-symbols))))
    (while (%cons? l)
      (if (%eq? (symbol-package (%car l)) p) (set! acc (%cons (%car l) acc)) nil)
      (set! l (%cdr l)))
    (sort acc symbol<?)))

(define (package-rows p)
  (map (lambda (s) (list (symbol-name s) s t)) (package-symbols p)))

(define (list-rows x private hold)
  (declare unsafe)
  (let ((acc nil) (i 0) (l x))
    (while (if (%cons? l) (%< i 500) nil)
      (set! acc (%cons (unsafe (slot-part (number->string i) (%car l) private hold)) acc))
      (set! i (%+ i 1))
      (set! l (%cdr l)))
    (cond ((%cons? l) (set! acc (%cons (list "..." nil nil) acc)))
          ((%null? l) nil)
          (else (set! acc (%cons (unsafe (slot-part "." l private hold)) acc))))
    (reverse acc)))

(define (vector-rows v private hold)
  (declare unsafe)
  (let ((acc nil) (i 0) (n (%vector-length v)))
    (if (%> n 500) (set! n 500) nil)
    (while (%< i n)
      (set! acc (%cons (unsafe (slot-part (number->string i) (%vector-ref v i) private hold)) acc))
      (set! i (%+ i 1)))
    (if (%< n (%vector-length v)) (set! acc (%cons (list "..." nil nil) acc)) nil)
    (reverse acc)))

;; A record's fields by name when its shape is known, by index otherwise.
(define (record-rows r private hold)
  (declare unsafe)
  (let* ((shape (record-shape (%record-ref r 0)))
         (fields (if shape (shape-fields shape) nil))
         (n (%obj-len r))
         (acc nil)
         (i 1))
    (while (%< i n)
      (let ((name (if (%cons? fields)
                      (symbol-name (%car fields))
                      (number->string i))))
        (set! acc (%cons (unsafe (slot-part name (%record-ref r i) private hold)) acc)))
      (if (%cons? fields) (set! fields (%cdr fields)) nil)
      (set! i (%+ i 1)))
    (reverse acc)))

;; A closure is sealed, so that only its own code can read what it holds. The
;; explorer opens it through the escape hatch: the root, at the closure
;; otype, is authority to unseal it. What is in its slots is private.
(define (closure-rows c hold)
  (declare unsafe)
  (unsafe
  (let* ((o (open-closure c))
         (acc (%cons (private-part "code" (%slot o clo-code) hold)
                     (%cons (private-part "entry" (%slot o clo-entry) hold) nil)))
         (i clo-free)
         (n (%obj-len o)))
    (while (%< i n)
      (set! acc (%cons (private-part (string-append "free " (number->string (%- i clo-free)))
                                     (%slot o i) hold)
                       acc))
      (set! i (%+ i 1)))
    (reverse acc))))

;; The entry is a capability to the machine code, so its length is the
;; code's. What a code object holds is private.
(define (code-rows c hold)
  (declare unsafe)
  (unsafe
  (let* ((entry (%slot c code-entry))
         (acc (%cons (private-part "name" (%slot c code-name) hold)
                     (%cons (private-part "entry" entry hold)
                            (%cons (fact "bytes" (number->string (%cap-len entry))) nil))))
         (i code-lits)
         (n (%obj-len c)))
    (while (%< i n)
      (set! acc (%cons (private-part (string-append "literal " (number->string (%- i code-lits)))
                                     (%slot c i) hold)
                       acc))
      (set! i (%+ i 1)))
    (reverse acc))))

;; A pointer's parts start with what its capability says, and a sealed
;; one's with its seal on the row after. `private` says whether `x` is
;; itself private, and so all that is reached through it.
(define (rows x private hold)
  (declare unsafe)
  (if (raw-capability? x)
      (capability-parts x)
      (let ((ps (unsafe
                 (cond ((%cons? x) (list-rows x private hold))
                       ((%vector? x) (vector-rows x private hold))
                       ((%symbol? x) (symbol-rows x hold))
                       ((%closure? x) (closure-rows x hold))
                       ((if (%object? x) (%= (%obj-type x) t-code) nil) (code-rows x hold))
                       ((if (%record? x) (%eq? (%record-ref x 0) 'package) nil) (package-rows x))
                       ((%record? x) (record-rows x private hold))
                       (else nil)))))
        (if (%cap-tag? x)
            (%cons (fact "capability" (fields-summary (%addr-of x) (%cap-base x) (cap-top-hex x) (%cap-perms x)))
                   (if (%cap-sealed? x) (%cons (fact "seal" (seal-string (%cap-otype x))) ps) ps))
            ps))))

;; What anybody may ask: the parts of a value they hold, every private one
;; withheld.
(define (parts x) (unsafe (rows x nil nil)))
(define (symbol-parts s) (unsafe (symbol-rows s nil)))

;; A window's rows: the parts of what a row holds, a token standing for its
;; private value, and of anything else as it is.
(define (window-rows x hold)
  (declare unsafe)
  (unsafe
  (let ((v (held x hold)))
    (rows v (if (%eq? v x) nil t) hold))))

;; The function a window's outline asks for a row's parts, over the table
;; that window keeps. What it answers holds tokens, never a private value.
(define (browser hold)
  (declare unsafe)
  (lambda (x) (unsafe (window-rows x hold))))

;; ---------------------------------------------------------------- the window
(define *count* 0)

;; The table is the window's own, held by its closures and by no record: the
;; window and its outline are anybody's to read, and hold tokens.
(define (open-explorer title roots hold)
  (declare unsafe)
  (if (%null? *screen*) (error "explorer: start the workbench first") nil)
  (let* ((n *count*)
         (win (make-window (%+ 60 (%* (%mod n 6) 30)) (%+ 50 (%* (%mod n 6) 24)) 480 340 title))
         (ol (ui:make-outline (win-inner-x win) (win-inner-y win)
                              (win-inner-w win) (win-inner-h win)
                              roots (unsafe (browser hold)))))
    (set! *count* (%+ n 1))
    (set-win-data! win ol)
    (set-win-refresh! win (lambda (w) (ui:draw-outline ol (window-rastport w))))
    (set-win-task! win (add-task "explorer" 0 (lambda () (unsafe (explorer-task win ol hold)))))
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
;; long after the hand had stopped. A row opened in a window of its own
;; takes the table with it, so a private value opens there too.
(define (explorer-task win ol hold)
  (declare unsafe)
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
                   (if (has-parts? x) (unsafe (open-on (ui:rw-label (%cdr r)) x hold)) nil)))
                (else nil)))
        (set! ev (window-event win)))
      (if changed (redraw win ol) nil))))

;; A window open at the top of what a row holds.
(define (open-on title x hold)
  (declare unsafe)
  (let ((win (unsafe (open-explorer title (list (list title x t)) hold))))
    (let ((ol (win-data win)))
      (ui:expand! ol (%car (ui:ol-roots ol)))
      (redraw win ol))
    win))

;; Every package, and under each one its symbols.
(define (explorer)
  (let ((roots (map (lambda (p) (list (package-name p) p t))
                    (sort (all-packages)
                          (lambda (a b) (string<? (package-name a) (package-name b)))))))
    (unsafe (open-explorer "Symbols" roots (%cons nil nil)))))

;; Any object, open at the top.
(define (explore x)
  (let ((title (brief x)))
    (if (has-parts? x)
        (unsafe (open-on title x (%cons nil nil)))
        (let ((roots (list (list title x nil))))
          (unsafe (open-explorer title roots (%cons nil nil)))))))
