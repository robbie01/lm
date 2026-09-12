;;; wb.lisp - a workbench: windows, a shell in each, and a compositor.
;;;
;;; Every window has two bitmaps of its own. Its owner draws into the first,
;;; which nothing else looks at; the second is what the screen is made from,
;;; and the only way anything gets from one to the other is the owner saying
;;; that part of its picture is finished: `window-damage-rect`, or
;;; `window-damage` for all of it. The compositor paints the screen from the
;;; second, front to back, over whatever has been damaged since it last ran.
;;; A picture part way through being drawn is never on the screen.

(in-package wb)

;; ---------------------------------------------------------------- windows
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
(define *running* nil)

;; A window draws into a bitmap of its own, so two windows cannot reach each
;; other however wrong their arithmetic is, drawing needs no clipping region
;; that somebody has to keep correct, and the order things appear in is
;; decided once, by the compositor.
(define (make-window x y w h title)
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
;; bottom. It falls on whatever is behind, so the compositor draws it rather
;; than the window, and damage has to cover it or a moved window leaves its
;; shadow behind.
(define (window-footprint w)
  (rect (win-x w) (win-y w)
        (%+ (win-w w) 1) (%+ (win-h w) 1)))

;; Coordinates inside a window are the window's own: nothing here knows or
;; cares where on the screen it ends up.
(define (win-inner-x w) band)
(define (win-inner-y w) title-height)
(define (win-inner-w w) (%- (win-w w) (%* 2 band)))
(define (win-inner-h w) (%- (win-h w) (%+ title-height band)))

(define (front-window) (if (%cons? *windows*) (%car *windows*) nil))

;; ---------------------------------------------------------------- damage
;; What the compositor owes the screen: a short list of rectangles covering
;; everything anybody has changed since it last ran. A whole screen is
;; 786,432 pixels and the blitter is charged one cycle each, which is more
;; than two frames at sixty hertz, so only what moved is composited.
(define *damage* nil)      ; a list of rectangles, newest first
(define damage-max 32)     ; beyond which a new one joins its nearest

;; Every task that draws adds to the list and the compositor empties it, so
;; it is guarded by a mutex: adding damage is a walk of up to thirty-two
;; rectangles, which is long to hold every other task off for, and only the
;; tasks that draw contend for it. A task that ends holding it may have left
;; the list half merged, so the repair is to repaint everything.
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

;; Is b entirely inside a?
(define (rect-covers? a b)
  (if (%<= (rect-x a) (rect-x b))
      (if (%<= (rect-y a) (rect-y b))
          (if (%>= (rect-x2 a) (rect-x2 b)) (%>= (rect-y2 a) (rect-y2 b)) nil)
          nil)
      nil))

;; A list rather than one growing rectangle: two windows at opposite corners
;; have a union that is nearly the whole screen. A rectangle already covered
;; is dropped, which keeps the list short when six tasks draw into one
;; window. When the list is full, r joins whichever rectangle it makes least
;; bigger.
(define (damage r)
  (with-mutex *damage-lock*
    (let ((have nil) (n 0))
      (dolist (d *damage*)
        (if (rect-covers? d r) (set! have t) nil)
        (set! n (%+ n 1)))
      (if have
          nil
          (if (%< n damage-max)
              (set! *damage* (%cons r *damage*))
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

;; The screen where a window is wants compositing again: it moved, came
;; forward or went away, but nothing in the window has changed.
(define (footprint-damage w) (damage (window-footprint w)))

;; Part of a window, in the window's own coordinates, is finished: what its
;; owner has drawn there becomes what the screen shows.
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
    (window-damage-rect w 0 0 ww title-height)
    (window-damage-rect w 0 title-height band (%- h title-height))
    (window-damage-rect w (%- ww band) title-height band (%- h title-height))
    (window-damage-rect w 0 (%- h band) ww band)))

;; A raised edge: two lines and two colours.
(define (draw-frame rp x y w h)
  (draw-line rp x y (%+ x (%- w 1)) y white)
  (draw-line rp x y x (%+ y (%- h 1)) white)
  (draw-line rp (%+ x (%- w 1)) y (%+ x (%- w 1)) (%+ y (%- h 1)) g6)
  (draw-line rp x (%+ y (%- h 1)) (%+ x (%- w 1)) (%+ y (%- h 1)) g6))

;; A window draws through its own rastport, which is clipped to its own
;; bitmap. The refresh closure is given the window, not the rastport: it may
;; want to know where it is, how big it is, and what it is showing.
(define (window-draw win)
  (let ((rp (window-rastport win))
        (w (win-w win))
        (h (win-h win))
        (front (%eq? win (front-window))))
    (window-frame rp win w h front)
    (fill-rect rp (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (win-inner-h win) white)
    (if (win-refresh win)
        (%funcall (win-refresh win) win)
        nil)
    (window-damage win)
    nil))

;; The chrome and nothing else. Coming forward or losing the front changes
;; the frame and not one pixel of what the window is showing.
(define (window-draw-frame win)
  (window-frame (window-rastport win) win
                (win-w win) (win-h win)
                (%eq? win (front-window)))
  (window-damage-frame win)
  nil)

;; The Platinum frame: a #CC face inside a black outline, raised six-pixel
;; bands down the sides and along the bottom, a striped title bar with a box
;; at each end, and a black border round the content. An inactive window
;; keeps the face and loses everything else: no stripes, no boxes, grey
;; text, a #55 outline.
(define (window-frame rp win w h front)
  (let* ((edge (if front black g10))
         (close-x box-x)
         (zoom-x (%- w (%+ box-x box-size)))
         (title (text-truncate (win-title win)
                               (%- (%- zoom-x close-x) 40)))
         (tw (text-width title))
         (tx (let ((c (%/ (%- w tw) 2)))
               (if (%< c (%+ close-x 20)) (%+ close-x 20) c))))
    ;; The bands, not the whole rectangle: the interior belongs to whoever
    ;; owns the window.
    (fill-rect rp 0 0 w title-height g3)
    (fill-rect rp 0 title-height band (%- h title-height) g3)
    (fill-rect rp (%- w band) title-height band (%- h title-height) g3)
    (fill-rect rp 0 (%- h band) w band g3)
    (outline rp 0 0 w h edge)
    (if front
        (begin
          ;; The raised bands: white outside, #99 inside.
          (hline rp 1 1 (%- w 2) white)
          (vline rp 1 1 (%- h 2) white)
          (vline rp (%- w 2) 2 (%- h 3) g6)
          (hline rp 2 (%- h 2) (%- w 3) g6)
          (hline rp 4 (%- title-height 2) (%- w 8) g6)
          (vline rp 4 (%- title-height 2) (%- h (%+ title-height 2)) g6)
          (stripes rp (%+ close-x (%+ box-size 5)) 4
                      (%- (%- zoom-x 4) (%+ close-x (%+ box-size 5)))
                      (list (list (%- tx 7) (%+ (%+ tx tw) 7))))
          (title-box rp close-x box-y 0)
          (title-box rp zoom-x box-y 1)
          (draw-text rp tx 4 title black nil))
        (draw-text rp tx 4 title g7 nil))
    ;; The content border, one pixel of outline round the interior.
    (outline rp (%- (win-inner-x win) 1) (%- (win-inner-y win) 1)
              (%+ (win-inner-w win) 2) (%+ (win-inner-h win) 2) edge)
    nil))

(define (draw-desktop rp)
  (fill-rect rp 0 0 (bm-w *screen*) (bm-h *screen*) desktop)
  ;; A menu bar with nothing in the menus yet.
  (fill-rect rp 0 0 (bm-w *screen*) menubar-height g2)
  (hline rp 0 (%- menubar-height 1) (bm-w *screen*) g6)
  (draw-text rp menubar-first-x 3 "Workbench" black nil)
  nil)

;; ---------------------------------------------------------------- composite-rect
;; Front to back, into the screen, over whatever was damaged, and every pixel
;; written once. A window is copied only where nothing in front of it lands,
;; its shadow likewise, and the desktop only where no window or shadow does.
;; Written once, a pixel the display catches early is old, never wrong.
;;
;; No critical section: windows are copied from their front bitmaps, which
;; change only when an owner says a part is finished.
;;
;; Most damage lies wholly inside the frontmost window it touches, a pupil, a
;; character, a window's own frame, and is then that window's pixels and
;; nobody else's: one copy, with no region to work out and nothing made. A
;; window's footprint, shadow included, is what counts as touching, so that
;; a shadow falling across the damage sends it the long way round.
(define (composite-rect r)
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
        ;; falls on whatever is behind it, so it goes in now, before anything
        ;; behind can claim those pixels.
        (set! spoken-for (composite-part r spoken-for (%+ x ww) (%+ y 2) 1 (%- wh 1) nil))
        (set! spoken-for (composite-part r spoken-for (%+ x 2) (%+ y wh) (%- ww 1) 1 nil))))
    ;; And the desktop, wherever nothing else went, through a rastport
    ;; clipped to exactly that.
    (let ((bare (region-subtract (list r) spoken-for)))
      (if bare (draw-desktop (make-rastport-on *screen* 0 0 bare)) nil)))
  nil)

;; One thing on the screen, a window or a strip of its shadow when `win` is
;; nil, painted wherever it meets r and nothing in front of it already has,
;; and added to what is spoken for. Nothing is made unless the two meet.
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
                              (rect-w piece) (rect-h piece) black)))
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

;; One pass of the compositor: take whatever damage has accumulated and pay
;; it.
(define (composite)
  (let ((ds (with-mutex *damage-lock* (let ((d *damage*)) (set! *damage* nil) d)))
        (screen (rect 0 0 (bm-w *screen*) (bm-h *screen*))))
    (dolist (d ds)
      (let ((i (rect-intersect d screen)))
        (if i (composite-rect i) nil)))
    nil))

;; Finished drawing: hand the frame over and wait until it has been shown.
;; A drawing task calls this instead of a bare wait, so that it is held to
;; the display's rate.
(define (present win)
  (window-damage win)
  (wait-vblank))

;; Everything, from scratch.
(define (repaint)
  (dolist (w *windows*)
    (window-draw w))
  (damage (rect 0 0 (bm-w *screen*) (bm-h *screen*)))
  nil)

;; Which window was in front last time, because the one that loses the front
;; has to be told: nothing else would repaint its title bar.
(define *front-was* nil)

;; What happens when a window opens, closes, moves or comes forward. The
;; occlusion model is the compositor's, so this only says what changed.
(define (update)
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
;; A window whose interior is exactly w by h, staggered like a shell, and
;; the calls something drawing pixel by pixel wants: straight at the bitmap,
;; because a plot that walks a clipping region costs more in bookkeeping than
;; in pixels.
(define (make-demo-window w h title)
  (let* ((n (length *windows*))
         (win (make-window (%+ 40 (%* n 24)) (%+ 40 (%* n 20))
                           (%+ w (%* 2 band))
                           (%+ h (%+ title-height band))
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
;; closes or raises a window. It is never changed in place: every change
;; builds a new list and puts it in `*windows*` with one store, so a reader
;; takes it as it stands and needs no lock. The writers take `*windows-lock*`
;; against each other.
(define *windows-lock* (make-mutex "windows"))

(define (window-open win)
  (with-mutex *windows-lock* (set! *windows* (%cons win *windows*)))
  (window-draw win)
  (update)
  win)

;; The bitmaps are left where they are: a compositor holding the old window
;; list draws one more frame from them, the damage repaints over it, and the
;; collector takes the pixels when the last reference goes. The footprint is
;; damaged, not the rectangle, so the shadow goes too.
(define (window-close win)
  (with-mutex *windows-lock* (set! *windows* (remove-eq win *windows*)))
  (let ((task (win-task win)))
    (if task (begin (remove-task task) (set-win-task! win nil)) nil))
  (footprint-damage win)
  (update)
  nil)

(define (window-to-front win)
  (if (%eq? win (front-window))
      nil
      (begin
        (with-mutex *windows-lock*
          (set! *windows* (%cons win (remove-eq win *windows*))))
        (update))))

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

;; The box `window-frame` draws at the left end of the title bar.
(define (in-close-box? win x y)
  (let ((bx (%+ (win-x win) box-x))
        (by (%+ (win-y win) box-y)))
    (if (if (%>= x bx) (%< x (%+ bx box-size)) nil)
        (if (%>= y by) (%< y (%+ by box-size)) nil)
        nil)))

;; ---------------------------------------------------------------- keys
;; Keys go to a window as messages, to a port belonging to the task that
;; reads the window, its shell's. The input task sends and never waits; the
;; shell takes them in order when it wants one and sleeps on the port when
;; there are none. A window nobody reads has no port, and a key sent to it
;; goes nowhere.
(define (window-push-key win c)
  (let ((p (win-keys win)))
    (if p (send p c) nil))
  nil)

(define (window-pop-key win)
  (let ((p (win-keys win)))
    (if p
        (let ((m (get-message p))) (if m (message-body m) nil))
        nil)))

;; ---------------------------------------------------------------- shells
;; A shell keeps characters, not pixels: a grid it can redraw from.
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

;; The grid moves up a line and so does the picture: the blitter copies the
;; interior over itself, which it may because it walks the right way when
;; source and destination overlap.
(define (shell-scroll rp win sh)
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
               (win-inner-w win) mono-height white)
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

;; Aimed at the window it was given: a shell stream writes into the window
;; it belongs to whatever task is holding it. What changes is handed over as
;; it changes, the cell, or the whole interior when it scrolls.
(define (shell-putc win sh c)
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
    (if (%> (sh-col sh) 0)
        (begin
          (set-sh-col! sh (%- (sh-col sh) 1))
          (shell-poke sh (%char->int #\space))
          (fill-rect rp (shell-cell-x win (sh-col sh))
                     (shell-cell-y win (sh-row sh))
                     mono-advance mono-height white)
          (shell-cell-done win sh))
        nil))
   (else
    (if (%>= (sh-col sh) (sh-cols sh))
        (shell-newline rp win sh)
        nil)
    (shell-poke sh (%char->int c))
    (draw-mono-char rp (shell-cell-x win (sh-col sh))
               (shell-cell-y win (sh-row sh))
               c black white)
    (shell-cell-done win sh)
    (set-sh-col! sh (%+ (sh-col sh) 1))))
  nil)

;; Everything the window knows, drawn again.
(define (shell-refresh win)
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
                           (%int->char ch) black nil)))
          (set! c (%+ c 1))))
      (set! r (%+ r 1)))
    nil))

;; Reading echoes: there is no terminal at the other end to do it.
(define (shell-stream win sh)
  (make-stream
   (lambda (c) (shell-putc win sh c))
   (lambda ()
     (let ((k (window-pop-key win)))
       (if k
           (let ((c (%int->char k))) (shell-putc win sh c) c)
           nil)))
   ;; Nothing to read: sleep until a key is sent.
   (lambda () (wait (port-signal (win-keys win))))))

;; A window with a prompt in it, and a task of its own to run the prompt.
;; The task and its port are made before the window is on the screen, so
;; that no key can arrive before there is somewhere for it to go.
(define (new-shell . opts)
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
    (let ((task (start-repl "shell" (shell-stream win sh))))
      (set-win-keys! win (make-port-for task nil 0))
      (set-win-task! win task))
    (window-open win)
    win))

;; ---------------------------------------------------------------- input
;; One task turns events into window operations: clicks choose and drag, keys
;; go to whichever window is in front.
(define *drag-win* nil)
(define *drag-dx* 0)
(define *drag-dy* 0)

(define (button-down x y)
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

;; The pixels have not changed, only where they go: both ends are damaged,
;; what the window has uncovered and where it is now, footprints included so
;; that the shadow moves too.
(define (drag x y)
  (if *drag-win*
      (let ((nx (clamp (%- x *drag-dx*) 0
                       (%- (bm-w *screen*) (win-w *drag-win*))))
            (ny (clamp (%- y *drag-dy*) 20
                       (%- (bm-h *screen*) (win-h *drag-win*))))
            (was (window-footprint *drag-win*)))
        (if (if (%= nx (win-x *drag-win*))
                (%= ny (win-y *drag-win*))
                nil)
            nil
            (begin
              (set-win-x! *drag-win* nx)
              (set-win-y! *drag-win* ny)
              (damage was)
              (footprint-damage *drag-win*))))
      nil))

;; An event as input.driver sends it: `(key down ascii code mods)`, `(button
;; down n x y)`, `(mouse moved x y)` and so on.
(define (handle-event e)
  (let ((what (%car e)) (how (cadr e)))
    (cond
     ((%eq? what 'input:key)
      (if (%eq? how 'input:down)
          (let ((a (caddr e)) (f (front-window)))
            (if (if f (%> a 0) nil) (window-push-key f a) nil))
          nil))
     ((%eq? what 'input:button)
      (if (%eq? how 'input:down)
          (button-down (cadddr e) (nth 4 e))
          (set! *drag-win* nil)))
     ((%eq? what 'input:mouse) (drag (caddr e) (cadddr e)))
     (else nil))))

;; The compositor: one pass a frame, and only over what changed.
(define (compositor-task)
  (while *running*
    (wait-vblank)
    (composite))
  nil)

;; One message per event from input.driver, and asleep in between.
(define (input-task)
  (let ((port (input:listen)))
    (while *running*
      (handle-event (input:next-event port)))
    (input:unlisten port))
  nil)

;; ---------------------------------------------------------------- startup
;; A resumed image has the windows and none of the tasks that were running
;; them: Exec is rebuilt from nothing, so the compositor, the input task and
;; every shell's prompt are gone. The workbench restarts, keeping the screen
;; it already has.
(define (resume)
  (if *running*
      (begin
        (gfx:attach-screen)
        (workbench))
      nil))

(define (workbench)
  (if (%null? *screen*) (gfx:open-screen screen-width screen-height) nil)
  (if (%null? *font*) (begin (font-init) (mono-init)) nil)
  (palette)
  (set! *windows* nil)
  (set! *running* t)
  (set! *resume-fn* (lambda () (resume)))
  (repaint)
  (add-task "composite-rect" 2 (lambda () (compositor-task)))
  (add-task "input" 1 (lambda () (input-task)))
  (new-shell)
  (emit-str "workbench: a shell is open on the display")
  (newline)
  nil)
