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
;;; disk's device, its page sealed, which it takes when it starts, the one
;;; unsafe act here, and hands to the accessors. A block number is the whole
;;; disk's, image and all, so the two calls that name blocks are declared
;;; unsafe, and whoever holds the device holds as much as a file system.

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
;; Start one and watch the status until it is over: the only way with
;; interrupts off, as inside an exclusive job.
(define (transfer dev cmd buf block n)
  (disk-go dev cmd buf block n)
  (while (disk-busy? dev) nil)
  (disk-status dev))

;; The driver's way: start it and sleep until the controller says it is done.
;; A loop, because the signal is an edge and one can be left over from a
;; transfer that was watched rather than slept through.
(define (transfer-sleeping dev cmd buf block n)
  (disk-go dev cmd buf block n)
  (while (disk-busy? dev)
    (set! *sleeps* (%+ *sleeps* 1))
    (wait (port-signal *disk-done*)))
  (disk-status dev))

;; Whether the blocks fit is the controller's to say.
(define (check-buffer bytes)
  (if (bytes? bytes) nil (error "disk: not a byte object:" bytes)))

;; ---------------------------------------------------------------- the driver
;; `dev` is the disk: its page sealed, which only the accessors open.
(define (serve dev body)
  (let ((op (%car body)))
    (cond ((%eq? op 'read) (serve-bytes dev disk-cmd-read body))
          ((%eq? op 'write) (serve-bytes dev disk-cmd-write body))
          ((%eq? op 'flush) (transfer-sleeping dev disk-cmd-flush 0 0 0))
          ((%eq? op 'size) (disk-blocks dev))
          ;; Interrupts off for the whole job, and every transfer in it
          ;; watched rather than slept through: nothing else runs to wake it.
          ((%eq? op 'exclusive) (without-interrupts (%funcall (cadr body))))
          (else (error "disk.driver: no such request:" op)))))

;; The object the request is holding goes to the controller. It cannot be
;; collected while the transfer runs, because the caller is blocked with the
;; request in hand.
(define (serve-bytes dev cmd body)
  (let ((block (cadr body)) (n (caddr body)) (bytes (cadddr body)))
    (check-buffer bytes)
    (transfer-sleeping dev cmd bytes block n)))

(define (running?) (server-running? *driver*))

(define (start)
  (if (running?)
      *driver*
      (let* ((dev (unsafe (device dev-disk)))
             (s (make-server "disk.driver" 10 (lambda (body) (serve dev body))))
             (task (server-task s))
             (done (make-port-for task nil 0))
             (int (make-interrupt "disk" 0 (lambda (d) (notify done)) nil)))
        ;; A resident outlives whoever started Exec.
        (detach-task task)
        (set! *disk-done* done)
        (disk-ctrl! dev 1)
        (add-int-server int-disk int)
        (on-task-end task (lambda () (remove-int-server int-disk int)))
        (set! *driver* s)
        s)))

(add-resident "disk.driver" (lambda () (start)))

;; ---------------------------------------------------------------- clients
;; Every call is a request to the driver; with no driver running there is no
;; way to the disk. Reading and writing name raw block numbers, the image's
;; among them, so both are unsafe, as an address is.
(define (driver-port)
  (if (running?) (server-port *driver*) (error "disk: there is no driver")))

(define (read-blocks block n bytes)
  (declare unsafe)
  (check-buffer bytes)
  (request (driver-port) (list 'read block n bytes)))

(define (write-blocks block n bytes)
  (declare unsafe)
  (check-buffer bytes)
  (request (driver-port) (list 'write block n bytes)))

(define (flush) (request (driver-port) (list 'flush)))

(define (size) (request (driver-port) (list 'size)))

;; Run `job` with the disk and nothing else: in the driver's task, with
;; interrupts off, so that no task and no interrupt server runs until it
;; returns and no transfer of the driver's is in flight. Saving an image
;; needs this: collect, then write every region, with nothing allocating or
;; changing a byte in between. Answers the job's value. The job must not
;; wait for anything, because nothing will run to wake it. Unsafe: the job
;; runs with interrupts off, in the driver's task.
;;
;; `write-raw` writes n blocks out of whatever capability it is handed, a
;; byte object or not, through the disk device it is handed: the image
;; writer hands it each region of memory through the region's own
;; capability. So it is unsafe, and programs the controller through its page
;; itself, watching the status until the transfer is over: the accessors
;; and `transfer` are names anybody may define again, and the region is
;; handed to none of them.
(define (exclusive job) (declare unsafe) (request (driver-port) (list 'exclusive job)))

(define (write-raw dev buf block n)
  (declare unsafe)
  (unsafe
  (let ((page (device-open dev disk-page-base)))
    (without-interrupts
      (%cap-st! page d-buf buf)
      (%cap-st-word! page d-block block)
      (%cap-st-word! page d-count n)
      (%cap-st-word! page d-cmd disk-cmd-write))
    (while (%= (%cap-ld-word page d-status) disk-busy) nil)
    (%cap-ld-word page d-status))))
