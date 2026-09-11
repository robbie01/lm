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
  ;; go through %ld-word and %st-word! and not through the slot accessors.
  (let ((c (alloc-object t-closure (%+ 2 nfree))))
    (%st-word! (%addr-of c) (%ld-word (%addr-of code)))
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

;; Allocation lives here rather than with the collector: everything below is
;; built out of it, and it is the prelude that everything below is in.
;;
;; It asks the collector for space through a pair of hooks rather than by
;; name, because it cannot name the collector's functions. The forge reads the
;; prelude with the bootstrap reader, which has one namespace, so every name
;; mentioned here becomes a name of the prelude's own - and `obj-take` written
;; here would be `lm:obj-take`, which is not the collector's. A hook says what
;; is going on anyway: allocation is the caller, collection is what it falls
;; back on when there is no room.
;;
;; Declared, not initialised. `install-allocator` fills them in before the
;; boot list runs, and a `(define ... nil)` would put a `(set! ... nil)` on
;; that list to undo the installation on the way past.
(define *object-allocator*)
(define *collector*)

;; All of it is one critical section, not just the part that touches the free
;; list, and the reason is worth writing down because the narrower version
;; looks obviously sufficient and is not.
;;
;; A block between being taken and being filled in is in the worst possible
;; state. Its header still says `t-free`, because taking it only unlinks it;
;; and the raw address held here is not a tagged object pointer, so no
;; conservative scan of this task's registers will recognise it. A collection
;; that ran in that window would sweep the block back onto a free list and
;; hand it out a second time. Nothing announces that: the two owners simply
;; write over each other, and it surfaces later as a string with a nonsense
;; length or a record with somebody else's fields.
;;
;; So the block is not let go of until it is a well formed object of a known
;; type. The zero fill is inside for the same reason - until it is done the
;; slots hold whatever the last owner left, which the collector would trace.
(define (alloc-object type len)
  (without-interrupts
  (let* ((size (%logand (%+ (%+ 4 (object-payload type len)) 7) -8))
         (p (%funcall *object-allocator* size)))
    (if (%= p 0)
        (begin
          (%funcall *collector*)
          (set! p (%funcall *object-allocator* size))
          (if (%= p 0) (out-of-memory "object space") nil))
        nil)
    (%st-fixnum! p (%logior (%lsh len 8) type))
    (let ((i 4))
      (while (%< i size)
        (%st-fixnum! (%+ p i) 0)
        (set! i (%+ i 4))))
    (%from-addr (%+ p 4)))))

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
(define (all-packages) (%ld-word lg-packages))

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
  (without-interrupts
  (let ((old (find-package name)))
    (if old
        old
        (let ((p (make-record pkg-slots nil)))
          (%set-slot! p pkg-name name)
          (%set-slot! p pkg-use nil)
          (%st-word! lg-packages (%cons p (%ld-word lg-packages)))
          (%set-slot! p pkg-tag (intern-in p "package"))
          p)))))

(define (symbol-exported? s)
  (%= sym-exported (%logand (symbol-flags s) sym-exported)))

(define (export-symbol! s)
  (%set-slot! s sym-flags
              (%logior (%slot s sym-flags) sym-exported))
  s)

;; ---------------------------------------------------------------- symbols
;; Interning has to be identical on both sides of the bootstrap or a symbol
;; read at build time and one read at run time would not be eq.
;; qualified-hash in two halves. djb2 is a polynomial: the hash of pkg:name is
;; the prefix's hash times 33 to the power of the name's length, plus the
;; name's own hash counted from zero - all modulo 2^30, which is what the mask
;; does at every step. So a name that is looked for in several packages, which
;; a bare name is - its own package, then everything that package uses - is
;; hashed once, and placed in each package with one multiply and one add. The
;; bucket is the one qualified-hash gives, to the bit.
(define (name-hash s) (hash-string-into 0 s))

(define (name-power s)
  (let ((i (%string-length s)) (p 1))
    (while (%> i 0)
      (set! p (%logand (%* p 33) 1073741823))
      (set! i (%- i 1)))
    p))

(define (prefix-hash pkg-name)
  (%logand (%+ (%* (hash-string-into 5381 pkg-name) 33) 58) 1073741823))

;; While a fresh image is being compiled, every symbol a lookup comes back with
;; is noted here: those are the names its sources use, and anything else this
;; machine has - something typed at a prompt, a function the sources no longer
;; define - is left out of it. See `genesis` and `save-fresh`.
(define *names-seen* nil)

(define (find-symbol-in pkg s)
  (find-symbol-hashed pkg s (name-hash s) (name-power s)))

(define (find-symbol-hashed pkg s nh np)
  (let* ((ob (%ld-word lg-obarray))
         (n (%vector-length ob))
         (h (%logand (%+ (%* (prefix-hash (package-name pkg)) np) nh) 1073741823))
         (chain (%vector-ref ob (%mod h n)))
         (found nil))
    (while (%cons? chain)
      (let ((sym (%car chain)))
        (if (if (%eq? (%slot sym sym-package) pkg)
                (string=? (%symbol-name sym) s)
                nil)
            (begin (set! found sym) (set! chain nil))
            (set! chain (%cdr chain)))))
    (if found (if *names-seen* (table-set! *names-seen* found t) nil) nil)
    found))

(define (intern-in pkg s)
  ;; Looking and creating have to be one indivisible act. Two tasks interning
  ;; the same name at once would otherwise both look, both miss, and both make
  ;; a symbol - and two symbols of one name in one package is a machine where
  ;; eq? has stopped meaning anything.
  (without-interrupts
  (let ((found (find-symbol-in pkg s)))
    (if found
        found
        (let* ((ob (%ld-word lg-obarray))
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
          (%st-word! lg-symlist (%cons sym (%ld-word lg-symlist)))
          (if *names-seen* (table-set! *names-seen* sym t) nil)
          sym)))))

;; What a bare name means here: this package first, then whatever the packages
;; it uses have exported, and failing both a new symbol of its own.
(define (find-visible pkg s)
  ;; What a bare name would resolve to here, without making anything. The
  ;; name is hashed once, for all the packages it may be looked for in.
  (let* ((nh (name-hash s))
         (np (name-power s))
         (here (find-symbol-hashed pkg s nh np)))
    (if here
        here
        (let ((u (package-use pkg)) (found nil))
          (while (%cons? u)
            (let ((sym (find-symbol-hashed (%car u) s nh np)))
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
  (let ((p (%ld-word lg-package)))
    (if p p (let ((base (make-package "lm"))) (%st-word! lg-package base) base))))

(define (set-current-package! p) (%st-word! lg-package p) p)

(define (intern-string s) (intern-in (current-package) s))

;; ---------------------------------------------------------------- the forms
;; The reader has already acted on these by the time they are evaluated: it
;; has to, because everything after them in a file is read in the package they
;; name. Doing it again here changes nothing, and is what makes them work when
;; they are typed at a prompt.
;; A package name arrives as a string from the reader that knows about
;; packages, and as a symbol from the one that does not - the bootstrap reads
;; these forms before there is any such thing as a package. Both spellings
;; mean the same package.
(define (package-designator x)
  (if (%symbol? x) (%symbol-name x) x))

;; in-package and defpackage are macros so that their arguments are names
;; rather than expressions, whichever reader read them: the bootstrap reader
;; hands over symbols and the real one hands over strings, and a macro can
;; quote either without evaluating it.
(define (set-package-by-name name)
  (set-current-package! (make-package (package-designator name)))
  nil)



(define (define-package-by-name all)
  (let ((name (%car all)) (words (%cdr all)))
    (defpackage-1 name words)))

(define (defpackage-1 name words)
  ;; Flat rather than nested - (defpackage wb use lm hw exec) - because the
  ;; reader hands these over as names, and a nested list of names would be
  ;; read by the evaluator as something to call.
  ;;
  ;; No dolist and no reverse here either: this file is compiled before the
  ;; macros and the library exist, so it says what it means the long way.
  (let ((p (make-package (package-designator name)))
        (used nil) (last nil) (w words) (in-use nil))
    (while (%cons? w)
      (let ((x (package-designator (%car w))))
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

(define (uart-put c) (%st-fixnum! uart-data c))
(define (uart-nl) (%st-fixnum! uart-data 10))

(define (uart-string s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (%st-fixnum! uart-data (%char->int (%string-ref s i)))
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
      (begin (%st-fixnum! uart-data 45) (set! n (%- 0 n)))
      nil)
  (if (%>= n 10) (uart-num-raw (%/ n 10)) nil)
  (%st-fixnum! uart-data (%+ 48 (%mod n 10))))

(define (uart-hex-raw n)
  (%st-fixnum! uart-data 48)
  (%st-fixnum! uart-data 120)
  (let ((i 28))
    (while (%>= i 0)
      (let ((d (%logand (%lsh n (%- 0 i)) 15)))
        (%st-fixnum! uart-data (if (%< d 10) (%+ 48 d) (%+ 87 d))))
      (set! i (%- i 4)))))

(define (uart-ready?) (%= 1 (%logand (%ld-fixnum uart-status) 1)))
(define (uart-get) (%ld-fixnum uart-data))
