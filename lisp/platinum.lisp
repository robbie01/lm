;;; platinum.lisp - the Mac OS 8/9 appearance.
;;;
;;; Ported from ~/platinum, a recreation in Rust whose values were measured
;;; off Mac OS 9.0 screenshots. Platinum is drawn almost entirely from a
;;; sixteen-step grey ramp, 0x11 apart, with one lavender accent and a
;;; blue-grey desktop: twenty-two colours in all, which go at the top of the
;;; palette. The low sixteen entries are the machine's named colours and the
;;; middle is a grey ramp the demos draw gradients out of.

(in-package platinum)

;; ---------------------------------------------------------------- palette
(define palette-base 232)

;; Grey n of the ramp, 0 black and 15 white.
(define (grey n) (%+ palette-base n))

(define black (%+ palette-base 0))
(define g13 (%+ palette-base 2))       ; 0x22, the darkest thing that is not black
(define g12 (%+ palette-base 3))       ; 0x33
(define g11 (%+ palette-base 4))       ; 0x44
(define g10 (%+ palette-base 5))       ; 0x55
(define g9 (%+ palette-base 6))        ; 0x66
(define g8 (%+ palette-base 7))        ; 0x77, the dark pinstripe
(define g7 (%+ palette-base 8))        ; 0x88
(define g6 (%+ palette-base 9))        ; 0x99, the shadow of a raised strip
(define g5 (%+ palette-base 10))       ; 0xAA
(define g4 (%+ palette-base 11))       ; 0xBB
(define g3 (%+ palette-base 12))       ; 0xCC, the frame face
(define g2 (%+ palette-base 13))       ; 0xDD, the dialog background
(define g1 (%+ palette-base 14))       ; 0xEE
(define white (%+ palette-base 15))

(define lav-light (%+ palette-base 16))   ; #CCCCFF
(define lav (%+ palette-base 17))         ; #9999FF
(define lav-dark (%+ palette-base 18))    ; #6666CC, the highlight colour
(define lav-darkest (%+ palette-base 19)) ; #333399
(define desktop (%+ palette-base 20))     ; #63639C
(define desktop-dark (%+ palette-base 21))

(define (palette)
  ;; Sixteen greys, then the accents, as one request to the display driver.
  (let ((pairs (list (%cons lav-light (rgb 204 204 255))
                     (%cons lav (rgb 153 153 255))
                     (%cons lav-dark (rgb 102 102 204))
                     (%cons lav-darkest (rgb 51 51 153))
                     (%cons desktop (rgb 99 99 156))
                     (%cons desktop-dark (rgb 90 90 146))))
        (i 15))
    (while (%>= i 0)
      (let ((v (%* i 17)))
        (set! pairs (%cons (%cons (%+ palette-base i) (rgb v v v)) pairs)))
      (set! i (%- i 1)))
    (gfx:set-colours pairs))
  nil)

;; ---------------------------------------------------------------- metrics
;; Rows 0..21 of a window: the frame-rect, nineteen interior rows, the shadow row
;; and the content border. Everything else is measured off that.
(define title-height 22)
(define band 6)              ; left, right and bottom bands
(define box-size 12)              ; a title-bar box
(define box-x 4)
(define box-y 4)
(define menubar-height 20)
(define menubar-first-x 9)

;; ---------------------------------------------------------------- bevels
;; A raised strip is a white line along its top and left and a #99 line
;; along its bottom and right. Everything in Platinum that looks like an edge
;; is one of these.
(define (hline rp x y w c) (fill-rect rp x y w 1 c))
(define (vline rp x y h c) (fill-rect rp x y 1 h c))

(define (frame-rect rp x y w h c)
  (hline rp x y w c)
  (hline rp x (%+ y (%- h 1)) w c)
  (vline rp x y h c)
  (vline rp (%+ x (%- w 1)) y h c))

(define (raised rp x y w h)
  (hline rp x y (%- w 1) white)
  (vline rp x y (%- h 1) white)
  (hline rp (%+ x 1) (%+ y (%- h 1)) (%- w 1) g6)
  (vline rp (%+ x (%- w 1)) (%+ y 1) (%- h 1) g6))

(define (sunken rp x y w h)
  (hline rp x y (%- w 1) g6)
  (vline rp x y (%- h 1) g6)
  (hline rp (%+ x 1) (%+ y (%- h 1)) (%- w 1) white)
  (vline rp (%+ x (%- w 1)) (%+ y 1) (%- h 1) white))

;; ---------------------------------------------------------------- pinstripes
;; Rows 4..15 of the title bar, white on even rows and #777 on odd, with a gap
;; cut around each box and around the title.
(define (stripes rp x y w cuts)
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
                  (hline rp cx py (%- (if (%< c0 end) c0 end) cx)
                            (if dark g8 white))
                  nil)
              (if (%> c1 cx) (set! cx c1) nil)))
          (if (%< cx end)
              (hline rp cx py (%- end cx) (if dark g8 white))
              nil)))
      (set! row (%+ row 1)))
    nil))

;; ---------------------------------------------------------------- boxes
;; The close, zoom and collapse boxes: a #222 frame-rect round a diagonal ramp
;; from #99 at the top left to white at the bottom right, with a white
;; highlight along the outside of the right and bottom edges.
(define (title-box rp x y kind)
  ;; kind 0 close, 1 zoom, 2 collapse.
  (fill-rect rp x y 12 12 g7)
  (fill-rect rp (%+ x 1) (%+ y 1) 10 10 g13)
  (let ((row 0))
    (while (%< row 8)
      (let ((col 0))
        (while (%< col 8)
          (let ((d (%+ row col)))
            (plot rp (%+ x (%+ col 2)) (%+ y (%+ row 2))
                  (grey (%+ 9 (%/ (%* d 6) 14)))))
          (set! col (%+ col 1))))
      (set! row (%+ row 1))))
  ;; The mark inside: a vertical bar for zoom, a horizontal one for collapse,
  ;; nothing for close.
  (if (%= kind 1)
      (vline rp (%+ x 6) (%+ y 2) 8 g13)
      (if (%= kind 2) (hline rp (%+ x 2) (%+ y 6) 8 g13) nil))
  (vline rp (%+ x 12) (%+ y 1) 12 white)
  (hline rp (%+ x 1) (%+ y 12) 12 white)
  nil)

;; ---------------------------------------------------------------- grow box
(define (grow-box rp x y)
  (fill-rect rp x y 15 15 g3)
  (raised rp x y 15 15)
  (let ((i 0))
    (while (%< i 3)
      (let ((o (%+ 3 (%* i 4))) (j 0))
        (while (%< j 9)
          (let ((px (%+ x (%+ o j))) (py (%+ y (%- 11 j))))
            (if (%< (%- px x) 14)
                (begin (plot rp px py g7) (plot rp px (%+ py 1) white))
                nil))
          (set! j (%+ j 1))))
      (set! i (%+ i 1))))
  nil)
