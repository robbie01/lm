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
(define ln-succ 0)
(define ln-pred 4)
(define ln-type 8)
(define ln-pri 12)
(define ln-name 16)
(define node-size 20)

(define nt-unknown 0)
(define nt-task 1)
(define nt-interrupt 2)
(define nt-device 3)
(define nt-msgport 4)
(define nt-message 5)
(define nt-library 6)
(define nt-memory 7)

;; ---------------------------------------------------------------- List
;; Exec's list header overlaps a node: lh-head is the successor field of an
;; imaginary node at the head, and lh-tail-pred is the predecessor field of an
;; imaginary node at the tail. That overlap is why insertion and removal need
;; no test for the ends of the list.
(define lh-head 0)
(define lh-tail 4)
(define lh-tailpred 8)
(define lh-type 12)
(define list-size 16)

(define (new-list l)
  (poke (%+ l lh-head) (%+ l lh-tail))
  (poke (%+ l lh-tail) 0)
  (poke (%+ l lh-tailpred) l)
  l)

;; The Lisp-facing accessors answer nil for "no node" rather than zero,
;; because zero is a perfectly good fixnum and would test true. Everything
;; that walks a list therefore ends with nil, not with a sentinel address.
(define (list-empty? l) (%= (peek (%+ l lh-tailpred)) l))
(define (list-first l) (if (list-empty? l) nil (peek (%+ l lh-head))))
(define (list-last l) (if (list-empty? l) nil (peek (%+ l lh-tailpred))))
(define (node-next n)
  ;; The successor of the last node is the imaginary tail node, whose own
  ;; successor field is the zero that terminates the walk.
  (let ((s (peek (%+ n ln-succ))))
    (if (%= (peek (%+ s ln-succ)) 0) nil s)))

(define (add-head l n)
  (let ((h (peek (%+ l lh-head))))
    (poke (%+ n ln-succ) h)
    (poke (%+ n ln-pred) l)
    (poke (%+ h ln-pred) n)
    (poke (%+ l lh-head) n)
    n))

(define (add-tail l n)
  (let ((tp (peek (%+ l lh-tailpred))))
    (poke (%+ n ln-succ) (%+ l lh-tail))
    (poke (%+ n ln-pred) tp)
    (poke (%+ tp ln-succ) n)
    (poke (%+ l lh-tailpred) n)
    n))

(define (remove-node n)
  (let ((s (peek (%+ n ln-succ)))
        (p (peek (%+ n ln-pred))))
    (poke (%+ p ln-succ) s)
    (poke (%+ s ln-pred) p)
    n))

(define (rem-head l)
  (if (list-empty? l) nil (remove-node (peek (%+ l lh-head)))))

(define (rem-tail l)
  (if (list-empty? l) nil (remove-node (peek (%+ l lh-tailpred)))))

(define (enqueue l n)
  ;; Insert by priority, after every node of equal or higher priority, so that
  ;; equal priorities keep their arrival order and round-robin fairly.
  (let ((pri (peek (%+ n ln-pri)))
        (p (peek (%+ l lh-head)))
        (done nil))
    (while (if done nil (%> (peek (%+ p ln-succ)) 0))
      (if (%< (peek (%+ p ln-pri)) pri)
          (set! done t)
          (set! p (peek (%+ p ln-succ)))))
    ;; insert before p
    (let ((prev (peek (%+ p ln-pred))))
      (poke (%+ n ln-succ) p)
      (poke (%+ n ln-pred) prev)
      (poke (%+ prev ln-succ) n)
      (poke (%+ p ln-pred) n))
    n))

(define (find-name l name)
  (let ((p (list-first l)) (found nil))
    (while (if found nil p)
      (let ((s (%raw-ld (%+ p ln-name))))
        (if (if (%string? s) (string=? s name) nil)
            (set! found p)
            (set! p (node-next p)))))
    found))

(define (list-nodes l)
  ;; A Lisp list of the node addresses, for inspection from the repl.
  (let ((p (list-first l)) (acc nil))
    (while p
      (set! acc (%cons p acc))
      (set! p (node-next p)))
    (reverse acc)))

;; ---------------------------------------------------------------- Task
(define tc-flags 20)
(define tc-state 24)
(define tc-idnest 28)
(define tc-tdnest 32)
(define tc-sigalloc 36)
(define tc-sigwait 40)
(define tc-sigrecvd 44)
(define tc-splower 48)
(define tc-spupper 52)
(define tc-context 56)     ; 128-byte register block
(define tc-fn 60)          ; the closure the task runs (a Lisp value)
(define tc-result 64)
(define tc-switches 68)
(define tc-userdata 72)
(define tc-quantum 76)
(define tc-elapsed 80)
(define tc-msgport 84)
(define task-size 96)

(define ts-invalid 0)
(define ts-added 1)
(define ts-run 2)
(define ts-ready 3)
(define ts-wait 4)
(define ts-except 5)
(define ts-removed 6)

;; ---------------------------------------------------------------- ExecBase
(define eb-thistask 20)
(define eb-taskready 24)      ; List
(define eb-taskwait 40)       ; List
(define eb-idnest 56)
(define eb-tdnest 60)
(define eb-quantum 64)
(define eb-attnresched 68)
(define eb-liblist 72)        ; List
(define eb-portlist 88)       ; List
(define eb-intvects 104)      ; 8 lists of 16 bytes
(define eb-dispcount 232)
(define eb-switchcount 236)
(define eb-idlecount 240)
(define eb-taskcount 244)
(define eb-idletask 248)
(define eb-idsaved 252)       ; interrupt state the outermost Disable found
(define execbase-size 256)

(define *sysbase* 0)

(define (sysbase) *sysbase*)
(define (this-task) (peek (%+ *sysbase* eb-thistask)))
(define (ready-list) (%+ *sysbase* eb-taskready))
(define (wait-list) (%+ *sysbase* eb-taskwait))
(define (int-vector n) (%+ *sysbase* (%+ eb-intvects (%* n list-size))))

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
        (n (peek (%+ *sysbase* eb-idnest))))
    (if (%= n 0) (poke (%+ *sysbase* eb-idsaved) was) nil)
    (poke (%+ *sysbase* eb-idnest) (%+ n 1)))
  nil)

(define (enable)
  (let ((n (%- (peek (%+ *sysbase* eb-idnest)) 1)))
    (poke (%+ *sysbase* eb-idnest) (if (%< n 0) 0 n))
    (if (%<= n 0)
        (%restore-interrupts (peek (%+ *sysbase* eb-idsaved)))
        nil))
  nil)

(define (forbid)
  (poke (%+ *sysbase* eb-tdnest) (%+ (peek (%+ *sysbase* eb-tdnest)) 1))
  nil)

(define (permit)
  (let ((n (%- (peek (%+ *sysbase* eb-tdnest)) 1)))
    (poke (%+ *sysbase* eb-tdnest) (if (%< n 0) 0 n))
    (if (%<= n 0)
        (if (%> (peek (%+ *sysbase* eb-attnresched)) 0)
            (begin (poke (%+ *sysbase* eb-attnresched) 0) (reschedule))
            nil)
        nil))
  nil)

(define (forbidden?) (%> (peek (%+ *sysbase* eb-tdnest)) 0))

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

(define (task-env task) (%raw-ld (%+ task tc-userdata)))
(define (set-task-env! task e) (%raw-st! (%+ task tc-userdata) e))

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
      (let ((task (%car p)))
        (free-if-ours (peek (%+ task tc-splower)))
        (free-if-ours (peek (%+ task tc-context)))
        (free-if-ours task))
      (set! p (%cdr p)))))

(define (task-ready! task)
  (poke (%+ task tc-state) ts-ready)
  (enqueue (ready-list) task))

;; Choose the next task and point mscratch at its context. Called only from
;; inside the trap handler, with the outgoing task's registers already saved.
(define (switch-tasks)
  (let ((cur (this-task)))
    (if (forbidden?)
        ;; A forbidden task keeps the processor; remember that it owes us one.
        (poke (%+ *sysbase* eb-attnresched) 1)
        (let ((next (rem-head (ready-list))))
          (if (%null? next)
              nil
              (begin
                (save-task-env cur)
                (if (%= (peek (%+ cur tc-state)) ts-run)
                    (task-ready! cur)
                    nil)
                (poke (%+ cur tc-elapsed) (%+ (peek (%+ cur tc-elapsed)) 1))
                (poke (%+ next tc-state) ts-run)
                (poke (%+ next tc-switches) (%+ (peek (%+ next tc-switches)) 1))
                (poke (%+ *sysbase* eb-thistask) next)
                (load-task-env next)
                (poke (%+ *sysbase* eb-switchcount)
                      (%+ (peek (%+ *sysbase* eb-switchcount)) 1))
                (%set-context (peek (%+ next tc-context)))
                ;; Only now, with the context switched away from whatever was
                ;; running, is it safe to hand a dead task's stack back.
                (if *reaped* (reap-tasks) nil)))))
    nil))

;; ---------------------------------------------------------------- signals
(define (alloc-signal task)
  ;; Signals 0..15 are reserved the way Exec reserves them; 16..31 are free.
  (disable)
  (let ((alloc (peek (%+ task tc-sigalloc))) (n 16) (got -1))
    (while (if (%< n 32) (%< got 0) nil)
      (if (%= 0 (%logand alloc (%lsh 1 n)))
          (begin
            (poke (%+ task tc-sigalloc) (%logior alloc (%lsh 1 n)))
            (set! got n))
          (set! n (%+ n 1))))
    (enable)
    got))

(define (free-signal task n)
  (disable)
  (poke (%+ task tc-sigalloc)
        (%logand (peek (%+ task tc-sigalloc)) (%lognot (%lsh 1 n))))
  (enable)
  nil)

(define (signal task mask)
  (disable)
  (poke (%+ task tc-sigrecvd) (%logior (peek (%+ task tc-sigrecvd)) mask))
  (if (%= (peek (%+ task tc-state)) ts-wait)
      (if (%> (%logand (peek (%+ task tc-sigrecvd)) (peek (%+ task tc-sigwait))) 0)
          (begin
            (remove-node task)
            (task-ready! task)
            ;; A woken task of higher priority should get the processor now.
            (if (%> (peek (%+ task ln-pri)) (peek (%+ (this-task) ln-pri)))
                (poke (%+ *sysbase* eb-attnresched) 1)
                nil))
          nil)
      nil)
  (enable)
  nil)

(define (wait mask)
  ;; Block until one of the signals in mask arrives, then take those bits and
  ;; leave the rest for the next Wait.
  (disable)
  (let ((task (this-task)) (got 0))
    (while (%= got 0)
      (set! got (%logand (peek (%+ task tc-sigrecvd)) mask))
      (if (%= got 0)
          (begin
            (poke (%+ task tc-sigwait) mask)
            (poke (%+ task tc-state) ts-wait)
            (add-tail (wait-list) task)
            (enable)
            (reschedule)
            (disable))
          nil))
    (poke (%+ task tc-sigrecvd) (%logand (peek (%+ task tc-sigrecvd)) (%lognot got)))
    (poke (%+ task tc-sigwait) 0)
    (enable)
    got))

(define (set-signal task new mask)
  (disable)
  (let ((old (peek (%+ task tc-sigrecvd))))
    (poke (%+ task tc-sigrecvd) (%logior (%logand old (%lognot mask)) (%logand new mask)))
    (enable)
    old))

;; ---------------------------------------------------------------- tasks
;; Slot 0 of a closure holds a raw code address rather than a tagged value, so
;; reading it back as a number takes %addr-of, not %from-addr: the word is
;; already an address and must not be shifted.
(define (closure-entry fn) (%addr-of (%raw-ld (%addr-of fn))))

(define default-stack 65536)
(define default-quantum 200000)

(define (add-task name pri fn . opts)
  (let* ((stack (if (%cons? opts) (%car opts) default-stack))
         (task (alloc-pool task-size))
         (ctx (alloc-pool ctx-bytes))
         (sp (alloc-pool stack)))
    (%raw-st! (%+ task ln-name) name)
    (poke (%+ task ln-type) nt-task)
    (poke (%+ task ln-pri) pri)
    (poke (%+ task tc-state) ts-added)
    (poke (%+ task tc-splower) sp)
    (poke (%+ task tc-spupper) (%+ sp stack))
    (poke (%+ task tc-context) ctx)
    (%raw-st! (%+ task tc-fn) fn)
    (set-task-env! task (new-task-env))
    (poke (%+ task tc-quantum) default-quantum)
    (poke (%+ task tc-sigalloc) 65535)
    ;; The context is built to look as though the task had just been
    ;; interrupted on the first instruction of its function.
    (poke (ctx-pc ctx) (closure-entry fn))
    (poke (ctx-reg ctx reg-sp) (%+ sp stack))
    (poke (ctx-reg ctx reg-ra) *task-exit-stub*)
    (%raw-st! (ctx-reg ctx reg-t0) fn)
    (poke (ctx-reg ctx reg-t1) 0)
    (disable)
    (task-ready! task)
    (poke (%+ *sysbase* eb-taskcount) (%+ (peek (%+ *sysbase* eb-taskcount)) 1))
    (enable)
    task))

;; A task that runs as an instance. Nothing else is different: s2 lives in the
;; context block like every other register, so the scheduler was already
;; carrying it and this costs a single word at startup.
;; What the forge handed out before the machine ran - the boot task's stack,
;; its context - has no header and was never meant to come back. Ending the
;; first task should not try to give it away.
(define (free-if-ours p)
  (if (%> p 0)
      (if (%= (%ld32 (%+ p -4)) pool-tag) (free-pool p) nil)
      nil))

(define (spawn inst name pri fn . opts)
  (let ((task (apply-list add-task (%cons name (%cons pri (%cons fn opts))))))
    (%raw-st! (ctx-reg (peek (%+ task tc-context)) reg-s2) inst)
    task))

(define (rem-task task)
  (disable)
  (poke (%+ task tc-state) ts-removed)
  (poke (%+ *sysbase* eb-taskcount) (%- (peek (%+ *sysbase* eb-taskcount)) 1))
  (enable)
  (if (%= task (this-task))
      (begin
        ;; The current task cannot free its own stack while standing on it, so
        ;; it puts itself on the reaper list and stops being runnable. The
        ;; switch that takes it off the processor is what frees it.
        (set! *reaped* (%cons task *reaped*))
        (reschedule)
        nil)
      (begin
        (remove-node task)
        (free-if-ours (peek (%+ task tc-splower)))
        (free-if-ours (peek (%+ task tc-context)))
        (free-if-ours task)
        nil)))

(define (find-task name)
  (if (%null? name)
      (this-task)
      (let ((f (find-name (ready-list) name)))
        (if f f (find-name (wait-list) name)))))

(define (task-name task) (%raw-ld (%+ task ln-name)))

(define (task-state-name s)
  (cond ((%= s ts-added) "added")
        ((%= s ts-run) "run")
        ((%= s ts-ready) "ready")
        ((%= s ts-wait) "wait")
        ((%= s ts-removed) "removed")
        (else "?")))

(define (tasks)
  ;; What the whole system is doing, for the repl.
  (emit-str "  pri  state    switches  name\n")
  (let ((show (lambda (p)
                (emit-str "  ")
                (emit-str (number->string (peek (%+ p ln-pri))))
                (emit-str "    ")
                (emit-str (task-state-name (peek (%+ p tc-state))))
                (emit-str "     ")
                (emit-str (number->string (peek (%+ p tc-switches))))
                (emit-str "  ")
                (emit-str (task-name p))
                (emit-str "\n"))))
    (%funcall show (this-task))
    (dolist (p (list-nodes (ready-list))) (%funcall show p))
    (dolist (p (list-nodes (wait-list))) (%funcall show p)))
  nil)

;; The stub a task returns to when its function finishes. It cannot be a Lisp
;; closure directly, because it is reached by `ret` with the argument registers
;; holding whatever the task left in them.
(define *task-exit-stub* 0)

(define (task-finished)
  (let ((task (this-task)))
    (%raw-st! (%+ task tc-result) 0)
    ;; The last task to finish takes the machine with it: there is nothing
    ;; left to schedule, and pretending otherwise is a hang. The idle task does
    ;; not count - it is always there and it never does anything.
    (if (%<= (task-count) (if (%> (peek (%+ *sysbase* eb-idletask)) 0) 2 1))
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
(define mp-flags 20)
(define mp-sigbit 24)
(define mp-sigtask 28)
(define mp-msglist 32)
(define port-size 48)

(define mn-replyport 20)
(define mn-length 24)
(define mn-body 28)          ; a Lisp value, kept alive because the collector
(define message-size 32)     ; scans the whole pool conservatively

(define (create-port name pri)
  (let ((p (alloc-pool port-size))
        (sig (alloc-signal (this-task))))
    (%raw-st! (%+ p ln-name) name)
    (poke (%+ p ln-type) nt-msgport)
    (poke (%+ p ln-pri) pri)
    (poke (%+ p mp-sigbit) sig)
    (poke (%+ p mp-sigtask) (this-task))
    (new-list (%+ p mp-msglist))
    (if (%null? name)
        nil
        (begin (disable) (enqueue (%+ *sysbase* eb-portlist) p) (enable)))
    p))

(define (delete-port p)
  (if (%null? (%raw-ld (%+ p ln-name))) nil (begin (disable) (remove-node p) (enable)))
  (free-signal (peek (%+ p mp-sigtask)) (peek (%+ p mp-sigbit)))
  (free-pool p)
  nil)

(define (find-port name) (find-name (%+ *sysbase* eb-portlist) name))

(define (create-message body reply)
  (let ((m (alloc-pool message-size)))
    (poke (%+ m ln-type) nt-message)
    (poke (%+ m mn-replyport) reply)
    (poke (%+ m mn-length) message-size)
    (%raw-st! (%+ m mn-body) body)
    m))

(define (message-body m) (%raw-ld (%+ m mn-body)))
(define (set-message-body! m v) (%raw-st! (%+ m mn-body) v))

(define (put-msg port msg)
  (disable)
  (add-tail (%+ port mp-msglist) msg)
  (let ((task (peek (%+ port mp-sigtask))))
    (enable)
    (if (%> task 0) (signal task (%lsh 1 (peek (%+ port mp-sigbit)))) nil))
  msg)

(define (get-msg port)
  (disable)
  (let ((m (rem-head (%+ port mp-msglist))))
    (enable)
    m))

(define (wait-port port)
  (let ((m nil))
    (while (%null? m)
      (set! m (get-msg port))
      (if (%null? m) (wait (%lsh 1 (peek (%+ port mp-sigbit)))) nil))
    ;; Put it back: WaitPort tells you a message is there without taking it.
    (disable)
    (add-head (%+ port mp-msglist) m)
    (enable)
    m))

(define (delete-message m) (free-pool m))

(define (reply-msg msg)
  (let ((r (peek (%+ msg mn-replyport))))
    (if (%> r 0) (put-msg r msg) nil)))

;; ---------------------------------------------------------------- libraries
;; A library is reached through a jump table below its base pointer, which is
;; what makes the interface stable across versions: entry n always lives at
;; base minus 8n, whatever else changes.
(define lib-flags 20)
(define lib-negsize 24)
(define lib-possize 28)
(define lib-version 32)
(define lib-opencnt 36)
(define lib-vectors 40)      ; how many entries the table has
(define library-size 48)

(define (make-library name version entries)
  ;; entries is a list of closures; entry n is reached with (lvo base n).
  (let* ((n (length entries))
         (neg (%* 8 (%+ n 1)))
         (block (alloc-pool (%+ neg library-size)))
         (base (%+ block neg))
         (i 1))
    (%raw-st! (%+ base ln-name) name)
    (poke (%+ base ln-type) nt-library)
    (poke (%+ base lib-negsize) neg)
    (poke (%+ base lib-possize) library-size)
    (poke (%+ base lib-version) version)
    (poke (%+ base lib-vectors) n)
    (dolist (fn entries)
      ;; Two words per entry: the closure, and the raw code address, so that
      ;; hand written code can jump through the table without knowing about
      ;; Lisp objects at all.
      (%raw-st! (%- base (%* 8 i)) fn)
      (poke (%+ (%- base (%* 8 i)) 4) (closure-entry fn))
      (set! i (%+ i 1)))
    (disable)
    (enqueue (%+ *sysbase* eb-liblist) base)
    (enable)
    base))

(define (lvo base n) (%raw-ld (%- base (%* 8 n))))

(define (open-library name version)
  (let ((lib (find-name (%+ *sysbase* eb-liblist) name)))
    (if (%null? lib)
        nil
        (if (%< (peek (%+ lib lib-version)) version)
            nil
            (begin
              (poke (%+ lib lib-opencnt) (%+ (peek (%+ lib lib-opencnt)) 1))
              lib)))))

(define (close-library lib)
  (if (%> lib 0)
      (poke (%+ lib lib-opencnt) (%- (peek (%+ lib lib-opencnt)) 1))
      nil)
  nil)

;; ---------------------------------------------------------------- interrupts
(define is-code 20)          ; a Lisp closure taking the data
(define is-data 24)
(define interrupt-size 32)

(define (make-interrupt name pri code data)
  (let ((i (alloc-pool interrupt-size)))
    (%raw-st! (%+ i ln-name) name)
    (poke (%+ i ln-type) nt-interrupt)
    (poke (%+ i ln-pri) pri)
    (%raw-st! (%+ i is-code) code)
    (%raw-st! (%+ i is-data) data)
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
        (if (%> (%logand (peek (%+ p tc-sigwait)) sigf-vblank) 0)
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
    (poke (%+ *sysbase* eb-idlecount) (%+ (peek (%+ *sysbase* eb-idlecount)) 1))
    (%wait-for-input)))

(define (idle-start)
  (if (%> (peek (%+ *sysbase* eb-idletask)) 0)
      nil
      (poke (%+ *sysbase* eb-idletask)
            (add-task "idle" -128 (lambda () (idle-task)) 4096)))
  (peek (%+ *sysbase* eb-idletask)))

(define (idle? task) (%= task (peek (%+ *sysbase* eb-idletask))))

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

(define (run-int-servers line)
  (let ((p (list-first (int-vector line))))
    (while p
      (let ((code (%raw-ld (%+ p is-code)))
            (data (%raw-ld (%+ p is-data))))
        (if code (%funcall code data) nil))
      (set! p (node-next p)))))

;; ---------------------------------------------------------------- dispatch
;; Everything that interrupts the machine arrives here, on the trap stack,
;; with the interrupted task's registers already in its context block.
(define (handle-interrupt n ctx)
  (cond
   ((%= n int-timer)
    (poke (%+ *sysbase* eb-dispcount) (%+ (peek (%+ *sysbase* eb-dispcount)) 1))
    (timer-set-in (peek (%+ *sysbase* eb-quantum)))
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
  (let ((sb (alloc-pool execbase-size)))
    (set! *sysbase* sb)
    (%raw-st! (%+ sb ln-name) "exec")
    (poke (%+ sb ln-type) nt-library)
    (new-list (ready-list))
    (new-list (wait-list))
    (new-list (%+ sb eb-liblist))
    (new-list (%+ sb eb-portlist))
    (let ((i 0))
      (while (%< i 8)
        (new-list (int-vector i))
        (set! i (%+ i 1))))
    (poke (%+ sb eb-quantum) default-quantum)
    ;; AbsSysBase, where every Amiga program has always looked for it.
    (%st32! sysbase-ptr sb)
    (%set-global! lg-sysbase sb)

    ;; The code that is already running becomes task zero. Its context is the
    ;; block the trap stub has been using all along, so it is already correct.
    (let ((boot (alloc-pool task-size)))
      (%raw-st! (%+ boot ln-name) "boot")
      (poke (%+ boot ln-type) nt-task)
      (poke (%+ boot ln-pri) 0)
      (poke (%+ boot tc-state) ts-run)
      (poke (%+ boot tc-context) (%global lg-trapsave))
      (poke (%+ boot tc-splower) (%global lg-stackbot))
      (poke (%+ boot tc-spupper) (%global lg-stacktop))
      (poke (%+ boot tc-sigalloc) 65535)
      (set-task-env! boot (new-task-env))
      (poke (%+ sb eb-thistask) boot)
      (poke (%+ sb eb-taskcount) 1))

    (build-task-exit-stub)
    ;; Now the two things sys.lisp had to leave blank: a task restarts on its
    ;; own stack, and a task that faults with no prompt behind it ends rather
    ;; than halting the machine.
    (set! *stack-top-fn* (lambda () (peek (%+ (this-task) tc-spupper))))
    (set! *return-addr-fn* (lambda () *task-exit-stub*))
    (vblank-start)
    (idle-start)
    (set! *abort-cleanup-fn*
          (lambda ()
            (poke (%+ sb eb-idnest) 0)
            (poke (%+ sb eb-tdnest) 0)
            (poke (%+ sb eb-attnresched) 0)))
    (set! *task-abort-fn*
          (lambda ()
            (emit-str "task ended by an error\n")
            (task-finished)))
    sb))

;; Stop the clock driving the scheduler. Nothing else changes: tasks still
;; switch when they ask to, signals still work, interrupts still arrive. What
;; stops is being taken off the processor against your will.
;;
;; There is one caller and it is the one that needs it. A rebuild recompiles
;; exec.lisp into the machine it is running on, and `(define *sysbase* nil)`
;; is a top level form like any other: for the rest of that rebuild the kernel
;; has no ExecBase. Nothing notices as long as nothing calls into the kernel -
;; and a timer interrupt is exactly that call, arriving unasked.
(define (preemption-off) (timer-never) nil)

(define (exec-start)
  ;; Turn on preemption. From here the timer interrupt drives the scheduler.
  (timer-set-in (peek (%+ *sysbase* eb-quantum)))
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
  (let ((ctx (peek (%+ task tc-context))))
    (if (%> ctx 0)
        (begin (poke (ctx-reg ctx reg-gp) 0)
               (poke (ctx-reg ctx reg-tp) 0))
        nil)))

(define (gc-invalidate-runs)
  (if (%= *sysbase* 0)
      nil
      (begin
        (gc-scan-list-of (ready-list) drop-task-run)
        (gc-scan-list-of (wait-list) drop-task-run)))
  nil)

(define (gc-scan-task task)
  (gc-slot (%+ task ln-name))
  (gc-slot (%+ task tc-fn))
  (gc-slot (%+ task tc-userdata))
  (let ((ctx (peek (%+ task tc-context))))
    (if (%> ctx 0)
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

(define (gc-scan-port port)
  (gc-slot (%+ port ln-name))
  (let ((m (list-first (%+ port mp-msglist))))
    (while m
      (gc-slot (%+ m ln-name))
      (gc-slot (%+ m mn-body))
      (set! m (node-next m)))))

(define (gc-scan-library base)
  (gc-slot (%+ base ln-name))
  (let ((i 1) (n (peek (%+ base lib-vectors))))
    (while (%<= i n)
      (gc-slot (%- base (%* 8 i)))
      (set! i (%+ i 1)))))

(define (gc-scan-int-server s)
  (gc-slot (%+ s ln-name))
  (gc-slot (%+ s is-code))
  (gc-slot (%+ s is-data)))

(define (gc-scan-list-of l fn)
  (let ((p (list-first l)))
    (while p
      (%funcall fn p)
      (set! p (node-next p)))))

(define (gc-extra-roots)
  (if (%= *sysbase* 0)
      nil
      (begin
        ;; The running task, whose stack gc-roots already walked.
        (gc-slot (%+ (this-task) ln-name))
        (gc-slot (%+ (this-task) tc-fn))
        (gc-slot (%+ (this-task) tc-userdata))
        (gc-scan-list-of (ready-list) gc-scan-task)
        (gc-scan-list-of (wait-list) gc-scan-task)
        (gc-scan-list-of (%+ *sysbase* eb-portlist) gc-scan-port)
        (gc-scan-list-of (%+ *sysbase* eb-liblist) gc-scan-library)
        (let ((i 0))
          (while (%< i 8)
            (gc-scan-list-of (int-vector i) gc-scan-int-server)
            (set! i (%+ i 1)))))))

(define (uptime) (peek (%+ *sysbase* eb-dispcount)))
(define (switch-count) (peek (%+ *sysbase* eb-switchcount)))
(define (task-count) (peek (%+ *sysbase* eb-taskcount)))
