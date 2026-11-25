;;; compile.lisp - Lisp to native RISC-V with CHERI.
;;;
;;; The same source runs twice. At build time the forge's interpreter runs it
;;; to compile the whole system, this file included, into the image. The
;;; image then holds a compiled copy of the compiler, which is what compiles
;;; forms typed at a prompt and what a rebuild uses.
;;;
;;; A value is a capability and every slot that holds one is 8 bytes: a
;;; pointer is tagged and bounded to its object, a fixnum or a character is
;;; untagged. docs/cheri.md is the contract.
;;;
;;; Calling convention
;;;   a0..a7   arguments 0..7; arguments 8 and up are pushed by the caller so
;;;            that argument 8 sits at 0(sp) on entry, which is 0(s0) inside
;;;   t0       the closure being entered, unsealed by the `jcl` that entered
;;;            it, so its free variables are reachable
;;;   t1       argument count, an integer
;;;   a0       the result
;;;   ra       the return sentry
;;;   gp       the cons run: bounded to the task's run, addressing its next
;;;            free pair
;;;   tp       nil, for the life of the machine
;;;   s1       the running function's code object, which holds its literals
;;;   s2       the running task
;;;
;;; Frame
;;;   s0 + 8k       argument 8 + k
;;;   s0 - 8        saved ra
;;;   s0 - 16       saved s0
;;;   s0 - 24       the closure
;;;   s0 - 32       saved s1
;;;   s0 - 40 - 8i  local slot i
;;;   sp            below all of that; temporaries are pushed under it
;;;
;;; sp and s0 are capabilities to the task's stack, so every move of either
;;; is a `cincoffset`, and every slot is loaded and stored with `lc` and `sc`.
;;; Only one instruction in the prologue depends on the frame size, so the
;;; frame is sized after the body is emitted and that instruction is patched.
;;;
;;; Every granule of a frame says by its tag whether it holds a pointer, so
;;; the collector walks a stack with no stack maps and nothing in a frame has
;;; to be disguised.
;;;
;;; Pairs
;;;   car, cdr, set-car! and set-cdr! are single instructions in the custom-0
;;;   opcode space. The processor checks that the base is a pair as it forms
;;;   the address, and anything else traps with the register in mtval, which
;;;   sys.lisp turns into a sentence naming the value. nil is a pair of nils
;;;   to read, and its capability refuses a write.

(in-package compiler)

;; The fixed slots of a frame, below s0.
(define ra-slot -8)
(define link-slot -16)
(define clo-slot -24)
(define code-slot -32)
(define frame-fixed 40)
(define (local-off n) (%- (%- 0 frame-fixed) (%* value-bytes n)))

;; The byte offset of slot k of an object.
(define (slot-off k) (%* value-bytes k))

;; ---------------------------------------------------------------- leaves
;; A function that calls nothing needs none of the frame it would build. It
;; cannot be returned into, so ra survives; nothing it does can lose a
;; register a collection needs, because a collection begun in a trap sees
;; every register exactly; and no callee can clobber its locals, so they stay
;; in registers. About seven functions in ten are leaves.
;;
;; s3..s10 hold a leaf's locals and s11 holds its caller's code object.
;; Nothing else in the machine touches those nine registers, so a leaf saves
;; and restores none of them.
(define (local-reg n) (%+ $s3 n))
(define leaf-locals 8)
(define $caller-code $s11)

;; ---------------------------------------------------------------- context
;; What the compiler knows while it compiles one function.
(defrecord (context cx)
  asm env nlocals maxlocals free boxed name framefix outer nparams
  self-label self-arity leaf)

(define (make-context asm name outer-env)
  (let ((c (cx-alloc)))
    (set-cx-asm! c asm)
    (set-cx-nlocals! c 0)
    (set-cx-maxlocals! c 0)
    (set-cx-name! c name)
    (set-cx-framefix! c 0)
    (set-cx-outer! c outer-env)
    (set-cx-nparams! c 0)
    c))

(define (cx-alloc-local c)
  (let ((n (cx-nlocals c)))
    ;; The pre-pass bounds the local count before it decides a function is a
    ;; leaf, so reaching here means the bound was wrong.
    (if (cx-leaf c)
        (if (%>= n leaf-locals) (error "compile: leaf out of registers" (cx-name c)) nil)
        nil)
    (set-cx-nlocals! c (%+ n 1))
    (if (%> (%+ n 1) (cx-maxlocals c)) (set-cx-maxlocals! c (%+ n 1)) nil)
    n))

(define (cx-bind c sym loc)
  (set-cx-env! c (%cons (%cons sym loc) (cx-env c))))

(define (cx-lookup c sym) (assq sym (cx-env c)))

;; ---------------------------------------------------------------- expansion
;; Macros are expanded before anything looks at the tree, so the analysis
;; passes below only see the special forms.
;;
;; `macro-form?` and `expand-macro` are the two places where the compiler
;; depends on which side of the bootstrap it is running on: in the forge the
;; macros live in the interpreter, on the machine in the symbols' function
;; cells.
(define (macroexpand form)
  (let ((go t))
    (while go
      (if (macro-form? form)
          (set! form (expand-macro form))
          (set! go nil)))
    form))

(define (macroexpand-all form)
  (set! form (macroexpand form))
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'quote) form)
         ((%eq? h 'lambda)
          (%cons 'lambda (%cons (cadr form) (map macroexpand-all (cddr form)))))
         ((%eq? h 'define)
          (if (%cons? (cadr form))
              (%cons 'define (%cons (cadr form) (map macroexpand-all (cddr form))))
              (list 'define (cadr form)
                    (if (%cons? (cddr form)) (macroexpand-all (caddr form)) nil))))
         ((%eq? h 'defmacro) form)
         ((%eq? h 'let)
          (%cons 'let
                 (%cons (map (lambda (b)
                               (if (%cons? b)
                                   (list (%car b) (macroexpand-all (cadr b)))
                                   (list b nil)))
                             (cadr form))
                        (map macroexpand-all (cddr form)))))
         (else (map macroexpand-all form))))
      form))

;; ---------------------------------------------------------------- analysis
;; The variables a form assigns to.
(define (assigned-vars form acc)
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'quote) acc)
         ((%eq? h 'set!)
          (assigned-vars (caddr form) (%cons (cadr form) acc)))
         (else
          (dolist (x form) (set! acc (assigned-vars x acc)))
          acc)))
      acc))

;; The variables that appear free inside a nested lambda. A closure captures
;; those, and a captured variable that is also assigned has to live in a box
;; rather than in a stack slot.
(define (captured-vars form acc)
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'quote) acc)
         ((%eq? h 'lambda)
          (append2 (free-vars form nil) acc))
         (else
          (dolist (x form) (set! acc (captured-vars x acc)))
          acc)))
      acc))

;; The free variables of a form, given the names already bound.
(define (free-vars form bound)
  (cond
   ((%symbol? form) (if (memq form bound) nil (list form)))
   ((not (%cons? form)) nil)
   (else
    (let ((h (%car form)))
      (cond
       ((%eq? h 'quote) nil)
       ((%eq? h 'lambda)
        (free-vars (%cons 'begin (cddr form))
                   (append2 (param-names (cadr form)) bound)))
       ((%eq? h 'let)
        (let ((binds (cadr form)) (acc nil))
          (dolist (b binds)
            (set! acc (append2 (free-vars (cadr b) bound) acc)))
          (append2 acc
                   (free-vars (%cons 'begin (cddr form))
                              (append2 (map car binds) bound)))))
       ((%eq? h 'define)
        (if (%cons? (cadr form))
            (free-vars (%cons 'lambda (%cons (cdadr form) (cddr form))) bound)
            (free-vars (caddr form) (%cons (cadr form) bound))))
       ((%eq? h 'set!)
        (append2 (if (memq (cadr form) bound) nil (list (cadr form)))
                 (free-vars (caddr form) bound)))
       (else
        (let ((acc nil))
          (dolist (x form) (set! acc (append2 (free-vars x bound) acc)))
          acc)))))))

;; Parameter lists are (a b), (a . rest) or (a &rest r).
(define (param-names params)
  (let ((acc nil))
    (while (%cons? params)
      (let ((p (%car params)))
        (if (%eq? p '&rest) nil (set! acc (%cons p acc))))
      (set! params (%cdr params)))
    (if (%symbol? params) (set! acc (%cons params acc)) nil)
    (reverse acc)))

;; How many arguments must be supplied.
(define (param-required params)
  (let ((n 0))
    (while (%cons? params)
      (if (%eq? (%car params) '&rest)
          (set! params nil)
          (begin (set! n (%+ n 1)) (set! params (%cdr params)))))
    n))

;; The rest parameter, or nil for a fixed count.
(define (param-rest params)
  (let ((r nil))
    (while (%cons? params)
      (if (%eq? (%car params) '&rest)
          (begin (set! r (cadr params)) (set! params nil))
          (set! params (%cdr params))))
    (if (%symbol? params) (set! r params) nil)
    r))

;; ---------------------------------------------------------------- constants
;; nil is tp, a fixnum is the integer itself, and a character is its code
;; retagged. Anything else is loaded from one of the code object's literal
;; slots, so the code holds no address and the collector sees the value.
(define (emit-const c v reg)
  (let ((a (cx-asm c)))
    (cond
     ((%null? v) (i-mv a reg $tp))
     ((%fixnum? v) (i-li a reg v))
     ((%char? v)
      (i-li a reg (%char->int v))
      (i-retag a reg reg kind-fixnum kind-char))
     (else (emit-literal c (freeze v) reg)))))

;; A constant is read-only all the way down: the literal and every pair,
;; vector, string, byte object and bignum inside it lose SD and SC, so
;; (set-car! '(1 2) 3) and a store into the tail of a quoted list are both
;; refused. LM stays, because a load through a capability without it would
;; strip the symbols inside too, and (car '(a)) would not be eq? to 'a.
;; Symbols, records, closures and code objects are left as they are.
;;
;; Freezing rewrites the constant in place, so every literal that names an
;; object is the same capability, eq? to every other however many code
;; objects hold it. A capability to the object taken before it was compiled,
;; which only a macro splicing a live object into a quote can have, keeps
;; its permissions and is not eq? to the literal: it is a different
;; authority over the same object.
(define (frozen v) (%cap-and-perms v (%lognot (%logior perm-sd perm-sc))))

(define (writable? v) (%> (%logand (%cap-perms v) perm-sd) 0))

(define (freeze v)
  (cond
   ((%cons? v)
    ;; Along the spine by iteration, into each car by recursion.
    (let ((p v))
      (while (if (%cons? p) (writable? p) nil)
        (%set-car! p (freeze (%car p)))
        (let ((next (%cdr p)))
          (%set-cdr! p (if (%cons? next) (frozen next) (freeze next)))
          (set! p next))))
    (frozen v))
   ((%vector? v)
    (if (writable? v)
        (let ((i 0) (n (%vector-length v)))
          (while (%< i n)
            (%vector-set! v i (freeze (%vector-ref v i)))
            (set! i (%+ i 1))))
        nil)
    (frozen v))
   ((%string? v) (frozen v))
   ((%bytes? v) (frozen v))
   ((%bignum? v) (frozen v))
   (else v)))

(define (emit-literal c v reg)
  (let* ((a (cx-asm c))
         (off (literal-offset (literal a v))))
    (if (%>= off 2048)
        (error "compile: too many literals in" (cx-name c))
        nil)
    (i-lc a reg $s1 off)))

;; ---------------------------------------------------------------- records
;; The shape of a record and its accessor functions come from macros.lisp,
;; because the interpreter needs them too. What is here is the open-coding: a
;; call to an accessor becomes the tag check and one indexed instruction.
;;
;; The check loads slot 0, compares it with the type this code was compiled
;; against, and branches. The tag it wanted is left in t3 and the value it
;; was given is still in a0, so the trap can name both.
;;
;; An `open` record, one others are built on, has no check: the indexed load
;; still refuses anything that is not a record.
(define (emit-record-check c type open)
  (let ((a (cx-asm c)))
    (if open
        nil
        (let ((ok (gensym-label "rec")))
          (i-ldxi a $t2 $a0 0 t-record)
          (emit-literal c type $t3)
          (i-beqx a $t2 $t3 ok)
          (i-li a $a7 ecall-record)
          (i-ecall a)
          (label a ok)))))

(define (record-getter type open k)
  (let ((emit-ref (fixed-ref k t-record)))
    (lambda (c) (emit-record-check c type open) (%funcall emit-ref c))))

(define (record-setter type open k)
  (let ((emit-set (fixed-set k t-record)))
    (lambda (c) (emit-record-check c type open) (%funcall emit-set c))))

;; Slot k of an object of type ty: read from the object in a0 into a0, or
;; written from a1. The one indexed instruction checks the type and the
;; bound.
(define (fixed-ref k ty) (lambda (c) (i-ldxi (cx-asm c) $a0 $a0 k ty)))

(define (fixed-set k ty)
  (lambda (c)
    (i-stxi (cx-asm c) $a1 $a0 k ty)
    (i-mv (cx-asm c) $a0 $a1)))

(define (install-record-inlines! s)
  (let ((type (%car s))
        (prefix (shape-prefix s))
        (open (shape-open? s))
        (pkg (symbol-package (%car s)))
        (k 1))
    (dolist (f (shape-fields s))
      (let ((n (symbol-name f)))
        (definline (intern-in pkg (string-append prefix n))
                   1 (record-getter type open k))
        (definline (intern-in pkg (string-append "set-" prefix n "!"))
                   2 (record-setter type open k)))
      (set! k (%+ k 1)))
    s))

;; ---------------------------------------------------------------- variables
;; A location is (local n), (boxed-local n), (free n), (boxed-free n) or
;; (global sym).
(define (location-of c sym)
  (let ((p (cx-lookup c sym)))
    (if p (%cdr p) (list 'global sym))))

;; A local is a frame slot, or in a leaf a register. These three are the only
;; places that know which.
(define (load-local c n reg)
  (if (cx-leaf c)
      (i-mv (cx-asm c) reg (local-reg n))
      (i-lc (cx-asm c) reg $s0 (local-off n))))

(define (store-local c n reg)
  (if (cx-leaf c)
      (i-mv (cx-asm c) (local-reg n) reg)
      (i-sc (cx-asm c) reg $s0 (local-off n))))

;; Where this function's closure is, unsealed. A framed function saved it at
;; s0-24; a leaf still has it in t0, because a leaf calls nothing and nothing
;; else in a body touches t0.
(define (closure-reg c scratch)
  (if (cx-leaf c)
      $t0
      (begin (i-lc (cx-asm c) scratch $s0 clo-slot) scratch)))

;; A free variable is a slot of the unsealed closure, read and written with
;; `lc` and `sc` at its offset: the closure's own capability bounds the
;; access, and nothing but its own code holds that capability unsealed.
(define (free-off i) (slot-off (%+ clo-free i)))

(define (emit-load c loc reg)
  (let ((a (cx-asm c)) (kind (%car loc)))
    (cond
     ((%eq? kind 'local) (load-local c (cadr loc) reg))
     ((%eq? kind 'boxed-local)
      (load-local c (cadr loc) reg)
      (i-car a reg reg))
     ((%eq? kind 'free)
      (i-lc a reg (closure-reg c $t6) (free-off (cadr loc))))
     ((%eq? kind 'boxed-free)
      (i-lc a reg (closure-reg c $t6) (free-off (cadr loc)))
      (i-car a reg reg))
     ;; A global's value cell, through the load that refuses the unbound
     ;; marker: a name nothing was stored in is an error where it is read.
     (else
      (let ((sym (cadr loc)))
        (note-global-ref sym)
        (emit-literal c sym $t6)
        (i-lvar a reg $t6 (slot-off sym-value)))))))

;; Every global the compiler emits a reference to while the name is still
;; unbound is recorded, so a build can report a name compiled code will call
;; but nothing defines.
(define *global-refs* nil)

(define (note-global-ref sym)
  (if (%eq? (%symbol-value sym) (%unbound))
      (if (memq sym *global-refs*)
          nil
          (set! *global-refs* (%cons sym *global-refs*)))
      nil))

(define (undefined-globals)
  (filter (lambda (s) (%eq? (%symbol-value s) (%unbound))) *global-refs*))

;; A location's storage cell, without following a box. Capturing a boxed
;; variable takes the box itself, so that the closure and the frame go on
;; sharing one cell.
(define (emit-load-cell c loc reg)
  (let ((kind (%car loc)))
    (cond
     ((memq kind '(local boxed-local)) (load-local c (cadr loc) reg))
     ((memq kind '(free boxed-free))
      (i-lc (cx-asm c) reg (closure-reg c $t6) (free-off (cadr loc))))
     (else (emit-load c loc reg)))))

(define (boxed-location? loc)
  (if (%eq? (%car loc) 'boxed-local) t (%eq? (%car loc) 'boxed-free)))

(define (emit-store c loc reg)
  (let ((a (cx-asm c)) (kind (%car loc)))
    (cond
     ((%eq? kind 'local) (store-local c (cadr loc) reg))
     ((%eq? kind 'boxed-local)
      (load-local c (cadr loc) $t6)
      (i-set-car a reg $t6))
     ((%eq? kind 'free)
      (i-sc a reg (closure-reg c $t6) (free-off (cadr loc))))
     ((%eq? kind 'boxed-free)
      (let ((cr (closure-reg c $t6)))
        (i-lc a $t6 cr (free-off (cadr loc))))
      (i-set-car a reg $t6))
     ;; Through the typed store, which checks that the literal is a symbol.
     ;; Like every store it goes through the write barrier, which matters
     ;; here: a global's old value may be the last pointer to something the
     ;; collector has not reached yet.
     (else
      (let ((sym (cadr loc)))
        (emit-literal c sym $t6)
        (i-stxi a reg $t6 sym-value t-symbol))))))

;; ---------------------------------------------------------------- the stack
;; A temporary pushed under sp, one slot.
(define (emit-push c reg)
  (let ((a (cx-asm c)))
    (i-cincoffsetimm a $sp $sp (%- 0 value-bytes))
    (i-sc a reg $sp 0)))

;; ---------------------------------------------------------------- allocation
;; Inline cons. gp is bounded to the task's run of cons space and addresses
;; its next free pair, so a pair is its first sixteen bytes and the run moves
;; on by sixteen. When the run is used up, `csetboundsimm` faults on gp; the
;; trap handler gives the task a fresh run and the instruction runs again. A
;; collection begun there sees every register exactly, so nothing here says
;; which registers are live.
;;
;; The pair is built in t2 when the destination is also an operand.
(define (emit-cons c car-reg cdr-reg dst)
  (let* ((a (cx-asm c))
         (p (if (if (%= dst car-reg) t (%= dst cdr-reg)) $t2 dst)))
    (i-csetboundsimm a p $gp (%* 2 value-bytes))
    (i-cincoffsetimm a $gp $gp (%* 2 value-bytes))
    (i-sc a car-reg p 0)
    (i-sc a cdr-reg p value-bytes)
    (if (%= p dst) nil (i-mv a dst p))))

;; ---------------------------------------------------------------- booleans
;; A test that is not branched on at once has to make a value. Every test
;; here is a branch taken when it fails, and as a value that branch chooses
;; between t and nil. The test reads its operands before dst is written, so
;; dst may be one of them.
;;
;; The literal 't is resolved when this file is read, so it is the one symbol
;; the source means whatever package is current at compile time.
(define (emit-bool c dst jump-false)
  (let ((a (cx-asm c))
        (no (gensym-label "no"))
        (done (gensym-label "bool"))
        (tsym 't))
    (%funcall jump-false no)
    (emit-literal c tsym dst)
    (i-j a done)
    (label a no)
    (i-mv a dst $tp)
    (label a done)))

;; t when the integer in flag-reg is not zero.
(define (emit-bool-from-flag c flag-reg dst)
  (emit-bool c dst (lambda (no) (i-beqz (cx-asm c) flag-reg no))))

;; ---------------------------------------------------------------- predicates
;; A type test compares the kind `vkind` reports with the one it wants. An
;; untagged value reports its metadata, nil and a pair have kinds of their
;; own, and an object reports kind-object plus its header type, sealed or not.
(define (predicate-kind op)
  (cond
   ((%eq? op '%fixnum?) kind-fixnum)
   ((%eq? op '%char?) kind-char)
   ((%eq? op '%cons?) kind-pair)
   ((%eq? op '%symbol?) (%+ kind-object t-symbol))
   ((%eq? op '%string?) (%+ kind-object t-string))
   ((%eq? op '%vector?) (%+ kind-object t-vector))
   ((%eq? op '%bytes?) (%+ kind-object t-bytes))
   ((%eq? op '%closure?) (%+ kind-object t-closure))
   ((%eq? op '%record?) (%+ kind-object t-record))
   ((%eq? op '%float?) (%+ kind-object t-float))
   ((%eq? op '%bignum?) (%+ kind-object t-bignum))
   (else nil)))

(define (predicate? op)
  (cond ((%eq? op '%null?) t)
        ((%eq? op '%object?) t)
        ((predicate-kind op) t)
        (else nil)))

;; Jump to `label` unless the value in a0 passes. nil is the value in tp, so
;; the null test is one comparison of identity; every object's kind is at
;; least kind-object.
(define (emit-predicate-jump-false c op label)
  (let ((a (cx-asm c)))
    (cond
     ((%eq? op '%null?) (i-bnex a $a0 $tp label))
     ((%eq? op '%object?)
      (i-vkind a $t2 $a0)
      (i-li a $t3 kind-object)
      (i-blt a $t2 $t3 label))
     (else
      (let ((k (predicate-kind op)))
        (i-vkind a $t2 $a0)
        (if (%= k 0)
            (i-bnez a $t2 label)
            (begin
              (i-li a $t3 k)
              (i-bne a $t2 $t3 label))))))))

(define (predicate-emitter op)
  (lambda (c) (emit-bool c $a0 (lambda (no) (emit-predicate-jump-false c op no)))))

;; Jump to `label` unless the comparison of a0 with a1 holds. The numeric
;; ones go through `flt` and `feq`, which check their operands and widen for
;; bignums, then branch on the flag. `%eq?` is identity, exact in tag,
;; metadata and address, and branches directly.
(define (emit-compare-jump-false c op label)
  (let ((a (cx-asm c)))
    (cond
     ((%eq? op '%<) (i-flt a $t2 $a0 $a1) (i-beqz a $t2 label))
     ((%eq? op '%>) (i-flt a $t2 $a1 $a0) (i-beqz a $t2 label))
     ((%eq? op '%<=) (i-flt a $t2 $a1 $a0) (i-bnez a $t2 label))
     ((%eq? op '%>=) (i-flt a $t2 $a0 $a1) (i-bnez a $t2 label))
     ((%eq? op '%=) (i-feq a $t2 $a0 $a1) (i-beqz a $t2 label))
     (else (i-bnex a $a0 $a1 label)))))

(define (comparison? op) (memq op '(%< %> %<= %>= %= %eq?)))

(define (comparison-emitter op)
  (lambda (c) (emit-bool c $a0 (lambda (no) (emit-compare-jump-false c op no)))))

;; ---------------------------------------------------------------- prologue
(define (emit-prologue c nreq variadic)
  (let ((a (cx-asm c)) (ok (gensym-label "arity")))
    ;; Arity is checked before the frame exists, so a bad call cannot corrupt
    ;; anything on the way to the report.
    (i-li a $t2 nreq)
    (if variadic (i-bge a $t1 $t2 ok) (i-beq a $t1 $t2 ok))
    (i-li a $a7 ecall-arity)
    (i-ecall a)
    (label a ok)
    ;; A leaf builds nothing: it keeps its caller's code object in s11 and
    ;; picks up its own. sp does not move, s0 still names the caller's frame,
    ;; and ra survives because nothing here overwrites it.
    (if (cx-leaf c)
        (begin
          (i-mv a $caller-code $s1)
          (i-lc a $s1 $t0 (slot-off clo-code)))
        (begin
          ;; A call by a function to its own name can skip the check above:
          ;; the closure is the one in this frame and the count is known to
          ;; be right. Variadic functions are left alone, because the
          ;; rest-list code reads the count out of t1.
          (if variadic
              nil
              (begin (set-cx-self-label! c ok) (set-cx-self-arity! c nreq)))
          ;; The local slots are not cleared. Until a binding writes one it
          ;; holds whatever an earlier, deeper frame left there, which the
          ;; collector takes for a value: at most some floating garbage, and
          ;; clearing would cost a store per slot on every call.
          (i-mv a $t3 $sp)
          ;; The one instruction that knows the frame size, which size-frame
          ;; rewrites once the body is done, so it keeps its width.
          (set-cx-framefix! c (asm-len a))
          (i-cincoffsetimm-w a $sp $sp 0)
          (i-sc a $ra $t3 ra-slot)
          (i-sc a $s0 $t3 link-slot)
          (i-sc a $t0 $t3 clo-slot)
          (i-sc a $s1 $t3 code-slot)
          (i-mv a $s0 $t3)
          ;; s1 is this function's own code object, hanging off the closure.
          ;; Every constant, symbol and inner code object the body mentions
          ;; is one load from there.
          (i-lc a $s1 $t0 (slot-off clo-code))))))

(define (emit-epilogue c)
  (let ((a (cx-asm c)))
    (if (cx-leaf c)
        (i-mv a $s1 $caller-code)
        (begin
          (i-lc a $ra $s0 ra-slot)
          (i-lc a $t3 $s0 link-slot)
          (i-lc a $s1 $s0 code-slot)
          (i-mv a $sp $s0)
          (i-mv a $s0 $t3)))))

;; Once every local is known: size the frame and patch the prologue. A leaf
;; has no frame, and instead has its assumption checked.
(define (finish-frame c)
  (if (cx-leaf c) (check-leaf c) (size-frame c)))

;; The pre-pass decides leaf-ness from the source, and could be wrong. This
;; reads the code that came out: if anything in a leaf's own code links
;; through ra, the function would return to the wrong place, and a build
;; failure is the right outcome.
(define (check-leaf c)
  (let* ((a (cx-asm c))
         (buf (asm-buf a))
         (len (asm-len a))
         (i 0))
    (while (%< i len)
      (let ((lo (%logior (%bytes-ref buf i) (%lsh (%bytes-ref buf (%+ i 1)) 8))))
        (if (%= 3 (%logand lo 3))
            (let ((hi (%logior (%bytes-ref buf (%+ i 2))
                               (%lsh (%bytes-ref buf (%+ i 3)) 8))))
              (if (links-ra? lo hi)
                  (error "compile: a leaf that calls" (cx-name c))
                  nil)
              (set! i (%+ i 4)))
            (begin
              ;; c.jalr, which is c.ebreak when its register field is zero
              (if (%= #x9002 (%logand lo #xf07f))
                  (if (%> (%logand (%lsh lo -7) 31) 0)
                      (error "compile: a leaf that calls" (cx-name c))
                      nil)
                  nil)
              ;; c.jal, which nothing emits
              (if (%= #x2001 (%logand lo #xe003))
                  (error "compile: a leaf that calls" (cx-name c))
                  nil)
              (set! i (%+ i 2))))))
    0))

;; Whether a 32-bit instruction, as its low and high halves, writes a link
;; into ra: jal, jalr, jcl, or cjalr.
(define (links-ra? lo hi)
  (if (%= 1 (%logand (%lsh lo -7) 31))
      (let ((op (%logand lo 127))
            (f3 (%logand (%lsh lo -12) 7)))
        (cond
         ((%= op #x6f) t)
         ((%= op #x67) t)
         ((%= op #x0b) (%= f3 3))
         ((%= op #x5b)
          (if (%= f3 0)
              (if (%= (%lsh hi -9) #x7f) (%= (%logand (%lsh hi -4) 31) #x0c) nil)
              nil))
         (else nil)))
      nil))

(define (size-frame c)
  (let* ((a (cx-asm c))
         ;; Rounded up to sixteen with at least one spare slot below the last
         ;; local.
         (frame (%logand (%+ (%+ frame-fixed (%* value-bytes (cx-maxlocals c))) 15) -16))
         (off (cx-framefix c))
         (save (asm-len a)))
    (if (%> frame 2048) (error "compile: frame too large in" (cx-name c)) nil)
    (set-asm-len! a off)
    (i-cincoffsetimm-w a $sp $sp (%- 0 frame))
    (set-asm-len! a save)
    frame))

;; ---------------------------------------------------------------- intrinsics
;; What the compiler knows about a name lives on the symbol, in the function
;; slot, as (intrinsic . aliases):
;;
;;   intrinsic   (arity . emitter), or nil
;;   aliases     ((nargs . target-symbol) ...)
;;
;; The emitter is handed the context with the arguments in a0, a1, ... and
;; leaves the result in a0.
(define (compile-info sym) (%symbol-function sym))

(define *inline-syms* nil)   ; every symbol carrying one, so setup can reset

(define (compile-info! sym)
  (let ((ci (compile-info sym)))
    (if (%cons? ci)
        ci
        (let ((new (%cons nil nil)))
          (%set-symbol-function! sym new)
          (set! *inline-syms* (%cons sym *inline-syms*))
          new))))

;; The (arity . emitter) to open-code a call with, or nil. A symbol that is
;; itself an intrinsic wins, and an arity mismatch there is an error; an
;; ordinary name is open-coded only at the argument count its alias names.
(define (inline-entry sym nargs)
  (let ((ci (compile-info sym)))
    (if (%cons? ci)
        (if (%car ci)
            (%car ci)
            (let ((p (assq nargs (%cdr ci))))
              (if p (%car (compile-info (%cdr p))) nil)))
        nil)))

;; The intrinsic a name means at this argument count: an intrinsic itself,
;; the one its alias names, or the name unchanged.
(define (intrinsic-name sym nargs)
  (let ((ci (compile-info sym)))
    (if (%cons? ci)
        (if (%car ci)
            sym
            (let ((p (assq nargs (%cdr ci))))
              (if p (%cdr p) sym)))
        sym)))

;; Ordinary names that mean an intrinsic at the right argument count, so
;; that (< i n) in a loop is one instruction rather than a call to the
;; variadic `<`. Redefining one of these does not affect code already
;; compiled against it.
;;
;; `+`, `-` and `*` are the trapping forms, so two-argument arithmetic
;; promotes to a bignum the way the variadic ones do. `ash` has no alias:
;; `%ash` takes the shift count modulo 32, which is wrong for (ash 1 100).
;; `peek` and `poke` have none: what they make of a word's top bit is for
;; hw.lisp to say.
(define *inline-aliases*
  '((+ 2 %+o) (- 2 %-o) (* 2 %*o) (/ 2 %/) (mod 2 %mod) (rem 2 %rem)
    (= 2 %=) (< 2 %<) (> 2 %>) (<= 2 %<=) (>= 2 %>=)
    (eq? 2 %eq?) (null? 1 %null?)
    (car 1 %car) (cdr 1 %cdr) (cons 2 %cons)
    (set-car! 2 %set-car!) (set-cdr! 2 %set-cdr!)
    (pair? 1 %cons?) (symbol? 1 %symbol?) (string? 1 %string?)
    (vector? 1 %vector?) (fixnum? 1 %fixnum?)
    (char? 1 %char?)
    (vector-ref 2 %vector-ref) (vector-set! 3 %vector-set!)
    (vector-length 1 %vector-length)
    (string-ref 2 %string-ref) (string-set! 3 %string-set!)
    (string-length 1 %string-length)
    (bytes-ref 2 %bytes-ref) (bytes-set! 3 %bytes-set!)
    (bytes-length 1 %bytes-length)
    (char->integer 1 %char->int) (integer->char 1 %int->char)
    (logand 2 %logand) (logior 2 %logior) (logxor 2 %logxor)
    (lognot 1 %lognot) (lsh 2 %lsh)
    (peek8 1 %ld-byte) (poke8 2 %st-byte!)
    (min 2 %min) (max 2 %max) (min2 2 %min) (max2 2 %max)))

(define (definline name arity fn)
  (%set-car! (compile-info! name) (%cons arity fn)))

(define (defalias name nargs target)
  (let ((ci (compile-info! name)))
    (%set-cdr! ci (%cons (%cons nargs target) (%cdr ci)))))

;; Emitters for the intrinsics that are one instruction, from a0, or from a0
;; and a1, into a0; and the same answering t or nil from the flag the
;; instruction leaves.
(define (one-op op) (lambda (c) (%funcall op (cx-asm c) $a0 $a0)))
(define (two-op op) (lambda (c) (%funcall op (cx-asm c) $a0 $a0 $a1)))

(define (one-test op)
  (lambda (c)
    (%funcall op (cx-asm c) $t2 $a0)
    (emit-bool-from-flag c $t2 $a0)))

(define (two-test op)
  (lambda (c)
    (%funcall op (cx-asm c) $t2 $a0 $a1)
    (emit-bool-from-flag c $t2 $a0)))

;; A load or a store through the capability in a0 moved by the byte offset
;; in a1. The access is checked against the capability's own bounds and
;; permissions, so it cannot reach past what the caller was given.
(define (cap-load op)
  (lambda (c)
    (let ((a (cx-asm c)))
      (i-cincoffset a $t2 $a0 $a1)
      (%funcall op a $a0 $t2 0))))

(define (cap-store op)
  (lambda (c)
    (let ((a (cx-asm c)))
      (i-cincoffset a $t2 $a0 $a1)
      (%funcall op a $a2 $t2 0)
      (i-mv a $a0 $a2))))

;; ---------------------------------------------------------------- constant argument
;; A second operand that is written down needs no register and no instruction
;; to load it, and a shift by a written-down amount needs no run-time choice
;; of direction. Entries are (name fits? emitter); the emitter is handed the
;; context and the constant, with the first argument in a0. A name that
;; aliases one of these, such as `+` for `%+o`, is found through its alias.
(define *const-arg* nil)

;; The immediate is the constant itself, twelve signed bits, and a
;; subtraction adds the negation, which has to fit as well.
(define (fits-imm? k) (if (%>= k -2048) (%< k 2048) nil))
(define (fits-negated-imm? k) (if (%> k -2048) (%<= k 2048) nil))
(define (shift-amount? k) (if (%> k -32) (%< k 32) nil))

(define (const-arg-entry h args)
  (let ((e (assq (intrinsic-name h 2) *const-arg*)))
    (if e
        (if (%= (length args) 2)
            (let ((k (cadr args)))
              (if (%fixnum? k) (if (%funcall (cadr e) k) e nil) nil))
            nil)
        nil)))

(define (emit-const-arg c e args tail)
  (compile-expr c (%car args) nil)
  (%funcall (caddr e) c (cadr args))
  (if tail (emit-return c) nil))

;; `faddi` wraps and `faddio` traps on overflow, which the handler widens.
(define (emit-add-const c k) (i-faddi (cx-asm c) $a0 $a0 k))
(define (emit-sub-const c k) (i-faddi (cx-asm c) $a0 $a0 (%- 0 k)))
(define (emit-add-const-o c k) (i-faddio (cx-asm c) $a0 $a0 k))
(define (emit-sub-const-o c k) (i-faddio (cx-asm c) $a0 $a0 (%- 0 k)))
(define (emit-and-const c k) (i-fandi (cx-asm c) $a0 $a0 k))
(define (emit-or-const c k) (i-fori (cx-asm c) $a0 $a0 k))

(define (emit-shift-const c k arith)
  (let ((a (cx-asm c)))
    (if (%= k 0)
        nil
        (if (%> k 0)
            (i-fshi a $a0 $a0 0 k)
            (i-fshi a $a0 $a0 (if arith 2 1) (%- 0 k))))))

(define (emit-lsh-const c k) (emit-shift-const c k nil))
(define (emit-ash-const c k) (emit-shift-const c k t))

;; A load at a written-down offset within a capability is the load's own
;; offset field.
(define (cap-load-const op)
  (lambda (c k) (%funcall op (cx-asm c) $a0 $a0 k)))

(define (setup-const-arg)
  (set! *const-arg*
        (list (list '%+ fits-imm? emit-add-const)
              (list '%- fits-negated-imm? emit-sub-const)
              (list '%+o fits-imm? emit-add-const-o)
              (list '%-o fits-negated-imm? emit-sub-const-o)
              (list '%logand fits-imm? emit-and-const)
              (list '%logior fits-imm? emit-or-const)
              (list '%lsh shift-amount? emit-lsh-const)
              (list '%ash shift-amount? emit-ash-const)
              (list '%cap-ld fits-imm? (cap-load-const i-lc))
              (list '%cap-ld-word fits-imm? (cap-load-const i-lw))
              (list '%cap-ld-byte fits-imm? (cap-load-const i-lbu)))))

;; ---------------------------------------------------------------- constant index
;; An index that is written down, which every record field and closure slot
;; is, goes in the instruction: the immediate form of custom-1 carries
;; indices 0 to 31. Entries are (name type store?); the index is the second
;; argument for the load and the store both.
(define *indexed-imm* nil)

(define (indexed-imm-entry h args)
  (let ((e (assq h *indexed-imm*)))
    (if e
        (let* ((store (caddr e))
               (want (if store 3 2))
               (idx (if (%= (length args) want) (cadr args) nil)))
          (if (%fixnum? idx)
              (if (%>= idx 0) (if (%< idx 32) e nil) nil)
              nil))
        nil)))

(define (emit-indexed-imm c e args tail)
  (let ((ty (cadr e))
        (i (cadr args)))
    (if (caddr e)
        (begin
          (compile-args c (list (%car args) (caddr args)) 2)
          (%funcall (fixed-set i ty) c))
        (begin
          (compile-expr c (%car args) nil)
          (%funcall (fixed-ref i ty) c)))
    (if tail (emit-return c) nil)))

;; This runs once in the forge and again on the machine, so it starts by
;; clearing every emitter it left on a symbol before.
(define (setup-intrinsics)
  (dolist (s *inline-syms*) (%set-symbol-function! s nil))
  (set! *inline-syms* nil)
  (set! *indexed-imm*
        (list (list '%slot 0 nil) (list '%set-slot! 0 t)
              (list '%record-ref t-record nil) (list '%record-set! t-record t)
              (list '%vector-ref t-vector nil) (list '%vector-set! t-vector t)))
  (setup-const-arg)

  ;; ---- pairs ----
  ;; One custom-0 instruction each, with the base checked on the way past.
  (definline '%car 1 (lambda (c) (i-car (cx-asm c) $a0 $a0)))
  (definline '%cdr 1 (lambda (c) (i-cdr (cx-asm c) $a0 $a0)))
  (definline '%set-car! 2
    (lambda (c) (i-set-car (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%set-cdr! 2
    (lambda (c) (i-set-cdr (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%cons 2 (lambda (c) (emit-cons c $a0 $a1 $a0)))

  ;; ---- fixnum arithmetic ----
  ;; One checked instruction each. The operands are checked to be fixnums,
  ;; and the trap handler widens an operation with a bignum in it.
  (definline '%+ 2 (two-op i-fadd))
  (definline '%- 2 (two-op i-fsub))
  (definline '%* 2 (two-op i-fmul))
  ;; The same three, trapping rather than wrapping when the answer does not
  ;; fit in 32 bits. `+`, `-` and `*` are made of these: the trap handler
  ;; widens the operation into a bignum and resumes, so an integer that fits
  ;; costs one instruction.
  (definline '%+o 2 (two-op i-faddo))
  (definline '%-o 2 (two-op i-fsubo))
  (definline '%*o 2 (two-op i-fmulo))
  (definline '%/ 2 (two-op i-fdiv))
  (definline '%rem 2 (two-op i-frem))
  ;; Euclidean: the sign of the result follows the divisor.
  (definline '%mod 2
    (lambda (c)
      (let ((a (cx-asm c)) (done (gensym-label "mod")))
        (i-frem a $t2 $a0 $a1)
        (i-beqz a $t2 done)
        (i-fxor a $t4 $t2 $a1)
        (i-bge a $t4 $zero done)
        (i-fadd a $t2 $t2 $a1)
        (label a done)
        (i-mv a $a0 $t2))))

  ;; ---- bitwise ----
  (definline '%logand 2 (two-op i-fand))
  (definline '%logior 2 (two-op i-for))
  (definline '%logxor 2 (two-op i-fxor))
  (definline '%lognot 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t2 -1)
        (i-fxor a $a0 $a0 $t2))))

  ;; A shift whose direction is only known at run time branches on it. A
  ;; shift by a written-down amount is one instruction; see emit-shift-const.
  (definline '%ash 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (gensym-label "ash"))
            (done (gensym-label "ash")))
        (i-blt a $a1 $zero right)
        (i-fsll a $a0 $a0 $a1)
        (i-j a done)
        (label a right)
        (i-fsub a $t2 $zero $a1)
        (i-fsra a $a0 $a0 $t2)
        (label a done))))
  (definline '%lsh 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (gensym-label "lsh"))
            (done (gensym-label "lsh")))
        (i-blt a $a1 $zero right)
        (i-fsll a $a0 $a0 $a1)
        (i-j a done)
        (label a right)
        (i-fsub a $t2 $zero $a1)
        (i-fsrl a $a0 $a0 $t2)
        (label a done))))

  ;; ---- comparisons and type tests producing a value ----
  ;; The same branches a test position uses, choosing between t and nil.
  (dolist (op '(%< %> %<= %>= %= %eq?))
    (definline op 2 (comparison-emitter op)))
  (dolist (op '(%null? %fixnum? %char? %cons? %object? %symbol? %string?
                %vector? %bytes? %closure? %record? %float? %bignum?))
    (definline op 1 (predicate-emitter op)))

  ;; ---- object access ----
  ;; The header type is the object's kind less kind-object, which `vkind`
  ;; reports for a sealed closure as for anything else. A value whose kind is
  ;; below that is not an object, and the `lhdr` on that path traps naming
  ;; it. `lhdr` reads the length from an object's header, refusing anything
  ;; that is not an object, or not of the type given when one is.
  (definline '%obj-type 1
    (lambda (c)
      (let ((a (cx-asm c)) (ok (gensym-label "otype")))
        (i-vkind a $t2 $a0)
        (i-addi a $t2 $t2 (%- 0 kind-object))
        (i-bge a $t2 $zero ok)
        (i-lhdr a $t3 $a0 0)
        (label a ok)
        (i-mv a $a0 $t2))))
  (definline '%obj-len 1 (lambda (c) (i-lhdr (cx-asm c) $a0 $a0 0)))
  ;; One instruction that checks the tag, the index and the bound. Type 0
  ;; means any object: a slot is a slot, whatever holds it. That is right for
  ;; the few places that reach into a symbol, a closure or a code object by
  ;; index; anything that knows it holds a record says so with `%record-ref`.
  (definline '%slot 2
    (lambda (c) (i-ldx (cx-asm c) $a0 $a0 $a1 0)))
  (definline '%set-slot! 3
    (lambda (c)
      (i-stx (cx-asm c) $a2 $a0 $a1 0)
      (i-mv (cx-asm c) $a0 $a2)))
  (definline '%record-ref 2
    (lambda (c) (i-ldx (cx-asm c) $a0 $a0 $a1 t-record)))
  (definline '%record-set! 3
    (lambda (c)
      (i-stx (cx-asm c) $a2 $a0 $a1 t-record)
      (i-mv (cx-asm c) $a0 $a2)))

  ;; These name the type they require, so (vector-ref "abc" 0) traps.
  (definline '%vector-ref 2
    (lambda (c) (i-ldx (cx-asm c) $a0 $a0 $a1 t-vector)))
  (definline '%vector-set! 3
    (lambda (c)
      (i-stx (cx-asm c) $a2 $a0 $a1 t-vector)
      (i-mv (cx-asm c) $a0 $a2)))
  (definline '%vector-length 1 (lambda (c) (i-lhdr (cx-asm c) $a0 $a0 t-vector)))
  (definline '%string-length 1 (lambda (c) (i-lhdr (cx-asm c) $a0 $a0 t-string)))
  (definline '%bytes-length 1 (lambda (c) (i-lhdr (cx-asm c) $a0 $a0 t-bytes)))
  ;; A string holds the codes of its characters, a byte each; a character is
  ;; its code retagged, and `retag` checks the kind it was given on the way.
  (definline '%string-ref 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-ldxb a $a0 $a0 $a1 t-string)
        (i-retag a $a0 $a0 kind-fixnum kind-char))))
  (definline '%string-set! 3
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-retag a $t3 $a2 kind-char kind-fixnum)
        (i-stxb a $t3 $a0 $a1 t-string)
        (i-mv a $a0 $a2))))
  (definline '%bytes-ref 2
    (lambda (c) (i-ldxb (cx-asm c) $a0 $a0 $a1 t-bytes)))
  (definline '%bytes-set! 3
    (lambda (c)
      (i-stxb (cx-asm c) $a2 $a0 $a1 t-bytes)
      (i-mv (cx-asm c) $a0 $a2)))

  ;; ---- characters ----
  (definline '%char->int 1
    (lambda (c) (i-retag (cx-asm c) $a0 $a0 kind-char kind-fixnum)))
  (definline '%int->char 1
    (lambda (c) (i-retag (cx-asm c) $a0 $a0 kind-fixnum kind-char)))

  ;; ---- raw memory ----
  ;; Memory named by an integer address, through DDC: the root. A word
  ;; loaded is a fixnum, a half or a byte comes back zero-extended, and a
  ;; capability comes back with its tag. These are the escape hatch, and the
  ;; processor refuses them to code without SR.
  (definline '%root 0
    (lambda (c) (i-cspecialrw (cx-asm c) $a0 scr-ddc $zero)))
  (definline '%from-addr 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-cspecialrw a $t2 scr-ddc $zero)
        (i-csetaddr a $a0 $t2 $a0))))
  (definline '%ld-word 1 (one-op i-lw-ddc))
  (definline '%ld-half 1 (one-op i-lhu-ddc))
  (definline '%ld-byte 1 (one-op i-lbu-ddc))
  (definline '%ld-cap 1 (one-op i-lc-ddc))
  (definline '%st-word! 2
    (lambda (c) (i-sw-ddc (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%st-half! 2
    (lambda (c) (i-sh-ddc (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%st-byte! 2
    (lambda (c) (i-sb-ddc (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%st-cap! 2
    (lambda (c) (i-sc-ddc (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))

  ;; ---- capabilities ----
  ;; The operations on a capability the caller already holds. A load or a
  ;; store is bounded by it, and everything that makes a new one from it can
  ;; only narrow it, seal it, or clear its tag, so none of these is unsafe.
  ;; Offsets are in bytes.
  (definline '%cap-ld 2 (cap-load i-lc))
  (definline '%cap-st! 3 (cap-store i-sc))
  (definline '%cap-ld-word 2 (cap-load i-lw))
  (definline '%cap-st-word! 3 (cap-store i-sw))
  (definline '%cap-ld-byte 2 (cap-load i-lbu))
  (definline '%cap-st-byte! 3 (cap-store i-sb))
  ;; The address of anything, as a fixnum: a pointer's, or an immediate's
  ;; payload. Following it again takes the root.
  (definline '%addr-of 1 (one-op i-cgetaddr))
  (definline '%cap-base 1 (one-op i-cgetbase))
  (definline '%cap-len 1 (one-op i-cgetlen))
  (definline '%cap-top 1 (one-op i-cgettop))
  (definline '%cap-perms 1 (one-op i-cgetperm))
  (definline '%cap-otype 1 (one-op i-cgettype))
  (definline '%cap-offset 1 (one-op i-cgetoffset))
  (definline '%cap-high 1 (one-op i-cgethigh))
  (definline '%cap-tag? 1 (one-test i-cgettag))
  (definline '%cap-sealed? 1 (one-test i-cgetsealed))
  (definline '%cap-set-addr 2 (two-op i-csetaddr))
  (definline '%cap-inc 2 (two-op i-cincoffset))
  (definline '%cap-bounds 2 (two-op i-csetbounds))
  (definline '%cap-bounds-exact 2 (two-op i-csetboundsexact))
  (definline '%cap-and-perms 2 (two-op i-candperm))
  (definline '%cap-clear-tag 1 (one-op i-ccleartag))
  (definline '%cap-seal-entry 1 (one-op i-csealentry))
  ;; A closure object sealed as a closure, which only `jcl` opens again:
  ;; anyone may seal their own closure, and nobody may open one.
  (definline '%cap-seal-closure 1 (one-op i-csealclo))
  ;; With an authority that has SE and whose address is the otype.
  (definline '%cap-seal 2 (two-op i-cseal))
  (definline '%cap-unseal 2 (two-op i-cunseal))
  ;; Untagged, with the metadata given: how an immediate is made from parts.
  (definline '%cap-set-high 2 (two-op i-csethigh))
  (definline '%cap=? 2 (two-test i-cseqx))
  ;; (%cap-subset? a b): whether b's bounds and permissions lie within a's,
  ;; both tagged or both not. `ctestsubset` asks it of its second operand
  ;; against its first.
  (definline '%cap-subset? 2
    (lambda (c)
      (i-ctestsubset (cx-asm c) $t2 $a0 $a1)
      (emit-bool-from-flag c $t2 $a0)))
  ;; The length and the alignment mask the processor would round a request
  ;; for n bytes to, so an allocator can pad an object to bounds it can have.
  (definline '%rrl 1 (one-op i-crrl))
  (definline '%ram 1 (one-op i-cram))

  ;; ---- min and max ----
  ;; The comparison is `flt`, which checks its operands and widens through
  ;; the trap handler. The choice is a branch: an operand may be a bignum,
  ;; and selecting through integer instructions would drop its tag.
  (definline '%min 2
    (lambda (c)
      (let ((a (cx-asm c)) (done (gensym-label "min")))
        (i-flt a $t2 $a0 $a1)
        (i-bnez a $t2 done)
        (i-mv a $a0 $a1)
        (label a done))))
  (definline '%max 2
    (lambda (c)
      (let ((a (cx-asm c)) (done (gensym-label "max")))
        (i-flt a $t2 $a1 $a0)
        (i-bnez a $t2 done)
        (i-mv a $a0 $a1)
        (label a done))))

  ;; ---- bits ----
  (definline '%popcount 1 (one-op i-cpop))

  ;; A bit array at an integer address, indexed by bit number: the
  ;; collector's mark map. The map is addressed a word at a time, which puts
  ;; the low five bits of the index where `bext` and `bset` look for them. On
  ;; a little-endian machine bit i of the word at (i >> 5) is bit i & 7 of
  ;; the byte at (i >> 3), so the blitter can still clear a map by the byte.
  (definline '%bit-ref 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srli a $t4 $a1 5)
        (i-sh2add a $t4 $t4 $a0)
        (i-lw-ddc a $t4 $t4)
        (i-bext a $t2 $t4 $a1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%bit-set! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srli a $t4 $a1 5)
        (i-sh2add a $t4 $t4 $a0)
        (i-lw-ddc a $t5 $t4)
        (i-bset a $t5 $t5 $a1)
        (i-sw-ddc a $t5 $t4)
        (i-mv a $a0 $tp))))

  ;; ---- symbols ----
  ;; Through the typed indexed access, so the one instruction also checks
  ;; that it was given a symbol: these are in the checked vocabulary.
  (definline '%symbol-name 1 (fixed-ref sym-name t-symbol))
  (definline '%symbol-value 1 (fixed-ref sym-value t-symbol))
  (definline '%set-symbol-value! 2 (fixed-set sym-value t-symbol))
  ;; What a reference to this name sees, and how to change it. On the machine
  ;; that is the symbol's value cell, so these are `%symbol-value` again. They
  ;; are spelled apart because the forge's interpreter keeps its own globals
  ;; in a map of its own, and a fluid binding has to land in the world doing
  ;; the reading.
  (definline '%fluid-value 1 (fixed-ref sym-value t-symbol))
  (definline '%set-fluid-value! 2 (fixed-set sym-value t-symbol))
  (definline '%symbol-function 1 (fixed-ref sym-function t-symbol))
  (definline '%set-symbol-function! 2 (fixed-set sym-function t-symbol))
  (definline '%symbol-plist 1 (fixed-ref sym-plist t-symbol))
  (definline '%set-symbol-plist! 2 (fixed-set sym-plist t-symbol))
  (definline '%symbol-flags 1 (fixed-ref sym-flags t-symbol))
  (definline '%set-symbol-flags! 2 (fixed-set sym-flags t-symbol))

  ;; ---- machine ----
  ;; Which task is running: s2, dedicated for the life of the machine like gp,
  ;; and switched with the rest of the registers. It is nil before
  ;; there is an Exec.
  (definline '%this-task 0 (lambda (c) (i-mv (cx-asm c) $a0 $s2)))
  (definline '%set-this-task! 1
    (lambda (c) (i-mv (cx-asm c) $s2 $a0)))

  ;; The stack pointer, as the capability it is: bounded to the task's stack.
  (definline '%stack-pointer 0
    (lambda (c) (i-mv (cx-asm c) $a0 $sp)))

  ;; The cons run is gp, bounded to the run and addressing its next free
  ;; pair; see gc.lisp. Reading it and replacing it are one move each.
  (definline '%cons-run 0
    (lambda (c) (i-mv (cx-asm c) $a0 $gp)))
  (definline '%set-cons-run! 1
    (lambda (c) (i-mv (cx-asm c) $gp $a0)))

  ;; A synchronous trap with a reason in a7. This is how a task asks to be
  ;; rescheduled: the switch happens inside the trap handler, where the whole
  ;; register set is already saved.
  (definline '%ecall 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-mv a $a7 $a0)
        (i-ecall a)
        (i-mv a $a0 $tp))))

  ;; The register context MScratchC names, as a capability: inside a trap,
  ;; the block the interrupted code was saved into. The trap stub restores
  ;; from whatever MScratchC names on its way out, so setting it is the
  ;; context switch.
  (definline '%context 0
    (lambda (c) (i-cspecialrw (cx-asm c) $a0 scr-mscratchc $zero)))
  (definline '%set-context! 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-cspecialrw a $zero scr-mscratchc $a0)
        (i-mv a $a0 $tp))))

  ;; Let the timer, the chips and software interrupts through.
  (definline '%enable-interrupt-lines 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t2 2184)              ; MTIE | MEIE | MSIE
        (i-csrrs a $zero csr-mie $t2)
        (i-mv a $a0 $tp))))

  ;; Stop the processor until something interrupts it.
  (definline '%wait-for-interrupt 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-wfi a)
        (i-mv a $a0 $tp))))

  ;; The immediate that marks a variable with no value yet. A constant, not
  ;; a global: a global holding it could not be read.
  (definline '%unbound 0
    (lambda (c) (i-retag (cx-asm c) $a0 $zero kind-fixnum kind-unbound)))
  ;; The low thirty-two bits of the cycle counter, as a fixnum. A difference
  ;; taken with the wrapping `%-` is right up to 2^31 cycles.
  (definline '%cycles 0
    (lambda (c) (i-csrrs (cx-asm c) $a0 csr-cycle $zero)))

  ;; The lowest address the stack pointer may reach before the processor
  ;; faults; see `task-stack-limit` in exec.lisp. An integer address.
  (definline '%set-stack-limit! 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrw a $zero csr-stklim $a0)
        (i-mv a $a0 $tp))))
  (definline '%stack-limit 0
    (lambda (c) (i-csrrs (cx-asm c) $a0 csr-stklim $zero)))
  ;; The write barrier: 1 to turn it on, 0 to turn it off. See `gc:start`.
  (definline '%set-gc-mode! 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrw a $zero csr-gcmode $a0)
        (i-mv a $a0 $tp))))
  ;; The system device's first register stops the machine with the exit code
  ;; written to it. A device page is named by its address, through DDC.
  (definline '%halt 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t3 mmio-base)
        (i-sw-ddc a $a0 $t3))))
  ;; Turning interrupts off answers whether they were on, as 1 or 0, which is
  ;; what makes a critical section nestable without a counter: every caller
  ;; puts back what it found.
  (definline '%disable 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrci a $a0 csr-mstatus 8)
        (i-srli a $a0 $a0 3)
        (i-andi a $a0 $a0 1))))
  ;; Put them back the way `%disable` found them. The saved fixnum becomes
  ;; the MIE bit or zero, and setting no bits changes nothing.
  (definline '%restore-interrupts 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slli a $a0 $a0 3)
        (i-csrrs a $zero csr-mstatus $a0)
        (i-mv a $a0 $tp))))
  ;; A trap returns through mret, which puts back the interrupt state the
  ;; faulting code had. An error abandons that code and must not inherit its
  ;; critical section, so this sets the bit mret restores from. The immediate
  ;; form of the CSR instructions carries five bits and this is bit seven, so
  ;; it goes through a register.
  (definline '%enable-after-trap 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t2 128)
        (i-csrrs a $zero csr-mstatus $t2)
        (i-mv a $a0 $tp))))
  ;; Unconditional, for the places that establish a state rather than
  ;; restore one: the kernel starting up, and a task that ends.
  (definline '%enable 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrsi a $zero csr-mstatus 8)
        (i-mv a $a0 $tp))))

  (dolist (e *inline-aliases*)
    (defalias (%car e) (cadr e) (caddr e)))
  nil)

;; ---------------------------------------------------------------- branches
;; A test feeding an `if` or a `while` never builds a value: it becomes the
;; branch. Jump to `label` when the test is false.
(define (emit-test-jump-false c form label)
  (let* ((a (cx-asm c))
         (op (if (%cons? form) (%car form) nil))
         (n (if (%cons? form) (length (%cdr form)) 0)))
    (cond
     ((if (%= n 1) (predicate? op) nil)
      (compile-expr c (cadr form) nil)
      (emit-predicate-jump-false c op label))
     ((if (%= n 2) (comparison? op) nil)
      (compile-args c (%cdr form) 2)
      (emit-compare-jump-false c op label))
     ;; An `if` in a test position is `and`, `or` or `not` spelled out, and
     ;; is walked rather than built: each arm's test becomes its own branch.
     ;; `and` expands to (if a b nil), `or` to (if a a b) through a binding,
     ;; and the kernel's hand-nested (if (if a b nil) c nil) is the same shape.
     ((%eq? op 'if)
      (emit-if-test-jump-false c form label))
     ;; Anything but nil is true.
     (else
      (compile-expr c form nil)
      (i-beqx a $a0 $tp label)))))

;; The `if` case of the above: jump to `fail` when (if test then else) is
;; false, without building its value.
(define (emit-if-test-jump-false c form fail)
  (let* ((a (cx-asm c))
         (test (cadr form))
         (then (caddr form))
         (else-form (if (%cons? (cdddr form)) (cadddr form) nil))
         (l-else (gensym-label "tor"))
         (l-end (gensym-label "tend")))
    (cond
     ;; (if a b nil): both must hold
     ((%null? else-form)
      (emit-test-jump-false c test fail)
      (emit-test-jump-false c then fail))
     ;; (if a a b): either will do
     ((if (%symbol? test) (%eq? test then) nil)
      (emit-test-jump-false c test l-else)
      (i-j a l-end)
      (label a l-else)
      (emit-test-jump-false c else-form fail)
      (label a l-end))
     ;; (if a nil b): the first must fail and the second hold
     ((%null? then)
      (emit-test-jump-false c test l-else)
      (i-j a fail)
      (label a l-else)
      (emit-test-jump-false c else-form fail))
     (else
      (emit-test-jump-false c test l-else)
      (emit-test-jump-false c then fail)
      (i-j a l-end)
      (label a l-else)
      (emit-test-jump-false c else-form fail)
      (label a l-end)))))

;; ---------------------------------------------------------------- arguments
;; Simple arguments go straight to their register. Anything that can run code
;; is evaluated first and parked on the stack, so evaluation order is left to
;; right.
(define (simple-arg? form)
  (if (%cons? form) (%eq? (%car form) 'quote) t))

;; Leaves argument i in register a{i}.
(define (compile-args c args n)
  (let ((a (cx-asm c)) (plan nil) (pushed 0) (i 0))
    ;; pass one: evaluate and park the complicated ones
    (dolist (x args)
      (if (simple-arg? x)
          (set! plan (%cons (%cons 'simple x) plan))
          (begin
            (compile-expr c x nil)
            (emit-push c $a0)
            (set! plan (%cons (%cons 'stack pushed) plan))
            (set! pushed (%+ pushed 1)))))
    (set! plan (reverse plan))
    ;; pass two: the parked values, while sp still points at them
    (set! i 0)
    (dolist (p plan)
      (if (%eq? (%car p) 'stack)
          (i-lc a (%+ $a0 i) $sp (%* value-bytes (%- (%- pushed 1) (%cdr p))))
          nil)
      (set! i (%+ i 1)))
    (if (%> pushed 0) (i-cincoffsetimm a $sp $sp (%* value-bytes pushed)) nil)
    ;; pass three: the simple ones, which cannot disturb anything
    (set! i 0)
    (dolist (p plan)
      (if (%eq? (%car p) 'simple)
          (compile-simple-into c (%cdr p) (%+ $a0 i))
          nil)
      (set! i (%+ i 1)))
    n))

(define (compile-simple-into c form reg)
  (cond
   ((%symbol? form) (emit-load c (location-of c form) reg))
   ((if (%cons? form) (%eq? (%car form) 'quote) nil)
    (emit-const c (cadr form) reg))
   (else (emit-const c form reg))))

;; ---------------------------------------------------------------- calls
;; A call loads the closure into t0 and the argument count into t1, and is
;; `jcl ra, t0`: the processor checks that t0 is a closure, unseals it into
;; t0 for the callee, and jumps to its slot 0. Calling anything that is not
;; a closure traps with a report. A tail call is `jcl zero, t0` once the
;; frame is gone.
;;
;; Arguments nine and up are pushed, so that argument eight lands at 0(sp) on
;; entry and the callee finds the rest above it. A tail call cannot do that,
;; because its epilogue moves the stack out from under them.
(define (compile-call c form tail)
  (let ((n (length (%cdr form))))
    (if (%> n 8)
        (if tail
            (begin (compile-call c form nil) (emit-return c))
            (compile-call-many c form))
        (compile-call-few c form tail))))

;; More than eight arguments. The operator, if it needs evaluating, goes on
;; the stack first. Every argument is then evaluated left to right onto the
;; stack; the first eight are lifted into registers and the rest are left
;; where they are, reversed so that argument eight sits at 0(sp). The
;; callee's frame pointer is the stack pointer it was entered with, so it
;; reads argument 8+j at 8j(s0).
(define (compile-call-many c form)
  (let* ((a (cx-asm c))
         (op (%car form))
         (args (%cdr form))
         (n (length args))
         (extra (%- n 8))
         (op-on-stack (if (%symbol? op) nil t))
         (i 0))
    (if op-on-stack
        (begin
          (compile-expr c op nil)
          (emit-push c $a0))
        nil)
    (dolist (x args)
      (compile-expr c x nil)
      (emit-push c $a0))
    ;; Pushed left to right, so argument k is n-1-k slots from the top.
    (while (%< i 8)
      (i-lc a (%+ $a0 i) $sp (%* value-bytes (%- (%- n 1) i)))
      (set! i (%+ i 1)))
    ;; Reverse the overflow block in place.
    (set! i 0)
    (while (%< i (%/ extra 2))
      (let ((lo (%* value-bytes i)) (hi (%* value-bytes (%- (%- extra 1) i))))
        (i-lc a $t3 $sp lo)
        (i-lc a $t4 $sp hi)
        (i-sc a $t4 $sp lo)
        (i-sc a $t3 $sp hi))
      (set! i (%+ i 1)))
    (if op-on-stack
        (i-lc a $t0 $sp (%* value-bytes n))
        (emit-load c (location-of c op) $t0))
    (i-li a $t1 n)
    (i-jcl a $ra $t0)
    (i-cincoffsetimm a $sp $sp (%* value-bytes (if op-on-stack (%+ n 1) n)))))

;; A call is a self-call when the operator is this function's own name, that
;; name is not shadowed by a local, and the argument count is the one the
;; prologue was built for. It jumps past the arity check with t0 the
;; unsealed closure from this frame. Redefining a function does not reach
;; the self-calls already inside it.
(define (self-call? c op n)
  (if (%symbol? op)
      (if (%eq? op (cx-name c))
          (if (cx-self-label c)
              (if (cx-lookup c op) nil (%= n (cx-self-arity c)))
              nil)
          nil)
      nil))

(define (compile-call-few c form tail)
  (let* ((a (cx-asm c))
         (op (%car form))
         (args (%cdr form))
         (n (length args)))
    ;; The operator, if it needs evaluating, goes first and waits on the stack.
    (let ((op-on-stack nil))
      (if (%symbol? op)
          nil
          (begin
            (compile-expr c op nil)
            (emit-push c $a0)
            (set! op-on-stack t)))
      (compile-args c args n)
      (if (self-call? c op n)
          (begin
            (i-lc a $t0 $s0 clo-slot)
            (if tail
                (begin (emit-epilogue c) (i-j a (cx-self-label c)))
                (i-jal a $ra (cx-self-label c))))
          (begin
            (if op-on-stack
                (begin
                  (i-lc a $t0 $sp 0)
                  (i-cincoffsetimm a $sp $sp value-bytes))
                (emit-load c (location-of c op) $t0))
            (i-li a $t1 n)
            (if tail
                (begin (emit-epilogue c) (i-jcl a $zero $t0))
                (i-jcl a $ra $t0)))))))

;; (%apply f list) calls f with the elements of the list as its arguments.
;; Up to eight it is an ordinary call, and a tail call in tail position. Past
;; eight the rest go on the stack, argument 8+j at 8j(sp), as
;; compile-call-many leaves them, except that how far the stack moves is only
;; known at run time. So the stack pointer to come back to waits in a local.
;; The space is cleared before it is filled: what an earlier, deeper frame
;; left there may still be tagged, and the collector takes every tagged
;; granule between sp and the top of the stack for a value. A list that does
;; not end in nil stops at the count, on the typed cdr.
(define (compile-apply c args tail)
  (if (%= (length args) 2) nil (error "compile: %apply takes a function and a list"))
  (compile-args c args 2)
  (let* ((a (cx-asm c))
         (saved-n (cx-nlocals c))
         (slot (cx-alloc-local c))
         (count (gensym-label "acount"))
         (counted (gensym-label "acounted"))
         (many (gensym-label "amany"))
         (clear (gensym-label "aclear"))
         (fill (gensym-label "afill"))
         (done (gensym-label "adone"))
         (k 0))
    (i-mv a $t0 $a0)
    ;; the length, which is also the count the callee is told
    (i-li a $t1 0)
    (i-mv a $t3 $a1)
    (label a count)
    (i-beqx a $t3 $tp counted)
    (i-cdr a $t3 $t3)
    (i-addi a $t1 $t1 1)
    (i-j a count)
    (label a counted)
    (i-addi a $t4 $t1 -8)
    (i-blt a $zero $t4 many)
    ;; eight or fewer
    (emit-apply-registers c)
    (if tail
        (begin
          (emit-epilogue c)
          (i-jcl a $zero $t0))
        (begin
          (i-jcl a $ra $t0)
          (i-j a done)))
    ;; more than eight: t4 slots of stack, cleared a slot at a time
    (label a many)
    (store-local c slot $sp)
    (label a clear)
    (emit-push c $zero)
    (i-addi a $t4 $t4 -1)
    (i-bnez a $t4 clear)
    ;; then filled from the ninth element on, upwards
    (i-mv a $t3 $a1)
    (while (%< k 8) (i-cdr a $t3 $t3) (set! k (%+ k 1)))
    (i-mv a $t4 $sp)
    (label a fill)
    (i-car a $t5 $t3)
    (i-sc a $t5 $t4 0)
    (i-cincoffsetimm a $t4 $t4 value-bytes)
    (i-cdr a $t3 $t3)
    (i-bnex a $t3 $tp fill)
    (emit-apply-registers c)
    (i-jcl a $ra $t0)
    (load-local c slot $sp)
    (label a done)
    (set-cx-nlocals! c saved-n)
    (if tail (emit-return c) nil)))

;; The first eight elements of the list in a1 into a0..a7, as far as it goes.
;; t3 takes the list before a1 is written.
(define (emit-apply-registers c)
  (let ((a (cx-asm c)) (end (gensym-label "aregs")) (k 0))
    (i-mv a $t3 $a1)
    (while (%< k 8)
      (i-beqx a $t3 $tp end)
      (i-car a (%+ $a0 k) $t3)
      (i-cdr a $t3 $t3)
      (set! k (%+ k 1)))
    (label a end)))

;; ---------------------------------------------------------------- unsafe
;; A raw operation, or a function that hands out raw memory, is a name with
;; the `sym-unsafe` bit (see `unsafe-names`). The compiler refuses to compile
;; a call to one, or a reference to one as a value, unless the site is inside
;; an `unsafe` form or the file said `(unsafe-file)` at its top. So the raw
;; vocabulary is still there, but every place it is used says so, and can
;; be found. What is not raw cannot fault the machine: it can only get a
;; typed error.
;;
;; The processor enforces the same line. A function whose source says
;; `unsafe` is placed with SR in its entry capability, which integer
;; addressing, CSRs and SCRs need; every other function is placed without.
(define *unsafe-ok* nil)     ; inside an `unsafe` form, while it compiles
(define *unsafe-file* nil)   ; after `(unsafe-file)`, until the next `in-package`

(define (unsafe-allowed?) (if *unsafe-ok* t *unsafe-file*))

(define *unsafe-warn* nil)   ; report and carry on, for an audit of a build

(define (check-unsafe c name)
  (cond ((unsafe-allowed?) nil)
        (*unsafe-warn*
         (display (list 'UNSAFE name 'in (cx-name c))) (newline))
        (else
         (error "unsafe: not inside an unsafe form:" name "in" (cx-name c)))))

(define (compile-unsafe c form tail)
  (let ((saved *unsafe-ok*))
    (set! *unsafe-ok* t)
    (compile-body c (%cdr form) tail)
    (set! *unsafe-ok* saved)
    nil))

;; Whether a function's code needs SR: it is compiled in an unsafe file, or
;; inside an `unsafe` form of the function around it, or its body says
;; `unsafe` outside the functions nested in it, which answer for themselves.
(define (privileged-body? forms)
  (if (unsafe-allowed?)
      t
      (let ((found nil))
        (dolist (f forms) (if (says-unsafe? f) (set! found t) nil))
        found)))

(define (says-unsafe? form)
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'quote) nil)
         ((%eq? h 'unsafe) t)
         ((%eq? h 'lambda) nil)
         ((if (%eq? h 'define) (%cons? (cadr form)) nil) nil)
         (else
          (let ((found nil))
            (while (%cons? form)
              (if (says-unsafe? (%car form)) (set! found t) nil)
              (set! form (%cdr form)))
            found))))
      nil))

;; ---------------------------------------------------------------- expressions
(define (compile-expr c form tail)
  (let ((a (cx-asm c)))
    (cond
     ;; ---- constants ----
     ((%null? form) (i-mv a $a0 $tp) (if tail (emit-return c) nil))
     ((%symbol? form)
      (if (if (cx-lookup c form) nil (symbol-unsafe? form))
          (check-unsafe c form)
          nil)
      (emit-load c (location-of c form) $a0)
      (if tail (emit-return c) nil))
     ((not (%cons? form))
      (emit-const c form $a0)
      (if tail (emit-return c) nil))

     (else
      (let ((h (%car form)))
        ;; Whatever the head turns out to be, an open-coded operation, an
        ;; operator with a constant, an indexed access or a call, a raw name
        ;; is refused here unless the site is allowed to say it.
        (if (if (%symbol? h) (if (cx-lookup c h) nil (symbol-unsafe? h)) nil)
            (check-unsafe c h)
            nil)
        (cond
         ((%eq? h 'quote)
          (emit-const c (cadr form) $a0)
          (if tail (emit-return c) nil))

         ((%eq? h 'if) (compile-if c form tail))
         ((%eq? h 'begin) (compile-body c (%cdr form) tail))
         ((%eq? h 'unsafe) (compile-unsafe c form tail))
         ((%eq? h 'let) (compile-let c form tail))
         ((%eq? h 'while) (compile-while c form tail))
         ((%eq? h 'set!) (compile-set c form tail))
         ((%eq? h 'define) (compile-inner-define c form tail))

         ;; An anonymous function is named (lambda . home), so a backtrace can
         ;; say where it came from.
         ((%eq? h 'lambda)
          (compile-closure c (cadr form) (cddr form)
                           (%cons 'lambda (cx-name c)))
          (if tail (emit-return c) nil))

         ;; (%funcall f a b) is a call whose operator is an expression.
         ((%eq? h '%funcall) (compile-call c (%cdr form) tail))

         ;; (%apply f list) is the same call with its arguments in a list.
         ((%eq? h '%apply) (compile-apply c (%cdr form) tail))

         ;; ---- an operator whose second argument is written down ----
         ((if (%symbol? h)
              (if (cx-lookup c h) nil (const-arg-entry h (%cdr form)))
              nil)
          (emit-const-arg c (const-arg-entry h (%cdr form)) (%cdr form) tail))

         ;; ---- indexed access with the index written down ----
         ((if (%symbol? h)
              (if (cx-lookup c h) nil (indexed-imm-entry h (%cdr form)))
              nil)
          (emit-indexed-imm c (indexed-imm-entry h (%cdr form)) (%cdr form) tail))

         ;; ---- open-coded operations ----
         ((if (%symbol? h)
              (if (cx-lookup c h) nil (inline-entry h (length (%cdr form))))
              nil)
          (let* ((e (inline-entry h (length (%cdr form))))
                 (arity (%car e))
                 (fn (%cdr e))
                 (args (%cdr form)))
            (if (%= (length args) arity)
                nil
                (error "compile: wrong argument count for" h))
            (compile-args c args arity)
            (%funcall fn c)
            (if tail (emit-return c) nil)))

         (else (compile-call c form tail))))))))

(define (emit-return c)
  (emit-epilogue c)
  (i-ret (cx-asm c)))

(define (compile-if c form tail)
  (let* ((a (cx-asm c))
         (test (cadr form))
         (then (caddr form))
         (else-form (if (%cons? (cdddr form)) (cadddr form) nil))
         (l-else (gensym-label "else"))
         (l-end (gensym-label "endif")))
    (emit-test-jump-false c test l-else)
    (compile-expr c then tail)
    (if tail
        nil                              ; the then branch already returned
        (i-j a l-end))
    (label a l-else)
    (compile-expr c else-form tail)
    (if tail nil (label a l-end))))

(define (compile-body c forms tail)
  (if (%null? forms)
      (begin (i-mv (cx-asm c) $a0 $tp) (if tail (emit-return c) nil))
      (begin
        (while (%cons? (%cdr forms))
          (compile-expr c (%car forms) nil)
          (set! forms (%cdr forms)))
        (compile-expr c (%car forms) tail))))

;; Initialisers all see the outer scope, so `let` binds in parallel.
(define (compile-let c form tail)
  (let* ((binds (cadr form))
         (body (cddr form))
         (saved-env (cx-env c))
         (saved-n (cx-nlocals c))
         (slots nil))
    (dolist (b binds)
      (compile-expr c (cadr b) nil)
      (let ((slot (cx-alloc-local c)))
        (store-local c slot $a0)
        (set! slots (%cons (%cons (%car b) slot) slots))))
    (dolist (s (reverse slots))
      (cx-bind c (%car s) (box-or-plain c (%car s) (%cdr s))))
    (compile-body c body tail)
    (set-cx-env! c saved-env)
    (set-cx-nlocals! c saved-n)))

;; A variable that an inner lambda captures and that something assigns lives
;; in a box, so the closure and the frame see one value.
(define (box-or-plain c sym slot)
  (if (memq sym (cx-boxed c))
      (begin
        (emit-make-box c slot)
        (list 'boxed-local slot))
      (list 'local slot)))

;; Replace the slot's value with a pair holding it in its car.
(define (emit-make-box c slot)
  (load-local c slot $a2)
  (emit-cons c $a2 $tp $a2)
  (store-local c slot $a2))

(define (compile-while c form tail)
  (let* ((a (cx-asm c))
         (top (gensym-label "while"))
         (done (gensym-label "wend")))
    (label a top)
    (emit-test-jump-false c (cadr form) done)
    (dolist (x (cddr form)) (compile-expr c x nil))
    (i-j a top)
    (label a done)
    (i-mv a $a0 $tp)
    (if tail (emit-return c) nil)))

(define (compile-set c form tail)
  (let ((name (cadr form)))
    (compile-expr c (caddr form) nil)
    (emit-store c (location-of c name) $a0)
    (if tail (emit-return c) nil)))

;; An internal define makes a new local in the current frame.
(define (compile-inner-define c form tail)
  (if (%cons? (cadr form))
      (let ((name (caadr form)))
        (compile-closure c (cdadr form) (cddr form) name)
        (let ((slot (cx-alloc-local c)))
          (store-local c slot $a0)
          (cx-bind c name (list 'local slot))))
      (let ((name (cadr form)))
        (compile-expr c (if (%cons? (cddr form)) (caddr form) nil) nil)
        (let ((slot (cx-alloc-local c)))
          (store-local c slot $a0)
          (cx-bind c name (list 'local slot)))))
  (if tail (emit-return c) nil))

;; ---------------------------------------------------------------- lambdas
;; An inner lambda is compiled into its own code object. Where the lambda
;; form appears, the enclosing function calls `make-closure`, which answers a
;; closure object holding the code object and its entry, unsealed; copies the
;; captured values in after them; and seals it. Sealed, the closure can be
;; called but not opened, so its free variables are reachable only by its own
;; code.
(define (compile-closure c params body name)
  (let* ((a (cx-asm c))
         (free (filter (lambda (s) (cx-lookup c s))
                       (dedup (free-vars (%cons 'lambda (%cons params body)) nil))))
         ;; A captured variable that lives in a box stays boxed inside the
         ;; closure, so the inner function has to know which of its free
         ;; variables to dereference.
         (free-boxed (map (lambda (s) (boxed-location? (location-of c s))) free))
         (code (%cdr (compile-function params body name free free-boxed)))
         (nfree (length free))
         (i 0))
    (if (%> (free-off nfree) 2048)
        (error "compile: too many free variables in" name)
        nil)
    (emit-literal c code $a0)
    (i-li a $a1 nfree)
    (emit-load c (list 'global 'make-closure) $t0)
    (i-li a $t1 2)
    (i-jcl a $ra $t0)
    (dolist (s free)
      (emit-load-cell c (location-of c s) $t5)
      (i-sc a $t5 $a0 (free-off i))
      (set! i (%+ i 1)))
    (i-csealclo a $a0 $a0)))

(define (dedup xs)
  (let ((acc nil))
    (dolist (x xs) (if (memq x acc) nil (set! acc (%cons x acc))))
    (reverse acc)))

;; ---------------------------------------------------------------- leaf test
;; Two things put a link into a function's own code: an ordinary call, and
;; building a closure, which calls the allocator. Anything this walk does not
;; recognise counts as a call, so it is only ever wrong in the safe
;; direction, and `check-leaf` reads the bytes afterwards in case it is wrong
;; in the other one.

(define (leaf-body? forms bound)
  (let ((ok t))
    (dolist (f forms) (if (leaf-form? f bound) nil (set! ok nil)))
    ok))

(define (leaf-binds? binds bound)
  (let ((ok t))
    (dolist (b binds) (if (leaf-form? (cadr b) bound) nil (set! ok nil)))
    ok))

(define (leaf-form? form bound)
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'quote) t)
         ((%eq? h 'lambda) nil)         ; a closure is allocated by a call
         ((%eq? h 'define) nil)         ; and an inner define may be one
         ((%eq? h 'if) (leaf-body? (%cdr form) bound))
         ((%eq? h 'begin) (leaf-body? (%cdr form) bound))
         ((%eq? h 'unsafe) (leaf-body? (%cdr form) bound))
         ((%eq? h 'while) (leaf-body? (%cdr form) bound))
         ((%eq? h 'set!) (leaf-body? (cddr form) bound))
         ((%eq? h 'let)
          (if (leaf-binds? (cadr form) bound) (leaf-body? (cddr form) bound) nil))
         ((%symbol? h)
          ;; An open-coded operator is a leaf if its arguments are. A name the
          ;; body binds shadows any intrinsic of the same name and makes an
          ;; ordinary call of it.
          (cond
           ((memq h bound) nil)
           ((inline-entry h (length (%cdr form))) (leaf-body? (%cdr form) bound))
           (else nil)))
         (else nil)))
      t))

;; Every name the body binds, which answers two questions: which names shadow
;; an intrinsic, and how many locals there could be. This over-counts, since
;; bindings in sibling scopes share a slot, which is the safe direction.
(define (bound-names form acc)
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'quote) acc)
         ((%eq? h 'let)
          (dolist (b (cadr form))
            (set! acc (%cons (%car b) acc))
            (set! acc (bound-names (cadr b) acc)))
          (dolist (f (cddr form)) (set! acc (bound-names f acc)))
          acc)
         ((%eq? h 'define)
          (set! acc (%cons (if (%cons? (cadr form)) (caadr form) (cadr form)) acc))
          (dolist (f (cddr form)) (set! acc (bound-names f acc)))
          acc)
         (else
          (dolist (f form) (set! acc (bound-names f acc)))
          acc)))
      acc))

;; Not variadic, because the rest list is gathered in frame slots. Locals
;; within the eight registers. And nothing in the body that can call.
;; Captured variables are fine: they are read through t0. Consing is fine
;; too: a pair is four instructions and no call.
(define (leaf-function? forms names rest)
  (if rest
      nil
      (let ((bound (bound-names (%cons 'begin forms) names)))
        (if (%> (length bound) leaf-locals)
            nil
            (leaf-body? forms bound)))))

;; Compile a lambda body into fresh code. Returns (entry . code-object).
(define (compile-function params body name free . free-boxed-opt)
  (let* ((a (make-assembler))
         (c (make-context a name nil))
         (nreq (param-required params))
         (rest (param-rest params))
         (names (param-names params))
         (expanded (map macroexpand-all body))
         (assigned (assigned-vars (%cons 'begin expanded) nil))
         (captured (captured-vars (%cons 'begin expanded) nil))
         (i 0))
    (set-asm-privileged! a (privileged-body? expanded))
    ;; Which variables need boxes, and whether this is a leaf, both have to
    ;; be known before a word is emitted.
    (set-cx-boxed! c (filter (lambda (s) (memq s captured)) (dedup assigned)))
    (set-cx-leaf! c (leaf-function? expanded names rest))
    (emit-prologue c nreq (if rest t nil))
    ;; Parameters land in the first local slots. The first eight arrive in
    ;; registers; the rest were pushed by the caller and sit above the frame
    ;; pointer, argument 8+j at 8j(s0). A leaf never has nine parameters,
    ;; because that is nine locals.
    (set! i 0)
    (dolist (p names)
      (if (%eq? p rest)
          nil
          (let ((slot (cx-alloc-local c)))
            (if (%< i 8)
                (store-local c slot (%+ $a0 i))
                (begin
                  (i-lc a $t3 $s0 (%* value-bytes (%- i 8)))
                  (store-local c slot $t3)))
            (cx-bind c p (list 'local slot))
            (set! i (%+ i 1)))))
    (if rest
        (let ((slot (cx-alloc-local c)))
          (emit-rest-list c nreq slot)
          (cx-bind c rest (list 'local slot)))
        nil)
    ;; Box the parameters that need it, now that they are in slots.
    (dolist (p names)
      (if (memq p (cx-boxed c))
          (let ((loc (%cdr (cx-lookup c p))))
            (emit-make-box c (cadr loc))
            (set-cx-env! c (%cons (%cons p (list 'boxed-local (cadr loc)))
                                  (cx-env c))))
          nil))
    ;; Free variables are read out of the closure, through the box when the
    ;; enclosing function put one there.
    (let ((fb (if (%cons? free-boxed-opt) (%car free-boxed-opt) nil)))
      (set! i 0)
      (dolist (s free)
        (cx-bind c s (if (if (%cons? fb) (%car fb) nil)
                         (list 'boxed-free i)
                         (list 'free i)))
        (if (%cons? fb) (set! fb (%cdr fb)) nil)
        (set! i (%+ i 1))))
    (compile-body c expanded t)
    (finish-frame c)
    (let ((entry (place a)))
      (%cons entry (code-object a (cx-name c))))))

;; Collect arguments nreq.. into a list. The eight argument registers are
;; spilled so the loop can index them uniformly with anything on the stack.
(define (emit-rest-list c nreq slot)
  (let* ((a (cx-asm c))
         (spill (cx-nlocals c))
         (loop (gensym-label "rest"))
         (done (gensym-label "rdone"))
         (from-reg (gensym-label "rreg"))
         (got (gensym-label "rgot"))
         (k 0))
    ;; Reserve eight slots for the spill.
    (while (%< k 8) (cx-alloc-local c) (set! k (%+ k 1)))
    (set! k 0)
    (while (%< k 8)
      (i-sc a (%+ $a0 k) $s0 (local-off (%+ spill k)))
      (set! k (%+ k 1)))
    (i-mv a $a2 $tp)                       ; the list under construction
    (i-addi a $t3 $t1 -1)                  ; i = nargs - 1
    (i-li a $t4 nreq)
    (label a loop)
    (i-blt a $t3 $t4 done)
    (i-li a $t5 8)
    (i-blt a $t3 $t5 from-reg)
    ;; argument 8 + j sits 8j above s0
    (i-addi a $t6 $t3 -8)
    (i-slli a $t6 $t6 3)
    (i-cincoffset a $t6 $s0 $t6)
    (i-lc a $a3 $t6 0)
    (i-j a got)
    ;; argument i < 8 is spill slot i, 8i below spill slot 0
    (label a from-reg)
    (i-slli a $t6 $t3 3)
    (i-sub a $t6 $zero $t6)
    (i-cincoffset a $t6 $s0 $t6)
    (i-lc a $a3 $t6 (local-off spill))
    (label a got)
    (emit-cons c $a3 $a2 $a2)
    (i-addi a $t3 $t3 -1)
    (i-j a loop)
    (label a done)
    (i-sc a $a2 $s0 (local-off slot))))

;; ---------------------------------------------------------------- top level
;; A function definition is installed at compile time. Anything else becomes
;; a thunk on the boot list, which the kickstart runs in order when the image
;; starts.
(define *boot-thunks* nil)

;; The closure of a top-level function, which has no free variables:
;; `make-closure` fills in its entry and its code object, and it is sealed
;; here, like every closure the compiler makes.
(define (top-level-closure code)
  (%cap-seal-closure (make-closure code 0)))

(define (add-boot-thunk form)
  (let* ((r (compile-function nil (list form) 'toplevel nil))
         (clo (top-level-closure (%cdr r))))
    (set! *boot-thunks* (%cons clo *boot-thunks*))
    clo))

;; ---------------------------------------------------------------- the image
;; Where a definition goes. Ordinarily that is this machine: `define` puts
;; the function in its symbol, and the next form can call it. A fresh rebuild
;; compiles the sources a second time for an image of their own (`genesis` in
;; sys.lisp), and while it does, *image* is a table of what that image will
;; hold in each symbol, and this machine goes on running the definitions it
;; has. The forge keeps its interpreter's definitions apart from the image's
;; in the same way.
(define *image* nil)

;; symbol -> #(value function macro?), made the first time the image gives the
;; symbol anything.
(define (image-entry sym)
  (let ((e (table-ref *image* sym nil)))
    (if e
        e
        (let ((v (make-vector 3 nil)))
          (%vector-set! v 0 (%unbound))
          (table-set! *image* sym v)
          v))))

(define (image-value sym)
  (if *image*
      (let ((e (table-ref *image* sym nil))) (if e (%vector-ref e 0) (%unbound)))
      (%symbol-value sym)))

(define (image-set-value! sym v)
  (if *image* (%vector-set! (image-entry sym) 0 v) (%set-symbol-value! sym v))
  v)

(define (image-set-macro! sym expander)
  (if *image*
      (let ((e (image-entry sym)))
        (%vector-set! e 1 expander)
        (%vector-set! e 2 t))
      (begin
        (%set-symbol-function! sym expander)
        (%set-symbol-flags! sym (%logior (%symbol-flags sym) sym-macro))))
  expander)

;; A macro expander takes the form's argument list as one argument and picks
;; it apart itself, so the calling convention's limit of eight register
;; arguments does not apply to macros.
(define (macro-binder params var body)
  (if (%symbol? params)
      (%cons 'let (%cons (list (list params var)) body))
      (let ((binds nil) (p params) (path var))
        (while (%cons? p)
          (if (%symbol? (%car p))
              nil
              (error "defmacro: a parameter must be a symbol" params))
          (set! binds (append binds (list (list (%car p) (list 'car path)))))
          (set! path (list 'cdr path))
          (set! p (%cdr p)))
        (if (%symbol? p)
            (set! binds (append binds (list (list p path))))
            nil)
        (%cons 'let* (%cons binds body)))))

;; Four forms are directives to the compiler as much as code. `defrecord` is
;; a macro, so that the interpreter has one to expand, and is caught here
;; before expansion, so the shape is registered and the accessors are
;; open-coded from here on. `in-package` ends an unsafe file, and is then
;; compiled as usual; `(unsafe-file)` begins one and compiles to nothing;
;; `unsafe-names` marks its names now, for the code compiled after it here,
;; as well as at boot for the machine.
(define (compile-top form)
  (set! *unsafe-ok* nil)
  (let ((h (if (%cons? form) (%car form) nil)))
    (cond
     ((%eq? h 'defrecord) (compile-defrecord form))
     ((%eq? h 'in-package) (set! *unsafe-file* nil) (compile-top-1 form))
     ((%eq? h 'unsafe-file) (set! *unsafe-file* t) 'unsafe-file)
     ((%eq? h 'unsafe-names) (compile-time-eval form) (compile-top-1 form))
     (else (compile-top-1 form)))))

(define (compile-top-1 form)
  (set! form (macroexpand form))
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'define)
          (if (%cons? (cadr form))
              (let* ((name (caadr form))
                     (r (compile-function (cdadr form) (cddr form) name nil))
                     (clo (top-level-closure (%cdr r))))
                (image-set-value! name clo)
                name)
              ;; A variable definition is given its value now, because code
              ;; compiled later in the same build reads it as a constant, and
              ;; the initialiser is recorded so that a booting image runs it
              ;; again in source order.
              ;;
              ;; `(define name)` with no initialiser is a declaration: it
              ;; names the variable, leaves any value already there alone,
              ;; and puts nothing on the boot list. A machine recompiling its
              ;; own sources must not knock out the allocator it is
              ;; allocating through.
              (let ((name (cadr form)))
                (if (%cons? (cddr form))
                    (let ((expr (caddr form)))
                      (image-set-value! name (compile-time-eval expr))
                      (record-initialiser name expr))
                    (if (%eq? (image-value name) (%unbound))
                        (image-set-value! name nil)
                        nil))
                name)))
         ;; A macro is needed twice: by the compiler running now, and by the
         ;; machine's compiler once the image boots. It is registered with
         ;; whatever expander is in charge here, and compiled into the
         ;; function cell where the other one will look for it.
         ((%eq? h 'defmacro)
          (register-macro form)
          (let* ((name (cadr form))
                 (r (compile-function (list 'macro-args)
                                      (list (macro-binder (caddr form) 'macro-args
                                                          (cdddr form)))
                                      name nil))
                 (clo (top-level-closure (%cdr r))))
            (image-set-macro! name clo)
            name))
         ((%eq? h 'begin)
          (let ((last nil))
            (dolist (f (%cdr form)) (set! last (compile-top f)))
            last))
         (else (top-level-form form))))
      (top-level-form form)))

;; The same expansion the interpreter's macro uses, compiled rather than
;; evaluated, with the shape registered on the way past, both here and, by
;; the form left on the boot list, in the machine that boots from this.
(define (compile-defrecord form)
  (let* ((forms (record-forms form))
         (head (cadr form))
         (type (if (%cons? head) (%car head) head))
         (s (record-shape type)))
    (top-level-form (list 'record-shape! (list 'quote type) (shape-prefix s)
                          (shape-open? s) (list 'quote (shape-fields s))))
    (dolist (f forms) (compile-top f))
    type))

(setup-intrinsics)

;; The raw vocabulary: what names memory by number through DDC, hands out
;; the root, or reads or sets the machine's own state, all of which the
;; processor refuses to code without SR, and `open-closure`, the escape hatch
;; built from them. The operations on a capability the caller already holds
;; are not here, and neither is `%addr-of`, whose answer cannot be followed
;; without one of these.
(unsafe-names
 '(%root %from-addr
   %ld-word %st-word! %ld-half %st-half! %ld-byte %st-byte! %ld-cap %st-cap!
   %bit-ref %bit-set! %slot %set-slot!
   %context %set-context! %stack-limit %set-stack-limit! %set-gc-mode!
   %set-this-task!
   %ecall %halt %disable %enable %restore-interrupts %enable-after-trap
   %enable-interrupt-lines %wait-for-interrupt
   %cons-run %set-cons-run! open-closure))

;; From here on a record's accessors are open-coded as the record is
;; declared. The shapes declared before this line get done now.
(set! *record-inline-hook* (lambda (s) (install-record-inlines! s)))
(dolist (s *record-shapes*) (install-record-inlines! s))
