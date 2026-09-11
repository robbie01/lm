;;; exec.lisp - an Amiga Exec, in Lisp.
;;;
;;; One shared address space, no protection, no MMU. Every task can see every
;;; byte of memory, which is exactly what makes the message passing here cost
;;; nothing: PutMsg puts a pointer on a list, and the receiving task reads the
;;; message where it already lies. Nothing is copied and nothing is mapped,
;;; because there is nothing to copy it between.
;;;
;;; The structures are laid out the way Exec's are, and behave the way Exec's
;;; do: doubly linked lists with a virtual head and tail node so that Remove
;;; needs no special cases; tasks with 32 signal bits and Wait/Signal; message
;;; ports built on top of signals; Forbid and Permit for cooperative critical
;;; sections and Disable and Enable for real ones; libraries reached through a
;;; jump table below their base pointer.
;;;
;;; The one piece of machinery this gets for free is the context switch. The
;;; trap stub already saves all 32 registers into the block that mscratch
;;; points at, and restores from there on the way out. So switching tasks is
;;; one CSR write: point mscratch at a different task's context and return.

(in-package exec)

;; ---------------------------------------------------------------- Node
;; Everything that goes on one of Exec's lists starts with the same five
;; slots. They used to be byte offsets into raw pool memory and are record
;; slots now. Reading one costs a single checked instruction where `peek` cost
;; four unchecked ones - but the reason for the change is neither of those. It
;; is that a task's memory used to go back to the pool when the task ended, so
;; a task pointer somebody kept could come back pointing at a different, live
;; task. Nothing frees a record; a kept reference holds a dead task, which
;; says it is removed and ignores its signals.
;; `open`, because everything below is built on this one and a list has to be
;; walkable without knowing which: a node's accessors check that they have a
;; record and stop there.
(defrecord (node open) succ pred pri name)

;; A node's tag is given rather than fixed - it says what kind of thing is on
;; the list, and a list holds tasks, ports, interrupts and its own sentinels.
(define (make-node tag) (make-record node-slots tag))
(define (node-tag n) (record-tag n))

;; ---------------------------------------------------------------- List
;; A list is a header owning two sentinel nodes: one before the first real
;; node, one after the last. That is what lets insert and remove skip every
;; test for the ends - a node's predecessor is always some node, real or
;; sentinel, and writing through it is always right.
;;
;; Exec packs those two sentinels into the header's own three words, treating
;; the header as a node at `l` and another at `l + 4`, sharing the word that
;; is the head's predecessor and the tail's successor - neither of which is
;; ever read. It saves one word per list and needs a pointer four bytes into
;; the header, which this machine cannot represent: an object reference has
;; its low three bits equal to four, so four bytes along reads as a cons. So
;; the sentinels are real nodes here. The packing is gone; the property that
;; made it worth having is not.
;; head: the sentinel before the first node. tail: the one after the last.
(defrecord (exec-list list) head tail)

(define (new-list)
  (let ((l (list-alloc))
        (h (make-node 'list-head))
        (tl (make-node 'list-tail)))
    (set-list-head! l h)
    (set-list-tail! l tl)
    ;; The tail sentinel's successor is nil, and that nil is what ends a walk:
    ;; the same terminator the zero in Exec's `lh-tail` always was.
    (set-node-succ! h tl)
    (set-node-pred! tl h)
    l))

(define (list-empty? l) (%eq? (node-succ (list-head l)) (list-tail l)))
(define (list-first l) (if (list-empty? l) nil (node-succ (list-head l))))
(define (list-last l) (if (list-empty? l) nil (node-pred (list-tail l))))

(define (node-next n)
  ;; The successor of the last real node is the tail sentinel, whose own
  ;; successor is nil. Walkers see nil for "no more", never a sentinel.
  (let ((s (node-succ n)))
    (if (%null? (node-succ s)) nil s)))

;; Four writes and no test. `p` may be the tail sentinel and its predecessor
;; may be the head sentinel; neither is a special case.
(define (insert-before p n)
  (let ((prev (node-pred p)))
    (set-node-succ! n p)
    (set-node-pred! n prev)
    (set-node-succ! prev n)
    (set-node-pred! p n)
    n))

(define (add-head l n) (insert-before (node-succ (list-head l)) n))
(define (add-tail l n) (insert-before (list-tail l) n))

;; Taking a node out, and *saying so in the node*. Removal has to be
;; idempotent, because there is no way to ask a node whether it is on a list
;; and every caller that takes one off is entitled to assume it worked.
;;
;; It used to leave the node's own links alone, pointing at the neighbours it
;; had when it was removed - which turned a second removal into a splice of
;; two nodes that had since moved on. That is not hypothetical:
;;
;;   `switch-tasks` takes the next task off the ready list with `rem-head`,
;;   which is `remove-node`. The task runs, signals somebody - who is enqueued
;;   on the ready list, quite possibly exactly between the two neighbours the
;;   first task still remembers - and then ends. Ending reaps it, and reaping
;;   is `forget-node`, which removed it a second time: the stale neighbours
;;   were joined to each other, and the task in between was lost. Not
;;   corrupted, not woken: simply on no list, marked ready, holding a signal
;;   it had already been sent, and never scheduled again.
;;
;;   It needed a task to exit while another was newly ready, so it took four
;;   tasks and a particular interleaving, and it looked exactly like a lost
;;   wakeup. It was in every version of this scheduler.
(define (remove-node n)
  (let ((s (node-succ n))
        (p (node-pred n)))
    (if (if s p nil)
        (begin (set-node-succ! p s) (set-node-pred! s p))
        nil)
    (set-node-succ! n nil)
    (set-node-pred! n nil)
    n))

;; The same thing. It is spelled differently where the point is that the node
;; is finished with rather than moving somewhere else - and the links going is
;; what the collector needs either way, so that a node somebody still holds
;; does not keep every node that was behind it alive.
(define (forget-node n) (remove-node n))

(define (rem-head l)
  (if (list-empty? l) nil (remove-node (list-first l))))

(define (rem-tail l)
  (if (list-empty? l) nil (remove-node (list-last l))))

(define (enqueue l n)
  ;; Insert by priority, after every node of equal or higher priority, so that
  ;; equal priorities keep their arrival order and round-robin fairly. The
  ;; walk ends at the tail sentinel, which is the one node with no successor.
  (let ((pri (node-pri n))
        (p (node-succ (list-head l)))
        (done nil))
    (while (if done nil (node-succ p))
      (if (%< (node-pri p) pri)
          (set! done t)
          (set! p (node-succ p))))
    (insert-before p n)))

(define (find-name l name)
  (let ((p (list-first l)) (found nil))
    (while (if found nil p)
      (let ((s (node-name p)))
        (if (if (%string? s) (string=? s name) nil)
            (set! found p)
            (set! p (node-next p)))))
    found))

(define (list-nodes l)
  ;; A Lisp list of the nodes, for inspection from the repl.
  (let ((p (list-first l)) (acc nil))
    (while p
      (set! acc (%cons p acc))
      (set! p (node-next p)))
    (reverse acc)))

;; ---------------------------------------------------------------- Task
;; Slots 0..4 are the node the scheduler's lists thread it on to. The stack
;; and the 128-byte register context stay raw pool memory: the trap stub
;; writes the context as thirty-two untagged words at whatever address
;; mscratch holds, and a record's slots are tagged values.
(defrecord (task tc) (include node)
  state sigalloc sigwait sigrecvd
  splower spupper                ; raw addresses, held as fixnums
  context                        ; 128-byte register block, raw
  fn                             ; the closure the task runs
  result switches
  binds                          ; this task's fluid bindings, innermost first
  quantum elapsed
  parent children                ; a dependent task dies with the one that made it
  cleanups)                      ; what to do when it ends, newest first

(define ts-invalid 0)
(define ts-added 1)
(define ts-run 2)
(define ts-ready 3)
(define ts-wait 4)
(define ts-except 5)
(define ts-removed 6)

;; ---------------------------------------------------------------- the kernel
;; Exec keeps its own state in an ExecBase at a known address, so that any
;; program, in any language, compiled separately, can find the kernel with
;; `move.l 4.w,a6` and no linker. None of that applies here: one address
;; space, one image, and every function can name a symbol directly. So there
;; is no ExecBase at all - the lists are records held in variables, like the
;; counts and the nesting depths beside them.
(define *idle-task* nil)
(define *ready-list* nil)
(define *wait-list* nil)
(define *lib-list* nil)
(define *port-list* nil)
(define *int-vectors* nil)     ; a vector of eight lists
(define *tdnest* 0)            ; Forbid nesting
(define *attn-resched* 0)      ; a switch a Forbid deferred
(define *quantum* 0)
(define *disp-count* 0)
(define *switch-count* 0)
(define *idle-count* 0)
(define *task-count* 0)

;; Which task is running is a register, not a variable. s2 is dedicated to
;; it, the trap stub was already saving and restoring all thirty two, and so
;; the scheduler carries it for nothing: a task's own state is one instruction
;; away wherever it is standing, and there is no second copy to keep in step.
;; Before Exec exists s2 is zero, which reads as nil.
(define (this-task) (%this-task))
(define (ready-list) *ready-list*)
(define (wait-list) *wait-list*)
(define (int-vector n) (%vector-ref *int-vectors* n))

;; ---------------------------------------------------------------- context
;; Word 0 is the pc, words 1..31 are x1..x31. This is the block the trap stub
;; saves into and restores from, so a task's context and a trap frame are the
;; same thing.

;; ---------------------------------------------------------------- critical
;; Two ways to be atomic, and which one you want depends on who else touches
;; the thing you are protecting.
;;
;; `without-interrupts` turns interrupts off at the processor. It is the one to
;; use when an interrupt server touches the data - the scheduler's lists, the
;; signal bits, the pool free list - and the price is that the clock stops, the
;; keyboard stops and the frame stops for as long as it is held.
;;
;; `without-preemption` (Forbid) leaves interrupts on and holds off the
;; scheduler, so no other *task* can run. It is the one to use when only tasks
;; touch the data. It costs one increment, needs nothing declared, and cannot
;; deadlock; what it cannot do is let you block, because nothing else will run
;; to wake you.
;;
;; There used to be a counted Disable/Enable pair here as well, with a nesting
;; depth and the interrupt state the outermost one found. It is gone.
;; `without-interrupts` already saves and restores that state, which makes it
;; nestable without a counter and correct in places the counter was not - and
;; the depth was read by nothing except the pair itself. The one section that
;; is not lexical is in `wait`, and it works the state by hand.

(define (forbid)
  (set! *tdnest* (%+ *tdnest* 1))
  nil)

;; Leaving Forbid means paying whatever the scheduler wanted to do while it was
;; held off. Split out because the macro below wants it too.
(define (permit-deferred)
  (if (%> *attn-resched* 0)
      (begin (set! *attn-resched* 0) (reschedule))
      nil))

(define (permit)
  (let ((n (%- *tdnest* 1)))
    (set! *tdnest* (if (%< n 0) 0 n))
    (if (%<= n 0) (permit-deferred) nil))
  nil)

;; Forbid, lexically, and the one to reach for by default.
;;
;; The body runs with the scheduler held off: no other task can take the
;; processor. Interrupts stay on, which is the whole difference from
;; `without-interrupts` - the clock keeps counting, the keyboard keeps
;; arriving, the display keeps its frame - and only tasks are excluded. So it
;; is the right lock for anything shared between tasks that no interrupt
;; server touches, and it is the wrong one for anything a server does touch.
;;
;; It restores the nesting depth it found rather than decrementing, so an
;; unbalanced Forbid somewhere inside the body cannot leave the scheduler
;; switched off for good.
(defmacro without-preemption body
  (let ((saved (gensym)) (result (gensym)))
    `(let ((,saved *tdnest*))
       (set! *tdnest* (%+ ,saved 1))
       (let ((,result (begin ,@body)))
         (set! *tdnest* ,saved)
         (if (%= ,saved 0) (permit-deferred) nil)
         ,result))))

(define (forbidden?) (%> *tdnest* 0))

;; ---------------------------------------------------------------- scheduler
;; A reschedule is asked for with an ecall, so that the switch happens inside
;; the trap handler where the whole register set has already been saved.

(define (reschedule) (%ecall trap-reschedule))

;; ---------------------------------------------------------------- fluids
;; The bindings themselves are in macros.lisp, because the reader and the
;; printer want them and neither can see Exec. All that is here is where a
;; binding goes: onto the running task's own stack, so that the scheduler can
;; swap it out with the registers and two tasks inside the same `fluid-let`
;; see their own values.
;;
;; Before this is installed, and in the trap handler where there is no task to
;; speak of, a binding goes on the one stack there is - which is right, since
;; nothing is competing for it.
(define (install-task-binds!)
  (set! *binds-get* (lambda () (let ((t (this-task))) (if t (tc-binds t) *boot-binds*))))
  (set! *binds-set*
        (lambda (v)
          (let ((t (this-task)))
            (if t (set-tc-binds! t v) (set! *boot-binds* v))))))

;; What a new task starts out holding: whatever its creator was holding, so
;; that a shell's children talk to the shell's window. One entry per place,
;; carrying the value the creator has now - which is exactly the shape a
;; suspended task's stack has, and a new task is suspended until it first runs.
(define (initial-binds)
  (list (%cons '*out* *out*)
        (%cons '*in* *in*)
        (%cons '*await* *await*)
        (%cons '*peeked* nil)
        (%cons '*repl-restart* nil)
        (%cons 'package (current-package))
        ;; Blitter descriptors of its own, so that programming the chip needs
        ;; no lock: two tasks are never half way through the same one. Made
        ;; the first time the task blits, since most tasks never do.
        (%cons '*blit-ring* 0)
        ;; And one reply port, made the first time this task asks a server for
        ;; something. One per task and not one per call, because a task has
        ;; one blocker and therefore one conversation.
        (%cons '*reply-port* nil)))

;; Dead tasks waiting to be reclaimed. A task cannot free the stack it is
;; standing on, so it goes on this list instead and the next context switch
;; does the work - that runs on the trap stack, with the corpse saved and
;; never to be resumed, which is the first moment its stack is genuinely idle.
(define *reply-port* nil)   ; per task; see `initial-binds` and `reply-port`

(define *reaped* nil)

(define (reap-tasks)
  (let ((p *reaped*))
    (set! *reaped* nil)
    (while (%cons? p)
      (reap-task (%car p))
      (set! p (%cdr p)))))

(define (task-ready! task)
  (set-tc-state! task ts-ready)
  (enqueue (ready-list) task))

;; Choose the next task and point mscratch at its context. Called only from
;; inside the trap handler, with the outgoing task's registers already saved.
(define (switch-tasks)
  (let ((cur (this-task)))
    (if (forbidden?)
        ;; A forbidden task keeps the processor; remember that it owes us one.
        (set! *attn-resched* 1)
        (let ((next (rem-head (ready-list))))
          (if (%null? next)
              nil
              (begin
                (swap-binds-out! (tc-binds cur))
                (if (%= (tc-state cur) ts-run)
                    (task-ready! cur)
                    nil)
                (set-tc-elapsed! cur (%+ (tc-elapsed cur) 1))
                (set-tc-state! next ts-run)
                (set-tc-switches! next (%+ (tc-switches next) 1))
                (swap-binds-in! (tc-binds next))
                (set! *switch-count* (%+ *switch-count* 1))
                (%set-context (tc-context next))
                ;; Only now, with the context switched away from whatever was
                ;; running, is it safe to hand a dead task's stack back.
                (if *reaped* (reap-tasks) nil)))))
    nil))

;; ---------------------------------------------------------------- signals
(define (alloc-signal task)
  ;; Signals 0..15 are reserved the way Exec reserves them; 16..30 are free.
  ;; What comes back is the bit as a mask, because that is what `signal` and
  ;; `wait` take: a bit number and a mask are both fixnums and nothing would
  ;; catch one handed to the other.
  ;;
  ;; The failure is raised outside the critical section, because an error here
  ;; abandons the stack and would abandon the section with it.
  (let ((got (without-interrupts
               ;; Up to 30, not 31. A mask is a fixnum and a fixnum has
               ;; thirty-one bits, so `(%lsh 1 31)` is not a bit, it is zero -
               ;; and a signal whose mask is zero is one nobody can receive.
               (let ((alloc (tc-sigalloc task)) (n 16) (g -1))
                 (while (if (%< n 31) (%< g 0) nil)
                   (if (%= 0 (%logand alloc (%lsh 1 n)))
                       (begin
                         (set-tc-sigalloc! task (%logior alloc (%lsh 1 n)))
                         ;; And clear it, the way AllocSignal does. The bit can
                         ;; still be set from its last owner - a port that was
                         ;; notified and then deleted before anybody waited on
                         ;; it - and a new signal that arrives already received
                         ;; makes the first wait on it return at once.
                         (set-tc-sigrecvd! task
                                           (%logand (tc-sigrecvd task)
                                                    (%lognot (%lsh 1 n))))
                         (set! g n))
                       (set! n (%+ n 1))))
                 g))))
    (if (%< got 0) (error "alloc-signal: none left") nil)
    (%lsh 1 got)))

(define (free-signal task mask)
  (without-interrupts
    (set-tc-sigalloc! task (%logand (tc-sigalloc task) (%lognot mask))))
  nil)

;;
;; A task is a record that says so, and nothing frees a record - so a task
;; pointer somebody kept is either a live task or a dead one, and never a
;; different live task that happens to have been given the same memory. That
;; used to be the hazard this file could only narrow, not close: `rem-task`
;; returned the block to the pool, and the pool handed it out again.

(define (signal task mask)
  (if (task? task) nil (error "signal: not a task" task))
  (without-interrupts
    (set-tc-sigrecvd! task (%logior (tc-sigrecvd task) mask))
    (if (%= (tc-state task) ts-wait)
        (if (%> (%logand (tc-sigrecvd task) (tc-sigwait task)) 0)
            (begin
              (remove-node task)
              (task-ready! task)
              ;; A woken task of higher priority should get the processor now.
              (if (%> (node-pri task) (node-pri (this-task)))
                  (set! *attn-resched* 1)
                  nil))
            nil)
        nil))
  nil)

(define (wait mask)
  ;; Block until one of the signals in mask arrives, then take those bits and
  ;; leave the rest for the next Wait.
  ;;
  ;; Not from an interrupt server. Waiting means asking to be rescheduled, and
  ;; asking to be rescheduled is an ecall - a trap taken from inside the trap
  ;; handler, on the trap stack, with the interrupted task's context half
  ;; saved. There is no task there to block.
  ;; The one critical section in the machine that is not lexical, and the only
  ;; reason the interrupt state is still worked by hand anywhere: it is opened
  ;; here, released around the reschedule that blocks - you cannot block with
  ;; interrupts off - and taken again on the way back. `without-interrupts`
  ;; cannot say that, so this says it, and restores what it found each time
  ;; rather than assuming interrupts were on.
  (if *in-interrupt* (error "wait: called from an interrupt server") nil)
  (let ((saved (%disable)))
    (let ((task (this-task)) (got 0))
      (set! got (%logand (tc-sigrecvd task) mask))
      (if (%= got 0)
          (begin
            (set-tc-sigwait! task mask)
            (set-tc-state! task ts-wait)
            ;; On the wait list *once*, and it stays there until `signal`
            ;; takes it off - which `signal` only does when a bit this task
            ;; asked for has arrived, so coming back round the loop still
            ;; waiting means still being on the list.
            ;;
            ;; This used to be inside the loop, and `add-tail` does not unlink
            ;; a node from wherever it already is: it splices it in and leaves
            ;; the old neighbours pointing at it. A second pass therefore
            ;; stitched the wait list into itself, and the tasks in the segment
            ;; that came adrift were on no list at all - runnable, signalled,
            ;; and never scheduled again. It needed a task to be rescheduled
            ;; without being signalled to show at all, which is why it only
            ;; turned up with three or four tasks running and looked like a
            ;; lost wakeup rather than a corrupted list.
            (add-tail (wait-list) task)
            (while (%= got 0)
              ;; You cannot block with interrupts off, so they go back on for
              ;; the reschedule and come off again on the way back.
              (%restore-interrupts saved)
              (reschedule)
              (set! saved (%disable))
              (set! got (%logand (tc-sigrecvd task) mask)))
            ;; `signal` took it off the wait list on the way to making it
            ;; ready; nothing to undo here.
            nil)
          nil)
      (set-tc-sigrecvd! task
                    (%logand (tc-sigrecvd task) (%lognot got)))
      (set-tc-sigwait! task 0)
      (%restore-interrupts saved)
      got)))

(define (set-signal task new mask)
  (without-interrupts
    (let ((old (tc-sigrecvd task)))
      (set-tc-sigrecvd! task
                    (%logior (%logand old (%lognot mask)) (%logand new mask)))
      old)))

;; ---------------------------------------------------------------- tasks
;; Slot 0 of a closure holds a raw code address rather than a tagged value, so
;; reading it back as a number takes %addr-of, not %from-addr: the word is
;; already an address and must not be shifted.
(define (closure-entry fn) (%addr-of (%ld-word (%addr-of fn))))

(define default-stack 65536)
(define default-quantum 200000)

;; A fresh record's slots hold nil, and nil is not the fixnum zero - `(%+ nil
;; 1)` is not 1, and `(%logand nil m)` is not 0. Anything counted or masked
;; has to be set before it is read. The old pool block came back zeroed, and
;; a raw zero word *is* the fixnum zero, so this is new bookkeeping that the
;; representation asks for.
(define (zero-task-counters! task)
  (set-tc-sigwait! task 0)
  (set-tc-sigrecvd! task 0)
  (set-tc-switches! task 0)
  (set-tc-elapsed! task 0)
  (set-tc-result! task 0)
  nil)

(define (add-task name pri fn . opts)
  (let* ((binds (initial-binds))
         (stack (if (%cons? opts) (%car opts) default-stack))
         (task (tc-alloc))
         (ctx (alloc-pool ctx-bytes))
         (sp (alloc-pool stack)))
    ;; The environment is built before the task holds any Lisp value. There is
    ;; no window to worry about any more - a half-filled task record is traced
    ;; like any other object, whether or not it is on a list yet - but the
    ;; order costs nothing and says what it means.
    (set-node-name! task name)
    (set-node-pri! task pri)
    (zero-task-counters! task)
    (set-tc-state! task ts-added)
    (set-tc-splower! task sp)
    (set-tc-spupper! task (%+ sp stack))
    (set-tc-context! task ctx)
    (set-tc-fn! task fn)
    (set-tc-binds! task binds)
    (set-tc-quantum! task default-quantum)
    (set-tc-sigalloc! task 65535)
    ;; The context is built to look as though the task had just been
    ;; interrupted on the first instruction of its function.
    (poke (ctx-pc ctx) (closure-entry fn))
    (poke (ctx-reg ctx reg-sp) (%+ sp stack))
    (poke (ctx-reg ctx reg-ra) *task-exit-stub*)
    ;; s2 says which task is running, so a task's context has to carry it the
    ;; way it carries its stack pointer. Nothing sets it again after this.
    (%st-word! (ctx-reg ctx reg-s2) task)
    (%st-word! (ctx-reg ctx reg-t0) fn)
    (poke (ctx-reg ctx reg-t1) 0)
    (without-interrupts
      (task-ready! task)
      (set! *task-count* (%+ *task-count* 1)))
    task))

;; What the forge handed out before the machine ran - the boot task's stack,
;; its context - has no header and was never meant to come back. Ending the
;; first task should not try to give it away.
(define (free-if-ours p)
  (if (if p (%> p 0) nil)
      (if (%= (%ld-fixnum (%+ p -4)) pool-tag) (free-pool p) nil)
      nil))

;; A dependent task: a goroutine, near enough. It is removed when the task
;; that made it is, so a server that fans work out to helpers does not have to
;; remember what it started, and a shell that dies does not leave its workers
;; holding its window.
;;
;; The link is one way for the collector's sake as well as the scheduler's: a
;; parent holds its children, so a child cannot outlive the list it is on.
(define (spawn name pri fn . opts)
  (let ((child (apply add-task (list* name pri fn opts)))
        (me (this-task)))
    (if me
        (without-interrupts
          (set-tc-parent! child me)
          (set-tc-children! me (%cons child (tc-children me))))
        nil)
    child))

(define (task-children task) (tc-children task))
(define (task-parent task) (tc-parent task))

(define (rem-children task)
  ;; Depth first, and the list is taken before anything is removed: removing a
  ;; child runs this again for its own children, and a child that ends by
  ;; itself is already off its parent's list.
  (let ((cs (without-interrupts
              (let ((c (tc-children task)))
                (set-tc-children! task nil)
                c))))
    (while (%cons? cs)
      (let ((c (%car cs)))
        (if (%= (tc-state c) ts-removed) nil (rem-task c)))
      (set! cs (%cdr cs))))
  nil)

(define (forget-child task)
  ;; A task that ends on its own takes itself off its parent's list, so a
  ;; long-lived parent does not accumulate corpses.
  (let ((p (tc-parent task)))
    (if p
        (without-interrupts
          (set-tc-children! p (remove-eq task (tc-children p)))
          (set-tc-parent! task nil))
        nil))
  nil)

;; Something to do when a task ends, however it ends - finishing, failing, or
;; being removed by somebody else. What a driver holds that is not a device,
;; like its interrupt server, is given back this way: from outside there is
;; no telling what a task was holding.
(define (on-task-end task fn)
  (without-interrupts (set-tc-cleanups! task (%cons fn (tc-cleanups task))))
  nil)

(define (run-cleanups task)
  (let ((fs (without-interrupts
              (let ((c (tc-cleanups task)))
                (set-tc-cleanups! task nil)
                c))))
    (while (%cons? fs)
      (%funcall (%car fs))
      (set! fs (%cdr fs))))
  nil)

;; Make a task nobody's dependent, so that it outlives whoever started it. A
;; resident driver is started by whichever task brought Exec up, and is not
;; that task's to take down with it.
(define (detach-task task) (forget-child task) task)

(define (rem-task task)
  ;; A task that has ended stays a task and says so. Signalling it does
  ;; nothing, because it is in no state to be woken; that is the whole
  ;; difference from a handle that could come back as somebody else.
  (rem-children task)
  (forget-child task)
  (release-devices-of task)
  (run-cleanups task)
  (without-interrupts
    (set-tc-state! task ts-removed)
    (set! *task-count* (%- *task-count* 1)))
  ;; Anybody still waiting on an answer from it gets one. After it is marked
  ;; ended, so that nothing can queue behind the last of these: `put-msg`
  ;; checks the same mark.
  (fail-ports-of task)
  (if (%eq? task (this-task))
      (begin
        ;; The current task cannot free its own stack while standing on it, so
        ;; it puts itself on the reaper list and stops being runnable. The
        ;; switch that takes it off the processor is what frees it.
        (set! *reaped* (%cons task *reaped*))
        (reschedule)
        nil)
      (begin (reap-task task) nil)))

;; The stack and the register context are pool memory and are given back by
;; hand. The task itself is not: it is an object, and the collector takes it
;; when the last reference to it goes. Its links go first, so that a task
;; somebody is still holding does not keep every task behind it alive.
(define (reap-task task)
  (forget-node task)
  (free-if-ours (tc-splower task))
  (free-if-ours (tc-context task))
  (set-tc-splower! task nil)
  (set-tc-context! task nil)
  nil)

(define (find-task name)
  (if (%null? name)
      (this-task)
      (let ((f (find-name (ready-list) name)))
        (if f f (find-name (wait-list) name)))))

(define (task-name task) (node-name task))

(define (task-state-name s)
  (cond ((%= s ts-added) "added")
        ((%= s ts-run) "run")
        ((%= s ts-ready) "ready")
        ((%= s ts-wait) "wait")
        ((%= s ts-removed) "removed")
        (else "?")))

(define (task-snapshot)
  ;; The lists are walked with interrupts off and printed with them on: an
  ;; interrupt that signals a task moves it from one list to the other, and a
  ;; walk that was halfway along the first one then follows a node that is now
  ;; in the second.
  (without-interrupts
    (let ((acc nil))
      (dolist (p (list-nodes (wait-list))) (set! acc (%cons p acc)))
      (dolist (p (list-nodes (ready-list))) (set! acc (%cons p acc)))
      (%cons (this-task) (reverse acc)))))

(define (tasks)
  ;; What the whole system is doing, for the repl.
  (emit-str "  pri  state    switches  name\n")
  (let ((show (lambda (p)
                (emit-str "  ")
                (emit-str (number->string (node-pri p)))
                (emit-str "    ")
                (emit-str (task-state-name (tc-state p)))
                (emit-str "     ")
                (emit-str (number->string (tc-switches p)))
                (emit-str "  ")
                (emit-str (task-name p))
                (emit-str "\n"))))
    (dolist (p (task-snapshot)) (%funcall show p)))
  nil)

;; The stub a task returns to when its function finishes. It cannot be a Lisp
;; closure directly, because it is reached by `ret` with the argument registers
;; holding whatever the task left in them.
(define *task-exit-stub* 0)

(define (task-finished)
  (let ((task (this-task)))
    (set-tc-result! task 0)
    ;; The last task to finish takes the machine with it: there is nothing
    ;; left to schedule, and pretending otherwise is a hang. The idle task does
    ;; not count - it is always there and it never does anything.
    (if (%<= (task-count) (if *idle-task* 2 1))
        (begin (emit-str "\n") (%halt 0))
        nil)
    (rem-task task)
    ;; rem-task on the current task never returns, but if it somehow did,
    ;; spinning is better than running off the end of the world.
    (while t (reschedule))))

(define (build-task-exit-stub)
  (let ((a (make-assembler)))
    (i-li a $t1 0)
    (i-lw a $t0 $zero lg-scratch0)
    (i-lw a $t2 $t0 0)
    (i-jr a $t2)
    (set! *task-exit-stub* (asm-place a))
    (%st-word! lg-scratch0 (%symbol-value 'task-finished))
    *task-exit-stub*))

;; ---------------------------------------------------------------- ports
(defrecord (msgport mp) (include node) sigmask sigtask msglist)

(defrecord (message mn) (include node) replyport length body)

(define (create-port name pri) (create-port-for (this-task) name pri))

;; A port belongs to the task that waits on it, which is not always the task
;; that makes it: a server's port has to be the server's, and the server is
;; not running yet when it is created.
(define (create-port-for owner name pri)
  (let ((p (mp-alloc))
        (sig (alloc-signal owner)))
    (set-node-name! p name)
    (set-node-pri! p pri)
    (set-mp-sigmask! p sig)
    (set-mp-sigtask! p owner)
    (set-mp-msglist! p (new-list))
    (if (%null? name)
        nil
        (without-interrupts (enqueue *port-list* p)))
    p))

(define (delete-port p)
  (if (%null? (node-name p)) nil (without-interrupts (forget-node p)))
  (free-signal (mp-sigtask p) (mp-sigmask p))
  nil)

(define (find-port name) (find-name *port-list* name))

(define (create-message body reply)
  (let ((m (mn-alloc)))
    (set-mn-replyport! m reply)
    (set-mn-length! m mn-slots)
    (set-mn-body! m body)
    m))

(define (message-body m) (mn-body m))
(define (set-message-body! m v) (set-mn-body! m v))

(define (port-signal p) (mp-sigmask p))

;; Whether anybody is behind a port: its task exists and has not ended.
(define (port-open? p)
  (let ((o (mp-sigtask p)))
    (if o (if (%= (tc-state o) ts-removed) nil t) nil)))

;; What a caller gets instead of an answer when nobody is left to give one:
;; the task behind the port has ended, or its handler failed. A value, not a
;; silence. A caller blocked on a reply that never comes is blocked for ever,
;; and with one blocker per task that is the whole task lost.
(defrecord (failure fl) why)

(define (make-failure why)
  (let ((f (fl-alloc)))
    (set-fl-why! f why)
    f))

(define (failure-why f) (fl-why f))

(define (put-msg port msg)
  ;; The signal is sent outside the section on purpose: Signal takes it again,
  ;; and holding it across a wake-up is holding it for longer than the list
  ;; needs.
  ;;
  ;; A port whose task has ended takes nothing: the message is answered with
  ;; a failure there and then. The check is in the same section as the
  ;; append, so a task cannot end between the two - `rem-task` marks it ended
  ;; first, and answers whatever was already queued second.
  (let ((owner (without-interrupts
                 (let ((o (mp-sigtask port)))
                   (if (if o (%= (tc-state o) ts-removed) nil)
                       'ended
                       (begin (add-tail (mp-msglist port) msg) o))))))
    (cond ((%eq? owner 'ended) (fail-msg msg "the task behind that port has ended"))
          (owner (signal owner (mp-sigmask port)))
          (else nil)))
  msg)

;; Answer a message with a failure. Straight onto its reply port rather than
;; through `put-msg`, so that answering a caller who has also ended does not
;; go round again.
(define (fail-msg msg why)
  (set-mn-body! msg (make-failure why))
  (let ((r (mn-replyport msg)))
    (if r
        (let ((owner (without-interrupts
                       (add-tail (mp-msglist r) msg)
                       (mp-sigtask r))))
          (if owner (signal owner (mp-sigmask r)) nil))
        nil))
  nil)

;; Everything queued on the ports of a task that has ended, answered. Only
;; named ports: a server's port has a name, and an unnamed one is a reply
;; port, which nobody is waiting on an answer from. The ports come off the
;; list as well, so that looking one up by name cannot find a dead one.
(define (fail-ports-of task)
  (let ((ports (without-interrupts
                 (let ((acc nil) (p (list-first *port-list*)))
                   (while p
                     (if (%eq? (mp-sigtask p) task) (set! acc (%cons p acc)) nil)
                     (set! p (node-next p)))
                   (dolist (q acc) (forget-node q))
                   acc))))
    (dolist (p ports)
      (let ((m (get-msg p)))
        (while m
          (fail-msg m "the task behind that port has ended")
          (set! m (get-msg p))))))
  nil)

(define (get-msg port)
  (without-interrupts (rem-head (mp-msglist port))))

(define (wait-port port)
  (let ((m nil))
    (while (%null? m)
      (set! m (get-msg port))
      (if (%null? m) (wait (mp-sigmask port)) nil))
    ;; Put it back: WaitPort tells you a message is there without taking it.
    (without-interrupts (add-head (mp-msglist port) m))
    m))

;; Nothing to free: a message nobody holds is collected like anything else.
(define (delete-message m) (forget-node m))

(define (reply-msg msg)
  (let ((r (mn-replyport msg)))
    (if r (put-msg r msg) nil)))

;; ---------------------------------------------------------------- servers
;; A driver is a task with a port, and talking to it is sending it a message.
;;
;; That is the whole of the device model. There is no registry of device names
;; and no `OpenDevice`: a driver is reached by naming the symbol that holds it,
;; because this is a Lisp machine and a symbol is already a name the whole
;; system agrees on. What AmigaOS needed a string-keyed table of IO ports for,
;; we get from the reader.
;;
;; Why a task rather than a lock: a resource that only one task touches cannot
;; be raced for, and the queue in front of it is the scheduler's, which already
;; exists and is already right. The blitter is the cautionary tale - it was
;; shared, and a command block filled by two contexts at once wrote pixels
;; across a task's saved registers. Nothing about that was hard to fix once it
;; was found; the trouble was that the API let it be written at all.

(defrecord (server sv) (include node) port task poll)

(define (server-port s) (sv-port s))
(define (server-task s) (sv-task s))

;; Work that arrives as an edge rather than as a message: a device's interrupt
;; server notifies the server's own port, and `fn` runs each time the server
;; wakes. It is how a driver has one blocker and still hears both from its
;; device and from its clients.
(define (server-poll! s fn) (set-sv-poll! s fn) s)

(define (server-loop s handler)
  ;; A handler that fails answers its caller with the failure instead of
  ;; leaving it blocked, and the server goes back to its port on a clean
  ;; stack. That is the prompt's restart, for the prompt's reason: an error
  ;; abandons the stack it happened on, so the only way back is to start
  ;; again from the top.
  (let ((mark (task-binds)))
    (set! *repl-restart*
          (lambda ()
            (unwind-binds-to! mark)
            (let ((m (get-msg (sv-port s))))
              (if m (fail-msg m "the server failed while answering") nil))
            (server-run s handler))))
  (server-run s handler))

(define (server-run s handler)
  (let ((port (sv-port s)))
    (while t
      ;; Anything that arrived as an edge first - see `server-poll!`.
      (let ((poll (sv-poll s))) (if poll (%funcall poll) nil))
      ;; A message stays on the port until it has been answered, so that a
      ;; server which ends part way through one - removed, or failed - leaves
      ;; it where `rem-task` and the restart will find it, and its caller
      ;; hears.
      (let ((m (without-interrupts (list-first (mp-msglist port)))))
        (if (%null? m)
            (wait (mp-sigmask port))
            (let ((v (%funcall handler (mn-body m))))
              ;; The answer goes back in the message the caller sent, so a
              ;; request and its reply are one object and there is nothing to
              ;; match up at the other end. Off the port and answered in one
              ;; step: there is no moment at which it is on neither.
              (without-interrupts
                (remove-node m)
                (set-mn-body! m v)
                (reply-msg m))))))))

(define (make-server name pri handler . opts)
  ;; Forbid rather than a rendezvous: the port has to exist before the server
  ;; runs and before anybody can be handed the server to talk to, and not
  ;; being switched out is the simplest way to say that.
  (let ((s (sv-alloc)))
    (set-node-name! s name)
    (set-node-pri! s pri)
    (forbid)
    (let ((task (apply spawn
                       (list* name pri (lambda () (server-loop s handler)) opts))))
      (set-sv-task! s task)
      (set-sv-port! s (create-port-for task name pri)))
    (permit)
    s))

;; Every task has one reply port, because every task has one blocker: a task
;; that is waiting for an answer is waiting for *the* answer, so there is
;; never a second one outstanding to tell it apart from. Fanning out is done
;; by making more tasks, which is what `spawn` is for.
(define (reply-port)
  (if *reply-port*
      *reply-port*
      (begin (set! *reply-port* (create-port nil 0)) *reply-port*)))

(define (request port body)
  ;; Send, block, answer - or fail, if the task behind the port ends or its
  ;; handler fails before answering.
  (let* ((r (reply-port))
         (m (create-message body r)))
    (put-msg port m)
    ;; Until it comes back. A loop, for the signal an answer leaves behind
    ;; when it arrives before the `wait`: the next request's first `wait`
    ;; returns at once, finds nothing, and waits again.
    (while (%null? (get-msg r)) (wait (mp-sigmask r)))
    (let ((v (mn-body m)))
      (if (failure? v) (error "request:" (node-name port) (fl-why v)) v))))

(define (send port body)
  ;; No answer wanted, and no waiting.
  (put-msg port (create-message body nil))
  nil)

;; An edge rather than a message: something happened at this port. This is
;; what an interrupt server posts, because a server must not allocate, and it
;; is why a task can `wait` on a mask that spans device interrupts and message
;; ports without knowing which is which. One blocker; any number of sources.
(define (notify port)
  (let ((task (mp-sigtask port)))
    (if task (signal task (mp-sigmask port)) nil))
  nil)

(define (port-ready? p) (if (list-empty? (mp-msglist p)) nil t))

;; `select`, for a task that genuinely has to listen in several places -
;; usually a server with a control port beside its work port. Answers the
;; first port with something on it.
(define (wait-ports ports)
  (let ((mask 0) (hit nil))
    (dolist (p ports) (set! mask (%logior mask (mp-sigmask p))))
    (while (%null? hit)
      (dolist (p ports) (if (if hit nil (port-ready? p)) (set! hit p) nil))
      (if hit nil (wait mask)))
    hit))

;; ---------------------------------------------------------------- libraries
;; A library is reached through a jump table below its base pointer, which is
;; what makes the interface stable across versions: entry n always lives at
;; base minus 8n, whatever else changes. That table is raw memory and holds
;; only code addresses, so hand written code can jump through it and the
;; collector never has to look at it. The closures themselves live in a vector
;; in the record, where the collector finds them without being told.
(defrecord (library lib) (include node)
  version opencnt
  entries                        ; a vector of closures
  table)                         ; raw address of the jump table, or nil

(define (make-library name version entries)
  (let* ((n (length entries))
         (table (alloc-pool (%* 8 (%+ n 1))))
         (base (%+ table (%* 8 (%+ n 1))))
         (v (make-vector-n n nil))
         (lib (lib-alloc))
         (i 0))
    (set-node-name! lib name)
    (set-lib-version! lib version)
    (set-lib-opencnt! lib 0)
    (set-lib-entries! lib v)
    (set-lib-table! lib base)
    (dolist (fn entries)
      (%vector-set! v i fn)
      (poke (%- base (%* 8 (%+ i 1))) (closure-entry fn))
      (set! i (%+ i 1)))
    (without-interrupts (enqueue *lib-list* lib))
    lib))

(define (lvo lib n) (%vector-ref (lib-entries lib) (%- n 1)))

(define (open-library name version)
  (let ((lib (find-name *lib-list* name)))
    (if (%null? lib)
        nil
        (if (%< (lib-version lib) version)
            nil
            (begin
              (set-lib-opencnt! lib (%+ (lib-opencnt lib) 1))
              lib)))))

(define (close-library lib)
  (if lib
      (set-lib-opencnt! lib (%- (lib-opencnt lib) 1))
      nil)
  nil)

;; ---------------------------------------------------------------- interrupts
(defrecord (interrupt is) (include node)
  code                           ; a Lisp closure taking the data
  data)

(define (make-interrupt name pri code data)
  (let ((i (is-alloc)))
    (set-node-name! i name)
    (set-node-pri! i pri)
    (set-is-code! i code)
    (set-is-data! i data)
    i))

;; ---------------------------------------------------------------- vblank
;; One signal bit, the same in every task, so that waking every waiter is a
;; walk of the wait list rather than a registry somebody has to maintain.
;; `alloc-signal` hands out bits from 16 up, which leaves the low half for
;; things like this.
;; The bit and the mask, said once each: `sigf-` is `sigb-` shifted, and a
;; `define` is evaluated when it is compiled, so this costs nothing.
(define sigb-vblank 5)
(define sigf-vblank (%lsh 1 sigb-vblank))
(define sigb-input 6)
(define sigf-input (%lsh 1 sigb-input))
(define sigb-blit 7)                   ; your blits have landed; see gfx.lisp
(define sigf-blit (%lsh 1 sigb-blit))
(define *vblank-int* nil)
(define *vblank-count* 0)

(define (vblank-server data)
  ;; Runs inside the interrupt handler, so it allocates nothing and takes the
  ;; successor before Signal moves the task off the list it is standing on.
  (set! *vblank-count* (%+ *vblank-count* 1))
  (let ((p (list-first (wait-list))))
    (while p
      (let ((next (node-next p)))
        (if (%> (%logand (tc-sigwait p) sigf-vblank) 0)
            (signal p sigf-vblank)
            nil)
        (set! p next))))
  nil)

;; Sleep until the display has finished a frame.
;;
;; This is what a drawing task should do instead of rescheduling: a redraw
;; that runs more often than the screen is shown is work nobody sees, and on a
;; preemptive machine it is work taken from somebody who needed it. A task
;; waiting here is off the ready list entirely, so it costs nothing until the
;; frame arrives.
(define (wait-vblank) (wait sigf-vblank))

;; ---------------------------------------------------------------- idle
;; Something always has to be ready to run, and this is it.
;;
;; Without it, a machine where every task is waiting has an empty ready list,
;; and `switch-tasks` quietly declines to switch - so the task that just
;; declared itself asleep carries on executing. `wait` then goes round its loop
;; and adds itself to the wait list a second time, which is a doubly linked
;; list with one node in it twice, which is the end of the scheduler. Nothing
;; noticed while every task was a spin loop; the moment they started really
;; blocking it became reachable.
;;
;; It runs `wfi`, so an idle machine costs nothing at all rather than costing
;; one task's worth of spinning.
(define (idle-task)
  (while t
    (set! *idle-count* (%+ *idle-count* 1))
    (%wait-for-input)))

(define (idle-start)
  (if *idle-task*
      nil
      (set! *idle-task* (add-task "idle" -128 (lambda () (idle-task)) 4096)))
  *idle-task*)

(define (idle? task) (%eq? task *idle-task*))

(define (vblank-start)
  (if *vblank-int*
      nil
      (begin
        (set! *vblank-int*
              (make-interrupt "vblank" 0 (lambda (d) (vblank-server d)) 0))
        ;; Only the kernel's end of the line. Telling the display chip to
        ;; raise it is gfx.driver's business: the chip is the driver's.
        (add-int-server int-vblank *vblank-int*)))
  *vblank-int*)

(define (add-int-server line int)
  (without-interrupts
    (enqueue (int-vector line) int)
    (int-enable line))
  int)

(define (rem-int-server line int)
  (without-interrupts
    (remove-node int)
    (if (list-empty? (int-vector line)) (int-disable line) nil))
  nil)

;; Cause is Exec's software interrupt: run something soon, but not here.
(define (cause int)
  (add-int-server int-soft int)
  (int-raise int-soft)
  nil)

;; The guard is for one window and it is a real one. A rebuild recompiles
;; exec.lisp into the machine that is running it, and every top level `define`
;; in this file resets a kernel variable as it goes - so for a moment there is
;; no vector of server lists, and an interrupt arriving then has nothing to
;; run. It used to survive that by accident: `int-vector` computed a low
;; address out of a base of zero, and low memory is zeroed, so the list read
;; as empty. Now it says so.
(define (run-int-servers line)
  (if (%null? *int-vectors*) nil (run-int-servers-1 line)))

(define (run-int-servers-1 line)
  (let ((p (list-first (int-vector line))))
    (while p
      (let ((code (is-code p))
            (data (is-data p)))
        (if code (%funcall code data) nil))
      (set! p (node-next p)))))

;; ---------------------------------------------------------------- dispatch
;; Everything that interrupts the machine arrives here, on the trap stack,
;; with the interrupted task's registers already in its context block.
(define (handle-interrupt n ctx)
  ;; Saying which context this is, and nothing else. `blit-block` refuses in
  ;; interrupt context and `wait` refuses too: a server does not draw and does
  ;; not block, it signals a task and returns.
  ;;
  ;; This flag is safe to set this way only because it is cleared before the
  ;; handler returns, and no other task runs until it does.
  (set! *in-interrupt* t)
  (handle-interrupt-1 n ctx)
  (set! *in-interrupt* nil)
  nil)

(define (handle-interrupt-1 n ctx)
  (cond
   ((%= n int-timer)
    (set! *disp-count* (%+ *disp-count* 1))
    (timer-set-in *quantum*)
    (switch-tasks))
   ((%= n int-external)
    ;; Ask the chips which line it was, service every server on it, then
    ;; acknowledge. Servers run with interrupts still off.
    (let ((line (int-pending)))
      (while (%>= line 0)
        (run-int-servers line)
        (int-ack line)
        (set! line (int-pending))))
    ;; A server that woke a task of higher priority than the one it
    ;; interrupted hands the processor over now rather than at the next tick.
    ;; That is what makes a driver answer when its device does, instead of up
    ;; to a quantum later - and a compositor draw when the frame starts.
    (if (%> *attn-resched* 0)
        (begin (set! *attn-resched* 0) (switch-tasks))
        nil))
   ((%= n int-software) (switch-tasks))
   (else nil))
  nil)

;; ---------------------------------------------------------------- residents
;; What Exec starts when it starts: the drivers. A driver's file says so when
;; it is loaded, and `exec-init` starts every one - at a cold boot, and again
;; after a resume, which is the other time a driver's task has to be made from
;; nothing. AmigaOS found these by scanning ROM for a RomTag; here one is a
;; name and a function, and adding one under a name already there replaces
;; it, which is what loading a driver's file again means.
(define *residents* nil)

(define (add-resident name start)
  (let ((keep nil))
    (dolist (r *residents*)
      (if (string=? (%car r) name) nil (set! keep (%cons r keep))))
    (set! *residents* (reverse (%cons (%cons name start) keep))))
  nil)

(define (start-residents)
  (dolist (r *residents*) (%funcall (%cdr r)))
  nil)

;; ---------------------------------------------------------------- startup
(define (exec-init)
  ;; A resumed image arrives with this still set, naming an interrupt
  ;; structure that belonged to the ExecBase this is about to replace.
  ;; Believing it means never installing the server into the new one, and a
  ;; machine with no vblank. The drivers see to their own: `start-residents`.
  (set! *vblank-int* nil)
  ;; And these, which a resumed image also arrives with: counts and flags that
  ;; described an Exec that no longer exists. When they lived in a structure,
  ;; allocating a fresh one zeroed them all at once; now that they are
  ;; variables, saying so is the price of not having a base pointer.
  (%set-this-task! nil)
  (set! *idle-task* nil)
  (set! *tdnest* 0)
  (set! *attn-resched* 0)
  (set! *disp-count* 0)
  (set! *switch-count* 0)
  (set! *idle-count* 0)
  (set! *task-count* 0)
  (set! *ready-list* (new-list))
  (set! *wait-list* (new-list))
  (set! *lib-list* (new-list))
  (set! *port-list* (new-list))
  (set! *int-vectors* (make-vector-n 8 nil))
  (let ((i 0))
    (while (%< i 8)
      (%vector-set! *int-vectors* i (new-list))
      (set! i (%+ i 1))))
  (set! *quantum* default-quantum)
  (begin
    ;; The code that is already running becomes task zero. Its context is the
    ;; block the trap stub has been using all along, so it is already correct.
    (let ((boot (tc-alloc)))
      (set-node-name! boot "boot")
      (set-node-pri! boot 0)
      (zero-task-counters! boot)
      (set-tc-quantum! boot default-quantum)
      (set-tc-state! boot ts-run)
      (set-tc-context! boot (%global lg-trapsave))
      (set-tc-splower! boot (%global lg-stackbot))
      (set-tc-spupper! boot (%global lg-stacktop))
      (set-tc-sigalloc! boot 65535)
      ;; Task zero takes whatever was bound before there were tasks, which
      ;; is what it has been using all along.
      (set-tc-binds! boot *boot-binds*)
      (set! *boot-binds* nil)
      (install-task-binds!)
      (%set-this-task! boot)
      (set! *task-count* 1))

    (build-task-exit-stub)
    ;; Now the two things sys.lisp had to leave blank: a task restarts on its
    ;; own stack, and a task that faults with no prompt behind it ends rather
    ;; than halting the machine.
    (set! *stack-top-fn* (lambda () (tc-spupper (this-task))))
    (set! *return-addr-fn* (lambda () *task-exit-stub*))
    (vblank-start)
    (idle-start)
    (set! *abort-cleanup-fn*
          (lambda ()
            (set! *tdnest* 0)
            (set! *attn-resched* 0)
            ;; A fault inside an interrupt server never reaches the line that
            ;; clears this, and a machine that believes it is permanently
            ;; inside a handler refuses every Wait after.
            (set! *in-interrupt* nil)))
    (set! *task-abort-fn*
          (lambda ()
            (emit-str "task ended by an error\n")
            (task-finished)))
    ;; And the drivers, last, once a task that fails has somewhere to go.
    (start-residents)
    *ready-list*))

;; Stop the clock driving the scheduler. Nothing else changes: tasks still
;; switch when they ask to, signals still work, interrupts still arrive. What
;; stops is being taken off the processor against your will.
;;
;; There is one caller and it is the one that needs it. A rebuild recompiles
;; exec.lisp into the machine it is running on, and every `(define *tdnest* 0)`
;; in it is a top level form like any other: for the rest of that rebuild the
;; kernel's state resets under it, one variable at a time. Nothing notices as
;; long as nothing calls into the kernel - and a timer interrupt is exactly
;; that call, arriving unasked.
;; Forbid is not this. Forbid stops the *scheduler* from taking the processor
;; away, and leaves the interrupts on - a server still runs, and a server calls
;; into the kernel, which is exactly what must not happen while a rebuild is
;; redefining the kernel's variables one `define` at a time. This turns the
;; sources of those calls off.
(define (preemption-off)
  ;; The chips too, not just the clock. Every top level `define` in this file
  ;; resets a kernel variable as the rebuild goes past, so for a moment there
  ;; is no ready list, no server list and no current task. An interrupt
  ;; arriving in that window used to enqueue a task into address zero and get
  ;; away with it, because a base pointer of zero plus a small offset is low
  ;; memory and low memory is zeroed. It says so now, which is an improvement
  ;; - and the answer is for it not to arrive.
  (timer-never)
  (int-disable int-vblank)
  (int-disable int-input)
  nil)

;; And back on, for a caller that wants the machine afterwards. `rebuild` does
;; not: by the time it returns it has overwritten the kernel it would be
;; handing back to, and the image it writes turns preemption on for itself.
(define (preemption-on)
  (int-enable int-vblank)
  (int-enable int-input)
  (timer-set-in *quantum*)
  nil)

(define (exec-start)
  ;; Turn on preemption. From here the timer interrupt drives the scheduler.
  (timer-set-in *quantum*)
  (%enable-timer)
  (%enable)
  nil)


;; ---------------------------------------------------------------- gc roots
;; Exec structures live in the pool, which the collector does not scan, so the
;; kernel has to hand over the Lisp values it is holding. Nothing here may
;; allocate: these run inside a collection, so the list walks are done by hand
;; rather than through list-nodes, which conses.

;; A collection moved every pair, so every run any task was holding describes
;; the wrong part of the heap. Zeroing the saved pair of registers is enough:
;; the allocator checks for room before it stores anything, finds none, and
;; asks for a fresh chunk. The task that is running gets the same treatment
;; from `%reload-cons-run`.
(define (drop-task-run task)
  (let ((ctx (tc-context task)))
    (if (if ctx (%> ctx 0) nil)
        (begin (poke (ctx-reg ctx reg-gp) 0)
               (poke (ctx-reg ctx reg-tp) 0))
        nil)))

(define (gc-invalidate-runs)
  (if *ready-list*
      (begin
        (gc-scan-list-of *ready-list* drop-task-run)
        (gc-scan-list-of *wait-list* drop-task-run))
      nil)
  nil)

(define (gc-scan-task task)
  ;; The task itself is an object and the collector has already traced its
  ;; name, its function and its environment on the way in. What it cannot see
  ;; is the stack the task was suspended on and the register block it was
  ;; suspended into: both are raw pool memory, and this is what walks them.
  (let ((ctx (tc-context task)))
    (if (if ctx (%> ctx 0) nil)
        (begin
          ;; Its stack, precisely, from where it was suspended.
          (gc-scan-frames (%ld-fixnum (%+ ctx (%* 4 reg-sp)))
                          (%ld-fixnum (%+ ctx (%* 4 8))))
          ;; And its saved registers. This is the one place left that has to
          ;; guess: a task preempted mid-expression has live values in
          ;; registers whose types nothing recorded. Thirty-two words per
          ;; suspended task, and the compactor pins whatever they reach.
          (gc-scan-conservative ctx (%+ ctx ctx-bytes)))
        nil)))

(define (gc-scan-list-of l fn)
  (let ((p (list-first l)))
    (while p
      (%funcall fn p)
      (set! p (node-next p)))))

;; Everything Exec owns is now an object hanging off a variable, so the
;; collector finds the tasks, the ports, the messages, the libraries and the
;; interrupt servers - and every Lisp value in them - without being told. What
;; is left here is the part it genuinely cannot reach on its own: the raw
;; stacks and register blocks the tasks were suspended on.
(define (gc-extra-roots)
  (if *ready-list*
      (begin
        (gc-scan-list-of *ready-list* gc-scan-task)
        (gc-scan-list-of *wait-list* gc-scan-task))
      nil))

(define (uptime) *disp-count*)
(define (switch-count) *switch-count*)
(define (task-count) *task-count*)
