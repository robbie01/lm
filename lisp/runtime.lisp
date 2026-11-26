;;; runtime.lisp - what compiled code calls into.
;;;
;;; These run under the bootstrap interpreter while the image is being built
;;; and as native code afterwards, and both times they do the same thing to
;;; the same words of memory. Nothing here may create a closure: the compiler
;;; emits a call to `make-closure` for every lambda, so a lambda in this file
;;; would be a circle.

(in-package lm)

;; ---------------------------------------------------------------- the kernel block
;; The kernel's own state, one object, which `mscratch` names: the trap
;; stub's state, the roots of the world, the frontiers of the heap, and the
;; capabilities the reset stub mints from the memory map. Reading
;; `mscratch` takes SR, so only code that says `unsafe` can reach it; these
;; are the slots by number, `kb-*` in the layout.
(defsubst (kernel-ref i) (declare unsafe) (%slot (%kernel) i))
(defsubst (kernel-set! i v) (declare unsafe) (%set-slot! (%kernel) i v))

;; Every interned symbol, as a list: the root of everything a name reaches.
(define (all-symbols) (declare unsafe) (unsafe (kernel-ref kb-symbols)))

;; How many traps are in progress: 0 outside the trap handler.
(define (trap-depth) (unsafe (kernel-ref kb-depth)))

;; ---------------------------------------------------------------- allocation
;; An object is a header granule and its payload. The header's first word is
;; (len << 8) | type and its second the object's identity hash, zero until
;; something asks for it (`identity-hash`), so a new header is exactly a
;; fixnum stored in the granule. The payload is a byte per element for a
;; string, a byte vector or a function's text, which hold no capabilities,
;; and a slot per element for the rest.
(defsubst (byte-payload? type)
  (cond ((%= type t-string) t)
        ((%= type t-bytes) t)
        (else (%= type t-text))))

;; A task's stack or its register context: slots the collector never traces,
;; because the roots scan the part of each that is in use.
(defsubst (state-payload? type)
  (if (%= type t-stack) t (%= type t-context)))

(defsubst (object-payload type len)
  (cond ((byte-payload? type) len)
        ((%= type t-symbol) (%* value-bytes sym-slots))
        ((%= type t-float) value-bytes)
        (else (%* value-bytes len))))

;; What a fresh slot holds until it is given something: nil, so that a
;; record's fields start empty, or zero in the limbs of a number.
(defsubst (fresh-slot type)
  (if (%= type t-bignum) 0 (if (%= type t-float) 0 nil)))

;; The closure is answered unsealed, so that its maker can fill in the free
;; variables; sealing it with `%cap-seal-closure` is the maker's last act. Its
;; entry is the code's. Unsafe: until it is sealed, whoever holds it can
;; store into any of its slots, its entry and its code object among them.
(define (make-closure code nfree)
  (declare unsafe)
  (unsafe
  (if (%= (%obj-type code) t-code) nil (error "make-closure: not code:" code))
  (let ((c (alloc-object t-closure (%+ clo-free nfree))))
    (%set-slot! c clo-entry (%slot code code-entry))
    (%set-slot! c clo-code code)
    c)))

;; A sealed closure opened through the escape hatch: the root holds every
;; capability, so it unseals any sealed one. For the printer and the
;; explorer, which show what a closure holds.
(define (open-closure f)
  (declare unsafe)
  (unsafe (%cap-unseal-within f (%root))))

;; A sealing key: authority to seal and to unseal with the otype `ot` and
;; with no other, the otypes the reset stub minted narrowed to that one. A
;; manager mints the key to its own type once and keeps it in its own
;; closures, so that what it seals into a record anybody can read is still
;; its own.
(define (sealing-key ot)
  (declare unsafe)
  (unsafe
  (%cap-and-perms (%cap-bounds-exact (%cap-set-addr (kernel-ref kb-seals) ot) 1) perm-se)))

;; A length an object can have: its header holds it in twenty-four bits.
(defsubst (check-length n)
  (if (if (%fixnum? n) (if (%>= n 0) (%< n 16777216) nil) nil)
      n
      (error "not a length:" n)))

;; A fresh vector already holds nil in every slot.
(define (make-vector-n n fill)
  (check-length n)
  (unsafe
  (let ((v (alloc-object t-vector n)) (i 0))
    (if (%null? fill)
        nil
        (while (%< i n)
          (%set-slot! v i fill)
          (set! i (%+ i 1))))
    v)))

(define (make-string-n n)
  (check-length n)
  (unsafe (alloc-object t-string n)))

(define (make-bytes-n n)
  (check-length n)
  (unsafe (alloc-object t-bytes n)))

;; The allocator reaches the collector through three hooks rather than by
;; name: the forge reads the prelude with a reader that has one namespace,
;; so a name written here would be the prelude's and not the collector's.
;; Declared, not initialised: `install-allocator` fills them in before the
;; boot list runs, and a `(define ... nil)` would put a `(set! ... nil)` on
;; the boot list that undid the installation. The pacer is called with the
;; size about to be allocated, before the critical section, and does the
;; collector's share of work for it; the collector proper is the last resort
;; when there is no room.
(define *object-allocator* (declare unsafe))
(define *collector* (declare unsafe))
(define *pacer* (declare unsafe))

;; A block between being taken and being a well formed object is in no state
;; to be collected: its header still says free, and the address held here is
;; a number, not a capability, so nothing would keep it. Whatever the block
;; held before may still carry tags. So the whole of taking the block,
;; writing its header, filling the slots the collector would trace and
;; minting the capability that keeps it is one critical section. A byte
;; payload, a stack and a context are never traced, so they are zeroed
;; afterwards with interrupts on, while the capability keeps them: a screen
;; bitmap is most of a megabyte, and a stack sixty-four kilobytes.
;;
;; The capability's bounds are the payload, rounded as the processor needs
;; to represent them: `%rrl` gives the length and `%ram` the alignment the
;; base must have. The collector's allocator is handed the size of the whole
;; block, header and rounded payload, and that alignment mask, and answers
;; where in object space the block is, a payload suitably aligned, or 0.
;; The header is written and the capability minted through object space's
;; own capability, which the kernel block holds. The capability's
;; permissions are `perms-object`, values and capabilities alike, or for a
;; byte payload `perms-bytes`, data only. Both carry HD, which only an
;; authority over the whole of object space mints. Unsafe: it makes an
;; object of any type, a closure, a code object or a stack among them, and
;; trusts its length; and the first hook says where the header goes, which
;; is why the three hooks are unsafe names too.
(define (alloc-object type len)
  (declare unsafe)
  (unsafe
  (let* ((bytes (byte-payload? type))
         (later (if bytes t (state-payload? type)))
         ;; A record, which is most of what gets made, is sized here rather
         ;; than by a call.
         (payload (if (%= type t-record) (%* value-bytes len) (object-payload type len)))
         (span (%rrl payload))
         (align (%ram payload))
         (size (%+ value-bytes (%logand (%+ span (%- value-bytes 1)) (%- 0 value-bytes))))
         (paced (%funcall *pacer* size))
         (space (kernel-ref kb-objects))
         (obj (without-interrupts
                (let ((p (%funcall *object-allocator* size align)))
                  (if (%= p 0)
                      (begin
                        (%funcall *collector*)
                        (set! p (%funcall *object-allocator* size align))
                        (if (%= p 0) (out-of-memory "object space") nil))
                      nil)
                  (let ((h (%cap-set-addr space p)))
                    (%cap-st! h 0 (%logior (%lsh len 8) type))
                    (if later nil (fill-granules h value-bytes size (fresh-slot type)))
                    (%cap-and-perms (%cap-bounds-exact (%cap-inc h value-bytes) span)
                                    (if bytes perms-bytes perms-object)))))))
    ;; Through object space's capability, which covers the whole block: a
    ;; byte payload's own bounds can stop short of its last granule.
    (if later (fill-granules (%cap-set-addr space (%cap-base obj)) 0 (%- size value-bytes) 0) nil)
    obj)))

;; Every granule `from` bytes into `c` up to `to` set to `v`. A store of an
;; untagged value clears the granule's tag.
(define (fill-granules c from to v)
  (declare unsafe)
  (unsafe
  (let ((g (%cap-inc c from)) (end (%+ (%addr-of c) to)))
    (while (%< (%addr-of g) end)
      (%cap-st! g 0 v)
      (set! g (%cap-inc g 8))))))

(define (make-record n tag)
  (check-length n)
  (if (%> n 0) nil (error "make-record: no room for its type:" n))
  (unsafe
  (let ((r (alloc-object t-record n)))
    (%set-slot! r 0 tag)
    r)))

;; ---------------------------------------------------------------- hashing
;; The obarray is a vector of buckets, each a list of symbols. Interning has to
;; be identical on both sides of the bootstrap or a symbol read at build time
;; and one read at run time would not be eq: `Heap::qual_hash` in the forge
;; computes exactly what `qualified-hash` does.
(define (string-hash s) (hash-string-into 5381 s))

;; djb2 with wrapping arithmetic, masked to 30 bits every round, as the
;; forge computes it: the hash is never negative.
(define (hash-string-into h s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (set! h (%logand (%+ (%* h 33) (%char->int (%string-ref s i))) 1073741823))
      (set! i (%+ i 1)))
    h))

;; The bucket is hashed over the package name, a colon and the symbol name.
(define (prefix-hash pkg-name)
  (%logand (%+ (%* (hash-string-into 5381 pkg-name) 33) 58) 1073741823))

(define (qualified-hash pkg-name name)
  (hash-string-into (prefix-hash pkg-name) name))

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

;; ---------------------------------------------------------------- packages
;; A package is a record: its tag, its name and the list of packages whose
;; exports it inherits. What it holds is not stored in it: the obarray is
;; keyed by package and name, and every symbol knows its home package. The
;; tag is the one symbol `package`, on both sides of the bootstrap.
;; A package is a record, so its fields are read with the record
;; instructions, which refuse anything else.
(define (package-name p) (%record-ref p pkg-name))
(define (package-use p) (%record-ref p pkg-use))
(define (set-package-use! p v) (%record-set! p pkg-use v))
(define (symbol-package s)
  (if (%symbol? s) nil (error "not a symbol:" s))
  (unsafe (%slot s sym-package)))

;; A copy: the kernel's own list is the kernel's to change.
(define (all-packages)
  (let ((p (unsafe (kernel-ref kb-packages))) (acc nil))
    (while (%cons? p) (set! acc (%cons (%car p) acc)) (set! p (%cdr p)))
    (reverse acc)))

(define (package? x)
  (if (%record? x) (%eq? (%record-ref x pkg-tag) 'package) nil))

(define (find-package name)
  (let ((p (unsafe (kernel-ref kb-packages))) (found nil))
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
          (%record-set! p pkg-name name)
          (%record-set! p pkg-use nil)
          (unsafe (kernel-set! kb-packages (%cons p (kernel-ref kb-packages))))
          p)))))

(define (symbol-exported? s)
  (%= sym-exported (%logand (symbol-flags s) sym-exported)))

(define (export-symbol! s)
  (let ((f (%symbol-flags s)))
    (unsafe (%set-symbol-flags! s (%logior f sym-exported))))
  s)

;; A name the compiler refuses outside an `unsafe` form: a raw operation, or
;; a function that is unsafe to call. The mark is a bit in the symbol, set by
;; `(declare unsafe)` at the definition; see compile.lisp.
(define (symbol-unsafe? s)
  (if (%= 0 (%logand (%symbol-flags s) sym-unsafe)) nil t))

;; ---------------------------------------------------------------- symbols
;; While a fresh image is being compiled, every symbol a lookup answers is
;; noted here: those are the names its sources use. See `genesis` in sys.lisp.
(define *names-seen* nil)

(define (find-symbol-in pkg s)
  (find-symbol-hashed pkg s (name-hash s) (name-power s)))

(define (find-symbol-hashed pkg s nh np)
  (unsafe
  (let* ((ob (kernel-ref kb-obarray))
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
    found)))

;; A symbol object: its name, no value, and the next identity from the one
;; counter both sides of the bootstrap intern through. Flags live in the low
;; eight bits of the flags word and the identity above them.
(define (alloc-symbol s)
  (if (%string? s) nil (error "not a name:" s))
  (unsafe
  (let ((sym (alloc-object t-symbol sym-slots)))
    (%set-slot! sym sym-name s)
    (%set-slot! sym sym-value (%unbound))
    (%set-slot! sym sym-function nil)
    (%set-slot! sym sym-plist nil)
    (%set-slot! sym sym-flags (%lsh (kernel-ref kb-symcount) 8))
    (kernel-set! kb-symcount (%+ (kernel-ref kb-symcount) 1))
    sym)))

;; A symbol in no package and on no list, for a macro's temporaries: nothing
;; reaches it but the code that mentions it, so the collector frees it with
;; that code. It prints as #:name.
(define (make-symbol s)
  (let ((sym (alloc-symbol s)))
    (unsafe (%set-slot! sym sym-package nil))
    sym))

;; Looking and creating are one indivisible act: two tasks interning the same
;; name at once would otherwise both miss and both make a symbol.
(define (intern-in pkg s)
  (if (package? pkg) nil (error "not a package:" pkg))
  (unsafe
  (without-interrupts
  (let ((found (find-symbol-in pkg s)))
    (if found
        found
        (let* ((ob (kernel-ref kb-obarray))
               (n (%vector-length ob))
               (b (%mod (qualified-hash (package-name pkg) s) n))
               (sym (alloc-symbol s)))
          (%set-slot! sym sym-package pkg)
          (%vector-set! ob b (%cons sym (%vector-ref ob b)))
          (kernel-set! kb-symbols (%cons sym (kernel-ref kb-symbols)))
          (if *names-seen* (table-set! *names-seen* sym t) nil)
          sym))))))

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

;; The package a bare name is read in: one slot of the kernel block, which
;; both readers work from. The scheduler swaps it like the streams, so two
;; shells can be in two packages at once.
(define (current-package)
  (unsafe
  (let ((p (kernel-ref kb-package)))
    (if p p (let ((base (make-package "lm"))) (kernel-set! kb-package base) base)))))

(define (set-current-package! p)
  (if (package? p) nil (error "not a package:" p))
  (unsafe (kernel-set! kb-package p))
  p)

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
(define (symbol-index s) (%lsh (%symbol-flags s) -8))
(define (symbol-flags s) (%logand (%symbol-flags s) 255))

;; Any other object's identity is a number in the second word of its header,
;; which does not depend on where the object is: whatever moves an object
;; copies its header with it. The allocator leaves the word zero, and the
;; first request fills it in with the object's address at the time, in
;; granules, which is never zero. Two objects share a number only when one
;; has moved to where the other was when it was asked, which is a collision
;; and nothing worse. Filling it in is a critical section, so two tasks
;; asking at once agree. `obj` must be an object, headed and based in object
;; space, since the word is written through object space's capability.
(define (identity-hash obj)
  (if (%object? obj) nil (error "identity-hash: not an object:" obj))
  (unsafe
  (let* ((at (%cap-set-addr (kernel-ref kb-objects) (%- (%cap-base obj) 4)))
         (h (%cap-ld-word at 0)))
    (if (%= h 0)
        (without-interrupts
          (set! h (%cap-ld-word at 0))
          (if (%= h 0)
              (begin (set! h (%lsh (%cap-base obj) -3)) (%cap-st-word! at 0 h))
              nil)
          h)
        h))))

;; What a table keyed by identity hashes (table.lisp). Symbols hash by
;; identity, fixnums and characters by value, and any other object by its
;; identity hash: none of these depends on where anything is. A pair has no
;; header to keep a hash in, so it hashes by its address, counted in
;; granules, and so does a capability that is no object, such as a slot
;; narrowed out of its vector; a table holding such a key watches for moves.
;; A hash only says where a probe starts: a key is found by `eq?`, which
;; stays exact.
;;
;; The number is scattered before a table masks it down to a slot: Fibonacci
;; hashing, then the high half folded into the low. Identities are handed out
;; in order, so as they are they would fill a table in runs, and a table
;; holding a few thousand of a machine's tens of thousands of symbols has keys
;; that share their low bits: both make long runs for a probe to walk.
(define (eq-hash k)
  (let ((h (%* (cond ((%symbol? k) (%lsh (%symbol-flags k) -8))
                     ((%fixnum? k) k)
                     ((%char? k) (%char->int k))
                     ((%null? k) 0)
                     ((%object? k)
                      (let ((w (unsafe (%cap-ld-word-at (kernel-ref kb-objects)
                                                        (%- (%cap-base k) 4)))))
                        (if (%= w 0) (identity-hash k) w)))
                     (else (%/ (%addr-of k) value-bytes)))
               -1640531535)))
    (%logxor h (%lsh h -16))))

;; ---------------------------------------------------------------- diagnostics
(define (out-of-memory what)
  (uart-string "out of memory: ")
  (uart-string what)
  (uart-nl)
  (unsafe (%halt exit-oom)))

;; ---------------------------------------------------------------- console
;; The serial port, reached raw: it works before anything else is up, inside
;; a trap handler, and after the scheduler has stopped being trustworthy,
;; which is why the collector and the panic path report through it. It is
;; written through the device's page in the kernel block. Nothing here
;; allocates. Ordinary console output goes through console.driver.
;; The page is the kernel block's, so each of these is a block, sound for
;; any caller: the line is anybody's to write.
(defsubst (uart-page) (declare unsafe) (%slot (kernel-ref kb-devices) dev-uart))

;; A character's code to the line, and the next code from it, or -1.
(define (uart-put n) (unsafe (%cap-st-word! (uart-page) uart-data-reg n)))
(define (uart-get) (unsafe (%cap-ld-word (uart-page) uart-data-reg)))

;; Whatever is waiting on the line, into the string `s` from its start,
;; until nothing is or `s` is full: answers how many characters came.
(define (uart-get-into s)
  (unsafe
  (let ((p (uart-page)) (n 0) (max (%string-length s)) (more t))
    (while (if more (%< n max) nil)
      (let ((v (%cap-ld-word p uart-data-reg)))
        (if (%= v -1)
            (set! more nil)
            (begin (%string-set! s n (%int->char v)) (set! n (%+ n 1))))))
    n)))

(define (uart-nl) (uart-put 10))

(define (uart-string s)
  (unsafe
  (let ((i 0) (n (%string-length s)) (p (uart-page)))
    (while (%< i n)
      (%cap-st-word! p uart-data-reg (%char->int (%string-ref s i)))
      (set! i (%+ i 1)))
    s)))

;; A negative number's digits are taken from it as it is, since the most
;; negative fixnum has no positive counterpart.
(define (uart-num n)
  (if (%< n 0)
      (begin
        (uart-put 45)
        (if (%< n -9) (uart-num (%- 0 (%/ n 10))) nil)
        (uart-put (%- 48 (%rem n 10))))
      (begin
        (if (%>= n 10) (uart-num (%/ n 10)) nil)
        (uart-put (%+ 48 (%rem n 10))))))

(define (uart-hex n)
  (uart-put 48)
  (uart-put 120)
  (let ((i 28))
    (while (%>= i 0)
      (let ((d (%logand (%lsh n (%- 0 i)) 15)))
        (uart-put (if (%< d 10) (%+ 48 d) (%+ 87 d))))
      (set! i (%- i 4)))))
