;;; hw.lisp - the custom chips.
;;;
;;; Every device is a 4 KiB page of naturally aligned 32-bit registers, so
;;; talking to hardware from Lisp is just peek and poke. Nothing here is
;;; privileged: this is a single address space with no MMU, and any task can
;;; reach the display or the blitter directly. That is the Amiga bargain -
;;; nothing protects you, and in exchange nothing gets in the way.

(in-package hw)

(define (dev-addr dev reg) (%+ mmio-base (%+ (%lsh dev 12) reg)))
;; A whole machine word, all thirty-two bits of it, promoting when it does
;; not fit a fixnum.
;;
;; These used to be `%ld-fixnum` and `%st-fixnum!` outright - one instruction
;; each. But a tagged load *tags*, and a fixnum is thirty-one bits, so bit 31
;; came off the top: `(peek a)` of a word holding 0x80000000 answered 0, and
;; said nothing. That is not a hypothetical - it cost a session of chasing
;; heap corruption in the collector, where a mark-bitmap word read this way
;; compared equal to zero and a live pair was left behind.
;;
;; Unsigned, like `%ld-byte` and `%ld-half`, which are both zero-extending
;; loads: a word is a bit pattern, and the neutral reading of one is the
;; number it spells. `poke` takes either sign and stores the low thirty-two
;; bits, so a value read out of one address goes back into another unchanged.
;;
;; The raw forms are still there and still one instruction. Use them where the
;; value is known to be an address or a small number - the collector and the
;; device registers do, and they are the reason the fast path matters.
;; A word is thirty-two bits and a fixnum is thirty-one, so reading one into
;; a value has to say which number it means. Three names, three answers:
;;
;;   peek / poke               the word as an *unsigned* integer, 0..2^32-1
;;   peek-signed               the same word as -2^31..2^31-1
;;   %ld-fixnum / %st-fixnum!  the raw instruction: the low thirty-one bits,
;;                             sign extended, in one instruction. The right
;;                             thing for an address or a count, neither of
;;                             which can have the top bit set on this machine.
;;
;; `poke` takes anything from -2^31 to 2^32-1 and stores the low thirty-two
;; bits, so a word read either way goes back unchanged.
;;
;; Unsigned is the default because a location is a bit pattern and the neutral
;; reading of one is the number it spells. It costs something: a word with its
;; top bit set becomes a bignum, where the signed reading would have kept it a
;; fixnum. That is the *only* case where the two differ in cost - a word with
;; bit 30 set and not bit 31 is 2^30, which is one past the largest fixnum and
;; promotes under either reading.
;;
;; These used to be `%ld-fixnum` and `%st-fixnum!` outright. But a tagged load
;; *tags*, and tagging drops bit 31: `(peek a)` of a word holding 0x80000000
;; answered 0, and said nothing about it. That is not hypothetical - it cost a
;; session of chasing heap corruption, where a mark-bitmap word read this way
;; compared equal to zero and a live pair was left behind by the collector.
;;
;; **The location is read once.** Taking a word apart with two half-word loads
;; reads it twice, which is fine for memory and wrong for a device register:
;; the timer's counter moves between the two reads, the random register rolls
;; again, and a half-word *write* to a device only writes the low lane. So the
;; word is moved whole, with one access, and taken apart in a scratch cell.
;; `lg-scratch3` on purpose: the collector scans `lg-scratch0` as a root, and
;; what sits here is a raw word rather than a value.
(define peek-scratch lg-scratch3)

;; Neither of these widens by trapping - see `halves->unsigned`. Both are
;; reachable from an interrupt server, and a trap cannot nest.
(define (peek a)
  (without-interrupts
    (%st-word! peek-scratch (%ld-word a))
    (halves->unsigned (%ld-half peek-scratch)
                      (%ld-half (%+ peek-scratch 2)))))

(define (peek-signed a)
  (without-interrupts
    (%st-word! peek-scratch (%ld-word a))
    (halves->signed (%ld-half peek-scratch)
                    (%ld-half (%+ peek-scratch 2)))))

(define (poke a v)
  (if (%fixnum? v)
      ;; One instruction, and exact: the store untags, which sign-extends a
      ;; fixnum across the whole word.
      (%st-fixnum! a v)
      (without-interrupts
        (bignum-poke-word peek-scratch v)
        (%st-word! a (%ld-word peek-scratch))
        v)))
(define (peek8 a) (%ld-byte a))
(define (poke8 a v) (%st-byte! a v))

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
;; Thirty bits and never negative, so it stays a fixnum and `(mod (random) n)`
;; is fixnum arithmetic. The register is a full word; taking all of it would
;; hand back a bignum half the time.
(define (random) (%logand (%ld-fixnum sys-random) 1073741823))
(define (int-enable line) (poke sys-intena (%logior (peek sys-intena) (%lsh 1 line))))
(define (int-disable line) (poke sys-intena (%logand (peek sys-intena) (%lognot (%lsh 1 line)))))
(define (int-ack line) (poke sys-intreq (%lsh 1 line)))
(define (int-raise line) (poke sys-intset (%lsh 1 line)))
;; The line number, or -1 when nothing is pending - which the chip spells as
;; a word of all ones. The raw load rather than `peek-signed`: a line number
;; is five bits and the sentinel is the one value where the two readings
;; differ, so the one-instruction form says exactly what is meant and cannot
;; allocate. This runs inside the trap handler.
(define (int-pending) (%ld-fixnum sys-intnum))

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
  ;;
  ;; Sixteen bits at a time, and every operation here is a fixnum one. Traps
  ;; nest now, so the promoting `+` would work - but this is called from the
  ;; timer interrupt every quantum, and the promoting version would take a
  ;; second trap and allocate a bignum each time, on the one path where that
  ;; is least welcome. So it is a choice rather than a requirement.
  ;;
  ;; It used to carry at 2^30 and mask the low half back together by hand,
  ;; which was the same problem answered by giving up on the top two bits.
  (without-interrupts
    (%st-word! peek-scratch (%ld-word tmr-lo))
    (let* ((l0 (%ld-half peek-scratch))
           (l1 (%ld-half (%+ peek-scratch 2)))
           (s0 (%+ l0 (%logand n 65535)))
           (s1 (%+ (%+ l1 (%lsh n -16)) (%lsh s0 -16))))
      ;; the high half first, so a wrap cannot leave a compare in the past
      (%st-fixnum! tmr-cmphi (%+ (%ld-fixnum tmr-hi) (%lsh s1 -16)))
      (%st-half! peek-scratch (%logand s0 65535))
      (%st-half! (%+ peek-scratch 2) (%logand s1 65535))
      (%st-word! tmr-cmplo (%ld-word peek-scratch)))))

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

;; ---------------------------------------------------------------- bitmaps
;; Where pixels live: the memory, and how wide and tall it is. The memory is
;; raw pool rather than a Lisp object, because the display reads it directly
;; and it must never move or be scanned - but the three numbers that describe
;; it are one value.
;;
;; They used to be three arguments. `bm-blit-rect` took twelve of them with
;; the source and destination triples adjacent and interchangeable, and every
;; caller had a base, a width and a height that had to be kept in step by
;; hand. A width that does not match the memory it describes is not a drawing
;; that looks wrong: the clipping passes and the write lands past the end,
;; where the stacks are.
(defrecord (bitmap bm) addr w h)

(define (make-bitmap addr w h)
  (let ((b (bm-alloc)))
    (set-bm-addr! b addr)
    (set-bm-w! b w)
    (set-bm-h! b h)
    b))

(define (alloc-bitmap w h) (make-bitmap (alloc-pool (%* w h)) w h))

(define *screen* nil)      ; the bitmap currently being displayed

(define (open-screen w h)
  (set! *screen* (alloc-bitmap w h))
  (attach-screen))

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
        (poke gfx-base (bm-addr *screen*))
        (poke gfx-width (bm-w *screen*))
        (poke gfx-height (bm-h *screen*))
        (poke gfx-pitch (bm-w *screen*))
        (poke gfx-mode 8)
        ;; The vblank interrupt goes on with the display. Exec has a server on
        ;; it before this runs, and writing the control register without the
        ;; bit would quietly turn the frame clock off again.
        (poke gfx-ctrl (%logior gfx-on gfx-vbirq))
        (default-palette)
        (set! *screen-rp* (make-bitmap-rastport *screen*))
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

(define (bm-at b x y) (%+ (bm-addr b) (%+ (%* y (bm-w b)) x)))

(define (bm-inside? b x y)
  (if (%>= x 0)
      (if (%< x (bm-w b)) (if (%>= y 0) (%< y (bm-h b)) nil) nil)
      nil))

(define (bm-plot b x y c)
  (if (bm-inside? b x y) (poke8 (bm-at b x y) c) nil))

(define (bm-point b x y)
  (if (bm-inside? b x y) (peek8 (bm-at b x y)) 0))

(define (screen-plot x y c) (bm-plot *screen* x y c))
(define (point x y) (bm-point *screen* x y))

;; ---------------------------------------------------------------- blitter
;; The one register worth naming: the address of a command block. The chip
;; has a full set of parameter registers too, and programming through them
;; takes six stores that something has to hold off - which is what the block
;; exists to avoid, so nothing here reaches for them.
(define blt-list (dev-addr dev-blit blit-list-reg))

;; ---------------------------------------------------------------- commands
;; The blitter takes its whole command from a block in memory, in one store, so
;; nothing has to be held off while it is programmed.
;;
;; That works only because the block belongs to whoever is filling it. A shared
;; block would have exactly the race the registers had: an interrupt server
;; that blits inside a task's setup would overwrite the half the task had
;; written, and the task would then commit a coherent command made of both.
;; So every task has a block of its own, swapped in by the scheduler the way
;; `*out*` and the current package are, and interrupt servers have one more.
;; Two contexts are never half way through the same block.
(define *blit-list* 0)      ; the running task's, swapped in with its bindings
(define *gc-blit-list* 0)   ; and one the collector owns outright
(define *in-interrupt* nil) ; set by the trap handler, cleared before it returns

;; The blitter belongs to task context.
;;
;; Every task fills a command block of its own, so programming the chip needs
;; no lock: two tasks are never half way through the same one, and the store
;; that commits it is a single word. That is ownership by disjointness, and it
;; is the whole arbitration - there is nothing to claim and nothing to release.
;;
;; An interrupt server does not get one and is not meant to. It used to: the
;; trap handler swapped a second block in for the duration, which looked
;; harmless and was the worst bug this machine has had. `*blit-list*` is per
;; task and the scheduler swaps it with the rest of a task's bindings - from
;; inside that handler - so the swap leaked one task's block into another's,
;; and two contexts then programmed one block. What the chip ran was half of
;; each: a destination from one window with the stride of another, writing
;; pixels across whatever followed the bitmap it thought it had.
;;
;; The fix at the time was to choose the block by asking rather than by
;; assigning, which closed the race. This closes the class: an interrupt
;; server has no business drawing. It runs with the world half saved, it must
;; not allocate, it must not block, and anything it draws is drawn over by the
;; next task that composites. If a server wants pixels it signals a task and
;; the task draws them - which is what every interrupt in this system already
;; does, and why nothing was using the second block by the time it was
;; deleted.
;;
;; The collector is the exception and has a block of its own rather than a
;; borrowed one. It clears its bit maps with the chip, it can run in either
;; context, and it holds interrupts off for the whole collection - so one
;; block, owned outright, is exactly the right shape for it. It is also why
;; `blit-block` can afford to be strict: the one caller that legitimately runs
;; anywhere does not go through it.
(define (blit-block)
  (if *in-interrupt*
      (error "the blitter is task context only: signal a task instead")
      nil)
  (if (%= *blit-list* 0) (set! *blit-list* (alloc-pool blit-list-size)) nil)
  *blit-list*)

;; The collector's own. Not a fluid binding: a collection runs with interrupts
;; off from end to end, so there is never a second one to keep apart from.
(define (gc-blit-block)
  (if (%= *gc-blit-list* 0)
      (set! *gc-blit-list* (alloc-pool blit-list-size))
      nil)
  *gc-blit-list*)

(define (blit-go b op)
  (poke (%+ b bl-op) op)
  (poke blt-list b)
  nil)



;; Everything that touches the bitmap clips to it first. The bitmap is raw
;; pool memory with task structures and stacks immediately after it, so a
;; rectangle that runs off the right edge does not merely look wrong - it
;; writes over the scheduler.
(define (bm-clip b x y w h)
  ;; Returns (x y w h) trimmed to a bitmap that size, or nil if nothing is
  ;; left. Every write to a bitmap goes through here first: bitmaps are raw
  ;; pool memory with task structures and stacks immediately after them, so a
  ;; rectangle that runs off the right edge does not merely look wrong - it
  ;; writes over the scheduler.
  (let* ((bw (bm-w b))
         (bh (bm-h b))
         (x0 (if (%< x 0) 0 x))
         (y0 (if (%< y 0) 0 y))
         (x1 (let ((e (%+ x w))) (if (%> e bw) bw e)))
         (y1 (let ((e (%+ y h))) (if (%> e bh) bh e))))
    (if (if (%< x0 x1) (%< y0 y1) nil)
        (list x0 y0 (%- x1 x0) (%- y1 y0))
        nil)))

(define (clip-rect x y w h) (bm-clip *screen* x y w h))

;; A device command is several register writes and then the one that starts
;; it. Those writes are a single act: two tasks interleaved in here would each
;; start the other's blit, which shows up as a stray line across the screen
;; from a rectangle that was supposed to be clipped to a window.
;;
;; The clipping is computed first, outside, because it is the expensive half
;; and it touches nothing shared.
(define (bm-fill-rect bmp x y w h c)
  (let ((r (bm-clip bmp x y w h)))
    (if r
        (let ((b (blit-block)))
          (poke (%+ b bl-dst) (bm-at bmp (%car r) (cadr r)))
          (poke (%+ b bl-w) (caddr r))
          (poke (%+ b bl-h) (cadddr r))
          (poke (%+ b bl-dmod) (bm-w bmp))
          (poke (%+ b bl-val) c)
          (blit-go b op-fill))
        nil)))

(define (screen-fill-rect x y w h c) (bm-fill-rect *screen* x y w h c))

(define (clear-screen c)
  (fill-rect (screen-rastport) 0 0 (bm-w *screen*) (bm-h *screen*) c))

(define (bm-blit-rect src dst sx sy dx dy w h)
  ;; Clipped against both ends: the source rectangle and the destination have
  ;; to fit, and the smaller of the two wins. Source and destination may be
  ;; the same bitmap, which is what a scroll inside a window is, or different
  ;; ones, which is what compositing is.
  (let* ((sr (bm-clip src sx sy w h))
         (dr (if sr (bm-clip dst dx dy (caddr sr) (cadddr sr)) nil)))
    (if dr
        (let ((b (blit-block)))
          (poke (%+ b bl-src) (bm-at src (%car sr) (cadr sr)))
          (poke (%+ b bl-dst) (bm-at dst (%car dr) (cadr dr)))
          (poke (%+ b bl-w) (caddr dr))
          (poke (%+ b bl-h) (cadddr dr))
          (poke (%+ b bl-smod) (bm-w src))
          (poke (%+ b bl-dmod) (bm-w dst))
          (blit-go b op-copy))
        nil)))

(define (screen-blit-rect sx sy dx dy w h)
  (bm-blit-rect *screen* *screen* sx sy dx dy w h))

;; ---------------------------------------------------------------- regions
;; A region is a list of rectangles that do not overlap. Rectangles are lists
;; of four numbers, because a region rarely has more than three of them and
;; the whole of the arithmetic below is one screenful.
;;
;; This is what a window system is made of. A window may draw into the part of
;; the bitmap it actually owns - its rectangle, less the rectangles of every
;; window in front of it - and subtracting one rectangle from another is the
;; only operation needed to work that out.
(defrecord rect x y w h)

(define (rect x y w h)
  (let ((r (rect-alloc)))
    (set-rect-x! r x)
    (set-rect-y! r y)
    (set-rect-w! r w)
    (set-rect-h! r h)
    r))

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
;; bitmap it is allowed to touch. Every drawing call takes one, the way the
;; graphics library this is copied from does - `RectFill(rp, ...)`, rather
;; than a mode set earlier and somewhere else.
;;
;; It used to be a current one, in `*rp*`, saved and restored by the scheduler
;; along with a task's streams - because an implicit target has to be per task
;; or two tasks drawing at once draw into each other's windows. That worked,
;; and it made the target of a drawing call a fact about the calling task's
;; history rather than about the call. A rastport belongs to a window, a
;; window belongs to whoever opened it, and anybody holding the window can
;; draw into it without borrowing anything or putting anything back.
;;
;; The bitmap is the part that makes a window a window rather than a promise
;; about clipping. Two tasks drawing into two bitmaps cannot reach each other
;; however wrong their arithmetic is; two tasks drawing into one screen behind
;; two clipping regions can, and did.
(defrecord (rastport rp) bitmap origin-x origin-y region)

(define *screen-rp* nil)

(define (make-rastport-on bmp ox oy clip)
  (let ((r (rp-alloc)))
    (set-rp-bitmap! r bmp)
    (set-rp-origin-x! r ox)
    (set-rp-origin-y! r oy)
    (set-rp-region! r clip)
    r))

;; The screen is the default target, so the old three-argument form still
;; means what it always did.
(define (make-rastport ox oy clip)
  (make-rastport-on *screen* ox oy clip))

;; A whole bitmap of one's own: no origin to shift by and nothing to clip
;; against but its own edges.
(define (make-bitmap-rastport bmp)
  (make-rastport-on bmp 0 0 (list (rect 0 0 (bm-w bmp) (bm-h bmp)))))

;; The screen as a rastport, which is what the boot messages and the desktop
;; draw into. Having one means no primitive below needs a second path for the
;; case where there is no rastport at all. It carries the screen's size, so
;; `attach-screen` builds a fresh one rather than keep this across a resize.
(define (screen-rastport)
  (if *screen-rp*
      *screen-rp*
      (begin (set! *screen-rp* (make-bitmap-rastport *screen*))
             *screen-rp*)))

(define (set-rp-origin! r x y)
  (set-rp-origin-x! r x)
  (set-rp-origin-y! r y))

;; A colour is a byte, and that is checked wherever one comes in. It used to
;; be that a negative number meant "no background" to `draw-char`, so a colour
;; arrived at by bad arithmetic was a picture nobody could account for rather
;; than a complaint at the door. `nil` says that now, and a number that is not
;; a colour says so here.
(define (check-colour c)
  (if (%fixnum? c)
      (if (%>= c 0) (if (%< c 256) c (bad-colour c)) (bad-colour c))
      (bad-colour c)))

(define (bad-colour c) (error "not a colour" c))

;; ---------------------------------------------- drawing, through a rastport
;; The three primitives everything else is built out of. Each shifts by the
;; rastport's origin and is cut to its region, and every circle, glyph and
;; line above them inherits that for nothing.
(define (fill-rect rp x y w h c)
  (let ((r (rect (%+ x (rp-origin-x rp)) (%+ y (rp-origin-y rp)) w h))
        (bmp (rp-bitmap rp)))
    (dolist (cr (rp-region rp))
      (let ((i (rect-intersect r cr)))
        (if i (bm-fill-rect bmp (rect-x i) (rect-y i) (rect-w i) (rect-h i) c)
            nil))))
  nil)

(define (plot rp x y c)
  (let ((px (%+ x (rp-origin-x rp)))
        (py (%+ y (rp-origin-y rp)))
        (go t))
    (dolist (cr (rp-region rp))
      (if (if go (rect-contains? cr px py) nil)
          (begin (bm-plot (rp-bitmap rp) px py c)
                 (set! go nil))
          nil)))
  nil)

;; A copy inside one bitmap: both ends shift, and the destination is cut to
;; the region. The source is not - it is the same bitmap, and whatever is on
;; top of it there is what a scroll should carry along.
(define (blit-rect rp sx sy dx dy w h)
  (let* ((ox (rp-origin-x rp))
         (oy (rp-origin-y rp))
         (d (rect (%+ dx ox) (%+ dy oy) w h)))
    (dolist (cr (rp-region rp))
      (let ((i (rect-intersect d cr)))
        (if i
            (let ((bmp (rp-bitmap rp)))
              (bm-blit-rect bmp bmp
                            (%+ (%+ sx ox) (%- (rect-x i) (rect-x d)))
                            (%+ (%+ sy oy) (%- (rect-y i) (rect-y d)))
                            (rect-x i) (rect-y i)
                            (rect-w i) (rect-h i)))
            nil))))
  nil)

(define (draw-line rp x0 y0 x1 y1 c)
  ;; Endpoints are clamped rather than properly clipped, so a line that leaves
  ;; the bitmap changes slope at the edge instead of being cut off. That keeps
  ;; it inside, which is the part that matters.
  (let* ((bmp (rp-bitmap rp))
         (bw (bm-w bmp))
         (bh (bm-h bmp))
         (ox (rp-origin-x rp))
         (oy (rp-origin-y rp)))
  (set! x0 (clamp (%+ x0 ox) 0 (%- bw 1)))
  (set! x1 (clamp (%+ x1 ox) 0 (%- bw 1)))
  (set! y0 (clamp (%+ y0 oy) 0 (%- bh 1)))
  (set! y1 (clamp (%+ y1 oy) 0 (%- bh 1)))
  (let ((b (blit-block)))
    (poke (%+ b bl-dst) (bm-addr bmp))
    (poke (%+ b bl-dmod) bw)
    (poke (%+ b bl-x0) x0)
    (poke (%+ b bl-y0) y0)
    (poke (%+ b bl-x1) x1)
    (poke (%+ b bl-y1) y1)
    (poke (%+ b bl-val) c)
    (blit-go b op-line))))

;; A filled circle, one scanline at a time. fill-rect goes through the
;; blitter, so a circle costs two device pokes a row rather than a poke a
;; pixel, and the clipping is the blitter's problem.
(define (fill-circle rp cx cy r c)
  (let ((dy (%- 0 r)))
    (while (%<= dy r)
      (let ((w (isqrt (%- (%* r r) (%* dy dy)))))
        (fill-rect rp (%- cx w) (%+ cy dy) (%+ (%* 2 w) 1) 1 c))
      (set! dy (%+ dy 1)))
    nil))

(define (draw-circle rp cx cy r c)
  ;; The outline, by the same measure: the leftmost and rightmost pixel of
  ;; each row, plus the top and bottom caps where the rows run out.
  (let ((dy (%- 0 r)) (prev -1))
    (while (%<= dy r)
      (let ((w (isqrt (%- (%* r r) (%* dy dy)))))
        (if (%< prev 0)
            (fill-rect rp (%- cx w) (%+ cy dy) (%+ (%* 2 w) 1) 1 c)
            (if (%> w prev)
                (begin
                  (fill-rect rp (%- cx w) (%+ cy dy) (%- w (%- prev 1)) 1 c)
                  (fill-rect rp (%+ (%+ cx prev) 1) (%+ cy dy) (%- w prev) 1 c))
                (begin (plot rp (%- cx w) (%+ cy dy) c)
                       (plot rp (%+ cx w) (%+ cy dy) c))))
        (set! prev w))
      (set! dy (%+ dy 1)))
    nil))

(define (draw-box rp x y w h c)
  (draw-line rp x y (%+ x w) y c)
  (draw-line rp x (%+ y h) (%+ x w) (%+ y h) c)
  (draw-line rp x y x (%+ y h) c)
  (draw-line rp (%+ x w) y (%+ x w) (%+ y h) c))

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

(define (pool-size b) (%ld-fixnum b))
(define (pool-next b) (%ld-fixnum (%+ b 4)))
(define (pool-set-size! b n) (%st-fixnum! b n))
(define (pool-set-next! b n) (%st-fixnum! (%+ b 4) n))

(define (pool-zero p n)
  (let ((i 0))
    (while (%< i n)
      (%st-fixnum! (%+ p i) 0)
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
    (%st-fixnum! (%+ b 4) pool-tag)
    b)))

(define (free-pool p)
  ;; Insert in address order, joining up with either neighbour that touches.
  (without-interrupts
  (let ((b (%- p 8)))
    (if (%= (%ld-fixnum (%+ b 4)) pool-tag)
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
