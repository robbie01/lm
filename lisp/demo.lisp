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
