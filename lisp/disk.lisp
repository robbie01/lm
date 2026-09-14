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
;;; A status is 0 for done, 1 for no disk attached, 2 for a range that is not
;;; in memory, 3 for the host failing.
;;;
;;; A transfer names a byte object, not an address: a disk read is a write
;;; into memory, and an address is permission to write anywhere. The driver
;;; checks that the blocks fit.

(in-package disk)

(define disk-block-bytes 512)

;; The running driver, and the port its completion interrupt notifies. Both
;; are replaced whenever a driver starts.
(define *driver* nil)
(define *disk-done* nil)

;; How many times a driver has gone to sleep on the controller. `(drivers)`
;; reads it.
(define *sleeps* 0)

;; ---------------------------------------------------------------- transfers
;; Start one and watch the status until it is over: the only way with
;; interrupts off, inside an exclusive job, or when there is no driver.
(define (transfer cmd addr block n)
  (disk-go cmd addr block n)
  (while (disk-busy?) nil)
  (disk-status))

;; The driver's way: start it and sleep until the controller says it is done.
;; A loop, because the signal is an edge and one can be left over from a
;; transfer that was watched rather than slept through.
(define (transfer-sleeping cmd addr block n)
  (disk-go cmd addr block n)
  (while (disk-busy?)
    (set! *sleeps* (%+ *sleeps* 1))
    (wait (port-signal *disk-done*)))
  (disk-status))

(define (check-buffer n bytes)
  (if (bytes? bytes) nil (error "disk: not a byte object:" bytes))
  (if (if (%>= n 0) (%<= n (%lsh (bytes-length bytes) -9)) nil)
      nil
      (error "disk:" n "blocks do not fit in" (bytes-length bytes) "bytes")))

;; ---------------------------------------------------------------- the driver
(define (serve body)
  (let ((op (%car body)))
    (cond ((%eq? op 'read) (serve-bytes disk-cmd-read body))
          ((%eq? op 'write) (serve-bytes disk-cmd-write body))
          ((%eq? op 'flush) (transfer-sleeping disk-cmd-flush 0 0 0))
          ((%eq? op 'size) (disk-blocks))
          ;; Interrupts off for the whole job, and every transfer in it
          ;; watched rather than slept through: nothing else runs to wake it.
          ((%eq? op 'exclusive) (without-interrupts (%funcall (cadr body))))
          (else (error "disk.driver: no such request:" op)))))

;; The address is taken here, in the driver, out of an object the request is
;; holding. It cannot be collected while the transfer runs, because the
;; caller is blocked with the request in hand; and objects never move.
(define (serve-bytes cmd body)
  (unsafe
  (let ((block (cadr body)) (n (caddr body)) (bytes (cadddr body)))
    (check-buffer n bytes)
    (transfer-sleeping cmd (%addr-of bytes) block n))))

;; A driver is running exactly when it holds the disk. That covers a driver
;; that ended, whose device came back when it did, and a resumed image, whose
;; driver belonged to an Exec that no longer exists.
(define (running?)
  (if *driver*
      (%eq? (device-owner *disk*) (server-task *driver*))
      nil))

(define (start)
  (if (running?)
      *driver*
      (let* ((s (make-server "disk.driver" 10 (lambda (body) (serve body))))
             (task (server-task s))
             (done (make-port-for task nil 0))
             (int (make-interrupt "disk" 0 (lambda (d) (notify done)) nil)))
        ;; A resident outlives whoever started Exec.
        (detach-task task)
        ;; Completion raises a line, set while the device is still anybody's;
        ;; then the device is the driver's, before anybody can be handed the
        ;; port to ask.
        (disk-interrupts! t)
        (claim-device-for *disk* task)
        (add-int-server int-disk int)
        (on-task-end task (lambda () (remove-int-server int-disk int)))
        (set! *disk-done* done)
        (set! *driver* s)
        s)))

(add-resident "disk.driver" (lambda () (start)))

;; ---------------------------------------------------------------- clients
;; Every call goes to the driver while one holds the disk. While none does,
;; before Exec is up, during a rebuild, or after a driver has ended and before
;; another starts, the device is anybody's and the call does the transfer
;; itself.
(define (driver-port)
  (if *driver* (server-port *driver*) (error "disk: there is no driver")))

(define (read-blocks block n bytes)
  (unsafe
  (check-buffer n bytes)
  (if (device-usable? *disk*)
      (transfer disk-cmd-read (%addr-of bytes) block n)
      (request (driver-port) (list 'read block n bytes)))))

(define (write-blocks block n bytes)
  (unsafe
  (check-buffer n bytes)
  (if (device-usable? *disk*)
      (transfer disk-cmd-write (%addr-of bytes) block n)
      (request (driver-port) (list 'write block n bytes)))))

(define (flush)
  (if (device-usable? *disk*)
      (transfer disk-cmd-flush 0 0 0)
      (request (driver-port) (list 'flush))))

(define (size)
  (if (device-usable? *disk*) (disk-blocks) (request (driver-port) (list 'size))))

;; Run `job` with the disk and nothing else: in the task that holds the disk,
;; with interrupts off, so that no task and no interrupt server runs until it
;; returns. Saving an image needs this: collect, then write every region,
;; with nothing allocating or changing a byte in between. Answers the job's
;; value. The job must not wait for anything, because nothing will run to
;; wake it.
;;
;; Inside the job, `write-raw` writes memory by address. The job runs in
;; the driver's task, so the device lets it through; the same call from any
;; other task is refused.
(define (exclusive job)
  (if (device-usable? *disk*)
      (without-interrupts (%funcall job))
      (request (driver-port) (list 'exclusive job))))

(define (write-raw addr block n) (transfer disk-cmd-write addr block n))
