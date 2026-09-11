;;; disk.lisp - disk.driver: the task that owns the disk.
;;;
;;; The first driver, and the whole model on the peripheral where nothing is
;;; hot. One task holds the controller and everything else asks it. A request
;;; is synchronous to the task that makes it and asynchronous to the
;;; controller: the driver starts a transfer and sleeps until the completion
;;; interrupt, the way any task sleeps on anything, and the rest of the
;;; machine runs meanwhile.
;;;
;;; What a client can ask for, and what comes back:
;;;
;;;   (read block n bytes)    a status: n blocks, into a byte object
;;;   (write block n bytes)   a status: n blocks, out of one
;;;   (flush)                 a status
;;;   (size)                  how many blocks the disk has
;;;   (exclusive job)         the job's value - see `disk-exclusive`
;;;
;;; A status is 0 for done, 1 for no disk attached, 2 for a range that is not
;;; in memory, 3 for the host failing.
;;;
;;; A transfer names a byte object, not an address, for the reason a bitmap
;;; does: a disk read is a write into memory, and an address is permission to
;;; write anywhere. The driver checks that the blocks fit.

(in-package disk)

(define disk-block-bytes 512)

;; The running driver, and the port its completion interrupt notifies. Both
;; are replaced whenever a driver starts.
(define *disk-driver* nil)
(define *disk-done* nil)

;; How many times a driver has gone to sleep on the controller. Only
;; `(drivers)` reads it, to tell a driver that waited from one that never had
;; to.
(define *disk-sleeps* 0)

;; ---------------------------------------------------------------- transfers
;; Start one and watch the status until it is over. Always correct, and the
;; only way with interrupts off: inside an exclusive job, or during a rebuild,
;; when there is no driver.
(define (transfer cmd addr block n)
  (disk-go cmd addr block n)
  (while (disk-busy?) nil)
  (disk-status))

;; The driver's way: start it and sleep until the controller says it is done.
;; A loop, because the signal is an edge and one can be left over - a job that
;; ran with interrupts off still had the controller raise its line at the end
;; of every transfer, and the first wait after it wakes straight away.
(define (transfer-sleeping cmd addr block n)
  (disk-go cmd addr block n)
  (while (disk-busy?)
    (set! *disk-sleeps* (%+ *disk-sleeps* 1))
    (wait (port-signal *disk-done*)))
  (disk-status))

(define (check-buffer n bytes)
  (if (bytes? bytes) nil (error "disk: not a byte object:" bytes))
  (if (if (%>= n 0) (%<= n (%lsh (bytes-length bytes) -9)) nil)
      nil
      (error "disk:" n "blocks do not fit in" (bytes-length bytes) "bytes")))

;; ---------------------------------------------------------------- the driver
(define (disk-serve body)
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
;; holding. It cannot be collected while the transfer runs, because the caller
;; is blocked with the request in hand; and it cannot move, because objects
;; never do.
(define (serve-bytes cmd body)
  (let ((block (cadr body)) (n (caddr body)) (bytes (cadddr body)))
    (check-buffer n bytes)
    (transfer-sleeping cmd (%addr-of bytes) block n)))

;; A driver is running exactly when it holds the disk. That one test covers a
;; driver that died - its device came back when it did - and a resumed image,
;; whose driver belonged to an Exec that no longer exists and whose claim the
;; resume released.
(define (disk-driver-running?)
  (if *disk-driver*
      (%eq? (device-owner *disk*) (server-task *disk-driver*))
      nil))

(define (start-disk-driver)
  (if (disk-driver-running?)
      *disk-driver*
      (let* ((s (make-server "disk.driver" 10 (lambda (body) (disk-serve body))))
             (task (server-task s))
             (done (create-port-for task nil 0))
             (int (make-interrupt "disk" 0 (lambda (d) (notify done)) nil)))
        ;; Nobody's dependent: a resident outlives whoever started Exec.
        (detach-task task)
        ;; Completion raises a line - set while the device is still anybody's
        ;; - and then the device is the driver's, before anybody has been
        ;; handed the port to ask.
        (disk-interrupts! t)
        (claim-device-for *disk* task)
        (add-int-server int-disk int)
        (on-task-end task (lambda () (rem-int-server int-disk int)))
        (set! *disk-done* done)
        (set! *disk-driver* s)
        s)))

(add-resident "disk.driver" (lambda () (start-disk-driver)))

;; ---------------------------------------------------------------- clients
;; Every call goes to the driver while one holds the disk. While none does -
;; before Exec is up, during a rebuild, or after a driver has died and before
;; another starts - the device is anybody's, and the call does the transfer
;; itself.
(define (disk-port)
  (if *disk-driver* (server-port *disk-driver*) (error "disk: there is no driver")))

(define (disk-read block n bytes)
  (check-buffer n bytes)
  (if (device-usable? *disk*)
      (transfer disk-cmd-read (%addr-of bytes) block n)
      (request (disk-port) (list 'read block n bytes))))

(define (disk-write block n bytes)
  (check-buffer n bytes)
  (if (device-usable? *disk*)
      (transfer disk-cmd-write (%addr-of bytes) block n)
      (request (disk-port) (list 'write block n bytes))))

(define (disk-flush)
  (if (device-usable? *disk*)
      (transfer disk-cmd-flush 0 0 0)
      (request (disk-port) (list 'flush))))

(define (disk-size)
  (if (device-usable? *disk*) (disk-blocks) (request (disk-port) (list 'size))))

;; Run `job` with the disk and nothing else: in the task that holds the disk,
;; with interrupts off, so that nothing else in the machine runs - no task and
;; no interrupt server - until it returns. It is for the one client that needs
;; the machine to stand still while it writes, which is saving an image:
;; collect, then write every region, with nothing allocating or changing a
;; byte in between. Answers the job's value. The job must not wait for
;; anything, because nothing will run to wake it.
;;
;; Inside the job, `disk-write-raw` writes memory by address. That is the one
;; place an address is taken, and it is scoped like the rest: the job runs in
;; the driver's task, so the device lets it through, and the same call from
;; any other task is refused.
(define (disk-exclusive job)
  (if (device-usable? *disk*)
      (without-interrupts (%funcall job))
      (request (disk-port) (list 'exclusive job))))

(define (disk-write-raw addr block n) (transfer disk-cmd-write addr block n))
