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
(define wb-desktop 13)
(define wb-face 12)
(define wb-shadow 11)
(define wb-light 1)
(define wb-text 1)
(define wb-back 0)
(define wb-title-on 4)
(define wb-title-off 11)
(define wb-title-text-on 1)
(define wb-title-text-off 0)

;; ---------------------------------------------------------------- text
;; A glyph is written a pixel at a time. Sixty four stores a character sounds
;; extravagant until you count them: a whole screen of text is about a
;; millisecond, and nothing else has to exist for it to work.
(define (draw-char x y ch fg bg)
  (let ((row 0))
    (while (%< row font-cell)
      (let ((bits (font-row ch row))
            (col 0))
        (while (%< col 5)
          (if (%= 1 (%logand (%lsh bits (%- col 4)) 1))
              (plot (%+ x col) (%+ y row) fg)
              (if (%>= bg 0) (plot (%+ x col) (%+ y row) bg) nil))
          (set! col (%+ col 1)))
        (if (%>= bg 0) (plot (%+ x 5) (%+ y row) bg) nil))
      (set! row (%+ row 1)))
    nil))

(define (draw-text x y s fg bg)
  (let ((i 0) (n (string-length s)))
    (while (%< i n)
      (draw-char (%+ x (%* i font-advance)) y (string-ref s i) fg bg)
      (set! i (%+ i 1)))
    nil))

(define (text-width s) (%* (string-length s) font-advance))

;; ---------------------------------------------------------------- windows
(define win-slots 10)
(define win-x 0)
(define win-y 1)
(define win-w 2)
(define win-h 3)
(define win-title 4)
(define win-refresh 5)    ; (lambda (w)) draws the interior
(define win-keys 6)       ; characters waiting, oldest first
(define win-task 7)
(define win-data 8)       ; whatever the window is for
(define win-spare 9)

(define *windows* nil)    ; front to back
(define *wb-running* nil)

(define (win-get w i) (%vector-ref w i))
(define (win-set! w i v) (%vector-set! w i v))

(define title-height 10)

(define (make-window x y w h title)
  (let ((v (make-vector-n win-slots nil)))
    (win-set! v win-x x)
    (win-set! v win-y y)
    (win-set! v win-w w)
    (win-set! v win-h h)
    (win-set! v win-title title)
    v))

(define (win-inner-x w) (%+ (win-get w win-x) 2))
(define (win-inner-y w) (%+ (win-get w win-y) (%+ title-height 1)))
(define (win-inner-w w) (%- (win-get w win-w) 4))
(define (win-inner-h w) (%- (win-get w win-h) (%+ title-height 3)))

(define (front-window) (if (%cons? *windows*) (%car *windows*) nil))

(define (remove-eq x l)
  (let ((acc nil))
    (dolist (e l) (if (%eq? e x) nil (set! acc (%cons e acc))))
    (reverse acc)))

(define (draw-frame x y w h)
  ;; Two lines and two colours, which is all a raised edge ever was.
  (draw-line x y (%+ x (%- w 1)) y wb-light)
  (draw-line x y x (%+ y (%- h 1)) wb-light)
  (draw-line (%+ x (%- w 1)) y (%+ x (%- w 1)) (%+ y (%- h 1)) wb-shadow)
  (draw-line x (%+ y (%- h 1)) (%+ x (%- w 1)) (%+ y (%- h 1)) wb-shadow))

(define (window-draw win)
  (let* ((x (win-get win win-x))
         (y (win-get win win-y))
         (w (win-get win win-w))
         (h (win-get win win-h))
         (front (%eq? win (front-window))))
    (fill-rect x y w h wb-face)
    (fill-rect (%+ x 1) (%+ y 1) (%- w 2) title-height
               (if front wb-title-on wb-title-off))
    (draw-text (%+ x 3) (%+ y 2) (win-get win win-title)
               (if front wb-title-text-on wb-title-text-off) -1)
    ;; The close box, top right.
    (fill-rect (%+ x (%- w 10)) (%+ y 2) 7 7 wb-face)
    (draw-frame (%+ x (%- w 10)) (%+ y 2) 7 7)
    (fill-rect (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (win-inner-h win) wb-back)
    (draw-frame x y w h)
    (if (win-get win win-refresh)
        (%funcall (win-get win win-refresh) win)
        nil)
    nil))

(define (wb-repaint)
  (fill-rect 0 0 *screen-w* *screen-h* wb-desktop)
  ;; A menu bar with nothing in the menus yet, which is honest enough.
  (fill-rect 0 0 *screen-w* 13 wb-face)
  (draw-text 4 3 "Workbench" wb-back -1)
  (draw-line 0 12 (%- *screen-w* 1) 12 wb-shadow)
  ;; Back to front, so the front window is drawn last and wins.
  (dolist (w (reverse *windows*)) (window-draw w))
  nil)

(define (window-open win)
  (set! *windows* (%cons win *windows*))
  (wb-repaint)
  win)

(define (window-close win)
  (set! *windows* (remove-eq win *windows*))
  (let ((task (win-get win win-task)))
    (if task (rem-task task) nil))
  (wb-repaint)
  nil)

(define (window-to-front win)
  (if (%eq? win (front-window))
      nil
      (begin
        (set! *windows* (%cons win (remove-eq win *windows*)))
        (wb-repaint))))

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

(define (shell-cell-x win col) (%+ (win-inner-x win) (%* col font-advance)))
(define (shell-cell-y win row) (%+ (win-inner-y win) (%* row font-height)))

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
    (blit-rect (win-inner-x win) (%+ (win-inner-y win) font-height)
               (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (%- (win-inner-h win) font-height))
    (fill-rect (win-inner-x win)
               (%+ (win-inner-y win) (%* (%- rows 1) font-height))
               (win-inner-w win) font-height wb-back)
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
                     font-advance font-height wb-back))
        nil))
   (else
    (if (%>= (%vector-ref sh sh-col) (%vector-ref sh sh-cols))
        (shell-newline win sh)
        nil)
    (shell-poke sh c)
    (draw-char (shell-cell-x win (%vector-ref sh sh-col))
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
                (draw-char (shell-cell-x win c) (shell-cell-y win r)
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
   (lambda () (reschedule))))

(define (new-shell . opts)
  ;; A window with a prompt in it, and a task of its own to run the prompt.
  (let* ((n (length *windows*))
         (x (%+ 20 (%* n 18)))
         (y (%+ 24 (%* n 16)))
         (w (if (%cons? opts) (%car opts) 380))
         (h (if (if (%cons? opts) (%cons? (%cdr opts)) nil) (cadr opts) 200))
         (win (make-window x y w h "Shell"))
         (cols (%/ (%- w 4) font-advance))
         (rows (%/ (%- h (%+ title-height 3)) font-height))
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
            (ny (clamp (%- y *drag-dy*) 13
                       (%- *screen-h* (win-get *drag-win* win-h)))))
        (if (if (%= nx (win-get *drag-win* win-x))
                (%= ny (win-get *drag-win* win-y))
                nil)
            nil
            (begin
              (win-set! *drag-win* win-x nx)
              (win-set! *drag-win* win-y ny)
              (wb-repaint))))
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

(define (wb-input-task)
  (while *wb-running*
    (let ((n (input-pending)))
      (if (%> n 0)
          (let ((i 0))
            (while (%< i n)
              (wb-event (input-event))
              (set! i (%+ i 1))))
          (reschedule))))
  nil)

;; ---------------------------------------------------------------- startup
(define (workbench)
  (if (%null? *screen*) (open-screen screen-width screen-height) nil)
  (if (%null? *font*) (font-init) nil)
  (set! *windows* nil)
  (set! *wb-running* t)
  (wb-repaint)
  (add-task "input" 1 (lambda () (wb-input-task)))
  (new-shell)
  (emit-str "workbench: a shell is open on the display")
  (newline)
  nil)
