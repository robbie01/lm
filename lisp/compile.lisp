;;; compile.lisp - Lisp to native RISC-V.
;;;
;;; The same source runs twice. At build time the bootstrap interpreter runs it
;;; to compile the whole system - this file included - into the image. After
;;; that the image contains a compiled copy of this compiler, so the machine
;;; can compile new Lisp for itself at the REPL. There is only ever one
;;; compiler.
;;;
;;; Calling convention
;;;   a0..a7   arguments 0..7; arguments 8 and up are pushed by the caller so
;;;            that argument 8 sits at 0(sp) on entry, which is 0(s0) inside
;;;   t0       the closure being called, so its free variables are reachable
;;;   t1       argument count, as a raw integer
;;;   a0       the result
;;;   gp       cons-space bump pointer      } dedicated for the life of the
;;;   tp       cons-space limit             } machine; allocation is inline
;;;
;;;   s1       the running function's literal vector, that is its code object
;;;
;;; Frame
;;;   s0 + 0        argument 8, if there is one
;;;   s0 - 4        saved ra
;;;   s0 - 8        saved s0
;;;   s0 - 12       the closure
;;;   s0 - 16       saved s1
;;;   s0 - 20 - 4i  local slot i
;;;   sp            below all of that; temporaries are pushed under it
;;;
;;; Only one instruction in the prologue depends on the frame size, so the
;;; frame is sized after the body is emitted and that single word is patched.
;;;
;;; Self-calls
;;;   A call to the name the function is being compiled under reuses the
;;;   closure already in this frame and jumps to a label past its own arity
;;;   check: two instructions instead of five, and no indirect jump. See
;;;   self-call? for the conditions, and note the trade - redefining a
;;;   function does not reach the calls already inside it.
;;;
;;; Every word between sp and s0-12 inclusive is a tagged Lisp value: locals,
;;; spilled temporaries, pushed arguments, the closure. Only the saved ra and
;;; the frame link are raw, and they are at fixed offsets. That uniformity is
;;; what lets the collector walk a stack precisely with no stack maps at all.
;;;
;;; Pairs
;;;   car, cdr, set-car! and set-cdr! are single instructions in the custom-0
;;;   opcode space rather than loads and stores, because the processor can
;;;   check the tag while it forms the address and so the check costs nothing.
;;;   Anything that is not a pair traps with the offending value in mtval, and
;;;   sys.lisp turns that into a sentence naming the value.

(in-package compiler)

(define frame-fixed 20)
(define (local-off n) (%- (%- 0 frame-fixed) (%* 4 n)))
(define clo-slot -12)
(define lit-slot -16)

;; ---------------------------------------------------------------- leaves
;; A function that calls nothing needs none of the frame it builds. It cannot
;; be returned into, so `ra` survives; nothing can collect while it runs, so
;; the closure need not be findable on a stack; and its locals cannot be
;; clobbered by a callee, so they can stay in registers and never be stored at
;; all. About seven functions in ten are leaves, and they take a bit over half
;; the calls, so this is the largest single piece of the frame protocol.
;;
;; s3..s10 hold a leaf's locals and s11 holds its caller's literal vector.
;; Nothing else in the machine touches those nine registers, so a leaf saves
;; and restores none of them: there is nothing there to preserve.
(define (local-reg n) (%+ $s3 n))
(define leaf-locals 8)
(define $lit-save $s11)

;; ---------------------------------------------------------------- ecall codes

;; ---------------------------------------------------------------- context
;; What the compiler knows while it is compiling one function. This was a
;; vector of thirteen numbered slots and a comment block to say which was
;; which, which is fine until you add a fourteenth and have to count.
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
    ;; The pre-pass bounds this before deciding a function is a leaf, so
    ;; reaching here means the bound was wrong rather than that the function
    ;; is unusual.
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
;; Macros are gone before anything looks at the tree, so the analysis passes
;; below only ever see the nine special forms.
(define (macroexpand form)
  ;; macro-form? and expand-macro are the two places where the compiler has to
  ;; know which side of the bootstrap it is running on. While the forge is
  ;; building the image the macros live in the interpreter; once the image is
  ;; running they live in the symbols' function cells. Everything else about
  ;; the compiler is identical either way.
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
;; Which variables does this form assign to?
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

;; Which variables appear free inside a nested lambda? Those are the ones a
;; closure will capture, and a captured variable that is also assigned has to
;; live in a box rather than in a stack slot.
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

;; Free variables of a form, given a list of names already bound.
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

(define (param-names params)
  ;; Accepts (a b), (a . rest), and (a &rest r).
  (let ((acc nil))
    (while (%cons? params)
      (let ((p (%car params)))
        (if (%eq? p '&rest) nil (set! acc (%cons p acc))))
      (set! params (%cdr params)))
    (if (%symbol? params) (set! acc (%cons params acc)) nil)
    (reverse acc)))

(define (param-required params)
  ;; How many arguments must be supplied.
  (let ((n 0))
    (while (%cons? params)
      (if (%eq? (%car params) '&rest)
          (set! params nil)
          (begin (set! n (%+ n 1)) (set! params (%cdr params)))))
    n))

(define (param-rest params)
  ;; The rest parameter, or nil if the function takes a fixed count.
  (let ((r nil))
    (while (%cons? params)
      (if (%eq? (%car params) '&rest)
          (begin (set! r (cadr params)) (set! params nil))
          (set! params (%cdr params))))
    (if (%symbol? params) (set! r params) nil)
    r))

;; ---------------------------------------------------------------- constants
(define (self-evaluating? x)
  (if (%null? x) t
      (if (%fixnum? x) t
          (if (%char? x) t
              (if (%string? x) t
                  (if (%vector? x) t (%float? x)))))))

(define (emit-const c v reg)
  (let ((a (cx-asm c)))
    (cond
     ((%null? v) (i-mv a reg $zero))
     ((%fixnum? v) (i-li-fixnum a reg v))
     ((%char? v) (i-li a reg (%logior (%lsh (%char->int v) 8) 2)))
     (else
      ;; A heap object. Its address is never written into the instruction
      ;; stream - the code loads it from the literal vector instead, so the
      ;; collector can move the object and only has to update one word.
      (emit-literal c v reg)))))

(define (emit-literal c v reg)
  (let* ((a (cx-asm c))
         (off (literal-offset (asm-literal a v))))
    (if (%>= off 2048)
        (error "compile: too many literals in" (cx-name c))
        nil)
    (i-lw a reg $s1 off)))

;; ---------------------------------------------------------------- records
;; The shape of a record and the functions that go with it are in macros.lisp,
;; because the interpreter needs them too. What is here is the open-coding: a
;; call to one of those accessors becomes four instructions and no call, with
;; the tag check the function does written out inline.
;;
;; The check is three of the four: load slot 0, compare it with the type this
;; code was compiled against, branch. The tag it wanted is left in t3 and the
;; value it did not like is still in a0, so the trap can name both ends rather
;; than give an address.
;;
;; An `open` record - one others are built on - has no check to make. The
;; indexed load still refuses anything that is not a record, which is exactly
;; what the hand-numbered `%record-ref` did and all a list walker can ask for.
(define (emit-record-check c type open)
  (let ((a (cx-asm c)))
    (if open
        nil
        (let ((ok (asm-gensym-label "rec")))
          (i-ldxi a $t2 $a0 0 t-record)
          (emit-literal c type $t3)
          (i-beq a $t2 $t3 ok)
          (i-li a $a7 trap-record)
          (i-ecall a)
          (asm-label a ok)))))

(define (record-getter type open k)
  (lambda (c)
    (emit-record-check c type open)
    (i-ldxi (cx-asm c) $a0 $a0 k t-record)))

(define (record-setter type open k)
  (lambda (c)
    (emit-record-check c type open)
    (i-stxi (cx-asm c) $a1 $a0 k t-record)
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
(define (resolve c sym)
  (let ((p (cx-lookup c sym)))
    (if p (%cdr p) (list 'global sym))))

;; A local is a frame slot, or - in a leaf - a register, and these three are
;; the only places that know which.
(define (load-local c n reg)
  (if (cx-leaf c)
      (i-mv (cx-asm c) reg (local-reg n))
      (i-lw (cx-asm c) reg $s0 (local-off n))))

(define (store-local c n reg)
  (if (cx-leaf c)
      (i-mv (cx-asm c) (local-reg n) reg)
      (i-sw (cx-asm c) reg $s0 (local-off n))))

;; Where this function's closure is. A framed function saved it at s0-12 and
;; has to load it back; a leaf still has it in t0, because a leaf calls nothing
;; and nothing else in a body touches t0. So a captured variable costs a leaf
;; one instruction rather than two - and, more to the point, a function that
;; captures can be a leaf at all.
(define (closure-reg c scratch)
  (if (cx-leaf c)
      $t0
      (begin (i-lw (cx-asm c) scratch $s0 clo-slot) scratch)))

(define (emit-load c loc reg)
  (let ((a (cx-asm c)) (kind (%car loc)))
    (cond
     ((%eq? kind 'local) (load-local c (cadr loc) reg))
     ((%eq? kind 'boxed-local)
      (load-local c (cadr loc) reg)
      (i-lref a reg reg 0))
     ((%eq? kind 'free)
      (i-lobj a reg (closure-reg c $t6) (%* 4 (%+ clo-free (cadr loc)))))
     ((%eq? kind 'boxed-free)
      (i-lobj a reg (closure-reg c $t6) (%* 4 (%+ clo-free (cadr loc))))
      (i-lref a reg reg 0))
     ;; One instruction, off the register that says which instance is running.
     (else
      (let ((sym (cadr loc)))
        (note-global-ref sym)
        (emit-literal c sym $t6)
        (i-lw a reg $t6 (%* 4 sym-value)))))))

;; Every global the compiler emits a reference to gets recorded, so the build
;; can report a name that compiled code will call but that nothing defines.
;; Without this the symptom is a jump to a nonsense address minutes later,
;; with nothing left to point at.
(define *global-refs* nil)
(define (note-global-ref sym)
  (if (memq sym *global-refs*)
      nil
      (set! *global-refs* (%cons sym *global-refs*))))

(define (undefined-globals)
  (filter (lambda (s) (%eq? (%symbol-value s) *unbound*)) *global-refs*))

;; Load a location's storage cell without following a box. Capturing a boxed
;; variable has to grab the box itself: the closure and the frame have to go
;; on sharing one cell, which is the entire point of boxing it.
(define (emit-load-cell c loc reg)
  (let ((a (cx-asm c)) (kind (%car loc)))
    (cond
     ((%eq? kind 'local) (load-local c (cadr loc) reg))
     ((%eq? kind 'boxed-local) (load-local c (cadr loc) reg))
     ((%eq? kind 'free)
      (i-lobj a reg (closure-reg c $t6) (%* 4 (%+ clo-free (cadr loc)))))
     ((%eq? kind 'boxed-free)
      (i-lobj a reg (closure-reg c $t6) (%* 4 (%+ clo-free (cadr loc)))))
     (else (emit-load c loc reg)))))

(define (boxed-location? loc)
  (if (%eq? (%car loc) 'boxed-local) t (%eq? (%car loc) 'boxed-free)))

(define (emit-store c loc reg)
  (let ((a (cx-asm c)) (kind (%car loc)))
    (cond
     ((%eq? kind 'local) (store-local c (cadr loc) reg))
     ((%eq? kind 'boxed-local)
      (load-local c (cadr loc) $t6)
      (i-sref a reg $t6 0))
     ((%eq? kind 'free)
      (i-sobj a reg (closure-reg c $t6) (%* 4 (%+ clo-free (cadr loc)))))
     ((%eq? kind 'boxed-free)
      (let ((cr (closure-reg c $t6)))
        (i-lobj a $t6 cr (%* 4 (%+ clo-free (cadr loc)))))
      (i-sref a reg $t6 0))
     (else
      (let ((sym (cadr loc)))
        (emit-literal c sym $t6)
        (i-sw a reg $t6 (%* 4 sym-value)))))))

;; ---------------------------------------------------------------- allocation
;; Inline cons. gp is the bump pointer and tp the limit, both held in registers
;; for the life of the machine, so a fresh pair costs four instructions on the
;; fast path plus one well-predicted branch.
(define (emit-cons c car-reg cdr-reg dst . live)
  ;; `live` is a bitmask of the argument registers holding values that must
  ;; survive a collection. It is written into t5 on the slow path only, and
  ;; the stub stores it where the collector can read it: that is what lets the
  ;; stack walker take exactly the live registers and ignore the rest, rather
  ;; than guessing at sixteen saved words.
  (let ((a (cx-asm c))
        (ok (asm-gensym-label "cons"))
        (mask (if (%cons? live) (%car live) 3)))
    (i-bltu a $gp $tp ok)
    (i-li a $t5 mask)
    (i-lw a $t6 $zero lg-gchook)
    (i-call-reg a $t6)
    (asm-label a ok)
    (i-sw a car-reg $gp 0)
    (i-sw a cdr-reg $gp 4)
    (i-mv a dst $gp)
    (i-addi a $gp $gp 8)))

;; ---------------------------------------------------------------- booleans
;; A comparison that is not immediately branched on has to make a value.
;; Turning the 0/1 from slt into nil/t branchlessly is cheaper than jumping.
(define (emit-type-test c type)
  ;; True when a0 is a heap object whose header type is `type`. The tag check
  ;; has to come first: reading a header off a fixnum would fault.
  (let ((a (cx-asm c)) (no (asm-gensym-label "nt")))
    (i-andi a $t2 $a0 7)
    (i-addi a $t2 $t2 -4)
    (i-mv a $t3 $zero)
    (i-bnez a $t2 no)
    (i-lw a $t3 $a0 -4)
    (i-andi a $t3 $t3 255)
    (i-addi a $t3 $t3 (%- 0 type))
    (i-seqz a $t3 $t3)
    (asm-label a no)
    (emit-bool-from-flag c $t3 $a0)))

(define (emit-bool-from-flag c flag-reg dst)
  ;; 't rather than (intern-string "t"): the symbol has to be the one this
  ;; source means, resolved once when this file was read, not whichever one
  ;; the package that happens to be current would give us at compile time.
  ;; czero.eqz is a select with no branch and no flags register: t stays t
  ;; when the flag is set, and becomes zero - which is nil - when it is not.
  (let ((a (cx-asm c)) (tsym 't))
    (emit-literal c tsym dst)
    (i-czero-eqz a dst dst flag-reg)))

;; ---------------------------------------------------------------- prologue
(define (emit-prologue c nreq variadic)
  (let ((a (cx-asm c)) (ok (asm-gensym-label "arity")))
    ;; Arity is checked before the frame exists, so a bad call cannot corrupt
    ;; anything on the way to the diagnostic.
    (i-li a $t2 nreq)
    (if variadic (i-bge a $t1 $t2 ok) (i-beq a $t1 $t2 ok))
    (i-li a $a7 trap-arity)
    (i-ecall a)
    (asm-label a ok)
    ;; A leaf builds nothing at all. It keeps its caller's literal vector in
    ;; s11 and picks up its own, and that is the whole of its prologue: sp
    ;; does not move, s0 still names the caller's frame, ra is in no danger
    ;; because nothing here will overwrite it, and its locals are registers
    ;; nothing else in the machine uses.
    (if (cx-leaf c)
        (begin
          (i-mv a $lit-save $s1)
          (i-lobj a $s1 $t0 (%* 4 clo-code)))
        (begin
          ;; A function calling itself by name knows the answer to every
          ;; question the general call sequence asks: which closure (the one
          ;; it is running), how many arguments (the right number, or this
          ;; would not compile), and where the code is (here). So it jumps
          ;; straight in, past the check it would only be proving to itself.
          ;; Variadic functions are left alone, because the rest-list code
          ;; downstream reads the count out of t1.
          (if variadic
              nil
              (begin (set-cx-self-label! c ok) (set-cx-self-arity! c nreq)))
          (i-mv a $t3 $sp)
          (set-cx-framefix! c (asm-len a))  ; the one word that knows the frame size
          (i-addi-w a $sp $sp 0)          ; patched by size-frame, so it stays wide
          (i-sw a $ra $t3 -4)
          (i-sw a $s0 $t3 -8)
          (i-sw a $t0 $t3 -12)
          (i-sw a $s1 $t3 -16)
          (i-mv a $s0 $t3)
          ;; Point s1 at this function's own literal vector, which lives in
          ;; the code object hanging off the closure. Every constant, symbol
          ;; and inner code object the body mentions is one load from here.
          (i-lobj a $s1 $t0 (%* 4 clo-code))))))

(define (emit-epilogue c)
  (let ((a (cx-asm c)))
    (if (cx-leaf c)
        (i-mv a $s1 $lit-save)
        (begin
          (i-lw a $ra $s0 -4)
          (i-lw a $t3 $s0 -8)
          (i-lw a $s1 $s0 -16)
          (i-mv a $sp $s0)
          (i-mv a $s0 $t3)))))

(define (finish-frame c)
  ;; Now that every local is known, size the frame and patch the single
  ;; instruction in the prologue that mentions it. A leaf has no frame and
  ;; nothing to patch - but it does have an assumption to check.
  (if (cx-leaf c) (check-leaf c) (size-frame c)))

;; The pre-pass decides leaf-ness from the source, and a source pre-pass can
;; be wrong. This looks at what actually came out: if anything in a leaf's own
;; code writes ra, then ra does not survive after all and the function would
;; return to the wrong place. A build failure is the right outcome; a silent
;; miscompile of the return address is the worst one in the machine.
(define (check-leaf c)
  (let* ((a (cx-asm c))
         (buf (asm-buf a))
         (len (asm-len a))
         (i 0))
    (while (%< i len)
      (let ((lo (%logior (%bytes-ref buf i) (%lsh (%bytes-ref buf (%+ i 1)) 8))))
        (if (%= 3 (%logand lo 3))
            (begin
              ;; jal or jalr writing ra
              (if (%= 1 (%logand (%lsh lo -7) 31))
                  (let ((op (%logand lo 127)))
                    (if (if (%= op #x6f) t (%= op #x67))
                        (error "compile: a leaf that calls" (cx-name c))
                        nil))
                  nil)
              (set! i (%+ i 4)))
            (begin
              ;; c.jalr, which is c.ebreak when its register field is zero
              (if (%= #x9002 (%logand lo #xf07f))
                  (if (%> (%logand (%lsh lo -7) 31) 0)
                      (error "compile: a leaf that calls" (cx-name c))
                      nil)
                  nil)
              ;; and c.jal, which nothing emits but which would be a call
              (if (%= #x2001 (%logand lo #xe003))
                  (error "compile: a leaf that calls" (cx-name c))
                  nil)
              (set! i (%+ i 2))))))
    0))

(define (size-frame c)
  (let* ((a (cx-asm c))
         ;; +15 rather than +7: round up to eight and leave one spare word
         ;; below the last local, so a stray store cannot reach the caller.
         (frame (%logand (%+ (%+ frame-fixed (%* 4 (cx-maxlocals c))) 15) -8))
         (off (cx-framefix c))
         (save (asm-len a)))
    (if (%> frame 2000) (error "compile: frame too large in" (cx-name c)) nil)
    (asm-set-len! a off)
    (i-addi-w a $sp $sp (%- 0 frame))
    (asm-set-len! a save)
    frame))

;; ---------------------------------------------------------------- intrinsics
;; Everything the compiler knows about a name lives on the symbol, in the
;; function slot, as (intrinsic . aliases):
;;
;;   intrinsic   (arity . emitter), or nil
;;   aliases     ((nargs . target-symbol) ...)
;;
;; The emitter is handed the context with the arguments already in a0, a1,
;; and leaves the result in a0.
;;
;; This used to be two lists, ninety entries between them, walked at every
;; call site the compiler looked at. A symbol is a unique object with four
;; slots and two of them spare, so the answer was already one load away.
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

(define (inline-entry sym nargs)
  ;; The (arity . emitter) to open-code this call with, or nil. A symbol that
  ;; is itself an intrinsic wins outright, and an arity mismatch there is an
  ;; error rather than a silent call; an ordinary name only open-codes at the
  ;; argument count its alias was declared for.
  (let ((ci (compile-info sym)))
    (if (%cons? ci)
        (if (%car ci)
            (%car ci)
            (let ((p (assq nargs (%cdr ci))))
              (if p (%car (compile-info (%cdr p))) nil)))
        nil)))

;; Ordinary names that mean an intrinsic when called with the right number of
;; arguments. Without this, (< i n) in a loop calls the variadic `<`, which
;; conses a rest list on every iteration just to compare two numbers - the
;; single biggest cost in normal-looking Lisp.
;;
;; The price is that redefining one of these does not affect code already
;; compiled against it, which is the usual bargain for an open-coded operator.
(define *inline-aliases*
  ;; A quoted literal rather than a call to `list`: it is data, and building
  ;; it with a call would need more arguments than the calling convention
  ;; passes in registers.
  '((+ 2 %+) (- 2 %-) (* 2 %*) (/ 2 %/) (mod 2 %mod) (rem 2 %rem)
    (= 2 %=) (< 2 %<) (> 2 %>) (<= 2 %<=) (>= 2 %>=)
    (eq? 2 %eq?) (null? 1 %null?)
    (car 1 %car) (cdr 1 %cdr) (cons 2 %cons)
    (set-car! 2 %set-car!) (set-cdr! 2 %set-cdr!)
    (pair? 1 %cons?) (symbol? 1 %symbol?) (string? 1 %string?)
    (vector? 1 %vector?) (number? 1 %fixnum?) (fixnum? 1 %fixnum?)
    (char? 1 %char?)
    (vector-ref 2 %vector-ref) (vector-set! 3 %vector-set!)
    (vector-length 1 %vector-length)
    (string-ref 2 %string-ref) (string-set! 3 %string-set!)
    (string-length 1 %string-length)
    (bytes-ref 2 %bytes-ref) (bytes-set! 3 %bytes-set!)
    (bytes-length 1 %bytes-length)
    (char->integer 1 %char->int) (integer->char 1 %int->char)
    (logand 2 %logand) (logior 2 %logior) (logxor 2 %logxor)
    (lognot 1 %lognot) (ash 2 %ash) (lsh 2 %lsh)
    (peek 1 %ld-fixnum) (poke 2 %st-fixnum!) (peek8 1 %ld-byte) (poke8 2 %st-byte!)
    (min 2 %min) (max 2 %max) (min2 2 %min) (max2 2 %max)))


(define (emit-load-addr c reg)
  ;; a0 holds a tagged fixnum address; leave the raw address in reg.
  (i-srai (cx-asm c) reg $a0 1))

(define (definline name arity fn)
  (%set-car! (compile-info! name) (%cons arity fn)))

(define (defalias name nargs target)
  (let ((ci (compile-info! name)))
    (%set-cdr! ci (%cons (%cons nargs target) (%cdr ci)))))

;; ---------------------------------------------------------------- constant argument
;; A second operand that is written down rather than computed needs no
;; register to hold it and no instruction to put it there - and for the
;; shifts it needs no run-time decision about which way to go, which is what
;; the general form spends most of its ten instructions and two branches on.
;;
;; This matters most in the collector, where a bitmap index is
;; `(%lsh (%- p gc-heap-lo) -3)`: three operators, every one of them with a
;; constant, and every one of them paying for a register it did not need.
;;
;; Entries are (name fits? emitter); the emitter is handed the compiler and
;; the untagged constant, with the first argument already in a0.
(define *const-arg* nil)

;; The bound is on the constant, not on the doubled constant: a fixnum is
;; thirty-one bits, so testing 2k for range would itself overflow and wrap a
;; large constant round into a small one. 2k and 2k+1 both fit a twelve-bit
;; signed immediate exactly when k is in [-1024, 1023].
;; The immediate is the constant itself now rather than the tagged constant,
;; so the range is the instruction's twelve signed bits - and negating it for
;; a subtraction has to stay inside them too.
(define (fits-tagged-imm? k) (if (%>= k -2047) (%< k 2048) nil))
(define (shift-amount? k) (if (%> k -32) (%< k 32) nil))

(define (const-arg-entry h args)
  (let ((e (assq h *const-arg*)))
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

;; A tagged fixnum is 2n+1, so adding the constant k means adding 2k: the two
;; tag bits cancel and the correcting `addi` the general form needs disappears
;; along with the `li`.
(define (emit-add-const c k) (i-faddi (cx-asm c) $a0 $a0 k))
(define (emit-sub-const c k) (i-faddi (cx-asm c) $a0 $a0 (%- 0 k)))
;; and / or keep the low bit set when both sides have it, so the constant
;; goes in tagged and the answer comes out tagged. (xor does not, which is
;; why it is not here: it would need the correcting `ori` back again.)
(define (emit-and-const c k) (i-fandi (cx-asm c) $a0 $a0 k))
(define (emit-or-const c k) (i-fori (cx-asm c) $a0 $a0 k))

(define (emit-shift-const c k arith)
  ;; One instruction: the direction is known here, so nothing branches, and
  ;; the instruction does its own untagging and retagging.
  (let ((a (cx-asm c)))
    (if (%= k 0)
        nil
        (if (%> k 0)
            (i-fshi a $a0 $a0 0 k)
            (i-fshi a $a0 $a0 (if arith 2 1) (%- 0 k))))))

(define (emit-lsh-const c k) (emit-shift-const c k nil))
(define (emit-ash-const c k) (emit-shift-const c k t))

(define (setup-const-arg)
  (set! *const-arg*
        (list (list '%+ fits-tagged-imm? emit-add-const)
              (list '%- fits-tagged-imm? emit-sub-const)
              (list '%logand fits-tagged-imm? emit-and-const)
              (list '%logior fits-tagged-imm? emit-or-const)
              (list '%lsh shift-amount? emit-lsh-const)
              (list '%ash shift-amount? emit-ash-const))))

;; ---------------------------------------------------------------- constant index
;; An index that is written down rather than computed - which is every record
;; field and every closure slot - does not need a
;; register to hold it or an instruction to put it there. The immediate form
;; of the custom-1 opcode carries indices 0 to 31 in the instruction itself.
;;
;; Entries are (name type store?), and the index is always the second
;; argument, for the load and the store both.
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
  (let ((a (cx-asm c))
        (ty (cadr e))
        (i (cadr args)))
    (if (caddr e)
        (begin
          ;; The object and the value; the index is in the instruction.
          (compile-args c (list (%car args) (caddr args)) 2)
          (i-stxi a $a1 $a0 i ty)
          (i-mv a $a0 $a1))
        (begin
          (compile-expr c (%car args) nil)
          (i-ldxi a $a0 $a0 i ty)))
    (if tail (emit-return c) nil)))

(define (setup-intrinsics)
  ;; Start from clean: this runs once in the forge and again on the machine,
  ;; and a stale emitter left on a symbol would be a compiler that quietly
  ;; disagrees with itself.
  (dolist (s *inline-syms*) (%set-symbol-function! s nil))
  (set! *inline-syms* nil)
  (set! *indexed-imm*
        (list (list '%slot 0 nil) (list '%set-slot! 0 t)
              (list '%record-ref t-record nil) (list '%record-set! t-record t)
              (list '%vector-ref t-vector nil) (list '%vector-set! t-vector t)))
  (setup-const-arg)

  ;; ---- pairs ----
  ;; One instruction each, and the tag is checked on the way past: these are
  ;; the custom-0 opcodes, not plain loads and stores.
  (definline '%car 1 (lambda (c) (i-car (cx-asm c) $a0 $a0)))
  (definline '%cdr 1 (lambda (c) (i-cdr (cx-asm c) $a0 $a0)))
  (definline '%set-car! 2
    (lambda (c) (i-set-car (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%set-cdr! 2
    (lambda (c) (i-set-cdr (cx-asm c) $a1 $a0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%cons 2 (lambda (c) (emit-cons c $a0 $a1 $a0)))

  ;; ---- fixnum arithmetic ----
  ;; One checked instruction each. These used to be two to five unchecked
  ;; ones, and the check is the point: (+ "abc" 2) returned a *cons*, because
  ;; a string is an object pointer with its low three bits equal to four,
  ;; adding a tagged two adds four, and four plus four is the pair tag. A
  ;; pointer into the middle of a string, fabricated with one addition, and
  ;; car would read it.
  (definline '%+ 2 (lambda (c) (i-fadd (cx-asm c) $a0 $a0 $a1)))
  (definline '%- 2 (lambda (c) (i-fsub (cx-asm c) $a0 $a0 $a1)))
  (definline '%* 2 (lambda (c) (i-fmul (cx-asm c) $a0 $a0 $a1)))
  (definline '%/ 2 (lambda (c) (i-fdiv (cx-asm c) $a0 $a0 $a1)))
  (definline '%rem 2 (lambda (c) (i-frem (cx-asm c) $a0 $a0 $a1)))
  (definline '%mod 2
    (lambda (c)
      ;; Euclidean: the sign of the result follows the divisor. Tagging keeps
      ;; the sign, so the test is the one it always was.
      (let ((a (cx-asm c)) (done (asm-gensym-label "mod")))
        (i-frem a $t2 $a0 $a1)
        (i-li a $t3 1)                  ; the fixnum zero
        (i-beq a $t2 $t3 done)
        (i-fxor a $t4 $t2 $a1)
        (i-bge a $t4 $zero done)
        (i-fadd a $t2 $t2 $a1)
        (asm-label a done)
        (i-mv a $a0 $t2))))

  ;; ---- bitwise ----
  (definline '%logand 2 (lambda (c) (i-fand (cx-asm c) $a0 $a0 $a1)))
  (definline '%logior 2 (lambda (c) (i-for (cx-asm c) $a0 $a0 $a1)))
  (definline '%logxor 2 (lambda (c) (i-fxor (cx-asm c) $a0 $a0 $a1)))
  (definline '%lognot 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t2 -1)                 ; the fixnum -1 is also the word -1
        (i-fxor a $a0 $a0 $t2))))

  ;; A shift whose direction is only known at run time still needs its branch.
  ;; What it no longer needs is untagging both sides and retagging the answer.
  ;; A shift by a written-down amount is one instruction; see emit-shift-const.
  (definline '%ash 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (asm-gensym-label "ash"))
            (done (asm-gensym-label "ash")))
        (i-li a $t2 1)                  ; the fixnum zero
        (i-blt a $a1 $t2 right)
        (i-fsll a $a0 $a0 $a1)
        (i-j a done)
        (asm-label a right)
        (i-fsub a $t2 $t2 $a1)
        (i-fsra a $a0 $a0 $t2)
        (asm-label a done))))
  (definline '%lsh 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (asm-gensym-label "lsh"))
            (done (asm-gensym-label "lsh")))
        (i-li a $t2 1)
        (i-blt a $a1 $t2 right)
        (i-fsll a $a0 $a0 $a1)
        (i-j a done)
        (asm-label a right)
        (i-fsub a $t2 $t2 $a1)
        (i-fsrl a $a0 $a0 $t2)
        (asm-label a done))))

  ;; ---- comparisons producing a value ----
  (definline '%eq? 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-sub a $t2 $a0 $a1)
        (i-seqz a $t2 $t2)
        (emit-bool-from-flag c $t2 $a0))))
  ;; Checked, and no dearer than the unchecked slt they replace: a fixnum is
  ;; 2n+1, so the order is the same order either way.
  ;;
  ;; %eq? above is deliberately not one of these. It compares identity, on
  ;; values of any kind at all, and asking it for two numbers would be asking
  ;; it the wrong question.
  (definline '%< 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-flt a $t2 $a0 $a1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%> 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-flt a $t2 $a1 $a0)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%<= 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-flt a $t2 $a1 $a0)
        (i-xori a $t2 $t2 1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%>= 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-flt a $t2 $a0 $a1)
        (i-xori a $t2 $t2 1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%= 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-feq a $t2 $a0 $a1)
        (emit-bool-from-flag c $t2 $a0))))

  ;; ---- type tests ----
  (definline '%null? 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-seqz a $t2 $a0)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%fixnum? 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-andi a $t2 $a0 1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%cons? 1
    (lambda (c)
      ;; a cons is a non-nil word with the low three bits clear
      (let ((a (cx-asm c)))
        (i-andi a $t2 $a0 7)
        (i-seqz a $t2 $t2)
        (i-snez a $t3 $a0)
        (i-and a $t2 $t2 $t3)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%object? 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-andi a $t2 $a0 7)
        (i-addi a $t2 $t2 -4)
        (i-seqz a $t2 $t2)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%char? 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-andi a $t2 $a0 255)
        (i-addi a $t2 $t2 -2)
        (i-seqz a $t2 $t2)
        (emit-bool-from-flag c $t2 $a0))))

  ;; A predicate for one object type: a heap object whose header says so.
  (definline '%string? 1 (lambda (c) (emit-type-test c t-string)))
  (definline '%vector? 1 (lambda (c) (emit-type-test c t-vector)))
  (definline '%bytes? 1 (lambda (c) (emit-type-test c t-bytes)))
  (definline '%symbol? 1 (lambda (c) (emit-type-test c t-symbol)))
  (definline '%closure? 1 (lambda (c) (emit-type-test c t-closure)))
  (definline '%float? 1 (lambda (c) (emit-type-test c t-float)))
  (definline '%record? 1 (lambda (c) (emit-type-test c t-record)))

  ;; ---- object access ----
  (definline '%obj-type 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lobj a $t2 $a0 -4)
        (i-andi a $t2 $t2 255)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%obj-len 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lobj a $t2 $a0 -4)
        (i-srli a $t2 $t2 8)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  ;; One instruction, and it checks the tag, the index and the bound. Type 0
  ;; means any object at all: a slot is a slot, whatever is holding it.
  (definline '%slot 2
    (lambda (c) (i-ldx (cx-asm c) $a0 $a0 $a1 0)))
  (definline '%set-slot! 3
    (lambda (c)
      (i-stx (cx-asm c) $a2 $a0 $a1 0)
      (i-mv (cx-asm c) $a0 $a2)))
  ;; A record, and only a record. `%slot` above will take any object at all,
  ;; which is right for the handful of places that reach into a symbol, a
  ;; closure or a code object by index - and wrong everywhere else, because it
  ;; means `(win-get "abc" 1)` reads a string's bytes back as a window's y
  ;; coordinate. Anything that knows it is holding a record says so.
  (definline '%record-ref 2
    (lambda (c) (i-ldx (cx-asm c) $a0 $a0 $a1 t-record)))
  (definline '%record-set! 3
    (lambda (c)
      (i-stx (cx-asm c) $a2 $a0 $a1 t-record)
      (i-mv (cx-asm c) $a0 $a2)))

  ;; These name the type they require, so (vector-ref "abc" 0) is a trap and
  ;; not a plausible-looking word out of the middle of a string.
  (definline '%vector-ref 2
    (lambda (c) (i-ldx (cx-asm c) $a0 $a0 $a1 t-vector)))
  (definline '%vector-set! 3
    (lambda (c)
      (i-stx (cx-asm c) $a2 $a0 $a1 t-vector)
      (i-mv (cx-asm c) $a0 $a2)))
  (definline '%vector-length 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lw a $t2 $a0 -4)
        (i-srli a $t2 $t2 8)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%string-length 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lw a $t2 $a0 -4)
        (i-srli a $t2 $t2 8)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%bytes-length 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lw a $t2 $a0 -4)
        (i-srli a $t2 $t2 8)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%string-ref 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-ldxb a $t2 $a0 $a1 t-string)
        (i-slli a $a0 $t2 8)
        (i-ori a $a0 $a0 2))))          ; a character immediate
  (definline '%string-set! 3
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srli a $t3 $a2 8)
        (i-stxb a $t3 $a0 $a1 t-string)
        (i-mv a $a0 $a2))))
  (definline '%bytes-ref 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-ldxb a $t2 $a0 $a1 t-bytes)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%bytes-set! 3
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t3 $a2 1)
        (i-stxb a $t3 $a0 $a1 t-bytes)
        (i-mv a $a0 $a2))))

  ;; ---- characters ----
  (definline '%char->int 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srli a $t2 $a0 8)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%int->char 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-slli a $a0 $t2 8)
        (i-ori a $a0 $a0 2))))

  ;; ---- raw memory ----
  ;; A word or a byte at a tagged address. This was four instructions - strip
  ;; the tag off the address, load, shift the word up, put a tag back on - and
  ;; the collector's inner loops are made of little else.
  (definline '%ld-byte 1 (lambda (c) (i-tlb (cx-asm c) $a0 $a0 0)))
  (definline '%ld-half 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-lhu a $t2 $t2 0)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%ld-fixnum 1 (lambda (c) (i-tlw (cx-asm c) $a0 $a0 0)))
  (definline '%st-byte! 2
    (lambda (c)
      (i-tsb (cx-asm c) $a1 $a0 0)
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%st-half! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-sh a $t3 $t2 0)
        (i-mv a $a0 $a1))))
  (definline '%st-fixnum! 2
    (lambda (c)
      (i-tsw (cx-asm c) $a1 $a0 0)
      (i-mv (cx-asm c) $a0 $a1)))
  ;; Read and write a slot without retagging, for moving raw tagged words
  ;; around, and for reaching the machine's registers from Lisp.
  (definline '%ld-word 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-lw a $a0 $t2 0))))
  (definline '%st-word! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-sw a $a1 $t2 0)
        (i-mv a $a0 $a1))))
  (definline '%addr-of 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slli a $a0 $a0 1)
        (i-ori a $a0 $a0 1))))
  (definline '%from-addr 1
    (lambda (c) (i-srai (cx-asm c) $a0 $a0 1)))
  (definline '%global 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-lw a $t2 $t2 0)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%set-global! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-sw a $t3 $t2 0)
        (i-mv a $a0 $a1))))

  ;; ---- min and max ----
  ;; A fixnum is 2n+1, which preserves signed order, so these are right on
  ;; tagged values without untagging either side and retagging the answer.
  (definline '%min 2 (lambda (c) (i-min (cx-asm c) $a0 $a0 $a1)))
  (definline '%max 2 (lambda (c) (i-max (cx-asm c) $a0 $a0 $a1)))

  ;; ---- bits ----
  (definline '%popcount 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-cpop a $t2 $t2)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))

  ;; A bit array at a raw address, indexed by bit number. The collector's mark
  ;; and pin maps are the customers, and between them they are the busiest
  ;; code in the system - a mark test was a call, four shifts and a mask.
  ;;
  ;; The map is addressed a word at a time rather than a byte at a time, which
  ;; is what makes the low five bits of the index land exactly where `bext`
  ;; and `bset` look for them. Same bits either way on a little-endian
  ;; machine: bit i of the word at (i >> 5) is bit i & 7 of the byte at
  ;; (i >> 3), so the blitter can still clear a map by the byte.
  (definline '%bit-ref 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)          ; base address
        (i-srai a $t3 $a1 1)          ; bit index
        (i-srli a $t4 $t3 5)
        (i-sh2add a $t4 $t4 $t2)
        (i-lw a $t4 $t4 0)
        (i-bext a $t2 $t4 $t3)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%bit-set! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-srli a $t4 $t3 5)
        (i-sh2add a $t4 $t4 $t2)
        (i-lw a $t5 $t4 0)
        (i-bset a $t5 $t5 $t3)
        (i-sw a $t5 $t4 0)
        (i-mv a $a0 $zero))))

  ;; ---- symbols ----
  (definline '%symbol-name 1
    (lambda (c) (i-lobj (cx-asm c) $a0 $a0 (%* 4 sym-name))))
  (definline '%symbol-value 1
    (lambda (c) (i-lobj (cx-asm c) $a0 $a0 (%* 4 sym-value))))
  ;; What a reference to this name would see, and how to change it. On the
  ;; machine that is the symbol's value cell and nothing else, so these two
  ;; are `%symbol-value` again. They are spelled apart because the bootstrap
  ;; interpreter keeps its globals in a map of its own and its symbols' cells
  ;; hold the compiled definitions bound for the image - two worlds in one
  ;; heap, and a fluid binding has to land in the one doing the reading.
  (definline '%fluid-value 1
    (lambda (c) (i-lobj (cx-asm c) $a0 $a0 (%* 4 sym-value))))
  (definline '%set-fluid-value! 2
    (lambda (c)
      (i-sobj (cx-asm c) $a1 $a0 (%* 4 sym-value))
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%set-symbol-value! 2
    (lambda (c)
      (i-sobj (cx-asm c) $a1 $a0 (%* 4 sym-value))
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-function 1
    (lambda (c) (i-lobj (cx-asm c) $a0 $a0 (%* 4 sym-function))))
  (definline '%set-symbol-function! 2
    (lambda (c)
      (i-sobj (cx-asm c) $a1 $a0 (%* 4 sym-function))
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-plist 1
    (lambda (c) (i-lobj (cx-asm c) $a0 $a0 (%* 4 sym-plist))))
  (definline '%set-symbol-plist! 2
    (lambda (c)
      (i-sobj (cx-asm c) $a1 $a0 (%* 4 sym-plist))
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-flags 1
    (lambda (c) (i-lobj (cx-asm c) $a0 $a0 (%* 4 sym-flags))))
  (definline '%set-symbol-flags! 2
    (lambda (c)
      (i-sobj (cx-asm c) $a1 $a0 (%* 4 sym-flags))
      (i-mv (cx-asm c) $a0 $a1)))

  ;; ---- machine ----
  ;; The collector needs to know where the stack currently is, so it can scan
  ;; from there upwards for anything that looks like a pointer.
  ;; Which task is running. Dedicated for the life of the machine, like the
  ;; cons pointers, and swapped by the context switch for nothing, because the
  ;; trap stub was already saving all thirty two registers - so Exec needs no
  ;; variable for it, and a task's own state is one instruction away wherever
  ;; it is standing. It is nil before there is an Exec to have tasks.
  (definline '%this-task 0 (lambda (c) (i-mv (cx-asm c) $a0 $s2)))
  (definline '%set-this-task! 1
    (lambda (c) (i-mv (cx-asm c) $s2 $a0)))

  (definline '%stack-pointer 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slli a $a0 $sp 1)
        (i-ori a $a0 $a0 1))))

  ;; Write the cons allocator's current run back to memory. gp and tp are the
  ;; live bump pointer and its limit; anything that wants to look at the heap
  ;; from outside - saving an image, mostly - has to see them there.
  ;;
  ;; It deliberately leaves lg-cons-ptr alone. That is the high water mark,
  ;; the highest address ever handed out, and gp is only how far the current
  ;; run has got: lowering the mark to gp would leave every live pair above it
  ;; out of the saved image, and out of the collector's sweep.
  (definline '%sync-cons-run 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-sw a $gp $zero lg-cons-run)
        (i-sw a $tp $zero lg-cons-run-end)
        (i-mv a $a0 $zero))))

  ;; Reload the cons allocator's run from memory. The compactor has to call
  ;; this: gp and tp are live registers describing a region of the old heap,
  ;; and after everything has slid down they describe nothing.
  (definline '%reload-cons-run 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lw a $gp $zero lg-cons-run)
        (i-lw a $tp $zero lg-cons-run-end)
        (i-mv a $a0 $zero))))

  ;; Raise a synchronous trap with a reason in a7. This is how a task asks to
  ;; be rescheduled: the switch has to happen inside the trap handler, where
  ;; the whole register set has already been saved.
  (definline '%ecall 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $a7 $a0 1)
        (i-ecall a)
        (i-mv a $a0 $zero))))

  ;; Point mscratch at a register context. The trap stub restores from
  ;; whatever mscratch names on its way out, so this one instruction is the
  ;; entire context switch.
  (definline '%set-context 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-csrrw a $zero csr-mscratch $t2)
        (i-mv a $a0 $zero))))

  ;; Let the timer and the chips interrupt us.
  (definline '%enable-timer 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t2 2184)              ; MTIE | MEIE | MSIE
        (i-csrrs a $zero csr-mie $t2)
        (i-mv a $a0 $zero))))

  ;; Stop the processor until something interrupts it. The console reader
  ;; uses this rather than spinning, so an idle machine costs nothing.
  (definline '%wait-for-input 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-wfi a)
        (i-mv a $a0 $zero))))

  ;; The retired-instruction count, narrowed to thirty bits so that it is a
  ;; fixnum. Differences up to 2^30 cycles - about a second of machine time -
  ;; come out right, which is what timing anything actually needs.
  ;; The frame pointer, so the collector can start walking the chain. Paired
  ;; with %stack-pointer, these two are the entire root-finding interface the
  ;; compiler has to provide.
  (definline '%frame-pointer 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slli a $a0 $s0 1)
        (i-ori a $a0 $a0 1))))

  (definline '%cycles 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrs a $t2 csr-cycle $zero)
        (i-slli a $t2 $t2 2)
        (i-srli a $t2 $t2 2)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%halt 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-li a $t3 mmio-base)
        (i-sw a $t2 $t3 0))))
  ;; Turning interrupts off answers whether they were on, because the
  ;; instruction that does it computes that for free and the only question is
  ;; whether the answer is kept. Keeping it is what makes a critical section
  ;; nestable without a counter anybody has to agree about: every caller puts
  ;; back what it found, and nobody can turn interrupts on underneath somebody
  ;; who wanted them off.
  (definline '%disable 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrci a $a0 csr-mstatus 8)
        (i-srli a $a0 $a0 3)
        (i-andi a $a0 $a0 1)
        (i-slli a $a0 $a0 1)
        (i-ori a $a0 $a0 1))))
  ;; Put them back the way `%disable` found them. Branchless: the saved fixnum
  ;; becomes the MIE bit or zero, and setting no bits is a write of what was
  ;; already there.
  (definline '%restore-interrupts 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $a0 $a0 1)
        (i-slli a $a0 $a0 3)
        (i-csrrs a $zero csr-mstatus $a0)
        (i-mv a $a0 $zero))))
  ;; A trap returns through mret, which puts back the interrupt state the
  ;; faulting code had. An error abandons that code, so it must not inherit its
  ;; critical section: this sets the bit mret will restore from. The immediate
  ;; form of the CSR instructions only carries five bits and this one is bit
  ;; seven, so it goes through a register.
  (definline '%enable-after-trap 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t2 128)
        (i-csrrs a $zero csr-mstatus $t2)
        (i-mv a $a0 $zero))))
  ;; Unconditional, for the two places that are establishing a state rather
  ;; than restoring one: the kernel starting up, and an error unwinding to a
  ;; prompt with no idea what it interrupted.
  (definline '%enable 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrsi a $zero csr-mstatus 8)
        (i-mv a $a0 $zero))))

  ;; And the ordinary names that mean one of the above at the right argument
  ;; count. These hang off the same slot, so a call site asks one question.
  (dolist (e *inline-aliases*)
    (defalias (%car e) (cadr e) (caddr e)))
  nil)

;; `blt reg, zero` is spelled out because there is no bltz pseudo-op above.
(define (i-bltz-helper a rs label) (i-blt a rs $zero label))

;; ---------------------------------------------------------------- branches
;; A comparison feeding an `if` never builds a value: it becomes the branch.
(define *branch-ops*
  '((%< . lt) (%> . gt) (%<= . le) (%>= . ge)
    (%= . eq) (%eq? . eq) (%null? . null) (%cons? . nil)))

;; A type test asks about the tag bits, and in a test position the answer
;; only has to steer a branch. Building the answer first costs seven or eight
;; instructions - mask, two set-if-zeros, an and, a literal load and a
;; conditional move - and then throws it away on a `beqz`. Branching on the
;; tag directly is two or three.
;;
;; These three are the ones that matter: `%cons?` and `%object?` are how every
;; walk over the heap decides what it is looking at, and `%fixnum?` is the
;; first question most of the arithmetic asks. The collector asks them a
;; million times in a collection, and `car` asks one every time it is called.
(define (fusable-type-test? form)
  (if (%cons? form)
      (if (%= 1 (length (%cdr form)))
          (memq (%car form) '(%cons? %object? %fixnum?))
          nil)
      nil))

(define (fusable-test? form)
  (if (%cons? form)
      (let ((h (%car form)))
        (if (%eq? h '%null?)
            (%= 1 (length (%cdr form)))
            (if (memq h '(%< %> %<= %>= %= %eq?))
                (%= 2 (length (%cdr form)))
                nil)))
      nil))

;; Emit code that jumps to `label` when the test is FALSE.
(define (emit-test-jump-false c form label)
  (let ((a (cx-asm c)))
    (cond
     ((fusable-type-test? form)
      (compile-expr c (cadr form) nil)
      (let ((op (%car form)))
        (cond
         ;; odd
         ((%eq? op '%fixnum?)
          (i-andi a $t2 $a0 1)
          (i-beqz a $t2 label))
         ;; low three bits clear, and not nil
         ((%eq? op '%cons?)
          (i-andi a $t2 $a0 7)
          (i-bnez a $t2 label)
          (i-beqz a $a0 label))
         ;; low three bits are four
         (else
          (i-andi a $t2 $a0 7)
          (i-addi a $t2 $t2 -4)
          (i-bnez a $t2 label)))))
     ((fusable-test? form)
      (let ((op (%car form)) (args (%cdr form)))
        (if (%eq? op '%null?)
            (begin
              (compile-expr c (%car args) nil)
              (i-bnez a $a0 label))
            (begin
              (compile-args c args 2)
              (cond
               ((%eq? op '%<) (i-bge a $a0 $a1 label))
               ((%eq? op '%>) (i-bge a $a1 $a0 label))
               ((%eq? op '%<=) (i-blt a $a1 $a0 label))
               ((%eq? op '%>=) (i-blt a $a0 $a1 label))
               (else (i-bne a $a0 $a1 label)))))))
     (else
      (compile-expr c form nil)
      (i-beqz a $a0 label)))))

;; ---------------------------------------------------------------- arguments
;; Simple arguments go straight to their register. Anything that can run code
;; is evaluated first and parked on the stack, so evaluation order is still
;; left to right.
(define (simple-arg? c form)
  (cond
   ((%null? form) t)
   ((%fixnum? form) t)
   ((%char? form) t)
   ((%string? form) t)
   ((%vector? form) t)
   ((%symbol? form) t)
   ((%cons? form) (%eq? (%car form) 'quote))
   (else t)))

(define (compile-args c args n)
  ;; Leaves argument i in register a{i}.
  (let ((a (cx-asm c)) (plan nil) (pushed 0) (i 0))
    ;; pass one: evaluate and park the complicated ones
    (dolist (x args)
      (if (simple-arg? c x)
          (set! plan (%cons (%cons 'simple x) plan))
          (begin
            (compile-expr c x nil)
            (i-addi a $sp $sp -4)
            (i-sw a $a0 $sp 0)
            (set! plan (%cons (%cons 'stack pushed) plan))
            (set! pushed (%+ pushed 1)))))
    (set! plan (reverse plan))
    ;; pass two: the parked values first, while sp still points at them
    (set! i 0)
    (dolist (p plan)
      (if (%eq? (%car p) 'stack)
          (i-lw a (%+ $a0 i) $sp (%* 4 (%- (%- pushed 1) (%cdr p))))
          nil)
      (set! i (%+ i 1)))
    (if (%> pushed 0) (i-addi a $sp $sp (%* 4 pushed)) nil)
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
   ((%symbol? form) (emit-load c (resolve c form) reg))
   ((if (%cons? form) (%eq? (%car form) 'quote) nil)
    (emit-const c (cadr form) reg))
   (else (emit-const c form reg))))

;; ---------------------------------------------------------------- calls
(define (compile-call c form tail)
  (let* ((a (cx-asm c))
         (op (%car form))
         (args (%cdr form))
         (n (length args)))
    ;; Arguments nine and up are pushed, so that argument eight lands at 0(sp)
    ;; on entry and the callee finds the rest above it. A tail call cannot do
    ;; that, because its epilogue moves the stack out from under them.
    (if (%> n 8)
        (if tail
            (begin (compile-call c form nil) (emit-return c))
            (compile-call-many c form))
        (compile-call-few c form tail))))

(define (compile-call-many c form)
  ;; More than eight arguments. All of them are evaluated left to right onto
  ;; the stack; the first eight are then lifted into registers and the rest
  ;; are left where they are, reversed so that argument eight sits at 0(sp).
  ;; The callee's frame pointer is the stack pointer it was entered with, so
  ;; it reads argument 8+j at 4j(s0) without knowing how it got there.
  (let* ((a (cx-asm c))
         (op (%car form))
         (args (%cdr form))
         (n (length args))
         (extra (%- n 8))
         (i 0))
    (dolist (x args)
      (compile-expr c x nil)
      (i-addi a $sp $sp -4)
      (i-sw a $a0 $sp 0))
    ;; Pushed left to right, so argument k is at 4*(n-1-k) from the top.
    (while (%< i 8)
      (i-lw a (%+ $a0 i) $sp (%* 4 (%- (%- n 1) i)))
      (set! i (%+ i 1)))
    ;; Reverse the overflow block in place: it currently runs backwards.
    (set! i 0)
    (while (%< i (%/ extra 2))
      (let ((lo (%* 4 i)) (hi (%* 4 (%- (%- extra 1) i))))
        (i-lw a $t3 $sp lo)
        (i-lw a $t4 $sp hi)
        (i-sw a $t4 $sp lo)
        (i-sw a $t3 $sp hi))
      (set! i (%+ i 1)))
    (emit-load c (resolve c op) $t0)
    (i-li a $t1 n)
    (i-ldxi a $t2 $t0 clo-entry t-closure)
    (i-call-reg a $t2)
    (i-addi a $sp $sp (%* 4 n))))

;; A call is a self-call when the operator is this function's own name, that
;; name still means the global it was defined as, and the argument count is
;; the one the prologue was built for. The price is that redefining a function
;; does not reach the calls already inside it - the same bargain the open
;; coded primitives make, and the same one every Lisp that compiles at all
;; ends up making somewhere.
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
            (i-addi a $sp $sp -4)
            (i-sw a $a0 $sp 0)
            (set! op-on-stack t)))
      (compile-args c args n)
      (if (self-call? c op n)
          ;; Two instructions and a direct branch: the closure is the one in
          ;; this frame, and the target is a label in this very buffer.
          (begin
            (i-lw a $t0 $s0 clo-slot)
            (if tail
                (begin (emit-epilogue c) (i-j a (cx-self-label c)))
                (i-jal a $ra (cx-self-label c))))
          (begin
            (if op-on-stack
                (begin (i-lw a $t0 $sp 0) (i-addi a $sp $sp 4))
                (emit-load c (resolve c op) $t0))
            (i-li a $t1 n)
            ;; The entry point is slot 0 of a closure, and loading it with the
            ;; immediate-index opcode says so: same instruction as the plain
            ;; `lw` it replaces, except that calling a number, a string or nil
            ;; now faults with a diagnostic instead of jumping to whatever the
            ;; first word of the thing happened to be.
            (if tail
                (begin
                  (emit-epilogue c)
                  (i-ldxi a $t2 $t0 clo-entry t-closure)
                  (i-jr a $t2))
                (begin
                  (i-ldxi a $t2 $t0 clo-entry t-closure)
                  (i-call-reg a $t2))))))))

;; ---------------------------------------------------------------- expressions
(define (compile-expr c form tail)
  (let ((a (cx-asm c)))
    (cond
     ;; ---- constants ----
     ((%null? form) (i-mv a $a0 $zero) (if tail (emit-return c) nil))
     ((%symbol? form)
      (emit-load c (resolve c form) $a0)
      (if tail (emit-return c) nil))
     ((not (%cons? form))
      (emit-const c form $a0)
      (if tail (emit-return c) nil))

     (else
      (let ((h (%car form)))
        (cond
         ((%eq? h 'quote)
          (emit-const c (cadr form) $a0)
          (if tail (emit-return c) nil))

         ((%eq? h 'if) (compile-if c form tail))
         ((%eq? h 'begin) (compile-body c (%cdr form) tail))
         ((%eq? h 'let) (compile-let c form tail))
         ((%eq? h 'while) (compile-while c form tail))
         ((%eq? h 'set!) (compile-set c form tail))
         ((%eq? h 'define) (compile-inner-define c form tail))

         ((%eq? h 'lambda)
          ;; An anonymous function still belongs somewhere, and a backtrace
          ;; that says "lambda in fill-rect" is worth the one pair this costs.
          (compile-closure c (cadr form) (cddr form)
                           (%cons 'lambda (cx-name c)))
          (if tail (emit-return c) nil))

         ;; (%funcall f a b) is just a call whose operator happens to be an
         ;; expression, so it compiles to the ordinary call sequence rather
         ;; than to a call to something named %funcall.
         ((%eq? h '%funcall) (compile-call c (%cdr form) tail))

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
         (l-else (asm-gensym-label "else"))
         (l-end (asm-gensym-label "endif")))
    (emit-test-jump-false c test l-else)
    (compile-expr c then tail)
    (if tail
        nil                              ; the then branch already returned
        (i-j a l-end))
    (asm-label a l-else)
    (compile-expr c else-form tail)
    (if tail nil (asm-label a l-end))))

(define (compile-body c forms tail)
  (if (%null? forms)
      (begin (i-mv (cx-asm c) $a0 $zero) (if tail (emit-return c) nil))
      (begin
        (while (%cons? (%cdr forms))
          (compile-expr c (%car forms) nil)
          (set! forms (%cdr forms)))
        (compile-expr c (%car forms) tail))))

(define (compile-let c form tail)
  (let* ((binds (cadr form))
         (body (cddr form))
         (saved-env (cx-env c))
         (saved-n (cx-nlocals c))
         (slots nil))
    ;; Initialisers all see the outer scope, so `let` binds in parallel.
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

(define (box-or-plain c sym slot)
  ;; A variable that an inner lambda captures and that something assigns has
  ;; to live in a box, or the closure and the frame would see different values.
  (if (memq sym (cx-boxed c))
      (begin
        (emit-make-box c slot)
        (list 'boxed-local slot))
      (list 'local slot)))

(define (emit-make-box c slot)
  ;; Replace the slot's value with a one-cell box holding it. Never reached in
  ;; a leaf: boxing is a cons, and anything that conses is not one.
  (let ((a (cx-asm c)))
    (load-local c slot $a2)
    (emit-cons c $a2 $zero $a2 4)
    (store-local c slot $a2)))

(define (compile-while c form tail)
  (let* ((a (cx-asm c))
         (top (asm-gensym-label "while"))
         (done (asm-gensym-label "wend")))
    (asm-label a top)
    (emit-test-jump-false c (cadr form) done)
    (dolist (x (cddr form)) (compile-expr c x nil))
    (i-j a top)
    (asm-label a done)
    (i-mv a $a0 $zero)
    (if tail (emit-return c) nil)))

(define (compile-set c form tail)
  (let ((name (cadr form)))
    (compile-expr c (caddr form) nil)
    (emit-store c (resolve c name) $a0)
    (if tail (emit-return c) nil)))

(define (compile-inner-define c form tail)
  ;; An internal define makes a new local in the current frame.
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
;; An inner lambda is compiled into its own block of code. At the point the
;; lambda form appears, the enclosing function emits the few instructions that
;; build a closure and copy the captured values into it.
(define (compile-closure c params body name)
  (let* ((a (cx-asm c))
         (free (filter (lambda (s) (cx-lookup c s))
                       (dedup (free-vars (%cons 'lambda (%cons params body)) nil))))
         ;; A captured variable that lives in a box stays boxed inside the
         ;; closure, so the inner function must know which of its free
         ;; variables to dereference.
         (free-boxed (map (lambda (s) (boxed-location? (resolve c s))) free))
         (entry-and-code (compile-function params body name free free-boxed))
         (entry (%car entry-and-code))
         (code (%cdr entry-and-code))
         (nfree (length free))
         (i 0))
    ;; The inner function is named by its code object, which carries its own
    ;; entry address. Nothing here mentions a code address, so the inner code
    ;; can be moved later without patching this call site.
    (emit-literal c code $a0)
    (i-li a $a1 (%logior (%lsh nfree 1) 1))
    (emit-load c (list 'global 'make-closure) $t0)
    (i-li a $t1 2)
    (i-ldxi a $t2 $t0 clo-entry t-closure)
    (i-call-reg a $t2)
    ;; a0 is the fresh closure; fill in the captured values.
    (dolist (s free)
      (emit-load-cell c (resolve c s) $t5)
      (i-sw a $t5 $a0 (%* 4 (%+ clo-free i)))
      (set! i (%+ i 1)))))

(define (dedup xs)
  (let ((acc nil))
    (dolist (x xs) (if (memq x acc) nil (set! acc (%cons x acc))))
    (reverse acc)))

;; ---------------------------------------------------------------- leaf test
;; Three things put a jal or a jalr into a function's own code: an ordinary
;; call, the allocator's slow path - so anything that conses - and building a
;; closure. Anything this walk does not recognise counts as a call, so it is
;; only ever wrong in the safe direction, and `check-leaf` reads the bytes
;; afterwards in case it is wrong in the other one.

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
         ((%eq? h 'lambda) nil)         ; make-closure is a call
         ((%eq? h 'define) nil)         ; and an inner define may be one
         ((%eq? h 'if) (leaf-body? (%cdr form) bound))
         ((%eq? h 'begin) (leaf-body? (%cdr form) bound))
         ((%eq? h 'while) (leaf-body? (%cdr form) bound))
         ((%eq? h 'set!) (leaf-body? (cddr form) bound))
         ((%eq? h 'let)
          (if (leaf-binds? (cadr form) bound) (leaf-body? (cddr form) bound) nil))
         ((%symbol? h)
          ;; An open-coded operator is a leaf if its arguments are. A name the
          ;; body binds shadows any intrinsic of the same name and makes an
          ;; ordinary call of it; and cons is open-coded but its slow path
          ;; calls the collector.
          (cond
           ((memq h bound) nil)
           ((memq h '(%cons cons)) nil)
           ((inline-entry h (length (%cdr form))) (leaf-body? (%cdr form) bound))
           (else nil)))
         (else nil)))
      t))

;; Every name the body binds, which is two questions at once: which names
;; shadow an intrinsic, and how many locals there could be. A leaf's locals
;; are eight registers and no more, and this over-counts (bindings in sibling
;; scopes share a slot at compile time) which is the safe way round.
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

(define (leaf-function? c forms names rest free)
  ;; Not variadic, because the rest list is a cons. Nothing boxed, because a
  ;; box is a cons. Locals within the eight registers. And nothing in the body
  ;; that can call. Captured variables are fine: they are read through t0.
  (if rest
      nil
      (if (%cons? (cx-boxed c))
          nil
          (let ((bound (bound-names (%cons 'begin forms) names)))
            (if (%> (length bound) leaf-locals)
                nil
                (leaf-body? forms bound))))))

;; Compile a lambda body into fresh code. Returns (entry-address . code-object).
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
    ;; Decide up front which variables need boxes.
    (set-cx-boxed! c (filter (lambda (s) (memq s captured)) (dedup assigned)))
    ;; And whether this is a leaf, which decides the whole shape of the frame
    ;; and where its locals live, so it has to be known before a word is
    ;; emitted.
    (set-cx-leaf! c (leaf-function? c expanded names rest free))
    (emit-prologue c nreq (if rest t nil))
    ;; Parameters land in the first local slots.
    (set! i 0)
    (dolist (p names)
      (if (%eq? p rest)
          nil
          (let ((slot (cx-alloc-local c)))
            ;; The first eight arrive in registers; the rest were pushed by
            ;; the caller and sit above the frame pointer, argument 8+j at
            ;; 4j(s0).
            ;; A leaf never gets here with i >= 8: nine parameters is nine
            ;; locals, and eight is all the registers set aside for them.
            (if (%< i 8)
                (store-local c slot (%+ $a0 i))
                (begin
                  (i-lw a $t3 $s0 (%* 4 (%- i 8)))
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
    (let ((entry (asm-place a)))
      (%cons entry (asm-code-object a (cx-name c))))))

;; Collect arguments nreq.. into a list. The eight argument registers are
;; spilled so the loop can index them uniformly with anything on the stack.
(define (emit-rest-list c nreq slot)
  (let* ((a (cx-asm c))
         (spill (cx-nlocals c))
         (loop (asm-gensym-label "rest"))
         (done (asm-gensym-label "rdone"))
         (from-reg (asm-gensym-label "rreg"))
         (got (asm-gensym-label "rgot"))
         (k 0))
    ;; Reserve eight slots for the spill.
    (while (%< k 8) (cx-alloc-local c) (set! k (%+ k 1)))
    (set! k 0)
    (while (%< k 8)
      (i-sw a (%+ $a0 k) $s0 (local-off (%+ spill k)))
      (set! k (%+ k 1)))
    (i-mv a $a2 $zero)                     ; the list under construction
    (i-addi a $t3 $t1 -1)                  ; i = nargs - 1
    (i-li a $t4 nreq)
    (asm-label a loop)
    (i-blt a $t3 $t4 done)
    (i-li a $t5 8)
    (i-blt a $t3 $t5 from-reg)
    (i-addi a $t6 $t3 -8)                  ; argument 8 and up sit above s0
    (i-slli a $t6 $t6 2)
    (i-add a $t6 $t6 $s0)
    (i-lw a $a3 $t6 0)
    (i-j a got)
    (asm-label a from-reg)
    (i-slli a $t6 $t3 2)
    (i-sub a $t6 $s0 $t6)
    (i-lw a $a3 $t6 (local-off spill))
    (asm-label a got)
    (emit-cons c $a3 $a2 $a2 12)
    (i-addi a $t3 $t3 -1)
    (i-j a loop)
    (asm-label a done)
    (i-sw a $a2 $s0 (local-off slot))))

;; ---------------------------------------------------------------- top level
;; A function definition is installed straight away, at compile time. Anything
;; else becomes a thunk on the boot list, which the kickstart runs in order
;; when the image starts - that is what makes the image a snapshot of a
;; running system rather than a pile of code.
(define *boot-thunks* nil)

(define (add-boot-thunk form)
  (let* ((r (compile-function nil (list form) 'toplevel nil))
         (clo (make-closure (%cdr r) 0)))
    (set! *boot-thunks* (%cons clo *boot-thunks*))
    clo))

;; A macro expander takes the form's argument list as a single argument and
;; picks it apart itself. The obvious alternative - call it with one argument
;; per element - runs into the calling convention at eight, which is a strange
;; place for a cond to stop working.
(define (macro-binder params var body)
  (if (%symbol? params)
      (%cons 'let (%cons (list (list params var)) body))
      (let ((binds nil) (p params) (path var))
        (while (%cons? p)
          (if (%symbol? (%car p))
              nil
              (error "defmacro: this parameter list is too clever" params))
          (set! binds (append binds (list (list (%car p) (list 'car path)))))
          (set! path (list 'cdr path))
          (set! p (%cdr p)))
        (if (%symbol? p)
            (set! binds (append binds (list (list p path))))
            nil)
        (%cons 'let* (%cons binds body)))))

;; `defrecord` is a macro, so that the interpreter has one to expand. Here it
;; has to be caught before expansion: the compiler wants the shape registered
;; before the rest of the file is read and the accessors open-coded, not just
;; the definitions the expansion would give it.
(define (compile-top form)
  (if (if (%cons? form) (%eq? (%car form) 'defrecord) nil)
      (compile-defrecord form)
      (compile-top-1 form)))

(define (compile-top-1 form)
  (set! form (macroexpand form))
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'define)
          (if (%cons? (cadr form))
              (let* ((name (caadr form))
                     (r (compile-function (cdadr form) (cddr form) name nil))
                     (clo (make-closure (%cdr r) 0)))
                (%set-symbol-value! name clo)
                name)
              ;; A variable definition is given its value now, because code
              ;; compiled later in the same build will read it as a constant,
              ;; and the initialiser is also recorded so that a booting image
              ;; re-runs it in source order.
              ;;
              ;; `(define name)` with nothing to run is a declaration and not
              ;; a definition: it names the variable, leaves any value already
              ;; there alone, and puts nothing on the boot list. That is what
              ;; a cell somebody installs into can be spelled as - the machine
              ;; recompiling its own sources walks over its own `define`s, and
              ;; must not knock out the allocator it is allocating through.
              (let ((name (cadr form)))
                (if (%cons? (cddr form))
                    (let ((expr (caddr form)))
                      (%set-symbol-value! name (compile-time-eval expr))
                      (record-initialiser name expr))
                    (if (%eq? (%symbol-value name) *unbound*)
                        (%set-symbol-value! name nil)
                        nil))
                name)))
         ;; A macro is needed twice: by the compiler running now, and by the
         ;; machine's own compiler once the image boots. So it is registered
         ;; with whatever expander is in charge here, and compiled into the
         ;; function cell where the other one will look for it.
         ((%eq? h 'defmacro)
          (register-macro form)
          (let* ((name (cadr form))
                 (r (compile-function (list 'macro-args)
                                      (list (macro-binder (caddr form) 'macro-args
                                                          (cdddr form)))
                                      name nil))
                 (clo (make-closure (%cdr r) 0)))
            (%set-symbol-function! name clo)
            (%set-symbol-flags! name (%logior (%symbol-flags name) sym-macro))
            name))
         ((%eq? h 'begin)
          (let ((last nil))
            (dolist (f (%cdr form)) (set! last (compile-top f)))
            last))
         (else (top-level-form form))))
      (top-level-form form)))

(define (field-name spec) (if (%cons? spec) (%car spec) spec))
(define (field-init spec) (if (%cons? spec) (cadr spec) nil))

;; The same expansion the interpreter's macro uses, compiled rather than
;; evaluated - and the shape registered on the way past, both here and, by the
;; form left in the boot list, in the machine that boots from this.
(define (compile-defrecord form)
  (let* ((forms (record-forms form))
         (head (cadr form))
         (type (if (%cons? head) (%car head) head))
         (s (record-shape type)))
    (top-level-form (list 'record-shape! (list 'quote type) (shape-prefix s)
                          (shape-open? s) (list 'quote (shape-fields s))))
    (dolist (f forms) (compile-top f))
    type))

(define (derived-name base suffix)
  (intern-in (current-package)
             (string-append (%symbol-name base) suffix)))

(define (derived-name2 prefix base suffix)
  (intern-in (current-package)
             (string-append prefix (string-append (%symbol-name base) suffix))))

(define (compile-file-forms forms)
  (dolist (f forms) (compile-top f))
  (length forms))

(setup-intrinsics)

;; From here on a record's accessors are open-coded as they are declared. The
;; shapes that were declared before this line - the collector's, the chips',
;; the assembler's, and this file's own - get done in one pass now.
(set! *record-inline-hook* (lambda (s) (install-record-inlines! s)))
(dolist (s *record-shapes*) (install-record-inlines! s))
