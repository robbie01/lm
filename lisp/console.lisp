;;; console.lisp - console.driver: the serial line, for everything but
;;; emergencies.
;;;
;;; There are two ways to the serial port, on purpose. The raw one -
;;; `uart-string` and friends in runtime.lisp, and a stream of nil - writes the
;;; registers directly. It works before Exec exists, inside a trap handler, and
;;; with the scheduler in pieces, and it is what the collector and the panic
;;; path use: a device you can only reach by asking a task is useless in
;;; exactly the situations you most need it. AmigaOS drew the same line,
;;; between serial.device and kprintf.
;;;
;;; This is the other one: a task that owns the ordinary console. It writes
;;; whole lines, so two tasks printing at once do not interleave inside one;
;;; and it owns the receive side, so a prompt waiting for a key is asleep on a
;;; port instead of spinning on the chip.
;;;
;;;   (write string)    put a string on the line, whole
;;;   (read port)       send what is typed to this port from now on, a string
;;;                     per burst - one key, or a whole pasted page
;;;
;;; The raw functions do not ask the driver and are not refused by it. That is
;;; the exception the plan made for this device, and it is why the driver's
;;; claim on `*serial*` is bookkeeping - it says who is reading the line - and
;;; not a lock.

(in-package console)

(define *console-driver* nil)
(define *reader* nil)     ; the port typed input goes to
(define *unread* nil)     ; bursts nobody had asked for yet, newest first

;; ---------------------------------------------------------------- the driver
(define (console-serve body)
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
;; queue is empty - the same arrangement as the keyboard.
(define (console-poll)
  (let ((s (take-typed)))
    (if s
        (if (if *reader* (port-open? *reader*) nil)
            (send *reader* s)
            (set! *unread* (%cons s *unread*)))
        nil))
  (int-enable int-uart)
  nil)

;; Everything waiting, as one string.
(define (take-typed)
  (let ((acc nil) (c (uart-char)))
    (while c
      (set! acc (%cons c acc))
      (set! c (uart-char)))
    (if acc (list->string (reverse acc)) nil)))

;; Running exactly when it holds the line - see `disk-driver-running?`.
(define (console-driver-running?)
  (if *console-driver*
      (%eq? (device-owner *serial*) (server-task *console-driver*))
      nil))

(define (start-console-driver)
  (if (console-driver-running?)
      *console-driver*
      (let* ((s (make-server "console.driver" 12 (lambda (body) (console-serve body))))
             (task (server-task s))
             (port (server-port s))
             (int (make-interrupt "serial" 0
                                  (lambda (d) (int-disable int-uart) (notify port))
                                  nil)))
        (detach-task task)
        ;; Nobody to send to yet, and after a resume the old reader belonged
        ;; to the Exec before this one.
        (set! *reader* nil)
        (set! *unread* nil)
        (claim-device-for *serial* task)
        (serial-interrupts! t)
        (server-poll! s (lambda () (console-poll)))
        (add-int-server int-uart int)
        (on-task-end task (lambda ()
                            (serial-interrupts! nil)
                            (rem-int-server int-uart int)))
        (set! *console-driver* s)
        s)))

;; Started with the others, and the task that brought Exec up - the prompt on
;; the serial line - is switched over to it: Exec is started by that task, so
;; this runs in it.
(add-resident "console.driver"
              (lambda ()
                (start-console-driver)
                (use-stream! (console-stream))))

;; ---------------------------------------------------------------- the stream
;; What the prompt on the serial line uses. Output collects into a line and
;; goes to the driver whole; input comes from the driver a burst at a time and
;; is handed out a character at a time.
;;
;; Wherever asking a task is impossible - in a trap handler, with interrupts
;; off, before the driver is up - or would give away a critical section the
;; caller is holding, output falls back on the raw line, after sending
;; whatever it had collected, so that nothing comes out of order. And it sends
;; what it has collected before it waits for input: a prompt that is still in
;; a buffer is a prompt nobody sees.
(define line-max 200)

(define (console-port)
  (if *console-driver* (server-port *console-driver*) (error "console: there is no driver")))

;; Whether a line can go to the driver. Handing it over is a request, and a
;; request waits for its answer, so this is as much a question about where it
;; is being asked from as about the driver: not from a trap handler or an
;; interrupt server, where there is no task to wait, and not from inside a
;; critical section of either kind. Waiting there lets the section go for as
;; long as the driver takes - see `wait` - and a print is the last thing that
;; should end one, since it is what somebody adds to find out what a section
;; is doing. Inside one, the line goes out raw, the way the collector's do.
;;
;; A Forbid used to get through this and ask. `wait` did not give a Forbid up
;; then, so the driver never ran to answer, and `(without-preemption (print
;; "hi"))` spun for ever where `(without-interrupts (print "hi"))` printed.
(define (can-ask?)
  (if (console-driver-running?)
      (if (%= 0 (%ld-fixnum lg-trapdepth))
          (if *in-interrupt* nil (if (forbidden?) nil (interrupts-on?)))
          nil)
      nil))

;; Whether a read can. The same, except that a critical section is no bar.
;; The driver owns the receive side, so while it is up there is no raw way to
;; wait for a key: a read inside a section sleeps like any other wait, and
;; lets the section go until the key comes. That is the only read there is.
;; It used to hang either way - inside a Forbid it asked and waited for ever,
;; and inside a Disable nothing could tell the driver a key had come.
(define (can-listen?)
  (if (console-driver-running?)
      (if (%= 0 (%ld-fixnum lg-trapdepth)) (if *in-interrupt* nil t) nil)
      nil))

(define (console-stream)
  (let ((out nil) (n 0)          ; the line so far, newest first, and its length
        (in nil) (pos 0)         ; the burst being read, and how far into it
        (port nil))              ; where the driver sends input, once asked
    (let ((flush
           (lambda ()
             (if out
                 (let ((s (list->string (reverse out))))
                   (set! out nil)
                   (set! n 0)
                   (if (can-ask?) (request (console-port) (list 'write s)) (uart-string s)))
                 nil)))
          (listen
           ;; Ask for the input the first time it is wanted rather than when the
           ;; stream is made: Exec makes it before interrupts are on, and asking
           ;; means waiting for an answer.
           (lambda ()
             (if (if port nil (can-listen?))
                 (begin
                   (set! port (create-port nil 0))
                   (request (console-port) (list 'read port)))
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
             (let ((m (if port (get-msg port) nil)))
               (if m
                   (begin
                     (set! in (message-body m))
                     (set! pos 1)
                     (%string-ref in 0))
                   ;; With no driver the line is anybody's, and the raw read is
                   ;; the only read there is.
                   (if (console-driver-running?) nil (uart-char))))))
       (lambda ()
         (%funcall flush)
         (%funcall listen)
         (if (if port (can-listen?) nil)
             (wait (port-signal port))
             (%wait-for-input)))))))
