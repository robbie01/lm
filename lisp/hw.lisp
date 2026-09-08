;;; hw.lisp - the custom chips.
;;;
;;; Every device is a 4 KiB page of naturally aligned 32-bit registers, so
;;; talking to hardware from Lisp is just peek and poke. Nothing here is
;;; privileged: this is a single address space with no MMU, and any task can
;;; reach the display or the blitter directly. That is the Amiga bargain -
;;; nothing protects you, and in exchange nothing gets in the way.

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
  ;; second so a wrap cannot leave a compare in the past.
  (let* ((lo (peek tmr-lo))
         (hi (peek tmr-hi))
         (sum (%+ (%logand lo 1073741823) n)))
    (poke tmr-cmphi (if (%> sum 1073741823) (%+ hi 1) hi))
    (poke tmr-cmplo (%logior (%logand lo -1073741824) (%logand sum 1073741823)))))

(define (timer-never)
  (poke tmr-cmphi -1)
  (poke tmr-cmplo -1))

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
    (poke gfx-base bm)
    (poke gfx-width w)
    (poke gfx-height h)
    (poke gfx-pitch w)
    (poke gfx-mode 8)
    (poke gfx-ctrl gfx-on)
    (default-palette)
    bm))

(define (set-colour i rgb)
  (poke gfx-palidx i)
  (poke gfx-paldat rgb))

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

(define (plot x y c)
  (if (if (%>= x 0) (if (%< x *screen-w*) (if (%>= y 0) (%< y *screen-h*) nil) nil) nil)
      (poke8 (%+ *screen* (%+ (%* y *screen-w*) x)) c)
      nil))

(define (point x y)
  (if (if (%>= x 0) (if (%< x *screen-w*) (if (%>= y 0) (%< y *screen-h*) nil) nil) nil)
      (peek8 (%+ *screen* (%+ (%* y *screen-w*) x)))
      0))

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
(define (clip-rect x y w h)
  ;; Returns (x y w h) trimmed to the screen, or nil if nothing is left.
  (let* ((x0 (if (%< x 0) 0 x))
         (y0 (if (%< y 0) 0 y))
         (x1 (let ((e (%+ x w))) (if (%> e *screen-w*) *screen-w* e)))
         (y1 (let ((e (%+ y h))) (if (%> e *screen-h*) *screen-h* e))))
    (if (if (%< x0 x1) (%< y0 y1) nil)
        (list x0 y0 (%- x1 x0) (%- y1 y0))
        nil)))

(define (fill-rect x y w h c)
  (let ((r (clip-rect x y w h)))
    (if r
        (begin
          (poke blt-dst (%+ *screen* (%+ (%* (cadr r) *screen-w*) (%car r))))
          (poke blt-w (caddr r))
          (poke blt-h (cadddr r))
          (poke blt-dmod *screen-w*)
          (poke blt-val c)
          (poke blt-op op-fill))
        nil)))

(define (clear-screen c) (fill-rect 0 0 *screen-w* *screen-h* c))

(define (blit-rect sx sy dx dy w h)
  ;; Clipped against both ends: the source rectangle and the destination have
  ;; to fit, and the smaller of the two wins.
  (let* ((sr (clip-rect sx sy w h))
         (dr (if sr (clip-rect dx dy (caddr sr) (cadddr sr)) nil)))
    (if dr
        (begin
          (poke blt-src (%+ *screen* (%+ (%* (cadr sr) *screen-w*) (%car sr))))
          (poke blt-dst (%+ *screen* (%+ (%* (cadr dr) *screen-w*) (%car dr))))
          (poke blt-w (caddr dr))
          (poke blt-h (cadddr dr))
          (poke blt-smod *screen-w*)
          (poke blt-dmod *screen-w*)
          (poke blt-op op-copy))
        nil)))

(define (clamp v lo hi) (if (%< v lo) lo (if (%> v hi) hi v)))

(define (draw-line x0 y0 x1 y1 c)
  ;; Endpoints are clamped rather than properly clipped, so a line that leaves
  ;; the screen changes slope at the edge instead of being cut off. That keeps
  ;; it inside the bitmap, which is the part that matters.
  (set! x0 (clamp x0 0 (%- *screen-w* 1)))
  (set! x1 (clamp x1 0 (%- *screen-w* 1)))
  (set! y0 (clamp y0 0 (%- *screen-h* 1)))
  (set! y1 (clamp y1 0 (%- *screen-h* 1)))
  (poke blt-dst *screen*)
  (poke blt-dmod *screen-w*)
  (poke blt-x0 x0)
  (poke blt-y0 y0)
  (poke blt-x1 x1)
  (poke blt-y1 y1)
  (poke blt-val c)
  (poke blt-op op-line))

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
  (poke dsk-addr addr)
  (poke dsk-block block)
  (poke dsk-count n)
  (poke dsk-cmd 1)
  (peek dsk-status))

(define (disk-write addr block n)
  (poke dsk-addr addr)
  (poke dsk-block block)
  (poke dsk-count n)
  (poke dsk-cmd 2)
  (peek dsk-status))

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
    (pool-zero (%+ b 8) (%- (pool-size b) 8))
    (%+ b 8)))

(define (free-pool p)
  ;; Insert in address order, joining up with either neighbour that touches.
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
      nil)))

(define (pool-used) (%- (%global lg-poolptr) pool-base))

(define (pool-free-bytes)
  (let ((p (%global lg-pool-free)) (n 0))
    (while (%> p 0)
      (set! n (%+ n (pool-size p)))
      (set! p (pool-next p)))
    n))
