;;; input.lisp - input.driver: the task that owns the keyboard and mouse.
;;;
;;; The chip keeps one queue of raw event words, and reading one takes it. So
;;; however many tasks listened, only whichever read first saw each event -
;;; which is why only one task ever listened, and why that task decoded every
;;; kind of event in one loop. The driver is now the one reader. It takes each
;;; event off the chip, turns it into a list that says what happened, and sends
;;; a copy to every subscriber:
;;;
;;;   (key down ascii code mods)    ascii is 0 for a key that has none
;;;   (key up ascii code mods)
;;;   (mouse moved x y)
;;;   (button down n x y)           n: 0 left, 1 right, 2 middle
;;;   (button up n x y)
;;;   (wheel delta x y)
;;;
;;; A subscriber reads its port like any other port. What anybody may ask the
;;; driver:
;;;
;;;   (subscribe port)       every event from now on arrives there
;;;   (unsubscribe port)
;;;   (inject kind ascii code payload)
;;;                          an event as though the keyboard had sent it: a
;;;                          loopback, so that a test can drive all of this
;;;
;;; Where the pointer is right now is not a message. The driver keeps it in
;;; three variables, updated with each event it takes, and anybody may read
;;; them: a pointer wants the latest position, not a history of them.

(in-package input)

(define *input-driver* nil)
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
;; The chip raises its line for as long as it has events. So the interrupt
;; server masks the line and wakes the driver, and the driver turns the line
;; back on once it has emptied the queue - anything that arrives in between
;; raises it again straight away. Masking is what makes a level-triggered
;; device behave: a server that only woke somebody would be entered again the
;; moment it returned.
(define (input-poll)
  (let ((e (input-take)))
    (while e
      (publish (decode e))
      (set! e (input-take))))
  (int-enable int-input)
  nil)

(define (decode e)
  (let ((kind (%car e)) (ascii (cadr e)) (code (caddr e)) (payload (cadddr e)))
    ;; The position with every event, not only a move: it is what a click
    ;; means.
    (set! *mouse-x* (input-mouse-x))
    (set! *mouse-y* (input-mouse-y))
    (set! *mouse-buttons* (input-buttons))
    (cond ((%= kind ev-keydown) (list 'key 'down ascii code (input-mods)))
          ((%= kind ev-keyup) (list 'key 'up ascii code (input-mods)))
          ((%= kind ev-mousemove) (list 'mouse 'moved *mouse-x* *mouse-y*))
          ((%= kind ev-buttondown) (list 'button 'down payload *mouse-x* *mouse-y*))
          ((%= kind ev-buttonup) (list 'button 'up payload *mouse-x* *mouse-y*))
          ((%= kind ev-wheel) (list 'wheel (wheel-delta payload) *mouse-x* *mouse-y*))
          (else (list 'unknown kind ascii code payload)))))

;; Twelve bits, two's complement.
(define (wheel-delta p) (if (%>= p 2048) (%- p 4096) p))

;; One list, sent to everybody: nobody changes an event. A subscriber whose
;; task has ended is dropped rather than sent to - the message would only be
;; answered with a failure, and there is nobody to hear that either.
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

(define (input-serve body)
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

;; Running exactly when it holds the device - see `disk-driver-running?`.
(define (input-driver-running?)
  (if *input-driver*
      (%eq? (device-owner *input*) (server-task *input-driver*))
      nil))

(define (start-input-driver)
  (if (input-driver-running?)
      *input-driver*
      (let* ((s (make-server "input.driver" 20 (lambda (body) (input-serve body))))
             (task (server-task s))
             (port (server-port s))
             (int (make-interrupt "input" 0
                                  (lambda (d) (int-disable int-input) (notify port))
                                  nil)))
        (detach-task task)
        ;; A driver that starts has nobody to tell yet. After a resume the old
        ;; list would name the ports of tasks that belonged to the Exec before
        ;; this one, and sending to one would wake a task this Exec never made.
        (set! *subscribers* nil)
        (input-interrupts! t)
        (claim-device-for *input* task)
        (server-poll! s (lambda () (input-poll)))
        (add-int-server int-input int)
        (on-task-end task (lambda () (rem-int-server int-input int)))
        (set! *input-driver* s)
        s)))

(add-resident "input.driver" (lambda () (start-input-driver)))

;; ---------------------------------------------------------------- clients
(define (driver-port)
  (if *input-driver* (server-port *input-driver*) (error "input: there is no driver")))

;; A port that every event arrives on from now on, as a message whose body is
;; the event.
(define (input-listen)
  (let ((port (create-port nil 0)))
    (request (driver-port) (list 'subscribe port))
    port))

(define (input-unlisten port)
  (request (driver-port) (list 'unsubscribe port))
  (delete-port port)
  nil)

;; The next event on a port, sleeping until there is one.
(define (next-input port)
  (let ((m (get-msg port)))
    (while (%null? m)
      (wait (port-signal port))
      (set! m (get-msg port)))
    (message-body m)))

(define (inject-input kind ascii code payload)
  (request (driver-port) (list 'inject kind ascii code payload)))

;; Where the pointer is, as of the last event the driver took - or straight
;; from the chip, while no driver holds it.
(define (mouse-x) (if (device-usable? *input*) (input-mouse-x) *mouse-x*))
(define (mouse-y) (if (device-usable? *input*) (input-mouse-y) *mouse-y*))
(define (mouse-buttons) (if (device-usable? *input*) (input-buttons) *mouse-buttons*))
