;;; stream.lisp - where characters come from and go.
;;;
;;; The reader takes characters from the current input stream and the printer
;;; puts them on the current output stream, so the same code serves the serial
;;; console, a window and a string. A stream is three closures: put a
;;; character, take one or answer nil, and block until one might be there.

(in-package lm)

;; The current streams are three globals rather than one object because every
;; character read or written goes through them, and because nil, the raw
;; serial line, is then free. The scheduler makes them per task by swapping
;; the running task's fluid bindings (see macros.lisp and exec.lisp).
(define *out* nil)
(define *in* nil)
;; How to wait for input. Not Exec's `wait`, which blocks on signals: a stream
;; with no answer falls back on halting the processor until an interrupt.
(define *await* nil)

;; The raw serial line takes and gives characters, not their codes.
(define (out-char c)
  (unsafe (%st-fixnum! uart-data (%char->int c))))

(define (uart-char)
  (unsafe
  (let ((v (%ld-fixnum uart-data)))
    (if (%= v -1) nil (%int->char v)))))

(define (emit-ch c)
  (if *out* (%funcall *out* c) (out-char c)))

;; A character if one is ready, nil otherwise. Never blocks.
(define (get-char)
  (if *in* (%funcall *in*) (uart-char)))

;; Give the processor away until input might have arrived.
(define (await-char)
  (unsafe
  (if *await* (%funcall *await*) (%wait-for-interrupt))))

(defrecord stream put get await)

(define (make-stream put get await)
  (let ((s (stream-alloc)))
    (set-stream-put! s put)
    (set-stream-get! s get)
    (set-stream-await! s await)
    s))

(define (current-stream) (make-stream *out* *in* *await*))

(define (use-stream! s)
  (set! *out* (stream-put s))
  (set! *in* (stream-get s))
  (set! *await* (stream-await s))
  s)

;; The raw serial line as a stream, for switching back to. The console proper
;; is console.driver's: see console.lisp.
(define (serial-stream) (make-stream nil nil nil))

(define (emit-str s)
  (let ((i 0) (n (%string-length s)))
    (while (%< i n)
      (emit-ch (%string-ref s i))
      (set! i (%+ i 1)))
    s))

(define (newline) (emit-ch #\newline) nil)
(define (space) (emit-ch #\space) nil)

;; Run the thunk with output collected into a string. A fluid binding, so that
;; an error inside leaves `*out*` for the prompt's restart to put back, rather
;; than pointing at a dead accumulator for good.
(define (with-output-to-string thunk)
  (let ((acc nil))
    (fluid-let ((*out* (lambda (c) (set! acc (%cons c acc)))))
      (%funcall thunk))
    (list->string (reverse acc))))
