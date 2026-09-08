;;; font.lisp - the system font.
;;;
;;; Five columns wide and seven tall in an eight by eight cell, which leaves a
;;; column and a row of gap and makes the advance six pixels. Each row is five
;;; bits with the leftmost column in bit four, so a glyph is eight small
;;; numbers and the whole font is legible in the source.
;;;
;;; The list is unpacked into a byte vector at startup and then dropped: it is
;;; there to be read, not to be indexed.

(in-package wb)

(define font-first 32)
(define font-cell 8)      ; the cell is eight rows tall
(define font-advance 6)   ; and six pixels wide including the gap
(define font-height 8)

(define *font-rows*
  '(( 0  0  0  0  0  0  0  0)  ; space
    ( 4  4  4  4  4  0  4  0)  ; !
    (10 10 10  0  0  0  0  0)  ; "
    (10 10 31 10 31 10 10  0)  ; #
    ( 4 15 20 14  5 30  4  0)  ; $
    (24 25  2  4  8 19  3  0)  ; %
    (12 18 20  8 21 18 13  0)  ; &
    ( 4  4  8  0  0  0  0  0)  ; quote
    ( 2  4  8  8  8  4  2  0)  ; (
    ( 8  4  2  2  2  4  8  0)  ; )
    ( 0  4 21 14 21  4  0  0)  ; *
    ( 0  4  4 31  4  4  0  0)  ; +
    ( 0  0  0  0  0  4  4  8)  ; ,
    ( 0  0  0 31  0  0  0  0)  ; -
    ( 0  0  0  0  0 12 12  0)  ; .
    ( 0  1  2  4  8 16  0  0)  ; /
    (14 17 19 21 25 17 14  0)  ; 0
    ( 4 12  4  4  4  4 14  0)  ; 1
    (14 17  1  2  4  8 31  0)  ; 2
    (31  2  4  2  1 17 14  0)  ; 3
    ( 2  6 10 18 31  2  2  0)  ; 4
    (31 16 30  1  1 17 14  0)  ; 5
    ( 6  8 16 30 17 17 14  0)  ; 6
    (31  1  2  4  8  8  8  0)  ; 7
    (14 17 17 14 17 17 14  0)  ; 8
    (14 17 17 15  1  2 12  0)  ; 9
    ( 0 12 12  0 12 12  0  0)  ; :
    ( 0 12 12  0 12  4  8  0)  ; ;
    ( 2  4  8 16  8  4  2  0)  ; <
    ( 0  0 31  0 31  0  0  0)  ; =
    ( 8  4  2  1  2  4  8  0)  ; >
    (14 17  1  2  4  0  4  0)  ; ?
    (14 17  1 13 21 21 14  0)  ; @
    (14 17 17 31 17 17 17  0)  ; A
    (30 17 17 30 17 17 30  0)  ; B
    (14 17 16 16 16 17 14  0)  ; C
    (28 18 17 17 17 18 28  0)  ; D
    (31 16 16 30 16 16 31  0)  ; E
    (31 16 16 30 16 16 16  0)  ; F
    (14 17 16 23 17 17 15  0)  ; G
    (17 17 17 31 17 17 17  0)  ; H
    (14  4  4  4  4  4 14  0)  ; I
    ( 7  2  2  2  2 18 12  0)  ; J
    (17 18 20 24 20 18 17  0)  ; K
    (16 16 16 16 16 16 31  0)  ; L
    (17 27 21 21 17 17 17  0)  ; M
    (17 17 25 21 19 17 17  0)  ; N
    (14 17 17 17 17 17 14  0)  ; O
    (30 17 17 30 16 16 16  0)  ; P
    (14 17 17 17 21 18 13  0)  ; Q
    (30 17 17 30 20 18 17  0)  ; R
    (15 16 16 14  1  1 30  0)  ; S
    (31  4  4  4  4  4  4  0)  ; T
    (17 17 17 17 17 17 14  0)  ; U
    (17 17 17 17 17 10  4  0)  ; V
    (17 17 17 21 21 21 10  0)  ; W
    (17 17 10  4 10 17 17  0)  ; X
    (17 17 10  4  4  4  4  0)  ; Y
    (31  1  2  4  8 16 31  0)  ; Z
    (14  8  8  8  8  8 14  0)  ; [
    ( 0 16  8  4  2  1  0  0)  ; backslash
    (14  2  2  2  2  2 14  0)  ; ]
    ( 4 10 17  0  0  0  0  0)  ; ^
    ( 0  0  0  0  0  0  0 31)  ; _
    ( 8  4  2  0  0  0  0  0)  ; `
    ( 0  0 14  1 15 17 15  0)  ; a
    (16 16 30 17 17 17 30  0)  ; b
    ( 0  0 14 17 16 17 14  0)  ; c
    ( 1  1 15 17 17 17 15  0)  ; d
    ( 0  0 14 17 31 16 14  0)  ; e
    ( 6  9  8 28  8  8  8  0)  ; f
    ( 0  0 15 17 17 15  1 14)  ; g
    (16 16 30 17 17 17 17  0)  ; h
    ( 4  0 12  4  4  4 14  0)  ; i
    ( 2  0  6  2  2  2 18 12)  ; j
    (16 16 18 20 24 20 18  0)  ; k
    (12  4  4  4  4  4 14  0)  ; l
    ( 0  0 26 21 21 21 21  0)  ; m
    ( 0  0 30 17 17 17 17  0)  ; n
    ( 0  0 14 17 17 17 14  0)  ; o
    ( 0  0 30 17 17 30 16 16)  ; p
    ( 0  0 15 17 17 15  1  1)  ; q
    ( 0  0 22 25 16 16 16  0)  ; r
    ( 0  0 15 16 14  1 30  0)  ; s
    ( 8  8 28  8  8  9  6  0)  ; t
    ( 0  0 17 17 17 19 13  0)  ; u
    ( 0  0 17 17 17 10  4  0)  ; v
    ( 0  0 17 17 21 21 10  0)  ; w
    ( 0  0 17 10  4 10 17  0)  ; x
    ( 0  0 17 17 17 15  1 14)  ; y
    ( 0  0 31  2  4  8 31  0)  ; z
    ( 6  8  8 16  8  8  6  0)  ; {
    ( 4  4  4  4  4  4  4  0)  ; |
    (12  2  2  1  2  2 12  0)  ; }
    ( 0  0  8 21  2  0  0  0)  ; ~
))

;; Unpacked: eight bytes a glyph, indexed by character code minus font-first.
(define *font* nil)

(define (font-init)
  (let* ((n (length *font-rows*))
         (b (make-bytes (%* n font-cell)))
         (i 0))
    (dolist (g *font-rows*)
      (let ((j 0))
        (dolist (r g)
          (bytes-set! b (%+ (%* i font-cell) j) r)
          (set! j (%+ j 1))))
      (set! i (%+ i 1)))
    (set! *font* b)
    ;; The readable form has done its job; let the collector have it back.
    (set! *font-rows* nil)
    b))

(define (font-row ch row)
  ;; The five bits of one row of one glyph, or nothing for a character the
  ;; font does not have.
  (let ((i (%- (%char->int ch) font-first)))
    (if (%null? *font*)
        0
        (if (%< i 0)
            0
            (let ((k (%+ (%* i font-cell) row)))
              (if (%< k (bytes-length *font*)) (bytes-ref *font* k) 0))))))
