;;; input.lisp - input.driver: the task that owns the keyboard and mouse.
;;;
;;; The chip keeps one queue of raw event words, and reading one takes it, so
;;; the driver is the one reader. It takes each event off the chip, turns it
;;; into a list that says what happened, and sends it to every subscriber:
;;;
;;;   (key down ascii code mods)    ascii is 0 for a key that has none
;;;   (key up ascii code mods)
;;;   (mouse moved x y)
;;;   (button down n x y)           n: 0 left, 1 right, 2 middle
;;;   (button up n x y)
;;;   (wheel delta x y)
;;;
;;; A subscriber reads its port like any other port. What anybody may ask
;;; the driver:
;;;
;;;   (subscribe port)       every event from now on arrives there
;;;   (unsubscribe port)
;;;   (inject kind ascii code payload)
;;;                          an event as though the keyboard had sent it, so
;;;                          that a test can drive all of this
;;;
;;; Where the pointer is right now is not a message. The driver keeps it in
;;; three variables, updated with each event it takes, and anybody may read
;;; them.

(in-package input)

(define *driver* nil)
(define *subscribers* nil)   ; the driver's own; only its task changes it
(define *mouse-x* 0)
(define *mouse-y* 0)
(define *mouse-buttons* 0)

(define ev-keydown 1)
(define ev-keyup 2)
(define ev-mousemove 3)
(define ev-buttondown 4)
(define ev-buttonup 5)
(define ev-wheel 6)

;; ---------------------------------------------------------------- the driver
;; The chip raises its line for as long as it has events. The interrupt
;; server masks the line and wakes the driver, and the driver turns the line
;; back on once it has emptied the queue; anything that arrived in between
;; raises it again at once.
(define (poll)
  (let ((e (input-take)))
    (while e
      (publish (decode e))
      (set! e (input-take))))
  (int-enable int-input)
  nil)

(define (decode e)
  (let ((kind (%car e)) (hi (cadr e)) (lo (caddr e)))
    (cond ((%= kind ev-keydown)
           (list 'key 'down (key-ascii-bits hi) (key-code-bits hi lo) (input-mods)))
          ((%= kind ev-keyup)
           (list 'key 'up (key-ascii-bits hi) (key-code-bits hi lo) (input-mods)))
          ((%= kind ev-wheel)
           (list 'wheel (wheel-delta (%logand lo 4095)) *mouse-x* *mouse-y*))
          ((if (%>= kind ev-mousemove) (%<= kind ev-buttonup) nil)
           ;; A pointer event says where it happened, which is not where the
           ;; pointer is now if the event was taken off the queue late.
           (let ((x (%lsh lo -4)) (y (%logand hi 4095)) (b (%logand lo 15)))
             (set! *mouse-x* x)
             (set! *mouse-y* y)
             (set! *mouse-buttons* (input-buttons))
             (cond ((%= kind ev-mousemove) (list 'mouse 'moved x y))
                   ((%= kind ev-buttondown) (list 'button 'down b x y))
                   (else (list 'button 'up b x y)))))
          (else (list 'unknown kind hi lo)))))

(define (key-ascii-bits hi) (%logand (%lsh hi -4) 255))
(define (key-code-bits hi lo) (%logior (%lsh (%logand hi 15) 4) (%lsh lo -12)))

;; Twelve bits, two's complement.
(define (wheel-delta p) (if (%>= p 2048) (%- p 4096) p))

;; One list, sent to everybody: nobody changes an event. A subscriber whose
;; task has ended is dropped.
(define (publish ev)
  (let ((dead nil))
    (dolist (p *subscribers*)
      (if (port-open? p) (send p ev) (set! dead t)))
    (if dead (set! *subscribers* (open-ports *subscribers*)) nil))
  nil)

(define (open-ports ps)
  (let ((keep nil))
    (dolist (p ps) (if (port-open? p) (set! keep (%cons p keep)) nil))
    (reverse keep)))

(define (serve body)
  (let ((op (%car body)))
    (cond ((%eq? op 'subscribe)
           (set! *subscribers* (%cons (cadr body) (remove-eq (cadr body) *subscribers*)))
           t)
          ((%eq? op 'unsubscribe)
           (set! *subscribers* (remove-eq (cadr body) *subscribers*))
           t)
          ((%eq? op 'inject)
           (input-inject (cadr body) (caddr body) (cadddr body) (nth 4 body))
           t)
          (else (error "input.driver: no such request:" op)))))

;; Running exactly when it holds the device; see `disk:running?`.
(define (running?)
  (if *driver*
      (%eq? (device-owner *input*) (server-task *driver*))
      nil))

(define (start)
  (if (running?)
      *driver*
      (let* ((s (make-server "input.driver" 20 (lambda (body) (serve body))))
             (task (server-task s))
             (port (server-port s))
             (int (make-interrupt "input" 0
                                  (lambda (d) (int-disable int-input) (notify port))
                                  nil)))
        (detach-task task)
        ;; After a resume the old list names the ports of tasks that belonged
        ;; to the Exec before this one.
        (set! *subscribers* nil)
        (input-interrupts! t)
        (claim-device-for *input* task)
        (server-poll! s (lambda () (poll)))
        (add-int-server int-input int)
        (on-task-end task (lambda () (remove-int-server int-input int)))
        (set! *driver* s)
        s)))

(add-resident "input.driver" (lambda () (start)))

;; ---------------------------------------------------------------- clients
(define (driver-port)
  (if *driver* (server-port *driver*) (error "input: there is no driver")))

;; A port that every event arrives on from now on, as a message whose body is
;; the event.
(define (listen)
  (let ((port (make-port nil 0)))
    (request (driver-port) (list 'subscribe port))
    port))

(define (unlisten port)
  (request (driver-port) (list 'unsubscribe port))
  (delete-port port)
  nil)

;; The next event on a port, sleeping until there is one.
(define (next-event port)
  (let ((m (get-message port)))
    (while (%null? m)
      (wait (port-signal port))
      (set! m (get-message port)))
    (message-body m)))

(define (inject kind ascii code payload)
  (request (driver-port) (list 'inject kind ascii code payload)))

;; Where the pointer is, as of the last event the driver took, or straight
;; from the chip while no driver holds it.
(define (mouse-x) (if (device-usable? *input*) (input-mouse-x) *mouse-x*))
(define (mouse-y) (if (device-usable? *input*) (input-mouse-y) *mouse-y*))
(define (mouse-buttons) (if (device-usable? *input*) (input-buttons) *mouse-buttons*))
