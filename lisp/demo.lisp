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
;; One task per ball. They share the framebuffer with no coordination at all,
;; which is exactly the Amiga bargain: a single address space, nothing in the
;; way, and it is on you not to draw over each other.
(define (ball-task colour seed)
  (lambda ()
    (let ((x (%+ 40 (%mod seed 500)))
          (y (%+ 40 (%mod (%* seed 7) 300)))
          (dx (if (%= 0 (%mod seed 2)) 3 -2))
          (dy (if (%= 0 (%mod seed 3)) 2 -3))
          (r 8))
      (while t
        (fill-rect x y r r 0)
        (set! x (%+ x dx))
        (set! y (%+ y dy))
        (if (if (%< x 2) t (%> x (%- screen-width (%+ r 2)))) (set! dx (%- 0 dx)) nil)
        (if (if (%< y 2) t (%> y (%- screen-height (%+ r 2)))) (set! dy (%- 0 dy)) nil)
        (fill-rect x y r r colour)
        (wait-vblank)))))

(define (balls n)
  (screen)
  (clear-screen 15)
  (poke gfx-ctrl (%logior gfx-on gfx-vbirq))
  (let ((i 0))
    (while (%< i n)
      (add-task (string-append "ball" (number->string i))
                0
                (ball-task (%+ 1 (%mod i 11)) (%+ 3 (%* i 37))))
      (set! i (%+ i 1))))
  (exec-start)
  n)

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
  (let ((limit (if (%cons? opts) (%car opts) 40)))
    (screen)
    (let ((y 0))
      (while (%< y screen-height)
        (let ((x 0)
              ;; -1.2 .. 1.2 over the height
              (ci (%- (%/ (%* y (%* 24 fp-one)) (%* 10 screen-height))
                      (%/ (%* 12 fp-one) 10))))
          (while (%< x screen-width)
            (let* ((cr (%- (%/ (%* x (%* 3 fp-one)) screen-width) (%* 2 fp-one)))
                   (n (mandel-point cr ci limit)))
              (plot x y (if (%>= n limit) 0 (%+ 16 (%mod (%* n 7) 240)))))
            (set! x (%+ x 1))))
        (set! y (%+ y 1))
        (if (%= 0 (%mod y 16)) (screen-sync) nil)))
    (screen-sync)
    'done))

;; ---------------------------------------------------------------- life
;; Conway's life, straight on the framebuffer: the screen is the board, which
;; is only reasonable because reading a pixel back is a load like any other.
(define *life-back* nil)

(define (life-seed density)
  (screen)
  (if *life-back* nil (set! *life-back* (alloc-pool (%* screen-width screen-height))))
  (clear-screen 0)
  (let ((y 1))
    (while (%< y (%- screen-height 1))
      (let ((x 1))
        (while (%< x (%- screen-width 1))
          (if (%< (%mod (random) 100) density) (plot x y 1) nil)
          (set! x (%+ x 1))))
      (set! y (%+ y 1))))
  'seeded)

(define (life-step)
  (let ((y 1) (w screen-width))
    ;; Count into the back buffer first, so every cell sees the same
    ;; generation.
    (while (%< y (%- screen-height 1))
      (let ((x 1) (row (%* y w)))
        (while (%< x (%- w 1))
          (let* ((p (%+ *screen* (%+ row x)))
                 (n (%+ (%+ (%+ (peek8 (%- p (%+ w 1))) (peek8 (%- p w)))
                            (%+ (peek8 (%- p (%- w 1))) (peek8 (%- p 1))))
                        (%+ (%+ (peek8 (%+ p 1)) (peek8 (%+ p (%- w 1))))
                            (%+ (peek8 (%+ p w)) (peek8 (%+ p (%+ w 1)))))))
                 (alive (peek8 p)))
            (poke8 (%+ *life-back* (%+ row x))
                   (if (%= alive 1)
                       (if (if (%= n 2) t (%= n 3)) 1 0)
                       (if (%= n 3) 1 0))))
          (set! x (%+ x 1))))
      (set! y (%+ y 1))))
  ;; Copy back with the blitter rather than a loop; this is what it is for.
  (poke blt-src *life-back*)
  (poke blt-dst *screen*)
  (poke blt-w screen-width)
  (poke blt-h screen-height)
  (poke blt-smod screen-width)
  (poke blt-dmod screen-width)
  (poke blt-op op-copy)
  (screen-sync)
  nil)

(define (life n)
  (life-seed 28)
  (let ((i 0))
    (while (%< i n)
      (life-step)
      (set! i (%+ i 1))))
  'done)

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
  (emit-str "  (exec-start)           turn on preemption\n")
  (emit-str "  (save-image)           write this machine to the disk\n")
  (emit-str "  bye                    stop the machine\n")
  nil)
