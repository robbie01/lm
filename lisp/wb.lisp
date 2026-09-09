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
(define win-slots 11)
(define win-x 0)
(define win-y 1)
(define win-w 2)
(define win-h 3)
(define win-title 4)
(define win-refresh 5)    ; (lambda (w)) draws the interior
(define win-keys 6)       ; characters waiting, oldest first
(define win-task 7)
(define win-data 8)       ; whatever the window is for
(define win-rp 9)        ; where this window draws: its own bitmap
(define win-bm 10)       ; and the pool memory that bitmap lives in

(define *windows* nil)    ; front to back
(define *wb-running* nil)

(define (win-get w i) (%vector-ref w i))
(define (win-set! w i v) (%vector-set! w i v))

(define title-height pt-title-h)

(define (make-window x y w h title)
  ;; A window is a bitmap of its own, and everything it draws goes there
  ;; rather than at the screen. Two windows cannot reach each other however
  ;; wrong their arithmetic is, drawing does not have to be clipped to a
  ;; region that somebody has to keep correct, and the order things appear in
  ;; is decided once, by the compositor, instead of every time anybody paints.
  (let ((v (make-vector-n win-slots nil)))
    (win-set! v win-x x)
    (win-set! v win-y y)
    (win-set! v win-w w)
    (win-set! v win-h h)
    (win-set! v win-title title)
    (win-set! v win-bm (alloc-pool (%* w h)))
    (win-set! v win-rp (make-bitmap-rastport (win-get v win-bm) w h))
    v))

(define (window-rastport w) (win-get w win-rp))
(define (window-bitmap w) (win-get w win-bm))

(define (window-rect w)
  (rect (win-get w win-x) (win-get w win-y) (win-get w win-w) (win-get w win-h)))

;; Coordinates inside a window are the window's own: nothing here knows or
;; cares where on the screen it ends up.
(define (win-inner-x w) pt-band)
(define (win-inner-y w) title-height)
(define (win-inner-w w) (%- (win-get w win-w) (%* 2 pt-band)))
(define (win-inner-h w) (%- (win-get w win-h) (%+ title-height pt-band)))

(define (front-window) (if (%cons? *windows*) (%car *windows*) nil))

;; ---------------------------------------------------------------- damage
;; What the compositor owes the screen: one rectangle, grown to cover
;; everything anybody has changed since it last ran. A whole screen is 786,432
;; pixels and the blitter is charged one cycle each, which is more than two
;; frames at sixty hertz - so compositing everything every time is not a thing
;; this machine can afford, and the union of what actually moved is.
(define *damage* nil)

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

(define (damage r)
  (without-interrupts (set! *damage* (rect-union *damage* r)))
  nil)

(define (window-damage w) (damage (window-rect w)))

(define (draw-frame x y w h)
  ;; Two lines and two colours, which is all a raised edge ever was.
  (draw-line x y (%+ x (%- w 1)) y wb-light)
  (draw-line x y x (%+ y (%- h 1)) wb-light)
  (draw-line (%+ x (%- w 1)) y (%+ x (%- w 1)) (%+ y (%- h 1)) wb-shadow)
  (draw-line x (%+ y (%- h 1)) (%+ x (%- w 1)) (%+ y (%- h 1)) wb-shadow))

;; Draw into a window's bitmap without disturbing the rastport the window's
;; own task is using: a repaint borrows the pixels, it does not take the
;; window over.
(define (draw-in win thunk)
  (let ((saved *rp*))
    (use-rastport (window-rastport win))
    (%funcall thunk)
    (use-rastport saved)
    nil))

(define (window-draw win)
  (let ((w (win-get win win-w))
        (h (win-get win win-h))
        (front (%eq? win (front-window)))
        (saved *rp*))
    (use-rastport (window-rastport win))
    (window-frame win w h front)
    (fill-rect (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (win-inner-h win) wb-back)
    (if (win-get win win-refresh)
        (%funcall (win-get win win-refresh) win)
        nil)
    (use-rastport saved)
    (window-damage win)
    nil))

;; The Platinum frame: a #CC face inside a black outline, raised six-pixel
;; bands down the sides and along the bottom, a striped title bar with a box
;; at each end, and a black border round the content.
;;
;; An inactive window keeps the face and loses everything else - no stripes,
;; no boxes, grey text, a #55 outline. That is the whole of how Mac OS said
;; "this one is not listening".
(define (window-frame win w h front)
  (let* ((outline (if front pt-black pt-g10))
         (close-x pt-box-x)
         (zoom-x (%- w (%+ pt-box-x pt-box)))
         (title (text-truncate (win-get win win-title)
                               (%- (%- zoom-x close-x) 40)))
         (tw (text-width title))
         (tx (let ((c (%/ (%- w tw) 2)))
               (if (%< c (%+ close-x 20)) (%+ close-x 20) c))))
    (fill-rect 0 0 w h pt-g3)
    (pt-frame 0 0 w h outline)
    (if front
        (begin
          ;; The raised bands: white outside, #99 inside.
          (pt-hline 1 1 (%- w 2) pt-white)
          (pt-vline 1 1 (%- h 2) pt-white)
          (pt-vline (%- w 2) 2 (%- h 3) pt-g6)
          (pt-hline 2 (%- h 2) (%- w 3) pt-g6)
          (pt-hline 4 (%- pt-title-h 2) (%- w 8) pt-g6)
          (pt-vline 4 (%- pt-title-h 2) (%- h (%+ pt-title-h 2)) pt-g6)
          (pt-stripes (%+ close-x (%+ pt-box 5)) 4
                      (%- (%- zoom-x 4) (%+ close-x (%+ pt-box 5)))
                      (list (list (%- tx 7) (%+ (%+ tx tw) 7))))
          (pt-title-box close-x pt-box-y 0)
          (pt-title-box zoom-x pt-box-y 1)
          (draw-text tx 4 title pt-black -1))
        (draw-text tx 4 title pt-g7 -1))
    ;; The content border, one pixel of outline round the interior.
    (pt-frame (%- (win-inner-x win) 1) (%- (win-inner-y win) 1)
              (%+ (win-inner-w win) 2) (%+ (win-inner-h win) 2) outline)
    nil))

(define (draw-desktop)
  (fill-rect 0 0 *screen-w* *screen-h* pt-desktop)
  ;; A menu bar with nothing in the menus yet, which is honest enough.
  (fill-rect 0 0 *screen-w* pt-menubar-h pt-g2)
  (pt-hline 0 (%- pt-menubar-h 1) *screen-w* pt-g6)
  (draw-text pt-menubar-first-x 3 "Workbench" pt-black -1)
  nil)

;; ---------------------------------------------------------------- composite
;; Back to front, into the screen, over whatever was damaged. Overlap needs no
;; arithmetic: a window in front is blitted after the one behind it and simply
;; wins.
(define (composite r)
  (let ((saved *rp*))
    (use-rastport (make-rastport-on *screen* *screen-w* *screen-h*
                                    0 0 (list r)))
    (draw-desktop)
    (use-rastport saved))
  (dolist (w (reverse *windows*))
    (let* ((wr (window-rect w))
           (i (rect-intersect wr r)))
      (if i
          (bm-blit-rect (window-bitmap w) (win-get w win-w) (win-get w win-h)
                        *screen* *screen-w* *screen-h*
                        (%- (rect-x i) (rect-x wr)) (%- (rect-y i) (rect-y wr))
                        (rect-x i) (rect-y i) (rect-w i) (rect-h i))
          nil)))
  nil)

;; One pass of the compositor: take whatever damage has accumulated and pay it.
(define (wb-composite)
  (let ((r (without-interrupts (let ((d *damage*)) (set! *damage* nil) d))))
    (if (%null? r)
        nil
        (composite (rect-intersect r (rect 0 0 *screen-w* *screen-h*))))))

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
  (damage (rect 0 0 *screen-w* *screen-h*))
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
            (window-draw *front-was*)
            nil)
        (if (front-window) (window-draw (front-window)) nil)
        (set! *front-was* (front-window))))
  (dolist (w *windows*) (window-damage w))
  nil)

(define (window-open win)
  (set! *windows* (%cons win *windows*))
  (wb-update)
  win)

(define (window-close win)
  (set! *windows* (remove-eq win *windows*))
  (let ((task (win-get win win-task)))
    (if task (rem-task task) nil))
  ;; The hole it leaves has to be repainted before its bitmap goes back.
  (damage (window-rect win))
  (if (win-get win win-bm) (free-pool (win-get win win-bm)) nil)
  (win-set! win win-bm nil)
  (wb-update)
  nil)

(define (window-to-front win)
  (if (%eq? win (front-window))
      nil
      (begin
        (set! *windows* (%cons win (remove-eq win *windows*)))
        (wb-update))))

(define (window-at x y)
  (let ((found nil))
    (dolist (w *windows*)
      (if found
          nil
          (if (if (%>= x (win-get w win-x))
                  (if (%< x (%+ (win-get w win-x) (win-get w win-w)))
                      (if (%>= y (win-get w win-y))
                          (%< y (%+ (win-get w win-y) (win-get w win-h)))
                          nil)
                      nil)
                  nil)
              (set! found w)
              nil)))
    found))

(define (in-title? win x y)
  (if (%< y (%+ (win-get win win-y) (%+ title-height 1)))
      (%>= y (win-get win win-y))
      nil))

(define (in-close-box? win x y)
  (if (in-title? win x y)
      (%>= x (%- (%+ (win-get win win-x) (win-get win win-w)) 10))
      nil))

;; ---------------------------------------------------------------- keys
;; One queue per window, oldest first. The input server writes to it and the
;; shell's stream reads from it, which is the whole of the routing.
(define (window-push-key win c)
  (win-set! win win-keys (append (win-get win win-keys) (list c)))
  ;; And wake whoever is reading that window. A shell blocked on its keyboard
  ;; should be woken by a keystroke, not by a clock it asks sixty times a
  ;; second whether one has arrived.
  (let ((task (win-get win win-task)))
    (if task (signal task sigf-input) nil))
  nil)

(define (window-pop-key win)
  (let ((q (win-get win win-keys)))
    (if (%cons? q)
        (begin (win-set! win win-keys (%cdr q)) (%car q))
        nil)))

;; ---------------------------------------------------------------- shells
;; A shell keeps characters, not pixels: a grid it can redraw from, which is
;; what lets it live on the shared bitmap with no backing store of its own.
(define shell-slots 5)
(define sh-cols 0)
(define sh-rows 1)
(define sh-grid 2)
(define sh-col 3)
(define sh-row 4)

(define (shell-clear sh)
  (let ((g (%vector-ref sh sh-grid)) (i 0))
    (while (%< i (bytes-length g))
      (bytes-set! g i 32)
      (set! i (%+ i 1)))
    (%vector-set! sh sh-col 0)
    (%vector-set! sh sh-row 0)
    nil))

(define (make-shell cols rows)
  (let ((v (make-vector-n shell-slots nil)))
    (%vector-set! v sh-cols cols)
    (%vector-set! v sh-rows rows)
    (%vector-set! v sh-grid (make-bytes (%* cols rows)))
    (shell-clear v)
    v))

(define (shell-cell-x win col) (%+ (win-inner-x win) (%* col mono-advance)))
(define (shell-cell-y win row) (%+ (win-inner-y win) (%* row mono-height)))

(define (shell-scroll win sh)
  ;; The grid moves up a line and so does the picture: the blitter copies the
  ;; interior over itself, which it is allowed to do because it knows which
  ;; way to walk when source and destination overlap.
  (let* ((g (%vector-ref sh sh-grid))
         (cols (%vector-ref sh sh-cols))
         (rows (%vector-ref sh sh-rows))
         (n (%* cols (%- rows 1)))
         (i 0))
    (while (%< i n)
      (bytes-set! g i (bytes-ref g (%+ i cols)))
      (set! i (%+ i 1)))
    (while (%< i (%* cols rows))
      (bytes-set! g i 32)
      (set! i (%+ i 1)))
    (blit-rect (win-inner-x win) (%+ (win-inner-y win) mono-height)
               (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (%- (win-inner-h win) mono-height))
    (fill-rect (win-inner-x win)
               (%+ (win-inner-y win) (%* (%- rows 1) mono-height))
               (win-inner-w win) mono-height wb-back)
    (%vector-set! sh sh-row (%- rows 1))
    nil))

(define (shell-newline win sh)
  (%vector-set! sh sh-col 0)
  (%vector-set! sh sh-row (%+ (%vector-ref sh sh-row) 1))
  (if (%>= (%vector-ref sh sh-row) (%vector-ref sh sh-rows))
      (shell-scroll win sh)
      nil))

(define (shell-poke sh c)
  (bytes-set! (%vector-ref sh sh-grid)
              (%+ (%* (%vector-ref sh sh-row) (%vector-ref sh sh-cols))
                  (%vector-ref sh sh-col))
              c))

(define (shell-putc win sh c)
  ;; Aimed at the window rather than wherever the task happened to be
  ;; pointing, and no closure to do it: this runs once per character.
  (let ((saved *rp*))
    (use-rastport (window-rastport win))
    (shell-putc-1 win sh c)
    (use-rastport saved))
  (window-damage win)
  nil)

(define (shell-putc-1 win sh c)
  (cond
   ((%= c 10) (shell-newline win sh))
   ((%= c 13) nil)
   ((%= c 8)
    ;; Backspace erases, because a prompt you cannot correct is a toy.
    (if (%> (%vector-ref sh sh-col) 0)
        (begin
          (%vector-set! sh sh-col (%- (%vector-ref sh sh-col) 1))
          (shell-poke sh 32)
          (fill-rect (shell-cell-x win (%vector-ref sh sh-col))
                     (shell-cell-y win (%vector-ref sh sh-row))
                     mono-advance mono-height wb-back))
        nil))
   (else
    (if (%>= (%vector-ref sh sh-col) (%vector-ref sh sh-cols))
        (shell-newline win sh)
        nil)
    (shell-poke sh c)
    (draw-mono-char (shell-cell-x win (%vector-ref sh sh-col))
               (shell-cell-y win (%vector-ref sh sh-row))
               (%int->char c) wb-text wb-back)
    (%vector-set! sh sh-col (%+ (%vector-ref sh sh-col) 1))))
  nil)

(define (shell-refresh win)
  ;; Everything the window knows, drawn again. This is what buys the absence
  ;; of a backing store.
  (let* ((sh (win-get win win-data))
         (g (%vector-ref sh sh-grid))
         (cols (%vector-ref sh sh-cols))
         (rows (%vector-ref sh sh-rows))
         (r 0))
    (while (%< r rows)
      (let ((c 0))
        (while (%< c cols)
          (let ((ch (bytes-ref g (%+ (%* r cols) c))))
            (if (%= ch 32)
                nil
                (draw-mono-char (shell-cell-x win c) (shell-cell-y win r)
                           (%int->char ch) wb-text -1)))
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
           (begin (shell-putc win sh k) (%int->char k))
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
    (win-set! win win-data sh)
    (win-set! win win-refresh (lambda (v) (shell-refresh v)))
    (window-open win)
    (win-set! win win-task (start-repl "shell" (shell-stream win sh)))
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
                    (set! *drag-dx* (%- x (win-get w win-x)))
                    (set! *drag-dy* (%- y (win-get w win-y))))
                  nil))))))

(define (wb-drag x y)
  (if *drag-win*
      (let ((nx (clamp (%- x *drag-dx*) 0
                       (%- *screen-w* (win-get *drag-win* win-w))))
            (ny (clamp (%- y *drag-dy*) 20
                       (%- *screen-h* (win-get *drag-win* win-h))))
            (was (window-rect *drag-win*)))
        (if (if (%= nx (win-get *drag-win* win-x))
                (%= ny (win-get *drag-win* win-y))
                nil)
            nil
            (begin
              (win-set! *drag-win* win-x nx)
              (win-set! *drag-win* win-y ny)
              ;; The pixels have not changed - only where they go. Damage
              ;; both ends: what the window has uncovered and where it is now.
              (damage was)
              (window-damage *drag-win*))))
      nil))

(define (wb-event e)
  (let ((kind (event-kind e)))
    (cond
     ((%= kind ev-keydown)
      (let ((a (event-ascii e)) (f (front-window)))
        (if (if f (%> a 0) nil) (window-push-key f a) nil)))
     ((%= kind ev-buttondown) (wb-button-down (mouse-x) (mouse-y)))
     ((%= kind ev-buttonup) (set! *drag-win* nil))
     ((%= kind ev-mousemove) (wb-drag (mouse-x) (mouse-y)))
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
  ;; Drain whatever has arrived, then sleep until the device says there is
  ;; more. This used to ask again as fast as the processor could be handed
  ;; back, which was most of what the machine did while it looked idle.
  (input-listen (this-task))
  (while *wb-running*
    (let ((n (input-pending)))
      (if (%> n 0)
          (let ((i 0))
            (while (%< i n)
              (wb-event (input-event))
              (set! i (%+ i 1))))
          (wait-input))))
  nil)

;; ---------------------------------------------------------------- startup
(define (workbench)
  (if (%null? *screen*) (open-screen screen-width screen-height) nil)
  (if (%null? *font*) (begin (font-init) (mono-init)) nil)
  (platinum-palette)
  (set! *windows* nil)
  (set! *wb-running* t)
  (wb-repaint)
  (add-task "composite" 2 (lambda () (wb-compositor-task)))
  (add-task "input" 1 (lambda () (wb-input-task)))
  (new-shell)
  (emit-str "workbench: a shell is open on the display")
  (newline)
  nil)
