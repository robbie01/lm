;;; gfx.lisp - gfx.driver: the task that owns the display.
;;;
;;; What it owns is the display chip: where the picture comes from, how big it
;;; is, the palette, and whether the chip raises the vertical blank. Those are
;;; set rarely and matter to everybody, which is what a driver is for. What
;;; it does not own is drawing. A blit costs the task that issues it about 850
;;; cycles and a message about 9,700, so tasks go on linking their own blitter
;;; descriptors, and the driver's part in blitting is waking them when their
;;; pixels have landed.
;;;
;;; What anybody may ask it:
;;;
;;;   (screen w h)       a new screen bitmap, shown; answers the bitmap
;;;   (show)             show the screen there already is - after a resume,
;;;                      when the bitmap survived and the chip did not
;;;   (colours pairs)    palette entries, as (index . rgb) pairs
;;;   (present)          put the frame in front of the viewer now
;;;
;;; The screen bitmap itself is not the driver's secret: `*screen*` is a value
;;; anybody may draw into with the blitter, which is what compositing is.

(in-package gfx)

(define *gfx-driver* nil)

;; How many times a task has gone to sleep waiting for its blits. Only
;; `(drivers)` reads it.
(define *blit-sleeps* 0)

;; ---------------------------------------------------------------- the driver
(define (gfx-serve body)
  (let ((op (%car body)))
    (cond ((%eq? op 'screen) (show-screen (alloc-bitmap (cadr body) (caddr body))))
          ((%eq? op 'show) (show-screen *screen*))
          ((%eq? op 'colours)
           (dolist (p (cadr body)) (gfx-colour! (%car p) (%cdr p)))
           t)
          ((%eq? op 'present) (gfx-present!) t)
          (else (error "gfx.driver: no such request:" op)))))

(define (show-screen b)
  (if (%null? b)
      nil
      (begin
        (set! *screen* b)
        (gfx-show b)
        (default-palette)
        (set! *screen-rp* (make-bitmap-rastport b))
        b)))

(define (default-palette)
  ;; Sixteen readable colours, then a grey ramp over the rest.
  (let ((i 0)
        (first (list (rgb 0 0 0) (rgb 255 255 255) (rgb 200 40 40) (rgb 40 200 60)
                     (rgb 60 100 230) (rgb 230 200 40) (rgb 220 120 30)
                     (rgb 170 80 220) (rgb 40 200 200) (rgb 240 130 180)
                     (rgb 120 90 50) (rgb 90 90 110) (rgb 150 150 170)
                     (rgb 60 70 90) (rgb 30 40 55) (rgb 20 24 34))))
    (dolist (c first)
      (gfx-colour! i c)
      (set! i (%+ i 1)))
    (while (%< i 256)
      (let ((v (%+ 16 (%lsh (%* (%- i 16) 239) -8))))
        (gfx-colour! i (rgb v v v)))
      (set! i (%+ i 1)))))

;; Running exactly when it holds the device - see `disk-driver-running?`.
(define (gfx-driver-running?)
  (if *gfx-driver*
      (%eq? (device-owner *gfx*) (server-task *gfx-driver*))
      nil))

(define (start-gfx-driver)
  (if (gfx-driver-running?)
      *gfx-driver*
      (let* ((s (make-server "gfx.driver" 15 (lambda (body) (gfx-serve body))))
             (task (server-task s))
             (int (make-interrupt "blit" 0 (lambda (d) (blit-server d)) nil)))
        (detach-task task)
        ;; The frame clock first, while the device is still anybody's: Exec's
        ;; vblank server is already installed, and waits on a chip that has
        ;; been told to raise it.
        (gfx-vblank-irq! t)
        (claim-device-for *gfx* task)
        ;; A driver that starts has nobody asleep on it yet. After a resume the
        ;; list would name tasks of the Exec before this one.
        (set! *blit-waiters* nil)
        (add-int-server int-blit int)
        (set-blit-sleep! (lambda (d) (blit-sleep d)))
        (on-task-end task (lambda ()
                            (set-blit-sleep! nil)
                            (rem-int-server int-blit int)))
        (set! *gfx-driver* s)
        s)))

(add-resident "gfx.driver" (lambda () (start-gfx-driver)))

;; ---------------------------------------------------------------- completion
;; A task whose blit has not landed yet sleeps on its blit signal rather than
;; spinning on the chip. It goes on this list, the chip is told to raise its
;; line after every descriptor, and the server wakes whoever's descriptor is
;; now done. The last sleeper to leave turns the per-descriptor line off
;; again, so a machine nobody is waiting on takes no interrupts for it.
;;
;; The server allocates nothing and removes nothing: it only signals. Each
;; sleeper takes itself off the list when it wakes, in its own task, where
;; allocating is allowed.
(define *blit-waiters* nil)   ; (task . descriptor), newest first

(define (blit-server data)
  (let ((p *blit-waiters*))
    (while (%cons? p)
      (let ((w (%car p)))
        (if (blit-done? (%cdr w)) (signal (%car w) sigf-blit) nil))
      (set! p (%cdr p))))
  nil)

;; Inside a Forbid it spins instead. Sleeping there would give the Forbid up -
;; see `wait` - and nothing about a blit needs another task to run: the chip
;; finishes by itself, and reading its status is what lets it be seen to. So
;; it waits the way it does with interrupts off, and the way WaitBlit always
;; did, and a section that draws is still a section when it has finished
;; drawing.
(define (blit-sleep d)
  (if (forbidden?)
      (while (if (blit-done? d) nil t) (blit-busy?))
      (let ((me (this-task)))
        (set! *blit-sleeps* (%+ *blit-sleeps* 1))
        (without-interrupts
          (set! *blit-waiters* (%cons (%cons me d) *blit-waiters*))
          (blit-irq-each! t))
        ;; Look again before sleeping: if it finished while this went on the
        ;; list, no interrupt is coming for it. The loop is for a signal left
        ;; over from the last sleep.
        (while (if (blit-done? d) nil t)
          (wait sigf-blit))
        (without-interrupts
          (set! *blit-waiters* (remove-waiter me *blit-waiters*))
          (if (%null? *blit-waiters*) (blit-irq-each! nil) nil))))
  nil)

(define (remove-waiter task ws)
  (let ((keep nil))
    (dolist (w ws) (if (%eq? (%car w) task) nil (set! keep (%cons w keep))))
    (reverse keep)))

;; ---------------------------------------------------------------- clients
;; Every call goes to the driver while one holds the display, and is done on
;; the spot while none does: before Exec is up, during a rebuild, or between
;; a driver dying and the next one starting.
(define (gfx-port)
  (if *gfx-driver* (server-port *gfx-driver*) (error "gfx: there is no driver")))

(define (ask body)
  (if (device-usable? *gfx*) (gfx-serve body) (request (gfx-port) body)))

(define (open-screen w h) (ask (list 'screen w h)))
(define (attach-screen) (ask (list 'show)))
(define (set-colour i rgb) (ask (list 'colours (list (%cons i rgb)))))
(define (set-colours pairs) (ask (list 'colours pairs)))
(define (screen-sync) (ask (list 'present)))

;; Frames since Exec started, from the vertical blank server: a variable, not
;; the chip's counter, so counting frames asks nobody anything.
(define (vblank-count) *vblank-count*)
