;;; eyes.lisp - xeyes, as a demonstration that an application can have more
;;; than one of itself.
;;;
;;; One pair of eyes is one record, and every function here is handed it.
;;;
;;; It used to be an `instance`: a record the scheduler carried in a register
;;; of its own, so that `window`, `rad` and `px1` could be written as though
;;; they were globals and mean this pair. That read well, and it was a whole
;;; second mechanism for per-task state - its own register, its own trap, its
;;; own rule about what a bare name means inside a package - serving one
;;; application. Passing the record costs a word per call and needs no rules.

(in-package eyes)

(defrecord eyes
  window                       ; the window we live in
  (lx 0) (ly 0)                ; where the eyes are, in window coordinates
  (rx 0) (ry 0)
  (rad 20)                     ; the white of an eye
  (pr 7)                       ; and its pupil
  (px1 -1) (py1 -1)            ; where the pupils are now, so we can tell
  (px2 -1) (py2 -1)            ; when nothing has moved
  (look-x -1) (look-y -1))     ; -1 -1 means follow the mouse

;; One pair of eyes, not yet looking at anything and not yet in a window.
;; `(eyes)` below is the application; this is the record it is built on.
(define (make-eyes) (eyes-alloc))

;; ---------------------------------------------------------------- geometry
;; Recomputed rather than remembered, because the window moves when it is
;; dragged and the eyes have to go with it.
(define (place-eyes e)
  (let* ((win (eyes-window e))
         (w (win-inner-w win))
         (h (win-inner-h win))
         (x (win-inner-x win))
         (y (win-inner-y win))
         (r (%lsh (if (%< w h) w h) -2))
         (rad (if (%< r 8) 8 r))
         (pr (%lsh rad -2)))
    (set-eyes-rad! e rad)
    (set-eyes-pr! e (if (%< pr 3) 3 pr))
    (set-eyes-ly! e (%+ y (%lsh h -1)))
    (set-eyes-ry! e (eyes-ly e))
    (set-eyes-lx! e (%+ x (%- (%lsh w -1) (%+ rad 2))))
    (set-eyes-rx! e (%+ x (%+ (%lsh w -1) (%+ rad 2))))))

;; The mouse is in screen coordinates and the eyes are in the window's, so
;; something has to convert; this is the only place in the application that
;; knows the window is anywhere in particular.
(define (target-x e)
  (%- (if (%< (eyes-look-x e) 0) (mouse-x) (eyes-look-x e))
      (win-x (eyes-window e))))
(define (target-y e)
  (%- (if (%< (eyes-look-y e) 0) (mouse-y) (eyes-look-y e))
      (win-y (eyes-window e))))

;; Where a pupil sits when the eye is looking at a point: along the line to
;; it, and no further out than the white of the eye allows.
(define (pupil-at e cx cy tx ty)
  (let* ((dx (%- tx cx))
         (dy (%- ty cy))
         (reach (%- (eyes-rad e) (%+ (eyes-pr e) 2)))
         (d (isqrt (%+ (%* dx dx) (%* dy dy)))))
    (if (%<= d reach)
        (list tx ty)
        (if (%= d 0)
            (list cx cy)
            (list (%+ cx (%/ (%* dx reach) d))
                  (%+ cy (%/ (%* dy reach) d)))))))

;; ---------------------------------------------------------------- drawing
;; Platinum's own colours rather than the workbench's foreground and
;; background, which are now black on white and would give a black eye.
(define (draw-eye e rp cx cy)
  (fill-circle rp cx cy (eyes-rad e) pt-white)
  (draw-circle rp cx cy (eyes-rad e) pt-black))

(define (draw-pupil e rp x y) (fill-circle rp x y (eyes-pr e) pt-black))

;; Drawing goes through this pair's own window, which is what makes
;; `(look-at w 100 100)` from a prompt safe: it paints into w's bitmap because
;; that is the rastport it hands to every call, not because the calling task
;; happened to be pointed there.
(define (draw-all e) (draw-all-1 e (window-rastport (eyes-window e))))
(define (track e) (track-1 e (window-rastport (eyes-window e))))

(define (draw-all-1 e rp)
  (place-eyes e)
  (let ((win (eyes-window e)))
    (fill-rect rp (win-inner-x win) (win-inner-y win)
               (win-inner-w win) (win-inner-h win) pt-g3))
  (draw-eye e rp (eyes-lx e) (eyes-ly e))
  (draw-eye e rp (eyes-rx e) (eyes-ry e))
  ;; Both pupils are gone with the fill, so neither remembered position is
  ;; true any more: track draws only what moved, and would otherwise leave an
  ;; eye blank until the mouse happened to shift it.
  (set-eyes-px1! e -1)
  (set-eyes-py1! e -1)
  (set-eyes-px2! e -1)
  (set-eyes-py2! e -1)
  (track-1 e rp))

;; Only the eye that changed is redrawn, and only when it changed: at sixty
;; frames a second with nothing moving, this does nothing at all. An eye that
;; is redrawn hands the compositor its own square and nothing more.
(define (track-1 e rp)
  (let* ((tx (target-x e))
         (ty (target-y e))
         (p1 (pupil-at e (eyes-lx e) (eyes-ly e) tx ty))
         (p2 (pupil-at e (eyes-rx e) (eyes-ry e) tx ty)))
    (if (if (%= (%car p1) (eyes-px1 e)) (%= (cadr p1) (eyes-py1 e)) nil)
        nil
        (begin
          (draw-eye e rp (eyes-lx e) (eyes-ly e))
          (set-eyes-px1! e (%car p1))
          (set-eyes-py1! e (cadr p1))
          (draw-pupil e rp (eyes-px1 e) (eyes-py1 e))
          (eye-damage e (eyes-lx e) (eyes-ly e))))
    (if (if (%= (%car p2) (eyes-px2 e)) (%= (cadr p2) (eyes-py2 e)) nil)
        nil
        (begin
          (draw-eye e rp (eyes-rx e) (eyes-ry e))
          (set-eyes-px2! e (%car p2))
          (set-eyes-py2! e (cadr p2))
          (draw-pupil e rp (eyes-px2 e) (eyes-py2 e))
          (eye-damage e (eyes-rx e) (eyes-ry e))))
    nil))

;; The square an eye covers, its outline included, in the window's own
;; coordinates.
(define (eye-damage e cx cy)
  (let ((r (%+ (eyes-rad e) 1)))
    (window-damage-rect (eyes-window e) (%- cx r) (%- cy r)
                        (%+ r (%+ r 1)) (%+ r (%+ r 1)))))

;; Look somewhere in particular, or -1 -1 to go back to following the mouse.
(define (look-at e x y)
  (set-eyes-look-x! e x)
  (set-eyes-look-y! e y)
  (track e))

;; ---------------------------------------------------------------- the app
(define (eyes-task e)
  ;; Once a frame: look, redraw whichever eye has moved - which hands the
  ;; compositor that eye's square - and wait for the next frame. This used to
  ;; present the whole window every frame whether anything had moved or not,
  ;; and ten pairs of eyes recomposited sixty times a second was more blitting
  ;; than a frame holds.
  (while t
    (track e)
    (wait-vblank)))

(define *eyes-count* 0)

(define (eyes . opts)
  ;; A window, a task, and the state that belongs to this pair of eyes. Both
  ;; the refresh callback and the task's own body close over the record, which
  ;; is the whole of how they know which pair they are.
  (let* ((e (eyes-alloc))
         (n (length opts))
         (w (if (%> n 0) (%car opts) 170))
         (h (if (%> n 1) (cadr opts) 130))
         (x (if (%> n 2) (caddr opts) (%+ 30 (%* *eyes-count* 26))))
         (y (if (%> n 3) (cadddr opts) (%+ 30 (%* *eyes-count* 22))))
         (win (make-window x y w h "Eyes")))
    (set! *eyes-count* (%+ *eyes-count* 1))
    (set-eyes-window! e win)
    (set-win-refresh! win (lambda (ignored) (draw-all e)))
    (set-win-data! win e)
    (window-open win)
    (set-win-task! win (add-task "eyes" 0 (lambda () (eyes-task e))))
    e))
