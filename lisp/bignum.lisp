;;; bignum.lisp - integers that do not fit a fixnum.
;;;
;;; A bignum is an object of type `t-bignum`: slot 0 is the sign, 0 for
;;; positive and 1 for negative, and the slots after it are the magnitude as
;;; raw 32-bit limbs, least significant first. That is the machine's own word,
;;; so a one-limb bignum is exactly a machine word with a sign on it, and
;;; `peek` can hand back any word there is.
;;;
;;; Two invariants, and everything here depends on both:
;;;
;;;   - The top limb is never zero, and the magnitude is never zero. Zero is
;;;     the fixnum 0 and nothing else.
;;;   - A value that fits in a fixnum *is* a fixnum. Every operation here ends
;;;     by demoting, which is what keeps `eq?` working on small numbers and
;;;     what makes `(%fixnum? n)` a complete test for "small".
;;;
;;; ---------------------------------------------------------------- halves
;;;
;;; The arithmetic works sixteen bits at a time, not thirty-two, and this is
;;; the one thing worth understanding before reading any of it.
;;;
;;; A fixnum has thirty-one bits. A limb has thirty-two, so no Lisp variable
;;; can hold one - the moment a limb is loaded into a value it has to be
;;; narrower than the storage it came from. Sixteen is the width that works:
;;; a sum of two halves and a carry is eighteen bits, and a product of two
;;; halves is thirty-two, which is one bit too wide - so the product is taken
;;; in two pieces, `%mulhi16` for the top half and a wrapping `%*` for the
;;; bottom. Everything else stays comfortably inside a fixnum.
;;;
;;; The machine is little-endian, so half `2i` of the magnitude is the low
;;; sixteen bits of limb `i` and half `2i+1` is the high sixteen. Halves are
;;; therefore just a finer-grained view of the same array, in the same order,
;;; and nothing has to be repacked to move between the two.

(in-package lm)

(define bn-hmask 65535)
(define bn-hbits 16)
(define bn-hbase 65536)

;; The largest fixnum is 2^30 - 1 and the smallest is -2^30, so a magnitude of
;; 2^30 fits only if it is negative. That asymmetry shows up once, in
;; `bn-finish`, and nowhere else.
(define bn-fix-hi 16384)          ; the high half of 2^30

;; ---------------------------------------------------------------- layout
(defsubst (bn-limbs b) (%- (%obj-len b) 1))
(defsubst (bn-halves b) (%lsh (%- (%obj-len b) 1) 1))
(defsubst (bn-mag b) (%+ (%addr-of b) 4))
(defsubst (bn-sign b) (%ld-fixnum (%addr-of b)))

;; A magnitude is passed around as the address of its first limb plus a count
;; of significant halves, so a loop hoists the address out once.
(defsubst (mag-half p i) (%ld-half (%+ p (%lsh i 1))))
(defsubst (mag-set! p i v) (%st-half! (%+ p (%lsh i 1)) v))

(define (bn-alloc nlimbs sign)
  (let ((b (alloc-object t-bignum (%+ nlimbs 1))))
    (%st-fixnum! (%addr-of b) sign)
    b))

;; Room for `nh` halves, rounded up to whole limbs.
(define (bn-alloc-halves nh sign)
  (bn-alloc (%lsh (%+ nh 1) -1) sign))

;; How many halves of this magnitude matter, counting down from `n`.
(define (mag-sig p n)
  (let ((i n))
    (while (if (%> i 0) (%= 0 (mag-half p (%- i 1))) nil)
      (set! i (%- i 1)))
    i))

;; ---------------------------------------------------------------- finishing
;; Every operation builds its result at the largest size it could need and
;; ends here, which applies both invariants at once: demote to a fixnum if it
;; fits, and otherwise hand back an object of exactly the right length.
(define (bn-finish b nsig)
  (let ((sign (bn-sign b)))
    (cond
     ((%= nsig 0) 0)
     ((%<= nsig 2)
      (let* ((h0 (mag-half (bn-mag b) 0))
             (h1 (if (%= nsig 2) (mag-half (bn-mag b) 1) 0)))
        (if (if (%< h1 bn-fix-hi)
                t
                ;; exactly 2^30, which is a fixnum only as a negative
                (if (%= h1 bn-fix-hi) (if (%= h0 0) (%= sign 1) nil) nil))
            ;; `%*` and `%+` wrap, and wrapping is exactly right here: for the
            ;; one magnitude that only fits as a negative, 2^30 wraps to -2^30
            ;; and negating it again leaves it there.
            (let ((v (%+ h0 (%* h1 bn-hbase))))
              (if (%= sign 1) (%- 0 v) v))
            (bn-shrink b nsig))))
     (else (bn-shrink b nsig)))))

(define (bn-shrink b nsig)
  (let ((want (%lsh (%+ nsig 1) -1)))
    (if (%= want (bn-limbs b))
        b
        (let* ((r (bn-alloc want (bn-sign b)))
               (p (bn-mag b))
               (q (bn-mag r))
               (i 0))
          (while (%< i nsig)
            (mag-set! q i (mag-half p i))
            (set! i (%+ i 1)))
          r))))

;; ---------------------------------------------------------------- promotion
;; A fixnum as a one-limb magnitude.
;;
;; The most negative fixnum is written out rather than negated: its magnitude
;; is 2^30, which is one more than the largest fixnum, so `(%- 0 x)` has
;; nowhere to put the answer and wraps straight back to x. Every other fixnum
;; negates into range.
(define bn-most-negative -1073741824)

(define (bn-of x)
  (cond
   ((%bignum? x) x)
   ((%= x bn-most-negative)
    (let ((b (bn-alloc 1 1)))
      (mag-set! (bn-mag b) 0 0)
      (mag-set! (bn-mag b) 1 bn-fix-hi)
      b))
   (else
    (let* ((neg (%< x 0))
           (m (if neg (%- 0 x) x))
           (b (bn-alloc 1 (if neg 1 0))))
      (mag-set! (bn-mag b) 0 (%logand m bn-hmask))
      (mag-set! (bn-mag b) 1 (%lsh m (%- 0 bn-hbits)))
      b))))

;; Significant halves of a value that may be either kind.
(define (num-sig x)
  (if (%bignum? x)
      (mag-sig (bn-mag x) (bn-halves x))
      2))

;; ---------------------------------------------------------------- magnitudes
;; All four take addresses and significant half counts, and none of them looks
;; at a sign.

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

;; a minus b, and the caller has already established that a is the larger.
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

;; Schoolbook, into a destination that starts as zero and has room for na+nb
;; halves. The carry stays below 2^16 throughout: a row contributes at most
;; (B-1)^2, and adding the running digit and the carry to that keeps the total
;; under B^2, which is what a two-digit result means.
(define (mag-mul! pr pa na pb nb)
  (let ((j 0))
    (while (%< j nb)
      (let ((bj (mag-half pb j)))
        (if (%= bj 0)
            nil
            (let ((i 0) (c 0))
              (while (%< i na)
                (let* ((ai (mag-half pa i))
                       (hi (%mulhi16 ai bj))
                       (lo (%logand (%* ai bj) bn-hmask))
                       (k (%+ i j))
                       (t (%+ (%+ (mag-half pr k) lo) c)))
                  (mag-set! pr k (%logand t bn-hmask))
                  (set! c (%+ hi (%lsh t (%- 0 bn-hbits)))))
                (set! i (%+ i 1)))
              ;; and whatever is left over, up the rest of the destination
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
;; `d` must be under 2^14: the running value is `r * 2^16 + half`, and with r
;; below d that stays inside a fixnum exactly while d does.
(define bn-small-max 16384)

(define (mag-div-small! p n d)
  (let ((i n) (r 0))
    (while (%> i 0)
      (set! i (%- i 1))
      (let ((cur (%+ (%lsh r bn-hbits) (mag-half p i))))
        (mag-set! p i (%/ cur d))
        (set! r (%mod cur d))))
    r))

;; Shift a magnitude left one bit, in place, over `n` halves. Answers the bit
;; shifted out.
(define (mag-shl1! p n)
  (let ((i 0) (c 0))
    (while (%< i n)
      (let ((t (%+ (%lsh (mag-half p i) 1) c)))
        (mag-set! p i (%logand t bn-hmask))
        (set! c (%lsh t (%- 0 bn-hbits))))
      (set! i (%+ i 1)))
    c))

;; Long division, a bit at a time. Slower than a digit-at-a-time method and
;; very much simpler: the estimate step of the usual algorithm needs to divide
;; a thirty-two bit value by a sixteen bit one, and thirty-two bits is the one
;; width this machine cannot hold in a value.
;;
;; `pq` gets the quotient over `na` halves and `pr` the remainder over `nb+1`;
;; both start zeroed. Answers nothing - the caller normalises both.
(define (mag-divmod! pq pr pa na pb nb)
  (let ((bit (%- (%* na bn-hbits) 1)))
    (while (%>= bit 0)
      ;; remainder <- remainder*2 + the next bit of the dividend
      (mag-shl1! pr (%+ nb 1))
      (let* ((h (%lsh bit (%- 0 4)))
             (k (%logand bit 15))
             (v (%logand (%lsh (mag-half pa h) (%- 0 k)) 1)))
        (if (%= v 1) (mag-set! pr 0 (%logior (mag-half pr 0) 1)) nil))
      ;; and take out one copy of the divisor if it goes
      (if (%>= (mag-cmp pr (mag-sig pr (%+ nb 1)) pb nb) 0)
          (begin
            (mag-sub! pr pr (%+ nb 1) pb nb)
            (let ((h (%lsh bit (%- 0 4)))
                  (k (%logand bit 15)))
              (mag-set! pq h (%logior (mag-half pq h) (%lsh 1 k)))))
          nil)
      (set! bit (%- bit 1)))))

;; ---------------------------------------------------------------- generic
;; The entry points. Each takes fixnums or bignums in any combination and
;; answers whichever kind the result belongs in.

(define (bn-add-mag x y sign)
  ;; magnitudes added, with a sign decided by the caller
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig (bn-mag bx) (bn-halves bx)))
         (ny (mag-sig (bn-mag by) (bn-halves by)))
         (r (bn-alloc-halves (%+ (if (%> nx ny) nx ny) 1) sign)))
    (bn-finish r (mag-add! (bn-mag r) (bn-mag bx) nx (bn-mag by) ny))))

(define (bn-sub-mag x y sign)
  ;; magnitudes subtracted, larger minus smaller, sign as given; the caller
  ;; has compared them already
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig (bn-mag bx) (bn-halves bx)))
         (ny (mag-sig (bn-mag by) (bn-halves by)))
         (r (bn-alloc-halves nx sign)))
    (bn-finish r (mag-sub! (bn-mag r) (bn-mag bx) nx (bn-mag by) ny))))

(define (num-sign x)
  (cond ((%bignum? x) (bn-sign x))
        ((%< x 0) 1)
        (else 0)))

(define (num-mag-cmp x y)
  (let ((bx (bn-of x)) (by (bn-of y)))
    (mag-cmp (bn-mag bx) (mag-sig (bn-mag bx) (bn-halves bx))
             (bn-mag by) (mag-sig (bn-mag by) (bn-halves by)))))

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
         (let* ((n (mag-sig (bn-mag x) (bn-halves x)))
                (r (bn-alloc-halves n (if (%= (bn-sign x) 1) 0 1)))
                (p (bn-mag x)) (q (bn-mag r)) (i 0))
           (while (%< i n)
             (mag-set! q i (mag-half p i))
             (set! i (%+ i 1)))
           (bn-finish r n)))
        ;; The one fixnum whose negation is not a fixnum. It cannot be written
        ;; as a literal here either - the reader would have the same problem -
        ;; so +2^30 is built out of its halves.
        ((%= x bn-most-negative)
         (let ((b (bn-alloc 1 0)))
           (mag-set! (bn-mag b) 0 0)
           (mag-set! (bn-mag b) 1 bn-fix-hi)
           b))
        (else (%- 0 x))))

(define (generic-sub x y) (generic-add x (generic-neg y)))

(define (generic-mul x y)
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig (bn-mag bx) (bn-halves bx)))
         (ny (mag-sig (bn-mag by) (bn-halves by))))
    (if (if (%= nx 0) t (%= ny 0))
        0
        (let ((r (bn-alloc-halves (%+ nx ny)
                                  (if (%= (bn-sign bx) (bn-sign by)) 0 1))))
          (bn-finish r (mag-mul! (bn-mag r) (bn-mag bx) nx (bn-mag by) ny))))))

;; -1, 0 or 1, for values of either kind.
(define (generic-cmp x y)
  (let ((sx (num-sign x)) (sy (num-sign y)))
    (cond ((if (%= sx 0) (%= sy 1) nil) 1)
          ((if (%= sx 1) (%= sy 0) nil) -1)
          (else
           (let ((c (num-mag-cmp x y)))
             (if (%= sx 1) (%- 0 c) c))))))

(define (generic-zero? x) (if (%bignum? x) nil (%= x 0)))

;; Quotient truncated toward zero, and a remainder with the dividend's sign -
;; the same rule the fixnum instructions follow.
(define (generic-divmod x y want-rem)
  (let* ((bx (bn-of x)) (by (bn-of y))
         (nx (mag-sig (bn-mag bx) (bn-halves bx)))
         (ny (mag-sig (bn-mag by) (bn-halves by))))
    (if (%= ny 0)
        (error "division by zero")
        (if (%< (mag-cmp (bn-mag bx) nx (bn-mag by) ny) 0)
            ;; the divisor is larger, so the quotient is zero and the
            ;; remainder is the dividend
            (if want-rem x 0)
            (let ((q (bn-alloc-halves nx (if (%= (bn-sign bx) (bn-sign by)) 0 1)))
                  (r (bn-alloc-halves (%+ ny 1) (bn-sign bx))))
              (mag-divmod! (bn-mag q) (bn-mag r) (bn-mag bx) nx (bn-mag by) ny)
              (if want-rem
                  (bn-finish r (mag-sig (bn-mag r) (%+ ny 1)))
                  (bn-finish q (mag-sig (bn-mag q) nx))))))))

(define (generic-quotient x y) (generic-divmod x y nil))
(define (generic-remainder x y) (generic-divmod x y t))

;; ---------------------------------------------------------------- printing
;; Four decimal digits at a time, because ten thousand is the largest round
;; number under the small-divisor limit.
(define bn-decimal-chunk 10000)

(define (bignum->string b)
  (let* ((n (mag-sig (bn-mag b) (bn-halves b)))
         ;; a scratch copy, because dividing is destructive
         (w (bn-alloc-halves (if (%> n 0) n 1) 0))
         (p (bn-mag w))
         (i 0)
         (groups nil))
    (while (%< i n)
      (mag-set! p i (mag-half (bn-mag b) i))
      (set! i (%+ i 1)))
    (let ((sig n))
      (while (%> sig 0)
        (set! groups (%cons (mag-div-small! p sig bn-decimal-chunk) groups))
        (set! sig (mag-sig p sig))))
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
  (%= 0 (%logand (mag-half (bn-mag b) 0) 1)))

;; ---------------------------------------------------------------- shifting
;; Two to the k, as a value. One bit set in one half, and `bn-finish` demotes
;; it if it turns out to be small.
(define (bn-two-to k)
  (let* ((nh (%+ (%/ k bn-hbits) 1))
         (b (bn-alloc-halves nh 0)))
    (mag-set! (bn-mag b) (%/ k bn-hbits) (%lsh 1 (%mod k bn-hbits)))
    (bn-finish b (mag-sig (bn-mag b) nh))))

;; `ash` shifts arithmetically, which means the answer is floored rather than
;; truncated: -1 shifted right by anything is still -1. `generic-quotient`
;; truncates, so a negative value with something shifted off the end is one
;; too high and gets corrected.
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

;; ---------------------------------------------------------------- words
;; The low thirty-two bits of a bignum, written at `a` as two halves. This is
;; what `poke` needs for a value too big for a fixnum, and it cannot be
;; spelled with a mask: masking is a bitwise operation and bignums have none
;; yet. It stores rather than answering so that nothing is allocated - `poke`
;; is called from inside the collector.
(define (bignum-poke-word a b)
  (let ((n (mag-sig (bn-mag b) (bn-halves b))))
    (if (%> n 2)
        (error "poke: wider than a word:" b)
        (let ((h0 (mag-half (bn-mag b) 0))
              (h1 (if (%> n 1) (mag-half (bn-mag b) 1) 0)))
          (if (%= (bn-sign b) 1)
              ;; negate in two's complement, sixteen bits at a time
              (begin
                (%st-half! a (%logand (%- 0 h0) bn-hmask))
                (%st-half! (%+ a 2)
                           (%logand (%- (%- 0 h1) (if (%= h0 0) 0 1)) bn-hmask)))
              (begin
                (%st-half! a h0)
                (%st-half! (%+ a 2) h1)))))
    b))

;; ---------------------------------------------------------------- halves in
;; A machine word, given as its two halves, as a number of the right kind.
;;
;; These build the bignum rather than reaching it through `+` and `*`, and
;; that is not an optimisation. Widening is a *trap*, and a trap cannot nest:
;; the stub saves the whole register file into the one context block that
;; `mscratch` names, so a second trap taken inside the handler would overwrite
;; the first one's registers. `peek` is called from interrupt servers - the
;; scheduler reads the timer from inside the trap handler every quantum - so
;; nothing on that path may widen by trapping.
(define (halves->unsigned lo hi)
  (if (%< hi bn-fix-hi)
      ;; the whole word fits a fixnum
      (%+ lo (%* hi 65536))
      (let ((b (bn-alloc 1 0)))
        (mag-set! (bn-mag b) 0 lo)
        (mag-set! (bn-mag b) 1 hi)
        (bn-finish b 2))))

(define (halves->signed lo hi)
  (cond
   ((%< hi bn-fix-hi) (%+ lo (%* hi 65536)))
   ((%< hi 32768) (halves->unsigned lo hi))
   ;; negative: the magnitude is 2^32 minus the word, taken half by half
   (else
    (let ((b (bn-alloc 1 1)))
      (if (%= lo 0)
          (begin (mag-set! (bn-mag b) 0 0)
                 (mag-set! (bn-mag b) 1 (%- 65536 hi)))
          (begin (mag-set! (bn-mag b) 0 (%- 65536 lo))
                 (mag-set! (bn-mag b) 1 (%- 65535 hi))))
      (bn-finish b 2)))))
