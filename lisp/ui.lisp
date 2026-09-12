;;; ui.lisp - controls, in the Platinum appearance.
;;;
;;; A control is a record with a position in its window's coordinates, drawn
;;; through the window's rastport and fed the window's events. Three kinds:
;;; a vertical scroll bar, a push button, and an outline, which is a list of
;;; rows with disclosure triangles that open onto more rows. The task that
;;; reads the window hands each event to its controls and redraws what
;;; answers `changed`.
;;;
;;; Geometry follows ~/platinum, which was measured off Mac OS 9 screenshots.

(in-package ui)

(define row-height 16)
(define scrollbar-width 16)
(define arrow-length 15)
(define min-thumb 17)
(define indent 16)
(define double-click-frames 25)

;; ---------------------------------------------------------------- shapes
;; The 8x4 scroll arrow with a two-pixel apex; x y is the top left of its box.
(define (scroll-arrow rp x y up c)
  (let ((i 0))
    (while (%< i 4)
      (if up
          (hline rp (%+ x (%- 3 i)) (%+ y i) (%+ 2 (%* 2 i)) c)
          (hline rp (%+ x i) (%+ y i) (%- 8 (%* 2 i)) c))
      (set! i (%+ i 1)))
    nil))

;; A solid 7x4 triangle centred on cx cy, pointing right or down.
(define (triangle rp cx cy down c)
  (let ((i 0))
    (while (%< i 4)
      (if down
          (hline rp (%- cx i) (%- (%+ cy 1) i) (%+ (%* 2 i) 1) c)
          (vline rp (%- (%+ cx 1) i) (%- cy i) (%+ (%* 2 i) 1) c))
      (set! i (%+ i 1)))
    nil))

;; ---------------------------------------------------------------- scroll bar
;; value runs from 0 to max; page is how much is visible, which sizes the
;; thumb; step is what an arrow moves by.
(defrecord (scrollbar sb) x y w h value max page step pressed grab)

(define (make-scrollbar x y h)
  (let ((s (sb-alloc)))
    (set-sb-x! s x)
    (set-sb-y! s y)
    (set-sb-w! s scrollbar-width)
    (set-sb-h! s h)
    (set-sb-value! s 0)
    (set-sb-max! s 0)
    (set-sb-page! s 1)
    (set-sb-step! s 1)
    (set-sb-grab! s 0)
    s))

(define (scrollbar-range! s max page)
  (set-sb-max! s (max2 max 0))
  (set-sb-page! s (max2 page 1))
  (set-sb-value! s (clamp (sb-value s) 0 (sb-max s)))
  nil)

;; Answers t when the value moved.
(define (scrollbar-set! s v)
  (let ((v (clamp v 0 (sb-max s))))
    (if (%= v (sb-value s))
        nil
        (begin (set-sb-value! s v) t))))

;; The two arrow boxes sit at the bottom, each arrow-length less one, with a
;; divider row above each.
(define (dec-box-y s) (%- (%+ (sb-y s) (sb-h s)) (%* 2 arrow-length)))
(define (inc-box-y s) (%- (%+ (sb-y s) (sb-h s)) arrow-length))
(define (track-y s) (%+ (sb-y s) 1))
(define (track-h s) (%- (sb-h s) (%+ 2 (%* 2 arrow-length))))

;; Where the thumb is, as (y . h), or nil when there is nothing to scroll.
(define (thumb s)
  (if (%<= (sb-max s) 0)
      nil
      (let ((len (track-h s)))
        (if (%< len min-thumb)
            nil
            (let* ((total (%+ (sb-max s) (sb-page s)))
                   (tl (clamp (%/ (%* len (sb-page s)) total) min-thumb len))
                   (pos (%/ (%* (%- len tl) (sb-value s)) (sb-max s))))
              (%cons (%+ (track-y s) pos) tl))))))

(define (scrollbar-hit? s x y)
  (if (%>= x (sb-x s))
      (if (%< x (%+ (sb-x s) (sb-w s)))
          (if (%>= y (sb-y s)) (%< y (%+ (sb-y s) (sb-h s))) nil)
          nil)
      nil))

(define (scrollbar-part s x y)
  (cond ((if (%>= y (dec-box-y s)) (%< y (%- (inc-box-y s) 1)) nil) 'dec)
        ((%>= y (inc-box-y s)) 'inc)
        (else
         (let ((th (thumb s)))
           (if th
               (cond ((%< y (%car th)) 'page-dec)
                     ((%>= y (%+ (%car th) (%cdr th))) 'page-inc)
                     (else 'thumb))
               nil)))))

(define (draw-arrow-box rp x y w h up pressed live)
  (fill-rect rp x y w h (if pressed g5 (if live g2 g1)))
  (if (if live (if pressed nil t) nil)
      (begin (hline rp (%+ x 1) (%+ y 1) (%- w 3) white)
             (vline rp (%+ x 1) (%+ y 1) (%- h 3) white))
      nil)
  (scroll-arrow rp (%+ x (%/ (%- w 8) 2)) (%+ y (%/ (%- h 4) 2)) up (if live black g7)))

(define (draw-thumb rp x y w h)
  (fill-rect rp x y w h lav)
  (hline rp x y w black)
  (hline rp x (%+ y (%- h 1)) w black)
  (hline rp x (%+ y 1) w lav-light)
  (plot rp x (%+ y 1) g1)
  (plot rp (%+ x (%- w 1)) (%+ y 1) lav)
  (vline rp x (%+ y 2) (%- h 4) lav-light)
  (vline rp (%+ x (%- w 1)) (%+ y 2) (%- h 4) lav-dark)
  (hline rp (%+ x 1) (%+ y (%- h 2)) (%- w 1) lav-dark)
  (plot rp x (%+ y (%- h 2)) lav)
  ;; the ridges
  (if (%>= h 13)
      (let ((gy (%+ y (%/ (%- h 8) 2))) (i 0))
        (while (%< i 4)
          (plot rp (%+ x 3) (%+ gy (%* 2 i)) g1)
          (hline rp (%+ x 4) (%+ gy (%* 2 i)) 6 lav-light)
          (hline rp (%+ x 4) (%+ gy (%+ (%* 2 i) 1)) 7 lav-darkest)
          (set! i (%+ i 1))))
      nil)
  nil)

(define (draw-scrollbar s rp)
  (let* ((x (sb-x s)) (y (sb-y s)) (w (sb-w s)) (h (sb-h s))
         (live (%> (sb-max s) 0))
         (tx (%+ x 1)) (ty (track-y s)) (tw (%- w 2)) (th (track-h s)))
    ;; the well
    (if live
        (begin
          (fill-rect rp tx ty tw th g5)
          (hline rp tx ty (%- tw 1) g8)
          (vline rp tx ty th g8)
          (hline rp (%+ tx 1) (%+ ty 1) (%- tw 3) g7)
          (vline rp (%+ tx 1) (%+ ty 1) (%- th 1) g7))
        (fill-rect rp tx ty tw th g1))
    (frame-rect rp x y w h black)
    (hline rp x (%- (dec-box-y s) 1) w (if live black g7))
    (hline rp x (%- (inc-box-y s) 1) w (if live black g7))
    (draw-arrow-box rp x (dec-box-y s) w (%- arrow-length 1) t
                    (%eq? (sb-pressed s) 'dec) live)
    (draw-arrow-box rp x (inc-box-y s) w (%- arrow-length 1) nil
                    (%eq? (sb-pressed s) 'inc) live)
    (let ((tb (thumb s)))
      (if tb (draw-thumb rp tx (%car tb) tw (%cdr tb)) nil))
    nil))

;; Answers `changed` when the bar has to be drawn again, `taken` when the
;; event was the bar's but nothing shows, and nil when it was not the bar's.
(define (scrollbar-event s ev)
  (let ((what (%car ev)))
    (cond
     ((%eq? what 'input:button)
      (if (%eq? (cadr ev) 'input:down)
          (let ((x (cadddr ev)) (y (nth 4 ev)))
            (if (scrollbar-hit? s x y)
                (let ((part (scrollbar-part s x y)))
                  (set-sb-pressed! s part)
                  (cond ((%eq? part 'dec) (scrollbar-set! s (%- (sb-value s) (sb-step s))))
                        ((%eq? part 'inc) (scrollbar-set! s (%+ (sb-value s) (sb-step s))))
                        ((%eq? part 'page-dec) (scrollbar-set! s (%- (sb-value s) (sb-page s))))
                        ((%eq? part 'page-inc) (scrollbar-set! s (%+ (sb-value s) (sb-page s))))
                        ((%eq? part 'thumb) (set-sb-grab! s (%- y (%car (thumb s)))))
                        (else nil))
                  'changed)
                nil))
          (if (sb-pressed s)
              (begin (set-sb-pressed! s nil) 'changed)
              nil)))
     ((%eq? what 'input:mouse)
      (cond ((%eq? (sb-pressed s) 'thumb)
             (let* ((tb (thumb s))
                    (span (max2 (%- (track-h s) (%cdr tb)) 1))
                    (pos (clamp (%- (%- (nth 4 ev) (sb-grab s)) (track-y s)) 0 span)))
               (if (scrollbar-set! s (%/ (%* pos (sb-max s)) span)) 'changed 'taken)))
            ((sb-pressed s) 'taken)
            (else nil)))
     ((%eq? what 'input:wheel)
      (if (scrollbar-hit? s (caddr ev) (cadddr ev))
          (if (scrollbar-set! s (%- (sb-value s) (%* (cadr ev) (sb-step s)))) 'changed 'taken)
          nil))
     (else nil))))

;; ---------------------------------------------------------------- button
(defrecord (button bt) x y w h label pressed on-click)

(define (make-button x y w h label on-click)
  (let ((b (bt-alloc)))
    (set-bt-x! b x)
    (set-bt-y! b y)
    (set-bt-w! b w)
    (set-bt-h! b h)
    (set-bt-label! b label)
    (set-bt-on-click! b on-click)
    b))

(define (button-hit? b x y)
  (if (%>= x (bt-x b))
      (if (%< x (%+ (bt-x b) (bt-w b)))
          (if (%>= y (bt-y b)) (%< y (%+ (bt-y b) (bt-h b))) nil)
          nil)
      nil))

;; The push button: a black outline with a two-pixel chamfer, corner pixels
;; softened in two greys, a white highlight two pixels in along the top and
;; left, a shadow one pixel in along the bottom and right. `bg` is what the
;; four corner pixels outside the chamfer show.
(define (draw-button b rp bg)
  (let* ((x (bt-x b)) (y (bt-y b)) (w (bt-w b)) (h (bt-h b))
         (down (bt-pressed b))
         (face (if down g9 g2))
         (hi (if down g11 white))
         (sh (if down g7 g8))
         (x1 (%+ x (%- w 1))) (y1 (%+ y (%- h 1))))
    (fill-rect rp x y w h face)
    ;; the outline, row by row through the chamfer
    (hline rp (%+ x 2) y (%- w 4) black)
    (hline rp (%+ x 2) y1 (%- w 4) black)
    (vline rp x (%+ y 2) (%- h 4) black)
    (vline rp x1 (%+ y 2) (%- h 4) black)
    (plot rp (%+ x 1) (%+ y 1) black) (plot rp (%- x1 1) (%+ y 1) black)
    (plot rp (%+ x 1) (%- y1 1) black) (plot rp (%- x1 1) (%- y1 1) black)
    ;; the corners outside the chamfer, and the softening beside them
    (fill-rect rp x y 2 1 bg) (fill-rect rp x (%+ y 1) 1 1 bg)
    (fill-rect rp (%- x1 1) y 2 1 bg) (fill-rect rp x1 (%+ y 1) 1 1 bg)
    (fill-rect rp x y1 2 1 bg) (fill-rect rp x (%- y1 1) 1 1 bg)
    (fill-rect rp (%- x1 1) y1 2 1 bg) (fill-rect rp x1 (%- y1 1) 1 1 bg)
    (plot rp (%+ x 2) y g13) (plot rp x (%+ y 2) g13)
    (plot rp (%- x1 2) y g13) (plot rp x1 (%+ y 2) g13)
    (plot rp (%+ x 2) y1 g13) (plot rp x (%- y1 2) g13)
    (plot rp (%- x1 2) y1 g13) (plot rp x1 (%- y1 2) g13)
    (plot rp (%+ x 1) y g8) (plot rp x (%+ y 1) g8)
    (plot rp (%- x1 1) y g8) (plot rp x1 (%+ y 1) g8)
    (plot rp (%+ x 1) y1 g8) (plot rp x (%- y1 1) g8)
    (plot rp (%- x1 1) y1 g8) (plot rp x1 (%- y1 1) g8)
    ;; highlight and shadow
    (hline rp (%+ x 2) (%+ y 2) (%- w 5) hi)
    (vline rp (%+ x 2) (%+ y 2) (%- h 5) hi)
    (hline rp (%+ x 3) (%- y1 1) (%- w 5) sh)
    (vline rp (%- x1 1) (%+ y 3) (%- h 5) sh)
    (plot rp (%- x1 2) (%- y1 2) sh)
    ;; the label, centred
    (let ((tw (text-width (bt-label b))))
      (draw-text rp (%+ x (%/ (%- w tw) 2)) (%+ y (%/ (%- h 15) 2))
                 (bt-label b) (if down white black) nil))
    nil))

;; Pressing shows at once; the click happens on release, and only if the
;; pointer is still on the button.
(define (button-event b ev)
  (if (%eq? (%car ev) 'input:button)
      (let ((x (cadddr ev)) (y (nth 4 ev)))
        (if (%eq? (cadr ev) 'input:down)
            (if (button-hit? b x y)
                (begin (set-bt-pressed! b t) 'changed)
                nil)
            (if (bt-pressed b)
                (begin
                  (set-bt-pressed! b nil)
                  (if (button-hit? b x y) (%funcall (bt-on-click b)) nil)
                  'changed)
                nil)))
      nil))

;; ---------------------------------------------------------------- outline
;; Rows, each of which may open onto more rows. A row that can open shows a
;; disclosure triangle; opening it asks `parts` for its children, once, as a
;; list of (label object expandable).
(defrecord (row rw) depth label object expandable expanded children)

(defrecord (outline ol) x y w h roots parts scrollbar selected pressed
  click-row click-frame)

(define (make-row depth label object expandable)
  (let ((r (rw-alloc)))
    (set-rw-depth! r depth)
    (set-rw-label! r label)
    (set-rw-object! r object)
    (set-rw-expandable! r expandable)
    r))

;; `roots` is a list of (label object expandable); `parts` is a function of
;; an object answering the same for its children.
(define (make-outline x y w h roots parts)
  (let ((o (ol-alloc)))
    (set-ol-x! o x)
    (set-ol-y! o y)
    (set-ol-w! o w)
    (set-ol-h! o h)
    (set-ol-roots! o (map (lambda (p) (make-row 0 (%car p) (cadr p) (caddr p))) roots))
    (set-ol-parts! o parts)
    (set-ol-scrollbar! o (make-scrollbar (%- (%+ x w) scrollbar-width) y h))
    (set-ol-click-frame! o -100)
    o))

(define (rows-x o) (%+ (ol-x o) 1))
(define (rows-y o) (%+ (ol-y o) 1))
(define (rows-w o) (%- (ol-w o) (%+ scrollbar-width 1)))
(define (rows-h o) (%- (ol-h o) 2))
(define (visible-count o) (max2 (%/ (rows-h o) row-height) 1))

;; The open rows, in order, as one list.
(define (visible-rows o)
  (reverse (flatten-rows (ol-roots o) nil)))

(define (flatten-rows rows acc)
  (dolist (r rows)
    (set! acc (%cons r acc))
    (if (rw-expanded r) (set! acc (flatten-rows (rw-children r) acc)) nil))
  acc)

(define (sync-scrollbar! o rows)
  (scrollbar-range! (ol-scrollbar o)
                    (%- (length rows) (visible-count o))
                    (visible-count o))
  nil)

(define (expand! o r)
  (if (rw-children r)
      nil
      (set-rw-children! r (map (lambda (p) (make-row (%+ (rw-depth r) 1) (%car p) (cadr p) (caddr p)))
                               (%funcall (ol-parts o) (rw-object r)))))
  (set-rw-expanded! r t)
  nil)

(define (collapse! o r) (set-rw-expanded! r nil) nil)

(define (toggle! o r)
  (if (rw-expanded r) (collapse! o r) (expand! o r)))

;; The row under y, from the rows now open, or nil.
(define (row-at o rows y)
  (let ((i (%+ (%/ (%- y (rows-y o)) row-height) (sb-value (ol-scrollbar o)))))
    (if (if (%>= y (rows-y o)) (%< y (%+ (rows-y o) (rows-h o))) nil)
        (if (%< i (length rows)) (nth i rows) nil)
        nil)))

(define (triangle-x o r) (%+ (rows-x o) (%+ 8 (%* (rw-depth r) indent))))
(define (label-x o r) (%+ (rows-x o) (%+ 16 (%* (rw-depth r) indent))))

(define (in-triangle? o r x)
  (if (rw-expandable r)
      (if (%>= x (%- (triangle-x o r) 6)) (%< x (%+ (triangle-x o r) 6)) nil)
      nil))

(define (index-of x l)
  (let ((i 0) (found -1))
    (while (if (%cons? l) (%< found 0) nil)
      (if (%eq? (%car l) x) (set! found i) nil)
      (set! i (%+ i 1))
      (set! l (%cdr l)))
    found))

(define (scroll-into-view! o rows r)
  (let ((i (index-of r rows))
        (s (ol-scrollbar o)))
    (if (%< i 0)
        nil
        (begin
          (if (%< i (sb-value s)) (scrollbar-set! s i) nil)
          (if (%>= i (%+ (sb-value s) (visible-count o)))
              (scrollbar-set! s (%+ (%- i (visible-count o)) 1))
              nil)))
    nil))

(define (draw-outline o rp)
  (let* ((rows (visible-rows o))
         (rx (rows-x o)) (ry (rows-y o)) (rw (rows-w o)) (rh (rows-h o))
         (crp (make-rastport-on (rp-bitmap rp) (rp-origin-x rp) (rp-origin-y rp)
                                (region-intersect-rect
                                 (rp-region rp)
                                 (rect (%+ rx (rp-origin-x rp)) (%+ ry (rp-origin-y rp)) rw rh))))
         (top (begin (sync-scrollbar! o rows) (sb-value (ol-scrollbar o))))
         (n (%+ (visible-count o) 1))
         (l (nthcdr top rows))
         (y ry))
    (fill-rect rp (ol-x o) (ol-y o) (ol-w o) (ol-h o) white)
    (frame-rect rp (ol-x o) (ol-y o) (ol-w o) (ol-h o) black)
    (while (if (%cons? l) (%> n 0) nil)
      (let ((r (%car l)))
        (if (%eq? r (ol-selected o)) (fill-rect crp rx y rw row-height lav-light) nil)
        (if (rw-expandable r)
            (triangle crp (triangle-x o r) (%+ y 7) (rw-expanded r) black)
            nil)
        (draw-text crp (label-x o r) (%+ y 1) (rw-label r) black nil))
      (set! y (%+ y row-height))
      (set! n (%- n 1))
      (set! l (%cdr l)))
    (draw-scrollbar (ol-scrollbar o) rp)
    nil))

(define (select! o rows r)
  (set-ol-selected! o r)
  (scroll-into-view! o rows r)
  nil)

;; Answers nil for an event that was not the outline's, `changed` when it has
;; to be drawn again, and (open . row) when a row was double-clicked or
;; entered.
(define (outline-event o ev)
  (let ((sb (scrollbar-event (ol-scrollbar o) ev)))
    (if sb
        (if (%eq? sb 'changed) 'changed nil)
        (let ((what (%car ev)) (rows (visible-rows o)))
          (cond
           ((%eq? what 'input:button)
            (if (%eq? (cadr ev) 'input:down)
                (button-down! o rows (cadddr ev) (nth 4 ev))
                (begin (set-ol-pressed! o nil) nil)))
           ((%eq? what 'input:mouse)
            (if (ol-pressed o)
                (let ((r (row-at o rows (nth 4 ev))))
                  (if (if r (if (%eq? r (ol-selected o)) nil t) nil)
                      (begin (set-ol-selected! o r) 'changed)
                      nil))
                nil))
           ((%eq? what 'input:wheel)
            (if (scrollbar-set! (ol-scrollbar o)
                                (%- (sb-value (ol-scrollbar o)) (%* 3 (cadr ev))))
                'changed
                nil))
           ((%eq? what 'input:key) (key! o rows (cadr ev) (caddr ev)))
           (else nil))))))

(define (button-down! o rows x y)
  (let ((r (row-at o rows y)))
    (set-ol-pressed! o t)
    (cond ((%null? r)
           (if (ol-selected o) (begin (set-ol-selected! o nil) 'changed) nil))
          ((in-triangle? o r x) (toggle! o r) 'changed)
          (else
           (let ((again (if (%eq? r (ol-click-row o))
                            (%< (%- *vblank-count* (ol-click-frame o)) double-click-frames)
                            nil)))
             (set-ol-click-row! o r)
             (set-ol-click-frame! o *vblank-count*)
             (set-ol-selected! o r)
             (if again (%cons 'open r) 'changed))))))

(define key-up #x80)
(define key-down #x81)
(define key-left #x82)
(define key-right #x83)
(define key-home #x84)
(define key-end #x85)
(define key-page-up #x86)
(define key-page-down #x87)

(define (key! o rows ascii code)
  (let* ((sel (ol-selected o))
         (i (if sel (index-of sel rows) -1))
         (n (length rows))
         (vis (visible-count o)))
    (cond
     ((%= n 0) nil)
     ((%= code key-up) (select! o rows (nth (max2 (%- i 1) 0) rows)) 'changed)
     ((%= code key-down) (select! o rows (nth (min2 (%+ i 1) (%- n 1)) rows)) 'changed)
     ((%= code key-home) (select! o rows (%car rows)) 'changed)
     ((%= code key-end) (select! o rows (nth (%- n 1) rows)) 'changed)
     ((%= code key-page-up) (select! o rows (nth (max2 (%- i vis) 0) rows)) 'changed)
     ((%= code key-page-down) (select! o rows (nth (min2 (%+ i vis) (%- n 1)) rows)) 'changed)
     ((%null? sel) nil)
     ((%= code key-right)
      (if (rw-expandable sel) (begin (expand! o sel) 'changed) nil))
     ((%= code key-left)
      (if (rw-expanded sel) (begin (collapse! o sel) 'changed) nil))
     ((%= ascii 32)
      (if (rw-expandable sel) (begin (toggle! o sel) 'changed) nil))
     ((%= ascii 13) (%cons 'open sel))
     (else nil))))

(define (outline-selected o)
  (let ((r (ol-selected o))) (if r (rw-object r) nil)))
