;;; font.lisp - the system font. GENERATED, do not edit by hand.
;;;
;;; The 12ppem monochrome bitmap strike of Virtue, a recreation of Apple's
;;; Charcoal by Marty P. Pfeiffer (Scooter Graphics, 1997-1999), which is the
;;; face Mac OS 8 and 9 set the interface in. Virtue is freeware; credit it
;;; wherever credits are shown.
;;;
;;; Every glyph sits in a 15-row box with an ascent of 12 and capitals 9 tall.
;;; A row is sixteen bits with the leftmost pixel in bit fifteen, so a glyph
;;; is 15 small numbers; `adv` is how far the pen moves and `left` the bearing
;;; the strike was drawn with. Codes 32..126 are the printable ASCII range and
;;; 128..131 are the command symbol, the menu check, the submenu triangle and
;;; the diamond, which Virtue does not carry.
;;;
;;; Regenerate rather than edit: the atlases live in ~/platinum/assets/fonts.

(in-package wb)

(define font-first 32)
(define font-last 131)
(define font-height 15)
(define font-ascent 12)
(define font-cap 9)
(define font-cell 15)

;; Advance, left bearing and ink width, one entry per code.
(define *font-adv* '(
    4 5 7 10 8 13 10 4 6 6 8 8 4 7 4 7 8 8 8 8 8 8 8 8 8 8 4 4 6 7 6 7 12 8
    9 8 9 8 6 9 9 4 5 9 6 12 9 10 8 10 8 7 6 9 8 12 8 8 8 5 6 5 8 6 6 8 8 7
    8 8 5 8 8 4 4 7 4 12 8 8 8 8 6 7 5 8 7 11 7 7 7 6 5 6 9 0 11 9 6 9
))
(define *font-left* '(
    0 2 1 0 1 1 1 1 1 1 1 1 1 1 1 1 1 2 1 1 0 1 1 1 1 1 1 1 1 1 1 1 1 0 1 1
    1 1 1 1 1 1 0 1 1 1 1 1 1 1 1 1 0 1 0 0 0 0 1 1 0 1 1 0 2 1 1 1 1 1 0 1
    1 1 0 1 1 1 1 1 1 1 1 1 0 1 0 0 0 0 1 1 2 1 1 0 1 1 1 1
))
(define *font-ink* '(
    1 2 5 9 6 11 8 2 4 4 6 6 2 5 2 5 6 3 6 6 7 6 6 6 6 6 2 2 4 5 4 5 10 8 7
    6 7 6 5 7 7 2 4 7 5 10 7 8 6 8 6 5 6 7 8 12 8 8 6 3 5 3 6 6 3 6 6 5 6 6
    5 6 6 2 3 6 2 10 6 6 6 6 5 5 5 6 7 11 7 7 5 4 2 4 7 0 9 7 4 7
))

;; 15 rows a glyph, glyph after glyph.
(define *font-rows* '(
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 49152 49152 49152 49152 49152 49152
    0 49152 49152 0 0 0 0 0 0 55296 55296 55296 0 0 0 0 0 0 0 0 0 0 0 0
    2560 2560 32640 32640 5120 65280 65280 10240 10240 0 0 0 0 0 4096 31744
    53248 53248 61440 30720 15360 11264 11264 63488 8192 0 0 0 0 0 28928
    55552 55808 29696 1024 2496 2912 4960 4544 0 0 0 0 0 0 14336 27648
    27648 14336 29440 56064 52736 52736 31488 0 0 0 0 0 0 49152 49152 49152
    0 0 0 0 0 0 0 0 0 0 0 0 12288 24576 24576 49152 49152 49152 49152 49152
    24576 24576 12288 0 0 0 0 49152 24576 24576 12288 12288 12288 12288
    12288 24576 24576 49152 0 0 0 0 0 18432 12288 64512 12288 18432 0 0 0 0
    0 0 0 0 0 0 0 12288 12288 64512 64512 12288 12288 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 49152 49152 16384 32768 0 0 0 0 0 0 0 0 63488 63488 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 49152 49152 0 0 0 0 0 0 2048 6144 4096 12288 8192
    24576 16384 49152 32768 0 0 0 0 0 0 30720 52224 52224 52224 52224 52224
    52224 52224 30720 0 0 0 0 0 0 24576 57344 24576 24576 24576 24576 24576
    24576 24576 0 0 0 0 0 0 30720 52224 3072 3072 6144 12288 24576 49152
    64512 0 0 0 0 0 0 30720 52224 3072 3072 14336 3072 3072 52224 30720 0 0
    0 0 0 0 3072 7168 11264 19456 35840 65024 3072 3072 3072 0 0 0 0 0 0
    64512 49152 49152 63488 3072 3072 3072 52224 30720 0 0 0 0 0 0 14336
    24576 49152 63488 52224 52224 52224 52224 30720 0 0 0 0 0 0 64512 3072
    6144 4096 12288 12288 24576 24576 24576 0 0 0 0 0 0 30720 52224 52224
    52224 30720 52224 52224 52224 30720 0 0 0 0 0 0 30720 52224 52224 52224
    52224 31744 3072 6144 28672 0 0 0 0 0 0 0 0 49152 49152 0 0 0 49152
    49152 0 0 0 0 0 0 0 0 49152 49152 0 0 0 49152 49152 16384 32768 0 0 0 0
    0 0 0 12288 24576 49152 49152 24576 12288 0 0 0 0 0 0 0 0 0 63488 63488
    0 63488 63488 0 0 0 0 0 0 0 0 0 0 49152 24576 12288 12288 24576 49152 0
    0 0 0 0 0 61440 6144 6144 12288 24576 24576 0 24576 24576 0 0 0 0 0 0
    16128 16512 32832 39488 46656 46656 46784 39808 32768 16384 15872 0 0 0
    0 6144 6144 15360 15360 9728 26112 32256 49920 49920 0 0 0 0 0 0 63488
    52224 52224 63488 52224 50688 50688 52224 63488 0 0 0 0 0 0 15360 25600
    49152 49152 49152 49152 49152 24576 15360 0 0 0 0 0 0 63488 52224 50688
    50688 50688 50688 50688 52224 63488 0 0 0 0 0 0 64512 49152 49152 49152
    63488 49152 49152 49152 64512 0 0 0 0 0 0 63488 49152 49152 49152 61440
    49152 49152 49152 49152 0 0 0 0 0 0 15360 25600 49152 49152 52736 50688
    50688 26112 15360 0 0 0 0 0 0 50688 50688 50688 50688 65024 50688 50688
    50688 50688 0 0 0 0 0 0 49152 49152 49152 49152 49152 49152 49152 49152
    49152 0 0 0 0 0 0 12288 12288 12288 12288 12288 12288 12288 12288 57344
    0 0 0 0 0 0 50688 52224 55296 61440 61440 63488 56320 52736 50688 0 0 0
    0 0 0 49152 49152 49152 49152 49152 49152 49152 49152 63488 0 0 0 0 0 0
    49344 49344 57792 57792 45760 45760 40128 40128 35008 0 0 0 0 0 0 33280
    49664 57856 61952 47616 40448 36352 34304 33280 0 0 0 0 0 0 15360 26112
    49920 49920 49920 49920 49920 26112 15360 0 0 0 0 0 0 63488 52224 52224
    52224 63488 49152 49152 49152 49152 0 0 0 0 0 0 15360 26112 49920 49920
    49920 49920 49920 26112 15360 6144 3072 0 0 0 0 63488 52224 52224 52224
    63488 56320 52224 52224 52224 0 0 0 0 0 0 30720 49152 49152 57344 28672
    14336 6144 6144 61440 0 0 0 0 0 0 64512 12288 12288 12288 12288 12288
    12288 12288 12288 0 0 0 0 0 0 49664 49664 49664 49664 49664 49664 49664
    25600 14336 0 0 0 0 0 0 49920 49664 26112 26112 25600 15360 15360 6144
    6144 0 0 0 0 0 0 50736 50720 50720 28512 27456 31680 12672 12672 12672
    0 0 0 0 0 0 58112 26112 13312 14336 6144 15360 11264 26112 50944 0 0 0
    0 0 0 58112 25088 26112 13312 15360 6144 6144 6144 6144 0 0 0 0 0 0
    64512 3072 6144 6144 12288 24576 24576 49152 64512 0 0 0 0 0 0 57344
    49152 49152 49152 49152 49152 49152 49152 49152 49152 57344 0 0 0 0
    32768 49152 16384 24576 8192 12288 4096 6144 2048 0 0 0 0 0 0 57344
    24576 24576 24576 24576 24576 24576 24576 24576 24576 57344 0 0 0 0
    12288 30720 30720 52224 52224 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    64512 0 0 0 0 49152 24576 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 30720 3072
    31744 52224 52224 56320 27648 0 0 0 0 0 0 49152 49152 55296 60416 52224
    52224 52224 52224 63488 0 0 0 0 0 0 0 0 30720 51200 49152 49152 49152
    49152 30720 0 0 0 0 0 0 3072 3072 31744 52224 52224 52224 52224 52224
    29696 0 0 0 0 0 0 0 0 30720 52224 52224 64512 49152 49152 31744 0 0 0 0
    0 0 14336 24576 61440 24576 24576 24576 24576 24576 24576 0 0 0 0 0 0 0
    0 29696 52224 52224 52224 52224 56320 27648 3072 30720 0 0 0 0 49152
    49152 55296 60416 52224 52224 52224 52224 52224 0 0 0 0 0 0 49152 0
    49152 49152 49152 49152 49152 49152 49152 0 0 0 0 0 0 24576 0 24576
    24576 24576 24576 24576 24576 24576 24576 49152 0 0 0 0 49152 49152
    52224 55296 61440 57344 61440 55296 52224 0 0 0 0 0 0 49152 49152 49152
    49152 49152 49152 49152 49152 49152 0 0 0 0 0 0 0 0 55680 61120 52416
    52416 52416 52416 52416 0 0 0 0 0 0 0 0 55296 60416 52224 52224 52224
    52224 52224 0 0 0 0 0 0 0 0 30720 52224 52224 52224 52224 52224 30720 0
    0 0 0 0 0 0 0 55296 60416 52224 52224 52224 52224 63488 49152 49152 0 0
    0 0 0 0 29696 52224 52224 52224 52224 52224 31744 3072 3072 0 0 0 0 0 0
    55296 63488 49152 49152 49152 49152 49152 0 0 0 0 0 0 0 0 30720 49152
    57344 28672 14336 6144 61440 0 0 0 0 0 0 8192 24576 63488 24576 24576
    24576 24576 24576 14336 0 0 0 0 0 0 0 0 52224 52224 52224 52224 52224
    56320 27648 0 0 0 0 0 0 0 0 50688 50688 25600 27648 14336 14336 4096 0
    0 0 0 0 0 0 0 52320 52320 28224 28352 15232 15232 4352 0 0 0 0 0 0 0 0
    58880 27648 14336 14336 14336 27648 52736 0 0 0 0 0 0 0 0 50688 50688
    25600 27648 14336 14336 4096 12288 24576 0 0 0 0 0 0 63488 6144 12288
    28672 24576 49152 63488 0 0 0 0 0 0 12288 24576 24576 24576 49152 24576
    24576 24576 24576 24576 12288 0 0 0 0 49152 49152 49152 49152 49152
    49152 49152 49152 49152 49152 49152 0 0 0 0 49152 24576 24576 24576
    12288 24576 24576 24576 24576 24576 49152 0 0 0 0 0 0 0 25088 65024
    35840 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 49920 42240
    48384 9216 9216 48384 42240 49920 0 0 0 0 0 0 0 1536 3072 3072 38912
    55296 28672 28672 8192 0 0 0 0 0 0 0 32768 49152 57344 61440 57344
    49152 32768 0 0 0 0 0 0 0 0 4096 14336 31744 65024 31744 14336 4096 0 0
    0 0
))

;; Unpacked at startup: the rows into a vector, because sixteen bits do not
;; fit in a byte, and the three metrics into byte vectors beside it.
(define *font* nil)
(define *font-advs* nil)
(define *font-lefts* nil)
(define *font-inks* nil)

(define (font-init)
  (let* ((n (length *font-rows*))
         (v (make-vector n 0))
         (i 0))
    (dolist (r *font-rows*)
      (vector-set! v i r)
      (set! i (%+ i 1)))
    (set! *font* v))
  (set! *font-advs* (font-bytes *font-adv*))
  (set! *font-lefts* (font-bytes *font-left*))
  (set! *font-inks* (font-bytes *font-ink*))
  ;; The readable forms have done their job; let the collector have them back.
  (set! *font-rows* nil)
  (set! *font-adv* nil)
  (set! *font-left* nil)
  (set! *font-ink* nil)
  *font*)

(define (font-bytes l)
  (let ((b (make-bytes (length l))) (i 0))
    (dolist (x l)
      (bytes-set! b i x)
      (set! i (%+ i 1)))
    b))

(define (font-index ch)
  (let ((c (%char->int ch)))
    (if (%< c font-first)
        -1
        (if (%> c font-last) -1 (%- c font-first)))))

(define (font-adv-of i) (if *font-advs* (bytes-ref *font-advs* i) 0))
(define (font-left-of i) (if *font-lefts* (bytes-ref *font-lefts* i) 0))
(define (font-ink-of i) (if *font-inks* (bytes-ref *font-inks* i) 0))
(define (font-bits i row) (%vector-ref *font* (%+ (%* i font-height) row)))

(define (char-width ch)
  (let ((i (font-index ch))) (if (%< i 0) 0 (font-adv-of i))))

(define (text-width s)
  (let ((i 0) (n (string-length s)) (w 0))
    (while (%< i n)
      (set! w (%+ w (char-width (string-ref s i))))
      (set! i (%+ i 1)))
    w))

;; A glyph, straight into the bitmap: going through the blitter for each run
;; costs more in setup than the pixels are worth. `bg` below zero leaves what
;; is there, which is what drawing over pinstripes needs.
;;
;; It clips to the rastport's region as well as to the bitmap. That used to be
;; only the bitmap, which was harmless as long as every caller happened to be
;; drawing inside its own window - and stopped being harmless the moment the
;; compositor started drawing the desktop through a rastport clipped to the
;; damage, where the menu bar's text was written whether or not the damage
;; reached it.
(define (glyph-rows i ox py ink fg bm bw bh x0 y0 x1 y1)
  (let ((row 0))
    (while (%< row font-height)
      (let ((gy (%+ py row)))
        (if (if (%>= gy y0) (%< gy y1) nil)
            (let ((bits (font-bits i row)) (col 0))
              (while (%< col ink)
                (let ((gx (%+ ox col)))
                  (if (if (%>= gx x0) (%< gx x1) nil)
                      (if (%= 1 (%logand (%lsh bits (%- col 15)) 1))
                          (bm-plot bm bw bh gx gy fg)
                          nil)
                      nil))
                (set! col (%+ col 1))))
            nil))
      (set! row (%+ row 1)))
    nil))

;; `bg` is a colour to fill the cell with first, or nil to leave what is
;; there - which is what drawing over pinstripes needs.
(define (draw-char rp x y ch fg bg)
  (check-colour fg)
  (let ((i (font-index ch)))
    (if (%< i 0)
        0
        (let ((bm (rp-bitmap rp))
              (bw (rp-bitmap-w rp))
              (bh (rp-bitmap-h rp))
              (px (%+ x (rp-origin-x rp)))
              (py (%+ y (rp-origin-y rp))))
          (if bg (fill-rect rp x y (font-adv-of i) font-height bg) nil)
          (let ((ink (font-ink-of i))
                (ox (%+ px (font-left-of i))))
            (dolist (cr (rp-region rp))
              (glyph-rows i ox py ink fg bm bw bh
                          (rect-x cr) (rect-y cr) (rect-x2 cr) (rect-y2 cr))))
          (font-adv-of i)))))

(define (draw-text rp x y s fg bg)
  (let ((i 0) (n (string-length s)) (px x))
    (while (%< i n)
      (set! px (%+ px (draw-char rp px y (string-ref s i) fg bg)))
      (set! i (%+ i 1)))
    px))

;; As much of `s` as fits in `w`, which is what a title bar wants.
(define (text-truncate s w)
  (let ((i 0) (n (string-length s)) (acc 0) (cut 0))
    (while (%< i n)
      (set! acc (%+ acc (char-width (string-ref s i))))
      (if (%<= acc w) (set! cut (%+ i 1)) (set! i n))
      (set! i (%+ i 1)))
    (if (%= cut n) s (substring s 0 cut))))
