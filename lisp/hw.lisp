;;; hw.lisp - the custom chips.
;;;
;;; Every device is a 4 KiB page of naturally aligned 32-bit registers. There
;;; is no MMU and no privileged mode. What keeps a task off a device it does
;;; not own is that it cannot name one: a device is a value, a register is an
;;; offset into its page (generated into layout.lisp from the Rust side), and
;;; `dev-reg` is the only way to turn the two into an address.

(in-package hw)

(define (dev-addr dev reg) (%+ mmio-base (%+ (%lsh dev 12) reg)))

;; ---------------------------------------------------------------- devices
;; A device's owner is one of three things:
;;
;;   kernel   Exec's: `sys`, `timer` and the blitter. Never claimed and not
;;            checked against the running task, because Exec runs inside
;;            whichever task called it or inside the trap handler. Reached
;;            only through the functions in this file.
;;   nil      A driver's device that no driver has claimed. Usable by whoever
;;            holds it, which is how the machine works before its drivers are
;;            up and during a rebuild.
;;   a task   Claimed. `dev-reg` from any other task is an error.
(defrecord (device dv) name base owner)

(define (make-device name dev owner)
  (let ((d (dv-alloc)))
    (set-dv-name! d name)
    (set-dv-base! d (dev-addr dev 0))
    (set-dv-owner! d owner)
    d))

(define (device-owner d) (dv-owner d))
(define (device-name d) (dv-name d))

(define (device-usable? d)
  (let ((o (dv-owner d)))
    (if (%null? o) t (if (%eq? o 'kernel) t (%eq? o (%this-task))))))

(define (dev-reg d off)
  (if (device-usable? d)
      (%+ (dv-base d) off)
      (error "dev-reg:" (dv-name d) "belongs to another task")))

;; The devices some task holds right now, so that a task that dies gives back
;; exactly what it held.
(define *claimed* nil)

(define (claim-device d) (claim-device-for d (%this-task)))

;; On another task's behalf: a driver's device is claimed for it before it
;; first runs, so nobody can reach the driver's port while the device is still
;; anybody's. The error is raised outside the critical section, because an
;; error abandons the stack and would abandon the section with it.
(define (claim-device-for d task)
  (let ((ok (without-interrupts
              (if (%null? (dv-owner d))
                  (begin
                    (set-dv-owner! d task)
                    (set! *claimed* (%cons d *claimed*))
                    t)
                  nil))))
    (if ok d (error "claim-device:" (dv-name d) "is already owned"))))

(define (release-device d)
  (if (%eq? (dv-owner d) (%this-task))
      (without-interrupts
        (set-dv-owner! d nil)
        (set! *claimed* (remove-eq d *claimed*)))
      (error "release-device:" (dv-name d) "is not this task's"))
  nil)

;; ---------------------------------------------------------------- words
;; A location holds thirty-two bits and a fixnum thirty-one, so reading one
;; has to say which number it means:
;;
;;   peek / poke               the word as an unsigned integer, 0..2^32-1
;;   peek-signed               the same word as -2^31..2^31-1
;;   %ld-fixnum / %st-fixnum!  the raw instruction: the low thirty-one bits,
;;                             sign extended. Right for an address or a count,
;;                             neither of which can have the top bit set here.
;;
;; `poke` takes anything from -2^31 to 2^32-1 and stores the low thirty-two
;; bits, so a word read either way goes back unchanged. A word with its top
;; bit set reads as a bignum under `peek`, so the collector and the device
;; code use the raw forms where they can.
;;
;; The location is read once, with one access, and taken apart in a scratch
;; cell: two half-word loads would read a device register twice, and a
;; half-word store would write one lane. `lg-scratch3` is not scanned by the
;; collector; what sits here is a raw word.
(define peek-scratch lg-scratch3)

;; Neither of these widens by trapping: they are reachable from interrupt
;; servers, and build the object directly.
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
      ;; one instruction, and exact: the store sign-extends the fixnum
      (%st-fixnum! a v)
      (without-interrupts
        (bignum-poke-word peek-scratch v)
        (%st-word! a (%ld-word peek-scratch))
        v)))
(define (peek8 a) (%ld-byte a))
(define (poke8 a v) (%st-byte! a v))

;; ---------------------------------------------------------------- system
(define *sys* (make-device "sys" dev-sys 'kernel))

;; Thirty bits and never negative, so it stays a fixnum.
(define (random) (%logand (%ld-fixnum (dev-reg *sys* sys-random)) 1073741823))

;; Read-modify-write of the enable register, atomic: a task turning a line
;; back on races the interrupt server that masks it.
(define (int-enable line)
  (let ((r (dev-reg *sys* sys-intena)))
    (without-interrupts (poke r (%logior (peek r) (%lsh 1 line))))))
(define (int-disable line)
  (let ((r (dev-reg *sys* sys-intena)))
    (without-interrupts (poke r (%logand (peek r) (%lognot (%lsh 1 line)))))))
(define (int-ack line) (poke (dev-reg *sys* sys-intreq) (%lsh 1 line)))
(define (int-raise line) (poke (dev-reg *sys* sys-intset) (%lsh 1 line)))
;; The lowest pending and enabled line, or -1, which the chip spells as a
;; word of all ones. The raw load: a line number is five bits, and the
;; sentinel is the one value where the two readings differ. Runs inside the
;; trap handler and must not allocate.
(define (int-pending) (%ld-fixnum (dev-reg *sys* sys-intnum)))

;; ---------------------------------------------------------------- timer
(define *timer* (make-device "timer" dev-timer 'kernel))

;; The timebase is the retired instruction count, so the same program
;; produces the same schedule on every run.
(define (millis) (peek (dev-reg *timer* tmr-wall)))

;; Fire n ticks from now. The compare is 64 bits: the high half is written
;; first so a wrap cannot leave a compare in the past, and both halves go out
;; inside one section. Sixteen bits at a time with fixnum operations, because
;; this runs from the timer interrupt every quantum and the promoting `+`
;; would take a second trap and allocate a bignum each time.
(define (timer-set-in n)
  (without-interrupts
    (%st-word! peek-scratch (%ld-word (dev-reg *timer* tmr-lo)))
    (let* ((l0 (%ld-half peek-scratch))
           (l1 (%ld-half (%+ peek-scratch 2)))
           (s0 (%+ l0 (%logand n 65535)))
           (s1 (%+ (%+ l1 (%lsh n -16)) (%lsh s0 -16))))
      (%st-fixnum! (dev-reg *timer* tmr-cmphi)
                   (%+ (%ld-fixnum (dev-reg *timer* tmr-hi)) (%lsh s1 -16)))
      (%st-half! peek-scratch (%logand s0 65535))
      (%st-half! (%+ peek-scratch 2) (%logand s1 65535))
      (%st-word! (dev-reg *timer* tmr-cmplo) (%ld-word peek-scratch)))))

(define (timer-never)
  (without-interrupts
    (poke (dev-reg *timer* tmr-cmphi) -1)
    (poke (dev-reg *timer* tmr-cmplo) -1)))

;; ---------------------------------------------------------------- releasing
;; A driver that dies must not take its peripheral with it.
(define (release-devices-of task)
  (without-interrupts
    (let ((keep nil))
      (dolist (d *claimed*)
        (if (%eq? (dv-owner d) task)
            (set-dv-owner! d nil)
            (set! keep (%cons d keep))))
      (set! *claimed* keep)))
  nil)

;; After a resume every task that owned a device is gone.
(define (release-all-devices)
  (without-interrupts
    (dolist (d *claimed*) (set-dv-owner! d nil))
    (set! *claimed* nil))
  nil)

;; ---------------------------------------------------------------- display
;; The display chip: where the picture comes from, how big it is, the
;; palette, and whether it raises the vertical blank. gfx.driver owns it (see
;; gfx.lisp); until the driver has claimed it, whoever holds it may use it.
(define *gfx* (make-device "gfx" dev-gfx nil))

;; The size the machine comes up in.
(define screen-width 1024)
(define screen-height 768)

;; ---------------------------------------------------------------- bitmaps
;; A bitmap is a byte object and its two dimensions. Holding the object rather
;; than an address means a bitmap cannot be forged, an overrun reaches at
;; worst another object, the collector frees the pixels when the last
;; reference goes, and the extent is checked once at construction so that
;; everything downstream can trust `w` and `h`. An address taken out of a
;; byte object is good for ever because objects never move, which is what
;; lets one be handed to the display register and to the blitter.
(defrecord (bitmap bm) pixels w h)

(define (make-bitmap pixels w h)
  (if (%bytes? pixels)
      nil
      (error "make-bitmap: pixels must be a byte object" pixels))
  (if (%<= (%* w h) (%bytes-length pixels))
      nil
      (error "make-bitmap: too small for" w h))
  (let ((b (bm-alloc)))
    (set-bm-pixels! b pixels)
    (set-bm-w! b w)
    (set-bm-h! b h)
    b))

;; Where the pixels are, as a raw address, for command blocks and the display
;; register.
(defsubst (bm-addr b) (%addr-of (bm-pixels b)))

;; `make-bytes` zero-fills, so a new bitmap starts black.
(define (alloc-bitmap w h) (make-bitmap (make-bytes (%* w h)) w h))

(define *screen* nil)      ; the bitmap being displayed; gfx.driver sets it

;; Point the chip at a bitmap, 8-bit indexed, with the picture and the frame
;; clock on: writing the control register without the interrupt bit would
;; stop the vertical blank.
(define (gfx-show b)
  (let ((base (dev-reg *gfx* 0)))
    (poke (%+ base gfx-base) (bm-addr b))
    (poke (%+ base gfx-width) (bm-w b))
    (poke (%+ base gfx-height) (bm-h b))
    (poke (%+ base gfx-pitch) (bm-w b))
    (poke (%+ base gfx-mode) 8)
    (poke (%+ base gfx-ctrl) (%logior gfx-on gfx-vbirq)))
  b)

(define (gfx-vblank-irq! on)
  (let ((r (dev-reg *gfx* gfx-ctrl)))
    (poke r (if on
                (%logior (peek r) gfx-vbirq)
                (%logand (peek r) (%lognot gfx-vbirq))))))

;; An index register and a data register: two writes that mean one thing.
(define (gfx-colour! i c)
  (let ((base (dev-reg *gfx* 0)))
    (without-interrupts
      (poke (%+ base gfx-palidx) i)
      (poke (%+ base gfx-paldat) c))))

(define (gfx-present!) (poke (dev-reg *gfx* gfx-sync) 1))

(define (rgb r g b)
  (%logior (%lsh (%logand r 255) 16)
           (%logior (%lsh (%logand g 255) 8) (%logand b 255))))

(define (bm-at b x y) (%+ (bm-addr b) (%+ (%* y (bm-w b)) x)))

(define (bm-inside? b x y)
  (if (%>= x 0)
      (if (%< x (bm-w b)) (if (%>= y 0) (%< y (bm-h b)) nil) nil)
      nil))

;; A pixel with the processor. Both wait for this task's blits first, because
;; the blitter may still be about to write the same pixels. Code that plots
;; many pixels should call `blit-sync` once and store through `bm-at`.
(define (bm-plot b x y c)
  (blit-sync)
  (if (bm-inside? b x y) (poke8 (bm-at b x y) c) nil))

(define (bm-point b x y)
  (blit-sync)
  (if (bm-inside? b x y) (peek8 (bm-at b x y)) 0))

;; ---------------------------------------------------------------- blitter
;; Every task blits, dozens of times a frame, so the blitter belongs to the
;; kernel like `sys` and the timer: never claimed, reached only through the
;; functions below. The chip has parameter registers too, but programming
;; through them takes six stores that something would have to hold off, and
;; descriptors exist to avoid that. Three registers are named here and none
;; is exported; the only way onto the chain is `blit-go`.
(define *blit* (make-device "blit" dev-blit 'kernel))
(define blt-list (dev-reg *blit* blit-list-reg))
(define blt-status (dev-reg *blit* blit-status-reg))
(define blt-ctrl (dev-reg *blit* blit-ctrl-reg))

;; ---------------------------------------------------------------- descriptors
;; A blit is a descriptor in memory: the parameters, a status word the chip
;; clears when it has finished, and a link to the next descriptor. The chip
;; walks the links itself, so a queue of blits is a chain in memory and
;; adding one is a store into the last one's link.
;;
;; A descriptor belongs to whoever is filling it. Every task has a ring of
;; eight, swapped in by the scheduler with its other bindings, so two
;; contexts are never half way through the same one. A ring rather than one:
;; the chip reads a descriptor when it reaches it, so one cannot be refilled
;; until the chip has finished it, and a task with one descriptor would wait
;; for each blit before starting the next.
(define blit-ring-size 8)
(define *blit-ring* 0)      ; the running task's, swapped in with its bindings
(define *gc-blit-ring* 0)   ; and one the collector owns outright
(define *blit-tail* 0)      ; the last descriptor put on the chain, anybody's
(define *in-interrupt* nil) ; set by the trap handler, cleared before it returns

;; A ring is a word saying which descriptor is next, then the descriptors.
(define (ring-slot r i) (%+ r (%+ 8 (%* i blit-list-size))))

;; Every status cleared: pool memory is not zeroed, and a descriptor that read
;; as pending before it was ever used would wait for a write-back that never
;; comes.
(define (new-blit-ring)
  (let ((r (alloc-pool (%+ 8 (%* blit-ring-size blit-list-size))))
        (i 0))
    (%st-fixnum! r 0)
    (while (%< i blit-ring-size)
      (let ((d (ring-slot r i)))
        (%st-fixnum! (%+ d bl-status) 0)
        (%st-fixnum! (%+ d bl-next) 0))
      (set! i (%+ i 1)))
    r))

;; The ring's next descriptor, once the chip has finished with it.
(define (ring-take r)
  (let* ((i (%ld-fixnum r))
         (d (ring-slot r i)))
    (blit-wait-descriptor d)
    (%st-fixnum! r (if (%= (%+ i 1) blit-ring-size) 0 (%+ i 1)))
    d))

;; A descriptor from the running task's ring. Not in an interrupt server: a
;; server runs with the world half saved, must not allocate or block, and
;; anything it draws is drawn over by the next task that composites. A server
;; that wants pixels signals a task.
(define (blit-descriptor)
  (if *in-interrupt*
      (error "the blitter is task context only: signal a task instead")
      nil)
  (if (%= *blit-ring* 0) (set! *blit-ring* (new-blit-ring)) nil)
  (ring-take *blit-ring*))

;; The collector's own ring. Not a fluid binding: a collection runs with
;; interrupts off from end to end, so there is never a second one.
(define (gc-blit-descriptor)
  (if (%= *gc-blit-ring* 0) (set! *gc-blit-ring* (new-blit-ring)) nil)
  (ring-take *gc-blit-ring*))

;; ---------------------------------------------------------------- waiting
;; A blit takes time and `blit-go` returns before it has happened. Two
;; questions follow. Is the chip idle? That is `blit-drain`, which almost
;; nothing needs, since a commit goes on the chain whether the chip is busy or
;; not. Have my pixels landed? That is `blit-sync`, which waits on this task's
;; own descriptors and never behind other tasks' transfers. Before touching
;; pixels with the processor, `blit-sync`: reading too early shows the old
;; picture.

(define (blit-busy?) (%= 1 (%logand (%ld-fixnum blt-status) 1)))

;; Reading the status register is what lets a finished transfer be noticed,
;; so this spin also drives completion. Preemptible.
(define (blit-drain)
  (while (blit-busy?) nil)
  nil)

(define (blit-done? d) (%= 0 (%ld-fixnum (%+ d bl-status))))

;; How a task whose blit has not landed goes to sleep instead of spinning.
;; gfx.driver installs it, since the driver owns the completion interrupt.
;; Where sleeping is impossible, in an interrupt server or with interrupts
;; off, waiting is a spin on the status register.
(define *blit-sleep* nil)
(define (set-blit-sleep! fn) (set! *blit-sleep* fn) nil)

(define (interrupts-on?)
  (let ((s (%disable)))
    (%restore-interrupts s)
    (%= s 1)))

;; Ask the chip for an interrupt after every descriptor, not only at the end
;; of the chain, while anybody is asleep waiting for one.
(define (blit-irq-each! on) (%st-fixnum! blt-ctrl (if on 2 0)))

;; A short spin first: most blits are small and done before a sleep could be
;; arranged.
(define (blit-wait-descriptor b)
  (if (if (%= b 0) t (blit-done? b))
      nil
      (let ((n 0))
        (while (if (blit-done? b) nil (%< n 64))
          (blit-busy?)
          (set! n (%+ n 1)))
        (if (blit-done? b)
            nil
            (if (if *blit-sleep* (if *in-interrupt* nil (interrupts-on?)) nil)
                (%funcall *blit-sleep* b)
                (while (if (blit-done? b) nil t) (blit-busy?))))))
  nil)

;; Every descriptor in a ring. The chain runs in order, so this is the same as
;; waiting for the last one issued.
(define (blit-wait-ring r)
  (if (%= r 0)
      nil
      (let ((i 0))
        (while (%< i blit-ring-size)
          (blit-wait-descriptor (ring-slot r i))
          (set! i (%+ i 1)))))
  nil)

(define (blit-sync) (blit-wait-ring *blit-ring*))

;; Put a filled descriptor on the chain and return. The chip reads a
;; descriptor's link when it finishes that descriptor, so a link written onto
;; a tail it has already finished is never seen. Hence the order: link only
;; while the chip is busy, then look again, and start the chip from here if it
;; went idle without taking this one. The fields go in before the section:
;; the descriptor is this task's and on no chain yet.
(define (blit-go d op)
  (%st-fixnum! (%+ d bl-op) op)
  (%st-fixnum! (%+ d bl-next) 0)
  (%st-fixnum! (%+ d bl-status) 1)
  (without-interrupts
    (let ((linked (if (if (%> *blit-tail* 0) (blit-busy?) nil)
                      (begin (%st-fixnum! (%+ *blit-tail* bl-next) d) t)
                      nil)))
      (set! *blit-tail* d)
      (if (if linked (blit-busy?) nil)
          nil
          (if (%= 1 (%ld-fixnum (%+ d bl-status)))
              (%st-fixnum! blt-list d)
              nil))))
  nil)

;; ---------------------------------------------------------------- rectangles
;; Clipped in place to the bitmap, with no list made to be taken apart again:
;; this is the innermost step of every rectangle, circle and glyph.
(define (bm-fill-rect bmp x y w h c)
  (let* ((bw (bm-w bmp))
         (bh (bm-h bmp))
         (x0 (if (%< x 0) 0 x))
         (y0 (if (%< y 0) 0 y))
         (x1 (let ((e (%+ x w))) (if (%> e bw) bw e)))
         (y1 (let ((e (%+ y h))) (if (%> e bh) bh e))))
    (if (if (%< x0 x1) (%< y0 y1) nil)
        (let ((b (blit-descriptor)))
          (poke (%+ b bl-dst) (bm-at bmp x0 y0))
          (poke (%+ b bl-w) (%- x1 x0))
          (poke (%+ b bl-h) (%- y1 y0))
          (poke (%+ b bl-dmod) bw)
          (poke (%+ b bl-val) c)
          (blit-go b op-fill))
        nil)))

;; Clipped against both ends: the source rectangle and the destination have
;; to fit, and the smaller wins. Source and destination may be one bitmap,
;; which is a scroll, or two, which is compositing.
(define (bm-blit-rect src dst sx sy dx dy w h)
  (let* ((sw (bm-w src))
         (sh (bm-h src))
         (sx0 (if (%< sx 0) 0 sx))
         (sy0 (if (%< sy 0) 0 sy))
         (sx1 (let ((e (%+ sx w))) (if (%> e sw) sw e)))
         (sy1 (let ((e (%+ sy h))) (if (%> e sh) sh e))))
    (if (if (%< sx0 sx1) (%< sy0 sy1) nil)
        (let* ((dw (bm-w dst))
               (dh (bm-h dst))
               (dx0 (if (%< dx 0) 0 dx))
               (dy0 (if (%< dy 0) 0 dy))
               (dx1 (let ((e (%+ dx (%- sx1 sx0)))) (if (%> e dw) dw e)))
               (dy1 (let ((e (%+ dy (%- sy1 sy0)))) (if (%> e dh) dh e))))
          (if (if (%< dx0 dx1) (%< dy0 dy1) nil)
              (let ((b (blit-descriptor)))
                (poke (%+ b bl-src) (bm-at src sx0 sy0))
                (poke (%+ b bl-dst) (bm-at dst dx0 dy0))
                (poke (%+ b bl-w) (%- dx1 dx0))
                (poke (%+ b bl-h) (%- dy1 dy0))
                (poke (%+ b bl-smod) sw)
                (poke (%+ b bl-dmod) dw)
                (blit-go b op-copy))
              nil))
        nil)))

;; ---------------------------------------------------------------- regions
;; A region is a list of rectangles that do not overlap. A window may draw
;; into its own rectangle less the rectangles of every window in front of
;; it, and subtracting one rectangle from another is the only operation that
;; needs.
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
;; what is left to the left and right of the hole between them.
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
;; Where drawing goes: a bitmap, an origin to shift by, and the region of the
;; bitmap it may touch. Every drawing call takes one. A rastport belongs to a
;; window, so anybody holding the window is clipped to it, and two tasks
;; drawing into two bitmaps cannot reach each other.
(defrecord (rastport rp) bitmap origin-x origin-y region)

(define *screen-rp* nil)

(define (make-rastport-on bmp ox oy clip)
  (let ((r (rp-alloc)))
    (set-rp-bitmap! r bmp)
    (set-rp-origin-x! r ox)
    (set-rp-origin-y! r oy)
    (set-rp-region! r clip)
    r))

;; A whole bitmap: no origin, and nothing to clip against but its edges.
(define (make-bitmap-rastport bmp)
  (make-rastport-on bmp 0 0 (list (rect 0 0 (bm-w bmp) (bm-h bmp)))))

;; The screen as a rastport. It carries the screen's size, so `attach-screen`
;; makes a fresh one after a resize.
(define (screen-rastport)
  (if *screen-rp*
      *screen-rp*
      (begin (set! *screen-rp* (make-bitmap-rastport *screen*))
             *screen-rp*)))

(define (set-rp-origin! r x y)
  (set-rp-origin-x! r x)
  (set-rp-origin-y! r y))

;; A colour is a byte, checked wherever one comes in; `nil` means no colour
;; where that is allowed.
(define (check-colour c)
  (if (%fixnum? c)
      (if (%>= c 0) (if (%< c 256) c (bad-colour c)) (bad-colour c))
      (bad-colour c)))

(define (bad-colour c) (error "not a colour" c))

;; ---------------------------------------------------------------- drawing
;; The primitives everything else is built out of. Each shifts by the
;; rastport's origin and is cut to its region in place, and every circle,
;; glyph and line above them inherits that.
(define (fill-rect rp x y w h c)
  (let* ((x0 (%+ x (rp-origin-x rp)))
         (y0 (%+ y (rp-origin-y rp)))
         (x1 (%+ x0 w))
         (y1 (%+ y0 h))
         (bmp (rp-bitmap rp)))
    (dolist (cr (rp-region rp))
      (let ((ix0 (if (%> x0 (rect-x cr)) x0 (rect-x cr)))
            (iy0 (if (%> y0 (rect-y cr)) y0 (rect-y cr)))
            (ix1 (if (%< x1 (rect-x2 cr)) x1 (rect-x2 cr)))
            (iy1 (if (%< y1 (rect-y2 cr)) y1 (rect-y2 cr))))
        (if (if (%< ix0 ix1) (%< iy0 iy1) nil)
            (bm-fill-rect bmp ix0 iy0 (%- ix1 ix0) (%- iy1 iy0) c)
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
;; the region. The source is not: whatever is on top of it is what a scroll
;; should carry along.
(define (blit-rect rp sx sy dx dy w h)
  (let* ((ox (rp-origin-x rp))
         (oy (rp-origin-y rp))
         (x0 (%+ dx ox))
         (y0 (%+ dy oy))
         (x1 (%+ x0 w))
         (y1 (%+ y0 h))
         (bmp (rp-bitmap rp)))
    (dolist (cr (rp-region rp))
      (let ((ix0 (if (%> x0 (rect-x cr)) x0 (rect-x cr)))
            (iy0 (if (%> y0 (rect-y cr)) y0 (rect-y cr)))
            (ix1 (if (%< x1 (rect-x2 cr)) x1 (rect-x2 cr)))
            (iy1 (if (%< y1 (rect-y2 cr)) y1 (rect-y2 cr))))
        (if (if (%< ix0 ix1) (%< iy0 iy1) nil)
            (bm-blit-rect bmp bmp
                          (%+ (%+ sx ox) (%- ix0 x0))
                          (%+ (%+ sy oy) (%- iy0 y0))
                          ix0 iy0 (%- ix1 ix0) (%- iy1 iy0))
            nil))))
  nil)

;; Endpoints are clamped to the bitmap rather than clipped, so a line that
;; leaves it changes slope at the edge. It is not cut to the region.
(define (draw-line rp x0 y0 x1 y1 c)
  (let* ((bmp (rp-bitmap rp))
         (bw (bm-w bmp))
         (bh (bm-h bmp))
         (ox (rp-origin-x rp))
         (oy (rp-origin-y rp)))
  (set! x0 (clamp (%+ x0 ox) 0 (%- bw 1)))
  (set! x1 (clamp (%+ x1 ox) 0 (%- bw 1)))
  (set! y0 (clamp (%+ y0 oy) 0 (%- bh 1)))
  (set! y1 (clamp (%+ y1 oy) 0 (%- bh 1)))
  (let ((b (blit-descriptor)))
    (poke (%+ b bl-dst) (bm-addr bmp))
    (poke (%+ b bl-dmod) bw)
    (poke (%+ b bl-x0) x0)
    (poke (%+ b bl-y0) y0)
    (poke (%+ b bl-x1) x1)
    (poke (%+ b bl-y1) y1)
    (poke (%+ b bl-val) c)
    (blit-go b op-line))))

;; A filled circle, one scanline at a time: two device pokes a row.
(define (fill-circle rp cx cy r c)
  (let ((dy (%- 0 r)))
    (while (%<= dy r)
      (let ((w (isqrt (%- (%* r r) (%* dy dy)))))
        (fill-rect rp (%- cx w) (%+ cy dy) (%+ (%* 2 w) 1) 1 c))
      (set! dy (%+ dy 1)))
    nil))

;; The outline: the leftmost and rightmost pixel of each row, plus the caps
;; where the rows run out.
(define (draw-circle rp cx cy r c)
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

;; ---------------------------------------------------------------- input
;; The keyboard and mouse. Events wait in a queue in the chip, one word each,
;; with the kind in bits 31..28. A key has ascii in 27..20 and the raw key
;; code in 19..12; a pointer event has y in 27..16, x in 15..4 and the button
;; in 3..0; the wheel has its step in 11..0. Reading the event register takes
;; one off the queue. input.driver owns this (see input.lisp); until it has
;; claimed the device, whoever holds it may use it.
(define *input* (make-device "input" dev-input nil))

;; The next event as (kind hi lo): the kind, and the word's two halves for
;; whoever knows how that kind is laid out; or nil when the queue is empty.
;; Read once, because reading takes the event, and into the scratch cell,
;; because a button event has bit 30 set.
(define (input-take)
  (let ((r (dev-reg *input* inp-event)) (hi 0) (lo 0))
    (without-interrupts
      (%st-word! peek-scratch (%ld-word r))
      (set! lo (%ld-half peek-scratch))
      (set! hi (%ld-half (%+ peek-scratch 2))))
    (if (if (%= hi 0) (%= lo 0) nil)
        nil
        (list (%lsh hi -12) hi lo))))

;; The same word the other way, into the loopback register: an event as
;; though the keyboard had sent it.
(define (input-inject kind ascii code payload)
  (let ((r (dev-reg *input* inp-inject))
        (hi (%logior (%lsh kind 12) (%logior (%lsh ascii 4) (%lsh code -4))))
        (lo (%logior (%lsh (%logand code 15) 12) payload)))
    (without-interrupts
      (%st-half! peek-scratch lo)
      (%st-half! (%+ peek-scratch 2) hi)
      (%st-word! r (%ld-word peek-scratch))))
  nil)

(define (input-interrupts! on) (poke (dev-reg *input* inp-ctrl) (if on 1 0)))
(define (input-mouse-x) (%ld-fixnum (dev-reg *input* inp-mousex)))
(define (input-mouse-y) (%ld-fixnum (dev-reg *input* inp-mousey)))
(define (input-buttons) (%ld-fixnum (dev-reg *input* inp-buttons)))
(define (input-mods) (%ld-fixnum (dev-reg *input* inp-mods)))

;; ---------------------------------------------------------------- serial
;; The serial line. Its registers are reached raw from runtime.lisp by
;; whatever has to report when nothing else can be trusted, and that path is
;; unchecked on purpose. This record is for the other path: console.driver
;; claims it, which says which task is reading the line.
(define *serial* (make-device "serial" dev-uart nil))

;; Whether the chip raises its line when a byte arrives.
(define (serial-interrupts! on) (%st-fixnum! uart-ctrl (if on 1 0)))

;; ---------------------------------------------------------------- storage
;; The disk controller. A command runs on its own time: `disk-go` programs it
;; and returns at once, the status reads `disk-busy` for as long as the
;; transfer takes, and then it reads the result: 0 ok, 1 no disk attached,
;; 2 the range is not in memory, 3 the host's I/O failed. With bit 0 of the
;; control register set, the controller raises `int-disk` when it finishes.
;; disk.driver owns it (see disk.lisp); until the driver has claimed it,
;; whoever holds it may use it.
(define *disk* (make-device "disk" dev-disk nil))

;; The command goes last: the controller latches the other three when it
;; arrives, so they can be rewritten for the next command while this one runs.
(define (disk-go cmd addr block n)
  (let ((base (dev-reg *disk* 0)))
    (without-interrupts
      (poke (%+ base dsk-addr) addr)
      (poke (%+ base dsk-block) block)
      (poke (%+ base dsk-count) n)
      (poke (%+ base dsk-cmd) cmd)))
  nil)

;; One load and no allocation: a status is a small number, read in a loop
;; with interrupts off.
(define (disk-status) (%ld-fixnum (dev-reg *disk* dsk-status)))
(define (disk-busy?) (%= (disk-status) disk-busy))
(define (disk-blocks) (peek (dev-reg *disk* dsk-blocks)))
(define (disk-interrupts! on) (poke (dev-reg *disk* dsk-ctrl) (if on 1 0)))

;; ---------------------------------------------------------------- pool
;; Raw memory the collector never touches and nothing moves: task contexts,
;; stacks and descriptor rings. Every block carries an eight byte header, its
;; total size and then a tag, and the free blocks are threaded on one list in
;; address order, so coalescing is a comparison against the neighbour. First
;; fit, split when the remainder is worth having.
;;
;; What the forge handed out before the machine ran, the trap frames, the
;; trap stack and the boot stack, has no header and is never freed. It sits
;; below the bump pointer this allocator starts from, and the tag is what
;; tells anyone who tries to free one that they have made a mistake.
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

;; A fresh block off the top, when nothing on the free list fits.
(define (pool-extend need)
  (let ((p (%ld-fixnum lg-poolptr)))
    (if (%> (%+ p need) (%ld-fixnum lg-poolend))
        (out-of-memory "exec pool")
        nil)
    (%st-fixnum! lg-poolptr (%+ p need))
    p))

;; Hand out the front of a free block and put any worthwhile remainder back
;; in its place on the list.
(define (pool-take b prev need)
  (let ((size (pool-size b))
        (next (pool-next b)))
    (if (%>= (%- size need) pool-min)
        (let ((rest (%+ b need)))
          (pool-set-size! rest (%- size need))
          (pool-set-next! rest next)
          (pool-set-size! b need)
          (if prev (pool-set-next! prev rest) (%st-fixnum! lg-pool-free rest)))
        (if prev (pool-set-next! prev next) (%st-fixnum! lg-pool-free next)))
    b))

;; Finding a block and claiming it is one act. Clearing it is not: once the
;; block is claimed it belongs to this caller, and zeroing a large block with
;; interrupts off would stall the machine.
(define (alloc-pool nbytes)
  (let ((b (claim-pool nbytes)))
    (pool-zero (%+ b 8) (%- (pool-size b) 8))
    (%+ b 8)))

(define (claim-pool nbytes)
  (without-interrupts
  (let* ((need (let ((n (%logand (%+ (%+ nbytes 8) 7) -8)))
                 (if (%< n pool-min) pool-min n)))
         (b (let ((p (%ld-fixnum lg-pool-free)) (prev nil) (found nil))
              (while (if found nil (%> p 0))
                (if (%>= (pool-size p) need)
                    (set! found (pool-take p prev need))
                    (begin (set! prev p) (set! p (pool-next p)))))
              (if found found (let ((n (pool-extend need)))
                                (pool-set-size! n need)
                                n)))))
    (%st-fixnum! (%+ b 4) pool-tag)
    b)))

;; Insert in address order, joining up with either neighbour that touches.
(define (free-pool p)
  (let ((b (%- p 8)))
    (if (%= (%ld-fixnum (%+ b 4)) pool-tag)
        nil
        (error "free-pool: not an allocated block" p))
    (without-interrupts
      (let ((size (pool-size b))
            (prev nil)
            (q (%ld-fixnum lg-pool-free)))
        (while (if (%> q 0) (%< q b) nil)
          (set! prev q)
          (set! q (pool-next q)))
        ;; forward: absorb the next block if it starts where this one ends
        (if (if (%> q 0) (%= (%+ b size) q) nil)
            (begin (set! size (%+ size (pool-size q))) (set! q (pool-next q)))
            nil)
        (pool-set-size! b size)
        (pool-set-next! b q)
        ;; backward: if the previous block runs up to this one, the two become
        ;; one and this header disappears
        (if (if prev (%= (%+ prev (pool-size prev)) b) nil)
            (begin
              (pool-set-size! prev (%+ (pool-size prev) size))
              (pool-set-next! prev q))
            (if prev
                (pool-set-next! prev b)
                (%st-fixnum! lg-pool-free b)))
        nil))))

(define (pool-used) (%- (%ld-fixnum lg-poolptr) pool-base))

(define (pool-free-bytes)
  (let ((p (%ld-fixnum lg-pool-free)) (n 0))
    (while (%> p 0)
      (set! n (%+ n (pool-size p)))
      (set! p (pool-next p)))
    n))
