;;; core.lisp - the bottom of the library.
;;;
;;; Written with only the nine special forms (quote if lambda set! define
;;; begin while let defmacro) and the % primitives, because nothing else exists
;;; when it loads. The compiler open-codes most of these when it sees them in
;;; operator position; the definitions here are what a name means when it is
;;; passed around as a value.

(in-package lm)

;; `(unsafe-file)` at the top of a file, after its `in-package`, tells the
;; compiler that everything to the next `in-package` may say raw things
;; without an `unsafe` form around each. It does nothing when run: the
;; compiler takes it as a directive and compiles nothing for it.
(define (unsafe-file) nil)

;; ---------------------------------------------------------------- identity
(define (not x) (if x nil t))
(define (eq? a b) (%eq? a b))
(define (null? x) (%null? x))
(define (pair? x) (%cons? x))
(define (atom? x) (if (%cons? x) nil t))
(define (symbol? x) (%symbol? x))
(define (string? x) (%string? x))
(define (vector? x) (%vector? x))
(define (bytes? x) (%bytes? x))
(define (char? x) (%char? x))
(define (fixnum? x) (%fixnum? x))
(define (number? x) (if (%fixnum? x) t (%bignum? x)))
(define (function? x) (%closure? x))

;; `t` is its own value. The forge's interpreter says so in Rust; an image the
;; machine builds from these sources takes every value from them.
(define t 't)

(define (boolean? x) (if (%null? x) t (%eq? x t)))

;; ---------------------------------------------------------------- pairs
(define (cons a d) (%cons a d))
(define (car x) (%car x))
(define (cdr x) (%cdr x))
(define (set-car! p v) (%set-car! p v))
(define (set-cdr! p v) (%set-cdr! p v))
(define (caar x) (%car (%car x)))
(define (cadr x) (%car (%cdr x)))
(define (cdar x) (%cdr (%car x)))
(define (cddr x) (%cdr (%cdr x)))
(define (caddr x) (%car (%cdr (%cdr x))))
(define (cdddr x) (%cdr (%cdr (%cdr x))))
(define (cadddr x) (%car (%cdr (%cdr (%cdr x)))))
(define (caadr x) (%car (%car (%cdr x))))
(define (cdadr x) (%cdr (%car (%cdr x))))
(define (first x) (%car x))
(define (second x) (%car (%cdr x)))
(define (third x) (%car (%cdr (%cdr x))))
(define (rest x) (%cdr x))

;; ---------------------------------------------------------------- numbers
(define (add2 a b) (%+ a b))
(define (sub2 a b) (%- a b))
(define (mul2 a b) (%* a b))

;; `+`, `-` and `*` are mixed fixnum and bignum arithmetic: a result that
;; outgrows a fixnum promotes and one that fits again demotes. They are built
;; on the trapping fixnum instructions, so the common case is one instruction
;; and the widening happens in the trap handler (`try-widen` in sys.lisp).
;;
;; Three other families exist for code with a reason not to promote:
;;
;;   wrap+   wrap-   wrap*     modulo 2^31, silently: hashing, fixed point
;;   strict+ strict- strict*   an error if the answer is not a fixnum
;;   sat+    sat-    sat*      clamped to the ends of the fixnum range
(define (+ . xs)
  (let ((acc 0))
    (while (%cons? xs)
      (set! acc (%+o acc (%car xs)))
      (set! xs (%cdr xs)))
    acc))

(define (- x . xs)
  (if (%null? xs)
      (%-o 0 x)
      (let ((acc x))
        (while (%cons? xs)
          (set! acc (%-o acc (%car xs)))
          (set! xs (%cdr xs)))
        acc)))

(define (* . xs)
  (let ((acc 1))
    (while (%cons? xs)
      (set! acc (%*o acc (%car xs)))
      (set! xs (%cdr xs)))
    acc))

(define (wrap+ . xs)
  (let ((acc 0))
    (while (%cons? xs)
      (set! acc (%+ acc (%car xs)))
      (set! xs (%cdr xs)))
    acc))

(define (wrap- x . xs)
  (if (%null? xs)
      (%- 0 x)
      (let ((acc x))
        (while (%cons? xs)
          (set! acc (%- acc (%car xs)))
          (set! xs (%cdr xs)))
        acc)))

(define (wrap* . xs)
  (let ((acc 1))
    (while (%cons? xs)
      (set! acc (%* acc (%car xs)))
      (set! xs (%cdr xs)))
    acc))

(define most-positive-fixnum 1073741823)
(define most-negative-fixnum -1073741824)

(define (fixnum-only op r)
  (if (%fixnum? r) r (error "fixnum overflow in" op)))

(define (strict+ a b) (fixnum-only '+ (%+o a b)))
(define (strict- a b) (fixnum-only '- (%-o a b)))
(define (strict* a b) (fixnum-only '* (%*o a b)))

(define (saturate r)
  (if (%fixnum? r)
      r
      (if (negative? r) most-negative-fixnum most-positive-fixnum)))

(define (sat+ a b) (saturate (%+o a b)))
(define (sat- a b) (saturate (%-o a b)))
(define (sat* a b) (saturate (%*o a b)))

(define (/ x . xs)
  (let ((acc x))
    (while (%cons? xs)
      (set! acc (%/ acc (%car xs)))
      (set! xs (%cdr xs)))
    acc))

;; (< a b c) holds when every neighbouring pair does.
(define (chain2 op xs)
  (let ((ok t))
    (while (%cons? (%cdr xs))
      (if (%funcall op (%car xs) (%car (%cdr xs)))
          nil
          (begin (set! ok nil) (set! xs (list (%car xs)))))
      (set! xs (%cdr xs)))
    ok))

;; Top level functions rather than lambdas written in place: a lambda in place
;; would build a closure on every call.
(define (num-eq a b) (%= a b))
(define (num-lt a b) (%< a b))
(define (num-gt a b) (%> a b))
(define (num-le a b) (%<= a b))
(define (num-ge a b) (%>= a b))

;; Two required arguments, so that the common call, which is also what
;; `sort` and `apply` make through a variable, builds no rest list. The
;; primitive in value position is the checking instruction, which widens to
;; bignums through the trap handler.
(define (= a b . more) (if (%null? more) (%= a b) (chain2 num-eq (%cons a (%cons b more)))))
(define (< a b . more) (if (%null? more) (%< a b) (chain2 num-lt (%cons a (%cons b more)))))
(define (> a b . more) (if (%null? more) (%> a b) (chain2 num-gt (%cons a (%cons b more)))))
(define (<= a b . more) (if (%null? more) (%<= a b) (chain2 num-le (%cons a (%cons b more)))))
(define (>= a b . more) (if (%null? more) (%>= a b) (chain2 num-ge (%cons a (%cons b more)))))
(define (/= a b) (if (%= a b) nil t))

(define (1+ n) (%+o n 1))
(define (1- n) (%-o n 1))
(define (zero? n) (%= n 0))
(define (positive? n) (%> n 0))
(define (negative? n) (%< n 0))
;; Parity is the bottom bit of the bottom limb either way.
(define (even? n) (if (%bignum? n) (bignum-even? n) (%= 0 (%logand n 1))))
(define (odd? n) (if (even? n) nil t))
(define (abs n) (if (negative? n) (- 0 n) n))
(define (clamp v lo hi) (if (num-lt v lo) lo (if (num-gt v hi) hi v)))

;; Integer square root, by Newton. The first estimate is n/2 + 1, formed
;; without the n + 1 that overflows at the top of the fixnum range.
(define (isqrt n)
  (if (%< n 2)
      (if (%< n 0) 0 n)
      (let ((x n) (y (%+ (%lsh n -1) 1)))
        (while (%< y x)
          (set! x y)
          (set! y (%lsh (%+ x (%/ n x)) -1)))
        x)))
(define (neg n) (- 0 n))
(define (min2 a b) (if (num-lt a b) a b))
(define (max2 a b) (if (num-gt a b) a b))
(define (min x . xs)
  (while (%cons? xs)
    (if (%< (%car xs) x) (set! x (%car xs)) nil)
    (set! xs (%cdr xs)))
  x)
(define (max x . xs)
  (while (%cons? xs)
    (if (%> (%car xs) x) (set! x (%car xs)) nil)
    (set! xs (%cdr xs)))
  x)
(define (mod a b) (%mod a b))
(define (rem a b) (%rem a b))
(define (quotient a b) (%/ a b))
(define (remainder a b) (%rem a b))
(define (modulo a b) (%mod a b))
(define (logand . xs)
  (let ((acc -1))
    (while (%cons? xs) (set! acc (%logand acc (%car xs))) (set! xs (%cdr xs)))
    acc))
(define (logior . xs)
  (let ((acc 0))
    (while (%cons? xs) (set! acc (%logior acc (%car xs))) (set! xs (%cdr xs)))
    acc))
(define (logxor . xs)
  (let ((acc 0))
    (while (%cons? xs) (set! acc (%logxor acc (%car xs))) (set! xs (%cdr xs)))
    acc))
(define (lognot n) (%lognot n))

;; An arithmetic shift is a multiplication or division by a power of two, so
;; it promotes and demotes like the rest of the arithmetic. `%ash` is the fast
;; path when the value is a fixnum and the shift is small; a left shift is
;; checked by shifting back, because `%ash` takes its count modulo thirty-two
;; and drops bits off the top. `lsh` is the raw logical shift and stays raw.
(define (ash n k)
  (if (%fixnum? n)
      (if (if (%> k -31) (%< k 15) nil)
          (let ((r (%ash n k)))
            (if (%<= k 0)
                r
                (if (%= (%ash r (%- 0 k)) n) r (generic-ash n k))))
          (generic-ash n k))
      (generic-ash n k)))

(define (lsh n k) (%lsh n k))
(define (bit-set? n k) (%= 1 (%logand 1 (%ash n (%- 0 k)))))

;; By squaring, and promoting: (expt 2 100) is exact.
(define (expt b e)
  (let ((acc 1))
    (while (%> e 0)
      (if (%= 1 (%logand e 1)) (set! acc (* acc b)) nil)
      (set! b (* b b))
      (set! e (%lsh e -1)))
    acc))

(define (gcd a b)
  (set! a (abs a))
  (set! b (abs b))
  (while (%> b 0)
    (let ((r (%mod a b)))
      (set! a b)
      (set! b r)))
  a)

;; ---------------------------------------------------------------- lists
(define (list . xs) xs)

;; (list* 1 2 '(3 4)) => (1 2 3 4)
(define (list* x . xs)
  (if (%null? xs)
      x
      (let ((head (%cons x nil)) (tail nil))
        (set! tail head)
        (while (%cons? (%cdr xs))
          (%set-cdr! tail (%cons (%car xs) nil))
          (set! tail (%cdr tail))
          (set! xs (%cdr xs)))
        (%set-cdr! tail (%car xs))
        head)))

(define (length xs)
  (let ((n 0))
    (while (%cons? xs)
      (set! n (%+ n 1))
      (set! xs (%cdr xs)))
    n))

(define (reverse xs)
  (let ((acc nil))
    (while (%cons? xs)
      (set! acc (%cons (%car xs) acc))
      (set! xs (%cdr xs)))
    acc))

(define (revappend xs tail)
  (while (%cons? xs)
    (set! tail (%cons (%car xs) tail))
    (set! xs (%cdr xs)))
  tail)

(define (append2 a b)
  (if (%null? a) b (revappend (reverse a) b)))

(define (append . ls)
  (if (%null? ls)
      nil
      (let ((acc nil) (r (reverse ls)))
        (set! acc (%car r))
        (set! r (%cdr r))
        (while (%cons? r)
          (set! acc (append2 (%car r) acc))
          (set! r (%cdr r)))
        acc)))

(define (nthcdr n xs)
  (while (%> n 0)
    (set! xs (%cdr xs))
    (set! n (%- n 1)))
  xs)

(define (nth n xs) (%car (nthcdr n xs)))
(define (list-ref xs n) (%car (nthcdr n xs)))
(define (last-pair xs)
  (while (%cons? (%cdr xs)) (set! xs (%cdr xs)))
  xs)
(define (last xs) (%car (last-pair xs)))

(define (list? x)
  (while (%cons? x) (set! x (%cdr x)))
  (%null? x))

(define (memq x xs)
  (let ((r nil))
    (while (%cons? xs)
      (if (%eq? x (%car xs))
          (begin (set! r xs) (set! xs nil))
          (set! xs (%cdr xs))))
    r))

(define (member x xs)
  (let ((r nil))
    (while (%cons? xs)
      (if (equal? x (%car xs))
          (begin (set! r xs) (set! xs nil))
          (set! xs (%cdr xs))))
    r))

(define (assq k al)
  (let ((r nil))
    (while (%cons? al)
      (if (if (%cons? (%car al)) (%eq? k (%car (%car al))) nil)
          (begin (set! r (%car al)) (set! al nil))
          (set! al (%cdr al))))
    r))

(define (assoc k al)
  (let ((r nil))
    (while (%cons? al)
      (if (if (%cons? (%car al)) (equal? k (%car (%car al))) nil)
          (begin (set! r (%car al)) (set! al nil))
          (set! al (%cdr al))))
    r))

(define (map f xs)
  (if (%null? xs)
      nil
      (let ((head (%cons (%funcall f (%car xs)) nil)) (tail nil))
        (set! tail head)
        (set! xs (%cdr xs))
        (while (%cons? xs)
          (%set-cdr! tail (%cons (%funcall f (%car xs)) nil))
          (set! tail (%cdr tail))
          (set! xs (%cdr xs)))
        head)))

(define (mapcar f xs) (map f xs))

(define (map2 f xs ys)
  (if (%null? xs)
      nil
      (let ((head (%cons (%funcall f (%car xs) (%car ys)) nil)) (tail nil))
        (set! tail head)
        (set! xs (%cdr xs))
        (set! ys (%cdr ys))
        (while (if (%cons? xs) (%cons? ys) nil)
          (%set-cdr! tail (%cons (%funcall f (%car xs) (%car ys)) nil))
          (set! tail (%cdr tail))
          (set! xs (%cdr xs))
          (set! ys (%cdr ys)))
        head)))

(define (for-each f xs)
  (while (%cons? xs)
    (%funcall f (%car xs))
    (set! xs (%cdr xs)))
  nil)

(define (append-map f xs)
  (let ((acc nil))
    (while (%cons? xs)
      (set! acc (revappend (%funcall f (%car xs)) acc))
      (set! xs (%cdr xs)))
    (reverse acc)))

(define (remove-eq x l)
  (let ((acc nil))
    (dolist (e l) (if (%eq? e x) nil (set! acc (%cons e acc))))
    (reverse acc)))

(define (filter pred xs)
  (let ((acc nil))
    (while (%cons? xs)
      (if (%funcall pred (%car xs))
          (set! acc (%cons (%car xs) acc))
          nil)
      (set! xs (%cdr xs)))
    (reverse acc)))

(define (remove-if pred xs)
  (filter (lambda (x) (not (%funcall pred x))) xs))

(define (delq x xs)
  (filter (lambda (y) (not (%eq? x y))) xs))

(define (fold f init xs)
  (while (%cons? xs)
    (set! init (%funcall f init (%car xs)))
    (set! xs (%cdr xs)))
  init)

(define (fold-right f init xs)
  (fold (lambda (acc x) (%funcall f x acc)) init (reverse xs)))

(define (reduce f xs)
  (if (%null? xs) nil (fold f (%car xs) (%cdr xs))))

(define (any pred xs)
  (let ((r nil))
    (while (%cons? xs)
      (let ((v (%funcall pred (%car xs))))
        (if v (begin (set! r v) (set! xs nil)) (set! xs (%cdr xs)))))
    r))

(define (every pred xs)
  (let ((r t))
    (while (%cons? xs)
      (if (%funcall pred (%car xs))
          (set! xs (%cdr xs))
          (begin (set! r nil) (set! xs nil))))
    r))

(define (position x xs)
  (let ((i 0) (r nil))
    (while (%cons? xs)
      (if (equal? x (%car xs))
          (begin (set! r i) (set! xs nil))
          (begin (set! i (%+ i 1)) (set! xs (%cdr xs)))))
    r))

(define (list-index pred xs)
  (let ((i 0) (r nil))
    (while (%cons? xs)
      (if (%funcall pred (%car xs))
          (begin (set! r i) (set! xs nil))
          (begin (set! i (%+ i 1)) (set! xs (%cdr xs)))))
    r))

(define (list-copy xs) (revappend (reverse xs) nil))

(define (iota n)
  (let ((acc nil))
    (while (%> n 0)
      (set! n (%- n 1))
      (set! acc (%cons n acc)))
    acc))

(define (make-list n fill)
  (let ((acc nil))
    (while (%> n 0)
      (set! acc (%cons fill acc))
      (set! n (%- n 1)))
    acc))

;; Merge sort: stable, and no recursion on the length of the list. The runs
;; are kept in list order through every pass, which is what makes it stable.
(define (sort xs less)
  (if (%null? (%cdr xs))
      xs
      (let ((runs nil))
        (while (%cons? xs)
          (set! runs (%cons (%cons (%car xs) nil) runs))
          (set! xs (%cdr xs)))
        (set! runs (reverse runs))
        (while (%cons? (%cdr runs))
          (let ((merged nil))
            (while (%cons? runs)
              (if (%cons? (%cdr runs))
                  (begin
                    (set! merged (%cons (merge2 (%car runs) (cadr runs) less) merged))
                    (set! runs (%cdr (%cdr runs))))
                  (begin
                    (set! merged (%cons (%car runs) merged))
                    (set! runs nil))))
            (set! runs (reverse merged))))
        (%car runs))))

;; Takes from `a` unless an element of `b` is strictly less, so equal elements
;; keep their order.
(define (merge2 a b less)
  (let ((acc nil))
    (while (if (%cons? a) (%cons? b) nil)
      (if (%funcall less (%car b) (%car a))
          (begin (set! acc (%cons (%car b) acc)) (set! b (%cdr b)))
          (begin (set! acc (%cons (%car a) acc)) (set! a (%cdr a)))))
    (while (%cons? a)
      (set! acc (%cons (%car a) acc))
      (set! a (%cdr a)))
    (while (%cons? b)
      (set! acc (%cons (%car b) acc))
      (set! b (%cdr b)))
    (reverse acc)))

;; ---------------------------------------------------------------- equality
;; `eq?` is identity. Two bignums of the same value are two objects, so the
;; numeric equality has to be asked for them; fixnums are always `eq?`,
;; because every result that fits is demoted to one.
(define (eqv? a b)
  (unsafe
  (cond
   ((%eq? a b) t)
   ((%bignum? a) (if (%bignum? b) (%= a b) nil))
   ((%float? a)
    (if (%float? b) (%= (%ld-fixnum (%addr-of a)) (%ld-fixnum (%addr-of b))) nil))
   (else nil))))

(define (equal? a b)
  (if (%eq? a b)
      t
      (if (%bignum? a)
          (if (%bignum? b) (%= a b) nil)
      (if (%cons? a)
          (if (%cons? b)
              (if (equal? (%car a) (%car b)) (equal? (%cdr a) (%cdr b)) nil)
              nil)
          (if (%string? a)
              (if (%string? b) (string=? a b) nil)
              (if (%vector? a)
                  (if (%vector? b) (vector-equal? a b) nil)
                  nil))))))

(define (vector-equal? a b)
  (if (%= (%vector-length a) (%vector-length b))
      (let ((i 0) (n (%vector-length a)) (ok t))
        (while (%< i n)
          (if (equal? (%vector-ref a i) (%vector-ref b i))
              (set! i (%+ i 1))
              (begin (set! ok nil) (set! i n))))
        ok)
      nil))

;; ---------------------------------------------------------------- characters
(define (char->integer c) (%char->int c))
(define (integer->char n) (%int->char n))
(define (char=? a b) (%eq? a b))
(define (char<? a b) (%< (%char->int a) (%char->int b)))
(define (char>? a b) (%> (%char->int a) (%char->int b)))
(define (char-upcase c)
  (let ((n (%char->int c)))
    (if (if (%>= n 97) (%<= n 122) nil) (%int->char (%- n 32)) c)))
(define (char-downcase c)
  (let ((n (%char->int c)))
    (if (if (%>= n 65) (%<= n 90) nil) (%int->char (%+ n 32)) c)))
(define (char-alphabetic? c)
  (let ((n (%char->int c)))
    (if (if (%>= n 65) (%<= n 90) nil)
        t
        (if (%>= n 97) (%<= n 122) nil))))
(define (char-numeric? c)
  (let ((n (%char->int c)))
    (if (%>= n 48) (%<= n 57) nil)))
(define (char-whitespace? c)
  (let ((n (%char->int c)))
    (if (%= n 32) t (if (%= n 10) t (if (%= n 9) t (%= n 13))))))
(define (digit->int c) (%- (%char->int c) 48))

;; ---------------------------------------------------------------- strings
(define (string-length s) (%string-length s))
(define (string-ref s i) (%string-ref s i))
(define (string-set! s i c) (%string-set! s i c))
(define (make-string n) (make-string-n n))

(define (string=? a b)
  (if (%= (%string-length a) (%string-length b))
      (let ((i 0) (n (%string-length a)) (ok t))
        (while (%< i n)
          (if (%eq? (%string-ref a i) (%string-ref b i))
              (set! i (%+ i 1))
              (begin (set! ok nil) (set! i n))))
        ok)
      nil))

(define (string<? a b)
  (let ((i 0) (na (%string-length a)) (nb (%string-length b)) (r nil) (go t))
    (while go
      (if (%>= i na)
          (begin (set! r (%> nb na)) (set! go nil))
          (if (%>= i nb)
              (begin (set! r nil) (set! go nil))
              (let ((ca (%char->int (%string-ref a i)))
                    (cb (%char->int (%string-ref b i))))
                (if (%= ca cb)
                    (set! i (%+ i 1))
                    (begin (set! r (%< ca cb)) (set! go nil)))))))
    r))

(define (substring s from to)
  (let ((n (%- to from)) (out nil) (i 0))
    (set! out (make-string-n n))
    (while (%< i n)
      (%string-set! out i (%string-ref s (%+ from i)))
      (set! i (%+ i 1)))
    out))

(define (string-append . ss)
  (let ((n 0) (rest ss))
    (while (%cons? rest)
      (set! n (%+ n (%string-length (%car rest))))
      (set! rest (%cdr rest)))
    (let ((out (make-string-n n)) (o 0))
      (set! rest ss)
      (while (%cons? rest)
        (let ((s (%car rest)) (i 0))
          (while (%< i (%string-length s))
            (%string-set! out o (%string-ref s i))
            (set! o (%+ o 1))
            (set! i (%+ i 1))))
        (set! rest (%cdr rest)))
      out)))

(define (string->list s)
  (let ((i (%string-length s)) (acc nil))
    (while (%> i 0)
      (set! i (%- i 1))
      (set! acc (%cons (%string-ref s i) acc)))
    acc))

(define (list->string cs)
  (let ((out (make-string-n (length cs))) (i 0))
    (while (%cons? cs)
      (%string-set! out i (%car cs))
      (set! i (%+ i 1))
      (set! cs (%cdr cs)))
    out))

(define (string . cs) (list->string cs))

(define (string-index s c)
  (let ((i 0) (n (%string-length s)) (r nil))
    (while (%< i n)
      (if (%eq? c (%string-ref s i))
          (begin (set! r i) (set! i n))
          (set! i (%+ i 1))))
    r))

(define (string-upcase s) (list->string (map char-upcase (string->list s))))
(define (string-downcase s) (list->string (map char-downcase (string->list s))))

(define (string->symbol s) (intern-string s))
(define (symbol->string s) (%symbol-name s))
(define (intern s) (intern-string s))
(define (symbol-name s) (%symbol-name s))
(define (gensym) (gensym-1))

(define (number->string n)
  (if (%bignum? n)
      (bignum->string n)
      (number->string-fix n)))

(define (number->string-fix n)
  (cond
   ((%= n 0) "0")
   ;; Its magnitude is one more than the largest fixnum, so negating it
   ;; wraps straight back to itself.
   ((%= n -1073741824) "-1073741824")
   (else
      (let ((neg (%< n 0)) (acc nil))
        (if neg (set! n (%- 0 n)) nil)
        (while (%> n 0)
          (set! acc (%cons (%int->char (%+ 48 (%mod n 10))) acc))
          (set! n (%/ n 10)))
        (if neg (set! acc (%cons (%int->char 45) acc)) nil)
        (list->string acc)))))

;; The bit pattern of the word, so a negative number shows as eight digits.
(define (number->hex n)
  (if (%= n 0)
      "0"
      (let ((acc nil) (d 0))
        (while (if (%> n 0) t (%< n 0))
          (set! d (%logand n 15))
          (set! acc (%cons (%int->char (if (%< d 10) (%+ 48 d) (%+ 87 d))) acc))
          (set! n (%lsh n -4)))
        (list->string acc))))

;; Straight off the string, with promoting arithmetic: a literal wider than a
;; fixnum reads as a bignum.
(define (string->number s)
  (let ((i 0) (n (%string-length s)) (neg nil) (acc 0) (ok nil))
    (if (%> n 0)
        (if (%eq? (%string-ref s 0) #\-)
            (begin (set! neg t) (set! i 1))
            (if (%eq? (%string-ref s 0) #\+) (set! i 1) nil))
        nil)
    (while (%< i n)
      (if (char-numeric? (%string-ref s i))
          (begin
            (set! ok t)
            (set! acc (+ (* acc 10) (digit->int (%string-ref s i))))
            (set! i (%+ i 1)))
          (begin (set! ok nil) (set! i n))))
    (if ok (if neg (- 0 acc) acc) nil)))

;; ---------------------------------------------------------------- vectors
(define (make-vector n . fill)
  (make-vector-n n (if (%cons? fill) (%car fill) nil)))
(define (vector . xs) (list->vector xs))
(define (vector-length v) (%vector-length v))
(define (vector-ref v i) (%vector-ref v i))
(define (vector-set! v i x) (%vector-set! v i x))

(define (list->vector xs)
  (let ((v (make-vector-n (length xs) nil)) (i 0))
    (while (%cons? xs)
      (%vector-set! v i (%car xs))
      (set! i (%+ i 1))
      (set! xs (%cdr xs)))
    v))

(define (vector->list v)
  (let ((i (%vector-length v)) (acc nil))
    (while (%> i 0)
      (set! i (%- i 1))
      (set! acc (%cons (%vector-ref v i) acc)))
    acc))

(define (vector-fill! v x)
  (let ((i 0) (n (%vector-length v)))
    (while (%< i n)
      (%vector-set! v i x)
      (set! i (%+ i 1)))
    v))

(define (vector-map f v) (list->vector (map f (vector->list v))))

(define (vector-grow v n)
  (let ((out (make-vector-n n nil)) (i 0) (m (%vector-length v)))
    (while (%< i m)
      (%vector-set! out i (%vector-ref v i))
      (set! i (%+ i 1)))
    out))

;; ---------------------------------------------------------------- bytes
(define (make-bytes n) (make-bytes-n n))
(define (bytes-length b) (%bytes-length b))
(define (bytes-ref b i) (%bytes-ref b i))
(define (bytes-set! b i v) (%bytes-set! b i v))

;; ---------------------------------------------------------------- symbols
(define (symbol-value s) (%symbol-value s))
(define (set-symbol-value! s v) (%set-symbol-value! s v))
(define (symbol-function s) (%symbol-function s))
(define (set-symbol-function! s v) (%set-symbol-function! s v))
(define (symbol-plist s) (%symbol-plist s))

(define (get sym key)
  (let ((p (%symbol-plist sym)) (r nil))
    (while (%cons? p)
      (if (%eq? (%car p) key)
          (begin (set! r (cadr p)) (set! p nil))
          (set! p (%cdr p))))
    r))

(define (put sym key val)
  (let ((p (%symbol-plist sym)) (done nil))
    (while (%cons? p)
      (if (%eq? (%car p) key)
          (begin (%set-car! (%cdr p) val) (set! done t) (set! p nil))
          (set! p (%cdr p))))
    (if done
        val
        (begin
          (%set-symbol-plist! sym (%cons key (%cons val (%symbol-plist sym))))
          val))))

;; ---------------------------------------------------------------- functions
;; A function may be named by its symbol wherever one is called for, so
;; (funcall 'car x) and (apply '+ xs) work. This is a Lisp-1: the function is
;; the symbol's value. `%fluid-value` rather than `%symbol-value` because the
;; forge keeps its globals somewhere else.
(define (resolve-function f)
  (let ((g (if (%symbol? f) (%fluid-value f) f)))
    (if (%closure? g) g (error "not a function:" f))))

(define (funcall f . args) (%apply (resolve-function f) args))

;; (apply f 1 2 '(3 4)) calls f with 1 2 3 4: the last argument is a list and
;; any before it go on its front.
(define (apply f arg . more)
  (%apply (resolve-function f) (if (%null? more) arg (%cons arg (%apply list* more)))))

;; `%apply` takes a list of any length: the first eight go in registers and
;; the rest on the stack. This is it without the symbol lookup.
(define (apply-list f args) (%apply f args))
(define (identity x) x)
(define (compose f g) (lambda (x) (%funcall f (%funcall g x))))
(define (constantly x) (lambda () x))

;; Output is in print.lisp for the machine and hostio.lisp for the forge.
