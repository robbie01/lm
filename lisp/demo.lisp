;;; demo.lisp - things to type at the prompt.
;;;
;;; These ship inside the kickstart, the way a ROM ships with what it needs.
;;; Between them they lean on every part of the machine: preemptive tasks
;;; sharing one framebuffer with no locking because they only ever touch their
;;; own pixels, the blitter for the parts that move whole rectangles, the
;;; vertical blank for timing, and the compiler itself for the last one.

(in-package user)


(define (screen)
  (if *screen*
      *screen*
      (open-screen screen-width screen-height)))

(define (wait-vblank)
  (let ((n (vblank-count)))
    (while (%= n (vblank-count)) (%wait-for-input))
    n))

;; ---------------------------------------------------------------- balls
;; One task per ball, all of them drawing into one window. They coordinate
;; about nothing, which is exactly the Amiga bargain - a single address space,
;; nothing in the way, and it is on you not to draw over each other - except
;; that now the worst they can do is spoil their own window.
(define (ball-task win colour seed)
  (let ((bw (win-inner-w win)) (bh (win-inner-h win)))
    (lambda ()
      (let ((x (%mod seed (%- bw 20)))
            (y (%mod (%* seed 7) (%- bh 20)))
            (dx (if (%= 0 (%mod seed 2)) 3 -2))
            (dy (if (%= 0 (%mod seed 3)) 2 -3))
            (r 8))
        (while t
          (win-fill win x y r r pt-white)
          (set! x (%+ x dx))
          (set! y (%+ y dy))
          ;; Turn round *and* step back inside. Flipping the direction without
          ;; correcting the position leaves the ball one column out, and one
          ;; column out is inside the window frame, which it then paints over.
          (if (%< x 0) (begin (set! x 0) (set! dx (%- 0 dx))) nil)
          (if (%> x (%- bw r)) (begin (set! x (%- bw r)) (set! dx (%- 0 dx))) nil)
          (if (%< y 0) (begin (set! y 0) (set! dy (%- 0 dy))) nil)
          (if (%> y (%- bh r)) (begin (set! y (%- bh r)) (set! dy (%- 0 dy))) nil)
          (win-fill win x y r r colour)
          (present win))))))

(define (balls . opts)
  (let* ((n (if (%cons? opts) (%car opts) 8))
         (win (make-demo-window 420 300 "Balls"))
         (i 0))
    (win-fill win 0 0 (win-inner-w win) (win-inner-h win) pt-white)
    (while (%< i n)
      (add-task (string-append "ball" (number->string i))
                0
                (ball-task win (%+ 1 (%mod i 11)) (%+ 3 (%* i 37))))
      (set! i (%+ i 1)))
    win))

;; ---------------------------------------------------------------- mandelbrot
;; Fixed point with twelve fractional bits. A fixnum holds thirty bits, and
;; the intermediate products here reach twenty-eight, which is the whole
;; reason the escape radius is checked against four rather than something
;; more generous.
(define fp-bits 12)
(define fp-one 4096)

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

(define (mandelbrot . opts)
  ;; A window of its own, and a row of it handed over every sixteen: the
  ;; picture appears in bands rather than after a long silence.
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
            (win-plot win x y (if (%>= n limit) pt-black (%+ 16 (%mod (%* n 7) 200)))))
          (set! x (%+ x 1))))
      (set! y (%+ y 1))
      (if (%= 0 (%mod y 16)) (present win) nil))
    (window-damage win)
    win))

;; ---------------------------------------------------------------- life
;; Conway's life, straight on the framebuffer: the screen is the board, which
;; is only reasonable because reading a pixel back is a load like any other.
(define *life-back* nil)

(define *life-win* nil)
(define *life-w* 0)
(define *life-h* 0)

(define (life-seed density)
  (let ((w (win-inner-w *life-win*)) (h (win-inner-h *life-win*)))
    (set! *life-w* w)
    (set! *life-h* h)
    (if *life-back* nil (set! *life-back* (alloc-pool (%* w h))))
    (win-fill *life-win* 0 0 w h pt-white)
    (let ((y 1))
      (while (%< y (%- h 1))
        (let ((x 1))
          (while (%< x (%- w 1))
            (if (%< (%mod (random) 100) density)
                (win-plot *life-win* x y pt-black)
                nil)
            (set! x (%+ x 1))))
        (set! y (%+ y 1)))))
  'seeded)

(define (life-step)
  ;; The window's own bitmap is the board, which is only reasonable because
  ;; reading a pixel back is a load like any other. A cell is alive if it is
  ;; black; the counting is done against the back buffer so that every cell
  ;; sees the same generation.
  ;;
  ;; Direct loads and stores into the bitmap, so the blitter's work on it has
  ;; to have landed first - the window was filled by a blit, and a blit is not
  ;; done when it returns.
  (blit-sync)
  (let ((y 1)
        (w *life-w*)
        (h *life-h*)
        (stride (win-w *life-win*)))
    (while (%< y (%- h 1))
      (let ((x 1) (row (win-row *life-win* y)))
        (while (%< x (%- w 1))
          (let* ((p (%+ row x))
                 (up (%- p stride))
                 (dn (%+ p stride))
                 (n (%+ (%+ (%+ (live? (%- up 1)) (live? up))
                            (%+ (live? (%+ up 1)) (live? (%- p 1))))
                        (%+ (%+ (live? (%+ p 1)) (live? (%- dn 1)))
                            (%+ (live? dn) (live? (%+ dn 1))))))
                 (alive (live? p)))
            (poke8 (%+ *life-back* (%+ (%* y w) x))
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
          (poke8 (%+ row x)
                 (if (%= 1 (peek8 (%+ *life-back* (%+ (%* y w) x))))
                     pt-black pt-white))
          (set! x (%+ x 1))))
      (set! y (%+ y 1))))
  (present *life-win*)
  nil)

(define (live? p) (if (%= (peek8 p) pt-black) 1 0))

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
;; The most convincing thing the machine can do is compile something while you
;; watch, so this does exactly that and times it.
(define (selftest)
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
    (write (ackermann 2 6))
    (emit-str " in ")
    (emit-str (number->string (%- (%cycles) t1)))
    (emit-str " cycles\n"))
  (emit-str "  code space now ")
  (emit-str (number->string (%lsh (%- (%global lg-code-ptr) code-base) -10)))
  (emit-str "k\n")
  'ok)

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
  (emit-str "  (balls 6)              six tasks, one framebuffer\n")
  (emit-str "  (mandelbrot)           fixed point, straight to the bitmap\n")
  (emit-str "  (life 200)             life, with the blitter for the copy\n")
  (emit-str "  (tasks)                what is running; preemption is already on\n")
  (emit-str "  (save-image)           write this machine to the disk\n")
  (emit-str "  bye                    stop the machine\n")
  nil)


;; ---------------------------------------------------------------- numbers
;; What `(numbers)` checks is that arithmetic is one thing rather than two.
;; A fixnum that outgrows thirty-one bits becomes a bignum, a bignum that
;; shrinks back becomes a fixnum again, and nothing in between has to be asked
;; which it is holding - so the interesting cases here are the boundaries, and
;; the one number whose magnitude is not a number.
(define (num-check name got want)
  (if (equal? got want)
      nil
      (begin (princ "FAIL ") (princ name) (princ ": got ") (princ got)
             (princ ", wanted ") (princ want) (newline))))

(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))

(define (numbers)
  (num-check 'small (+ 2 3) 5)
  (num-check 'promote (+ 1073741823 1) 1073741824)
  (num-check 'demote (- (+ 1073741823 1) 1) 1073741823)
  ;; and it really is a fixnum again, not a bignum that prints small
  (num-check 'demoted-is-fixnum (%fixnum? (- (+ 1073741823 1) 1)) t)
  (num-check 'most-negative (- 0 -1073741824) 1073741824)
  (num-check 'most-negative-print (number->string -1073741824) "-1073741824")
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
  (num-check 'wrapping (wrap+ 1073741823 1) -1073741824)
  (num-check 'saturating (sat* 1000000 1000000) most-positive-fixnum)
  (princ "numbers: done (nothing above = all correct)")
  (newline))


;; ---------------------------------------------------------------- words
;; `(words)` checks the other half of the number question: a location holds
;; thirty-two bits and a fixnum has thirty-one, so reading one has to say
;; which number it means. `peek` reads a word unsigned, `peek-signed` reads
;; the same word signed, and `poke` takes either and stores the low
;; thirty-two bits - so a word read one way goes back unchanged.
(define (words)
  (let ((p (alloc-pool 32)))
    ;; a word with its top bit set, built out of halves so nothing has to
    ;; represent it on the way in
    (%st-half! p 0)
    (%st-half! (%+ p 2) 32768)
    (num-check 'top-bit (peek p) 2147483648)
    (num-check 'top-bit-signed (peek-signed p) -2147483648)
    (poke p 4294967295)
    (num-check 'all-ones (peek p) 4294967295)
    (num-check 'all-ones-signed (peek-signed p) -1)
    (poke p -1)
    (num-check 'poke-negative (peek p) 4294967295)
    (poke p 12345)
    (num-check 'small (peek p) 12345)
    (num-check 'small-is-fixnum (%fixnum? (peek p)) t)
    (poke p 1073741824)
    (num-check 'one-past-fixnum (peek p) 1073741824)
    (num-check 'one-past-signed (peek-signed p) 1073741824)
    (poke p 2147483648)
    (num-check 'round-trip (peek p) 2147483648)
    ;; and the raw forms still say what they always said: the low thirty-one
    ;; bits, sign extended, in one instruction
    (poke p 12345)
    (num-check 'raw-load (%ld-fixnum p) 12345)
    (free-pool p))
  (princ "words: done (nothing above = all correct)")
  (newline))


;; ---------------------------------------------------------------- nesting
;; A trap taken while the trap handler is already running.
;;
;; The server below runs from the vertical blank, which means it runs inside
;; the handler, and its arithmetic outgrows a fixnum - which widens through
;; the trap handler, so it is itself a trap. That is a trap inside a trap, and
;; until the stub kept a stack of save areas it overwrote the registers of the
;; one already in progress and the machine died somewhere else entirely a
;; second later.
(define *nest-hits* 0)
(define *nest-last* 0)
(define *nest-int* nil)

(define (nesting . opts)
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
    (exec::rem-int-server int-vblank *nest-int*)
    (num-check 'nested-result *nest-last*
               (* 1000000 (+ 1000000 *nest-hits*)))
    (num-check 'depth-unwound (peek lg-trapdepth) 0)
    (princ "nesting: ") (princ *nest-hits*)
    (princ " traps taken inside the trap handler, all of them survived")
    (newline)))


;; ---------------------------------------------------------------- talking
;; `(talking)` exercises the way tasks are meant to reach anything they do not
;; own: by sending it a message.
;;
;; There is no device registry here and no `OpenDevice`. A driver is a task
;; with a port, and it is reached by naming the symbol that holds it - which
;; is the one thing a Lisp machine gets for free and an Amiga had to build a
;; string-keyed table for.
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
    ;; `wait` over both masks rather than a poll over either.
    (let ((a (create-port nil 0))
          (b (create-port nil 0)))
      (spawn "sender" 0 (lambda () (wait-vblank)
                                   (put-msg b (create-message 'from-b nil))))
      (let ((hit (wait-ports (list a b))))
        (num-check 'select-b (eq? hit b) t)
        (num-check 'select-body (message-body (get-msg hit)) 'from-b))
      (put-msg a (create-message 'from-a nil))
      (let ((hit (wait-ports (list a b))))
        (num-check 'select-a (eq? hit a) t)
        (num-check 'select-body-a (message-body (get-msg hit)) 'from-a))
      (delete-port a)
      (delete-port b))

    ;; Dependent tasks. A child dies with its parent, so a server that fans
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
      (rem-task parent)
      (num-check 'children-gone (find-task "kid-one") nil))

    ;; And the rule that closes the bug this all started from: an interrupt
    ;; server does not draw.
    (num-check 'blitter-is-task-context
               (if hw::*in-interrupt* 'in-interrupt 'task) 'task))
  (princ "talking: done (nothing above = all correct)")
  (newline))


;; ---------------------------------------------------------------- blitting
;; `(blitting)` checks that the blitter is really asynchronous, and that
;; waiting for it means what it says. The second group is the one that
;; matters: two blits in a row through one task's command block, which is
;; what every drawing task does and what the collector does to clear its maps.
(define (blitting)
  (let* ((a (alloc-bitmap 256 256))
         (b (alloc-bitmap 256 256))
         (pa (%addr-of (bm-pixels a)))
         (pb (%addr-of (bm-pixels b))))
    ;; A blit is not done when it returns: read too early and you see the
    ;; old pixel, which is what real hardware would give you too.
    (%st-byte! pa 7)
    (bm-fill-rect a 0 0 256 256 42)
    (num-check 'not-landed-yet (%ld-byte pa) 7)
    (blit-sync)
    (num-check 'landed-after-sync (%ld-byte pa) 42)
    ;; Back to back through one block. The second commit waits for the
    ;; first, and the first one's write-back must not mark the second done.
    (%st-byte! pb 9)
    (bm-fill-rect a 0 0 256 256 1)
    (bm-fill-rect b 0 0 256 256 2)
    (blit-sync)
    (num-check 'second-of-two-landed (%ld-byte pb) 2)
    (num-check 'first-of-two-landed (%ld-byte pa) 1)
    ;; And a big one does not hold the machine up while it runs: the commit
    ;; is a few hundred cycles, and the transfer happens while others run.
    (let ((big (alloc-bitmap 1024 768)))
      (blit-drain)
      (let ((t0 (%cycles)))
        (bm-fill-rect big 0 0 1024 768 5)
        (num-check 'big-commit-is-quick (%< (%- (%cycles) t0) 10000) t))
      (blit-sync)
      (num-check 'big-landed (%ld-byte (%addr-of (bm-pixels big))) 5))
    ;; A chain: a blit queued behind a big one does not wait for it. Its
    ;; commit is a few hundred cycles, not the big one's two hundred thousand
    ;; - the chip gets to it by itself - and the two land in order.
    (let ((big (alloc-bitmap 1024 768)) (small (alloc-bitmap 16 16)))
      (blit-drain)
      (bm-fill-rect big 0 0 1024 768 6)
      (let ((t0 (%cycles)))
        (bm-fill-rect small 0 0 16 16 7)
        (num-check 'queued-behind-a-big-one-is-quick (%< (%- (%cycles) t0) 5000) t))
      (num-check 'and-the-big-one-still-running (blit-busy?) t)
      (blit-sync)
      (num-check 'the-queued-one-landed (%ld-byte (%addr-of (bm-pixels small))) 7)
      (num-check 'after-the-big-one (%ld-byte (%addr-of (bm-pixels big))) 6))
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
          (if (%= (%ld-byte (%addr-of (bm-pixels b))) v) nil (set! ok nil))
          (set! v (%- v 1)))
        (num-check 'twenty-through-a-ring-of-eight ok t))))
  (princ "blitting: done (nothing above = all correct)")
  (newline))


;; ---------------------------------------------------------------- devices
;; `(devices)` checks device ownership. A device is a value: holding it is the
;; permission, a claimed one refuses every task but its owner, and a task that
;; dies gives back what it held.
(define *dev-probe* nil)

(define (devices)
  (let ((d (make-device "probe" dev-disk nil))
        (me (this-task))
        (sig (exec::alloc-signal (this-task))))
    (num-check 'unclaimed-is-usable (device-usable? d) t)
    (claim-device d)
    (num-check 'claimed-by-this-task (%eq? (device-owner d) me) t)
    (num-check 'usable-by-its-owner (device-usable? d) t)
    ;; another task asks, and is refused
    (set! *dev-probe* 'unset)
    (spawn "probe" 0 (lambda ()
                       (set! *dev-probe* (device-usable? d))
                       (signal me sig)))
    (wait sig)
    (num-check 'refused-to-other-tasks *dev-probe* nil)
    (release-device d)
    (num-check 'released-on-request (device-owner d) nil)
    ;; a task that claims it and then ends gives it back
    (spawn "claimer" 0 (lambda () (claim-device d) (signal me sig)))
    (wait sig)
    (while (find-task "claimer") (reschedule))
    (num-check 'released-when-its-owner-died (device-owner d) nil)
    ;; and the kernel's own devices are the kernel's
    (num-check 'sys-is-kernel (device-owner hw::*sys*) 'hw::kernel)
    (num-check 'timer-is-kernel (device-owner hw::*timer*) 'hw::kernel)
    (exec::free-signal me sig))
  (princ "devices: done (nothing above = all correct)")
  (newline))


;; ---------------------------------------------------------------- drivers
;; `(drivers)` checks the driver model end to end, on the disk and the
;; keyboard: one task holds each device and every other task asks it, a
;; transfer lets the machine run while it happens, every listener hears every
;; event, and a server that fails or dies answers its callers instead of
;; leaving them blocked. The transfers need a disk - start the
;; machine with --disk FILE; a scratch file will do.
(define *drv-probe* nil)
(define *drv-count* 0)
(define *drv-stuck* nil)

;; A request that hands back whatever came back, failure or not, instead of
;; raising on a failure the way `request` does - so that a check can look.
(define (raw-request port body)
  (let* ((r (reply-port))
         (m (create-message body r)))
    (put-msg port m)
    (while (%null? (get-msg r)) (wait (port-signal r)))
    (message-body m)))

(define (bytes-same? a b)
  (let ((n (bytes-length a)) (i 0) (same (%= (bytes-length a) (bytes-length b))))
    (while (if same (%< i n) nil)
      (if (%= (bytes-ref a i) (bytes-ref b i)) nil (set! same nil))
      (set! i (%+ i 1)))
    same))

(define (drivers)
  (num-check 'disk-driver-running (disk-driver-running?) t)
  (num-check 'disk-held-by-its-driver
             (%eq? (device-owner *disk*) (server-task *disk-driver*)) t)
  (num-check 'disk-refused-to-everybody-else (device-usable? *disk*) nil)
  ;; Through the driver: out, back, and the same bytes.
  (let ((out (make-bytes 1024)) (in (make-bytes 1024)) (i 0))
    (while (%< i 1024)
      (bytes-set! out i (%logand (%+ (%* i 7) 3) 255))
      (set! i (%+ i 1)))
    (let ((st (disk-write 40 2 out)))
      (if (%= st 1)
          (begin
            (princ "drivers: no disk attached, so no transfers - start with --disk FILE")
            (newline))
          (begin
            (num-check 'write-through-the-driver st 0)
            (num-check 'read-through-the-driver (disk-read 40 2 in) 0)
            (num-check 'the-same-bytes-came-back (bytes-same? out in) t)
            ;; And the machine runs while a transfer does: the driver sleeps
            ;; on the controller, and another task counts in the meantime.
            (let ((big (make-bytes (* 512 256)))
                  (sleeps *disk-sleeps*)
                  (counter (spawn "counter" 0
                                  (lambda ()
                                    (while t (set! *drv-count* (%+ *drv-count* 1)))))))
              (set! *drv-count* 0)
              (num-check 'a-big-write (disk-write 100 256 big) 0)
              (num-check 'the-driver-slept-through-it (%> *disk-sleeps* sleeps) t)
              (num-check 'another-task-ran-meanwhile (%> *drv-count* 0) t)
              (rem-task counter))))))
  ;; The keyboard and mouse. The driver is the one reader, and every
  ;; subscriber gets every event - which two tasks reading the chip could
  ;; never have, because reading an event is what takes it.
  (num-check 'input-driver-running (input-driver-running?) t)
  (num-check 'input-held-by-its-driver
             (%eq? (device-owner *input*) (server-task *input-driver*)) t)
  (num-check 'input-refused-to-everybody-else (device-usable? *input*) nil)
  (let ((a (input-listen)) (b (input-listen)))
    ;; A key with no ascii, so that a workbench, if one is up, lets it go by.
    (inject-input 1 0 200 0)
    (let ((ea (next-input a)) (eb (next-input b)))
      (num-check 'one-listener-hears
                 (list (%car ea) (cadr ea) (caddr ea) (cadddr ea))
                 (list 'key 'down 0 200))
      (num-check 'and-so-does-the-other (equal? ea eb) t))
    (input-unlisten a)
    (input-unlisten b))
  ;; A handler that fails answers with a failure, and the server carries on.
  (princ "drivers: the error below is on purpose")
  (newline)
  (let ((s (make-server "fragile" 0
                        (lambda (body)
                          (if (eq? body 'break) (error "fragile: asked to fail") body)))))
    (num-check 'a-failing-handler-answers (failure? (raw-request (server-port s) 'break)) t)
    (num-check 'and-the-server-carries-on (raw-request (server-port s) 'hello) 'hello)
    (rem-task (server-task s)))
  ;; A server that dies with a caller waiting: the caller hears, and so does
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
    (rem-task (server-task s))
    (wait sig)
    (num-check 'a-caller-hears-when-its-server-dies (failure? *drv-probe*) t)
    (num-check 'and-a-dead-server-answers-at-once
               (failure? (raw-request (server-port s) 'again)) t)
    (exec::free-signal me sig))
  ;; A driver that dies gives its device back, and the next one takes it.
  (let ((old *disk-driver*))
    (rem-task (server-task old))
    (num-check 'a-dead-driver-gives-the-disk-back (device-owner *disk*) nil)
    (num-check 'and-is-not-running (disk-driver-running?) nil)
    (num-check 'with-no-driver-a-call-goes-direct (number? (disk-size)) t)
    (start-disk-driver)
    (num-check 'a-new-driver-takes-it (disk-driver-running?) t)
    (num-check 'in-a-new-task
               (%eq? (server-task *disk-driver*) (server-task old)) nil)
    (num-check 'with-one-interrupt-server
               (length (list-nodes (exec::int-vector int-disk))) 1)
    (num-check 'and-it-answers (number? (disk-size)) t))
  (princ "drivers: done (nothing above = all correct)")
  (newline))
