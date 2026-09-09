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
(define ln-tag 0)
(define ln-succ 1)
(define ln-pred 2)
(define ln-pri 3)
(define ln-name 4)
(define node-slots 5)

(define (make-node tag) (make-record node-slots tag))
(define (node-succ n) (%slot n ln-succ))
(define (node-pred n) (%slot n ln-pred))
(define (node-pri n) (%slot n ln-pri))
(define (node-name n) (%slot n ln-name))
(define (node-tag n) (if (%record? n) (%slot n ln-tag) nil))

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
(define lh-tag 0)
(define lh-head 1)           ; the sentinel before the first node
(define lh-tail 2)           ; the sentinel after the last
(define list-slots 3)

(define (new-list)
  (let ((l (make-record list-slots 'list))
        (h (make-node 'list-head))
        (tl (make-node 'list-tail)))
    (%set-slot! l lh-head h)
    (%set-slot! l lh-tail tl)
    ;; The tail sentinel's successor is nil, and that nil is what ends a walk:
    ;; the same terminator the zero in Exec's `lh-tail` always was.
    (%set-slot! h ln-succ tl)
    (%set-slot! tl ln-pred h)
    l))

(define (list-head l) (%slot l lh-head))
(define (list-tail l) (%slot l lh-tail))

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
    (%set-slot! n ln-succ p)
    (%set-slot! n ln-pred prev)
    (%set-slot! prev ln-succ n)
    (%set-slot! p ln-pred n)
    n))

(define (add-head l n) (insert-before (node-succ (list-head l)) n))
(define (add-tail l n) (insert-before (list-tail l) n))

(define (remove-node n)
  (let ((s (node-succ n))
        (p (node-pred n)))
    (%set-slot! p ln-succ s)
    (%set-slot! s ln-pred p)
    n))

;; Removal for good rather than to move it somewhere else. The links go too:
;; the collector can see them now, so a node somebody still holds would
;; otherwise keep every node that was after it alive.
(define (forget-node n)
  (remove-node n)
  (%set-slot! n ln-succ nil)
  (%set-slot! n ln-pred nil)
  n)

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
(define tc-state 5)
(define tc-sigalloc 6)
(define tc-sigwait 7)
(define tc-sigrecvd 8)
(define tc-splower 9)          ; raw addresses, held as fixnums
(define tc-spupper 10)
(define tc-context 11)         ; 128-byte register block, raw
(define tc-fn 12)              ; the closure the task runs
(define tc-result 13)
(define tc-switches 14)
(define tc-userdata 15)        ; the per-task environment vector
(define tc-quantum 16)
(define tc-elapsed 17)
(define task-slots 18)

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
(define *this-task* nil)
(define *idle-task* nil)
(define *ready-list* nil)
(define *wait-list* nil)
(define *lib-list* nil)
(define *port-list* nil)
(define *int-vectors* nil)     ; a vector of eight lists
(define *idnest* 0)            ; Disable nesting
(define *tdnest* 0)            ; Forbid nesting
(define *int-state-saved* 0)   ; the interrupt state the outermost Disable found
(define *attn-resched* 0)      ; a switch a Forbid deferred
(define *quantum* 0)
(define *disp-count* 0)
(define *switch-count* 0)
(define *idle-count* 0)
(define *task-count* 0)

(define (this-task) *this-task*)
(define (ready-list) *ready-list*)
(define (wait-list) *wait-list*)
(define (int-vector n) (%vector-ref *int-vectors* n))

;; ---------------------------------------------------------------- context
;; Word 0 is the pc, words 1..31 are x1..x31. This is the block the trap stub
;; saves into and restores from, so a task's context and a trap frame are the
;; same thing.
(define ctx-bytes 128)
(define (ctx-pc c) (%+ c 0))
(define (ctx-reg c n) (%+ c (%* 4 n)))
(define reg-ra 1)
(define reg-sp 2)
(define reg-gp 3)
(define reg-tp 4)
(define reg-t0 5)
(define reg-t1 6)
(define reg-s2 18)
(define reg-a0 10)
(define reg-a7 17)

;; ---------------------------------------------------------------- critical
;; Disable turns interrupts off at the processor. Forbid leaves them on but
;; tells the scheduler not to switch: an interrupt still runs, it just cannot
;; take the processor away.
;; The count is what a debugger reads; what makes the pair correct is the
;; state the outermost Disable found. Enable used to turn interrupts on when
;; the count reached zero, which is wrong wherever the count did not start at
;; zero-with-interrupts-on - and an interrupt handler is exactly that place.
;; A server that called Signal, whose Enable balanced, re-enabled interrupts
;; in the middle of the handler.
(define (disable)
  (let ((was (%disable))
        (n *idnest*))
    (if (%= n 0) (set! *int-state-saved* was) nil)
    (set! *idnest* (%+ n 1)))
  nil)

(define (enable)
  (let ((n (%- *idnest* 1)))
    (set! *idnest* (if (%< n 0) 0 n))
    (if (%<= n 0)
        (%restore-interrupts *int-state-saved*)
        nil))
  nil)

(define (forbid)
  (set! *tdnest* (%+ *tdnest* 1))
  nil)

(define (permit)
  (let ((n (%- *tdnest* 1)))
    (set! *tdnest* (if (%< n 0) 0 n))
    (if (%<= n 0)
        (if (%> *attn-resched* 0)
            (begin (set! *attn-resched* 0) (reschedule))
            nil)
        nil))
  nil)

(define (forbidden?) (%> *tdnest* 0))

;; ---------------------------------------------------------------- scheduler
;; A reschedule is asked for with an ecall, so that the switch happens inside
;; the trap handler where the whole register set has already been saved.
(define trap-reschedule 5)

(define (reschedule) (%ecall trap-reschedule))

;; ---------------------------------------------------------------- task state
;; Five globals are per-task in truth: where output goes, where input comes
;; from, how to wait for it, the character the reader put back, and where an
;; error should restart. They stay globals because everything reads them
;; constantly and the common case has to be one load; what makes them local is
;; the scheduler, saving them into the task leaving the processor and loading
;; the arriving one's. That is what a context switch is for, and it is why two
;; REPLs can read from two different windows without either knowing.
(define env-slots 7)
(define env-out 0)
(define env-in 1)
(define env-wait 2)
(define env-peeked 3)
(define env-restart 4)
(define env-package 5)
(define env-rp 6)

(define (task-env task) (%slot task tc-userdata))
(define (set-task-env! task e) (%set-slot! task tc-userdata e))

(define (new-task-env)
  ;; A new task starts out talking to whatever its creator was talking to.
  (let ((e (make-vector-n env-slots nil)))
    (%vector-set! e env-out *out*)
    (%vector-set! e env-in *in*)
    (%vector-set! e env-wait *wait*)
    (%vector-set! e env-package (current-package))
    (%vector-set! e env-rp *rp*)
    e))

(define (save-task-env task)
  (let ((e (task-env task)))
    (if (%vector? e)
        (begin
          (%vector-set! e env-out *out*)
          (%vector-set! e env-in *in*)
          (%vector-set! e env-wait *wait*)
          (%vector-set! e env-peeked *peeked*)
          (%vector-set! e env-restart *repl-restart*)
          (%vector-set! e env-package (current-package))
          (%vector-set! e env-rp *rp*))
        nil)))

(define (load-task-env task)
  (let ((e (task-env task)))
    (if (%vector? e)
        (begin
          (set! *out* (%vector-ref e env-out))
          (set! *in* (%vector-ref e env-in))
          (set! *wait* (%vector-ref e env-wait))
          (set! *peeked* (%vector-ref e env-peeked))
          (set! *repl-restart* (%vector-ref e env-restart))
          (set-current-package! (%vector-ref e env-package))
          (set! *rp* (%vector-ref e env-rp)))
        nil)))

;; Dead tasks waiting to be reclaimed. A task cannot free the stack it is
;; standing on, so it goes on this list instead and the next context switch
;; does the work - that runs on the trap stack, with the corpse saved and
;; never to be resumed, which is the first moment its stack is genuinely idle.
(define *reaped* nil)

(define (reap-tasks)
  (let ((p *reaped*))
    (set! *reaped* nil)
    (while (%cons? p)
      (reap-task (%car p))
      (set! p (%cdr p)))))

(define (task-ready! task)
  (%set-slot! task tc-state ts-ready)
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
                (save-task-env cur)
                (if (%= (%slot cur tc-state) ts-run)
                    (task-ready! cur)
                    nil)
                (%set-slot! cur tc-elapsed (%+ (%slot cur tc-elapsed) 1))
                (%set-slot! next tc-state ts-run)
                (%set-slot! next tc-switches (%+ (%slot next tc-switches) 1))
                (set! *this-task* next)
                (load-task-env next)
                (set! *switch-count* (%+ *switch-count* 1))
                (%set-context (%slot next tc-context))
                ;; Only now, with the context switched away from whatever was
                ;; running, is it safe to hand a dead task's stack back.
                (if *reaped* (reap-tasks) nil)))))
    nil))

;; ---------------------------------------------------------------- signals
(define (alloc-signal task)
  ;; Signals 0..15 are reserved the way Exec reserves them; 16..31 are free.
  (disable)
  (let ((alloc (%slot task tc-sigalloc)) (n 16) (got -1))
    (while (if (%< n 32) (%< got 0) nil)
      (if (%= 0 (%logand alloc (%lsh 1 n)))
          (begin
            (%set-slot! task tc-sigalloc (%logior alloc (%lsh 1 n)))
            (set! got n))
          (set! n (%+ n 1))))
    (enable)
    (if (%< got 0) (error "alloc-signal: none left") nil)
    got))

(define (free-signal task n)
  (disable)
  (%set-slot! task tc-sigalloc
              (%logand (%slot task tc-sigalloc) (%lognot (%lsh 1 n))))
  (enable)
  nil)

;;
;; A task is a record that says so, and nothing frees a record - so a task
;; pointer somebody kept is either a live task or a dead one, and never a
;; different live task that happens to have been given the same memory. That
;; used to be the hazard this file could only narrow, not close: `rem-task`
;; returned the block to the pool, and the pool handed it out again.
(define (task? p) (%eq? (node-tag p) 'task))

(define (signal task mask)
  (if (task? task) nil (error "signal: not a task" task))
  (disable)
  (%set-slot! task tc-sigrecvd (%logior (%slot task tc-sigrecvd) mask))
  (if (%= (%slot task tc-state) ts-wait)
      (if (%> (%logand (%slot task tc-sigrecvd) (%slot task tc-sigwait)) 0)
          (begin
            (remove-node task)
            (task-ready! task)
            ;; A woken task of higher priority should get the processor now.
            (if (%> (%slot task ln-pri) (%slot (this-task) ln-pri))
                (set! *attn-resched* 1)
                nil))
          nil)
      nil)
  (enable)
  nil)

(define (wait mask)
  ;; Block until one of the signals in mask arrives, then take those bits and
  ;; leave the rest for the next Wait.
  ;;
  ;; Not from an interrupt server. Waiting means asking to be rescheduled, and
  ;; asking to be rescheduled is an ecall - a trap taken from inside the trap
  ;; handler, on the trap stack, with the interrupted task's context half
  ;; saved. There is no task there to block.
  (if *in-interrupt* (error "wait: called from an interrupt server") nil)
  (disable)
  (let ((task (this-task)) (got 0))
    (while (%= got 0)
      (set! got (%logand (%slot task tc-sigrecvd) mask))
      (if (%= got 0)
          (begin
            (%set-slot! task tc-sigwait mask)
            (%set-slot! task tc-state ts-wait)
            (add-tail (wait-list) task)
            (enable)
            (reschedule)
            (disable))
          nil))
    (%set-slot! task tc-sigrecvd (%logand (%slot task tc-sigrecvd) (%lognot got)))
    (%set-slot! task tc-sigwait 0)
    (enable)
    got))

(define (set-signal task new mask)
  (disable)
  (let ((old (%slot task tc-sigrecvd)))
    (%set-slot! task tc-sigrecvd (%logior (%logand old (%lognot mask)) (%logand new mask)))
    (enable)
    old))

;; ---------------------------------------------------------------- tasks
;; Slot 0 of a closure holds a raw code address rather than a tagged value, so
;; reading it back as a number takes %addr-of, not %from-addr: the word is
;; already an address and must not be shifted.
(define (closure-entry fn) (%addr-of (%raw-ld (%addr-of fn))))

(define default-stack 65536)
(define default-quantum 200000)

;; A fresh record's slots hold nil, and nil is not the fixnum zero - `(%+ nil
;; 1)` is not 1, and `(%logand nil m)` is not 0. Anything counted or masked
;; has to be set before it is read. The old pool block came back zeroed, and
;; a raw zero word *is* the fixnum zero, so this is new bookkeeping that the
;; representation asks for.
(define (zero-task-counters! task)
  (%set-slot! task tc-sigwait 0)
  (%set-slot! task tc-sigrecvd 0)
  (%set-slot! task tc-switches 0)
  (%set-slot! task tc-elapsed 0)
  (%set-slot! task tc-result 0)
  nil)

(define (add-task name pri fn . opts)
  (let* ((env (new-task-env))
         (stack (if (%cons? opts) (%car opts) default-stack))
         (task (make-record task-slots 'task))
         (ctx (alloc-pool ctx-bytes))
         (sp (alloc-pool stack)))
    ;; The environment is built before the task holds any Lisp value. There is
    ;; no window to worry about any more - a half-filled task record is traced
    ;; like any other object, whether or not it is on a list yet - but the
    ;; order costs nothing and says what it means.
    (%set-slot! task ln-name name)
    (%set-slot! task ln-pri pri)
    (zero-task-counters! task)
    (%set-slot! task tc-state ts-added)
    (%set-slot! task tc-splower sp)
    (%set-slot! task tc-spupper (%+ sp stack))
    (%set-slot! task tc-context ctx)
    (%set-slot! task tc-fn fn)
    (set-task-env! task env)
    (%set-slot! task tc-quantum default-quantum)
    (%set-slot! task tc-sigalloc 65535)
    ;; The context is built to look as though the task had just been
    ;; interrupted on the first instruction of its function.
    (poke (ctx-pc ctx) (closure-entry fn))
    (poke (ctx-reg ctx reg-sp) (%+ sp stack))
    (poke (ctx-reg ctx reg-ra) *task-exit-stub*)
    (%raw-st! (ctx-reg ctx reg-t0) fn)
    (poke (ctx-reg ctx reg-t1) 0)
    (disable)
    (task-ready! task)
    (set! *task-count* (%+ *task-count* 1))
    (enable)
    task))

;; A task that runs as an instance. Nothing else is different: s2 lives in the
;; context block like every other register, so the scheduler was already
;; carrying it and this costs a single word at startup.
;; What the forge handed out before the machine ran - the boot task's stack,
;; its context - has no header and was never meant to come back. Ending the
;; first task should not try to give it away.
(define (free-if-ours p)
  (if (if p (%> p 0) nil)
      (if (%= (%ld32 (%+ p -4)) pool-tag) (free-pool p) nil)
      nil))

(define (spawn inst name pri fn . opts)
  (let ((task (apply-list add-task (%cons name (%cons pri (%cons fn opts))))))
    (%raw-st! (ctx-reg (%slot task tc-context) reg-s2) inst)
    task))

(define (rem-task task)
  (disable)
  ;; A task that has ended stays a task and says so. Signalling it does
  ;; nothing, because it is in no state to be woken; that is the whole
  ;; difference from a handle that could come back as somebody else.
  (%set-slot! task tc-state ts-removed)
  (set! *task-count* (%- *task-count* 1))
  (enable)
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
  (free-if-ours (%slot task tc-splower))
  (free-if-ours (%slot task tc-context))
  (%set-slot! task tc-splower nil)
  (%set-slot! task tc-context nil)
  nil)

(define (find-task name)
  (if (%null? name)
      (this-task)
      (let ((f (find-name (ready-list) name)))
        (if f f (find-name (wait-list) name)))))

(define (task-name task) (%slot task ln-name))

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
                (emit-str (number->string (%slot p ln-pri)))
                (emit-str "    ")
                (emit-str (task-state-name (%slot p tc-state)))
                (emit-str "     ")
                (emit-str (number->string (%slot p tc-switches)))
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
    (%set-slot! task tc-result 0)
    ;; The last task to finish takes the machine with it: there is nothing
    ;; left to schedule, and pretending otherwise is a hang. The idle task does
    ;; not count - it is always there and it never does anything.
    (if (%<= (task-count) (if (%> *idle-task* 0) 2 1))
        (begin (emit-str "\n") (%halt 0))
        nil)
    (rem-task task)
    ;; rem-task on the current task never returns, but if it somehow did,
    ;; spinning is better than running off the end of the world.
    (while t (reschedule))))

(define (build-task-exit-stub)
  (let ((a (asm-new)))
    (i-li a $t1 0)
    (i-lw a $t0 $zero lg-scratch0)
    (i-lw a $t2 $t0 0)
    (i-jr a $t2)
    (set! *task-exit-stub* (asm-place a))
    (%raw-st! lg-scratch0 (%symbol-value 'task-finished))
    *task-exit-stub*))

;; ---------------------------------------------------------------- ports
(define mp-sigbit 5)
(define mp-sigtask 6)
(define mp-msglist 7)
(define port-slots 8)

(define mn-replyport 5)
(define mn-length 6)
(define mn-body 7)
(define message-slots 8)

(define (create-port name pri)
  (let ((p (make-node 'msgport))
        (sig (alloc-signal (this-task))))
    (%set-slot! p ln-name name)
    (%set-slot! p ln-pri pri)
    (%set-slot! p mp-sigbit sig)
    (%set-slot! p mp-sigtask (this-task))
    (%set-slot! p mp-msglist (new-list))
    (if (%null? name)
        nil
        (begin (disable) (enqueue *port-list* p) (enable)))
    p))

(define (delete-port p)
  (if (%null? (node-name p)) nil (begin (disable) (forget-node p) (enable)))
  (free-signal (%slot p mp-sigtask) (%slot p mp-sigbit))
  nil)

(define (find-port name) (find-name *port-list* name))

(define (create-message body reply)
  (let ((m (make-node 'message)))
    (%set-slot! m mn-replyport reply)
    (%set-slot! m mn-length message-slots)
    (%set-slot! m mn-body body)
    m))

(define (message-body m) (%slot m mn-body))
(define (set-message-body! m v) (%set-slot! m mn-body v))

(define (put-msg port msg)
  (disable)
  (add-tail (%slot port mp-msglist) msg)
  (let ((task (%slot port mp-sigtask)))
    (enable)
    (if task (signal task (%lsh 1 (%slot port mp-sigbit))) nil))
  msg)

(define (get-msg port)
  (disable)
  (let ((m (rem-head (%slot port mp-msglist))))
    (enable)
    m))

(define (wait-port port)
  (let ((m nil))
    (while (%null? m)
      (set! m (get-msg port))
      (if (%null? m) (wait (%lsh 1 (%slot port mp-sigbit))) nil))
    ;; Put it back: WaitPort tells you a message is there without taking it.
    (disable)
    (add-head (%slot port mp-msglist) m)
    (enable)
    m))

;; Nothing to free: a message nobody holds is collected like anything else.
(define (delete-message m) (forget-node m))

(define (reply-msg msg)
  (let ((r (%slot msg mn-replyport)))
    (if r (put-msg r msg) nil)))

;; ---------------------------------------------------------------- libraries
;; A library is reached through a jump table below its base pointer, which is
;; what makes the interface stable across versions: entry n always lives at
;; base minus 8n, whatever else changes. That table is raw memory and holds
;; only code addresses, so hand written code can jump through it and the
;; collector never has to look at it. The closures themselves live in a vector
;; in the record, where the collector finds them without being told.
(define lib-version 5)
(define lib-opencnt 6)
(define lib-entries 7)         ; a vector of closures
(define lib-table 8)           ; raw address of the jump table, or nil
(define library-slots 9)

(define (make-library name version entries)
  (let* ((n (length entries))
         (table (alloc-pool (%* 8 (%+ n 1))))
         (base (%+ table (%* 8 (%+ n 1))))
         (v (make-vector-n n nil))
         (lib (make-node 'library))
         (i 0))
    (%set-slot! lib ln-name name)
    (%set-slot! lib lib-version version)
    (%set-slot! lib lib-opencnt 0)
    (%set-slot! lib lib-entries v)
    (%set-slot! lib lib-table base)
    (dolist (fn entries)
      (%vector-set! v i fn)
      (poke (%- base (%* 8 (%+ i 1))) (closure-entry fn))
      (set! i (%+ i 1)))
    (disable)
    (enqueue *lib-list* lib)
    (enable)
    lib))

(define (lvo lib n) (%vector-ref (%slot lib lib-entries) (%- n 1)))

(define (open-library name version)
  (let ((lib (find-name *lib-list* name)))
    (if (%null? lib)
        nil
        (if (%< (%slot lib lib-version) version)
            nil
            (begin
              (%set-slot! lib lib-opencnt (%+ (%slot lib lib-opencnt) 1))
              lib)))))

(define (close-library lib)
  (if lib
      (%set-slot! lib lib-opencnt (%- (%slot lib lib-opencnt) 1))
      nil)
  nil)

;; ---------------------------------------------------------------- interrupts
(define is-code 5)             ; a Lisp closure taking the data
(define is-data 6)
(define interrupt-slots 7)

(define (make-interrupt name pri code data)
  (let ((i (make-record interrupt-slots 'interrupt)))
    (%set-slot! i ln-name name)
    (%set-slot! i ln-pri pri)
    (%set-slot! i is-code code)
    (%set-slot! i is-data data)
    i))

;; ---------------------------------------------------------------- vblank
;; One signal bit, the same in every task, so that waking every waiter is a
;; walk of the wait list rather than a registry somebody has to maintain.
;; `alloc-signal` hands out bits from 16 up, which leaves the low half for
;; things like this.
(define sigb-vblank 5)
(define sigf-vblank 32)
(define sigb-input 6)
(define sigf-input 64)
(define *vblank-int* 0)
(define *vblank-count* 0)

(define (vblank-server data)
  ;; Runs inside the interrupt handler, so it allocates nothing and takes the
  ;; successor before Signal moves the task off the list it is standing on.
  (set! *vblank-count* (%+ *vblank-count* 1))
  (let ((p (list-first (wait-list))))
    (while p
      (let ((next (node-next p)))
        (if (%> (%logand (%slot p tc-sigwait) sigf-vblank) 0)
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
  (if (%> *idle-task* 0)
      nil
      (set! *idle-task* (add-task "idle" -128 (lambda () (idle-task)) 4096)))
  *idle-task*)

(define (idle? task) (%= task *idle-task*))

;; ---------------------------------------------------------------- input
;; The input device raises its line for as long as it has events, so a handler
;; that only signalled would be re-entered forever. Masking the line is what
;; makes a level-triggered device behave: the server hands the work to a task
;; and stops listening, and the task turns it back on when the queue is dry.
(define *input-int* 0)
(define *input-task* 0)

(define (input-server data)
  (int-disable int-input)
  (if (%> *input-task* 0) (signal *input-task* sigf-input) nil)
  nil)

(define (input-listen task)
  (set! *input-task* task)
  (poke inp-ctrl (%logior (peek inp-ctrl) 1))
  (if (%> *input-int* 0)
      nil
      (begin
        (set! *input-int*
              (make-interrupt "input" 0 (lambda (d) (input-server d)) 0))
        (add-int-server int-input *input-int*)))
  (int-enable int-input)
  nil)

(define (wait-input)
  ;; Drain first: the line was masked when the server fired, so anything that
  ;; arrived since is sitting in the device with nobody listening.
  (int-enable int-input)
  (wait sigf-input))

(define (vblank-start)
  (if (%> *vblank-int* 0)
      nil
      (begin
        (set! *vblank-int*
              (make-interrupt "vblank" 0 (lambda (d) (vblank-server d)) 0))
        (add-int-server int-vblank *vblank-int*)
        ;; And tell the display to raise it.
        (poke gfx-ctrl (%logior (peek gfx-ctrl) gfx-vbirq))))
  *vblank-int*)

(define (add-int-server line int)
  (disable)
  (enqueue (int-vector line) int)
  (int-enable line)
  (enable)
  int)

(define (rem-int-server line int)
  (disable)
  (remove-node int)
  (if (list-empty? (int-vector line)) (int-disable line) nil)
  (enable)
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
      (let ((code (%slot p is-code))
            (data (%slot p is-data)))
        (if code (%funcall code data) nil))
      (set! p (node-next p)))))

;; ---------------------------------------------------------------- dispatch
;; Everything that interrupts the machine arrives here, on the trap stack,
;; with the interrupted task's registers already in its context block.
(define *in-interrupt* nil)

(define (handle-interrupt n ctx)
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
        (set! line (int-pending)))))
   ((%= n int-software) (switch-tasks))
   (else nil))
  nil)

;; ---------------------------------------------------------------- startup
(define (exec-init)
  ;; A resumed image arrives with these still set, naming interrupt structures
  ;; that belonged to the ExecBase this is about to replace. Believing them
  ;; means never installing the servers into the new one, and a machine with
  ;; no vblank and no keyboard.
  (set! *vblank-int* 0)
  (set! *input-int* 0)
  (set! *input-task* 0)
  ;; And these, which a resumed image also arrives with: counts and flags that
  ;; described an Exec that no longer exists. When they lived in a structure,
  ;; allocating a fresh one zeroed them all at once; now that they are
  ;; variables, saying so is the price of not having a base pointer.
  (set! *this-task* 0)
  (set! *idle-task* 0)
  (set! *idnest* 0)
  (set! *tdnest* 0)
  (set! *int-state-saved* 0)
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
    (let ((boot (make-record task-slots 'task)))
      (%set-slot! boot ln-name "boot")
      (%set-slot! boot ln-pri 0)
      (zero-task-counters! boot)
      (%set-slot! boot tc-quantum default-quantum)
      (%set-slot! boot tc-state ts-run)
      (%set-slot! boot tc-context (%global lg-trapsave))
      (%set-slot! boot tc-splower (%global lg-stackbot))
      (%set-slot! boot tc-spupper (%global lg-stacktop))
      (%set-slot! boot tc-sigalloc 65535)
      (set-task-env! boot (new-task-env))
      (set! *this-task* boot)
      (set! *task-count* 1))

    (build-task-exit-stub)
    ;; Now the two things sys.lisp had to leave blank: a task restarts on its
    ;; own stack, and a task that faults with no prompt behind it ends rather
    ;; than halting the machine.
    (set! *stack-top-fn* (lambda () (%slot (this-task) tc-spupper)))
    (set! *return-addr-fn* (lambda () *task-exit-stub*))
    (vblank-start)
    (idle-start)
    (set! *abort-cleanup-fn*
          (lambda ()
            (set! *idnest* 0)
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
    *ready-list*))

;; Stop the clock driving the scheduler. Nothing else changes: tasks still
;; switch when they ask to, signals still work, interrupts still arrive. What
;; stops is being taken off the processor against your will.
;;
;; There is one caller and it is the one that needs it. A rebuild recompiles
;; exec.lisp into the machine it is running on, and every `(define *idnest* 0)`
;; in it is a top level form like any other: for the rest of that rebuild the
;; kernel's state resets under it, one variable at a time. Nothing notices as
;; long as nothing calls into the kernel - and a timer interrupt is exactly
;; that call, arriving unasked.
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
  (let ((ctx (%slot task tc-context)))
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
  (let ((ctx (%slot task tc-context)))
    (if (if ctx (%> ctx 0) nil)
        (begin
          ;; Its stack, precisely, from where it was suspended.
          (gc-scan-frames (%ld32 (%+ ctx (%* 4 reg-sp)))
                          (%ld32 (%+ ctx (%* 4 8))))
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
