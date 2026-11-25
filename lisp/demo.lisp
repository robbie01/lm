;;; demo.lisp - things to type at the prompt.
;;;
;;; These ship inside the kickstart. Between them they use every part of the
;;; machine: preemptive tasks drawing into their own windows, the blitter for
;;; the parts that move whole rectangles, the vertical blank for timing, the
;;; kernel's ports and mutexes, the drivers, and the compiler itself.

(in-package user)

(define (screen)
  (if *screen*
      *screen*
      (gfx:open-screen screen-width screen-height)))

;; ---------------------------------------------------------------- balls
;; One task per ball, all of them drawing into one window. They coordinate
;; about nothing: the worst they can do is spoil their own window.
(define (ball-task win colour seed)
  (let ((bw (win-inner-w win)) (bh (win-inner-h win)))
    (lambda ()
      (let ((x (%mod seed (%- bw 20)))
            (y (%mod (%* seed 7) (%- bh 20)))
            (dx (if (%= 0 (%mod seed 2)) 3 -2))
            (dy (if (%= 0 (%mod seed 3)) 2 -3))
            (r 8))
        (while t
          (win-fill win x y r r white)
          (set! x (%+ x dx))
          (set! y (%+ y dy))
          ;; Turn round and step back inside, or the ball is one column out,
          ;; which is inside the window frame.
          (if (%< x 0) (begin (set! x 0) (set! dx (%- 0 dx))) nil)
          (if (%> x (%- bw r)) (begin (set! x (%- bw r)) (set! dx (%- 0 dx))) nil)
          (if (%< y 0) (begin (set! y 0) (set! dy (%- 0 dy))) nil)
          (if (%> y (%- bh r)) (begin (set! y (%- bh r)) (set! dy (%- 0 dy))) nil)
          (win-fill win x y r r colour)
          (present win))))))

(define (balls . opts)
  (let ((n (if (%cons? opts) (%car opts) 8))
        (win (make-demo-window 420 300 "Balls")))
    (win-fill win 0 0 (win-inner-w win) (win-inner-h win) white)
    ;; The window's task starts the balls as its children and then has
    ;; nothing more to do, so closing the window ends every ball with it.
    (set-win-task! win (add-task "balls" 0 (lambda () (start-balls win n))))
    win))

;; The named colours from 2, after black and white: a white ball on the
;; white field would not be seen.
(define (start-balls win n)
  (let ((i 0))
    (while (%< i n)
      (spawn (string-append "ball" (number->string i))
             0
             (ball-task win (%+ 2 (%mod i 11)) (%+ 3 (%* i 37))))
      (set! i (%+ i 1))))
  (wait (exec::alloc-signal (this-task))))

;; ---------------------------------------------------------------- mandelbrot
;; Fixed point with twelve fractional bits. A fixnum holds thirty-one bits and
;; a sign, and the intermediate products here reach twenty-eight, which is why
;; the escape radius is checked against four rather than something more
;; generous.
(defconstant fp-bits 12)
(defconstant fp-one 4096)

(define (mandel-point cr ci limit)
  (let ((zr 0) (zi 0) (i 0) (done nil))
    (while (if done nil (%< i limit))
      (let* ((zr2 (%ash (%* zr zr) (%- 0 fp-bits)))
             (zi2 (%ash (%* zi zi) (%- 0 fp-bits))))
        (if (%> (%+ zr2 zi2) (%* 4 fp-one))
            (set! done t)
            (begin
              (set! zi (%+ (%ash (%* 2 (%ash (%* zr zi) (%- 0 fp-bits))) 0) ci))
              (set! zr (%+ (%- zr2 zi2) cr))
              (set! i (%+ i 1))))))
    i))

;; A window of its own, and a row of it handed over every sixteen, so the
;; picture appears in bands.
(define (mandelbrot . opts)
  (let* ((limit (if (%cons? opts) (%car opts) 40))
         (win (make-demo-window 420 320 "Mandelbrot"))
         (bw (win-inner-w win))
         (bh (win-inner-h win))
         (y 0))
    (while (%< y bh)
      (let ((x 0)
            ;; -1.2 .. 1.2 over the height
            (ci (%- (%/ (%* y (%* 24 fp-one)) (%* 10 bh))
                    (%/ (%* 12 fp-one) 10))))
        (while (%< x bw)
          (let* ((cr (%- (%/ (%* x (%* 3 fp-one)) bw) (%* 2 fp-one)))
                 (n (mandel-point cr ci limit)))
            (win-plot win x y (if (%>= n limit) black (%+ 16 (%mod (%* n 7) 200)))))
          (set! x (%+ x 1))))
      (set! y (%+ y 1))
      (if (%= 0 (%mod y 16)) (present win) nil))
    (window-damage win)
    win))

;; ---------------------------------------------------------------- life
;; Conway's life. The window's own bitmap is the board: a cell is alive if
;; it is black, and the counting is done against a back buffer so that every
;; cell sees the same generation.
(define *life-back* nil)

(define *life-win* nil)
(define *life-w* 0)
(define *life-h* 0)

(define (life-seed density)
  (let ((w (win-inner-w *life-win*)) (h (win-inner-h *life-win*)))
    (set! *life-w* w)
    (set! *life-h* h)
    (set! *life-back* (make-bytes (%* w h)))
    (win-fill *life-win* 0 0 w h white)
    (let ((y 1))
      (while (%< y (%- h 1))
        (let ((x 1))
          (while (%< x (%- w 1))
            (if (%< (%mod (random) 100) density)
                (win-plot *life-win* x y black)
                nil)
            (set! x (%+ x 1))))
        (set! y (%+ y 1)))))
  'seeded)

;; Direct loads and stores into the bitmap's pixels, so the blitter's work on
;; them has to have landed first: the window was filled by a blit, and a blit
;; is not done when it returns.
(define (life-step)
  (blit-sync)
  (let ((y 1)
        (w *life-w*)
        (h *life-h*)
        (back *life-back*)
        (pixels (bm-pixels (window-bitmap *life-win*)))
        (stride (win-w *life-win*)))
    (while (%< y (%- h 1))
      (let ((x 1) (row (win-row *life-win* y)))
        (while (%< x (%- w 1))
          (let* ((p (%+ row x))
                 (up (%- p stride))
                 (dn (%+ p stride))
                 (n (%+ (%+ (%+ (live? pixels (%- up 1)) (live? pixels up))
                            (%+ (live? pixels (%+ up 1)) (live? pixels (%- p 1))))
                        (%+ (%+ (live? pixels (%+ p 1)) (live? pixels (%- dn 1)))
                            (%+ (live? pixels dn) (live? pixels (%+ dn 1))))))
                 (alive (live? pixels p)))
            (bytes-set! back (%+ (%* y w) x)
                        (if (%= alive 1)
                            (if (if (%= n 2) t (%= n 3)) 1 0)
                            (if (%= n 3) 1 0))))
          (set! x (%+ x 1))))
      (set! y (%+ y 1)))
    ;; And back, a row at a time: the board is w wide and the bitmap is not.
    (set! y 1)
    (while (%< y (%- h 1))
      (let ((x 1) (row (win-row *life-win* y)))
        (while (%< x (%- w 1))
          (bytes-set! pixels (%+ row x)
                      (if (%= 1 (bytes-ref back (%+ (%* y w) x))) black white))
          (set! x (%+ x 1))))
      (set! y (%+ y 1))))
  (present *life-win*)
  nil)

(define (live? pixels i) (if (%= (bytes-ref pixels i) black) 1 0))

(define (life . opts)
  (let ((n (if (%cons? opts) (%car opts) 60)))
    (set! *life-win* (make-demo-window 260 200 "Life"))
    (life-seed 28)
    (let ((i 0))
      (while (%< i n)
        (life-step)
        (set! i (%+ i 1))))
    *life-win*))

;; ---------------------------------------------------------------- self-test
;; Compile a function on the machine, time it, and run it.
(define (selftest)
  (unsafe
  (emit-str "compiling a function on the machine...\n")
  (let ((t0 (%cycles)))
    (eval '(define (ackermann m n)
             (cond ((= m 0) (+ n 1))
                   ((= n 0) (ackermann (- m 1) 1))
                   (else (ackermann (- m 1) (ackermann m (- n 1)))))))
    (emit-str "  compiled in ")
    (emit-str (number->string (%- (%cycles) t0)))
    (emit-str " cycles\n"))
  (let ((t1 (%cycles)))
    (emit-str "  (ackermann 2 6) = ")
    (write (funcall 'ackermann 2 6))
    (emit-str " in ")
    (emit-str (number->string (%- (%cycles) t1)))
    (emit-str " cycles\n"))
  (emit-str "  code now ")
  (emit-str (number->string (%lsh (code-bytes) -10)))
  (emit-str "k\n")
  'ok))

(define (help)
  (emit-str "\n")
  (emit-str "  (in-package wb)        read names in another package\n")
  (emit-str "  (all-packages)         what there is to be in\n")
  (emit-str "  (room)                 heap and code usage\n")
  (emit-str "  (gc)                   collect now\n")
  (emit-str "  (tasks)                what every task is doing\n")
  (emit-str "  (selftest)             compile a function and run it\n")
  (emit-str "  (screen)               open the display\n")
  (emit-str "  (workbench)            windows, with a shell in each\n")
  (emit-str "  (new-shell)            another shell window\n")
  (emit-str "  (eyes)                 xeyes; call it more than once\n")
  (emit-str "  (explorer)             every symbol in the heap, in a window\n")
  (emit-str "  (explore x)            any object, opened up\n")
  (emit-str "  (balls 6)              six tasks, one window\n")
  (emit-str "  (mandelbrot)           fixed point, straight to the bitmap\n")
  (emit-str "  (life 200)             life, with the blitter for the copy\n")
  (emit-str "  (check)                every suite, counted; the machine stops with the verdict\n")
  (emit-str "  (numbers) (words) (nesting) (talking) (locking) (blitting)\n")
  (emit-str "  (devices) (drivers) (capabilities)\n")
  (emit-str "                         check one part of the machine each\n")
  (emit-str "  (save-image)           write this machine to the disk\n")
  (emit-str "  bye                    stop the machine\n")
  nil)

;; ---------------------------------------------------------------- numbers
;; `(numbers)` checks that arithmetic is one thing rather than two. A fixnum
;; that outgrows thirty-two bits becomes a bignum, a bignum that shrinks back
;; becomes a fixnum again, and nothing in between has to be asked which it is
;; holding, so the cases here are the boundaries.
(define *check-count* 0)
(define *check-failures* 0)

(define (num-check name got want)
  (set! *check-count* (+ *check-count* 1))
  (if (equal? got want)
      nil
      (begin (set! *check-failures* (+ *check-failures* 1))
             (princ "FAIL ") (princ name) (princ ": got ") (princ got)
             (princ ", wanted ") (princ want) (newline))))

;; Every suite, counted, and then the machine stops: exit code 0 if every
;; check held and 1 if not. `lmdev check` boots an image and types this.
(define (check)
  (unsafe
  (set! *check-count* 0)
  (set! *check-failures* 0)
  (numbers) (words) (nesting) (talking) (locking) (blitting) (devices)
  (drivers) (capabilities)
  (princ *check-count*) (princ " checks, ")
  (princ *check-failures*) (princ " failed") (newline)
  (%halt (if (= *check-failures* 0) exit-ok exit-error))))

(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))

(define (numbers)
  (num-check 'small (+ 2 3) 5)
  (num-check 'most-positive most-positive-fixnum 2147483647)
  (num-check 'promote (+ 2147483647 1) 2147483648)
  (num-check 'demote (- (+ 2147483647 1) 1) 2147483647)
  ;; and it really is a fixnum again, not a bignum that prints small
  (num-check 'demoted-is-fixnum (%fixnum? (- (+ 2147483647 1) 1)) t)
  (num-check 'below-most-negative (- -2147483648 1) -2147483649)
  (num-check 'most-negative (- 0 -2147483648) 2147483648)
  (num-check 'most-negative-print (number->string -2147483648) "-2147483648")
  (num-check 'literal 12345678901234567890 (* 1234567890123456789 10))
  (num-check 'fact-20 (fact 20) 2432902008176640000)
  (num-check 'fact-25 (fact 25) 15511210043330985984000000)
  (num-check 'quotient (quotient 100000000000000 7) 14285714285714)
  (num-check 'remainder (remainder 100000000000000 7) 2)
  (num-check 'negative-quotient (quotient -100000000000000 7) -14285714285714)
  (num-check 'negative-remainder (remainder -100000000000000 7) -2)
  (num-check 'compare (list (< (fact 20) (fact 21))
                            (> (fact 20) (fact 21))
                            (= (fact 20) (fact 20)))
             (list t nil t))
  (num-check 'mixed (+ (fact 25) 1) 15511210043330985984000001)
  (num-check 'cancel (- (fact 25) (fact 25)) 0)
  (num-check 'abs (abs (- 0 (fact 25))) (fact 25))
  (num-check 'min-max (list (min 3 (fact 25)) (max 3 (fact 25)))
             (list 3 (fact 25)))
  (num-check 'parity (list (even? (fact 25)) (odd? (fact 25))) (list t nil))
  (num-check 'shift-left (ash 1 100) 1267650600228229401496703205376)
  (num-check 'shift-right (ash (ash 1 100) -99) 2)
  (num-check 'shift-floors (ash -1025 -5) -33)
  (num-check 'eqv (eqv? (fact 25) (fact 25)) t)
  (num-check 'not-eq (eq? (fact 25) (fact 25)) nil)
  (num-check 'sort (sort (list (fact 21) 5 (fact 20)) num-lt)
             (list 5 (fact 20) (fact 21)))
  (num-check 'wrapping (wrap+ 2147483647 1) -2147483648)
  (num-check 'saturating (sat* 1000000 1000000) most-positive-fixnum)
  (princ "numbers: done (nothing above = all correct)")
  (newline))

;; ---------------------------------------------------------------- words
;; `(words)` checks the other half of the number question: a machine word is
;; a fixnum. `peek` reads the word at an address as a number from -2^31 to
;; 2^31-1 and `poke` stores one back unchanged, so no word needs a bignum on
;; the way in or out, and a value that is not a word is refused rather than
;; cut down to one. The words are a byte object's, by address.
(define (words)
  (unsafe
  (let* ((b (make-bytes 16)) (p (%addr-of b)))
    ;; a word with its top bit set, built a byte at a time, is the most
    ;; negative fixnum
    (poke p 0)
    (poke8 (%+ p 3) 128)
    (num-check 'top-bit (peek p) -2147483648)
    (num-check 'top-bit-is-fixnum (%fixnum? (peek p)) t)
    (poke p -1)
    (num-check 'all-ones (peek p) -1)
    (num-check 'all-ones-top-byte (peek8 (%+ p 3)) 255)
    (poke p 2147483647)
    (num-check 'most-positive (peek p) 2147483647)
    (poke p #x12345678)
    (num-check 'little-endian
               (list (peek8 p) (peek8 (%+ p 1)) (peek8 (%+ p 2)) (peek8 (%+ p 3)))
               (list #x78 #x56 #x34 #x12))
    (num-check 'peek-is-the-load (%ld-word p) #x12345678)
    (princ "words: the errors below are on purpose")
    (newline)
    (num-check 'wider-than-a-word-is-refused (refused? (lambda () (poke p 2147483648))) t)
    (num-check 'not-a-number-is-refused (refused? (lambda () (poke p "word"))) t)
    (num-check 'a-refused-poke-stores-nothing (peek p) #x12345678)
    (num-check 'and-the-bytes-are-the-words (bytes-ref b 3) #x12))
  (princ "words: done (nothing above = all correct)")
  (newline)))

;; ---------------------------------------------------------------- nesting
;; A trap taken while the trap handler is already running. The server below
;; runs from the vertical blank, which means it runs inside the handler, and
;; its arithmetic outgrows a fixnum, which widens through the trap handler:
;; a trap inside a trap.
(define *nest-hits* 0)
(define *nest-last* 0)
(define *nest-int* nil)

(define (nesting . opts)
  (unsafe
  (let ((n (if (%cons? opts) (%car opts) 300)))
    (set! *nest-hits* 0)
    (set! *nest-last* 0)
    (set! *nest-int*
          (exec::make-interrupt "nesting" 0
            (lambda (d)
              (set! *nest-hits* (+ *nest-hits* 1))
              ;; both of these widen, so both of them trap
              (set! *nest-last* (* 1000000 (+ 1000000 *nest-hits*)))
              nil)
            0))
    (exec::add-int-server int-vblank *nest-int*)
    (while (%< *nest-hits* n) (wait-vblank))
    (exec::remove-int-server int-vblank *nest-int*)
    (num-check 'nested-result *nest-last*
               (* 1000000 (+ 1000000 *nest-hits*)))
    (num-check 'depth-unwound (peek lg-trapdepth) 0)
    (princ "nesting: ") (princ *nest-hits*)
    (princ " traps taken inside the trap handler, all of them survived")
    (newline))))

;; ---------------------------------------------------------------- talking
;; `(talking)` exercises the way tasks reach anything they do not own: by
;; sending it a message. There is no device registry: a driver is a task with
;; a port, reached by naming the symbol that holds it.
(define *talk-server* nil)

(define (talking)
  ;; A server. The handler is called with whatever was sent and its answer
  ;; goes back in the same message.
  (set! *talk-server*
        (make-server "arith" 0
          (lambda (body)
            (cond ((eq? (%car body) 'add) (+ (cadr body) (caddr body)))
                  ((eq? (%car body) 'mul) (* (cadr body) (caddr body)))
                  (else 'what)))))
  (let ((p (server-port *talk-server*)))
    (num-check 'request (request p (list 'add 2 3)) 5)
    ;; and it is ordinary arithmetic on the other side, bignums and all
    (num-check 'request-promotes (request p (list 'mul 1000000 1000000))
               1000000000000)
    (num-check 'request-again (request p (list 'add 10 20)) 30)

    ;; Select. A task has one blocker, so listening in two places is one
    ;; `wait` over both masks.
    (let ((a (make-port nil 0))
          (b (make-port nil 0)))
      (spawn "sender" 0 (lambda () (wait-vblank)
                                   (put-message b (make-message 'from-b nil))))
      (let ((hit (wait-ports (list a b))))
        (num-check 'select-b (eq? hit b) t)
        (num-check 'select-body (message-body (get-message hit)) 'from-b))
      (put-message a (make-message 'from-a nil))
      (let ((hit (wait-ports (list a b))))
        (num-check 'select-a (eq? hit a) t)
        (num-check 'select-body-a (message-body (get-message hit)) 'from-a))
      (delete-port a)
      (delete-port b))

    ;; Dependent tasks. A child ends with its parent, so a server that fans
    ;; work out does not have to remember what it started.
    (let ((me (this-task)) (parent nil))
      (set! parent
            (add-task "parent" 0
              (lambda ()
                (spawn "kid-one" 0 (lambda () (wait 262144)))
                (spawn "kid-two" 0 (lambda () (wait 262144)))
                (signal me 65536)
                (wait 131072))))
      (wait 65536)
      (num-check 'children (length (task-children parent)) 2)
      (remove-task parent)
      (num-check 'children-gone (find-task "kid-one") nil))

    ;; An interrupt server does not draw: this is a task.
    (num-check 'blitter-is-task-context
               (if hw::*in-interrupt* 'in-interrupt 'task) 'task)

    ;; Waiting for a moment. A sleep takes at least what it asked for; a
    ;; wait that times out answers 0; a signal that comes first answers
    ;; itself, and the deadline it beat does not wake the next wait.
    (let ((t0 (now-ms)))
      (sleep 30)
      (num-check 'slept-long-enough (>= (- (now-ms) t0) 30) t))
    (num-check 'timed-out (wait-timeout 65536 20) 0)
    (let ((me (this-task)))
      (add-task "knocker" 0 (lambda () (sleep 10) (signal me 65536)))
      (num-check 'signal-beat-the-clock (wait-timeout 65536 1000) 65536)
      (num-check 'old-deadline-forgotten (wait-timeout 65536 40) 0)))
  (tasks-come-and-go)
  (princ "talking: done (nothing above = all correct)")
  (newline))

;; A task's stack and its register context are objects, which the collector
;; takes back with the task: a thousand tasks that have come and gone, a
;; hundred at a time, leave object space as they found it, give or take less
;; than one stack.
(define (brief-tasks n)
  (let ((i 0) (made nil))
    (while (< i n)
      (set! made (cons (add-task "brief" 0 (lambda () (list 1 2 3))) made))
      (set! i (+ i 1)))
    (dolist (task made) (while (task-alive? task) (sleep 10)))))

(define (tasks-come-and-go)
  (gc)
  (let ((used (object-bytes-used)) (i 0))
    (while (< i 10)
      (brief-tasks 100)
      (set! i (+ i 1)))
    (gc)
    (gc)
    (num-check 'a-thousand-tasks-leave-nothing
               (< (- (object-bytes-used) used) exec::default-stack)
               t)))

;; ---------------------------------------------------------------- locking
;; `(locking)` checks the rules about waiting and the mutex: a critical
;; section never sleeps, and shared data that has to be waited for is guarded
;; by a lock that belongs to somebody.
;;
;; What should be an error is tried in a task of its own, which ends when the
;; error comes. Checking that the task ended, and what it left behind, is how
;; this can watch an error happen and carry on.
;;
;; Nothing here waits a fixed time. Every wait is for the condition about to
;; be checked, bounded so that a task which never gets there fails its check
;; instead of hanging the test. How long a task takes to get anywhere depends
;; on what else the machine is doing: with a collection in progress, a fresh
;; task's first cons pays the collector for its whole run.
(defconstant lk-patience 1200)  ; vblanks: twenty seconds of the machine's clock

;; Waits until `pred` holds, or patience runs out. Answers what `pred` does.
(define (lk-until pred)
  (let ((n 0))
    (while (if (pred) nil (< n lk-patience))
      (wait-vblank)
      (set! n (+ n 1)))
    (pred)))

(define (lk-ended? task) (%= (exec::tc-state task) exec::ts-removed))
(define (lk-asleep? task) (%= (exec::tc-state task) exec::ts-wait))
(define (lk-queued-on? task m) (eq? (exec::tc-blocked-on task) m))

(define (lk-wait-ended task) (lk-until (lambda () (lk-ended? task))))
(define (lk-wait-queued task m) (lk-until (lambda () (lk-queued-on? task m))))

;; Asleep in `wait`, holding `m`.
(define (lk-wait-holding task m)
  (lk-until (lambda () (if (lk-asleep? task) (eq? (mutex-owner m) task) nil))))

(define (lk-try name thunk)
  (let ((task (add-task name 0 thunk)))
    (lk-wait-ended task)
    task))

(define (locking)
  (let ((m (make-mutex "test"))
        (me (this-task)))
    ;; Owned, nested, let go.
    (num-check 'lock (mutex-lock m) t)
    (num-check 'owner (eq? (mutex-owner m) me) t)
    (num-check 'nests (mutex-lock m) t)
    (mutex-unlock m)
    (num-check 'still-held (eq? (mutex-owner m) me) t)
    (mutex-unlock m)
    (num-check 'free (mutex-owner m) nil)

    ;; Only the owner lets go.
    (mutex-lock m)
    (let ((thief (lk-try "thief" (lambda () (mutex-unlock m)))))
      (num-check 'unlock-by-another-is-an-error (lk-ended? thief) t)
      (num-check 'still-mine (eq? (mutex-owner m) me) t))
    (mutex-unlock m)

    ;; Nothing sleeps with interrupts off, and the machine carries on: the
    ;; task that tried ends, and the interrupts come back on.
    (let ((a (lk-try "sleeper" (lambda () (without-interrupts (wait-vblank)))))
          (b (lk-try "yielder" (lambda () (without-interrupts (reschedule)))))
          (c (lk-try "locker" (lambda () (without-interrupts (mutex-lock m))))))
      (num-check 'wait-in-disable (lk-ended? a) t)
      (num-check 'reschedule-in-disable (lk-ended? b) t)
      (num-check 'lock-in-disable (lk-ended? c) t)
      (num-check 'interrupts-back (interrupts-on?) t)
      (num-check 'lock-untouched (mutex-owner m) nil))

    ;; Handed over directly: the waiter wakes holding it.
    (mutex-lock m)
    (let* ((got nil)
           (waiter (add-task "waiter" 0 (lambda () (mutex-lock m) (set! got t) (mutex-unlock m)))))
      (num-check 'waiter-queues (lk-wait-queued waiter m) t)
      (num-check 'waiter-waits got nil)
      (mutex-unlock m)
      (num-check 'waiter-ends (lk-wait-ended waiter) t)
      (num-check 'waiter-got-it got t)
      (num-check 'waiter-let-go (mutex-owner m) nil))

    ;; Abandoned by an error inside with-mutex: the next owner is told,
    ;; through the repair, which with-mutex runs before its own body.
    (let* ((repaired nil)
           (r (make-mutex "repairable" (lambda (x) (set! repaired t))))
           (dier (lk-try "dier" (lambda () (with-mutex r (car 5))))))
      (num-check 'dier-ended (lk-ended? dier) t)
      (num-check 'abandoned-is-free (mutex-owner r) nil)
      (with-mutex r (num-check 'repair-ran-first repaired t))
      (num-check 'told-once (mutex-lock r) t)
      (mutex-unlock r))

    ;; And by a task that ended holding it.
    (let ((q (make-mutex "quitter")))
      (lk-try "quitter" (lambda () (mutex-lock q)))
      (num-check 'ended-holding-it (mutex-lock q) 'abandoned)
      (mutex-unlock q))

    ;; Given away on purpose.
    (let ((h (make-mutex "gift"))
          (taker (add-task "taker" 0 (lambda () (wait 65536)))))
      (num-check 'taker-sleeps (lk-until (lambda () (lk-asleep? taker))) t)
      (mutex-lock h)
      (mutex-hand-over h taker)
      (num-check 'handed-over (eq? (mutex-owner h) taker) t)
      (num-check 'gone-from-me (eq? (mutex-owner h) me) nil)
      (signal taker 65536)
      (num-check 'taker-ends (lk-wait-ended taker) t)
      (num-check 'taker-ended-holding-it (mutex-lock h) 'abandoned)
      (mutex-unlock h))

    ;; A circle is an error, not a hang. `one` holds m1 and waits for m2;
    ;; `two` holds m2 and asks for m1, and is refused. What `two` held goes
    ;; to `one`, abandoned, and `one` finishes.
    (let* ((m1 (make-mutex "m1"))
           (m2 (make-mutex "m2"))
           (one (add-task "one" 0 (lambda ()
                                    (mutex-lock m1) (wait 65536)
                                    (mutex-lock m2) (mutex-unlock m2)
                                    (mutex-unlock m1))))
           (two (add-task "two" 0 (lambda ()
                                    (mutex-lock m2) (wait 65536)
                                    (mutex-lock m1)))))
      (num-check 'one-holds-m1 (lk-wait-holding one m1) t)
      (num-check 'two-holds-m2 (lk-wait-holding two m2) t)
      (signal one 65536)
      (num-check 'one-queues-on-m2 (lk-wait-queued one m2) t)
      (signal two 65536)
      (num-check 'circle-refused (lk-wait-ended two) t)
      (num-check 'circle-broken (lk-wait-ended one) t)
      (num-check 'm1-free (mutex-owner m1) nil))

    ;; A waiter lends its priority to the owner, and the owner gives it back.
    (let* ((p (make-mutex "pri"))
           (low (add-task "low" 0 (lambda () (mutex-lock p) (wait 65536) (mutex-unlock p))))
           (high nil))
      (num-check 'low-holds-it (lk-wait-holding low p) t)
      (set! high (add-task "high" 5 (lambda () (mutex-lock p) (mutex-unlock p))))
      (num-check 'high-queues (lk-wait-queued high p) t)
      (num-check 'lent (exec::node-pri low) 5)
      (signal low 65536)
      (num-check 'high-got-it (lk-wait-ended high) t)
      (num-check 'given-back (exec::node-pri low) 0)))
  (princ "locking: done (nothing above = all correct)")
  (newline))

;; ---------------------------------------------------------------- blitting
;; `(blitting)` checks that the blitter is asynchronous, and that waiting for
;; it means what it says: two blits in a row through one task's descriptors
;; is what every drawing task does and what the collector does to clear its
;; maps.

;; The first pixel of a bitmap, read without waiting for the blitter.
(define (first-pixel b) (bytes-ref (bm-pixels b) 0))

;; A blit of w by h with rows w apart, from `src` to `dst`, filled in by hand
;; through a descriptor of this task's ring and waited for. Answers the done
;; word the chip wrote back.
(define (blit-probe op dst src w h)
  (let ((d (unsafe (blit-descriptor))))
    (%cap-st! d bl-dst dst)
    (%cap-st! d bl-src src)
    (%cap-st-word! d bl-w w)
    (%cap-st-word! d bl-h h)
    (%cap-st-word! d bl-smod w)
    (%cap-st-word! d bl-dmod w)
    (%cap-st-word! d bl-val 3)
    (unsafe (blit-go d op))
    (blit-sync)
    (%cap-ld-word d bl-status)))

(define (all-bytes? b from to v)
  (let ((same t))
    (while (%< from to)
      (if (%= (bytes-ref b from) v) nil (set! same nil))
      (set! from (%+ from 1)))
    same))

;; Start a ring's worth of long fills into a fresh bitmap and drop it: the
;; only things left holding the pixels are the descriptors the chip is
;; working through, about a million and a half cycles of them. Answers their
;; address, which is a number and keeps nothing alive.
(define (blit-and-drop)
  (let ((b (alloc-bitmap 1024 768)) (i 0))
    (while (< i hw::blit-ring-size)
      (bm-fill-rect b 0 0 1024 768 (+ i 1))
      (set! i (+ i 1)))
    (%addr-of (bm-pixels b))))

(define (blitting)
  (let ((a (alloc-bitmap 256 256))
        (b (alloc-bitmap 256 256)))
    ;; A blit is not done when it returns: read too early and you see the
    ;; old pixel.
    (bytes-set! (bm-pixels a) 0 7)
    (bm-fill-rect a 0 0 256 256 42)
    (num-check 'not-landed-yet (first-pixel a) 7)
    (blit-sync)
    (num-check 'landed-after-sync (first-pixel a) 42)
    ;; Back to back. The second commit waits for the first, and the first
    ;; one's write-back must not mark the second done.
    (bytes-set! (bm-pixels b) 0 9)
    (bm-fill-rect a 0 0 256 256 1)
    (bm-fill-rect b 0 0 256 256 2)
    (blit-sync)
    (num-check 'second-of-two-landed (first-pixel b) 2)
    (num-check 'first-of-two-landed (first-pixel a) 1)
    ;; A big one does not hold the machine up while it runs: the commit is a
    ;; few hundred cycles, and the transfer happens while others run.
    (let ((big (alloc-bitmap 1024 768)))
      (blit-drain)
      (let ((t0 (%cycles)))
        (bm-fill-rect big 0 0 1024 768 5)
        (num-check 'big-commit-is-quick (%< (%- (%cycles) t0) 10000) t))
      (blit-sync)
      (num-check 'big-landed (first-pixel big) 5))
    ;; A chain: a blit queued behind a big one does not wait for it, and the
    ;; two land in order.
    (let ((big (alloc-bitmap 1024 768)) (small (alloc-bitmap 16 16)))
      (blit-drain)
      (bm-fill-rect big 0 0 1024 768 6)
      (let ((t0 (%cycles)))
        (bm-fill-rect small 0 0 16 16 7)
        (num-check 'queued-behind-a-big-one-is-quick (%< (%- (%cycles) t0) 5000) t))
      (num-check 'and-the-big-one-still-running (blit-busy?) t)
      (blit-sync)
      (num-check 'the-queued-one-landed (first-pixel small) 7)
      (num-check 'after-the-big-one (first-pixel big) 6))
    ;; More blits than a ring has descriptors: taking one waits for the chip
    ;; to be done with it, and every one of them lands.
    (let ((bs nil) (i 0))
      (while (%< i 20)
        (let ((b (alloc-bitmap 8 8)))
          (bm-fill-rect b 0 0 8 8 (%+ i 1))
          (set! bs (%cons b bs)))
        (set! i (%+ i 1)))
      (blit-sync)
      (let ((ok t) (v 20))
        (dolist (b bs)
          (if (%= (first-pixel b) v) nil (set! ok nil))
          (set! v (%- v 1)))
        (num-check 'twenty-through-a-ring-of-eight ok t)))
    ;; The chip is handed capabilities and refuses a transfer they do not
    ;; cover: nothing moves, the done word says which capability refused it
    ;; and why, and the chip's status says that something was refused.
    (let ((v (make-bytes 64)) (src (make-bytes 64)))
      (bytes-set! v 20 7)
      (blit-clear-refused!)
      (num-check 'a-short-destination-is-refused
                 (blit-probe op-fill (%cap-bounds-exact v 16) src 8 4)
                 (logior blit-refused-dst capex-length))
      (num-check 'and-the-chip-says-so (blit-refused?) t)
      (num-check 'and-nothing-moved (list (all-bytes? v 0 16 0) (bytes-ref v 20)) (list t 7))
      (num-check 'a-number-is-no-destination
                 (blit-probe op-fill (%addr-of v) src 8 4)
                 (logior blit-refused-dst capex-tag))
      (num-check 'a-read-only-destination-is-refused
                 (blit-probe op-fill (%cap-and-perms v perm-ld) src 8 4)
                 (logior blit-refused-dst capex-store))
      (num-check 'a-short-source-is-refused
                 (blit-probe op-copy v (%cap-bounds-exact src 8) 8 4)
                 (logior blit-refused-src capex-length))
      (num-check 'and-still-nothing-moved (list (all-bytes? v 0 16 0) (bytes-ref v 20)) (list t 7))
      (blit-clear-refused!)
      (num-check 'the-status-clears (blit-refused?) nil)
      (num-check 'what-they-cover-lands (blit-probe op-fill v src 8 4) blit-done)
      (num-check 'all-of-it (all-bytes? v 0 32 3) t)
      (num-check 'and-nothing-was-refused (blit-refused?) nil))
    ;; A blit in flight keeps its bitmap alive: the descriptor holding the
    ;; pixels nothing else holds is a slot of this task's ring, and a
    ;; collection that reaches the ring while the chip is still filling them
    ;; marks them through it, as it would through any vector, and the fill
    ;; lands in a live object.
    (gc)
    (let ((a (blit-and-drop)))
      (num-check 'a-dropped-bitmap-still-being-filled
                 (list (blit-busy?) gc::*phase*) (list t gc::phase-idle))
      (unsafe (without-interrupts
                (gc::start-cycle)
                (gc::gc-push *blit-ring*)
                (gc::trace-some)))
      (num-check 'is-kept-by-its-descriptor
                 (list (blit-busy?) (unsafe (gc::marked? (- a 8))))
                 (list t t))
      (while (= gc::*phase* gc::phase-marking) (gc::step))
      (gc)
      (blit-sync)
      (num-check 'and-the-fill-landed-in-it (unsafe (%ld-byte (+ a (* 1024 767)))) hw::blit-ring-size)))
  (princ "blitting: done (nothing above = all correct)")
  (newline))

;; ---------------------------------------------------------------- devices
;; `(devices)` checks that possession is ownership. A device is reached only
;; through a capability to its page, which only code that says `unsafe` can
;; make. A driver makes its own when it starts and keeps it in its closures,
;; which are sealed, so nothing a program can name leads to one, and a task
;; without it cannot touch the device.

;; Whether `c` is a capability to a device's page.
(define (device-cap? c)
  (if (%cap-tag? c)
      (let ((b (%cap-base c)))
        (if (>= b mmio-base) (< b (+ mmio-base (* 16 device-page-bytes))) nil))
      nil))

;; Whether a program that says nothing unsafe can load through `c`: tagged,
;; unsealed, with LD and LC, and not code.
(define (loadable? c)
  (if (%cap-tag? c)
      (if (%cap-sealed? c)
          nil
          (let ((ps (%cap-perms c)))
            (if (= (logand ps (logior perm-ld perm-lc)) (logior perm-ld perm-lc))
                (if (= (logand ps perm-ex) 0) (= (logand (%cap-base c) 7) 0) nil)
                nil)))
      nil))

;; The first device capability reachable from `roots` by loading through
;; capabilities the way such a program can, or nil.
(define (loads-reach roots)
  (let ((seen (make-table 65536)) (todo roots) (found nil))
    (while (if found nil (pair? todo))
      (let ((c (car todo)))
        (set! todo (cdr todo))
        (cond ((device-cap? c) (set! found c))
              ((if (loadable? c) (not (table-has? seen c)) nil)
               (table-set! seen c t)
               (let ((at (%cap-set-addr c (%cap-base c))) (n (%cap-len c)) (off 0))
                 (while (<= (+ off 8) n)
                   (let ((v (%cap-ld at off)))
                     (if (%cap-tag? v) (set! todo (cons v todo)) nil))
                   (set! off (+ off 8)))))
              (else nil))))
    found))

;; The first device capability in a closure, or in the closures it holds,
;; opening each with the root: what the closure's own code can reach.
(define (opened-reach f)
  (unsafe
   (let ((o (open-closure f)) (i clo-free) (found nil))
     (while (if found nil (< (* i value-bytes) (%cap-len o)))
       (let ((v (%slot o i)))
         (cond ((device-cap? v) (set! found v))
               ((if (%cap-tag? v) (= (%cap-otype v) otype-closure) nil)
                (set! found (opened-reach v)))
               (else nil)))
       (set! i (+ i 1)))
     found)))

(define (devices)
  (let ((sys (unsafe (device-page dev-sys)))
        (disk (unsafe (device-page dev-disk)))
        (task (server-task disk:*driver*)))
    ;; A page is the device and no more, and only the chips with a
    ;; capability register get SC.
    (num-check 'a-page-is-the-device
               (list (%cap-len sys) (%cap-perms sys) (%cap-perms disk))
               (list device-page-bytes (logior perm-ld perm-sd)
                     (logior perm-ld perm-sd perm-sc)))
    (num-check 'reading-a-register-through-it (> (%cap-ld-word sys hw::sys-ramsize) 0) t)
    ;; Making one is unsafe, and a number is no authority.
    (num-check 'the-compiler-will-not-make-a-page
               (refused? (lambda () (eval '(device-page dev-disk)))) t)
    (num-check 'an-address-is-not-a-device
               (refused? (lambda () (disk-status (+ mmio-base (* dev-disk device-page-bytes)))))
               t)
    ;; The driver holds its page in its closures and nowhere else, and a
    ;; task's stack and saved registers are sealed in its record.
    (num-check 'the-driver-holds-its-page
               (let ((p (opened-reach (exec::tc-fn task))))
                 (if p (list (%cap-base p) (%cap-len p)) nil))
               (list (%cap-base disk) device-page-bytes))
    (num-check 'a-tasks-registers-are-sealed
               (list (%cap-sealed? (exec::tc-context task)) (%cap-sealed? (exec::tc-stack task)))
               (list t t))
    (num-check 'and-cannot-be-read
               (refused? (lambda () (%cap-ld (exec::tc-context task) 0))) t)
    (num-check 'the-walk-finds-a-page-left-lying-about
               (device-cap? (loads-reach (list (list 1 (vector 2 sys))))) t)
    (num-check 'nothing-a-program-can-name-leads-to-one
               (loads-reach (list (unsafe (%ld-cap lg-symlist)) (this-task)))
               nil))
  (princ "devices: done (nothing above = all correct)")
  (newline))

;; ---------------------------------------------------------------- drivers
;; `(drivers)` checks the driver model end to end, on the disk and the
;; keyboard: one task holds each device and every other task asks it, a
;; transfer lets the machine run while it happens, every listener hears every
;; event, and a server that fails or ends answers its callers instead of
;; leaving them blocked. The transfers need a disk: start the machine with
;; --disk FILE; a scratch file will do.
(define *drv-probe* nil)
(define *drv-count* 0)
(define *drv-stuck* nil)

;; A request that hands back whatever came back, failure or not, instead of
;; raising on a failure the way `request` does.
(define (raw-request port body)
  (let* ((r (reply-port))
         (m (make-message body r)))
    (put-message port m)
    (while (%null? (get-message r)) (wait (port-signal r)))
    (message-body m)))

(define (bytes-same? a b)
  (let ((n (bytes-length a)) (i 0) (same (%= (bytes-length a) (bytes-length b))))
    (while (if same (%< i n) nil)
      (if (%= (bytes-ref a i) (bytes-ref b i)) nil (set! same nil))
      (set! i (%+ i 1)))
    same))

(define (drivers)
  (num-check 'disk-driver-running (disk:running?) t)
  ;; Through the driver: out, back, and the same bytes.
  (let ((out (make-bytes 1024)) (in (make-bytes 1024)) (i 0))
    (while (%< i 1024)
      (bytes-set! out i (%logand (%+ (%* i 7) 3) 255))
      (set! i (%+ i 1)))
    (let ((st (disk:write-blocks 40 2 out)))
      (if (%= st 1)
          (begin
            (princ "drivers: no disk attached, so no transfers - start with --disk FILE")
            (newline))
          (begin
            (num-check 'write-through-the-driver st 0)
            (num-check 'read-through-the-driver (disk:read-blocks 40 2 in) 0)
            (num-check 'the-same-bytes-came-back (bytes-same? out in) t)
            ;; The controller is handed the buffer's capability and refuses a
            ;; transfer it does not cover, and moves nothing.
            (let ((small (make-bytes 600)))
              (bytes-set! small 0 7)
              (num-check 'a-read-past-its-buffer-is-refused
                         (disk:read-blocks 40 2 small) disk-refused)
              (num-check 'and-nothing-was-read (bytes-ref small 0) 7)
              (num-check 'a-write-from-a-narrowed-buffer-too
                         (disk:write-blocks 40 1 (%cap-bounds-exact out 256)) disk-refused)
              (num-check 'and-the-disk-is-unchanged
                         (list (disk:read-blocks 40 2 in) (bytes-same? out in)) (list 0 t)))
            ;; And the machine runs while a transfer does: the driver sleeps
            ;; on the controller, and another task counts in the meantime.
            (let ((big (make-bytes (* 512 256)))
                  (sleeps disk:*sleeps*)
                  (counter (spawn "counter" 0
                                  (lambda ()
                                    (while t (set! *drv-count* (%+ *drv-count* 1)))))))
              (set! *drv-count* 0)
              (num-check 'a-big-write (disk:write-blocks 100 256 big) 0)
              (num-check 'the-driver-slept-through-it (%> disk:*sleeps* sleeps) t)
              (num-check 'another-task-ran-meanwhile (%> *drv-count* 0) t)
              (remove-task counter))))))
  ;; The keyboard and mouse. The driver is the one reader, and every
  ;; subscriber gets every event.
  (num-check 'input-driver-running (input:running?) t)
  (let ((a (input:listen)) (b (input:listen)))
    ;; A key with no ascii, so that a workbench, if one is up, lets it go by.
    (input:inject 1 0 200 0)
    (let ((ea (input:next-event a)) (eb (input:next-event b)))
      (num-check 'one-listener-hears
                 (list (%car ea) (cadr ea) (caddr ea) (cadddr ea))
                 (list 'input:key 'input:down 0 200))
      (num-check 'and-so-does-the-other (equal? ea eb) t))
    (input:unlisten a)
    (input:unlisten b))
  ;; The display. The driver holds the chip, the frame clock is a signal,
  ;; and a task whose blit is still running sleeps until the blitter wakes
  ;; it.
  (num-check 'gfx-driver-running (gfx:running?) t)
  (num-check 'wait-vblank-is-the-kernels (wait-vblank) sigf-vblank)
  (let ((big (alloc-bitmap 1024 768)) (sleeps gfx:*sleeps*))
    (bm-fill-rect big 0 0 1024 768 9)
    (blit-sync)
    (num-check 'a-long-blit-is-slept-through (%> gfx:*sleeps* sleeps) t)
    (num-check 'and-it-landed (first-pixel big) 9))
  ;; The console: a driver holds the line, and this prompt reads through it.
  (num-check 'console-driver-running (console:running?) t)
  (num-check 'the-prompt-reads-through-it (port-open? console::*reader*) t)
  ;; A handler that fails answers with a failure, and the server carries on.
  (princ "drivers: the error below is on purpose")
  (newline)
  (let ((s (make-server "fragile" 0
                        (lambda (body)
                          (if (eq? body 'break) (error "fragile: asked to fail") body)))))
    (num-check 'a-failing-handler-answers (failure? (raw-request (server-port s) 'break)) t)
    (num-check 'and-the-server-carries-on (raw-request (server-port s) 'hello) 'hello)
    (remove-task (server-task s)))
  ;; A server that ends with a caller waiting: the caller hears, and so does
  ;; anybody who asks after.
  (let* ((me (this-task))
         (sig (exec::alloc-signal me))
         (s (make-server "stuck" 0
                         (lambda (body) (set! *drv-stuck* t) (wait 536870912) body))))
    (set! *drv-stuck* nil)
    (set! *drv-probe* 'unset)
    (spawn "caller" 0 (lambda ()
                        (set! *drv-probe* (raw-request (server-port s) 'hello))
                        (signal me sig)))
    (while (%null? *drv-stuck*) (reschedule))
    (remove-task (server-task s))
    (wait sig)
    (num-check 'a-caller-hears-when-its-server-dies (failure? *drv-probe*) t)
    (num-check 'and-a-dead-server-answers-at-once
               (failure? (raw-request (server-port s) 'again)) t)
    (exec::free-signal me sig))
  ;; A driver that ends takes its page with it, and the next one makes its
  ;; own.
  (let ((old disk:*driver*))
    (remove-task (server-task old))
    (num-check 'a-dead-driver-is-not-running (disk:running?) nil)
    (num-check 'and-with-no-driver-there-is-no-disk (refused? (lambda () (disk:size))) t)
    (disk:start)
    (num-check 'a-new-driver-takes-it (disk:running?) t)
    (num-check 'in-a-new-task
               (%eq? (server-task disk:*driver*) (server-task old)) nil)
    (num-check 'with-one-interrupt-server
               (length (list-nodes (exec::int-vector int-disk))) 1)
    (num-check 'and-it-answers (number? (disk:size)) t))
  (princ "drivers: done (nothing above = all correct)")
  (newline))

;; ---------------------------------------------------------------- capabilities
;; `(capabilities)` checks what the processor guarantees a program that says
;; nothing unsafe. Every value is a capability: a pointer has a tag, bounds
;; that are exactly its object and the permissions it was made with; a number
;; has no tag; and identity is the whole capability, not its address. What
;; should be refused is tried in a probe of its own, so that this can watch
;; the error happen and carry on.

;; Whether running `thunk` is an error. It runs in a server's handler, where
;; an error answers this task with a failure instead of ending it.
(define (refused? thunk)
  (let* ((s (make-server "probe" 0 (lambda (th) (th) 'ran)))
         (r (raw-request (server-port s) thunk)))
    (remove-task (server-task s))
    (failure? r)))

;; A capability narrowed out of a heap block keeps the block its base lies
;; in alive. Each is made in a call of its own, so that no frame is left
;; holding the whole block, and the heap is churned until a collection
;; would have reused it.
(define (narrowed-pair) (%cap-bounds (cons 'apple 'pear) 8))
(define (narrowed-cdr) (%cap-bounds (%cap-inc (cons 'plum 'quince) 8) 8))
(define (narrowed-slot) (%cap-bounds (%cap-inc (vector 'first (list 'kept 42) 'third) 8) 8))
(define (churn n)
  (let ((i 0) (l nil))
    (while (< i n)
      (set! l (cons i (if (= (logand i 1023) 0) nil l)))
      (if (= (logand i 7) 0) (vector i l i) nil)
      (set! i (+ i 1)))
    nil))
(define (narrowed-survive)
  (let ((c (narrowed-pair)) (d (narrowed-cdr)) (s (narrowed-slot)))
    (churn 300000)
    (gc)
    (churn 300000)
    (gc)
    (num-check 'a-narrowed-pair-keeps-its-pair
               (list (%cap-len c) (%cap-ld c 0))
               (list value-bytes 'apple))
    (num-check 'and-one-narrowed-to-its-cdr (%cap-ld d 0) 'quince)
    (num-check 'a-narrowed-slot-keeps-its-vector
               (list (%cap-len s) (%cap-ld s 0))
               (list value-bytes '(kept 42)))
    ;; Its base is a slot, not a payload, so it is not headed: the slot below
    ;; it cannot be passed off as a header.
    (num-check 'a-narrowed-slot-is-not-an-object
               (list (logand (%cap-perms s) perm-hd) (%object? s))
               (list 0 nil))
    (let ((u (%cap-and-perms s (lognot perm-hd))))
      (set! s nil)
      (churn 300000)
      (gc)
      (num-check 'and-so-does-one-without-hd (%cap-ld u 0) '(kept 42)))))

;; Machine code is an object, a text, and the collector takes it back like
;; any other: a function defined again and again leaves the code and the
;; objects in use after a collection as they were, give or take a function or
;; two. A capability into a text, an entry or a return address, keeps it
;; alive by the same rule a narrowed capability keeps its block.
(define (redefine n)
  (let ((i 0))
    (while (< i n)
      (eval '(define (redefined x) (list x (+ x 1) (* x 2) (vector x x x))))
      (set! i (+ i 1)))))

(define (entry-of f) (unsafe (%slot (open-closure f) clo-entry)))

(define (code-is-collected)
  (gc)
  (let ((code (code-bytes)) (used (object-bytes-used)))
    (redefine 1)
    (let ((one (- (code-bytes) code)) (e (entry-of (%symbol-value 'redefined))))
      (redefine 100)
      (gc)
      (num-check 'old-code-is-reclaimed (< (- (code-bytes) code) (* 3 one)) t)
      (num-check 'and-so-are-its-objects (< (- (object-bytes-used) used) (* 12 one)) t)
      (num-check 'an-entry-keeps-its-text
                 (list (= (logand (unsafe (%ld-word (- (%cap-base e) 8))) 255) t-text)
                       (logand (%cap-perms e) (logior perm-ex perm-ld perm-sd)))
                 (list t perm-ex)))))

(define (capabilities)
  (narrowed-survive)
  (code-is-collected)
  (let* ((v (vector 1 2 3))
         (w (%cap-and-perms v (lognot perm-sd)))
         (p (cons 1 2))
         (b (make-bytes 8))
         (narrow (%cap-bounds-exact b 4))
         (f (let ((n 5)) (lambda () n)))
         (opened (unsafe (open-closure f)))
         (page (unsafe (device-page dev-sys)))
         (blit (unsafe (device-page dev-blit))))
    ;; nil is the read-only cell at address 0, and not the number 0.
    (num-check 'nil-is-not-zero (eq? nil 0) nil)
    (num-check 'nil-is-the-cell-at-zero
               (list (%cap-tag? nil) (%addr-of nil) (%cap-len nil))
               (list t 0 (* 2 value-bytes)))
    (num-check 'nil-is-read-only (logand (%cap-perms nil) (logior perm-sd perm-sc)) 0)
    (num-check 'nil-holds-nil (list (car nil) (cdr nil)) (list nil nil))
    ;; A number is an untagged capability whose metadata says which kind.
    (num-check 'a-fixnum-is-untagged
               (list (%cap-tag? 5) (%cap-high 5) (%addr-of 5))
               (list nil 0 5))
    (num-check 'a-character-is-untagged (list (%cap-tag? #\A) (%cap-high #\A)) (list nil 1))
    (num-check 'fixnums-are-thirty-two-bits
               (list (fixnum? 2147483647) (fixnum? -2147483648) (fixnum? (+ 2147483647 1)))
               (list t t nil))
    ;; Identity is exact: the same address with other permissions, or the
    ;; same payload as another kind, is another value.
    (num-check 'eq-is-the-whole-capability (list (eq? v v) (eq? v w)) (list t nil))
    (num-check 'with-the-same-address (%= (%addr-of v) (%addr-of w)) t)
    (num-check 'a-character-is-not-its-code (list (eq? #\A 65) (%addr-of #\A)) (list nil 65))
    ;; What the readers say about a capability.
    (num-check 'a-vector-is-its-slots
               (list (%cap-base v) (%cap-len v) (%cap-top v) (%cap-offset v))
               (list (%addr-of v) (* 3 value-bytes) (+ (%addr-of v) (* 3 value-bytes)) 0))
    (num-check 'an-object-is-headed (logand (%cap-perms v) perm-hd) perm-hd)
    (num-check 'a-pair-is-two-slots-and-unheaded
               (list (%cap-len p) (logand (%cap-perms p) perm-hd))
               (list (* 2 value-bytes) 0))
    (num-check 'bytes-hold-no-capabilities
               (list (%cap-len b) (logand (%cap-perms b) (logior perm-lc perm-sc)))
               (list 8 0))
    (num-check 'narrowed (list (%cap-base narrow) (%cap-len narrow)) (list (%addr-of b) 4))
    (num-check 'a-device-is-its-page
               (list (%cap-len page) (%cap-perms page))
               (list device-page-bytes (logior perm-ld perm-sd)))
    (num-check 'inside-the-bounds-reads (%cap-ld-word b 4) 0)
    ;; A closure is sealed: calling it is the only way in, unless the escape
    ;; hatch opens it.
    (num-check 'a-closure-is-sealed (list (%cap-sealed? f) (%cap-otype f)) (list t otype-closure))
    (num-check 'calling-it-opens-it (f) 5)
    (num-check 'the-escape-hatch-opens-it
               (list (%cap-sealed? opened) (code-object? (unsafe (%slot opened clo-code))))
               (list nil t))
    ;; A pointer cannot be made from its bits.
    (let ((forged (%cap-set-high (%addr-of v) (%cap-high v))))
      (num-check 'bits-are-not-a-pointer (list (%cap-tag? forged) (eq? forged v)) (list nil nil)))
    ;; A capability store keeps the tag, and any other store clears it.
    (let ((m (make-vector 1 nil)))
      (%cap-st! m 0 v)
      (num-check 'a-capability-store-keeps-the-tag (eq? (%cap-ld m 0) v) t)
      (%cap-st-word! m 0 (%addr-of v))
      (num-check 'a-word-store-clears-it (%cap-tag? (%cap-ld m 0)) nil))
    (princ "capabilities: the errors below are on purpose")
    (newline)
    (num-check 'storing-into-nil-is-refused (refused? (lambda () (set-car! nil 1))) t)
    (num-check 'and-nil-still-holds-nil (car nil) nil)
    (num-check 'a-dropped-permission-is-gone (refused? (lambda () (vector-set! w 0 9))) t)
    (vector-set! v 0 9)
    (num-check 'and-the-original-still-has-it (vector-ref w 0) 9)
    (num-check 'past-the-bounds-is-refused (refused? (lambda () (%cap-ld-word b 8))) t)
    (num-check 'a-store-past-them-too (refused? (lambda () (%cap-st-byte! b 8 1))) t)
    (num-check 'narrowed-is-refused-beyond (refused? (lambda () (%cap-ld-word narrow 4))) t)
    (num-check 'past-a-device-page-is-refused
               (refused? (lambda () (%cap-ld-word page device-page-bytes))) t)
    (num-check 'a-device-hands-out-no-capability (refused? (lambda () (%cap-ld page 0))) t)
    (num-check 'a-page-without-sc-takes-none
               (refused? (lambda () (%cap-st! page hw::sys-ramsize v)))
               t)
    (num-check 'and-only-a-capability-register-takes-one
               (refused? (lambda () (%cap-st! blit blit-status-reg v)))
               t)
    ;; A chip is handed capabilities, not numbers.
    (num-check 'a-chip-refuses-a-number
               (blit-probe op-fill (%addr-of b) b 8 1)
               (logior blit-refused-dst capex-tag))
    (blit-clear-refused!)
    (num-check 'the-compiler-will-not-open-a-closure
               (refused? (lambda () (eval '(lambda (g) (%slot g 1)))))
               t)
    (num-check 'nor-will-the-processor
               (refused? (lambda () (unsafe (%slot f clo-code))))
               t)
    ;; A quoted constant is read-only all the way down, and the symbols in it
    ;; are the symbols themselves.
    (let ((k '(a (1 2) "s" #(3))))
      (num-check 'a-constant-is-read-only (refused? (lambda () (set-car! k 1))) t)
      (num-check 'and-so-is-its-tail (refused? (lambda () (set-car! (cdr k) 1))) t)
      (num-check 'and-what-it-holds
                 (list (refused? (lambda () (set-car! (cadr k) 9)))
                       (refused? (lambda () (string-set! (caddr k) 0 #\z)))
                       (refused? (lambda () (vector-set! (cadddr k) 0 9))))
                 (list t t t))
      (num-check 'but-its-symbols-are-not (eq? (car k) 'a) t)))
  (princ "capabilities: done (nothing above = all correct)")
  (newline))
