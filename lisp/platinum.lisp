;;; platinum.lisp - the Mac OS 8/9 appearance.
;;;
;;; Ported from ~/platinum, a pixel-for-pixel recreation in Rust whose values
;;; were measured off Mac OS 9.0 screenshots. Platinum is drawn almost
;;; entirely from a sixteen-step grey ramp - 0x11 apart, so grey n is 0x11*n -
;;; with one lavender accent and a blue-grey desktop, which is why it survives
;;; the trip to an eight-bit palette intact: the whole appearance is
;;; twenty-two colours.
;;;
;;; They go at the top of the palette rather than the bottom. The low sixteen
;;; are the machine's named colours and the middle is a grey ramp the demos
;;; draw gradients out of; taking either would have made this file a change to
;;; everything that ever plotted a pixel.

(in-package wb)

;; ---------------------------------------------------------------- palette
(define pt-base 232)

;; Grey n of the ramp, 0 black and 15 white.
(define (pt-grey n) (%+ pt-base n))

(define pt-black (%+ pt-base 0))
(define pt-g13 (%+ pt-base 2))       ; 0x22, the darkest thing that is not black
(define pt-g12 (%+ pt-base 3))       ; 0x33
(define pt-g11 (%+ pt-base 4))       ; 0x44
(define pt-g10 (%+ pt-base 5))       ; 0x55
(define pt-g9 (%+ pt-base 6))        ; 0x66
(define pt-g8 (%+ pt-base 7))        ; 0x77, the dark pinstripe
(define pt-g7 (%+ pt-base 8))        ; 0x88
(define pt-g6 (%+ pt-base 9))        ; 0x99, the shadow of a raised strip
(define pt-g5 (%+ pt-base 10))       ; 0xAA
(define pt-g4 (%+ pt-base 11))       ; 0xBB
(define pt-g3 (%+ pt-base 12))       ; 0xCC, the frame face
(define pt-g2 (%+ pt-base 13))       ; 0xDD, the dialog background
(define pt-g1 (%+ pt-base 14))       ; 0xEE
(define pt-white (%+ pt-base 15))

(define pt-lav-light (%+ pt-base 16))   ; #CCCCFF
(define pt-lav (%+ pt-base 17))         ; #9999FF
(define pt-lav-dark (%+ pt-base 18))    ; #6666CC, the highlight colour
(define pt-lav-darkest (%+ pt-base 19)) ; #333399
(define pt-desktop (%+ pt-base 20))     ; #63639C
(define pt-desktop-dark (%+ pt-base 21))

(define (platinum-palette)
  ;; Sixteen greys, then the accents.
  (let ((i 0))
    (while (%< i 16)
      (let ((v (%* i 17)))
        (set-colour (%+ pt-base i) (rgb v v v)))
      (set! i (%+ i 1))))
  (set-colour pt-lav-light (rgb 204 204 255))
  (set-colour pt-lav (rgb 153 153 255))
  (set-colour pt-lav-dark (rgb 102 102 204))
  (set-colour pt-lav-darkest (rgb 51 51 153))
  (set-colour pt-desktop (rgb 99 99 156))
  (set-colour pt-desktop-dark (rgb 90 90 146))
  nil)

;; ---------------------------------------------------------------- metrics
;; Rows 0..21 of a window: the outline, nineteen interior rows, the shadow row
;; and the content border. Everything else is measured off that.
(define pt-title-h 22)
(define pt-band 6)              ; left, right and bottom bands
(define pt-box 12)              ; a title-bar box
(define pt-box-x 4)
(define pt-box-y 4)
(define pt-menubar-h 20)
(define pt-menubar-first-x 9)

;; ---------------------------------------------------------------- bevels
;; A raised strip is a white line along its top and left and a #99 line along
;; its bottom and right. Everything in Platinum that looks like an edge is one
;; of these; the rest is deciding which rectangle to put it round.
(define (pt-hline rp x y w c) (fill-rect rp x y w 1 c))
(define (pt-vline rp x y h c) (fill-rect rp x y 1 h c))

(define (pt-frame rp x y w h c)
  (pt-hline rp x y w c)
  (pt-hline rp x (%+ y (%- h 1)) w c)
  (pt-vline rp x y h c)
  (pt-vline rp (%+ x (%- w 1)) y h c))

(define (pt-raised rp x y w h)
  (pt-hline rp x y (%- w 1) pt-white)
  (pt-vline rp x y (%- h 1) pt-white)
  (pt-hline rp (%+ x 1) (%+ y (%- h 1)) (%- w 1) pt-g6)
  (pt-vline rp (%+ x (%- w 1)) (%+ y 1) (%- h 1) pt-g6))

(define (pt-sunken rp x y w h)
  (pt-hline rp x y (%- w 1) pt-g6)
  (pt-vline rp x y (%- h 1) pt-g6)
  (pt-hline rp (%+ x 1) (%+ y (%- h 1)) (%- w 1) pt-white)
  (pt-vline rp (%+ x (%- w 1)) (%+ y 1) (%- h 1) pt-white))

;; ---------------------------------------------------------------- pinstripes
;; Rows 4..15 of the title bar, white on even rows and #777 on odd, with a gap
;; cut around each box and around the title. The cuts are what make it read as
;; Platinum rather than as a striped rectangle.
(define (pt-stripes rp x y w cuts)
  (let ((row 0))
    (while (%< row 12)
      (let ((dark (%= 1 (%logand row 1)))
            (px x)
            (py (%+ y row)))
        ;; One run per gap between cuts, left to right.
        (let ((cx x) (end (%+ x w)))
          (dolist (c cuts)
            (let ((c0 (if dark (%car c) (%- (%car c) 1)))
                  (c1 (if dark (cadr c) (%+ (cadr c) 1))))
              (if (%> c0 cx)
                  (pt-hline rp cx py (%- (if (%< c0 end) c0 end) cx)
                            (if dark pt-g8 pt-white))
                  nil)
              (if (%> c1 cx) (set! cx c1) nil)))
          (if (%< cx end)
              (pt-hline rp cx py (%- end cx) (if dark pt-g8 pt-white))
              nil)))
      (set! row (%+ row 1)))
    nil))

;; ---------------------------------------------------------------- boxes
;; The close, zoom and collapse boxes: a #222 outline round a diagonal ramp
;; from #99 at the top left to white at the bottom right, with a white
;; highlight along the outside of the right and bottom edges.
(define (pt-title-box rp x y kind)
  ;; kind 0 close, 1 zoom, 2 collapse.
  (fill-rect rp x y 12 12 pt-g7)
  (fill-rect rp (%+ x 1) (%+ y 1) 10 10 pt-g13)
  (let ((row 0))
    (while (%< row 8)
      (let ((col 0))
        (while (%< col 8)
          (let ((d (%+ row col)))
            (plot rp (%+ x (%+ col 2)) (%+ y (%+ row 2))
                  (pt-grey (%+ 9 (%/ (%* d 6) 14)))))
          (set! col (%+ col 1))))
      (set! row (%+ row 1))))
  ;; The mark inside: a vertical bar for zoom, a horizontal one for collapse,
  ;; nothing for close.
  (if (%= kind 1)
      (pt-vline rp (%+ x 6) (%+ y 2) 8 pt-g13)
      (if (%= kind 2) (pt-hline rp (%+ x 2) (%+ y 6) 8 pt-g13) nil))
  (pt-vline rp (%+ x 12) (%+ y 1) 12 pt-white)
  (pt-hline rp (%+ x 1) (%+ y 12) 12 pt-white)
  nil)

;; ---------------------------------------------------------------- grow box
(define (pt-grow-box rp x y)
  (fill-rect rp x y 15 15 pt-g3)
  (pt-raised rp x y 15 15)
  (let ((i 0))
    (while (%< i 3)
      (let ((o (%+ 3 (%* i 4))) (j 0))
        (while (%< j 9)
          (let ((px (%+ x (%+ o j))) (py (%+ y (%- 11 j))))
            (if (%< (%- px x) 14)
                (begin (plot rp px py pt-g7) (plot rp px (%+ py 1) pt-white))
                nil))
          (set! j (%+ j 1))))
      (set! i (%+ i 1))))
  nil)
