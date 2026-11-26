;;; bignum.lisp - integers that do not fit a fixnum.
;;;
;;; A bignum is an object of type `t-bignum`: slot 0 is the sign, 0 for
;;; positive and 1 for negative, and the slots after it are the magnitude as
;;; 32-bit limbs, least significant first. A limb is a fixnum holding the
;;; limb's thirty-two bits, so one with its top bit set reads as negative.
;;;
;;; Two invariants, which everything here depends on:
;;;
;;;   - The top limb is never zero and the magnitude is never zero. Zero is
;;;     the fixnum 0.
;;;   - A value that fits a fixnum is a fixnum. Every operation ends by
;;;     demoting, so `eq?` works on small numbers and `%fixnum?` is a complete
;;;     test for "small".
;;;
;;; The arithmetic works sixteen bits at a time. A product of two limbs is
;;; sixty-four bits, but a product of two halves plus two more halves is at
;;; most 2^32 - 1, which a fixnum holds exactly when its bits are read
;;; unsigned: a mask takes the low half of it and a logical shift the high.
;;; All the arithmetic on pieces is the wrapping kind, which is exact on the
;;; bits.
;;;
;;; Half 2i of the magnitude is the low sixteen bits of limb i and half 2i+1
;;; the high sixteen: halves are a finer view of the same limbs, in the same
;;; order.

(in-package lm)

(defconstant bn-hmask 65535)
(defconstant bn-hbits 16)
(defconstant bn-hbase 65536)

;; ---------------------------------------------------------------- layout
;; The slots are reached through the bignum's own capability, whose bounds
;; are its payload.
(defsubst (bn-limbs b) (%- (%obj-len b) 1))
(defsubst (bn-halves b) (%lsh (%- (%obj-len b) 1) 1))
(defsubst (bn-sign b) (%cap-ld b 0))
(defsubst (bn-limb b i) (%cap-ld b (%* value-bytes (%+ i 1))))
(defsubst (bn-set-limb! b i v) (%cap-st! b (%* value-bytes (%+ i 1)) v))

;; A magnitude is passed as the bignum that holds it plus a count of
;; significant halves. A half reads from 0 to 65535, and writing one leaves
;; the other half of its limb as it was.
(defsubst (mag-half b i)
  (let ((w (bn-limb b (%lsh i -1))))
    (if (%= 0 (%logand i 1)) (%logand w bn-hmask) (%lsh w (%- 0 bn-hbits)))))

(defsubst (mag-set! b i v)
  (let* ((j (%lsh i -1)) (w (bn-limb b j)))
    (bn-set-limb! b j (if (%= 0 (%logand i 1))
                          (%logior (%logand w (%lognot bn-hmask)) v)
                          (%logior (%logand w bn-hmask) (%lsh v bn-hbits))))))

;; The limbs of a fresh bignum are zero.
(define (bn-alloc nlimbs sign)
  (check-length (%+ nlimbs 1))
  (let ((b (unsafe (alloc-object t-bignum (%+ nlimbs 1)))))
    (%cap-st! b 0 sign)
    b))

;; Room for `nh` halves, rounded up to whole limbs.
(define (bn-alloc-halves nh sign)
  (bn-alloc (%lsh (%+ nh 1) -1) sign))

;; How many halves of this magnitude matter, counting down from `n`.
(define (mag-sig b n)
  (let ((i n))
    (while (if (%> i 0) (%= 0 (mag-half b (%- i 1))) nil)
      (set! i (%- i 1)))
    i))

;; ---------------------------------------------------------------- finishing
;; Every operation builds its result at the largest size it could need and
;; ends here: demote to a fixnum if it fits, otherwise an object of exactly
;; the right length. A one-limb magnitude fits when it is below 2^31, which
;; is when the limb reads as non-negative. 2^31 itself fits only as a
;; negative, and then the limb's bits are already those of -2^31.
(define (bn-finish b nsig)
  (cond
   ((%= nsig 0) 0)
   ((%<= nsig 2)
    (let ((m (bn-limb b 0)) (neg (%= (bn-sign b) 1)))
      (cond ((%>= m 0) (if neg (%- 0 m) m))
            ((if neg (%= m most-negative-fixnum) nil) m)
            (else (bn-shrink b nsig)))))
   (else (bn-shrink b nsig))))

;; The halves above `nsig` are zero, so whole limbs are copied.
(define (bn-shrink b nsig)
  (let ((want (%lsh (%+ nsig 1) -1)))
    (if (%= want (bn-limbs b))
        b
        (let ((r (bn-alloc want (bn-sign b))) (i 0))
          (while (%< i want)
            (bn-set-limb! r i (bn-limb b i))
            (set! i (%+ i 1)))
          r))))

;; ---------------------------------------------------------------- promotion
;; A fixnum as a one-limb magnitude. The most negative fixnum needs no case
;; of its own: negating it wraps back to itself, and its bits read unsigned
;; are its magnitude, 2^31.
(define (bn-of x)
  (if (%bignum? x)
      x
      (let* ((neg (%< x 0))
             (b (bn-alloc 1 (if neg 1 0))))
        (bn-set-limb! b 0 (if neg (%- 0 x) x))
        b)))

;; ---------------------------------------------------------------- magnitudes
;; These take magnitudes and significant half counts and never look at a
;; sign. A destination may be one of the sources: each half is read before it
;; is written.

(define (mag-cmp pa na pb nb)
  (cond ((%< na nb) -1)
        ((%> na nb) 1)
        (else
         (let ((i na) (r 0))
           (while (if (%> i 0) (%= r 0) nil)
             (set! i (%- i 1))
             (let ((x (mag-half pa i)) (y (mag-half pb i)))
               (cond ((%< x y) (set! r -1))
                     ((%> x y) (set! r 1))
                     (else nil))))
           r))))

(define (mag-add! pr pa na pb nb)
  (let ((n (if (%> na nb) na nb)) (i 0) (c 0))
    (while (%< i n)
      (let ((t (%+ (%+ (if (%< i na) (mag-half pa i) 0)
                       (if (%< i nb) (mag-half pb i) 0))
                   c)))
        (mag-set! pr i (%logand t bn-hmask))
        (set! c (%lsh t (%- 0 bn-hbits))))
      (set! i (%+ i 1)))
    (if (%> c 0)
        (begin (mag-set! pr n c) (%+ n 1))
        n)))

;; a minus b, where the caller has established that a is the larger.
(define (mag-sub! pr pa na pb nb)
  (let ((i 0) (bor 0))
    (while (%< i na)
      (let ((t (%- (%- (mag-half pa i) (if (%< i nb) (mag-half pb i) 0)) bor)))
        (if (%< t 0)
            (begin (set! t (%+ t bn-hbase)) (set! bor 1))
            (set! bor 0))
        (mag-set! pr i t))
      (set! i (%+ i 1)))
    (mag-sig pr na)))

;; Schoolbook, into a destination that starts as zero with room for na+nb
;; halves. Each step adds a product of two halves, the half already there and
;; the carry: at most (B-1)^2 + 2(B-1) = B^2 - 1, so the sum is exact in
;; thirty-two bits and the carry it leaves stays below B.
(define (mag-mul! pr pa na pb nb)
  (let ((j 0))
    (while (%< j nb)
      (let ((bj (mag-half pb j)))
        (if (%= bj 0)
            nil
            (let ((i 0) (c 0))
              (while (%< i na)
                (let* ((k (%+ i j))
                       (t (%+ (%+ (%* (mag-half pa i) bj) (mag-half pr k)) c)))
                  (mag-set! pr k (%logand t bn-hmask))
                  (set! c (%lsh t (%- 0 bn-hbits))))
                (set! i (%+ i 1)))
              (let ((k (%+ na j)))
                (while (%> c 0)
                  (let ((t (%+ (mag-half pr k) c)))
                    (mag-set! pr k (%logand t bn-hmask))
                    (set! c (%lsh t (%- 0 bn-hbits))))
                  (set! k (%+ k 1)))))))
      (set! j (%+ j 1)))
    (mag-sig pr (%+ na nb))))

;; ---------------------------------------------------------------- division
;; Divide a magnitude in place by a small number and answer the remainder.
;; `d` must be under 2^15: the running value is r * 2^16 + half, and with r
;; below d that stays below 2^31, where the signed division is exact.
(define (mag-div-small! p n d)
  (let ((i n) (r 0))
    (while (%> i 0)
      (set! i (%- i 1))
      (let ((cur (%+ (%lsh r bn-hbits) (mag-half p i))))
        (mag-set! p i (%/ cur d))
        (set! r (%mod cur d))))
    r))

;; Shift a magnitude left one bit in place over `n` halves; answers the bit
;; shifted out.
(define (mag-shl1! p n)
  (let ((i 0) (c 0))
    (while (%< i n)
      (let ((t (%+ (%lsh (mag-half p i) 1) c)))
        (mag-set! p i (%logand t bn-hmask))
        (set! c (%lsh t (%- 0 bn-hbits))))
      (set! i (%+ i 1)))
    c))

;; Long division a bit at a time. A digit-at-a-time method needs to divide a
;; thirty-two bit value by a sixteen bit one, and the fixnum division is
;; signed, so a dividend with its top bit set would come out wrong. `pq` gets
;; the quotient over `na` halves and `pr` the remainder over nb+1; both start
;; zeroed, and the caller normalises them.
(define (mag-divmod! pq pr pa na pb nb)
  (let ((bit (%- (%* na bn-hbits) 1)))
    (while (%>= bit 0)
      (mag-shl1! pr (%+ nb 1))
      (let* ((h (%lsh bit (%- 0 4)))
             (k (%logand bit 15))
             (v (%logand (%lsh (mag-half pa h) (%- 0 k)) 1)))
        (if (%= v 1) (mag-set! pr 0 (%logior (mag-half pr 0) 1)) nil))
      (if (%>= (mag-cmp pr (mag-sig pr (%+ nb 1)) pb nb) 0)
          (begin
            (mag-sub! pr pr (%+ nb 1) pb nb)
            (let ((h (%lsh bit (%- 0 4)))
                  (k (%logand bit 15)))
              (mag-set! pq h (%logior (mag-half pq h) (%lsh 1 k)))))
          nil)
      (set! bit (%- bit 1)))))

;; ---------------------------------------------------------------- generic
;; The entry points take fixnums or bignums in any combination and answer
;; whichever kind the result belongs in.

(define (bn-add-mag x y sign)
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig bx (bn-halves bx)))
         (ny (mag-sig by (bn-halves by)))
         (r (bn-alloc-halves (%+ (if (%> nx ny) nx ny) 1) sign)))
    (bn-finish r (mag-add! r bx nx by ny))))

;; Larger minus smaller, with the sign given; the caller has compared them.
(define (bn-sub-mag x y sign)
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig bx (bn-halves bx)))
         (ny (mag-sig by (bn-halves by)))
         (r (bn-alloc-halves nx sign)))
    (bn-finish r (mag-sub! r bx nx by ny))))

(define (num-sign x)
  (cond ((%bignum? x) (bn-sign x))
        ((%< x 0) 1)
        (else 0)))

(define (num-mag-cmp x y)
  (let ((bx (bn-of x)) (by (bn-of y)))
    (mag-cmp bx (mag-sig bx (bn-halves bx)) by (mag-sig by (bn-halves by)))))

(define (generic-add x y)
  (let ((sx (num-sign x)) (sy (num-sign y)))
    (if (%= sx sy)
        (bn-add-mag x y sx)
        ;; different signs: the larger magnitude wins and keeps its sign
        (let ((c (num-mag-cmp x y)))
          (cond ((%= c 0) 0)
                ((%> c 0) (bn-sub-mag x y sx))
                (else (bn-sub-mag y x sy)))))))

(define (generic-neg x)
  (cond ((%bignum? x)
         (let* ((n (bn-limbs x))
                (r (bn-alloc n (if (%= (bn-sign x) 1) 0 1)))
                (i 0))
           (while (%< i n)
             (bn-set-limb! r i (bn-limb x i))
             (set! i (%+ i 1)))
           (bn-finish r (bn-halves r))))
        ;; The one fixnum whose negation is not a fixnum: 2^31, whose limb
        ;; has the bits of -2^31.
        ((%= x most-negative-fixnum)
         (let ((b (bn-alloc 1 0)))
           (bn-set-limb! b 0 x)
           b))
        (else (%- 0 x))))

(define (generic-sub x y) (generic-add x (generic-neg y)))

(define (generic-mul x y)
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig bx (bn-halves bx)))
         (ny (mag-sig by (bn-halves by))))
    (if (if (%= nx 0) t (%= ny 0))
        0
        (let ((r (bn-alloc-halves (%+ nx ny)
                                  (if (%= (bn-sign bx) (bn-sign by)) 0 1))))
          (bn-finish r (mag-mul! r bx nx by ny))))))

;; -1, 0 or 1, for values of either kind.
(define (generic-cmp x y)
  (let ((sx (num-sign x)) (sy (num-sign y)))
    (cond ((if (%= sx 0) (%= sy 1) nil) 1)
          ((if (%= sx 1) (%= sy 0) nil) -1)
          (else
           (let ((c (num-mag-cmp x y)))
             (if (%= sx 1) (%- 0 c) c))))))

(define (generic-zero? x) (if (%bignum? x) nil (%= x 0)))

;; Quotient truncated toward zero and a remainder with the dividend's sign,
;; the rule the fixnum instructions follow.
(define (generic-divmod x y want-rem)
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig bx (bn-halves bx)))
         (ny (mag-sig by (bn-halves by))))
    (if (%= ny 0)
        (error "division by zero")
        (if (%< (mag-cmp bx nx by ny) 0)
            ;; the divisor is larger: the quotient is zero and the remainder
            ;; is the dividend
            (if want-rem x 0)
            (let ((q (bn-alloc-halves nx (if (%= (bn-sign bx) (bn-sign by)) 0 1)))
                  (r (bn-alloc-halves (%+ ny 1) (bn-sign bx))))
              (mag-divmod! q r bx nx by ny)
              (if want-rem
                  (bn-finish r (mag-sig r (%+ ny 1)))
                  (bn-finish q (mag-sig q nx))))))))

(define (generic-quotient x y) (generic-divmod x y nil))
(define (generic-remainder x y) (generic-divmod x y t))

;; ---------------------------------------------------------------- printing
;; Four decimal digits at a time: ten thousand is the largest power of ten
;; under the small-divisor limit.
(defconstant bn-decimal-chunk 10000)

(define (bignum->string b)
  (let* ((n (bn-limbs b))
         ;; a scratch copy, because dividing is destructive
         (w (bn-alloc n 0))
         (i 0)
         (groups nil))
    (while (%< i n)
      (bn-set-limb! w i (bn-limb b i))
      (set! i (%+ i 1)))
    (let ((sig (mag-sig w (bn-halves w))))
      (while (%> sig 0)
        (set! groups (%cons (mag-div-small! w sig bn-decimal-chunk) groups))
        (set! sig (mag-sig w sig))))
    (if (%null? groups)
        "0"
        (let ((out (if (%= (bn-sign b) 1) "-" "")))
          (set! out (string-append out (number->string (%car groups))))
          (set! groups (%cdr groups))
          (while (%cons? groups)
            (set! out (string-append out (pad4 (%car groups))))
            (set! groups (%cdr groups)))
          out))))

(define (pad4 n)
  (let ((s (number->string n)))
    (while (%< (%string-length s) 4)
      (set! s (string-append "0" s)))
    s))

;; ---------------------------------------------------------------- predicates
(define (bignum? x) (%bignum? x))

(define (bignum-even? b)
  (%= 0 (%logand (bn-limb b 0) 1)))

;; ---------------------------------------------------------------- shifting
;; Two to the k, as a value: bit k mod 32 of limb k/32.
(define (bn-two-to k)
  (let* ((j (%/ k 32))
         (b (bn-alloc (%+ j 1) 0)))
    (bn-set-limb! b j (%lsh 1 (%mod k 32)))
    (bn-finish b (bn-halves b))))

;; `ash` floors: -1 shifted right by anything is still -1. `generic-quotient`
;; truncates, so a negative value with something shifted off the end is one
;; too high and is corrected.
(define (generic-ash x k)
  (cond
   ((%= k 0) x)
   ((%> k 0) (generic-mul x (bn-two-to k)))
   (else
    (let* ((d (bn-two-to (%- 0 k)))
           (q (generic-quotient x d)))
      (if (%< (generic-cmp x 0) 0)
          (if (generic-zero? (generic-remainder x d)) q (generic-sub q 1))
          q)))))
