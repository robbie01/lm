;;; hw.lisp - the custom chips.
;;;
;;; Every device is a 4 KiB page of naturally aligned 32-bit registers, so
;;; talking to hardware from Lisp is just peek and poke. Nothing here is
;;; privileged: this is a single address space with no MMU, and any task can
;;; reach the display or the blitter directly. That is the Amiga bargain -
;;; nothing protects you, and in exchange nothing gets in the way.

(in-package hw)

(define (dev-addr dev reg) (%+ mmio-base (%+ (%lsh dev 12) reg)))
(define (peek a) (%ld32 a))
(define (poke a v) (%st32! a v))
(define (peek8 a) (%ld8 a))
(define (poke8 a v) (%st8! a v))

;; ---------------------------------------------------------------- system
(define sys-halt (dev-addr dev-sys #x00))
(define sys-debug (dev-addr dev-sys #x04))
(define sys-intreq (dev-addr dev-sys #x08))
(define sys-intena (dev-addr dev-sys #x0c))
(define sys-intnum (dev-addr dev-sys #x10))
(define sys-cyclo (dev-addr dev-sys #x14))
(define sys-cychi (dev-addr dev-sys #x18))
(define sys-random (dev-addr dev-sys #x1c))
(define sys-ramsize (dev-addr dev-sys #x20))
(define sys-chipsize (dev-addr dev-sys #x24))
(define sys-intset (dev-addr dev-sys #x28))

(define (halt code) (%halt code))
(define (random) (peek sys-random))
(define (int-enable line) (poke sys-intena (%logior (peek sys-intena) (%lsh 1 line))))
(define (int-disable line) (poke sys-intena (%logand (peek sys-intena) (%lognot (%lsh 1 line)))))
(define (int-ack line) (poke sys-intreq (%lsh 1 line)))
(define (int-raise line) (poke sys-intset (%lsh 1 line)))
(define (int-pending) (peek sys-intnum))

;; ---------------------------------------------------------------- timer
(define tmr-lo (dev-addr dev-timer #x00))
(define tmr-hi (dev-addr dev-timer #x04))
(define tmr-cmplo (dev-addr dev-timer #x08))
(define tmr-cmphi (dev-addr dev-timer #x0c))
(define tmr-freq (dev-addr dev-timer #x10))
(define tmr-wall (dev-addr dev-timer #x14))

;; The timebase is the retired instruction count, so the clock is exact and
;; the same program produces the same schedule on every run.
(define (timer-now-low) (peek tmr-lo))
(define (timer-freq) (peek tmr-freq))
(define (millis) (peek tmr-wall))

(define (timer-set-in n)
  ;; Fire n ticks from now. The compare is 64-bit; the low half is written
  ;; second so a wrap cannot leave a compare in the past - and both halves go
  ;; out together, or the interrupt that arrives in between reads half of one
  ;; deadline and half of another.
  (without-interrupts
    (let* ((lo (peek tmr-lo))
           (hi (peek tmr-hi))
           (sum (%+ (%logand lo 1073741823) n)))
      (poke tmr-cmphi (if (%> sum 1073741823) (%+ hi 1) hi))
      (poke tmr-cmplo (%logior (%logand lo -1073741824) (%logand sum 1073741823))))))

(define (timer-never)
  (without-interrupts
    (poke tmr-cmphi -1)
    (poke tmr-cmplo -1)))

;; ---------------------------------------------------------------- display
(define gfx-base (dev-addr dev-gfx #x00))
(define gfx-width (dev-addr dev-gfx #x04))
(define gfx-height (dev-addr dev-gfx #x08))
(define gfx-pitch (dev-addr dev-gfx #x0c))
(define gfx-mode (dev-addr dev-gfx #x10))
(define gfx-palidx (dev-addr dev-gfx #x14))
(define gfx-paldat (dev-addr dev-gfx #x18))
(define gfx-ctrl (dev-addr dev-gfx #x1c))
(define gfx-vcount (dev-addr dev-gfx #x20))
(define gfx-sync (dev-addr dev-gfx #x24))
(define gfx-hz (dev-addr dev-gfx #x30))

(define gfx-on 1)
(define gfx-vbirq 2)

;; The size the machine comes up in. Nothing depends on it but the defaults.
(define screen-width 1024)
(define screen-height 768)

(define *screen* nil)      ; the bitmap address currently being displayed
(define *screen-w* 0)
(define *screen-h* 0)

;; A bitmap is raw memory out of the Exec pool rather than a Lisp object: the
;; display reads it directly, so it must never move and must not be scanned.
(define (open-screen w h)
  (let ((bm (alloc-pool (%* w h))))
    (set! *screen* bm)
    (set! *screen-w* w)
    (set! *screen-h* h)
    (attach-screen)))

;; Point the display at the bitmap we already have.
;;
;; A resumed image still has the bitmap - it is pool memory, and the pool is
;; saved - and it still has the three globals that say where and how big. What
;; it does not have is a display: devices are hardware, hardware comes back
;; reset, and a machine drawing carefully into memory nothing is scanning out
;; looks exactly like a machine that has crashed.
(define (attach-screen)
  (if (%null? *screen*)
      nil
      (begin
        (poke gfx-base *screen*)
        (poke gfx-width *screen-w*)
        (poke gfx-height *screen-h*)
        (poke gfx-pitch *screen-w*)
        (poke gfx-mode 8)
        ;; The vblank interrupt goes on with the display. Exec has a server on
        ;; it before this runs, and writing the control register without the
        ;; bit would quietly turn the frame clock off again.
        (poke gfx-ctrl (%logior gfx-on gfx-vbirq))
        (default-palette)
        *screen*)))

(define (set-colour i rgb)
  ;; An index register and a data register: two writes that mean one thing.
  (without-interrupts
    (poke gfx-palidx i)
    (poke gfx-paldat rgb)))

(define (rgb r g b)
  (%logior (%lsh (%logand r 255) 16)
           (%logior (%lsh (%logand g 255) 8) (%logand b 255))))

(define (default-palette)
  ;; Sixteen readable colours, then a grey ramp over the rest.
  (set-colour 0 (rgb 0 0 0))
  (set-colour 1 (rgb 255 255 255))
  (set-colour 2 (rgb 200 40 40))
  (set-colour 3 (rgb 40 200 60))
  (set-colour 4 (rgb 60 100 230))
  (set-colour 5 (rgb 230 200 40))
  (set-colour 6 (rgb 220 120 30))
  (set-colour 7 (rgb 170 80 220))
  (set-colour 8 (rgb 40 200 200))
  (set-colour 9 (rgb 240 130 180))
  (set-colour 10 (rgb 120 90 50))
  (set-colour 11 (rgb 90 90 110))
  (set-colour 12 (rgb 150 150 170))
  (set-colour 13 (rgb 60 70 90))
  (set-colour 14 (rgb 30 40 55))
  (set-colour 15 (rgb 20 24 34))
  (let ((i 16))
    (while (%< i 256)
      (let ((v (%+ 16 (%lsh (%* (%- i 16) 239) -8))))
        (set-colour i (rgb v v v)))
      (set! i (%+ i 1)))))

(define (vblank-count) (peek gfx-vcount))
(define (screen-sync) (poke gfx-sync 1))

(define (bm-plot bm bw bh x y c)
  (if (if (%>= x 0) (if (%< x bw) (if (%>= y 0) (%< y bh) nil) nil) nil)
      (poke8 (%+ bm (%+ (%* y bw) x)) c)
      nil))

(define (bm-point bm bw bh x y)
  (if (if (%>= x 0) (if (%< x bw) (if (%>= y 0) (%< y bh) nil) nil) nil)
      (peek8 (%+ bm (%+ (%* y bw) x)))
      0))

(define (screen-plot x y c) (bm-plot *screen* *screen-w* *screen-h* x y c))
(define (point x y) (bm-point *screen* *screen-w* *screen-h* x y))

;; ---------------------------------------------------------------- blitter
(define blt-src (dev-addr dev-blit #x00))
(define blt-dst (dev-addr dev-blit #x04))
(define blt-w (dev-addr dev-blit #x08))
(define blt-h (dev-addr dev-blit #x0c))
(define blt-smod (dev-addr dev-blit #x10))
(define blt-dmod (dev-addr dev-blit #x14))
(define blt-val (dev-addr dev-blit #x18))
(define blt-op (dev-addr dev-blit #x1c))
(define blt-x0 (dev-addr dev-blit #x24))
(define blt-y0 (dev-addr dev-blit #x28))
(define blt-x1 (dev-addr dev-blit #x2c))
(define blt-y1 (dev-addr dev-blit #x30))

(define op-copy 0)
(define op-fill 1)
(define op-xor 2)
(define op-and 3)
(define op-or 4)
(define op-mask 5)
(define op-line 6)
(define op-add 7)


;; Everything that touches the bitmap clips to it first. The bitmap is raw
;; pool memory with task structures and stacks immediately after it, so a
;; rectangle that runs off the right edge does not merely look wrong - it
;; writes over the scheduler.
(define (bm-clip bw bh x y w h)
  ;; Returns (x y w h) trimmed to a bitmap that size, or nil if nothing is
  ;; left. Every write to a bitmap goes through here first: bitmaps are raw
  ;; pool memory with task structures and stacks immediately after them, so a
  ;; rectangle that runs off the right edge does not merely look wrong - it
  ;; writes over the scheduler.
  (let* ((x0 (if (%< x 0) 0 x))
         (y0 (if (%< y 0) 0 y))
         (x1 (let ((e (%+ x w))) (if (%> e bw) bw e)))
         (y1 (let ((e (%+ y h))) (if (%> e bh) bh e))))
    (if (if (%< x0 x1) (%< y0 y1) nil)
        (list x0 y0 (%- x1 x0) (%- y1 y0))
        nil)))

(define (clip-rect x y w h) (bm-clip *screen-w* *screen-h* x y w h))

;; A device command is several register writes and then the one that starts
;; it. Those writes are a single act: two tasks interleaved in here would each
;; start the other's blit, which shows up as a stray line across the screen
;; from a rectangle that was supposed to be clipped to a window.
;;
;; The clipping is computed first, outside, because it is the expensive half
;; and it touches nothing shared.
(define (bm-fill-rect bm bw bh x y w h c)
  (let ((r (bm-clip bw bh x y w h)))
    (if r
        (without-interrupts
          (poke blt-dst (%+ bm (%+ (%* (cadr r) bw) (%car r))))
          (poke blt-w (caddr r))
          (poke blt-h (cadddr r))
          (poke blt-dmod bw)
          (poke blt-val c)
          (poke blt-op op-fill))
        nil)))

(define (screen-fill-rect x y w h c)
  (bm-fill-rect *screen* *screen-w* *screen-h* x y w h c))

(define (clear-screen c) (fill-rect 0 0 *screen-w* *screen-h* c))

(define (bm-blit-rect sbm sbw sbh dbm dbw dbh sx sy dx dy w h)
  ;; Clipped against both ends: the source rectangle and the destination have
  ;; to fit, and the smaller of the two wins. Source and destination may be
  ;; the same bitmap, which is what a scroll inside a window is, or different
  ;; ones, which is what compositing is.
  (let* ((sr (bm-clip sbw sbh sx sy w h))
         (dr (if sr (bm-clip dbw dbh dx dy (caddr sr) (cadddr sr)) nil)))
    (if dr
        (without-interrupts
          (poke blt-src (%+ sbm (%+ (%* (cadr sr) sbw) (%car sr))))
          (poke blt-dst (%+ dbm (%+ (%* (cadr dr) dbw) (%car dr))))
          (poke blt-w (caddr dr))
          (poke blt-h (cadddr dr))
          (poke blt-smod sbw)
          (poke blt-dmod dbw)
          (poke blt-op op-copy))
        nil)))

(define (screen-blit-rect sx sy dx dy w h)
  (bm-blit-rect *screen* *screen-w* *screen-h*
                *screen* *screen-w* *screen-h* sx sy dx dy w h))

;; ---------------------------------------------------------------- regions
;; A region is a list of rectangles that do not overlap. Rectangles are lists
;; of four numbers, because a region rarely has more than three of them and
;; the whole of the arithmetic below is one screenful.
;;
;; This is what a window system is made of. A window may draw into the part of
;; the bitmap it actually owns - its rectangle, less the rectangles of every
;; window in front of it - and subtracting one rectangle from another is the
;; only operation needed to work that out.
(define (rect x y w h) (list x y w h))
(define (rect-x r) (%car r))
(define (rect-y r) (cadr r))
(define (rect-w r) (caddr r))
(define (rect-h r) (cadddr r))
(define (rect-x2 r) (%+ (rect-x r) (rect-w r)))
(define (rect-y2 r) (%+ (rect-y r) (rect-h r)))
(define (rect-ok? r) (if (%> (rect-w r) 0) (%> (rect-h r) 0) nil))

(define (rect-intersect a b)
  (let ((x (if (%> (rect-x a) (rect-x b)) (rect-x a) (rect-x b)))
        (y (if (%> (rect-y a) (rect-y b)) (rect-y a) (rect-y b)))
        (x2 (if (%< (rect-x2 a) (rect-x2 b)) (rect-x2 a) (rect-x2 b)))
        (y2 (if (%< (rect-y2 a) (rect-y2 b)) (rect-y2 a) (rect-y2 b))))
    (if (if (%< x x2) (%< y y2) nil) (rect x y (%- x2 x) (%- y2 y)) nil)))

(define (rect-contains? r x y)
  (if (%>= x (rect-x r))
      (if (%< x (rect-x2 r))
          (if (%>= y (rect-y r)) (%< y (rect-y2 r)) nil)
          nil)
      nil))

;; a minus b, as up to four rectangles: the strip above, the strip below, and
;; what is left to the left and to the right of the hole in between.
(define (rect-subtract a b)
  (let ((i (rect-intersect a b)))
    (if (%null? i)
        (list a)
        (let ((out nil))
          (if (%> (rect-y i) (rect-y a))
              (set! out (%cons (rect (rect-x a) (rect-y a)
                                     (rect-w a) (%- (rect-y i) (rect-y a)))
                               out))
              nil)
          (if (%< (rect-y2 i) (rect-y2 a))
              (set! out (%cons (rect (rect-x a) (rect-y2 i)
                                     (rect-w a) (%- (rect-y2 a) (rect-y2 i)))
                               out))
              nil)
          (if (%> (rect-x i) (rect-x a))
              (set! out (%cons (rect (rect-x a) (rect-y i)
                                     (%- (rect-x i) (rect-x a)) (rect-h i))
                               out))
              nil)
          (if (%< (rect-x2 i) (rect-x2 a))
              (set! out (%cons (rect (rect-x2 i) (rect-y i)
                                     (%- (rect-x2 a) (rect-x2 i)) (rect-h i))
                               out))
              nil)
          out))))

(define (region-subtract-rect rgn b)
  (let ((out nil))
    (dolist (r rgn) (dolist (piece (rect-subtract r b)) (set! out (%cons piece out))))
    out))

(define (region-intersect-rect rgn b)
  (let ((out nil))
    (dolist (r rgn)
      (let ((i (rect-intersect r b)))
        (if i (set! out (%cons i out)) nil)))
    out))

(define (region-subtract rgn holes)
  (let ((out rgn))
    (dolist (h holes) (set! out (region-subtract-rect out h)))
    out))

(define (region-area rgn)
  (let ((n 0))
    (dolist (r rgn) (set! n (%+ n (%* (rect-w r) (rect-h r)))))
    n))

;; ---------------------------------------------------------------- rastports
;; Where drawing goes: a bitmap, an origin to shift by, and the region of that
;; bitmap it is allowed to touch. Everything below draws through the current
;; one, and the current one travels with the task the way its streams do - so
;; a task that draws is aimed at its own window without being told.
;;
;; Nothing set means the bare screen, which is what the boot messages want and
;; what the machine did before any of this existed.
;;
;; The bitmap is the part that makes a window a window rather than a promise
;; about clipping. Two tasks drawing into two bitmaps cannot reach each other
;; however wrong their arithmetic is; two tasks drawing into one screen behind
;; two clipping regions can, and did.
(define rp-slots 7)
(define rp-bm 1)
(define rp-bw 2)
(define rp-bh 3)
(define rp-org-x 4)
(define rp-org-y 5)
(define rp-clip 6)

(define *rp* nil)

(define (make-rastport-on bm bw bh ox oy clip)
  (let ((r (make-record rp-slots 'rastport)))
    (%record-set! r rp-bm bm)
    (%record-set! r rp-bw bw)
    (%record-set! r rp-bh bh)
    (%record-set! r rp-org-x ox)
    (%record-set! r rp-org-y oy)
    (%record-set! r rp-clip clip)
    r))

;; The screen is the default target, so the old three-argument form still
;; means what it always did.
(define (make-rastport ox oy clip)
  (make-rastport-on *screen* *screen-w* *screen-h* ox oy clip))

;; A whole bitmap of one's own: no origin to shift by and nothing to clip
;; against but its own edges.
(define (make-bitmap-rastport bm w h)
  (make-rastport-on bm w h 0 0 (list (rect 0 0 w h))))

(define (rastport? x)
  (if (%record? x) (%eq? (%record-ref x 0) 'rastport) nil))

(define (rp-bitmap r) (%record-ref r rp-bm))
(define (rp-bitmap-w r) (%record-ref r rp-bw))
(define (rp-bitmap-h r) (%record-ref r rp-bh))
(define (set-rp-bitmap! r bm w h)
  (%record-set! r rp-bm bm) (%record-set! r rp-bw w) (%record-set! r rp-bh h))
(define (rp-origin-x r) (%record-ref r rp-org-x))
(define (rp-origin-y r) (%record-ref r rp-org-y))
(define (rp-region r) (%record-ref r rp-clip))
(define (set-rp-origin! r x y) (%record-set! r rp-org-x x) (%record-set! r rp-org-y y))
(define (set-rp-region! r rgn) (%record-set! r rp-clip rgn))

(define (use-rastport rp) (set! *rp* rp) rp)

(define (clamp v lo hi) (if (%< v lo) lo (if (%> v hi) hi v)))

;; ---------------------------------------------- drawing, through a rastport
;; The three primitives everything else is built out of. With no rastport they
;; are what they always were; with one they shift by its origin and are cut to
;; its region, and every circle, glyph and line above them inherits that for
;; nothing.
(define (fill-rect x y w h c)
  (if *rp*
      (let ((r (rect (%+ x (rp-origin-x *rp*)) (%+ y (rp-origin-y *rp*)) w h))
            (bm (rp-bitmap *rp*)) (bw (rp-bitmap-w *rp*)) (bh (rp-bitmap-h *rp*)))
        (dolist (cr (rp-region *rp*))
          (let ((i (rect-intersect r cr)))
            (if i (bm-fill-rect bm bw bh (rect-x i) (rect-y i) (rect-w i) (rect-h i) c)
                nil))))
      (screen-fill-rect x y w h c))
  nil)

(define (plot x y c)
  (if *rp*
      (let ((px (%+ x (rp-origin-x *rp*)))
            (py (%+ y (rp-origin-y *rp*)))
            (go t))
        (dolist (cr (rp-region *rp*))
          (if (if go (rect-contains? cr px py) nil)
              (begin (bm-plot (rp-bitmap *rp*) (rp-bitmap-w *rp*) (rp-bitmap-h *rp*)
                              px py c)
                     (set! go nil))
              nil)))
      (screen-plot x y c))
  nil)

;; A copy inside one window: both ends shift, and the destination is cut to
;; the region. The source is not - it is the same bitmap, and whatever is on
;; top of it there is what a scroll should carry along.
(define (blit-rect sx sy dx dy w h)
  (if *rp*
      (let* ((ox (rp-origin-x *rp*))
             (oy (rp-origin-y *rp*))
             (d (rect (%+ dx ox) (%+ dy oy) w h)))
        (dolist (cr (rp-region *rp*))
          (let ((i (rect-intersect d cr)))
            (if i
                (let ((bm (rp-bitmap *rp*))
                      (bw (rp-bitmap-w *rp*))
                      (bh (rp-bitmap-h *rp*)))
                  (bm-blit-rect bm bw bh bm bw bh
                                (%+ (%+ sx ox) (%- (rect-x i) (rect-x d)))
                                (%+ (%+ sy oy) (%- (rect-y i) (rect-y d)))
                                (rect-x i) (rect-y i)
                                (rect-w i) (rect-h i)))
                nil))))
      (screen-blit-rect sx sy dx dy w h))
  nil)

(define (draw-line x0 y0 x1 y1 c)
  ;; Endpoints are clamped rather than properly clipped, so a line that leaves
  ;; the screen changes slope at the edge instead of being cut off. That keeps
  ;; it inside the bitmap, which is the part that matters.
  (let ((bm (if *rp* (rp-bitmap *rp*) *screen*))
        (bw (if *rp* (rp-bitmap-w *rp*) *screen-w*))
        (bh (if *rp* (rp-bitmap-h *rp*) *screen-h*))
        (ox (if *rp* (rp-origin-x *rp*) 0))
        (oy (if *rp* (rp-origin-y *rp*) 0)))
  (set! x0 (clamp (%+ x0 ox) 0 (%- bw 1)))
  (set! x1 (clamp (%+ x1 ox) 0 (%- bw 1)))
  (set! y0 (clamp (%+ y0 oy) 0 (%- bh 1)))
  (set! y1 (clamp (%+ y1 oy) 0 (%- bh 1)))
  (without-interrupts
    (poke blt-dst bm)
    (poke blt-dmod bw)
    (poke blt-x0 x0)
    (poke blt-y0 y0)
    (poke blt-x1 x1)
    (poke blt-y1 y1)
    (poke blt-val c)
    (poke blt-op op-line))))

;; Integer square root, by Newton. Wanted by anything that has to turn a
;; distance into a length, which on a machine with no floats is more things
;; than you would think.
(define (isqrt n)
  (if (%< n 2)
      (if (%< n 0) 0 n)
      (let ((x n) (y (%lsh (%+ n 1) -1)))
        (while (%< y x)
          (set! x y)
          (set! y (%lsh (%+ x (%/ n x)) -1)))
        x)))

;; A filled circle, one scanline at a time. fill-rect goes through the
;; blitter, so a circle costs two device pokes a row rather than a poke a
;; pixel, and the clipping is the blitter's problem.
(define (fill-circle cx cy r c)
  (let ((dy (%- 0 r)))
    (while (%<= dy r)
      (let ((w (isqrt (%- (%* r r) (%* dy dy)))))
        (fill-rect (%- cx w) (%+ cy dy) (%+ (%* 2 w) 1) 1 c))
      (set! dy (%+ dy 1)))
    nil))

(define (draw-circle cx cy r c)
  ;; The outline, by the same measure: the leftmost and rightmost pixel of
  ;; each row, plus the top and bottom caps where the rows run out.
  (let ((dy (%- 0 r)) (prev -1))
    (while (%<= dy r)
      (let ((w (isqrt (%- (%* r r) (%* dy dy)))))
        (if (%< prev 0)
            (fill-rect (%- cx w) (%+ cy dy) (%+ (%* 2 w) 1) 1 c)
            (if (%> w prev)
                (begin
                  (fill-rect (%- cx w) (%+ cy dy) (%- w (%- prev 1)) 1 c)
                  (fill-rect (%+ (%+ cx prev) 1) (%+ cy dy) (%- w prev) 1 c))
                (begin (plot (%- cx w) (%+ cy dy) c)
                       (plot (%+ cx w) (%+ cy dy) c))))
        (set! prev w))
      (set! dy (%+ dy 1)))
    nil))

(define (draw-box x y w h c)
  (draw-line x y (%+ x w) y c)
  (draw-line x (%+ y h) (%+ x w) (%+ y h) c)
  (draw-line x y x (%+ y h) c)
  (draw-line (%+ x w) y (%+ x w) (%+ y h) c))

;; ---------------------------------------------------------------- input
(define inp-event (dev-addr dev-input #x00))
(define inp-count (dev-addr dev-input #x04))
(define inp-mousex (dev-addr dev-input #x08))
(define inp-mousey (dev-addr dev-input #x0c))
(define inp-buttons (dev-addr dev-input #x10))
(define inp-ctrl (dev-addr dev-input #x14))
(define inp-mods (dev-addr dev-input #x18))

(define ev-keydown 1)
(define ev-keyup 2)
(define ev-mousemove 3)
(define ev-buttondown 4)
(define ev-buttonup 5)
(define ev-wheel 6)

(define (input-event) (peek inp-event))
(define (input-pending) (peek inp-count))
(define (event-kind e) (%logand (%lsh e -28) 15))
(define (event-ascii e) (%logand (%lsh e -20) 255))
(define (event-code e) (%logand (%lsh e -12) 255))
(define (event-payload e) (%logand e 4095))
(define (mouse-x) (peek inp-mousex))
(define (mouse-y) (peek inp-mousey))
(define (mouse-buttons) (peek inp-buttons))

;; ---------------------------------------------------------------- storage
(define dsk-addr (dev-addr dev-disk #x00))
(define dsk-block (dev-addr dev-disk #x04))
(define dsk-count (dev-addr dev-disk #x08))
(define dsk-cmd (dev-addr dev-disk #x0c))
(define dsk-status (dev-addr dev-disk #x10))
(define dsk-blocks (dev-addr dev-disk #x14))

(define (disk-read addr block n)
  (without-interrupts
    (poke dsk-addr addr)
    (poke dsk-block block)
    (poke dsk-count n)
    (poke dsk-cmd 1)
    (peek dsk-status)))

(define (disk-write addr block n)
  (without-interrupts
    (poke dsk-addr addr)
    (poke dsk-block block)
    (poke dsk-count n)
    (poke dsk-cmd 2)
    (peek dsk-status)))

(define (disk-blocks) (peek dsk-blocks))

;; ---------------------------------------------------------------- pool
;; Raw memory that the collector never touches and nothing ever moves: task
;; structures, message ports, stacks and bitmaps all live here.
;;
;; Every block carries an eight byte header - its total size, then a tag - and
;; the free blocks are threaded onto one list kept in address order, which is
;; what makes coalescing a comparison against the neighbour rather than a
;; search. First fit, split when the remainder is worth having.
;;
;; What the forge handed out before the machine ever ran - the trap save area,
;; the trap stack, the boot stack - has no header and is never freed. It sits
;; below the bump pointer this allocator starts carving from, so the two never
;; meet, and the tag is what tells anyone who tries to free one that they have
;; made a mistake.
(define pool-tag #x1feeded)     ; not a pool address, so it cannot be a link
(define pool-min 24)            ; a free block must hold its size and its link

(define (pool-size b) (%ld32 b))
(define (pool-next b) (%ld32 (%+ b 4)))
(define (pool-set-size! b n) (%st32! b n))
(define (pool-set-next! b n) (%st32! (%+ b 4) n))

(define (pool-zero p n)
  (let ((i 0))
    (while (%< i n)
      (%st32! (%+ p i) 0)
      (set! i (%+ i 4)))))

;; Carve a fresh block off the top, for when nothing on the free list fits.
(define (pool-extend need)
  (let ((p (%global lg-poolptr)))
    (if (%> (%+ p need) (%global lg-poolend))
        (out-of-memory "exec pool")
        nil)
    (%set-global! lg-poolptr (%+ p need))
    p))

(define (pool-take b prev need)
  ;; Hand out the front of a free block, and put any worthwhile remainder
  ;; back in its place on the list.
  (let ((size (pool-size b))
        (next (pool-next b)))
    (if (%>= (%- size need) pool-min)
        (let ((rest (%+ b need)))
          (pool-set-size! rest (%- size need))
          (pool-set-next! rest next)
          (pool-set-size! b need)
          (if prev (pool-set-next! prev rest) (%set-global! lg-pool-free rest)))
        (if prev (pool-set-next! prev next) (%set-global! lg-pool-free next)))
    b))

(define (alloc-pool nbytes)
  ;; Finding a block and claiming it is one act: the free list is threaded
  ;; through the blocks themselves and the bump pointer is a global.
  ;;
  ;; Clearing it is not, and must not be. A window bitmap is 141,696 bytes and
  ;; the screen is 786,432; zeroing that with interrupts off is most of a
  ;; frame during which the machine hears nothing at all. Once the block is
  ;; claimed it belongs to this caller and nobody else can be inside it.
  (let ((b (claim-pool nbytes)))
    (pool-zero (%+ b 8) (%- (pool-size b) 8))
    (%+ b 8)))

(define (claim-pool nbytes)
  (without-interrupts
  (let* ((need (let ((n (%logand (%+ (%+ nbytes 8) 7) -8)))
                 (if (%< n pool-min) pool-min n)))
         (b (let ((p (%global lg-pool-free)) (prev nil) (found nil))
              (while (if found nil (%> p 0))
                (if (%>= (pool-size p) need)
                    (set! found (pool-take p prev need))
                    (begin (set! prev p) (set! p (pool-next p)))))
              (if found found (let ((n (pool-extend need)))
                                (pool-set-size! n need)
                                n)))))
    (%st32! (%+ b 4) pool-tag)
    b)))

(define (free-pool p)
  ;; Insert in address order, joining up with either neighbour that touches.
  (without-interrupts
  (let ((b (%- p 8)))
    (if (%= (%ld32 (%+ b 4)) pool-tag)
        nil
        (error "free-pool: not an allocated block" p))
    (let ((size (pool-size b))
          (prev nil)
          (q (%global lg-pool-free)))
      (while (if (%> q 0) (%< q b) nil)
        (set! prev q)
        (set! q (pool-next q)))
      ;; Forward: absorb the next block if it starts where this one ends.
      (if (if (%> q 0) (%= (%+ b size) q) nil)
          (begin (set! size (%+ size (pool-size q))) (set! q (pool-next q)))
          nil)
      (pool-set-size! b size)
      (pool-set-next! b q)
      ;; Backward: if the previous block runs right up to this one, the two
      ;; become one and this header disappears.
      (if (if prev (%= (%+ prev (pool-size prev)) b) nil)
          (begin
            (pool-set-size! prev (%+ (pool-size prev) size))
            (pool-set-next! prev q))
          (if prev
              (pool-set-next! prev b)
              (%set-global! lg-pool-free b)))
      nil))))

(define (pool-used) (%- (%global lg-poolptr) pool-base))

(define (pool-free-bytes)
  (let ((p (%global lg-pool-free)) (n 0))
    (while (%> p 0)
      (set! n (%+ n (pool-size p)))
      (set! p (pool-next p)))
    n))
