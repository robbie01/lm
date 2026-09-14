;;; console.lisp - console.driver: the serial line, for everything but
;;; emergencies.
;;;
;;; There are two ways to the serial port. The raw one, `uart-string` and its
;;; relatives in runtime.lisp and a stream of nil, writes the registers
;;; directly. It works before Exec exists, inside a trap handler, and with
;;; the scheduler in pieces, and it is what the collector and the fault
;;; reports use.
;;;
;;; This is the other one: a task that owns the ordinary console. It writes
;;; whole lines, so two tasks printing at once do not interleave inside one;
;;; and it owns the receive side, so a prompt waiting for a key is asleep on
;;; a port instead of spinning on the chip.
;;;
;;;   (write string)    put a string on the line, whole
;;;   (read port)       send what is typed to this port from now on, a string
;;;                     per burst: one key, or a whole pasted page
;;;
;;; The raw functions do not ask the driver and are not refused by it. The
;;; driver's claim on `*serial*` says who is reading the line; it is not a
;;; lock.

(in-package console)

(define *driver* nil)
(define *reader* nil)     ; the port typed input goes to
(define *unread* nil)     ; bursts nobody had asked for yet, newest first

;; ---------------------------------------------------------------- the driver
(define (serve body)
  (let ((op (%car body)))
    (cond ((%eq? op 'write) (uart-string (cadr body)) t)
          ((%eq? op 'read)
           (set! *reader* (cadr body))
           (dolist (s (reverse *unread*)) (send *reader* s))
           (set! *unread* nil)
           t)
          (else (error "console.driver: no such request:" op)))))

;; The chip raises its line while bytes are waiting, so the interrupt server
;; masks it and wakes the driver, and the driver turns it back on once the
;; queue is empty, the same arrangement as the keyboard.
(define (poll)
  (let ((s (take-typed)))
    (if s
        (if (if *reader* (port-open? *reader*) nil)
            (send *reader* s)
            (set! *unread* (%cons s *unread*)))
        nil))
  (int-enable int-uart)
  nil)

;; Everything waiting, as one string, or as much of it as fits in a chunk.
;; The rest stays in the chip, which raises its line again as soon as
;; `poll` turns it back on, and arrives as the next string. Read
;; into a buffer the driver keeps and copied out at the length it came to,
;; so that a pasted megabyte of source does not become a list of characters.
(define typed-max 4096)
(define *typed* nil)

(define (take-typed)
  (if (%null? *typed*) (set! *typed* (make-string-n typed-max)) nil)
  (let ((n 0) (c (uart-char)))
    (while c
      (%string-set! *typed* n c)
      (set! n (%+ n 1))
      (set! c (if (%< n typed-max) (uart-char) nil)))
    (if (%= n 0)
        nil
        (let ((s (make-string-n n)) (i 0))
          (while (%< i n)
            (%string-set! s i (%string-ref *typed* i))
            (set! i (%+ i 1)))
          s))))

;; Running exactly when it holds the line; see `disk:running?`.
(define (running?)
  (if *driver*
      (%eq? (device-owner *serial*) (server-task *driver*))
      nil))

(define (start)
  (if (running?)
      *driver*
      (let* ((s (make-server "console.driver" 12 (lambda (body) (serve body))))
             (task (server-task s))
             (port (server-port s))
             (int (make-interrupt "serial" 0
                                  (lambda (d) (int-disable int-uart) (notify port))
                                  nil)))
        (detach-task task)
        ;; After a resume the old reader belonged to the Exec before this one.
        (set! *reader* nil)
        (set! *unread* nil)
        (claim-device-for *serial* task)
        (serial-interrupts! t)
        (server-poll! s (lambda () (poll)))
        (add-int-server int-uart int)
        (on-task-end task (lambda ()
                            (serial-interrupts! nil)
                            (remove-int-server int-uart int)))
        (set! *driver* s)
        s)))

;; Started with the others, and the task that brought Exec up, the prompt on
;; the serial line, is switched over to it: Exec is started by that task, so
;; this runs in it.
(add-resident "console.driver"
              (lambda ()
                (start)
                (use-stream! (open))))

;; ---------------------------------------------------------------- the stream
;; What the prompt on the serial line uses. Output collects into a line and
;; goes to the driver whole; input comes from the driver a burst at a time
;; and is handed out a character at a time.
;;
;; Wherever asking a task is impossible, in a trap handler, with interrupts
;; off, before the driver is up, output falls back on the raw line, after
;; sending whatever it had collected, so that nothing comes out of order. It
;; sends what it has collected before it waits for input: a prompt that is
;; still in a buffer is a prompt nobody sees.
(define line-max 200)

(define (driver-port)
  (if *driver* (server-port *driver*) (error "console: there is no driver")))

;; Whether a line can go to the driver. Handing it over is a request, and a
;; request waits for its answer, so this is as much a question about where it
;; is asked from as about the driver: not from a trap handler or an interrupt
;; server, where there is no task to wait, and not with interrupts off, where
;; waiting is an error and a print is the last thing that should be one.
;; There, the line goes out raw.
(define (can-ask?)
  (unsafe
  (if (running?)
      (if (%= 0 (%ld-fixnum lg-trapdepth))
          (if *in-interrupt* nil (interrupts-on?))
          nil)
      nil)))

;; Whether a read can. The same, except that a critical section is no bar
;; here: the driver owns the receive side, so while it is up there is no raw
;; way to wait for a key, and a read that has to wait inside a section is
;; refused by `wait` itself.
(define (can-listen?)
  (unsafe
  (if (running?)
      (if (%= 0 (%ld-fixnum lg-trapdepth)) (if *in-interrupt* nil t) nil)
      nil)))

(define (open)
  (let ((out nil) (n 0)          ; the line so far, newest first, and its length
        (in nil) (pos 0)         ; the burst being read, and how far into it
        (port nil))              ; where the driver sends input, once asked
    (let ((flush
           (lambda ()
             (if out
                 (let ((s (list->string (reverse out))))
                   (set! out nil)
                   (set! n 0)
                   (if (can-ask?) (request (driver-port) (list 'write s)) (uart-string s)))
                 nil)))
          (listen
           ;; Ask for the input the first time it is wanted rather than when
           ;; the stream is made: Exec makes it before interrupts are on, and
           ;; asking means waiting for an answer.
           (lambda ()
             (if (if port nil (can-listen?))
                 (begin
                   (set! port (make-port nil 0))
                   (request (driver-port) (list 'read port)))
                 nil))))
      (make-stream
       (lambda (c)
         (if (can-ask?)
             (begin
               (set! out (%cons c out))
               (set! n (%+ n 1))
               (if (if (%eq? c #\newline) t (%>= n line-max)) (%funcall flush) nil))
             (begin
               (if out
                   (begin (uart-string (list->string (reverse out))) (set! out nil) (set! n 0))
                   nil)
               (out-char c))))
       (lambda ()
         (%funcall listen)
         (if (if in (%< pos (%string-length in)) nil)
             (let ((c (%string-ref in pos)))
               (set! pos (%+ pos 1))
               c)
             (let ((m (if port (get-message port) nil)))
               (if m
                   (begin
                     (set! in (message-body m))
                     (set! pos 1)
                     (%string-ref in 0))
                   ;; With no driver the line is anybody's, and the raw read
                   ;; is the only read there is.
                   (if (running?) nil (uart-char))))))
       (lambda ()
         (%funcall flush)
         (%funcall listen)
         (if (if port (can-listen?) nil)
             (wait (port-signal port))
             (unsafe (%wait-for-interrupt))))))))
