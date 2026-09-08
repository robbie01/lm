;;; runtime.lisp - what compiled code calls into.
;;;
;;; These run under the bootstrap interpreter while the image is being built
;;; and as native code afterwards, and both times they do exactly the same
;;; thing to exactly the same words of memory. Nothing here may create a
;;; closure: the compiler emits a call to `make-closure` for every lambda, so
;;; a lambda in this file would be a circle.

(in-package lm)

;; The immediate that marks a variable with no value yet: kind 1, payload 0.
(define *unbound* (%from-addr (%logior (%lsh imm-unbound 3) 2)))

;; ---------------------------------------------------------------- allocation
;; Object space is a bump allocator, like cons space, but objects vary in size
;; so the arithmetic does not fit in the four instructions the compiler inlines
;; for a pair.
(define (object-payload type len)
  (cond ((%= type t-string) len)
        ((%= type t-bytes) len)
        ((%= type t-symbol) (%* 4 sym-slots))
        ((%= type t-float) 4)
        (else (%* 4 len))))

;; alloc-object lives in gc.lisp, next to the free lists it draws from.

(define (make-closure code nfree)
  ;; The entry address is copied out of the code object rather than passed in,
  ;; so that a caller never has to know one. Both that word and the closure
  ;; slot it lands in are raw addresses, not tagged values, which is why they
  ;; go through %raw-ld and %raw-st! and not through the slot accessors.
  (let ((c (alloc-object t-closure (%+ 2 nfree))))
    (%raw-st! (%addr-of c) (%raw-ld (%addr-of code)))
    (%set-slot! c clo-code code)
    c))

(define (make-vector-n n fill)
  (let ((v (alloc-object t-vector n)) (i 0))
    (while (%< i n)
      (%set-slot! v i fill)
      (set! i (%+ i 1)))
    v))

(define (make-string-n n)
  (alloc-object t-string n))

(define (make-bytes-n n)
  (alloc-object t-bytes n))

(define (make-record n tag)
  (let ((r (alloc-object t-record n)))
    (%set-slot! r 0 tag)
    r))

;; ---------------------------------------------------------------- symbols
;; The obarray is a vector of buckets, each an association list keyed by name.
;; Interning has to be identical on both sides of the bootstrap or a symbol
;; read at build time and one read at run time would not be eq.
(define (string-hash s) (hash-string-into 5381 s))

(define (hash-string-into h s)
  ;; djb2, masked to 30 bits every round so every intermediate stays a fixnum.
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (set! h (%logand (%+ (%* h 33) (%char->int (%string-ref s i))) 1073741823))
      (set! i (%+ i 1)))
    h))

;; The obarray is keyed by package and name together, hashed over the package
;; name, a colon and the symbol name. Heap::qual_hash in the forge computes
;; exactly this, and the two agreeing is what makes a symbol read at build
;; time eq to one the running machine reads.
(define (qualified-hash pkg-name name)
  (hash-string-into
   (%logand (%+ (%* (hash-string-into 5381 pkg-name) 33) 58) 1073741823)
   name))

;; ---------------------------------------------------------------- packages
;; A package is a name and the list of packages whose exports it inherits.
;; What it holds is not stored in it: the obarray is keyed by package and
;; name, and every symbol knows which package is its home.
(define (package-name p) (%slot p pkg-name))
(define (package-use p) (%slot p pkg-use))
(define (set-package-use! p v) (%set-slot! p pkg-use v))
(define (symbol-package s) (%slot s sym-package))
(define (all-packages) (%raw-ld lg-packages))

(define (package? x)
  (if (%record? x) (%= (%obj-len x) pkg-slots) nil))

(define (find-package name)
  (let ((p (all-packages)) (found nil))
    (while (%cons? p)
      (if (string=? (package-name (%car p)) name)
          (begin (set! found (%car p)) (set! p nil))
          (set! p (%cdr p))))
    found))

(define (make-package name)
  (let ((old (find-package name)))
    (if old
        old
        (let ((p (make-record pkg-slots nil)))
          (%set-slot! p pkg-name name)
          (%set-slot! p pkg-use nil)
          (%raw-st! lg-packages (%cons p (%raw-ld lg-packages)))
          (%set-slot! p pkg-tag (intern-in p "package"))
          p))))

(define (symbol-exported? s)
  (%= sym-exported (%logand (symbol-flags s) sym-exported)))

(define (export-symbol! s)
  (%set-slot! s sym-flags
              (%logior (%slot s sym-flags) sym-exported))
  s)

;; ---------------------------------------------------------------- symbols
;; Interning has to be identical on both sides of the bootstrap or a symbol
;; read at build time and one read at run time would not be eq.
(define (find-symbol-in pkg s)
  (let* ((ob (%raw-ld lg-obarray))
         (n (%vector-length ob))
         (b (%mod (qualified-hash (package-name pkg) s) n))
         (chain (%vector-ref ob b))
         (found nil))
    (while (%cons? chain)
      (let ((sym (%car chain)))
        (if (if (%eq? (symbol-package sym) pkg)
                (string=? (%symbol-name sym) s)
                nil)
            (begin (set! found sym) (set! chain nil))
            (set! chain (%cdr chain)))))
    found))

(define (intern-in pkg s)
  (let ((found (find-symbol-in pkg s)))
    (if found
        found
        (let* ((ob (%raw-ld lg-obarray))
               (n (%vector-length ob))
               (b (%mod (qualified-hash (package-name pkg) s) n))
               (sym (alloc-object t-symbol sym-slots)))
          (%set-slot! sym sym-name s)
          (%set-slot! sym sym-value *unbound*)
          (%set-slot! sym sym-function nil)
          (%set-slot! sym sym-plist nil)
          ;; Flags in the low eight bits, the symbol's identity above them.
          ;; Interning is the only place a symbol comes from, here or in the
          ;; forge, so one counter in low memory is what stops the two sides
          ;; from ever handing out the same number.
          (%set-slot! sym sym-flags (%lsh (%global lg-symcount) 8))
          (%set-global! lg-symcount (%+ (%global lg-symcount) 1))
          (%set-slot! sym sym-package pkg)
          (%vector-set! ob b (%cons sym (%vector-ref ob b)))
          (%raw-st! lg-symlist (%cons sym (%raw-ld lg-symlist)))
          sym))))

;; What a bare name means here: this package first, then whatever the packages
;; it uses have exported, and failing both a new symbol of its own.
(define (find-visible pkg s)
  ;; What a bare name would resolve to here, without making anything.
  (let ((here (find-symbol-in pkg s)))
    (if here
        here
        (let ((u (package-use pkg)) (found nil))
          (while (%cons? u)
            (let ((sym (find-symbol-in (%car u) s)))
              (if (if sym (symbol-exported? sym) nil)
                  (begin (set! found sym) (set! u nil))
                  (set! u (%cdr u)))))
          found))))

(define (intern-visible pkg s)
  (let ((v (find-visible pkg s)))
    (if v v (intern-in pkg s))))

;; The package a bare name is read in. One cell, which the forge's reader and
;; the machine's reader both work from, so they cannot drift apart about it.
;; The scheduler swaps it like the streams, so two shells can be in two
;; packages at once.
(define (current-package)
  (let ((p (%raw-ld lg-package)))
    (if p p (let ((base (make-package "lm"))) (%raw-st! lg-package base) base))))

(define (set-current-package! p) (%raw-st! lg-package p) p)

(define (intern-string s) (intern-in (current-package) s))

;; ---------------------------------------------------------------- the forms
;; The reader has already acted on these by the time they are evaluated: it
;; has to, because everything after them in a file is read in the package they
;; name. Doing it again here changes nothing, and is what makes them work when
;; they are typed at a prompt.
(define (in-package name)
  (set-current-package! (make-package name))
  nil)

(define (defpackage name . words)
  ;; Flat rather than nested - (defpackage wb use lm hw exec) - because the
  ;; reader hands these over as names, and a nested list of names would be
  ;; read by the evaluator as something to call.
  ;;
  ;; No dolist and no reverse here either: this file is compiled before the
  ;; macros and the library exist, so it says what it means the long way.
  (let ((p (make-package name)) (used nil) (last nil) (w words) (in-use nil))
    (while (%cons? w)
      (let ((x (%car w)))
        (if (string=? x "use")
            (set! in-use t)
            (if in-use
                (let ((cell (%cons (make-package x) nil)))
                  (if last (%set-cdr! last cell) (set! used cell))
                  (set! last cell))
                nil)))
      (set! w (%cdr w)))
    (set-package-use! p used)
    p))

;; Public, in the Common Lisp sense: a name another package may write without
;; two colons and an apology.
(define (export names)
  (let ((p names))
    (while (%cons? p)
      (export-symbol! (%car p))
      (set! p (%cdr p))))
  nil)

;; A symbol's identity is a small dense integer, which makes it the hash: no
;; collisions at all, nothing to recompute, and nothing that a collector could
;; invalidate by moving something. It also orders symbols, which is enough to
;; iterate a table deterministically.
(define (symbol-index s) (%lsh (%slot s sym-flags) -8))
(define (symbol-flags s) (%logand (%slot s sym-flags) 255))
(define (symbol-hash s) (symbol-index s))
(define (symbol-count) (%global lg-symcount))

;; ---------------------------------------------------------------- diagnostics
(define (out-of-memory what)
  (uart-string "out of memory: ")
  (uart-string what)
  (uart-nl)
  (%halt 3))

;; ---------------------------------------------------------------- console
;; The serial port is the console of last resort: it works before anything else
;; is up, which makes it the right place to report a failure from.
(define uart-data (%+ mmio-base (%+ (%lsh dev-uart 12) 0)))
(define uart-status (%+ mmio-base (%+ (%lsh dev-uart 12) 4)))
(define uart-ctrl (%+ mmio-base (%+ (%lsh dev-uart 12) 8)))
(define uart-count (%+ mmio-base (%+ (%lsh dev-uart 12) 12)))

(define (uart-put c) (%st32! uart-data c))
(define (uart-nl) (%st32! uart-data 10))

(define (uart-string s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (%st32! uart-data (%char->int (%string-ref s i)))
      (set! i (%+ i 1)))
    s))

(define (uart-num n)
  (uart-string (number->string n)))

(define (uart-hex n)
  (uart-string "0x")
  (uart-string (number->hex n)))

;; The same two, without allocating. The collector reports through these,
;; because when it has something to report, consing is often the very thing
;; that has gone wrong.
(define (uart-num-raw n)
  (if (%< n 0)
      (begin (%st32! uart-data 45) (set! n (%- 0 n)))
      nil)
  (if (%>= n 10) (uart-num-raw (%/ n 10)) nil)
  (%st32! uart-data (%+ 48 (%mod n 10))))

(define (uart-hex-raw n)
  (%st32! uart-data 48)
  (%st32! uart-data 120)
  (let ((i 28))
    (while (%>= i 0)
      (let ((d (%logand (%lsh n (%- 0 i)) 15)))
        (%st32! uart-data (if (%< d 10) (%+ 48 d) (%+ 87 d))))
      (set! i (%- i 4)))))

(define (uart-ready?) (%= 1 (%logand (%ld32 uart-status) 1)))
(define (uart-get) (%ld32 uart-data))
