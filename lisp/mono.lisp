;;; mono.lisp - the terminal face.
;;;
;;; MS Gothic at twelve pixels, the halfwidth half of the Windows 3.1J
;;; strike (RGMJA12): six columns wide and twelve rows tall, so the advance
;;; is six pixels and a line is twelve. Each row is six bits with the
;;; leftmost column in bit five, so a glyph is twelve small numbers and the
;;; whole font is legible in the source. The strike stores ink as a clear
;;; bit; here a set bit is ink.
;;;
;;; The interface is set in Charcoal, which is proportional; a shell is a
;;; grid of cells and wants a face where every character is the same width.
;;;
;;; The list is unpacked into a byte vector at startup and then dropped.

(in-package wb)

(define mono-first 32)
(define mono-cell 12)     ; the cell is twelve rows tall
(define mono-advance 6)   ; and six pixels wide
(define mono-height 12)
(define mono-columns 6)

(define *mono-rows*
  '(
    ( 0  0  0  0  0  0  0  0  0  0  0  0)  ; space
    ( 4  4  4  4  4  4  0  0  4  4  0  0)  ; !
    (10 10 20  0  0  0  0  0  0  0  0  0)  ; double quote
    (10 10 31 10 10 10 10 10 31 10 10  0)  ; #
    ( 4 14 21 21 12  6  5 21 21 14  4  0)  ; $
    ( 9 21 22 10  4  4 10 13 21 18  0  0)  ; %
    ( 8 20 20  8  8 21 21 18 18 13  0  0)  ; &
    (12  4  8  0  0  0  0  0  0  0  0  0)  ; quote
    ( 2  4  4  8  8  8  8  8  4  4  2  0)  ; open paren
    ( 8  4  4  2  2  2  2  2  4  4  8  0)  ; close paren
    ( 0  0  4 21 21 14 21 21  4  0  0  0)  ; *
    ( 0  0  4  4  4 31  4  4  4  0  0  0)  ; +
    ( 0  0  0  0  0  0  0  0 12  4  8  0)  ; ,
    ( 0  0  0  0  0 30  0  0  0  0  0  0)  ; -
    ( 0  0  0  0  0  0  0  0 12 12  0  0)  ; .
    ( 1  1  2  2  4  4  4  8  8 16 16  0)  ; /
    ( 0 12 18 18 18 18 18 18 18 12  0  0)  ; 0
    ( 0  4 12  4  4  4  4  4  4  4  0  0)  ; 1
    ( 0 12 18 18  2  4  8  8 16 30  0  0)  ; 2
    ( 0 12 18 18  2 12  2 18 18 12  0  0)  ; 3
    ( 0  2  6  6 10 10 18 31  2  2  0  0)  ; 4
    ( 0 30 16 16 28 18  2 18 18 12  0  0)  ; 5
    ( 0 12 18 18 16 28 18 18 18 12  0  0)  ; 6
    ( 0 30  2  2  4  4  4  8  8  8  0  0)  ; 7
    ( 0 12 18 18 18 12 18 18 18 12  0  0)  ; 8
    ( 0 12 18 18 18 14  2 18 18 12  0  0)  ; 9
    ( 0  0  0 12 12  0  0  0 12 12  0  0)  ; :
    ( 0  0  0 12 12  0  0  0 12  4  8  0)  ; semicolon
    ( 0  1  2  4  8 16  8  4  2  1  0  0)  ; <
    ( 0  0  0 30  0  0 30  0  0  0  0  0)  ; =
    ( 0 16  8  4  2  1  2  4  8 16  0  0)  ; >
    ( 0 12 18 18  2  4  4  0  4  4  0  0)  ; ?
    ( 0 14 17 29 21 21 29 18 17 14  0  0)  ; @
    ( 0  4  4 10 10 10 17 31 17 17  0  0)  ; A
    ( 0 30 17 17 17 30 17 17 17 30  0  0)  ; B
    ( 0 14 17 17 16 16 16 17 17 14  0  0)  ; C
    ( 0 28 18 17 17 17 17 17 18 28  0  0)  ; D
    ( 0 31 16 16 16 30 16 16 16 31  0  0)  ; E
    ( 0 31 16 16 16 30 16 16 16 16  0  0)  ; F
    ( 0 14 17 17 16 16 19 17 19 13  0  0)  ; G
    ( 0 17 17 17 17 31 17 17 17 17  0  0)  ; H
    ( 0 14  4  4  4  4  4  4  4 14  0  0)  ; I
    ( 0  2  2  2  2  2  2 18 18 12  0  0)  ; J
    ( 0 18 18 20 20 24 20 20 18 18  0  0)  ; K
    ( 0 16 16 16 16 16 16 16 16 31  0  0)  ; L
    ( 0 17 17 27 27 27 21 21 21 21  0  0)  ; M
    ( 0 17 25 25 21 21 21 19 19 17  0  0)  ; N
    ( 0 14 17 17 17 17 17 17 17 14  0  0)  ; O
    ( 0 30 17 17 17 30 16 16 16 16  0  0)  ; P
    ( 0 14 17 17 17 17 17 21 18 13  0  0)  ; Q
    ( 0 30 17 17 17 30 18 17 17 17  0  0)  ; R
    ( 0 14 17 17  8  4  2 17 17 14  0  0)  ; S
    ( 0 31  4  4  4  4  4  4  4  4  0  0)  ; T
    ( 0 17 17 17 17 17 17 17 17 14  0  0)  ; U
    ( 0 17 17 17 10 10 10  4  4  4  0  0)  ; V
    ( 0 21 21 21 21 21 10 10 10 10  0  0)  ; W
    ( 0 17 17 10 10  4 10 10 17 17  0  0)  ; X
    ( 0 17 17 10 10  4  4  4  4  4  0  0)  ; Y
    ( 0 31  1  2  2  4  8  8 16 31  0  0)  ; Z
    ( 7  4  4  4  4  4  4  4  4  4  7  0)  ; [
    ( 0 17 17 10 10 31  4 31  4  4  0  0)  ; backslash
    (28  4  4  4  4  4  4  4  4  4 28  0)  ; ]
    ( 4 10  0  0  0  0  0  0  0  0  0  0)  ; ^
    ( 0  0  0  0  0  0  0  0  0  0  0 63)  ; underscore
    ( 8  4  0  0  0  0  0  0  0  0  0  0)  ; `
    ( 0  0  0  0 12 18 14 18 18 13  0  0)  ; a
    ( 0 16 16 16 30 17 17 17 17 30  0  0)  ; b
    ( 0  0  0  0 14 17 16 16 17 14  0  0)  ; c
    ( 0  1  1  1 15 17 17 17 17 15  0  0)  ; d
    ( 0  0  0  0 14 17 31 16 17 14  0  0)  ; e
    ( 0  6  8  8 28  8  8  8  8  8  0  0)  ; f
    ( 0  0  0  0 13 18 12 16 14 17 14  0)  ; g
    ( 0 16 16 16 30 17 17 17 17 17  0  0)  ; h
    ( 0  4  4  0  4  4  4  4  4  4  0  0)  ; i
    ( 0  4  4  0  4  4  4  4  4  4 24  0)  ; j
    ( 0 16 16 16 17 18 20 28 18 17  0  0)  ; k
    ( 0  4  4  4  4  4  4  4  4  4  0  0)  ; l
    ( 0  0  0  0 26 21 21 21 21 21  0  0)  ; m
    ( 0  0  0  0 30 17 17 17 17 17  0  0)  ; n
    ( 0  0  0  0 14 17 17 17 17 14  0  0)  ; o
    ( 0  0  0  0 30 17 17 17 30 16 16  0)  ; p
    ( 0  0  0  0 15 17 17 17 15  1  1  0)  ; q
    ( 0  0  0  0 11 12  8  8  8  8  0  0)  ; r
    ( 0  0  0  0 14 17 12  2 17 14  0  0)  ; s
    ( 0  8  8  8 28  8  8  8  8  6  0  0)  ; t
    ( 0  0  0  0 17 17 17 17 17 15  0  0)  ; u
    ( 0  0  0  0 17 17 10 10  4  4  0  0)  ; v
    ( 0  0  0  0 21 21 21 10 10 10  0  0)  ; w
    ( 0  0  0  0 17 10  4  4 10 17  0  0)  ; x
    ( 0  0  0  0 17 17 10 10  4  4 24  0)  ; y
    ( 0  0  0  0 31  1  2  4  8 31  0  0)  ; z
    ( 6  4  4  4  4  8  4  4  4  4  6  0)  ; {
    ( 4  4  4  4  4  4  4  4  4  4  4  4)  ; bar
    (12  4  4  4  4  2  4  4  4  4 12  0)  ; }
    (13 18  0  0  0  0  0  0  0  0  0  0)  ; ~
    ))

(define *mono* nil)

(define (mono-init)
  (let* ((n (length *mono-rows*))
         (b (make-bytes (%* n mono-cell)))
         (i 0))
    (dolist (g *mono-rows*)
      (let ((j 0))
        (dolist (r g)
          (bytes-set! b (%+ (%* i mono-cell) j) r)
          (set! j (%+ j 1))))
      (set! i (%+ i 1)))
    (set! *mono* b)
    (set! *mono-rows* nil)
    b))

;; The six bits of one row of one glyph, or nothing for a character the
;; face does not have.
(define (mono-row ch row)
  (let ((i (%- (%char->int ch) mono-first)))
    (if (%null? *mono*)
        0
        (if (%< i 0)
            0
            (let ((k (%+ (%* i mono-cell) row)))
              (if (%< k (bytes-length *mono*)) (bytes-ref *mono* k) 0))))))

;; Straight into the bitmap, clipped to the rastport's region and to the
;; bitmap. One wait for the blitter per glyph, after the background fill has
;; been issued, and then plain stores. `bg` is a colour, or nil to leave what
;; is already there.
(define (draw-mono-char rp x y ch fg bg)
  (check-colour fg)
  (let ((bmp (rp-bitmap rp))
        (px (%+ x (rp-origin-x rp)))
        (py (%+ y (rp-origin-y rp))))
    (if bg (fill-rect rp x y mono-advance mono-height bg) nil)
    (blit-sync)
    (dolist (cr (rp-region rp))
      (mono-rows ch px py fg bmp
                 (max2 (rect-x cr) 0) (max2 (rect-y cr) 0)
                 (min2 (rect-x2 cr) (bm-w bmp)) (min2 (rect-y2 cr) (bm-h bmp))))
    nil))

(define (mono-rows ch px py fg bmp x0 y0 x1 y1)
  (let ((row 0))
    (while (%< row mono-cell)
      (let ((gy (%+ py row)))
        (if (if (%>= gy y0) (%< gy y1) nil)
            (let ((bits (mono-row ch row)) (col 0) (addr (bm-at bmp px gy)))
              (while (%< col mono-columns)
                (let ((gx (%+ px col)))
                  (if (if (%>= gx x0) (%< gx x1) nil)
                      (if (%= 1 (%logand (%lsh bits (%- col 5)) 1))
                          (%st-byte! (%+ addr col) fg)
                          nil)
                      nil))
                (set! col (%+ col 1))))
            nil))
      (set! row (%+ row 1)))
    nil))
