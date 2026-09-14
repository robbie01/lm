;;; exec.lisp - an Amiga Exec, in Lisp.
;;;
;;; One shared address space, no protection, no MMU. Message passing costs a
;;; pointer on a list, because there is nothing to copy it between.
;;;
;;; The structures are Exec's: doubly linked lists with sentinel nodes at both
;;; ends so that insert and remove need no special cases; tasks with 32 signal
;;; bits and Wait/Signal; message ports on top of signals; mutexes that belong
;;; to the task holding them. There is no ExecBase, the lists are records
;;; held in variables, and no Forbid: data tasks share is guarded by a mutex
;;; or owned by one task and reached through its port, and the kernel's own
;;; few-instruction sections turn interrupts off.
;;;
;;; The context switch is one CSR write. The trap stub saves all 32 registers
;;; into the block mscratch points at and restores from there on the way out,
;;; so switching tasks is pointing mscratch at a different task's context.

(in-package exec)

;; ---------------------------------------------------------------- Node
;; Everything on one of Exec's lists starts with the same four slots. A task
;; pointer somebody keeps is either a live task or a dead one that says it is
;; removed and ignores its signals: nothing frees a record, so a kept
;; reference can never come back as a different task. `open`, because a list
;; holds tasks, ports and interrupts at once and has to be walkable by the
;; node accessors alone.
(defrecord (node open) succ pred pri name)

;; A node's tag says what kind of thing is on the list.
(define (make-node tag) (make-record node-slots tag))
(define (node-tag n) (record-tag n))

;; ---------------------------------------------------------------- List
;; A header owning two sentinel nodes, one before the first real node and one
;; after the last. Exec packs them into three words by pointing four bytes
;; into the header, which this machine cannot represent, since four bytes past an
;; object reference reads as a cons, so they are real nodes here.
(defrecord (exec-list list) head tail)

(define (new-list)
  (let ((l (list-alloc))
        (h (make-node 'list-head))
        (tl (make-node 'list-tail)))
    (set-list-head! l h)
    (set-list-tail! l tl)
    ;; The tail sentinel's successor is nil, which is what ends a walk.
    (set-node-succ! h tl)
    (set-node-pred! tl h)
    l))

(define (list-empty? l) (%eq? (node-succ (list-head l)) (list-tail l)))
(define (list-first l) (if (list-empty? l) nil (node-succ (list-head l))))

;; The next real node, or nil: walkers never see a sentinel.
(define (node-next n)
  (let ((s (node-succ n)))
    (if (%null? (node-succ s)) nil s)))

;; Four writes and no test: p may be the tail sentinel and its predecessor
;; the head sentinel.
(define (insert-before p n)
  (let ((prev (node-pred p)))
    (set-node-succ! n p)
    (set-node-pred! n prev)
    (set-node-succ! prev n)
    (set-node-pred! p n)
    n))

(define (add-head l n) (insert-before (node-succ (list-head l)) n))
(define (add-tail l n) (insert-before (list-tail l) n))

;; Taking a node out clears its own links, which makes removal idempotent.
;; A second removal of a node whose links still named its old neighbours
;; would splice those two together and lose whatever had been inserted
;; between them since, and a second removal is normal: `switch-tasks` takes a
;; task off the ready list, and reaping it when it ends removes it again.
(define (remove-node n)
  (let ((s (node-succ n))
        (p (node-pred n)))
    (if (if s p nil)
        (begin (set-node-succ! p s) (set-node-pred! s p))
        nil)
    (set-node-succ! n nil)
    (set-node-pred! n nil)
    n))

;; The same, spelled for a node that is finished with. Clearing the links is
;; what stops a node somebody still holds from keeping the rest of its list
;; alive.
(define (forget-node n) (remove-node n))

(define (remove-head l)
  (if (list-empty? l) nil (remove-node (list-first l))))

;; Insert by priority, after every node of equal or higher priority, so that
;; equal priorities keep their arrival order.
(define (enqueue l n)
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

;; The nodes as a Lisp list, for inspection.
(define (list-nodes l)
  (let ((p (list-first l)) (acc nil))
    (while p
      (set! acc (%cons p acc))
      (set! p (node-next p)))
    (reverse acc)))

;; ---------------------------------------------------------------- Task
;; The stack and the 128-byte register context are raw pool memory: the trap
;; stub writes the context as thirty-two untagged words, and a record's slots
;; are tagged values.
(defrecord (task tc) (include node)
  state sigalloc sigwait sigrecvd
  splower spupper                ; raw addresses, held as fixnums
  context                        ; 128-byte register block, raw
  fn                             ; the closure the task runs
  result switches
  binds                          ; this task's fluid bindings, innermost first
  quantum elapsed
  parent children                ; a dependent task ends with the one that made it
  cleanups                       ; what to do when it ends, newest first
  base                           ; its own priority, which a waiter may add to
  held                           ; the mutexes it owns, newest first
  blocked-on                     ; the mutex it is waiting for, if any
  mx-next                        ; and who is behind it in that mutex's queue
  run-owed                       ; bytes of cons run handed to it, unpaid; see gc.lisp
  gen)                           ; which Exec it belongs to: see `task-alive?`

(define ts-invalid 0)
(define ts-added 1)
(define ts-run 2)
(define ts-ready 3)
(define ts-wait 4)
(define ts-except 5)
(define ts-removed 6)

;; ---------------------------------------------------------------- the kernel
(define *idle-task* nil)
(define *ready-list* nil)
(define *wait-list* nil)
(define *port-list* nil)
(define *int-vectors* nil)     ; a vector of eight lists
(define *attn-resched* 0)      ; a switch owed to a more urgent task
(define *quantum* 0)
(define *disp-count* 0)
(define *switch-count* 0)
(define *idle-count* 0)
(define *task-count* 0)

;; Which task is running is the register s2, which the trap stub saves and
;; restores with the rest, so the scheduler carries it for nothing. It is nil
;; before there is an Exec.
(define (this-task) (%this-task))
(define (ready-list) *ready-list*)
(define (wait-list) *wait-list*)
(define (int-vector n) (%vector-ref *int-vectors* n))

;; ---------------------------------------------------------------- critical
;; `without-interrupts` is for what an interrupt server touches, the
;; scheduler's lists, the signal bits, the pool free list, and for the
;; kernel's own sections of a few dozen instructions, the mutex's among them.
;; Nothing sleeps inside it: whatever would wake a sleeping task is another
;; task or an interrupt, which is what it holds off, so `wait`, `reschedule`,
;; taking a mutex and the running task ending itself are errors there (see
;; `sleep-check`). A print inside one goes straight to the serial line.
;;
;; Data tasks share, and any section that may have to wait, wants a mutex;
;; talking to another task wants a port.

;; A task this one has just woken, or has just dropped its own priority
;; below, is owed the processor as soon as the kernel's own section is over.
;; `signal` and `repri!` note the debt and the operations that can run one up
;; pay it on the way out.
(define (yield-if-owed)
  (if (if (%> *attn-resched* 0) (if *in-interrupt* nil (interrupts-on?)) nil)
      (begin (set! *attn-resched* 0) (reschedule))
      nil))

;; Interrupts are only a question once Exec has turned them on: the boot task
;; runs with them off until then.
(define *exec-started* nil)

;; One more every time `exec-init` runs: at a cold boot, and again after a
;; resume, which throws the old Exec's tasks away.
(define *exec-generation* 0)

;; Whether the running task may sleep here. Asked even when it would not have
;; to sleep this time, so that a section that sleeps is an error the first
;; time it runs.
(define (sleep-check what)
  (cond (*in-interrupt*
         (error (string-append what " cannot sleep in an interrupt server: signal a task instead")))
        ((if *exec-started* (if (interrupts-on?) nil t) nil)
         (error (string-append what " would sleep inside without-interrupts, where nothing can arrive to wake it")))
        (else nil)))

;; ---------------------------------------------------------------- scheduler
;; A reschedule is an ecall, so the switch happens inside the trap handler
;; where the whole register set is already saved. Not with interrupts off: a
;; task's saved context does not hold the interrupt enable, so the task
;; switched to would start deaf.
(define (reschedule)
  (if (if *exec-started* (if (interrupts-on?) nil t) nil)
      (error "reschedule: inside without-interrupts, where the next task would start with them off")
      nil)
  (%ecall ecall-reschedule))

;; ---------------------------------------------------------------- fluids
;; Where a fluid binding goes: onto the running task's own stack, so that the
;; scheduler swaps it with the registers. Before this is installed, and in a
;; trap where there is no task to speak of, there is one stack.
(define (install-task-binds!)
  (set! *binds-get* (lambda () (let ((t (this-task))) (if t (tc-binds t) *boot-binds*))))
  (set! *binds-set*
        (lambda (v)
          (let ((t (this-task)))
            (if t (set-tc-binds! t v) (set! *boot-binds* v))))))

;; What a new task starts out holding: whatever its creator holds now, so a
;; shell's children talk to the shell's window. One entry per place, which is
;; the shape a suspended task's stack has.
(define (initial-binds)
  (list (%cons '*out* *out*)
        (%cons '*in* *in*)
        (%cons '*await* *await*)
        (%cons '*peeked* nil)
        (%cons '*repl-restart* nil)
        (%cons 'package (current-package))
        ;; Blitter descriptors of its own, made the first time it blits.
        (%cons '*blit-ring* 0)
        ;; One reply port, made the first time it asks a server for something:
        ;; a task has one blocker and therefore one conversation.
        (%cons '*reply-port* nil)))

(define *reply-port* nil)   ; per task; see `initial-binds` and `reply-port`

;; Dead tasks waiting to be reclaimed. A task cannot free the stack it is
;; standing on, so it goes on this list and the next context switch does the
;; work, on the trap stack, once the corpse is saved and will never resume.
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
  (let* ((cur (this-task))
         (head (list-first (ready-list)))
         ;; A task still able to run keeps the processor against anything
         ;; less urgent: the tick is for its equals, in turn, and its
         ;; betters. Without this the idle task, always ready, took every
         ;; other quantum from a busy machine.
         (next (if (if head
                       (if (%= (tc-state cur) ts-run)
                           (%< (node-pri head) (node-pri cur))
                           nil)
                       nil)
                   nil
                   (remove-head (ready-list)))))
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
                (%set-context! (tc-context next))
                (%set-stack-limit! (task-stack-limit next))
                ;; Only now, with the context switched away, is a dead task's
                ;; stack safe to give back.
                (if *reaped* (reap-tasks) nil)))
    nil))

;; ---------------------------------------------------------------- signals
;; Three bits are fixed, the same in every task, so that waking every waiter
;; is a walk of the wait list: the vertical blank, the blitter, and a mutex
;; handed over. Every other bit from 0 to 29 is for allocation. Bit 30 is
;; not: a mask is a fixnum, and a fixnum with bit 30 set is negative, which
;; the tests below would misread.
(define sigb-vblank 5)
(define sigf-vblank (%lsh 1 sigb-vblank))
(define sigb-blit 7)                   ; your blits have landed; see gfx.lisp
(define sigf-blit (%lsh 1 sigb-blit))
(define sigb-mutex 8)                  ; you have been handed a mutex
(define sigf-mutex (%lsh 1 sigb-mutex))
(define sigb-timer 9)                  ; your deadline has passed; see `wait-timeout`
(define sigf-timer (%lsh 1 sigb-timer))
(define sig-reserved
  (%logior sigf-vblank (%logior sigf-blit (%logior sigf-mutex sigf-timer))))

;; What comes back is the mask, because that is what `signal` and `wait`
;; take. The failure is raised outside the critical section, because an
;; error abandons the stack and would abandon the section with it.
(define (alloc-signal task)
  (let ((got (without-interrupts
               (let ((alloc (tc-sigalloc task)) (n 0) (g -1))
                 (while (if (%< n 30) (%< g 0) nil)
                   (if (%= 0 (%logand alloc (%lsh 1 n)))
                       (begin
                         (set-tc-sigalloc! task (%logior alloc (%lsh 1 n)))
                         ;; Cleared, as AllocSignal does: the bit can still be
                         ;; set from its last owner, and a signal that arrives
                         ;; already received makes the first wait return at
                         ;; once.
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

(define (signal task mask)
  (if (task? task) nil (error "signal: not a task" task))
  (without-interrupts
    (set-tc-sigrecvd! task (%logior (tc-sigrecvd task) mask))
    (if (%= (tc-state task) ts-wait)
        (if (%= 0 (%logand (tc-sigrecvd task) (tc-sigwait task)))
            nil
            (begin
              (remove-node task)
              (task-ready! task)
              ;; A woken task of higher priority gets the processor now.
              (if (%> (node-pri task) (node-pri (this-task)))
                  (set! *attn-resched* 1)
                  nil)))
        nil))
  nil)

;; Block until one of the signals in the mask arrives, then take those bits
;; and leave the rest for the next wait.
;;
;; This is the one critical section that is not lexical: it is opened here,
;; released around the reschedule that blocks, and taken again on the way
;; back. The task goes on the wait list once and stays there until `signal`
;; takes it off, which it only does when a bit this task asked for has
;; arrived; coming back round the loop still waiting means still being on
;; the list. Interrupts go on for the reschedule and off again after it: a
;; task's saved context does not hold the interrupt enable, so the task that
;; runs next gets whatever the reschedule was asked for in.
(define (wait mask)
  (sleep-check "wait:")
  (if (%= mask 0) (error "wait: an empty mask would sleep for ever") nil)
  (let ((entry (%disable)))
    (let ((task (this-task)) (got 0))
      (set! got (%logand (tc-sigrecvd task) mask))
      (if (%= got 0)
          (begin
            (set-tc-sigwait! task mask)
            (set-tc-state! task ts-wait)
            (add-tail (wait-list) task)
            (while (%= got 0)
              (%restore-interrupts 1)
              (reschedule)
              (%disable)
              (set! got (%logand (tc-sigrecvd task) mask))))
          nil)
      (set-tc-sigrecvd! task
                    (%logand (tc-sigrecvd task) (%lognot got)))
      (set-tc-sigwait! task 0)
      (%restore-interrupts entry)
      got)))

;; ---------------------------------------------------------------- time
;; A task can wait for a moment as well as for a signal. Time here is the
;; machine's own: the timer interrupt fires every quantum, and counting the
;; ticks gives a clock that runs at the same rate in idle jumps and under
;; load, and the same on every run. Deadlines are ticks, on one list soonest
;; first, and the interrupt signals whoever's has passed, so a deadline is
;; met within a quantum of when it was set, the scheduler's own resolution.
;; A task that draws waits for the vertical blank instead, which is finer and
;; in step with the screen. `millis` in hw is the host's clock, for pacing
;; to the host, and is not this.
(define *ticks* 0)                     ; timer interrupts since Exec started
(define *ms-per-tick* 10)              ; set from the quantum at exec-init

(define (now-ms) (%* *ticks* *ms-per-tick*))

(define (ticks-for ms)
  (let ((n (%/ (%+ ms (%- *ms-per-tick* 1)) *ms-per-tick*)))
    (if (%< n 1) 1 n)))

(define *deadlines* nil)               ; ((when . task) ...)

(define (add-deadline! task when)
  (let ((cell (%cons (%cons when task) nil)))
    (if (if (%cons? *deadlines*) (%< (%car (%car *deadlines*)) when) nil)
        (let ((p *deadlines*))
          (while (if (%cons? (%cdr p)) (%<= (%car (%car (%cdr p))) when) nil)
            (set! p (%cdr p)))
          (%set-cdr! cell (%cdr p))
          (%set-cdr! p cell))
        (begin (%set-cdr! cell *deadlines*) (set! *deadlines* cell)))))

(define (drop-deadline! task)
  (let ((keep nil))
    (dolist (d *deadlines*) (if (%eq? (%cdr d) task) nil (set! keep (%cons d keep))))
    (set! *deadlines* (reverse keep))))

;; From the timer interrupt, with interrupts off: allocates nothing.
(define (fire-deadlines)
  (if (%cons? *deadlines*)
      (let ((now *ticks*))
        (while (if (%cons? *deadlines*) (%<= (%car (%car *deadlines*)) now) nil)
          (signal (%cdr (%car *deadlines*)) sigf-timer)
          (set! *deadlines* (%cdr *deadlines*))))
      nil))

;; `wait`, but for at most `ms` milliseconds: answers the signals that came,
;; and 0 if the time passed first.
(define (wait-timeout mask ms)
  (sleep-check "wait-timeout:")
  (let ((me (this-task)))
    (without-interrupts
      ;; a timer signal left from an earlier wait must not end this one early
      (set-tc-sigrecvd! me (%logand (tc-sigrecvd me) (%lognot sigf-timer)))
      (add-deadline! me (%+ *ticks* (ticks-for ms))))
    (let ((got (wait (%logior mask sigf-timer))))
      (without-interrupts
        (drop-deadline! me)
        (set-tc-sigrecvd! me (%logand (tc-sigrecvd me) (%lognot sigf-timer))))
      (%logand got mask))))

(define (sleep ms) (wait-timeout 0 ms) nil)

;; ---------------------------------------------------------------- tasks
;; Slot 0 of a closure holds a raw code address, so it is read with %addr-of
;; rather than %from-addr: the word is already an address.
(define (closure-entry fn) (%addr-of (%ld-word (%addr-of fn))))

(define default-stack 65536)
(define default-quantum 200000)

;; How far above the bottom of its stack a task is stopped. The processor
;; faults when the stack pointer goes below the limit with interrupts on; the
;; reserve under it is for code that runs with them off, the collector, the
;; allocator, the kernel's lists, which can be entered with the stack nearly
;; full and has to finish. A small stack keeps a quarter of itself.
(define stack-reserve 8192)

(define (task-stack-limit task)
  (let* ((lo (tc-splower task))
         (quarter (%lsh (%- (tc-spupper task) lo) -2)))
    (%+ lo (if (%< quarter stack-reserve) quarter stack-reserve))))

;; A fresh record's slots hold nil, and nil is not the fixnum zero, so
;; anything counted or masked is set before it is read.
(define (zero-task-counters! task)
  (set-tc-run-owed! task 0)
  (set-tc-sigwait! task 0)
  (set-tc-sigrecvd! task 0)
  (set-tc-switches! task 0)
  (set-tc-elapsed! task 0)
  (set-tc-result! task 0)
  nil)

;; A task made and not yet started: on no list, so nothing runs it until
;; `start-task` does. `make-server` needs the gap, to give the task its port
;; before it can run.
(define (make-task name pri fn . opts)
  (let* ((binds (initial-binds))
         (stack (if (%cons? opts) (%car opts) default-stack))
         (task (tc-alloc))
         (ctx (alloc-pool ctx-bytes))
         (sp (alloc-pool stack)))
    (set-node-name! task name)
    (set-node-pri! task pri)
    (set-tc-base! task pri)
    (set-tc-gen! task *exec-generation*)
    (zero-task-counters! task)
    (set-tc-state! task ts-added)
    (set-tc-splower! task sp)
    (set-tc-spupper! task (%+ sp stack))
    (set-tc-context! task ctx)
    (set-tc-fn! task fn)
    (set-tc-binds! task binds)
    (set-tc-quantum! task default-quantum)
    (set-tc-sigalloc! task sig-reserved)
    ;; The context is built to look as though the task had just been
    ;; interrupted on the first instruction of its function.
    (poke (ctx-pc ctx) (closure-entry fn))
    (poke (ctx-reg ctx reg-sp) (%+ sp stack))
    (poke (ctx-reg ctx reg-ra) *task-exit-stub*)
    ;; s2 says which task is running, so the context carries it the way it
    ;; carries the stack pointer.
    (%st-word! (ctx-reg ctx reg-s2) task)
    (%st-word! (ctx-reg ctx reg-t0) fn)
    (poke (ctx-reg ctx reg-t1) 0)
    task))

;; Onto the ready list: from here it runs when the scheduler says so.
(define (start-task task)
  (without-interrupts
    (task-ready! task)
    (set! *task-count* (%+ *task-count* 1)))
  task)

(define (add-task name pri fn . opts)
  (start-task (apply make-task name pri fn opts)))

;; What the forge handed out before the machine ran has no header and was
;; never meant to come back.
(define (free-if-ours p)
  (if (if p (%> p 0) nil)
      (if (%= (%ld-fixnum (%+ p -4)) pool-tag) (free-pool p) nil)
      nil))

;; A dependent task: removed when the task that made it is, so a server that
;; fans work out does not have to remember what it started. A parent holds
;; its children, so a child cannot outlive the list it is on.
(define (spawn name pri fn . opts)
  (start-task (apply make-child name pri fn opts)))

(define (make-child name pri fn . opts)
  (let ((child (apply make-task name pri fn opts))
        (me (this-task)))
    (if me
        (without-interrupts
          (set-tc-parent! child me)
          (set-tc-children! me (%cons child (tc-children me))))
        nil)
    child))

(define (task-children task) (tc-children task))
(define (task-parent task) (tc-parent task))

;; Depth first, with the list taken before anything is removed: removing a
;; child runs this again for its own children, and a child that ended by
;; itself is already off its parent's list.
(define (remove-children task)
  (let ((cs (without-interrupts
              (let ((c (tc-children task)))
                (set-tc-children! task nil)
                c))))
    (while (%cons? cs)
      (let ((c (%car cs)))
        (if (%= (tc-state c) ts-removed) nil (remove-task c)))
      (set! cs (%cdr cs))))
  nil)

;; A task that ends takes itself off its parent's list.
(define (forget-child task)
  (let ((p (tc-parent task)))
    (if p
        (without-interrupts
          (set-tc-children! p (remove-eq task (tc-children p)))
          (set-tc-parent! task nil))
        nil))
  nil)

;; Something to do when a task ends, however it ends. What a driver holds
;; that is not a device, its interrupt server, is given back this way.
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

;; Make a task nobody's dependent, so it outlives whoever started it: a
;; resident driver is started by the task that brought Exec up.
(define (detach-task task) (forget-child task) task)

;; A task that has ended stays a task and says so. The running task ending
;; itself leaves the processor, which nothing can do from inside a section.
(define (remove-task task)
  (if (%eq? task (this-task)) (sleep-check "remove-task of the running task:") nil)
  (remove-children task)
  (forget-child task)
  ;; What it held goes to whoever is waiting, marked abandoned, before its
  ;; cleanups run: a cleanup may want the very thing it held.
  (abandon-mutexes task)
  (release-devices-of task)
  (run-cleanups task)
  (without-interrupts
    ;; one that was made and never started was never counted
    (if (%= (tc-state task) ts-added) nil (set! *task-count* (%- *task-count* 1)))
    (set-tc-state! task ts-removed))
  ;; Anybody still waiting on an answer from it gets one. After the mark, so
  ;; that nothing can queue behind the last of these: `put-message` checks the
  ;; same mark.
  (fail-ports-of task)
  (if (%eq? task (this-task))
      (begin
        ;; It cannot free its own stack while standing on it: onto the reaper
        ;; list, and the switch that takes it off the processor frees it.
        (set! *reaped* (%cons task *reaped*))
        (reschedule)
        nil)
      (begin (reap-task task) nil)))

;; The stack and the register context are pool memory, given back by hand.
;; The task itself is an object, collected when the last reference goes; its
;; links go first so that a task somebody still holds does not keep every
;; task behind it alive.
(define (reap-task task)
  (forget-node task)
  (free-if-ours (tc-splower task))
  (free-if-ours (tc-context task))
  (set-tc-splower! task nil)
  (set-tc-context! task nil)
  nil)

(define (find-task name)
  (let ((f (find-name (ready-list) name)))
    (if f f (find-name (wait-list) name))))

(define (task-name task) (node-name task))

(define (task-state-name s)
  (cond ((%= s ts-added) "added")
        ((%= s ts-run) "run")
        ((%= s ts-ready) "ready")
        ((%= s ts-wait) "wait")
        ((%= s ts-removed) "removed")
        (else "?")))

;; The lists are walked with interrupts off and printed with them on: an
;; interrupt that signals a task moves it from one list to the other.
(define (task-snapshot)
  (without-interrupts
    (let ((acc nil))
      (dolist (p (list-nodes (wait-list))) (set! acc (%cons p acc)))
      (dolist (p (list-nodes (ready-list))) (set! acc (%cons p acc)))
      (%cons (this-task) (reverse acc)))))

(define (tasks)
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
;; closure directly, because it is reached by `ret` with the argument
;; registers holding whatever the task left in them.
(define *task-exit-stub* 0)

(define (task-finished)
  (let ((task (this-task)))
    ;; A section the task's function opened and returned without closing ends
    ;; with the task.
    (%enable)
    (set-tc-result! task 0)
    ;; The last task to finish takes the machine with it: there is nothing
    ;; left to schedule. The idle task does not count.
    (if (%<= (task-count) (if *idle-task* 2 1))
        (begin (emit-str "\n") (%halt exit-ok))
        nil)
    (remove-task task)
    ;; `remove-task` on the current task never returns.
    (while t (reschedule))))

(define (build-task-exit-stub)
  (let ((a (make-assembler)))
    (i-li a $t1 0)
    (i-lw a $t0 $zero lg-task-exit)
    (i-lw a $t2 $t0 0)
    (i-jr a $t2)
    (set! *task-exit-stub* (place a))
    (%st-word! lg-task-exit (%symbol-value 'task-finished))
    *task-exit-stub*))

;; ---------------------------------------------------------------- ports
(defrecord (msgport mp) (include node) sigmask sigtask msglist)

(defrecord (message mn) (include node) replyport length body)

(define (make-port name pri) (make-port-for (this-task) name pri))

;; A port belongs to the task that waits on it, which is not always the task
;; that makes it: a server's port is the server's, and the server is not
;; running yet when it is made.
(define (make-port-for owner name pri)
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

(define (make-message body reply)
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
;; the task behind the port has ended, or its handler failed. A caller
;; blocked on a reply that never comes is blocked for ever.
(defrecord (failure fl) why)

(define (make-failure why)
  (let ((f (fl-alloc)))
    (set-fl-why! f why)
    f))

(define (failure-why f) (fl-why f))

;; The signal is sent outside the section: `signal` takes its own. A port
;; whose task has ended takes nothing; the message is answered with a failure
;; there and then. The check is in the same section as the append, so a task
;; cannot end between the two.
(define (put-message port msg)
  (let ((owner (without-interrupts
                 (let ((o (mp-sigtask port)))
                   (if (if o (%= (tc-state o) ts-removed) nil)
                       'ended
                       (begin (add-tail (mp-msglist port) msg) o))))))
    (cond ((%eq? owner 'ended) (fail-message msg "the task behind that port has ended"))
          (owner (signal owner (mp-sigmask port)))
          (else nil)))
  msg)

;; Answer a message with a failure, straight onto its reply port rather than
;; through `put-message`, so that answering a caller who has also ended does
;; not go round again.
(define (fail-message msg why)
  (set-mn-body! msg (make-failure why))
  (let ((r (mn-replyport msg)))
    (if r
        (let ((owner (without-interrupts
                       (add-tail (mp-msglist r) msg)
                       (mp-sigtask r))))
          (if owner (signal owner (mp-sigmask r)) nil))
        nil))
  nil)

;; Everything queued on the named ports of a task that has ended, answered.
;; An unnamed port is a reply port, which nobody is waiting on an answer
;; from. The ports come off the list too, so a lookup by name cannot find a
;; dead one.
(define (fail-ports-of task)
  (let ((ports (without-interrupts
                 (let ((acc nil) (p (list-first *port-list*)))
                   (while p
                     (if (%eq? (mp-sigtask p) task) (set! acc (%cons p acc)) nil)
                     (set! p (node-next p)))
                   (dolist (q acc) (forget-node q))
                   acc))))
    (dolist (p ports)
      (let ((m (get-message p)))
        (while m
          (fail-message m "the task behind that port has ended")
          (set! m (get-message p))))))
  nil)

(define (get-message port)
  (without-interrupts (remove-head (mp-msglist port))))

;; Block until a message is there, and leave it there.
(define (wait-port port)
  (let ((m nil))
    (while (%null? m)
      (set! m (get-message port))
      (if (%null? m) (wait (mp-sigmask port)) nil))
    (without-interrupts (add-head (mp-msglist port) m))
    m))

;; Nothing to free: a message nobody holds is collected like anything else.
(define (delete-message m) (forget-node m))

(define (reply-message msg)
  (let ((r (mn-replyport msg)))
    (if r (put-message r msg) nil)))

;; ---------------------------------------------------------------- servers
;; A driver is a task with a port, and talking to it is sending it a message.
;; There is no registry of device names: a driver is reached by naming the
;; symbol that holds it. A resource one task owns cannot be raced for, and
;; the queue in front of it is the scheduler's.

(defrecord (server sv) (include node) port task poll)

(define (server-port s) (sv-port s))
(define (server-task s) (sv-task s))

;; Work that arrives as an edge rather than a message: a device's interrupt
;; server notifies the server's own port, and `fn` runs each time the server
;; wakes. A driver has one blocker and still hears both its device and its
;; clients.
(define (server-poll! s fn) (set-sv-poll! s fn) s)

;; A handler that fails answers its caller with the failure instead of
;; leaving it blocked, and the server goes back to its port on a clean stack:
;; the prompt's restart, for the prompt's reason.
(define (server-loop s handler)
  (let ((mark (task-binds)))
    (set! *repl-restart*
          (lambda report
            (unwind-binds-to! mark)
            (print-report report)
            (let ((m (get-message (sv-port s))))
              (if m (fail-message m "the server failed while answering") nil))
            (server-run s handler))))
  (server-run s handler))

;; A message stays on the port until it has been answered, so that a server
;; which ends part way through one leaves it where `remove-task` and the
;; restart will find it. The answer goes back in the message the caller sent,
;; so a request and its reply are one object.
(define (server-run s handler)
  (let ((port (sv-port s)))
    (while t
      (let ((poll (sv-poll s))) (if poll (%funcall poll) nil))
      (let ((m (without-interrupts (list-first (mp-msglist port)))))
        (if (%null? m)
            (wait (mp-sigmask port))
            (let ((v (%funcall handler (mn-body m))))
              (without-interrupts
                (remove-node m)
                (set-mn-body! m v)
                (reply-message m))))))))

;; The task is made, given its port, and only then started, so that the port
;; exists before the server runs and before anybody can be handed the server.
(define (make-server name pri handler . opts)
  (let ((s (sv-alloc)))
    (set-node-name! s name)
    (set-node-pri! s pri)
    (let ((task (apply make-child name pri (lambda () (server-loop s handler)) opts)))
      (set-sv-task! s task)
      (set-sv-port! s (make-port-for task name pri))
      (start-task task))
    s))

;; Every task has one reply port: a task that is waiting for an answer is
;; waiting for the one answer. Fanning out is done by making more tasks.
(define (reply-port)
  (if *reply-port*
      *reply-port*
      (begin (set! *reply-port* (make-port nil 0)) *reply-port*)))

;; Send, block, answer, or fail if the task behind the port ends or its
;; handler fails first. A loop, for the signal an answer leaves behind when it
;; arrives before the `wait`.
(define (request port body)
  (let* ((r (reply-port))
         (m (make-message body r)))
    (put-message port m)
    (while (%null? (get-message r)) (wait (mp-sigmask r)))
    (let ((v (mn-body m)))
      (if (failure? v) (error "request:" (node-name port) (fl-why v)) v))))

;; No answer wanted, and no waiting.
(define (send port body)
  (put-message port (make-message body nil))
  nil)

;; An edge rather than a message: something happened at this port. What an
;; interrupt server posts, because a server must not allocate, and why a task
;; can `wait` on a mask that spans device interrupts and message ports without
;; knowing which is which.
(define (notify port)
  (let ((task (mp-sigtask port)))
    (if task (signal task (mp-sigmask port)) nil))
  nil)

(define (port-ready? p) (if (list-empty? (mp-msglist p)) nil t))

;; `select`: a port with something on it. The scan starts one port further
;; along on each call, so a busy port cannot starve a quiet one.
(define *select-turn* 0)

(define (wait-ports ports)
  (let ((mask 0) (hit nil) (n (length ports)))
    (if (%= n 0) (error "wait-ports: no ports") nil)
    (dolist (p ports) (set! mask (%logior mask (mp-sigmask p))))
    (while (%null? hit)
      (let ((start (%rem *select-turn* n)) (i 0) (before nil))
        (set! *select-turn* (%logand (%+ *select-turn* 1) 1073741823))
        (dolist (p ports)
          (if (port-ready? p)
              (if (%< i start)
                  (if before nil (set! before p))
                  (if hit nil (set! hit p)))
              nil)
          (set! i (%+ i 1)))
        (if hit nil (set! hit before)))
      (if hit nil (wait mask)))
    hit))

;; ---------------------------------------------------------------- mutexes
;; A lock that belongs to a task, for data several tasks share and for any
;; section that may have to wait.
;;
;; - Only the owner can let it go. Taking it again while holding it nests.
;; - Waiters queue in priority order, first come first served among equals,
;;   and the one at the front is handed the mutex directly when it is let go.
;; - A waiter lends its priority to the owner, and on to whatever the owner
;;   is waiting for.
;; - A task that ends holding one, or whose stack an error abandons inside
;;   `with-mutex`, has it taken away. The next task to take it is told:
;;   `mutex-lock` answers `abandoned` rather than `t`, and `with-mutex` runs
;;   the mutex's repair function first, if it was made with one.
;; - Ownership moves only by `mutex-hand-over`.
;; - Waiting that would close a circle is an error naming the circle.
;;
;; The bookkeeping is done with interrupts off, for the few dozen
;; instructions it takes; it never sleeps there.

(defrecord (mutex mx) name owner count head next-held abandoned repair)

;; `repair`, if given, is a function of the mutex, run by the first task to
;; take it after it was abandoned.
(define (make-mutex name . repair)
  (let ((m (mx-alloc)))
    (set-mx-name! m (if (%symbol? name) (%symbol-name name) name))
    (set-mx-count! m 0)
    (set-mx-repair! m (if (%cons? repair) (%car repair) nil))
    m))

(define (mutex-name m) (mx-name m))
(define (mutex-owner m) (mx-owner m))

;; A task of this Exec that has not ended. A saved image keeps the records of
;; an Exec that a resume replaces.
(define (task-alive? task)
  (if (%eq? (tc-gen task) *exec-generation*)
      (if (%= (tc-state task) ts-removed) nil t)
      nil))

;; Answers `t`, or `abandoned` the first time the mutex is taken after its
;; owner ended holding it.
(define (mutex-lock m)
  (sleep-check "mutex-lock:")
  (let* ((me (this-task))
         (how (without-interrupts
                (let ((o (mx-owner m)))
                  (cond ((%null? o) (mutex-take! m me) (mutex-report! m))
                        ((%eq? o me) (set-mx-count! m (%+ (mx-count m) 1)) t)
                        ;; an owner from an Exec that no longer exists ended
                        ;; without letting go
                        ((if (task-alive? o) nil t)
                         (set-mx-abandoned! m t)
                         (mutex-take! m me)
                         (mutex-report! m))
                        ((mutex-circle? m me) 'circle)
                        (else (mutex-enqueue! m me) (lend-priority! m) 'wait))))))
    (cond ((%eq? how 'circle) (deadlock-error m me))
          ((%eq? how 'wait)
           ;; Until it is handed over, by `mutex-unlock`, `mutex-hand-over` or
           ;; the owner's end, each of which makes this task the owner first
           ;; and signals it second.
           (while (if (%eq? (mx-owner m) me) nil t) (wait sigf-mutex))
           (without-interrupts (mutex-report! m)))
          (else how))))

(define (mutex-report! m)
  (if (mx-abandoned m)
      (begin (set-mx-abandoned! m nil) 'abandoned)
      t))

(define (mutex-unlock m)
  (if (%eq? (mx-owner m) (this-task))
      nil
      (error (string-append "mutex-unlock: this task does not hold " (mx-name m))))
  (without-interrupts
    (if (%> (mx-count m) 1)
        (set-mx-count! m (%- (mx-count m) 1))
        (mutex-release! m (this-task))))
  ;; whoever it went to may be more urgent than this task
  (yield-if-owed)
  nil)

;; The body with the mutex held. An error in the body does not come back
;; through here; the mutex goes with the abandoned stack, and the next task
;; to take it finds it abandoned.
(defmacro with-mutex args
  (let ((m (gensym)) (result (gensym)))
    `(let ((,m ,(%car args)))
       (mutex-lock-repaired ,m)
       (let ((,result (begin ,@(%cdr args))))
         (mutex-unlock ,m)
         ,result))))

(define (mutex-lock-repaired m)
  (if (%eq? (mutex-lock m) 'abandoned)
      (let ((r (mx-repair m))) (if r (%funcall r m) nil))
      nil)
  nil)

;; Give a mutex this task holds, once and not nested, to another task. If that
;; task was waiting for it, it wakes holding it.
(define (mutex-hand-over m task)
  (let ((me (this-task)))
    (if (%eq? (mx-owner m) me)
        nil
        (error (string-append "mutex-hand-over: this task does not hold " (mx-name m))))
    (if (%> (mx-count m) 1)
        (error (string-append "mutex-hand-over: held more than once: " (mx-name m)))
        nil)
    (if (if (task? task) (%= (tc-state task) ts-removed) t)
        (error "mutex-hand-over: not a live task" task)
        nil)
    (without-interrupts
      (unlink-held! me m)
      (if (%eq? (tc-blocked-on task) m) (mutex-unqueue! m task) nil)
      (mutex-take! m task)
      (settle-priority! task)
      (settle-priority! me)
      (signal task sigf-mutex))
    (yield-if-owed)
    nil))

;; ------------------------- the bookkeeping, with interrupts off
(define (mutex-take! m task)
  (set-mx-owner! m task)
  (set-mx-count! m 1)
  (set-mx-next-held! m (tc-held task))
  (set-tc-held! task m))

(define (unlink-held! task m)
  (if (%eq? (tc-held task) m)
      (set-tc-held! task (mx-next-held m))
      (let ((p (tc-held task)))
        (while (if p (if (%eq? (mx-next-held p) m) nil t) nil)
          (set! p (mx-next-held p)))
        (if p (set-mx-next-held! p (mx-next-held m)) nil)))
  (set-mx-next-held! m nil))

;; Let go of it altogether, to whoever is at the front of the queue.
(define (mutex-release! m owner)
  (unlink-held! owner m)
  (let ((next (mutex-dequeue! m)))
    (if next
        (begin
          (mutex-take! m next)
          (settle-priority! next)
          (signal next sigf-mutex))
        (begin (set-mx-owner! m nil) (set-mx-count! m 0))))
  (settle-priority! owner))

;; In priority order, behind everybody of the same priority.
(define (mutex-enqueue! m task)
  (set-tc-blocked-on! task m)
  (let ((p (node-pri task)) (prev nil) (q (mx-head m)))
    (while (if q (%>= (node-pri q) p) nil)
      (set! prev q)
      (set! q (tc-mx-next q)))
    (set-tc-mx-next! task q)
    (if prev (set-tc-mx-next! prev task) (set-mx-head! m task))))

;; Past anybody who is not there to be woken: a waiter from before a resume.
(define (mutex-dequeue! m)
  (while (if (mx-head m) (if (task-alive? (mx-head m)) nil t) nil)
    (set-mx-head! m (tc-mx-next (mx-head m))))
  (let ((w (mx-head m)))
    (if w
        (begin
          (set-mx-head! m (tc-mx-next w))
          (set-tc-mx-next! w nil)
          (set-tc-blocked-on! w nil))
        nil)
    w))

(define (mutex-unqueue! m task)
  (let ((prev nil) (q (mx-head m)))
    (while (if q (if (%eq? q task) nil t) nil)
      (set! prev q)
      (set! q (tc-mx-next q)))
    (if q
        (begin
          (if prev (set-tc-mx-next! prev (tc-mx-next q)) (set-mx-head! m (tc-mx-next q)))
          (set-tc-mx-next! q nil)
          (set-tc-blocked-on! q nil))
        nil)))

;; The priority a task should run at: its own, or that of the most urgent
;; task waiting for anything it holds. Each queue is in priority order, so its
;; front is its most urgent.
(define (settle-priority! task)
  (let ((p (if (tc-base task) (tc-base task) (node-pri task)))
        (m (tc-held task)))
    (while m
      (let ((w (mx-head m)))
        (if (if w (%> (node-pri w) p) nil) (set! p (node-pri w)) nil))
      (set! m (mx-next-held m)))
    (if (%= p (node-pri task)) nil (repri! task p))))

(define (repri! task p)
  (without-interrupts
    (set-node-pri! task p)
    (cond ((%= (tc-state task) ts-ready)
           (remove-node task)
           (enqueue (ready-list) task))
          ((%= (tc-state task) ts-run)
           ;; lowered below somebody who is ready: that one goes next
           (let ((h (list-first (ready-list))))
             (if (if h (%> (node-pri h) p) nil) (set! *attn-resched* 1) nil)))
          (else nil)))
  ;; and its place in the queue of whatever it is itself waiting for
  (let ((b (tc-blocked-on task)))
    (if b (begin (mutex-unqueue! b task) (mutex-enqueue! b task)) nil))
  nil)

;; A new waiter's priority goes to the owner, and on down the line of owners
;; that are themselves waiting.
(define (lend-priority! m)
  (let ((o (mx-owner m)) (n 0))
    (while (if o (%< n 64) nil)
      (settle-priority! o)
      (let ((b (tc-blocked-on o)))
        (set! o (if b (mx-owner b) nil)))
      (set! n (%+ n 1)))))

;; Would waiting for m close a circle back to this task?
(define (mutex-circle? m me)
  (let ((o (mx-owner m)) (n 0) (hit nil))
    (while (if o (if hit nil (%< n 64)) nil)
      (if (%eq? o me)
          (set! hit t)
          (let ((b (tc-blocked-on o))) (set! o (if b (mx-owner b) nil))))
      (set! n (%+ n 1)))
    hit))

;; Outside the section, because an error abandons the stack and the section
;; with it.
(define (deadlock-error m me)
  (let ((s (string-append "deadlock: " (string-append (task-name me)
             (string-append " would wait for " (mx-name m)))))
        (o (mx-owner m))
        (n 0))
    (while (if o (%< n 16) nil)
      (set! s (string-append s (string-append ", held by " (task-name o))))
      (let ((b (tc-blocked-on o)))
        (if (if b (if (%eq? o me) nil t) nil)
            (begin
              (set! s (string-append s (string-append ", which is waiting for " (mx-name b))))
              (set! o (mx-owner b)))
            (set! o nil)))
      (set! n (%+ n 1)))
    (error s)))

;; Everything a task holds, handed on marked abandoned, and its place in the
;; queue of whatever it was waiting for. For a task that has ended, and for
;; one whose stack an error abandoned. No section of its own: `remove-task`
;; turns interrupts off around it, and the error path calls it from the trap
;; handler, where they are off already.
(define (abandon-mutexes-now task)
  (let ((m (tc-held task)))
    (while m
      (let ((next (mx-next-held m)))
        (set-mx-abandoned! m t)
        (set-mx-count! m 1)
        (mutex-release! m task)
        (set! m next))))
  (let ((b (tc-blocked-on task)))
    (if b
        (let ((o (mx-owner b)))
          (mutex-unqueue! b task)
          (if o (settle-priority! o) nil))
        nil))
  nil)

(define (abandon-mutexes task) (without-interrupts (abandon-mutexes-now task)))

;; ---------------------------------------------------------------- interrupts
(defrecord (interrupt is) (include node)
  code                           ; a closure taking the data
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
;; walk of the wait list; `sigf-vblank` is defined with the other fixed bits.
(define *vblank-int* nil)
(define *vblank-count* 0)

;; Runs inside the interrupt handler: allocates nothing, and takes the
;; successor before `signal` moves the task off the list.
(define (vblank-server data)
  (set! *vblank-count* (%+ *vblank-count* 1))
  (let ((p (list-first (wait-list))))
    (while p
      (let ((next (node-next p)))
        (if (%= 0 (%logand (tc-sigwait p) sigf-vblank))
            nil
            (signal p sigf-vblank))
        (set! p next))))
  nil)

;; Sleep until the display has finished a frame. A task waiting here is off
;; the ready list entirely.
(define (wait-vblank) (wait sigf-vblank))

;; ---------------------------------------------------------------- idle
;; Something always has to be ready to run. Without this, a machine where
;; every task is waiting has an empty ready list and `switch-tasks` declines
;; to switch, so the task that just declared itself asleep carries on. It
;; runs `wfi`, so an idle machine costs nothing; but a collection in
;; progress is what an idle machine should be doing, so it does that first,
;; a slice at a time, with interrupts on in between.
(define (idle-task)
  (while t
    (set! *idle-count* (%+ *idle-count* 1))
    (if (busy?) (step) (%wait-for-interrupt))))

(define (idle-start)
  (if *idle-task*
      nil
      (set! *idle-task* (add-task "idle" -128 (lambda () (idle-task)) 4096)))
  *idle-task*)

;; Only the kernel's end of the line: telling the display chip to raise it is
;; gfx.driver's business.
(define (vblank-start)
  (if *vblank-int*
      nil
      (begin
        (set! *vblank-int*
              (make-interrupt "vblank" 0 (lambda (d) (vblank-server d)) 0))
        (add-int-server int-vblank *vblank-int*)))
  *vblank-int*)

(define (add-int-server line int)
  (without-interrupts
    (enqueue (int-vector line) int)
    (int-enable line))
  int)

(define (remove-int-server line int)
  (without-interrupts
    (remove-node int)
    (if (list-empty? (int-vector line)) (int-disable line) nil))
  nil)

;; Cause is Exec's software interrupt: run something soon, but not here.
(define (cause int)
  (add-int-server int-soft int)
  (int-raise int-soft)
  nil)

;; A rebuild recompiles this file into the machine that is running it, and
;; every top level `define` here resets a kernel variable as it goes; an
;; interrupt arriving in that window finds no vector of server lists.
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
;; with the interrupted task's registers in its context block. The flag is
;; safe to set this way only because it is cleared before the handler
;; returns, and no other task runs until it does.
(define (handle-interrupt n ctx)
  (set! *in-interrupt* t)
  (handle-interrupt-1 n ctx)
  (set! *in-interrupt* nil)
  nil)

(define (handle-interrupt-1 n ctx)
  (cond
   ((%= n irq-timer)
    (set! *disp-count* (%+ *disp-count* 1))
    (timer-set-in *quantum*)
    (set! *ticks* (%+ *ticks* 1))
    (fire-deadlines)
    (switch-tasks))
   ((%= n irq-external)
    ;; Ask the chips which line it was, run every server on it, then
    ;; acknowledge. Servers run with interrupts off.
    (let ((line (int-pending)))
      (while (%>= line 0)
        (run-int-servers line)
        (int-ack line)
        (set! line (int-pending))))
    ;; A server that woke a task of higher priority than the one it
    ;; interrupted hands the processor over now rather than at the next tick.
    (if (%> *attn-resched* 0)
        (begin (set! *attn-resched* 0) (switch-tasks))
        nil))
   ((%= n irq-software) (switch-tasks))
   (else nil))
  nil)

;; ---------------------------------------------------------------- residents
;; What Exec starts when it starts: the drivers. A driver's file registers
;; one when it loads, and `exec-init` starts every one, at a cold boot and
;; again after a resume. Adding one under a name already there replaces it.
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
;; A resumed image arrives with the counts and flags of an Exec that no longer
;; exists, so every one of them is set here.
(define (exec-init)
  (set! *vblank-int* nil)
  (%set-this-task! nil)
  (set! *idle-task* nil)
  (set! *attn-resched* 0)
  (set! *exec-started* nil)
  (set! *exec-generation* (%+ *exec-generation* 1))
  (set! *disp-count* 0)
  (set! *switch-count* 0)
  (set! *idle-count* 0)
  (set! *task-count* 0)
  (set! *ready-list* (new-list))
  (set! *wait-list* (new-list))
  (set! *deadlines* nil)
  (set! *port-list* (new-list))
  (set! *int-vectors* (make-vector-n 8 nil))
  (let ((i 0))
    (while (%< i 8)
      (%vector-set! *int-vectors* i (new-list))
      (set! i (%+ i 1))))
  (set! *quantum* default-quantum)
  (set! *ticks* 0)
  (set! *ms-per-tick* (%/ *quantum* (%/ (timer-hz) 1000)))
  ;; The code that is already running becomes task zero. Its context is the
  ;; block the trap stub has been using all along.
  (let ((boot (tc-alloc)))
    (set-node-name! boot "boot")
    (set-node-pri! boot 0)
    (set-tc-base! boot 0)
    (set-tc-gen! boot *exec-generation*)
    (zero-task-counters! boot)
    (set-tc-quantum! boot default-quantum)
    (set-tc-state! boot ts-run)
    (set-tc-context! boot (%ld-fixnum lg-trapsave))
    (set-tc-splower! boot (%ld-fixnum lg-stackbot))
    (set-tc-spupper! boot (%ld-fixnum lg-stacktop))
    (set-tc-sigalloc! boot sig-reserved)
    ;; Task zero takes whatever was bound before there were tasks.
    (set-tc-binds! boot *boot-binds*)
    (set! *boot-binds* nil)
    (install-task-binds!)
    (%set-this-task! boot)
    (%set-stack-limit! (task-stack-limit boot))
    (set! *task-count* 1))
  (build-task-exit-stub)
  ;; What sys.lisp had to leave blank: a task restarts on its own stack, and a
  ;; task that faults with no prompt behind it ends rather than halting the
  ;; machine.
  (set! *stack-top-fn* (lambda () (tc-spupper (this-task))))
  (set! *return-addr-fn* (lambda () *task-exit-stub*))
  (vblank-start)
  (idle-start)
  (set! *abort-cleanup-fn*
        (lambda ()
          (set! *attn-resched* 0)
          ;; A fault inside an interrupt server never reaches the line that
          ;; clears this.
          (set! *in-interrupt* nil)
          ;; Every `with-mutex` the task was inside went with its stack.
          (let ((me (this-task))) (if me (abandon-mutexes-now me) nil))))
  (set! *task-abort-fn*
        (lambda report
          (print-report report)
          (emit-str "task ended by an error\n")
          (task-finished)))
  ;; The drivers last, once a task that fails has somewhere to go.
  (start-residents)
  *ready-list*)

;; Stop the clock driving the scheduler, and the chips that would call into
;; the kernel. Tasks still switch when they ask to. The one caller is a
;; rebuild, which recompiles this file into the running machine: every top
;; level `define` in it resets a kernel variable as the rebuild goes past, and
;; a timer interrupt arriving then would find no ready list. Turning
;; interrupts off instead would cut the rebuild off from the serial line its
;; sources arrive on.
(define (preemption-off)
  (timer-never)
  (int-disable int-vblank)
  (int-disable int-input)
  nil)

(define (preemption-on)
  (int-enable int-vblank)
  (int-enable int-input)
  (timer-set-in *quantum*)
  nil)

;; From here the timer interrupt drives the scheduler.
(define (exec-start)
  (timer-set-in *quantum*)
  (%enable-interrupt-lines)
  (%enable)
  (set! *exec-started* t)
  nil)

;; ---------------------------------------------------------------- gc roots
;; Exec's records are objects hanging off variables, so the collector finds
;; the tasks, ports, messages and interrupt servers and every value in them
;; by itself. What it cannot reach are the raw stacks and register blocks the
;; tasks were suspended on. Nothing here may allocate: these run inside a
;; collection.

;; A cycle has begun, or a compaction moved every pair: the run a suspended
;; task was holding is not its own any more. The cell gp names is kept: the
;; task may have been preempted between the room check and the two stores
;; that fill the cell, and would finish its pair there. `scan-run` has the
;; collector treat that cell as a live pair, and here the run shrinks to
;; that one cell; the next cons after it asks for a fresh run. A run with
;; nothing left is left with nothing: extending it would hand the task the
;; cell past its end, which belongs to whoever got the next run.
(define (drop-task-run task)
  (let ((ctx (tc-context task)))
    (if (if ctx (%> ctx 0) nil)
        (let ((gp (%ld-fixnum (ctx-reg ctx reg-gp)))
              (tp (%ld-fixnum (ctx-reg ctx reg-tp))))
          (if (%< gp tp) (poke (ctx-reg ctx reg-tp) (%+ gp 8)) nil))
        nil)))

(define (invalidate-runs)
  (if *ready-list*
      (begin
        (scan-list-of *ready-list* drop-task-run)
        (scan-list-of *wait-list* drop-task-run))
      nil)
  nil)

;; The run a task was handed is owed by that task, not by whoever refills
;; next; see `refill-cons` in gc.lisp. Before there are tasks, gc's own cell.
(define (note-run! bytes)
  (let ((me (this-task)))
    (if me (set-tc-run-owed! me bytes) (set! gc::*run-owed* bytes))))

(define (take-owed-run)
  (let ((me (this-task)))
    (if me
        (let ((b (tc-run-owed me))) (set-tc-run-owed! me 0) b)
        (let ((b gc::*run-owed*)) (set! gc::*run-owed* 0) b))))

;; A suspended task's stack, precisely, and its saved registers,
;; conservatively: a task preempted mid-expression has live values in
;; registers whose types nothing recorded, and the compactor pins whatever
;; they reach. gp and tp are not guesses, they are the cons run, and are
;; handled by `scan-run`.
(define (scan-task task)
  (let ((ctx (tc-context task)))
    (if (if ctx (%> ctx 0) nil)
        (begin
          (scan-frames (%ld-fixnum (%+ ctx (%* 4 reg-sp)))
                          (%ld-fixnum (%+ ctx (%* 4 reg-s0))))
          (scan-conservative ctx (ctx-reg ctx reg-gp))
          (scan-conservative (ctx-reg ctx reg-t0) (%+ ctx ctx-bytes))
          (scan-run ctx))
        nil)))

;; The cell at the front of a suspended task's run: nothing yet, or a pair the
;; task was interrupted in the middle of filling in. Kept as a pair like any
;; other, with gp rewritten to wherever it goes. A run with nothing left in it
;; is given up here and now.
(define (scan-run ctx)
  (let ((gp (ctx-reg ctx reg-gp))
        (tp (ctx-reg ctx reg-tp)))
    (if (%< (%ld-fixnum gp) (%ld-fixnum tp))
        (slot gp)
        (begin (poke gp 0) (poke tp 0)))))

(define (scan-list-of l fn)
  (let ((p (list-first l)))
    (while p
      (%funcall fn p)
      (set! p (node-next p)))))

(define (extra-roots)
  (if *ready-list*
      (begin
        (scan-list-of *ready-list* scan-task)
        (scan-list-of *wait-list* scan-task))
      nil))

(define (task-count) *task-count*)
