;;; wb.lisp - a workbench: windows, a shell in each, and a compositor.
;;;
;;; Every window has two bitmaps of its own. Its owner draws into the first,
;;; which nothing else ever looks at; the second is what the screen is made
;;; from, and the only way anything gets from one to the other is the owner
;;; saying that part of its picture is finished - `window-damage-rect`, or
;;; `window-damage` for all of it. The compositor paints the screen from the
;;; second, front to back, over whatever has been damaged since it last ran.
;;;
;;; It used to be one bitmap a window, drawn into and composited from at once.
;;; A pair of eyes is a white disc, then an outline, then a pupil, and a
;;; compositor that ran in the middle of that put a white disc on the screen.
;;; With ten pairs following the pointer somebody was always in the middle,
;;; and the pupils flickered.

(in-package wb)

;; ---------------------------------------------------------------- palette
;; The old names, pointed at Platinum. A window's interior is white with black
;; text, which is what every Mac OS document window was; the workbench's own
;; furniture is the grey ramp.
(define wb-desktop pt-desktop)
(define wb-face pt-g3)
(define wb-shadow pt-g6)
(define wb-light pt-white)
(define wb-text pt-black)
(define wb-back pt-white)
(define wb-title-on pt-g3)
(define wb-title-off pt-g3)
(define wb-title-text-on pt-black)
(define wb-title-text-off pt-g7)

;; ---------------------------------------------------------------- windows
;; Slot 0 is the record's tag, so a window says what it is and asking a
;; number for its title is a trap rather than a wrong answer.
(defrecord (window win)
  x y w h title
  refresh                 ; (lambda (w)) draws the interior
  keys                    ; the port its keys are sent to, if anybody reads it
  task
  data                    ; whatever the window is for
  rp                      ; where this window draws: its own bitmap
  bm                      ; that bitmap, which only its owner sees
  front)                  ; and the copy the screen is composited from

(define *windows* nil)    ; front to back
(define *wb-running* nil)

(define title-height pt-title-h)

(define (make-window x y w h title)
  ;; A window is a bitmap of its own, and everything it draws goes there
  ;; rather than at the screen. Two windows cannot reach each other however
  ;; wrong their arithmetic is, drawing does not have to be clipped to a
  ;; region that somebody has to keep correct, and the order things appear in
  ;; is decided once, by the compositor, instead of every time anybody paints.
  (let ((v (win-alloc)))
    (set-win-x! v x)
    (set-win-y! v y)
    (set-win-w! v w)
    (set-win-h! v h)
    (set-win-title! v title)
    (set-win-bm! v (alloc-bitmap w h))
    (set-win-front! v (alloc-bitmap w h))
    (set-win-rp! v (make-bitmap-rastport (win-bm v)))
    v))

(define (window-rastport w) (win-rp w))
(define (window-bitmap w) (win-bm w))

(define (window-rect w)
  (rect (win-x w) (win-y w) (win-w w) (win-h w)))

;; What the window costs the screen, which is one pixel more than the window:
;; Platinum draws a hard black shadow down the right edge and along the
;; bottom. It is not part of the window - it falls on whatever is behind -
;; so the compositor draws it rather than the window, and damage has to
;; cover it or a moved window leaves its shadow behind.
(define (window-footprint w)
  (rect (win-x w) (win-y w)
        (%+ (win-w w) 1) (%+ (win-h w) 1)))

;; Coordinates inside a window are the window's own: nothing here knows or
;; cares where on the screen it ends up.
(define (win-inner-x w) pt-band)
(define (win-inner-y w) title-height)
(define (win-inner-w w) (%- (win-w w) (%* 2 pt-band)))
(define (win-inner-h w) (%- (win-h w) (%+ title-height pt-band)))

(define (front-window) (if (%cons? *windows*) (%car *windows*) nil))

;; ---------------------------------------------------------------- damage
;; What the compositor owes the screen: a short list of rectangles covering
;; everything anybody has changed since it last ran. A whole screen is 786,432
;; pixels and the blitter is charged one cycle each, which is more than two
;; frames at sixty hertz - so compositing everything every time is not a thing
;; this machine can afford, and what actually moved is.
(define *damage* nil)      ; a list of rectangles, newest first
(define damage-max 32)     ; beyond which a new one joins its nearest

;; Every task that draws adds to the list and the compositor empties it, so it
;; is shared, and it is guarded by a mutex rather than a Forbid: adding damage
;; is a walk of up to thirty-two rectangles, which is long to hold every other
;; task in the machine off for, and only the tasks that draw ever contend for
;; it. A task that dies holding it may have left the list half merged, so the
;; repair is to repaint everything.
(define *damage-lock*
  (make-mutex "damage"
              (lambda (m) (set! *damage* (list (rect 0 0 (bm-w *screen*) (bm-h *screen*)))))))

(define (rect-union a b)
  (if (%null? a)
      b
      (if (%null? b)
          a
          (let ((x (if (%< (rect-x a) (rect-x b)) (rect-x a) (rect-x b)))
                (y (if (%< (rect-y a) (rect-y b)) (rect-y a) (rect-y b)))
                (x2 (if (%> (rect-x2 a) (rect-x2 b)) (rect-x2 a) (rect-x2 b)))
                (y2 (if (%> (rect-y2 a) (rect-y2 b)) (rect-y2 a) (rect-y2 b))))
            (rect x y (%- x2 x) (%- y2 y))))))

(define (rect-covers? a b)
  ;; Is b entirely inside a?
  (if (%<= (rect-x a) (rect-x b))
      (if (%<= (rect-y a) (rect-y b))
          (if (%>= (rect-x2 a) (rect-x2 b)) (%>= (rect-y2 a) (rect-y2 b)) nil)
          nil)
      nil))

(define (damage r)
  ;; A list rather than one growing rectangle. Two windows at opposite corners
  ;; have a union that is nearly the whole screen, and a compositor asked to
  ;; repaint the whole screen sixty times a second is a compositor that never
  ;; finishes one - which looks exactly like a window that will not appear.
  ;; The mutex, not Disable: only tasks ever add damage - the vblank and input
  ;; servers signal, they do not draw.
  (with-mutex *damage-lock*
    ;; Six tasks drawing into one window ask for the same rectangle six times.
    ;; Dropping what is already covered is what keeps the list short.
    (let ((have nil) (n 0))
      (dolist (d *damage*)
        (if (rect-covers? d r) (set! have t) nil)
        (set! n (%+ n 1)))
      (if have
          nil
          (if (%< n damage-max)
              (set! *damage* (%cons r *damage*))
              ;; Full, so r goes in with whichever rectangle it makes least
              ;; bigger. This used to merge the whole list into one, and ten
              ;; pairs of eyes damage twenty little squares a frame: the one
              ;; rectangle round all of them was most of the screen,
              ;; composited sixty times a second to move twenty pupils.
              (let ((best *damage*)
                    (least (union-growth (%car *damage*) r))
                    (l (%cdr *damage*)))
                (while (%cons? l)
                  (let ((g (union-growth (%car l) r)))
                    (if (%< g least) (begin (set! least g) (set! best l)) nil))
                  (set! l (%cdr l)))
                (%set-car! best (rect-union (%car best) r)))))))
  nil)

;; How much bigger a gets if it has to cover b as well.
(define (union-growth a b)
  (let ((x (if (%< (rect-x a) (rect-x b)) (rect-x a) (rect-x b)))
        (y (if (%< (rect-y a) (rect-y b)) (rect-y a) (rect-y b)))
        (x2 (if (%> (rect-x2 a) (rect-x2 b)) (rect-x2 a) (rect-x2 b)))
        (y2 (if (%> (rect-y2 a) (rect-y2 b)) (rect-y2 a) (rect-y2 b))))
    (%- (%* (%- x2 x) (%- y2 y)) (%* (rect-w a) (rect-h a)))))

;; The screen where a window is wants compositing again - it moved, came
;; forward or went away - but nothing in the window has changed.
(define (footprint-damage w) (damage (window-footprint w)))

;; Part of a window, in the window's own coordinates, is finished: what its
;; owner has drawn there becomes what the screen shows. This is the only road
;; from the bitmap a window is drawn in to the one it is shown from, so a
;; picture part way through being drawn is never on the screen part way
;; through.
(define (window-damage-rect win x y w h)
  (bm-blit-rect (win-bm win) (win-front win) x y x y w h)
  (damage (rect (%+ (win-x win) x) (%+ (win-y win) y) w h)))

;; All of it, and the shadow it throws.
(define (window-damage w)
  (bm-blit-rect (win-bm w) (win-front w) 0 0 0 0 (win-w w) (win-h w))
  (damage (window-footprint w)))

;; The frame and nothing inside it: the title bar and the three bands, which
;; is everything `window-frame` draws. Coming forward or losing the front
;; changes those alone, and the interior may be half way through a picture
;; its owner has not finished.
(define (window-damage-frame w)
  (let ((ww (win-w w)) (h (win-h w)))
    (window-damage-rect w 0 0 ww pt-title-h)
    (window-damage-rect w 0 pt-title-h pt-band (%- h pt-title-h))
    (window-damage-rect w (%- ww pt-band) pt-title-h pt-band (%- h pt-title-h))
    (window-damage-rect w 0 (%- h pt-band) ww pt-band)))

(define (draw-frame rp x y w h)
  ;; Two lines and two colours, which is all a raised edge ever was.
  (draw-line rp x y (%+ x (%- w 1)) y wb-light)
  (draw-line rp x y x (%+ y (%- h 1)) wb-light)
  (draw-line rp (%+ x (%- w 1)) y (%+ x (%- w 1)) (%+ y (%- h 1)) wb-shadow)
  (draw-line rp x (%+ y (%- h 1)) (%+ x (%- w 1)) (%+ y (%- h 1)) wb-shadow))

;; A window draws through its own rastport - the one it was made with, which
;; is clipped to its own bitmap. Anybody holding the window can ask for it.
(define (window-draw win)
  (let ((rp (window-rastport win))
        (w (win-w win))
        (h (win-h win))
        (front (%eq? win (front-window))))
    (window-frame rp win w h front)
    (fill-rect rp (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (win-inner-h win) wb-back)
    ;; The refresh closure is given the window, not the rastport: it may want
    ;; to know where it is, how big it is, and what it is showing, and the
    ;; rastport is one call away.
    (if (win-refresh win)
        (%funcall (win-refresh win) win)
        nil)
    (window-damage win)
    nil))

;; The chrome and nothing else. Coming forward or losing the front changes the
;; frame and not one pixel of what the window is showing - and a window whose
;; contents took a minute to compute would rather not be asked for them again
;; because somebody clicked on something else.
(define (window-draw-frame win)
  (window-frame (window-rastport win) win
                (win-w win) (win-h win)
                (%eq? win (front-window)))
  (window-damage-frame win)
  nil)

;; The Platinum frame: a #CC face inside a black outline, raised six-pixel
;; bands down the sides and along the bottom, a striped title bar with a box
;; at each end, and a black border round the content.
;;
;; An inactive window keeps the face and loses everything else - no stripes,
;; no boxes, grey text, a #55 outline. That is the whole of how Mac OS said
;; "this one is not listening".
(define (window-frame rp win w h front)
  (let* ((outline (if front pt-black pt-g10))
         (close-x pt-box-x)
         (zoom-x (%- w (%+ pt-box-x pt-box)))
         (title (text-truncate (win-title win)
                               (%- (%- zoom-x close-x) 40)))
         (tw (text-width title))
         (tx (let ((c (%/ (%- w tw) 2)))
               (if (%< c (%+ close-x 20)) (%+ close-x 20) c))))
    ;; The bands, not the whole rectangle: the interior belongs to whoever
    ;; owns the window, and coming forward must not cost them their picture.
    (fill-rect rp 0 0 w pt-title-h pt-g3)
    (fill-rect rp 0 pt-title-h pt-band (%- h pt-title-h) pt-g3)
    (fill-rect rp (%- w pt-band) pt-title-h pt-band (%- h pt-title-h) pt-g3)
    (fill-rect rp 0 (%- h pt-band) w pt-band pt-g3)
    (pt-frame rp 0 0 w h outline)
    (if front
        (begin
          ;; The raised bands: white outside, #99 inside.
          (pt-hline rp 1 1 (%- w 2) pt-white)
          (pt-vline rp 1 1 (%- h 2) pt-white)
          (pt-vline rp (%- w 2) 2 (%- h 3) pt-g6)
          (pt-hline rp 2 (%- h 2) (%- w 3) pt-g6)
          (pt-hline rp 4 (%- pt-title-h 2) (%- w 8) pt-g6)
          (pt-vline rp 4 (%- pt-title-h 2) (%- h (%+ pt-title-h 2)) pt-g6)
          (pt-stripes rp (%+ close-x (%+ pt-box 5)) 4
                      (%- (%- zoom-x 4) (%+ close-x (%+ pt-box 5)))
                      (list (list (%- tx 7) (%+ (%+ tx tw) 7))))
          (pt-title-box rp close-x pt-box-y 0)
          (pt-title-box rp zoom-x pt-box-y 1)
          (draw-text rp tx 4 title pt-black nil))
        (draw-text rp tx 4 title pt-g7 nil))
    ;; The content border, one pixel of outline round the interior.
    (pt-frame rp (%- (win-inner-x win) 1) (%- (win-inner-y win) 1)
              (%+ (win-inner-w win) 2) (%+ (win-inner-h win) 2) outline)
    nil))

(define (draw-desktop rp)
  (fill-rect rp 0 0 (bm-w *screen*) (bm-h *screen*) pt-desktop)
  ;; A menu bar with nothing in the menus yet, which is honest enough.
  (fill-rect rp 0 0 (bm-w *screen*) pt-menubar-h pt-g2)
  (pt-hline rp 0 (%- pt-menubar-h 1) (bm-w *screen*) pt-g6)
  (draw-text rp pt-menubar-first-x 3 "Workbench" pt-black nil)
  nil)

;; ---------------------------------------------------------------- composite
;; Front to back, into the screen, over whatever was damaged - and every pixel
;; written once. A window is copied only where nothing in front of it lands,
;; its shadow likewise, and the desktop only where no window or shadow does.
;;
;; It used to go back to front and let whatever came last win: the desktop
;; over the whole damaged rectangle, then every window over that. What that
;; ended with was right, and the way there was not. The blitter is charged a
;; cycle a pixel, ten windows' worth of fill and copy is more than a frame,
;; and the display caught it part way - a window gone to desktop grey, or
;; showing the one behind it - which at sixty frames a second is flicker.
;; Written once, a pixel the display catches early is old, never wrong.
;;
;; No critical section. There was one here for a long time, held across the
;; whole body, and it was covering for a race in the allocator rather than for
;; anything in this loop: two tasks could come back from a refill holding the
;; same run of cons space, and the compositor was where the wreckage showed up.
;;
;; Windows are copied from their front bitmaps, which change only when an
;; owner says a part is finished - see `window-damage-rect`.
;;
;; Most damage lies wholly inside the frontmost window it touches - a pupil,
;; a character, a window's own frame - and is then that window's pixels and
;; nobody else's: one copy, with no region to work out and nothing made. A
;; window's footprint, shadow included, is what counts as touching, so that a
;; shadow falling across the damage sends it the long way round.
(define (composite r)
  (let ((rx (rect-x r)) (ry (rect-y r))
        (rx2 (rect-x2 r)) (ry2 (rect-y2 r))
        (hit nil)                   ; the frontmost window r touches
        (l *windows*))
    (while (if hit nil (%cons? l))
      (let ((w (%car l)))
        (if (if (%< rx (%+ (win-x w) (%+ (win-w w) 1)))
                (if (%< (win-x w) rx2)
                    (if (%< ry (%+ (win-y w) (%+ (win-h w) 1))) (%< (win-y w) ry2) nil)
                    nil)
                nil)
            (set! hit w)
            nil))
      (set! l (%cdr l)))
    (if (if hit
            (if (%>= rx (win-x hit))
                (if (%>= ry (win-y hit))
                    (if (%<= rx2 (%+ (win-x hit) (win-w hit)))
                        (%<= ry2 (%+ (win-y hit) (win-h hit)))
                        nil)
                    nil)
                nil)
            nil)
        (bm-blit-rect (win-front hit) *screen*
                      (%- rx (win-x hit)) (%- ry (win-y hit))
                      rx ry (rect-w r) (rect-h r))
        (composite-pieces r)))
  nil)

;; Everything else, front to back and every pixel once.
(define (composite-pieces r)
  (let ((spoken-for nil))           ; what something in front has taken of r
    (dolist (w *windows*)           ; front to back
      (let ((x (win-x w)) (y (win-y w)) (ww (win-w w)) (wh (win-h w)))
        (set! spoken-for (composite-part r spoken-for x y ww wh w))
        ;; Its shadow, a column down the right and a row along the bottom,
        ;; falls on whatever is behind it - so it goes in now, before
        ;; anything behind can claim those pixels.
        (set! spoken-for (composite-part r spoken-for (%+ x ww) (%+ y 2) 1 (%- wh 1) nil))
        (set! spoken-for (composite-part r spoken-for (%+ x 2) (%+ y wh) (%- ww 1) 1 nil))))
    ;; And the desktop, wherever nothing else went: through a rastport clipped
    ;; to exactly that.
    (let ((bare (region-subtract (list r) spoken-for)))
      (if bare (draw-desktop (make-rastport-on *screen* 0 0 bare)) nil)))
  nil)

;; One thing on the screen - a window, or a strip of its shadow when `win` is
;; nil - painted wherever it meets r and nothing in front of it already has,
;; and added to what is spoken for. Nothing is made unless the two meet, and
;; most windows do not meet most damage: this used to build every window's
;; rectangle and both of its shadow's for every rectangle of damage, and at
;; twenty rectangles a frame that was most of what the workbench allocated.
(define (composite-part r spoken-for x y w h win)
  (let ((i (rect-cut r x y w h)))
    (if i
        (begin
          (dolist (piece (region-subtract (list i) spoken-for))
            (if win
                (bm-blit-rect (win-front win) *screen*
                              (%- (rect-x piece) x) (%- (rect-y piece) y)
                              (rect-x piece) (rect-y piece)
                              (rect-w piece) (rect-h piece))
                (bm-fill-rect *screen* (rect-x piece) (rect-y piece)
                              (rect-w piece) (rect-h piece) pt-black)))
          (%cons i spoken-for))
        spoken-for)))

;; What r and the rectangle x y w h have in common, or nil.
(define (rect-cut r x y w h)
  (let ((x0 (if (%> x (rect-x r)) x (rect-x r)))
        (y0 (if (%> y (rect-y r)) y (rect-y r)))
        (x1 (let ((e (%+ x w))) (if (%< e (rect-x2 r)) e (rect-x2 r))))
        (y1 (let ((e (%+ y h))) (if (%< e (rect-y2 r)) e (rect-y2 r)))))
    (if (if (%< x0 x1) (%< y0 y1) nil)
        (rect x0 y0 (%- x1 x0) (%- y1 y0))
        nil)))

;; One pass of the compositor: take whatever damage has accumulated and pay it.
(define (wb-composite)
  (let ((ds (with-mutex *damage-lock* (let ((d *damage*)) (set! *damage* nil) d)))
        (screen (rect 0 0 (bm-w *screen*) (bm-h *screen*))))
    (dolist (d ds)
      (let ((i (rect-intersect d screen)))
        (if i (composite i) nil)))
    nil))

;; Finished drawing: hand the frame over and wait until it has been shown.
;; This is what a drawing task should call instead of a bare wait - the
;; throttling is the same, and the meaning is the handover rather than the
;; clock.
(define (present win)
  (window-damage win)
  (wait-vblank))

;; Everything, from scratch.
(define (wb-repaint)
  (dolist (w *windows*)
    (window-draw w))
  (damage (rect 0 0 (bm-w *screen*) (bm-h *screen*)))
  nil)

;; What actually happens when a window opens, closes, moves or comes forward.
;; Which window was in front last time, because the one that loses the front
;; has to be told: nothing else would repaint its title bar, and it would go
;; on claiming to be active.
(define *front-was* nil)

(define (wb-update)
  ;; The occlusion model is the compositor's, so this only has to say what
  ;; changed. Redrawing a window costs its own bitmap and nothing else.
  (if (%eq? *front-was* (front-window))
      nil
      (begin
        (if (if *front-was* (memq *front-was* *windows*) nil)
            (window-draw-frame *front-was*)
            nil)
        (if (front-window) (window-draw-frame (front-window)) nil)
        (set! *front-was* (front-window))))
  (dolist (w *windows*) (footprint-damage w))
  nil)

;; ---------------------------------------------------------------- surfaces
;; A window whose interior is exactly w by h, staggered like a shell, plus the
;; two calls something drawing pixel by pixel wants: straight at the bitmap,
;; because a plot that walks a clipping region is a plot that costs more in
;; bookkeeping than in pixels.
(define (make-demo-window w h title)
  (let* ((n (length *windows*))
         (win (make-window (%+ 40 (%* n 24)) (%+ 40 (%* n 20))
                           (%+ w (%* 2 pt-band))
                           (%+ h (%+ pt-title-h pt-band))
                           title)))
    (window-open win)
    win))

(define (win-plot win x y c)
  (bm-plot (window-bitmap win)
           (%+ x (win-inner-x win)) (%+ y (win-inner-y win)) c))

(define (win-point win x y)
  (bm-point (window-bitmap win)
            (%+ x (win-inner-x win)) (%+ y (win-inner-y win))))

(define (win-fill win x y w h c)
  (bm-fill-rect (window-bitmap win)
                (%+ x (win-inner-x win)) (%+ y (win-inner-y win)) w h c))

;; Where a row of the interior starts, for the things that walk memory.
(define (win-row win y)
  (bm-at (window-bitmap win) (win-inner-x win) (%+ y (win-inner-y win))))

;; The window list is read by the compositor and written by whoever opens,
;; closes or raises a window. It is never changed in place - every change
;; builds a new list and puts it in `*windows*` with one store - so a reader
;; takes it as it stands and needs no lock at all. The writers take
;; `*windows-lock*` against each other: two raises at once would each build
;; from the list as it was before the other, and one of them would be lost.
(define *windows-lock* (make-mutex "windows"))

(define (window-open win)
  (with-mutex *windows-lock* (set! *windows* (%cons win *windows*)))
  (window-draw win)
  (wb-update)
  win)

(define (window-close win)
  (with-mutex *windows-lock* (set! *windows* (remove-eq win *windows*)))
  (let ((task (win-task win)))
    (if task (begin (rem-task task) (set-win-task! win nil)) nil))
  ;; The hole it leaves has to be repainted.
  ;;
  ;; And the bitmap is left exactly where it is. This used to hand the pixels
  ;; back with `free-pool` and then null the field, and both halves were
  ;; wrong: the compositor reads window bitmaps outside any critical section,
  ;; so it can be part way through this window right now - reading pool memory
  ;; that has been given away, or asking a null bitmap how wide it is.
  ;;
  ;; Now the pixels are a byte object. A compositor holding the old window
  ;; list draws one more stale frame from a bitmap that is still perfectly
  ;; valid, the damage above repaints over it, and the collector takes the
  ;; pixels when the last reference to them goes - which is the whole answer
  ;; rather than a smaller window in which to be wrong.
  ;;
  ;; The footprint, not the rectangle: the rectangle left the shadow behind, an
  ;; outline of the closed window along its right and bottom edges.
  (footprint-damage win)
  (wb-update)
  nil)

(define (window-to-front win)
  (if (%eq? win (front-window))
      nil
      (begin
        (with-mutex *windows-lock*
          (set! *windows* (%cons win (remove-eq win *windows*))))
        (wb-update))))

(define (window-at x y)
  (let ((found nil))
    (dolist (w *windows*)
      (if found
          nil
          (if (if (%>= x (win-x w))
                  (if (%< x (%+ (win-x w) (win-w w)))
                      (if (%>= y (win-y w))
                          (%< y (%+ (win-y w) (win-h w)))
                          nil)
                      nil)
                  nil)
              (set! found w)
              nil)))
    found))

(define (in-title? win x y)
  (if (%< y (%+ (win-y win) (%+ title-height 1)))
      (%>= y (win-y win))
      nil))

;; The box `window-frame` draws at the left end of the title bar. This used to
;; test the right end instead, where the zoom box is drawn: clicking the close
;; box started a drag, and clicking the zoom box closed the window.
(define (in-close-box? win x y)
  (let ((bx (%+ (win-x win) pt-box-x))
        (by (%+ (win-y win) pt-box-y)))
    (if (if (%>= x bx) (%< x (%+ bx pt-box)) nil)
        (if (%>= y by) (%< y (%+ by pt-box)) nil)
        nil)))

;; ---------------------------------------------------------------- keys
;; Keys go to a window as messages, to a port belonging to the task that reads
;; the window - its shell's. The input task sends and never waits; the shell
;; takes them in order when it wants one and sleeps on the port when there are
;; none, and a shell that has ended has its keys answered with a failure that
;; nobody is waiting to hear. A window nobody reads has no port, and a key sent
;; to it goes nowhere - which is better than the queue it used to grow for ever.
;;
;; It was a list that both tasks read and rewrote, and then the same list with
;; a Forbid at both ends, after keys typed at a program's speed came through
;; dropped or doubled. A queue two tasks share is what a port already is.
(define (window-push-key win c)
  (let ((p (win-keys win)))
    (if p (send p c) nil))
  nil)

(define (window-pop-key win)
  (let ((p (win-keys win)))
    (if p
        (let ((m (get-msg p))) (if m (message-body m) nil))
        nil)))

;; ---------------------------------------------------------------- shells
;; A shell keeps characters, not pixels: a grid it can redraw from, which is
;; what lets it live on the shared bitmap with no backing store of its own.
(defrecord (shell sh) cols rows grid col row)

(define (shell-clear sh)
  (let ((g (sh-grid sh)) (i 0))
    (while (%< i (bytes-length g))
      (bytes-set! g i 32)
      (set! i (%+ i 1)))
    (set-sh-col! sh 0)
    (set-sh-row! sh 0)
    nil))

(define (make-shell cols rows)
  (let ((v (sh-alloc)))
    (set-sh-cols! v cols)
    (set-sh-rows! v rows)
    (set-sh-grid! v (make-bytes (%* cols rows)))
    (shell-clear v)
    v))

(define (shell-cell-x win col) (%+ (win-inner-x win) (%* col mono-advance)))
(define (shell-cell-y win row) (%+ (win-inner-y win) (%* row mono-height)))

(define (shell-scroll rp win sh)
  ;; The grid moves up a line and so does the picture: the blitter copies the
  ;; interior over itself, which it is allowed to do because it knows which
  ;; way to walk when source and destination overlap.
  (let* ((g (sh-grid sh))
         (cols (sh-cols sh))
         (rows (sh-rows sh))
         (n (%* cols (%- rows 1)))
         (i 0))
    (while (%< i n)
      (bytes-set! g i (bytes-ref g (%+ i cols)))
      (set! i (%+ i 1)))
    (while (%< i (%* cols rows))
      (bytes-set! g i 32)
      (set! i (%+ i 1)))
    (blit-rect rp (win-inner-x win) (%+ (win-inner-y win) mono-height)
               (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (%- (win-inner-h win) mono-height))
    (fill-rect rp (win-inner-x win)
               (%+ (win-inner-y win) (%* (%- rows 1) mono-height))
               (win-inner-w win) mono-height wb-back)
    (window-damage-rect win (win-inner-x win) (win-inner-y win)
                        (win-inner-w win) (win-inner-h win))
    (set-sh-row! sh (%- rows 1))
    nil))

(define (shell-newline rp win sh)
  (set-sh-col! sh 0)
  (set-sh-row! sh (%+ (sh-row sh) 1))
  (if (%>= (sh-row sh) (sh-rows sh))
      (shell-scroll rp win sh)
      nil))

(define (shell-poke sh c)
  (bytes-set! (sh-grid sh)
              (%+ (%* (sh-row sh) (sh-cols sh))
                  (sh-col sh))
              c))

(define (shell-putc win sh c)
  ;; Aimed at the window, because the window is what it was given: a shell
  ;; stream writes into the window it belongs to whatever task is holding it.
  ;; What changes is handed over as it changes - the cell, or the whole
  ;; interior when it scrolls - rather than the whole window a character.
  (shell-putc-1 (window-rastport win) win sh c)
  nil)

(define (shell-cell-done win sh)
  (window-damage-rect win (shell-cell-x win (sh-col sh)) (shell-cell-y win (sh-row sh))
                      mono-advance mono-height))

(define (shell-putc-1 rp win sh c)
  (cond
   ((%eq? c #\newline) (shell-newline rp win sh))
   ((%eq? c (%int->char 13)) nil)
   ((%eq? c #\backspace)
    ;; Backspace erases, because a prompt you cannot correct is a toy.
    (if (%> (sh-col sh) 0)
        (begin
          (set-sh-col! sh (%- (sh-col sh) 1))
          (shell-poke sh (%char->int #\space))
          (fill-rect rp (shell-cell-x win (sh-col sh))
                     (shell-cell-y win (sh-row sh))
                     mono-advance mono-height wb-back)
          (shell-cell-done win sh))
        nil))
   (else
    (if (%>= (sh-col sh) (sh-cols sh))
        (shell-newline rp win sh)
        nil)
    (shell-poke sh (%char->int c))
    (draw-mono-char rp (shell-cell-x win (sh-col sh))
               (shell-cell-y win (sh-row sh))
               c wb-text wb-back)
    (shell-cell-done win sh)
    (set-sh-col! sh (%+ (sh-col sh) 1))))
  nil)

(define (shell-refresh win)
  ;; Everything the window knows, drawn again. This is what buys the absence
  ;; of a backing store.
  (let* ((sh (win-data win))
         (rp (window-rastport win))
         (g (sh-grid sh))
         (cols (sh-cols sh))
         (rows (sh-rows sh))
         (r 0))
    (while (%< r rows)
      (let ((c 0))
        (while (%< c cols)
          (let ((ch (bytes-ref g (%+ (%* r cols) c))))
            (if (%= ch 32)
                nil
                (draw-mono-char rp (shell-cell-x win c) (shell-cell-y win r)
                           (%int->char ch) wb-text nil)))
          (set! c (%+ c 1))))
      (set! r (%+ r 1)))
    nil))

(define (shell-stream win sh)
  ;; Reading echoes. On the serial line the terminal at the other end does
  ;; that; here there is no other end, so the shell has to show you what you
  ;; typed itself.
  (make-stream
   (lambda (c) (shell-putc win sh c))
   (lambda ()
     (let ((k (window-pop-key win)))
       (if k
           (let ((c (%int->char k))) (shell-putc win sh c) c)
           nil)))
   ;; Nothing to read: sleep until a key is sent.
   (lambda () (wait (port-signal (win-keys win))))))

(define (new-shell . opts)
  ;; A window with a prompt in it, and a task of its own to run the prompt.
  (let* ((n (length *windows*))
         (x (%+ 20 (%* n 18)))
         (y (%+ 24 (%* n 16)))
         (w (if (%cons? opts) (%car opts) 380))
         (h (if (if (%cons? opts) (%cons? (%cdr opts)) nil) (cadr opts) 200))
         (win (make-window x y w h "Shell"))
         (cols (%/ (%- w 4) mono-advance))
         (rows (%/ (%- h (%+ title-height 3)) mono-height))
         (sh (make-shell cols rows)))
    (set-win-data! win sh)
    (set-win-refresh! win (lambda (v) (shell-refresh v)))
    ;; The task and its port before the window is on the screen, so that no
    ;; key can arrive at it before there is somewhere for the key to go.
    (let ((task (start-repl "shell" (shell-stream win sh))))
      (set-win-keys! win (create-port-for task nil 0))
      (set-win-task! win task))
    (window-open win)
    win))

;; ---------------------------------------------------------------- input
;; One task turns events into window operations: clicks choose and drag, keys
;; go to whichever window is in front. Nothing else in the system has to know
;; that a mouse exists.
(define *drag-win* nil)
(define *drag-dx* 0)
(define *drag-dy* 0)

(define (wb-button-down x y)
  (let ((w (window-at x y)))
    (if (%null? w)
        nil
        (begin
          (window-to-front w)
          (if (in-close-box? w x y)
              (window-close w)
              (if (in-title? w x y)
                  (begin
                    (set! *drag-win* w)
                    (set! *drag-dx* (%- x (win-x w)))
                    (set! *drag-dy* (%- y (win-y w))))
                  nil))))))

(define (wb-drag x y)
  (if *drag-win*
      (let ((nx (clamp (%- x *drag-dx*) 0
                       (%- (bm-w *screen*) (win-w *drag-win*))))
            (ny (clamp (%- y *drag-dy*) 20
                       (%- (bm-h *screen*) (win-h *drag-win*))))
            ;; The footprint, shadow included: the rectangle alone left the
            ;; shadow's column and row behind at every step of a drag, a
            ;; staircase of one-pixel lines across the desktop.
            (was (window-footprint *drag-win*)))
        (if (if (%= nx (win-x *drag-win*))
                (%= ny (win-y *drag-win*))
                nil)
            nil
            (begin
              (set-win-x! *drag-win* nx)
              (set-win-y! *drag-win* ny)
              ;; The pixels have not changed - only where they go. Damage
              ;; both ends: what the window has uncovered and where it is now.
              (damage was)
              (footprint-damage *drag-win*))))
      nil))

;; An event as input.driver sends it: `(key down ascii code mods)`, `(button
;; down n x y)`, `(mouse moved x y)` and so on.
(define (wb-event e)
  (let ((what (%car e)) (how (cadr e)))
    (cond
     ((%eq? what 'key)
      (if (%eq? how 'down)
          (let ((a (caddr e)) (f (front-window)))
            (if (if f (%> a 0) nil) (window-push-key f a) nil))
          nil))
     ((%eq? what 'button)
      (if (%eq? how 'down)
          (wb-button-down (cadddr e) (nth 4 e))
          (set! *drag-win* nil)))
     ((%eq? what 'mouse) (wb-drag (caddr e) (cadddr e)))
     (else nil))))

;; The compositor. One pass a frame, and only if something changed - a task
;; that draws nothing costs nothing, and a task that draws too fast is held to
;; the display's rate by `present` rather than by a clock it has to remember
;; to look at.
(define (wb-compositor-task)
  (while *wb-running*
    (wait-vblank)
    (wb-composite))
  nil)

(define (wb-input-task)
  ;; One message per event, from input.driver, and asleep in between. This
  ;; used to read the chip itself, which made it the only task that could.
  (let ((port (input-listen)))
    (while *wb-running*
      (wb-event (next-input port)))
    (input-unlisten port))
  nil)

;; ---------------------------------------------------------------- startup
;; A resumed image has the windows and none of the tasks that were running
;; them: Exec is rebuilt from nothing, so the compositor, the input task and
;; every shell's prompt are gone. The pixels are still there and mean nothing.
;;
;; So the workbench restarts rather than pretends. What it keeps is the screen
;; it already has.
(define (wb-resume)
  (if *wb-running*
      (begin
        (attach-screen)
        (workbench))
      nil))

(define (workbench)
  (if (%null? *screen*) (open-screen screen-width screen-height) nil)
  (if (%null? *font*) (begin (font-init) (mono-init)) nil)
  (platinum-palette)
  (set! *windows* nil)
  (set! *wb-running* t)
  (set! *resume-fn* (lambda () (wb-resume)))
  (wb-repaint)
  (add-task "composite" 2 (lambda () (wb-compositor-task)))
  (add-task "input" 1 (lambda () (wb-input-task)))
  (new-shell)
  (emit-str "workbench: a shell is open on the display")
  (newline)
  nil)
