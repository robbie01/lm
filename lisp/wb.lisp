;;; wb.lisp - a workbench: windows, a shell in each, straight to the bitmap.
;;;
;;; There is one bitmap and every window draws into it. No window owns a
;;; backing store, which is what keeps a window down to a few hundred bytes
;;; instead of a quarter of a megabyte, and the price is that a window has to
;;; be able to draw itself again on demand. A shell can, because it keeps the
;;; characters rather than the pixels.
;;;
;;; Repainting is back to front over the window list. That is the whole
;;; occlusion model: no clip rectangles, no damage regions, just an order and
;;; the willingness to draw the lot. At blitter speed a whole screen is well
;;; inside a frame, and the code that results is a page rather than a chapter.

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
  keys                    ; characters waiting, oldest first
  task
  data                    ; whatever the window is for
  rp                      ; where this window draws: its own bitmap
  bm)                     ; and the pool memory that bitmap lives in

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

(define (shadow-rects w)
  (let ((x (win-x w)) (y (win-y w))
        (ww (win-w w)) (wh (win-h w)))
    (list (rect (%+ x ww) (%+ y 2) 1 (%- wh 1))
          (rect (%+ x 2) (%+ y wh) (%- ww 1) 1))))

;; Coordinates inside a window are the window's own: nothing here knows or
;; cares where on the screen it ends up.
(define (win-inner-x w) pt-band)
(define (win-inner-y w) title-height)
(define (win-inner-w w) (%- (win-w w) (%* 2 pt-band)))
(define (win-inner-h w) (%- (win-h w) (%+ title-height pt-band)))

(define (front-window) (if (%cons? *windows*) (%car *windows*) nil))

;; ---------------------------------------------------------------- damage
;; What the compositor owes the screen: one rectangle, grown to cover
;; everything anybody has changed since it last ran. A whole screen is 786,432
;; pixels and the blitter is charged one cycle each, which is more than two
;; frames at sixty hertz - so compositing everything every time is not a thing
;; this machine can afford, and the union of what actually moved is.
(define *damage* nil)      ; a list of rectangles, newest first
(define damage-max 16)      ; beyond which they are all merged into one

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

(define (covered? r)
  ;; Is the damage entirely behind one window? Then the desktop under it does
  ;; not need painting, and the common case - a task damaging its own window -
  ;; costs one blit instead of a screenful of fill.
  (let ((yes nil))
    (dolist (w *windows*)
      (if (if yes nil (rect-covers? (window-rect w) r)) (set! yes t) nil))
    yes))

(define (damage r)
  ;; A list rather than one growing rectangle. Two windows at opposite corners
  ;; have a union that is nearly the whole screen, and a compositor asked to
  ;; repaint the whole screen sixty times a second is a compositor that never
  ;; finishes one - which looks exactly like a window that will not appear.
  ;; Forbid, not Disable. Only tasks ever add damage - the vblank and input
  ;; servers signal, they do not draw - so there is no reason to stop the clock
  ;; and the keyboard for the length of this walk.
  (without-preemption
    ;; Six tasks drawing into one window ask for the same rectangle six times.
    ;; Dropping what is already covered is what keeps the list short enough
    ;; that it never has to be merged into one screen-sized regret.
    (let ((have nil))
      (dolist (d *damage*) (if (rect-covers? d r) (set! have t) nil))
      (if have
          nil
          (begin
            (set! *damage* (%cons r *damage*))
            (if (%> (length *damage*) damage-max)
                (let ((u nil))
                  (dolist (d *damage*) (set! u (rect-union u d)))
                  (set! *damage* (list u)))
                nil)))))
  nil)

(define (window-damage w) (damage (window-footprint w)))

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
  (window-damage win)
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
;; Back to front, into the screen, over whatever was damaged. Overlap needs no
;; arithmetic: a window in front is blitted after the one behind it and simply
;; wins.


;; No critical section. There was one here for a long time, held across the
;; whole body, and it was covering for a race in the allocator rather than for
;; anything in this loop: two tasks could come back from a refill holding the
;; same run of cons space, and the compositor - which allocates a rectangle per
;; window per frame - was where the wreckage showed up.
(define (composite r)
  ;; Filling 1024 by 768 costs 786,432 cycles and a frame is 333,333, so the
  ;; desktop is painted only where it will actually show.
  (if (covered? r)
      nil
      ;; The desktop, through a rastport clipped to this rectangle and nothing
      ;; else - which is what keeps a repaint from painting over the windows.
      (draw-desktop (make-rastport-on *screen* 0 0 (list r))))
  (dolist (w (reverse *windows*))
    (let* ((wr (window-rect w))
           (i (rect-intersect wr r)))
      (if i
          (let ((bm (window-bitmap w))
                (sx (%- (rect-x i) (rect-x wr)))
                (sy (%- (rect-y i) (rect-y wr)))
                (dx (rect-x i))
                (dy (rect-y i))
                (cw (rect-w i))
                (ch (rect-h i)))
            (bm-blit-rect bm *screen* sx sy dx dy cw ch))
          nil)
      ;; And its shadow, clipped to the damage like everything else.
      (dolist (sr (shadow-rects w))
        (let ((si (rect-intersect sr r)))
          (if si
              (bm-fill-rect *screen* (rect-x si) (rect-y si)
                            (rect-w si) (rect-h si) pt-black)
              nil)))))
  nil)

;; One pass of the compositor: take whatever damage has accumulated and pay it.
(define (wb-composite)
  (let ((ds (without-preemption (let ((d *damage*)) (set! *damage* nil) d)))
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
  (dolist (w *windows*) (window-damage w))
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
;; closes or raises a window - all tasks, so Forbid is the lock. Only the
;; read-modify-write is inside it: painting the window is far too long to hold
;; every other task off for.
(define (window-open win)
  (without-preemption (set! *windows* (%cons win *windows*)))
  (window-draw win)
  (wb-update)
  win)

(define (window-close win)
  (without-preemption (set! *windows* (remove-eq win *windows*)))
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
  (damage (window-rect win))
  (wb-update)
  nil)

(define (window-to-front win)
  (if (%eq? win (front-window))
      nil
      (begin
        (without-preemption
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

(define (in-close-box? win x y)
  (if (in-title? win x y)
      (%>= x (%- (%+ (win-x win) (win-w win)) 10))
      nil))

;; ---------------------------------------------------------------- keys
;; One queue per window, oldest first. The input server writes to it and the
;; shell's stream reads from it, which is the whole of the routing.
(define (window-push-key win c)
  (set-win-keys! win (append (win-keys win) (list c)))
  ;; And wake whoever is reading that window. A shell blocked on its keyboard
  ;; should be woken by a keystroke, not by a clock it asks sixty times a
  ;; second whether one has arrived.
  ;; The task may have ended - a shell's prompt is a task and `bye` ends it -
  ;; and a window that outlives its task must not go on signalling it.
  (let ((task (win-task win)))
    (if (if task (task? task) nil)
        (signal task sigf-input)
        (set-win-task! win nil)))
  nil)

(define (window-pop-key win)
  (let ((q (win-keys win)))
    (if (%cons? q)
        (begin (set-win-keys! win (%cdr q)) (%car q))
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
  (shell-putc-1 (window-rastport win) win sh c)
  (window-damage win)
  nil)

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
                     mono-advance mono-height wb-back))
        nil))
   (else
    (if (%>= (sh-col sh) (sh-cols sh))
        (shell-newline rp win sh)
        nil)
    (shell-poke sh (%char->int c))
    (draw-mono-char rp (shell-cell-x win (sh-col sh))
               (shell-cell-y win (sh-row sh))
               c wb-text wb-back)
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
   ;; Nothing to read: sleep until `window-push-key` says otherwise.
   (lambda () (wait sigf-input))))

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
    (window-open win)
    (set-win-task! win (start-repl "shell" (shell-stream win sh)))
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
            (was (window-rect *drag-win*)))
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
              (window-damage *drag-win*))))
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
