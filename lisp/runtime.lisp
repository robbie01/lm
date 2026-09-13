;;; runtime.lisp - what compiled code calls into.
;;;
;;; These run under the bootstrap interpreter while the image is being built
;;; and as native code afterwards, and both times they do the same thing to
;;; the same words of memory. Nothing here may create a closure: the compiler
;;; emits a call to `make-closure` for every lambda, so a lambda in this file
;;; would be a circle.

(in-package lm)

;; ---------------------------------------------------------------- allocation
(define (object-payload type len)
  (cond ((%= type t-string) len)
        ((%= type t-bytes) len)
        ((%= type t-symbol) (%* 4 sym-slots))
        ((%= type t-float) 4)
        (else (%* 4 len))))

;; The entry address is copied out of the code object. Both that word and the
;; closure slot it lands in are raw addresses, so they go through the raw
;; word accessors and not the slot accessors.
(define (make-closure code nfree)
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

;; The allocator reaches the collector through three hooks rather than by
;; name: the forge reads the prelude with a reader that has one namespace,
;; so a name written here would be the prelude's and not the collector's.
;; Declared, not initialised: `install-allocator` fills them in before the
;; boot list runs, and a `(define ... nil)` would put a `(set! ... nil)` on
;; the boot list that undid the installation. The pacer is called with the
;; size about to be allocated, before the critical section, and does the
;; collector's share of work for it; the collector proper is the last resort
;; when there is no room.
(define *object-allocator*)
(define *collector*)
(define *pacer*)

;; A block between being taken and being a well formed object is in no state
;; to be collected: its header still says free, and the raw address held here
;; is not a tagged pointer, so nothing would keep it. So the whole of taking
;; the block, writing its header and zeroing any slots the collector would
;; trace is one critical section. The payload of a string, byte vector,
;; bignum or float holds no pointers, so it is zeroed afterwards with
;; interrupts on: a screen bitmap is most of a megabyte.
(define (raw-payload? type)
  (if (%= type t-string) t
      (if (%= type t-bytes) t
          (if (%= type t-bignum) t (%= type t-float)))))

(define (alloc-object type len)
  (let* ((raw (raw-payload? type))
         ;; A record, which is most of what gets made, is sized here rather
         ;; than by a call: a slot is a word, and the header is one more.
         (size (%logand (%+ (if (%= type t-record) (%lsh len 2) (object-payload type len))
                            11)
                        -8))
         (paced (%funcall *pacer* size))
         (p (without-interrupts
              (let ((p (%funcall *object-allocator* size)))
                (if (%= p 0)
                    (begin
                      (%funcall *collector*)
                      (set! p (%funcall *object-allocator* size))
                      (if (%= p 0) (out-of-memory "object space") nil))
                    nil)
                (%st-fixnum! p (%logior (%lsh len 8) type))
                (if raw nil (zero-words (%+ p 4) (%+ p size)))
                p))))
    (if raw (zero-words (%+ p 4) (%+ p size)) nil)
    (%from-addr (%+ p 4))))

(define (zero-words from to)
  (while (%< from to)
    (%st-fixnum! from 0)
    (set! from (%+ from 4))))

(define (make-record n tag)
  (let ((r (alloc-object t-record n)))
    (%set-slot! r 0 tag)
    r))

;; ---------------------------------------------------------------- hashing
;; The obarray is a vector of buckets, each a list of symbols. Interning has to
;; be identical on both sides of the bootstrap or a symbol read at build time
;; and one read at run time would not be eq: `Heap::qual_hash` in the forge
;; computes exactly what `qualified-hash` does.
(define (string-hash s) (hash-string-into 5381 s))

;; djb2, masked to 30 bits every round so that every intermediate is a fixnum.
(define (hash-string-into h s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (set! h (%logand (%+ (%* h 33) (%char->int (%string-ref s i))) 1073741823))
      (set! i (%+ i 1)))
    h))

;; The bucket is hashed over the package name, a colon and the symbol name.
(define (qualified-hash pkg-name name)
  (hash-string-into
   (%logand (%+ (%* (hash-string-into 5381 pkg-name) 33) 58) 1073741823)
   name))

;; djb2 is a polynomial, so the hash of pkg:name is the prefix's hash times 33
;; to the power of the name's length, plus the name's own hash counted from
;; zero. A bare name is looked for in several packages, and these let it be
;; hashed once and placed in each with one multiply and one add.
(define (name-hash s) (hash-string-into 0 s))

(define (name-power s)
  (let ((i (%string-length s)) (p 1))
    (while (%> i 0)
      (set! p (%logand (%* p 33) 1073741823))
      (set! i (%- i 1)))
    p))

(define (prefix-hash pkg-name)
  (%logand (%+ (%* (hash-string-into 5381 pkg-name) 33) 58) 1073741823))

;; ---------------------------------------------------------------- packages
;; A package is a record: its tag, its name and the list of packages whose
;; exports it inherits. What it holds is not stored in it: the obarray is
;; keyed by package and name, and every symbol knows its home package. The
;; tag is the one symbol `package`, on both sides of the bootstrap.
(define (package-name p) (%slot p pkg-name))
(define (package-use p) (%slot p pkg-use))
(define (set-package-use! p v) (%set-slot! p pkg-use v))
(define (symbol-package s) (%slot s sym-package))
(define (all-packages) (%ld-word lg-packages))

(define (package? x)
  (if (%record? x) (%eq? (%slot x pkg-tag) 'package) nil))

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
        (let ((p (make-record pkg-slots 'package)))
          (%set-slot! p pkg-name name)
          (%set-slot! p pkg-use nil)
          (%st-word! lg-packages (%cons p (%ld-word lg-packages)))
          p)))))

(define (symbol-exported? s)
  (%= sym-exported (%logand (symbol-flags s) sym-exported)))

(define (export-symbol! s)
  (%set-slot! s sym-flags
              (%logior (%slot s sym-flags) sym-exported))
  s)

;; ---------------------------------------------------------------- symbols
;; While a fresh image is being compiled, every symbol a lookup answers is
;; noted here: those are the names its sources use. See `genesis` in sys.lisp.
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

;; A symbol object: its name, no value, and the next identity from the one
;; counter both sides of the bootstrap intern through. Flags live in the low
;; eight bits of the flags word and the identity above them.
(define (alloc-symbol s)
  (let ((sym (alloc-object t-symbol sym-slots)))
    (%set-slot! sym sym-name s)
    (%set-slot! sym sym-value (%unbound))
    (%set-slot! sym sym-function nil)
    (%set-slot! sym sym-plist nil)
    (%set-slot! sym sym-flags (%lsh (%ld-fixnum lg-symcount) 8))
    (%st-fixnum! lg-symcount (%+ (%ld-fixnum lg-symcount) 1))
    sym))

;; A symbol in no package and on no list, for a macro's temporaries: nothing
;; reaches it but the code that mentions it, so the collector frees it with
;; that code. It prints as #:name.
(define (make-symbol s)
  (let ((sym (alloc-symbol s)))
    (%set-slot! sym sym-package nil)
    sym))

;; Looking and creating are one indivisible act: two tasks interning the same
;; name at once would otherwise both miss and both make a symbol.
(define (intern-in pkg s)
  (without-interrupts
  (let ((found (find-symbol-in pkg s)))
    (if found
        found
        (let* ((ob (%ld-word lg-obarray))
               (n (%vector-length ob))
               (b (%mod (qualified-hash (package-name pkg) s) n))
               (sym (alloc-symbol s)))
          (%set-slot! sym sym-package pkg)
          (%vector-set! ob b (%cons sym (%vector-ref ob b)))
          (%st-word! lg-symlist (%cons sym (%ld-word lg-symlist)))
          (if *names-seen* (table-set! *names-seen* sym t) nil)
          sym)))))

;; What a bare name means here without making anything: this package first,
;; then whatever the packages it uses have exported. The name is hashed once
;; for all of them.
(define (find-visible pkg s)
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

;; The package a bare name is read in: one machine cell, which both readers
;; work from. The scheduler swaps it like the streams, so two shells can be in
;; two packages at once.
(define (current-package)
  (let ((p (%ld-word lg-package)))
    (if p p (let ((base (make-package "lm"))) (%st-word! lg-package base) base))))

(define (set-current-package! p) (%st-word! lg-package p) p)

(define (intern-string s) (intern-in (current-package) s))

;; ---------------------------------------------------------------- the forms
;; The reader has already acted on `in-package` and `defpackage` by the time
;; they are evaluated, because everything after them in a file is read in the
;; package they name. Evaluating them again changes nothing, and is what makes
;; them work when typed at a prompt.
;;
;; A package name arrives as a string from the reader that knows packages and
;; as a symbol from the bootstrap reader, which does not.
(define (package-designator x)
  (if (%symbol? x) (%symbol-name x) x))

(define (set-package-by-name name)
  (set-current-package! (make-package (package-designator name)))
  nil)

(define (define-package-by-name all)
  (let ((name (%car all)) (words (%cdr all)))
    (defpackage-1 name words)))

;; (defpackage wb use lm hw exec): flat, because the reader hands the words
;; over as names. Written the long way because this file is compiled before
;; the macros and the library exist.
(define (defpackage-1 name words)
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

;; Public, in the Common Lisp sense: a name another package may read with one
;; colon.
(define (export names)
  (let ((p names))
    (while (%cons? p)
      (export-symbol! (%car p))
      (set! p (%cdr p))))
  nil)

;; A symbol's identity is a small dense integer, which makes it a perfect
;; hash: no collisions, nothing to recompute, nothing a collector could
;; invalidate. It also orders symbols, which is enough to walk a table
;; deterministically.
(define (symbol-index s) (%lsh (%slot s sym-flags) -8))
(define (symbol-flags s) (%logand (%slot s sym-flags) 255))
(define (symbol-hash s) (symbol-index s))

;; ---------------------------------------------------------------- diagnostics
(define (out-of-memory what)
  (uart-string "out of memory: ")
  (uart-string what)
  (uart-nl)
  (%halt exit-oom))

;; ---------------------------------------------------------------- console
;; The serial port, reached raw: it works before anything else is up, inside
;; a trap handler, and after the scheduler has stopped being trustworthy,
;; which is why the collector and the panic path report through it. Nothing
;; here allocates. Ordinary console output goes through console.driver.
(define uart-data (%+ mmio-base (%+ (%lsh dev-uart 12) uart-data-reg)))
(define uart-ctrl (%+ mmio-base (%+ (%lsh dev-uart 12) uart-ctrl-reg)))

(define (uart-nl) (%st-fixnum! uart-data 10))

(define (uart-string s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (%st-fixnum! uart-data (%char->int (%string-ref s i)))
      (set! i (%+ i 1)))
    s))

(define (uart-num n)
  (if (%< n 0)
      (begin (%st-fixnum! uart-data 45) (set! n (%- 0 n)))
      nil)
  (if (%>= n 10) (uart-num (%/ n 10)) nil)
  (%st-fixnum! uart-data (%+ 48 (%mod n 10))))

(define (uart-hex n)
  (%st-fixnum! uart-data 48)
  (%st-fixnum! uart-data 120)
  (let ((i 28))
    (while (%>= i 0)
      (let ((d (%logand (%lsh n (%- 0 i)) 15)))
        (%st-fixnum! uart-data (if (%< d 10) (%+ 48 d) (%+ 87 d))))
      (set! i (%- i 4)))))
