;;; hw.lisp - the custom chips.
;;;
;;; Every device is a 4 KiB page of naturally aligned 32-bit registers, but for
;;; the blitter's list register, the disk's buffer register and the display's
;;; scan-out register, which take a capability: the chips that reach memory
;;; are handed capabilities and refuse what those do not cover. A register is
;;; an offset into its device's page (generated into layout.lisp from the
;;; Rust side), and the only way to the registers is a capability bounded
;;; exactly to the page, so a register offset that leaves the page is a
;;; bounds fault and never a store into the next device.
;;;
;;; A page is the authority over its device, and it stays in the kernel's
;;; hands. What everything else holds is a device: the page sealed with
;;; `otype-device`, which anyone may hold and pass, and which nothing but the
;;; accessors generated into devices.lisp opens. Each accessor opens it for
;;; the one device it was written for and traps on any other, so a safe
;;; accessor only ever touches a register of the device it was written for.
;;; The kernel's own devices, `sys` and the timer, and the raw serial line
;;; are reached through their pages in the kernel block, inside `unsafe`.

(in-package hw)

(defconstant device-page-bytes 4096)

;; ---------------------------------------------------------------- devices
;; A device's page: its 4 KiB, to load and store data, and, for the three
;; chips with a capability register, capabilities as well, since storing
;; them goes with loading them. The reset stub mints every page from the
;; memory map into the kernel block: two loads and no allocation, so the
;; trap handler uses it too. Holding a page is the authority over its
;; device, so taking one is unsafe.
(defsubst (device-page dev) (declare unsafe) (%slot (kernel-ref kb-devices) dev))

;; A device, as everything but the kernel holds one: its page sealed with
;; `otype-device`, one otype for every device, with a key hw mints once and
;; keeps in these two closures and nowhere else, as it keeps the blitter's.
;; `device-open` unseals a device and checks that its page's base is the
;; one asked for, and traps otherwise: the base is the class, which is right
;; while every device has a fixed address, as on this machine. A device
;; whose address could not be known would be sealed as a {class, page} pair
;; instead, and only `device-open` and the accessors' generator would
;; change.
(defconstant otype-device 5)
(define device-seal (declare unsafe))
(define device-open (declare unsafe))
(define (mint-device-key)
  (unsafe
  (let ((key (sealing-key otype-device)))
    (set! device-seal (lambda (page) (%cap-seal page key)))
    (set! device-open
          (lambda (dev base)
            (let ((page (%cap-unseal dev key)))
              (if (if (%cap-tag? page) (%= (%cap-base page) base) nil)
                  page
                  (error "not the device this accessor is for:" dev))))))))

;; Device `dev` of the memory map, sealed: what a driver's start takes.
(define (device dev)
  (declare unsafe)
  (unsafe
  (if device-seal nil (mint-device-key))
  (device-seal (device-page dev))))

;; ---------------------------------------------------------------- words
;; A machine word is a fixnum. `peek` reads the word at an address as a
;; number from -2^31 to 2^31-1 and `poke` stores one back unchanged, both by
;; number through the root. They are the gun in the safe: nothing gets in
;; their way, and nothing but code that says `unsafe` can reach for them.
;; `poke` takes nothing but a fixnum: anything else would store its address,
;; which is never what was meant.
(define (peek a) (declare unsafe) (unsafe (%ld-word a)))

(define (poke a v)
  (declare unsafe)
  (unsafe
  (if (%fixnum? v) (%st-word! a v) (error "poke: not a machine word:" v))
  v))

(define (peek8 a) (declare unsafe) (unsafe (%ld-byte a)))
(define (poke8 a v) (declare unsafe) (unsafe (%st-byte! a v)))

;; ---------------------------------------------------------------- system
;; Thirty-one bits and never negative.
(define (random)
  (unsafe (%logand (%cap-ld-word (device-page dev-sys) sys-random) most-positive-fixnum)))

;; Read-modify-write of the enable register, atomic: a task turning a line
;; back on races the interrupt server that masks it.
(define (int-enable line)
  (unsafe
  (let ((p (device-page dev-sys)))
    (without-interrupts
      (%cap-st-word! p sys-intena (%logior (%cap-ld-word p sys-intena) (%lsh 1 line)))))))
(define (int-disable line)
  (unsafe
  (let ((p (device-page dev-sys)))
    (without-interrupts
      (%cap-st-word! p sys-intena
                     (%logand (%cap-ld-word p sys-intena) (%lognot (%lsh 1 line))))))))
(define (int-ack line) (unsafe (%cap-st-word! (device-page dev-sys) sys-intreq (%lsh 1 line))))
(define (int-raise line) (unsafe (%cap-st-word! (device-page dev-sys) sys-intset (%lsh 1 line))))
;; The lowest pending and enabled line, or -1, which the chip spells as a
;; word of all ones. Runs inside the trap handler and must not allocate.
(define (int-pending) (unsafe (%cap-ld-word (device-page dev-sys) sys-intnum)))

;; The processor started again at the reset vector, as from power-on, with
;; memory as it is: the reset stub mints the memory map and enters the
;; kernel block's top level. Never returns.
(define (reset-processor)
  (declare unsafe)
  (unsafe (%cap-st-word! (device-page dev-sys) sys-reset 1)))

;; ---------------------------------------------------------------- timer
;; The timebase is the retired instruction count, so the same program
;; produces the same schedule on every run.
;; The host's clock, in milliseconds since boot, read as a fixnum: for pacing
;; something to the host, not for deadlines, which exec keeps on the machine's
;; own ticks (`now-ms`). No allocation and no critical section.
(define (millis) (unsafe (%cap-ld-word (device-page dev-timer) tmr-wall)))

;; Cycles per second of the machine's clock.
(define (timer-hz) (unsafe (%cap-ld-word (device-page dev-timer) tmr-freq)))

;; Fire n ticks from now, n a fixnum no smaller than zero. The compare is 64
;; bits: the high half is written first so a wrap cannot leave a compare in
;; the past, and both halves go out inside one section. The low word, read as
;; unsigned, carries into the high one exactly when it was negative and its
;; wrapping sum with n is not. Wrapping fixnum operations throughout, because
;; this runs from the timer interrupt every quantum and must not allocate.
(define (timer-set-in n)
  (unsafe
  (let ((p (device-page dev-timer)))
    (without-interrupts
      (let* ((lo (%cap-ld-word p tmr-lo))
             (sum (%+ lo n))
             (carry (if (%< lo 0) (if (%>= sum 0) 1 0) 0)))
        (%cap-st-word! p tmr-cmphi (%+ (%cap-ld-word p tmr-hi) carry))
        (%cap-st-word! p tmr-cmplo sum))))))

(define (timer-never)
  (unsafe
  (let ((p (device-page dev-timer)))
    (without-interrupts
      (%cap-st-word! p tmr-cmphi -1)
      (%cap-st-word! p tmr-cmplo -1)))))

;; ---------------------------------------------------------------- display
;; The display chip: where the picture comes from, how big it is, the
;; palette, and whether it raises the vertical blank. gfx.driver is what
;; calls these (see gfx.lisp).

;; The size the machine comes up in.
(defconstant screen-width 1024)
(defconstant screen-height 768)

;; ---------------------------------------------------------------- bitmaps
;; A bitmap is a byte object and its two dimensions. The pixels are a
;; capability with LD and SD whose bounds are exactly the pixels, so a bitmap
;; cannot be forged, a store the processor makes outside it is a bounds fault,
;; the collector frees the pixels when the last reference goes, and the
;; extent is checked once at construction so that everything downstream can
;; trust `w` and `h`. The blitter is handed the pixels' capability itself
;; and refuses a rectangle it does not cover, and so is the display chip,
;; which shows nothing it may not read. What either chip holds stays alive:
;; a blit in flight through its descriptor, and the bitmap on show through
;; the scan-out register, which hands its capability back to the collector.
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

;; `make-bytes` zero-fills, so a new bitmap starts black.
(define (alloc-bitmap w h) (make-bitmap (make-bytes (%* w h)) w h))

(define *screen* nil)      ; the bitmap being displayed; gfx.driver sets it

;; Point the display at a bitmap, 8-bit indexed, with the picture and the
;; frame clock on: writing the control register without the interrupt bit
;; would stop the vertical blank. The pixels go to the scan-out register
;; with a capability store, and the chip shows only what they let it read.
(define (gfx-show dev b)
  (gfx-base! dev (bm-pixels b))
  (gfx-width! dev (bm-w b))
  (gfx-height! dev (bm-h b))
  (gfx-pitch! dev (bm-w b))
  (gfx-mode! dev 8)
  (gfx-ctrl! dev (%logior gfx-on gfx-vbirq))
  b)

(define (gfx-vblank-irq! dev on)
  (gfx-ctrl! dev (if on
                     (%logior (gfx-ctrl dev) gfx-vbirq)
                     (%logand (gfx-ctrl dev) (%lognot gfx-vbirq)))))

;; An index register and a data register: two writes that mean one thing.
(define (gfx-colour! dev i c)
  (without-interrupts
    (gfx-palidx! dev i)
    (gfx-paldat! dev c)))

(define (gfx-present! dev) (gfx-sync! dev 1))

(define (rgb r g b)
  (%logior (%lsh (%logand r 255) 16)
           (%logior (%lsh (%logand g 255) 8) (%logand b 255))))

;; Where pixel x, y is: its index in the pixels, for the processor, and the
;; pixels' capability moved to it, for the blitter.
(define (bm-index b x y) (%+ (%* y (bm-w b)) x))
(define (bm-at b x y) (%cap-inc (bm-pixels b) (bm-index b x y)))

(define (bm-inside? b x y)
  (if (%>= x 0)
      (if (%< x (bm-w b)) (if (%>= y 0) (%< y (bm-h b)) nil) nil)
      nil))

;; A pixel with the processor. Both wait for this task's blits first, because
;; the blitter may still be about to write the same pixels. Code that plots
;; many pixels should call `blit-sync` once and store into the pixels at
;; `bm-index`.
(define (bm-plot b x y c)
  (blit-sync)
  (if (bm-inside? b x y) (bytes-set! (bm-pixels b) (bm-index b x y) c) nil))

(define (bm-point b x y)
  (blit-sync)
  (if (bm-inside? b x y) (bytes-ref (bm-pixels b) (bm-index b x y)) 0))

;; ---------------------------------------------------------------- blitter
;; Every task blits, dozens of times a frame, so the blitter belongs to the
;; kernel like `sys` and the timer: no task holds its page, and it is reached
;; only through the functions below. It has three registers, all of them used
;; here: the list register, which takes a capability to a descriptor and
;; starts the chain there, the status and the control. The only way onto the
;; chain is `blit-go`.

;; ---------------------------------------------------------------- descriptors
;; A blit is a descriptor in memory: the capabilities of the source and the
;; destination, the parameters, a done word the chip writes when it has
;; finished, and a capability to the next descriptor. The chip walks the
;; links itself, so a queue of blits is a chain in memory and adding one is a
;; store into the last one's link.
;;
;; The chip checks what it is handed. A source needs LD, a destination SD,
;; and LD too for an operation that reads it, and every byte the rectangle
;; touches, rows and stride, must lie inside the capability. A transfer that
;; fails is not made: its done word says which capability refused it and
;; why, as `blit-refused-src` or `blit-refused-dst` with a `refuse-*` code
;; in the low byte, and the chip's status keeps `blit-status-refused` until
;; it is cleared. The descriptor completes either way, so nothing waits
;; for a blit that will never land.
;;
;; A descriptor belongs to whoever is filling it. Every task has a ring of
;; eight, swapped in by the scheduler with its other bindings, so two
;; contexts are never half way through the same one. A ring rather than one:
;; the chip reads a descriptor when it reaches it, so one cannot be refilled
;; until the chip has finished it, and a task with one descriptor would wait
;; for each blit before starting the next.
(defconstant blit-ring-size 8)
(define *blit-ring* 0)      ; the running task's, swapped in with its bindings, sealed
(define *gc-blit-ring* (declare unsafe) 0)   ; and one the collector owns outright
(define *blit-tail* (declare unsafe) 0)      ; the last descriptor put on the chain, anybody's
(define *in-interrupt* nil) ; set by the trap handler, cleared before it returns

;; Each of those holds its ring or its descriptor sealed, with an otype of
;; the chips', as a sleeper's place on a waiting list does: a binding, a
;; global and a list are anybody's to read, and a capability to a descriptor
;; is authority over what the chip does next. Only the code here opens one,
;; with its key to that otype, which the first ring made mints and these two
;; closures hold, and nothing else. The two closures, the collector's ring
;; and the chain's tail are unsafe names: the code here trusts what they
;; hold. A task's ring is a binding, and a binding anybody may make, so the
;; code here trusts only what unsealing it gives.
(defconstant otype-blit 4)
(define blit-seal (declare unsafe))
(define blit-unseal (declare unsafe))
(define (mint-blit-key)
  (unsafe
  (let ((key (sealing-key otype-blit)))
    (set! blit-seal (lambda (c) (%cap-seal c key)))
    (set! blit-unseal (lambda (c) (%cap-unseal c key))))))

;; A ring is a vector: a slot saying which descriptor is next, then the
;; descriptors, each a run of value slots, a field to a slot, laid out as the
;; chip reads them. A blit the chip has not finished holds the capabilities
;; of its source and destination in its descriptor, so a ring is marked and
;; traced as any vector is, and what a blit in flight reads and writes stays
;; alive while it is in flight. A task's ring is held by its binding; one
;; whose task ends is waited for first (`remove-task` in exec.lisp).
(defconstant blit-ring-slots
  (%+ 1 (%* blit-ring-size (%lsh blit-list-size -3))))

;; A fresh ring holds zero in every slot: the next descriptor is the first,
;; and every done word reads as done, so no descriptor that was never used
;; waits for a write-back that never comes. It is handed out sealed.
(define (new-blit-ring)
  (unsafe
  (if blit-seal nil (mint-blit-key))
  (blit-seal (make-vector blit-ring-slots 0))))

;; Descriptor i of ring r, as the capability it is filled through and handed
;; to the chip as: bounded to the descriptor, with a pair's permissions, so
;; that the chip can load capabilities through it with their tags and write
;; them mutable.
(define (ring-slot r i)
  (%cap-and-perms (%cap-bounds-exact (%cap-inc r (%+ value-bytes (%* i blit-list-size)))
                                     blit-list-size)
                  perms-pair))

;; The ring's next descriptor, once the chip has finished with it.
(define (ring-take r)
  (declare unsafe)
  (let* ((i (%vector-ref r 0))
         (d (ring-slot r i)))
    (unsafe (blit-wait-descriptor d))
    (%vector-set! r 0 (if (%= (%+ i 1) blit-ring-size) 0 (%+ i 1)))
    d))

;; A descriptor from the running task's ring. Not in an interrupt server: a
;; server runs with the world half saved, must not allocate or block, and
;; anything it draws is drawn over by the next task that composites. A server
;; that wants pixels signals a task.
(define (blit-descriptor)
  (declare unsafe)
  (if *in-interrupt*
      (error "the blitter is task context only: signal a task instead")
      nil)
  (unsafe
  (if (%cap-tag? *blit-ring*) nil (set! *blit-ring* (new-blit-ring)))
  (ring-take (blit-unseal *blit-ring*))))

;; The collector's own ring. Not a fluid binding: a collection runs with
;; interrupts off from end to end, so there is never a second one. It is
;; made before a collection that uses it begins, because nothing may be
;; allocated inside one.
(define (ensure-gc-blit-ring)
  (unsafe (if (%cap-tag? *gc-blit-ring*) nil (set! *gc-blit-ring* (new-blit-ring)))))

(define (gc-blit-descriptor)
  (declare unsafe)
  (unsafe (ring-take (blit-unseal *gc-blit-ring*))))

;; ---------------------------------------------------------------- waiting
;; A blit takes time and `blit-go` returns before it has happened. Two
;; questions follow. Is the chip idle? That is `blit-drain`, which almost
;; nothing needs, since a commit goes on the chain whether the chip is busy or
;; not. Have my pixels landed? That is `blit-sync`, which waits on this task's
;; own descriptors and never behind other tasks' transfers. Before touching
;; pixels with the processor, `blit-sync`: reading too early shows the old
;; picture.

;; The blitter is everybody's, so its device is anybody's to hold: the chip
;; checks every capability a descriptor hands it.
(define *blitter* 0)
(define (blitter)
  (if (%cap-tag? *blitter*) nil (set! *blitter* (unsafe (device dev-blit))))
  *blitter*)

(define (blit-busy?)
  (%= blit-status-busy (%logand (blit-status (blitter)) blit-status-busy)))

;; Whether the chip has refused a descriptor, a link or a transfer since the
;; bit was last cleared.
(define (blit-refused?)
  (%= blit-status-refused (%logand (blit-status (blitter)) blit-status-refused)))
(define (blit-clear-refused!) (blit-status! (blitter) blit-status-refused))

;; Reading the status register is what lets a finished transfer be noticed,
;; so this spin also drives completion. Preemptible.
(define (blit-drain)
  (while (blit-busy?) nil)
  nil)

;; Done, whether it landed or was refused: of a descriptor in hand, and of
;; one a sleeper holds sealed.
(define (descriptor-done? d) (if (%= blit-pending (%cap-ld-word d bl-status)) nil t))
(define (blit-done? s) (descriptor-done? (unsafe (blit-unseal s))))

;; How a task whose blit has not landed goes to sleep instead of spinning.
;; gfx.driver installs it, since the driver owns the completion interrupt.
;; Where sleeping is impossible, in an interrupt server or with interrupts
;; off, waiting is a spin on the status register.
(define *blit-sleep* nil)
(define (set-blit-sleep! fn) (set! *blit-sleep* fn) nil)

(define (interrupts-on?)
  (unsafe
  (let ((s (%disable)))
    (%restore-interrupts s)
    (%= s 1))))

;; Ask the chip for an interrupt after every descriptor, not only at the end
;; of the chain, while anybody is asleep waiting for one.
(define (blit-irq-each! on) (blit-ctrl! (blitter) (if on 2 0)))

;; A short spin first: most blits are small and done before a sleep could be
;; arranged. Unsafe, since it seals what it is handed as a descriptor.
(define (blit-wait-descriptor b)
  (declare unsafe)
  (if (descriptor-done? b)
      nil
      (let ((n 0))
        (while (if (descriptor-done? b) nil (%< n 64))
          (blit-busy?)
          (set! n (%+ n 1)))
        (if (descriptor-done? b)
            nil
            (if (if *blit-sleep* (if *in-interrupt* nil (interrupts-on?)) nil)
                (%funcall *blit-sleep* (unsafe (blit-seal b)))
                (while (if (descriptor-done? b) nil t) (blit-busy?))))))
  nil)

;; Every descriptor in a ring, as a binding holds it: sealed, or 0 for a task
;; that has never blitted. The chain runs in order, so this is the same as
;; waiting for the last one issued.
(define (blit-wait-ring s)
  (unsafe
  (if (%cap-tag? s)
      (let ((r (blit-unseal s)) (i 0))
        (while (%< i blit-ring-size)
          (blit-wait-descriptor (ring-slot r i))
          (set! i (%+ i 1))))
      nil))
  nil)

(define (blit-sync) (blit-wait-ring *blit-ring*))

;; Put a filled descriptor on the chain and return. The chip reads a
;; descriptor's link when it finishes that descriptor, so a link written onto
;; a tail it has already finished is never seen. Hence the order: link only
;; while the chip is busy, then look again, and start the chip from here if it
;; went idle without taking this one. The fields go in before the section:
;; the descriptor is this task's and on no chain yet. `d` is the capability
;; `blit-descriptor` handed out, and the link and the list register take it
;; with a capability store.
(define (blit-go d op)
  (declare unsafe)
  (unsafe
  (%cap-st-word! d bl-op op)
  (%cap-st! d bl-next 0)
  (%cap-st-word! d bl-status blit-pending)
  (without-interrupts
    (let ((linked (if (if (%cap-tag? *blit-tail*) (blit-busy?) nil)
                      (begin (%cap-st! (blit-unseal *blit-tail*) bl-next d) t)
                      nil)))
      (set! *blit-tail* (blit-seal d))
      (if (if linked (blit-busy?) nil)
          nil
          (if (%= blit-pending (%cap-ld-word d bl-status))
              (blit-list! (blitter) d)
              nil)))))
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
        (unsafe
        (let ((b (blit-descriptor)))
          (%cap-st! b bl-dst (bm-at bmp x0 y0))
          (%cap-st-word! b bl-w (%- x1 x0))
          (%cap-st-word! b bl-h (%- y1 y0))
          (%cap-st-word! b bl-dmod bw)
          (%cap-st-word! b bl-val c)
          (blit-go b op-fill)))
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
              (unsafe
              (let ((b (blit-descriptor)))
                (%cap-st! b bl-src (bm-at src sx0 sy0))
                (%cap-st! b bl-dst (bm-at dst dx0 dy0))
                (%cap-st-word! b bl-w (%- dx1 dx0))
                (%cap-st-word! b bl-h (%- dy1 dy0))
                (%cap-st-word! b bl-smod sw)
                (%cap-st-word! b bl-dmod dw)
                (blit-go b op-copy)))
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

;; The screen as a rastport. It carries the screen's size, so `gfx:attach-screen`
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
  (unsafe
  (let ((b (blit-descriptor)))
    (%cap-st! b bl-dst (bm-pixels bmp))
    (%cap-st-word! b bl-dmod bw)
    (%cap-st-word! b bl-x0 x0)
    (%cap-st-word! b bl-y0 y0)
    (%cap-st-word! b bl-x1 x1)
    (%cap-st-word! b bl-y1 y1)
    (%cap-st-word! b bl-val c)
    (blit-go b op-line)))))

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
;; one off the queue. input.driver is the one reader (see input.lisp).

;; The next event's word, or nil when the queue is empty. Read once, because
;; reading takes the event.
(define (input-take dev)
  (let ((w (input-event dev)))
    (if (%= w 0) nil w)))

;; The same word the other way, into the loopback register: an event as
;; though the keyboard had sent it. Whoever holds the input device types for
;; the person at the keyboard.
(define (input-type dev kind ascii code payload)
  (input-inject! dev (%logior (%logior (%lsh kind 28) (%lsh ascii 20))
                              (%logior (%lsh code 12) payload)))
  nil)

;; ---------------------------------------------------------------- serial
;; The serial line. Its registers are reached raw from runtime.lisp by
;; whatever has to report when nothing else can be trusted, and that path is
;; unchecked on purpose; console.driver writes and reads through it too.

;; Whether the chip raises its line when a byte arrives. Raw, like the rest of
;; the line's registers: it is turned on by whoever starts console.driver and
;; off when the driver ends.
(define (serial-interrupts! on) (unsafe (%cap-st-word! (uart-page) uart-ctrl-reg (if on 1 0))))

;; ---------------------------------------------------------------- storage
;; The disk controller. A command runs on its own time: `disk-go` programs it
;; and returns at once, the status reads `disk-busy` for as long as the
;; transfer takes, and then it reads the result: 0 ok, 1 no disk attached,
;; `disk-refused` when the buffer does not allow the transfer, 3 the host's
;; I/O failed. With bit 0 of the control register set, the controller raises
;; `int-disk` when it finishes. Whoever holds the disk device reaches every
;; block, the image's among them: it is as much as a file system.

;; The command goes last: the controller latches the other three when it
;; arrives, so they can be rewritten for the next command while this one runs.
;; The buffer is a capability, written to the buffer register with a
;; capability store, and the controller moves only what it covers: a read
;; into it needs SD, a write out of it LD, and every byte of the n blocks
;; inside its bounds. A flush takes no buffer.
(define (disk-go dev cmd buf block n)
  (without-interrupts
    (disk-buf! dev buf)
    (disk-block! dev block)
    (disk-count! dev n)
    (disk-cmd! dev cmd))
  nil)

;; A status is a small number, read in a loop with interrupts off.
(define (disk-busy? dev) (%= (disk-status dev) disk-busy))
