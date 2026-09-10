;;; stream.lisp - where characters come from and go.
;;;
;;; Both halves of the machine's I/O rest on this: the reader takes characters
;;; from the current stream and the printer puts them there, so the same code
;;; serves the serial console, a window, and a source file the forge hands
;;; over as a string. It is a file of its own because the reader needs it and
;;; the reader has to be up before the printer is.

(in-package lm)

;; ---------------------------------------------------------------- streams
;; A stream is three closures: put a character, take one or answer nil, and
;; block until there might be one. The printer was always written against the
;; first of those; giving the reader the same shape is what lets a REPL run in
;; a window as readily as on the serial line.
;;
;; They are three globals rather than one object because every character read
;; and written goes through them, and because that makes the default - nil,
;; meaning the serial port - free. What makes them per task is the scheduler,
;; which saves them into the outgoing task and loads the incoming one's, the
;; same way it does the registers.
(define *out* nil)
(define *in* nil)
;; How to wait for a character - not Exec's `wait`, which blocks a task on
;; signals. A stream that has no answer falls back on the machine's.
(define *await* nil)

;; A character, not its number: `get-char` gives one back, and a pair of
;; primitives that disagree about that is a `%int->char` at every call site
;; and a wrong one somewhere.
(define (out-char c) (%st-fixnum! uart-data (%char->int c)))

(define (uart-char)
  (let ((v (%ld-fixnum uart-data)))
    (if (%= v -1) nil (%int->char v))))

(define (emit-ch c)
  (if *out* (%funcall *out* c) (out-char c)))

;; A character if one is ready, nil otherwise. Never blocks.
(define (get-char)
  (if *in* (%funcall *in*) (uart-char)))

;; Give the machine to somebody else until input might have arrived.
(define (await-char)
  (if *await* (%funcall *await*) (%wait-for-input)))

;; Slot 0 is the tag, so a stream says what it is.
(define stream-slots 4)
(define st-put 1)
(define st-get 2)
(define st-await 3)

(define (make-stream put get await)
  (let ((s (make-record stream-slots 'stream)))
    (%record-set! s st-put put)
    (%record-set! s st-get get)
    (%record-set! s st-await await)
    s))
(define (stream-put s) (%record-ref s st-put))
(define (stream-get s) (%record-ref s st-get))
(define (stream-await s) (%record-ref s st-await))

(define (current-stream) (make-stream *out* *in* *await*))

(define (use-stream! s)
  (set! *out* (stream-put s))
  (set! *in* (stream-get s))
  (set! *await* (stream-await s))
  s)

;; The serial line, named so it can be switched back to.
(define (console-stream) (make-stream nil nil nil))

(define (emit-str s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (emit-ch (%string-ref s i))
      (set! i (%+ i 1)))
    s))

(define (newline) (emit-ch #\newline) nil)
(define (space) (emit-ch #\space) nil)

;; Collect output into a string instead of sending it anywhere.
(define (with-output-to-string thunk)
  (let ((acc nil) (saved *out*))
    (set! *out* (lambda (c) (set! acc (%cons c acc))))
    (%funcall thunk)
    (set! *out* saved)
    (list->string (reverse acc))))

;; ---------------------------------------------------------------- printing
