;;; hw.lisp - the custom chips.
;;;
;;; Every device is a 4 KiB page of naturally aligned 32-bit registers. There
;;; is no MMU and no privileged mode, and there will not be one: what keeps a
;;; task off a device it does not own is that it cannot name one. A device is
;;; a value, a register is an offset into it, and the only way to turn the two
;;; into an address is `dev-reg`, below.

(in-package hw)

(define (dev-addr dev reg) (%+ mmio-base (%+ (%lsh dev 12) reg)))

;; ---------------------------------------------------------------- devices
;; A device is a value, and holding it is the permission to use it.
;;
;; Register names are offsets into a device's page, not addresses. The base
;; lives only in the device record, so an offset on its own names nothing: the
;; only way to reach a register is `dev-reg`, and the only way to call that is
;; to hold the device. That is the whole of the enforcement - it is scoping,
;; the same way a bitmap is protected by being a value rather than an address.
;;
;; A device's owner is one of three things:
;;
;;   kernel   Exec's: `sys` and `timer`. Never claimed, and not checked
;;            against the running task, because there is no task to check it
;;            against - Exec runs inside whatever task called it, or inside
;;            the trap handler with the interrupted task still in s2. These
;;            are reached only through the functions in this file, and the
;;            device values are not exported.
;;   nil      A driver's device that no driver has claimed yet. Usable by
;;            whoever holds it, which is how code written before its driver
;;            existed keeps working until the driver arrives.
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

;; The devices some task holds right now. A task that dies gives back exactly
;; these - which a list of the machine's own devices would not cover, since a
;; device can be made on the spot.
(define *claimed* nil)

(define (claim-device d) (claim-device-for d (%this-task)))

;; On another task's behalf. A driver's device is claimed for it before it
;; first runs, so that by the time anybody can reach its port it holds the
;; device - there is no moment at which the driver exists and the device is
;; still anybody's.
;;
;; The error is raised outside the critical section: an error abandons the
;; stack, and would abandon the section with it.
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
;; Offsets into the page, not addresses; `*sys*` is the page.
(define *sys* (make-device "sys" dev-sys 'kernel))
(define sys-halt #x00)
(define sys-debug #x04)
(define sys-intreq #x08)
(define sys-intena #x0c)
(define sys-intnum #x10)
(define sys-cyclo #x14)
(define sys-cychi #x18)
(define sys-random #x1c)
(define sys-ramsize #x20)
(define sys-chipsize #x24)
(define sys-intset #x28)

(define (halt code) (%halt code))
;; Thirty bits and never negative, so it stays a fixnum and `(mod (random) n)`
;; is fixnum arithmetic. The register is a full word; taking all of it would
;; hand back a bignum half the time.
(define (random) (%logand (%ld-fixnum (dev-reg *sys* sys-random)) 1073741823))
(define (int-enable line)
  (let ((r (dev-reg *sys* sys-intena)))
    (poke r (%logior (peek r) (%lsh 1 line)))))
(define (int-disable line)
  (let ((r (dev-reg *sys* sys-intena)))
    (poke r (%logand (peek r) (%lognot (%lsh 1 line))))))
(define (int-ack line) (poke (dev-reg *sys* sys-intreq) (%lsh 1 line)))
(define (int-raise line) (poke (dev-reg *sys* sys-intset) (%lsh 1 line)))
;; The line number, or -1 when nothing is pending - which the chip spells as
;; a word of all ones. The raw load rather than `peek-signed`: a line number
;; is five bits and the sentinel is the one value where the two readings
;; differ, so the one-instruction form says exactly what is meant and cannot
;; allocate. This runs inside the trap handler.
(define (int-pending) (%ld-fixnum (dev-reg *sys* sys-intnum)))

;; ---------------------------------------------------------------- timer
(define *timer* (make-device "timer" dev-timer 'kernel))
(define tmr-lo #x00)
(define tmr-hi #x04)
(define tmr-cmplo #x08)
(define tmr-cmphi #x0c)
(define tmr-freq #x10)
(define tmr-wall #x14)

;; The timebase is the retired instruction count, so the clock is exact and
;; the same program produces the same schedule on every run.
(define (timer-now-low) (peek (dev-reg *timer* tmr-lo)))
(define (timer-freq) (peek (dev-reg *timer* tmr-freq)))
(define (millis) (peek (dev-reg *timer* tmr-wall)))

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
    (%st-word! peek-scratch (%ld-word (dev-reg *timer* tmr-lo)))
    (let* ((l0 (%ld-half peek-scratch))
           (l1 (%ld-half (%+ peek-scratch 2)))
           (s0 (%+ l0 (%logand n 65535)))
           (s1 (%+ (%+ l1 (%lsh n -16)) (%lsh s0 -16))))
      ;; the high half first, so a wrap cannot leave a compare in the past
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
;; A driver that dies must not take its peripheral with it: the next one could
;; never claim it.
(define (release-devices-of task)
  (without-interrupts
    (let ((keep nil))
      (dolist (d *claimed*)
        (if (%eq? (dv-owner d) task)
            (set-dv-owner! d nil)
            (set! keep (%cons d keep))))
      (set! *claimed* keep)))
  nil)

;; After a resume, Exec is rebuilt from nothing and every task that owned a
;; device is gone, so every claim the image remembers is a claim nobody holds.
(define (release-all-devices)
  (without-interrupts
    (dolist (d *claimed*) (set-dv-owner! d nil))
    (set! *claimed* nil))
  nil)

;; ---------------------------------------------------------------- display
;; The display chip: where the picture comes from, how big it is, the palette,
;; and whether it raises the vertical blank. gfx.driver owns it - see gfx.lisp
;; - and everybody else asks the driver. Until the driver has claimed it,
;; whoever holds it may use it.
(define *gfx* (make-device "gfx" dev-gfx nil))
(define gfx-base #x00)
(define gfx-width #x04)
(define gfx-height #x08)
(define gfx-pitch #x0c)
(define gfx-mode #x10)
(define gfx-palidx #x14)
(define gfx-paldat #x18)
(define gfx-ctrl #x1c)
(define gfx-vcount #x20)
(define gfx-sync #x24)
(define gfx-hz #x30)

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
;; The pixels are a byte object and the bitmap holds *the object*, not an
;; address. That is worth more than it looks:
;;
;; - **They are no longer in the pool.** A bitmap used to be `alloc-pool`
;;   memory, with task control blocks, stacks and blitter command blocks
;;   allocated either side of it - which is why a rectangle that ran off the
;;   end did not merely look wrong, it wrote over the scheduler. In object
;;   space the worst an overrun reaches is another object, and the collector
;;   notices a damaged header.
;;
;; - **The collector frees them.** `window-close` used to hand the pixels back
;;   with `free-pool` while the compositor might still be reading them. Now the
;;   bitmap stays alive exactly as long as somebody holds it, which is the
;;   whole answer rather than a smaller window to be wrong in.
;;
;; - **The extent is knowable.** A byte object carries its length in its
;;   header, so the size of a bitmap is a property of the bitmap and cannot
;;   disagree with the `w` and `h` beside it. `make-bitmap` checks that once,
;;   and everything downstream can trust it.
;;
;; - **One cannot be forged.** The constructor used to take a raw address, so
;;   `(make-bitmap 0 9999 9999)` was a legal call that authorised writing over
;;   the whole machine. There is no way to say that now: the only way to get a
;;   bitmap is to allocate one.
;;
;; None of this would work if objects moved. They do not - this collector
;; compacts pairs and sweeps objects in place - so an address taken out of a
;; byte object is good for ever, which is what lets one be handed to the
;; display register and to the blitter.
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

;; Where the pixels are. Raw, and deliberately the only place that says so:
;; below here it is an address in a command block, above here it is a value
;; the collector keeps alive.
(defsubst (bm-addr b) (%addr-of (bm-pixels b)))

;; `make-bytes` zero-fills, so a new window starts black rather than showing
;; whatever the pool last had in it.
(define (alloc-bitmap w h) (make-bitmap (make-bytes (%* w h)) w h))

(define *screen* nil)      ; the bitmap being displayed; gfx.driver sets it

;; Point the chip at a bitmap, 8-bit indexed, and turn the picture on - and
;; the frame clock with it, since writing the control register without that
;; bit would quietly stop the vertical blank.
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

;; Both wait for this task's own blits first: the processor is about to
;; touch pixels the blitter may still be about to write.
(define (bm-plot b x y c)
  (blit-sync)
  (if (bm-inside? b x y) (poke8 (bm-at b x y) c) nil))

(define (bm-point b x y)
  (blit-sync)
  (if (bm-inside? b x y) (peek8 (bm-at b x y)) 0))

(define (screen-plot x y c) (bm-plot *screen* x y c))
(define (point x y) (bm-point *screen* x y))

;; ---------------------------------------------------------------- blitter
;; The one register worth naming: the address of a command block. The chip
;; has a full set of parameter registers too, and programming through them
;; takes six stores that something has to hold off - which is what the block
;; exists to avoid, so nothing here reaches for them.
(define blt-list (dev-addr dev-blit blit-list-reg))
(define blt-status (dev-addr dev-blit blit-status-reg))
(define blt-ctrl (dev-addr dev-blit blit-ctrl-reg))

;; ---------------------------------------------------------------- commands
;; A blit is a descriptor in memory: the parameters, a status word the chip
;; clears when it has finished, and a link to the next descriptor. The chip
;; walks the links by itself, so a queue of blits is a chain in memory, and
;; putting one more on it is a store into the last one's link - no waiting for
;; the chip, and no processor involved in getting from one blit to the next.
;;
;; A descriptor belongs to whoever is filling it. A shared one would have
;; exactly the race the registers had: an interrupt server that blits inside a
;; task's setup would overwrite the half the task had written, and the task
;; would then commit a coherent command made of both. So every task has
;; descriptors of its own, swapped in by the scheduler the way `*out*` and the
;; current package are. Two contexts are never half way through the same one.
;;
;; A ring of them, not one. The chip reads a descriptor when it reaches it
;; rather than when it is committed, so a descriptor cannot be refilled until
;; the chip has finished it - and a task with only one would wait for each blit
;; before starting the next, which is the synchronous chip back again. Eight go
;; round, and a task waits only when it has eight in flight.
(define blit-ring-size 8)
(define *blit-ring* 0)      ; the running task's, swapped in with its bindings
(define *gc-blit-ring* 0)   ; and one the collector owns outright
(define *blit-tail* 0)      ; the last descriptor put on the chain, anybody's
(define *in-interrupt* nil) ; set by the trap handler, cleared before it returns

;; A ring is a word saying which descriptor is next, then the descriptors.
(define (ring-slot r i) (%+ r (%+ 8 (%* i blit-list-size))))

;; Every status clear: pool memory is not zeroed, and a descriptor that
;; happened to read "pending" before it was ever used would make the first
;; wait on it wait for a write-back that is never coming.
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
    (blit-wait-block d)
    (%st-fixnum! r (if (%= (%+ i 1) blit-ring-size) 0 (%+ i 1)))
    d))

;; The blitter belongs to task context.
;;
;; Every task fills a command block of its own, so programming the chip needs
;; no lock: two tasks are never half way through the same one, and the store
;; that commits it is a single word. That is ownership by disjointness, and it
;; is the whole arbitration - there is nothing to claim and nothing to release.
;;
;; An interrupt server does not get one and is not meant to. It used to: the
;; trap handler swapped a second block in for the duration, which looked
;; harmless and was the worst bug this machine has had. `*blit-list*` - one
;; block then, a ring now - is per
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
  (if (%= *blit-ring* 0) (set! *blit-ring* (new-blit-ring)) nil)
  (ring-take *blit-ring*))

;; The collector's own. Not a fluid binding: a collection runs with interrupts
;; off from end to end, so there is never a second one to keep apart from.
(define (gc-blit-block)
  (if (%= *gc-blit-ring* 0) (set! *gc-blit-ring* (new-blit-ring)) nil)
  (ring-take *gc-blit-ring*))

;; ---------------------------------------------------------------- waiting
;; The blitter is asynchronous: a blit takes time, and `blit-go` returns
;; before it has happened. Two different questions follow, and they have
;; different answers.
;;
;; *Is the chip idle?* That is `blit-drain`, and it asks the status register.
;; Hardly anything needs it any more, since a commit goes on the chain whether
;; the chip is busy or not. What does is whatever needs every blit in the
;; machine finished - saving an image.
;;
;; *Have my pixels landed?* That is the one drawing code actually cares about,
;; and it must not be answered by waiting for the chip to go idle, because the
;; chip is the compositor's too: it composites continuously and the chip is
;; busy about half the time, so a task that plotted a pixel only when the chip
;; was idle would spend most of its life waiting for other people's windows.
;; So the chip writes a status word back into each descriptor when it finishes
;; it, and a task waits on *its own* descriptors. That is `blit-sync`, and it
;; is a few loads from the task's own memory.
;;
;; The rule, which is the WaitBlit rule on the Amiga: **before touching pixels
;; with the processor, `blit-sync`.** `bm-plot` and `bm-point` do it for you.
;; Anything that computes pixel addresses itself - the Life demo does - has to
;; do it by hand. And forgetting is now visible: the destination holds its old
;; contents until the transfer ends, so reading too early shows the old
;; picture instead of quietly working.

(define (blit-busy?) (%= 1 (%logand (%ld-fixnum blt-status) 1)))

;; Reading the status register is what lets a finished transfer be noticed,
;; so this spin also drives completion. It is preemptible.
(define (blit-drain)
  (while (blit-busy?) nil)
  nil)

(define (blit-done? d) (%= 0 (%ld-fixnum (%+ d bl-status))))

;; How a task whose blit has not landed goes to sleep instead of spinning.
;; gfx.driver installs it, because the driver owns the chip's completion
;; interrupt. Until it does, and wherever sleeping is impossible - in an
;; interrupt server, or with interrupts off - waiting is a spin on the status
;; register.
(define *blit-sleep* nil)
(define (set-blit-sleep! fn) (set! *blit-sleep* fn) nil)

(define (interrupts-on?)
  (let ((s (%disable)))
    (%restore-interrupts s)
    (%= s 1)))

;; Ask the chip for an interrupt after every descriptor, not only at the end
;; of the chain - while anybody is asleep waiting for one.
(define (blit-irq-each! on) (%st-fixnum! blt-ctrl (if on 2 0)))

(define (blit-wait-block b)
  (if (if (%= b 0) t (blit-done? b))
      nil
      (let ((n 0))
        ;; A short spin first. Most blits are small, and a small one is done
        ;; before a sleep could be arranged. The status read is what lets the
        ;; chip notice it has finished, without waiting for the next host
        ;; slice to look.
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
;; waiting for the last one issued, without having to remember which it was.
(define (blit-wait-ring r)
  (if (%= r 0)
      nil
      (let ((i 0))
        (while (%< i blit-ring-size)
          (blit-wait-block (ring-slot r i))
          (set! i (%+ i 1)))))
  nil)

(define (blit-sync) (blit-wait-ring *blit-ring*))

;; Put a filled descriptor on the chain and return. The chip may be busy with
;; anybody's blits; this one waits its turn in memory, not here.
;;
;; The link is the delicate part. The chip reads a descriptor's link when it
;; finishes that descriptor, so a link written onto a tail it has already
;; finished is never seen. Hence the order: link only while the chip is busy -
;; then it cannot have finished the tail, because the tail is the last thing
;; it has - and afterwards look again, and start the chip from here if it has
;; gone idle without taking this one. On hardware the chip runs while this
;; does, and the second look is what catches it finishing in between; the
;; emulator only lets the chip move when somebody looks, but the code is the
;; one for the hardware.
;;
;; The fields go in before the section. The descriptor is this task's, the
;; ring has already waited for the chip to be done with it, and it is on no
;; chain until the section puts it on one.
(define (blit-go d op)
  (%st-fixnum! (%+ d bl-op) op)
  (%st-fixnum! (%+ d bl-next) 0)
  (%st-fixnum! (%+ d bl-status) 1)
  (without-interrupts
    (let ((linked (if (if (%> *blit-tail* 0) (blit-busy?) nil)
                      (begin (%st-fixnum! (%+ *blit-tail* bl-next) d) t)
                      nil)))
      (set! *blit-tail* d)
      ;; Not linked, or linked onto a tail the chip finished before it could
      ;; see the link: either way it is not coming for this one by itself. A
      ;; store to the list register starts it - or, if the chip is busy with a
      ;; chain whose end nothing here knows, waits for that chain first, which
      ;; is slow but right.
      (if (if linked (blit-busy?) nil)
          nil
          (if (%= 1 (%ld-fixnum (%+ d bl-status)))
              (%st-fixnum! blt-list d)
              nil))))
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
;; The keyboard and mouse. Events wait in a queue in the chip, one word each:
;; the kind in bits 31..28, ascii in 27..20, the raw key code in 19..12, and a
;; payload - a button number, a wheel step - in 11..0. Reading the event
;; register takes one off the queue. The pointer's position and buttons are
;; registers, since where the mouse is now is what a pointer wants.
;;
;; input.driver owns this, and everybody else subscribes to it: see
;; input.lisp. Until it has claimed the device, whoever holds it may use it.
(define *input* (make-device "input" dev-input nil))
(define inp-event #x00)
(define inp-count #x04)
(define inp-mousex #x08)
(define inp-mousey #x0c)
(define inp-buttons #x10)
(define inp-ctrl #x14)
(define inp-mods #x18)
(define inp-inject #x1c)

;; The next event, taken apart - (kind ascii code payload) - or nil when the
;; queue is empty. The register is read once, because reading it is what takes
;; the event; and into the scratch cell rather than into a number, because a
;; button event has bit 30 set and the word was never a number anyway.
(define (input-take)
  (let ((r (dev-reg *input* inp-event)) (hi 0) (lo 0))
    (without-interrupts
      (%st-word! peek-scratch (%ld-word r))
      (set! lo (%ld-half peek-scratch))
      (set! hi (%ld-half (%+ peek-scratch 2))))
    (if (if (%= hi 0) (%= lo 0) nil)
        nil
        (list (%lsh hi -12)
              (%logand (%lsh hi -4) 255)
              (%logior (%lsh (%logand hi 15) 4) (%lsh lo -12))
              (%logand lo 4095)))))

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

(define (input-count) (%ld-fixnum (dev-reg *input* inp-count)))
(define (input-interrupts! on) (poke (dev-reg *input* inp-ctrl) (if on 1 0)))
(define (input-mouse-x) (%ld-fixnum (dev-reg *input* inp-mousex)))
(define (input-mouse-y) (%ld-fixnum (dev-reg *input* inp-mousey)))
(define (input-buttons) (%ld-fixnum (dev-reg *input* inp-buttons)))
(define (input-mods) (%ld-fixnum (dev-reg *input* inp-mods)))

;; ---------------------------------------------------------------- storage
;; The disk controller. A command runs on its own time: `disk-go` programs it
;; and returns at once, the status reads `disk-busy` for as long as the
;; transfer takes, and then it reads the result - 0 ok, 1 no disk attached,
;; 2 the range is not in memory, 3 the host's I/O failed. With the control
;; register's bit 0 set, the controller raises `int-disk` when it finishes.
;;
;; The disk driver owns this, and everything else asks the driver: see
;; disk.lisp. Until the driver has claimed it - and in the stretch of a
;; rebuild where there is no Exec to run a driver in - whoever holds the
;; device may use it.
(define *disk* (make-device "disk" dev-disk nil))
(define dsk-addr #x00)
(define dsk-block #x04)
(define dsk-count #x08)
(define dsk-cmd #x0c)
(define dsk-status #x10)
(define dsk-blocks #x14)
(define dsk-ctrl #x18)

(define (disk-go cmd addr block n)
  ;; The command goes last: the controller latches the other three when it
  ;; arrives, so the three before it can be rewritten for the next command
  ;; while this one runs.
  (let ((base (dev-reg *disk* 0)))
    (without-interrupts
      (poke (%+ base dsk-addr) addr)
      (poke (%+ base dsk-block) block)
      (poke (%+ base dsk-count) n)
      (poke (%+ base dsk-cmd) cmd)))
  nil)

;; One load, no allocation: a status is a small number, and this is read in a
;; loop with interrupts off.
(define (disk-status) (%ld-fixnum (dev-reg *disk* dsk-status)))
(define (disk-busy?) (%= (disk-status) disk-busy))
(define (disk-blocks) (peek (dev-reg *disk* dsk-blocks)))
(define (disk-interrupts! on) (poke (dev-reg *disk* dsk-ctrl) (if on 1 0)))

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
