;;; runtime.lisp - what compiled code calls into.
;;;
;;; These run under the bootstrap interpreter while the image is being built
;;; and as native code afterwards, and both times they do exactly the same
;;; thing to exactly the same words of memory. Nothing here may create a
;;; closure: the compiler emits a call to `make-closure` for every lambda, so
;;; a lambda in this file would be a circle.

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
(define (string-hash s)
  ;; djb2, masked to 30 bits every round so every intermediate stays a fixnum.
  ;; Heap::sym_hash in the forge computes exactly this.
  (let ((h 5381) (i 0) (n (%string-length s)))
    (while (%< i n)
      (set! h (%logand (%+ (%* h 33) (%char->int (%string-ref s i))) 1073741823))
      (set! i (%+ i 1)))
    h))

(define (intern-string s)
  (let* ((ob (%raw-ld lg-obarray))
         (n (%vector-length ob))
         (b (%mod (string-hash s) n))
         (chain (%vector-ref ob b))
         (found nil))
    (while (%cons? chain)
      (if (string=? (%symbol-name (%car chain)) s)
          (begin (set! found (%car chain)) (set! chain nil))
          (set! chain (%cdr chain))))
    (if found
        found
        (let ((sym (alloc-object t-symbol sym-slots)))
          (%set-slot! sym sym-name s)
          (%set-slot! sym sym-value *unbound*)
          (%set-slot! sym sym-function nil)
          (%set-slot! sym sym-plist nil)
          (%set-slot! sym sym-flags 0)
          (%vector-set! ob b (%cons sym (%vector-ref ob b)))
          (%raw-st! lg-symlist (%cons sym (%raw-ld lg-symlist)))
          sym))))

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
