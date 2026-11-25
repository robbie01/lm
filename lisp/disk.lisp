;;; disk.lisp - disk.driver: the task that owns the disk.
;;;
;;; One task holds the controller and everything else asks it. A request is
;;; synchronous to the task that makes it and asynchronous to the controller:
;;; the driver starts a transfer and sleeps until the completion interrupt,
;;; and the rest of the machine runs meanwhile.
;;;
;;; What a client can ask for, and what comes back:
;;;
;;;   (read block n bytes)    a status: n blocks, into a byte object
;;;   (write block n bytes)   a status: n blocks, out of one
;;;   (flush)                 a status
;;;   (size)                  how many blocks the disk has
;;;   (exclusive job)         the job's value; see `exclusive`
;;;
;;; A status is 0 for done, 1 for no disk attached, `disk-refused` for a
;;; buffer that does not hold the blocks, 3 for the host failing.
;;;
;;; A transfer names a byte object, and the controller is handed the object's
;;; capability itself: it moves only what the capability covers, and refuses
;;; a transfer of more blocks than the object holds. The driver holds the
;;; controller's page, taken once when it starts and kept in its closures,
;;; and that is the one unsafe form here: nothing else names memory by
;;; number or makes a device's page.

(in-package disk)

(defconstant disk-block-bytes 512)

;; The running driver, and the port its completion interrupt notifies. Both
;; are replaced whenever a driver starts.
(define *driver* nil)
(define *disk-done* nil)

;; How many times a driver has gone to sleep on the controller. `(drivers)`
;; reads it.
(define *sleeps* 0)

;; ---------------------------------------------------------------- transfers
;; Each takes the controller's page. Start one and watch the status until it
;; is over: the only way with interrupts off, as inside an exclusive job.
(define (transfer page cmd buf block n)
  (disk-go page cmd buf block n)
  (while (disk-busy? page) nil)
  (disk-status page))

;; The driver's way: start it and sleep until the controller says it is done.
;; A loop, because the signal is an edge and one can be left over from a
;; transfer that was watched rather than slept through.
(define (transfer-sleeping page cmd buf block n)
  (disk-go page cmd buf block n)
  (while (disk-busy? page)
    (set! *sleeps* (%+ *sleeps* 1))
    (wait (port-signal *disk-done*)))
  (disk-status page))

;; Whether the blocks fit is the controller's to say.
(define (check-buffer bytes)
  (if (bytes? bytes) nil (error "disk: not a byte object:" bytes)))

;; ---------------------------------------------------------------- the driver
(define (serve page body)
  (let ((op (%car body)))
    (cond ((%eq? op 'read) (serve-bytes page disk-cmd-read body))
          ((%eq? op 'write) (serve-bytes page disk-cmd-write body))
          ((%eq? op 'flush) (transfer-sleeping page disk-cmd-flush 0 0 0))
          ((%eq? op 'size) (disk-blocks page))
          ;; Interrupts off for the whole job, and every transfer in it
          ;; watched rather than slept through: nothing else runs to wake it.
          ((%eq? op 'exclusive) (without-interrupts (%funcall (cadr body))))
          (else (error "disk.driver: no such request:" op)))))

;; The object the request is holding goes to the controller. It cannot be
;; collected while the transfer runs, because the caller is blocked with the
;; request in hand.
(define (serve-bytes page cmd body)
  (let ((block (cadr body)) (n (caddr body)) (bytes (cadddr body)))
    (check-buffer bytes)
    (transfer-sleeping page cmd bytes block n)))

(define (running?) (server-running? *driver*))

;; The page goes into the handler before the task exists, so the driver
;; holds the controller from its first instruction, and nothing but the
;; driver's own closures ever holds it.
(define (start)
  (if (running?)
      *driver*
      (let* ((page (unsafe (device-page dev-disk)))
             (s (make-server "disk.driver" 10 (lambda (body) (serve page body))))
             (task (server-task s))
             (done (make-port-for task nil 0))
             (int (make-interrupt "disk" 0 (lambda (d) (notify done)) nil)))
        ;; A resident outlives whoever started Exec.
        (detach-task task)
        (set! *disk-done* done)
        (disk-interrupts! page t)
        (add-int-server int-disk int)
        (on-task-end task (lambda () (remove-int-server int-disk int)))
        (set! *driver* s)
        s)))

(add-resident "disk.driver" (lambda () (start)))

;; ---------------------------------------------------------------- clients
;; Every call is a request to the driver; with no driver running there is no
;; way to the disk.
(define (driver-port)
  (if (running?) (server-port *driver*) (error "disk: there is no driver")))

(define (read-blocks block n bytes)
  (check-buffer bytes)
  (request (driver-port) (list 'read block n bytes)))

(define (write-blocks block n bytes)
  (check-buffer bytes)
  (request (driver-port) (list 'write block n bytes)))

(define (flush) (request (driver-port) (list 'flush)))

(define (size) (request (driver-port) (list 'size)))

;; Run `job` with the disk and nothing else: in the driver's task, with
;; interrupts off, so that no task and no interrupt server runs until it
;; returns and no transfer of the driver's is in flight. Saving an image
;; needs this: collect, then write every region, with nothing allocating or
;; changing a byte in between. Answers the job's value. The job must not
;; wait for anything, because nothing will run to wake it.
;;
;; The job does not get the driver's page. `write-raw` writes n blocks out
;; of whatever capability it is handed, a byte object or not, through the
;; page it is handed: the image writer makes its own from the root, and
;; hands it each region of memory.
(define (exclusive job) (request (driver-port) (list 'exclusive job)))

(define (write-raw page buf block n) (transfer page disk-cmd-write buf block n))
