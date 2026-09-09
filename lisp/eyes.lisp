;;; eyes.lisp - xeyes, as a demonstration that an application can have more
;;; than one of itself.
;;;
;;; Every name below that looks like a global - window, rad, px1 - is a slot
;;; of whichever instance is running, one instruction off s2. Nothing in the
;;; code knows how many pairs of eyes there are, and nothing had to be written
;;; differently to allow more than one: `(eyes)` twice is two windows, two
;;; tasks, two sets of pupils, one copy of this file's machine code.

(in-package eyes)

(definstance eyes
  (window nil)                 ; the window we live in
  (lx 0) (ly 0)                ; where the eyes are, in screen coordinates
  (rx 0) (ry 0)
  (rad 20)                     ; the white of an eye
  (pr 7)                       ; and its pupil
  (px1 -1) (py1 -1)            ; where the pupils are now, so we can tell
  (px2 -1) (py2 -1)            ; when nothing has moved
  (look-x -1) (look-y -1))     ; -1 -1 means follow the mouse

;; ---------------------------------------------------------------- geometry
;; Recomputed rather than remembered, because the window moves when it is
;; dragged and the eyes have to go with it.
(define (place-eyes)
  (let* ((w (win-inner-w window))
         (h (win-inner-h window))
         (x (win-inner-x window))
         (y (win-inner-y window))
         (r (%lsh (if (%< w h) w h) -2)))
    (set! rad (if (%< r 8) 8 r))
    (set! pr (%lsh rad -2))
    (if (%< pr 3) (set! pr 3) nil)
    (set! ly (%+ y (%lsh h -1)))
    (set! ry ly)
    (set! lx (%+ x (%- (%lsh w -1) (%+ rad 2))))
    (set! rx (%+ x (%+ (%lsh w -1) (%+ rad 2))))))

;; The mouse is in screen coordinates and the eyes are in the window's, so
;; something has to convert; this is the only place in the application that
;; knows the window is anywhere in particular.
(define (target-x)
  (%- (if (%< look-x 0) (mouse-x) look-x) (win-x-of window)))
(define (target-y)
  (%- (if (%< look-y 0) (mouse-y) look-y) (win-y-of window)))

(define (win-x-of w) (win-get w win-x))
(define (win-y-of w) (win-get w win-y))

;; Where a pupil sits when the eye is looking at a point: along the line to
;; it, and no further out than the white of the eye allows.
(define (pupil-at cx cy tx ty)
  (let* ((dx (%- tx cx))
         (dy (%- ty cy))
         (reach (%- rad (%+ pr 2)))
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
(define (draw-eye cx cy)
  (fill-circle cx cy rad pt-white)
  (draw-circle cx cy rad pt-black))

(define (draw-pupil x y) (fill-circle x y pr pt-black))

;; Drawing establishes its own rastport rather than trusting the one the task
;; happens to be carrying: `(with-instance w (look-at ...))` from a prompt is
;; a perfectly reasonable thing to do, and it must not paint over the window
;; in front just because the prompt's task was not clipped to anything.
(define (drawing thunk)
  (let ((saved *rp*))
    (use-rastport (window-rastport window))
    (%funcall thunk)
    (use-rastport saved)
    nil))

(define (draw-all) (drawing (lambda () (draw-all-1))))
(define (track) (drawing (lambda () (track-1))))

(define (draw-all-1)
  (place-eyes)
  (fill-rect (win-inner-x window) (win-inner-y window)
             (win-inner-w window) (win-inner-h window) pt-g3)
  (draw-eye lx ly)
  (draw-eye rx ry)
  ;; Both pupils are gone with the fill, so neither remembered position is
  ;; true any more: track draws only what moved, and would otherwise leave an
  ;; eye blank until the mouse happened to shift it.
  (set! px1 -1)
  (set! py1 -1)
  (set! px2 -1)
  (set! py2 -1)
  (track))

;; Only the eye that changed is redrawn, and only when it changed: at sixty
;; frames a second with nothing moving, this does nothing at all.
(define (track-1)
  (let* ((tx (target-x))
         (ty (target-y))
         (p1 (pupil-at lx ly tx ty))
         (p2 (pupil-at rx ry tx ty)))
    (if (if (%= (%car p1) px1) (%= (cadr p1) py1) nil)
        nil
        (begin
          (draw-eye lx ly)
          (set! px1 (%car p1))
          (set! py1 (cadr p1))
          (draw-pupil px1 py1)))
    (if (if (%= (%car p2) px2) (%= (cadr p2) py2) nil)
        nil
        (begin
          (draw-eye rx ry)
          (set! px2 (%car p2))
          (set! py2 (cadr p2))
          (draw-pupil px2 py2)))
    nil))

;; Look somewhere in particular, or -1 -1 to go back to following the mouse.
(define (look-at x y)
  (set! look-x x)
  (set! look-y y)
  (track))

;; ---------------------------------------------------------------- the app
(define (eyes-task)
  ;; Once a frame, and said as a handover rather than as a wait on a clock:
  ;; the frame is finished, show it, and do not run again until it has been.
  (while t
    (track)
    (present window)))

(define *eyes-count* 0)

(define (eyes . opts)
  ;; A window, a task, and the state that belongs to this pair of eyes. The
  ;; refresh closure captures the instance and steps back into it, which is
  ;; how a callback from somebody else's code gets its bearings again.
  (let* ((self (make-eyes))
         (n (length opts))
         (w (if (%> n 0) (%car opts) 170))
         (h (if (%> n 1) (cadr opts) 130))
         (x (if (%> n 2) (caddr opts) (%+ 30 (%* *eyes-count* 26))))
         (y (if (%> n 3) (cadddr opts) (%+ 30 (%* *eyes-count* 22)))))
    (set! *eyes-count* (%+ *eyes-count* 1))
    (with-instance self
      (set! window (make-window x y w h "Eyes"))
      (win-set! window win-refresh (lambda (win) (with-instance self (draw-all))))
      (win-set! window win-data self)
      (window-open window)
      (win-set! window win-task (spawn self "eyes" 0 (lambda () (eyes-task)))))
    self))
