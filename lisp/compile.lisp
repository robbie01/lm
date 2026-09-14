;;; compile.lisp - Lisp to native RISC-V.
;;;
;;; The same source runs twice. At build time the forge's interpreter runs it
;;; to compile the whole system, this file included, into the image. The
;;; image then holds a compiled copy of the compiler, which is what compiles
;;; forms typed at a prompt and what a rebuild uses.
;;;
;;; Calling convention
;;;   a0..a7   arguments 0..7; arguments 8 and up are pushed by the caller so
;;;            that argument 8 sits at 0(sp) on entry, which is 0(s0) inside
;;;   t0       the closure being called, so its free variables are reachable
;;;   t1       argument count, as a raw integer
;;;   a0       the result
;;;   gp       cons-space bump pointer      } dedicated for the life of the
;;;   tp       cons-space limit             } machine; allocation is inline
;;;   s1       the running function's code object, which holds its literals
;;;   s2       the running task
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
;;; frame is sized after the body is emitted and that word is patched.
;;;
;;; Every word between sp and s0-12 inclusive is a tagged Lisp value: locals,
;;; spilled temporaries, pushed arguments, the closure. Only the saved ra and
;;; the frame link are raw, at fixed offsets. That is what lets the collector
;;; walk a stack precisely with no stack maps.
;;;
;;; Pairs
;;;   car, cdr, set-car! and set-cdr! are single instructions in the custom-0
;;;   opcode space. The processor checks the tag as it forms the address, and
;;;   anything that is not a pair traps with the value in mtval, which
;;;   sys.lisp turns into a sentence naming it.

(in-package compiler)
(unsafe-file)                 ; it walks symbols, code and closures by slot

(define frame-fixed 20)
(define (local-off n) (%- (%- 0 frame-fixed) (%* 4 n)))
(define clo-slot -12)
(define lit-slot -16)

;; ---------------------------------------------------------------- leaves
;; A function that calls nothing needs none of the frame it would build. It
;; cannot be returned into, so ra survives; nothing can collect while it
;; runs, so its closure need not be findable on the stack; and no callee can
;; clobber its locals, so they stay in registers. About seven functions in
;; ten are leaves.
;;
;; s3..s10 hold a leaf's locals and s11 holds its caller's code object.
;; Nothing else in the machine touches those nine registers, so a leaf saves
;; and restores none of them.
(define (local-reg n) (%+ $s3 n))
(define leaf-locals 8)
(define $lit-save $s11)

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
(define (emit-const c v reg)
  (let ((a (cx-asm c)))
    (cond
     ((%null? v) (i-mv a reg $zero))
     ((%fixnum? v) (i-li-fixnum a reg v))
     ((%char? v) (i-li a reg (%logior (%lsh (%char->int v) 8) 2)))
     ;; A heap object is loaded from the code object's literal vector, so the
     ;; collector can move it and update one word.
     (else (emit-literal c v reg)))))

(define (emit-literal c v reg)
  (let* ((a (cx-asm c))
         (off (literal-offset (literal a v))))
    (if (%>= off 2048)
        (error "compile: too many literals in" (cx-name c))
        nil)
    (i-lw a reg $s1 off)))

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
          (i-beq a $t2 $t3 ok)
          (i-li a $a7 ecall-record)
          (i-ecall a)
          (label a ok)))))

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
(define (location-of c sym)
  (let ((p (cx-lookup c sym)))
    (if p (%cdr p) (list 'global sym))))

;; A local is a frame slot, or in a leaf a register. These three are the only
;; places that know which.
(define (load-local c n reg)
  (if (cx-leaf c)
      (i-mv (cx-asm c) reg (local-reg n))
      (i-lw (cx-asm c) reg $s0 (local-off n))))

(define (store-local c n reg)
  (if (cx-leaf c)
      (i-mv (cx-asm c) (local-reg n) reg)
      (i-sw (cx-asm c) reg $s0 (local-off n))))

;; Where this function's closure is. A framed function saved it at s0-12; a
;; leaf still has it in t0, because a leaf calls nothing and nothing else in
;; a body touches t0.
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
     ;; A global's value cell, through the load that refuses the unbound
     ;; marker: a name nothing was stored in is an error where it is read.
     (else
      (let ((sym (cadr loc)))
        (note-global-ref sym)
        (emit-literal c sym $t6)
        (i-lvar a reg $t6 (%* 4 sym-value)))))))

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
     ;; A checked store, not a plain `sw`: the write barrier watches
     ;; checked stores, and a global's old value may be the last pointer to
     ;; something the collector has not reached yet.
     (else
      (let ((sym (cadr loc)))
        (emit-literal c sym $t6)
        (i-sobj a reg $t6 (%* 4 sym-value)))))))

;; ---------------------------------------------------------------- allocation
;; Inline cons. gp is the bump pointer and tp the limit, so a fresh pair costs
;; four instructions on the fast path and one branch.
;;
;; `live` is a bitmask of the argument registers holding values that must
;; survive a collection. It goes into t5 on the slow path only, and the
;; refill stub stores it where the collector can read it, so the stack walker
;; takes exactly the live registers and ignores the rest.
(define (emit-cons c car-reg cdr-reg dst . live)
  (let ((a (cx-asm c))
        (ok (gensym-label "cons"))
        (mask (if (%cons? live) (%car live) 3)))
    (i-bltu a $gp $tp ok)
    (i-li a $t5 mask)
    (i-lw a $t6 $zero lg-gchook)
    (i-call-reg a $t6)
    (label a ok)
    (i-sw a car-reg $gp 0)
    (i-sw a cdr-reg $gp 4)
    (i-mv a dst $gp)
    (i-addi a $gp $gp 8)))

;; ---------------------------------------------------------------- booleans
;; A test that is not branched on at once has to make a value. The raw 0 or 1
;; a comparison leaves becomes nil or t without a branch.

;; True when a0 is a heap object whose header type is `type`. The tag check
;; comes first: reading a header off a fixnum would fault.
(define (emit-type-test c type)
  (let ((a (cx-asm c)) (no (gensym-label "nt")))
    (i-andi a $t2 $a0 7)
    (i-addi a $t2 $t2 -4)
    (i-mv a $t3 $zero)
    (i-bnez a $t2 no)
    (i-lw a $t3 $a0 -4)
    (i-andi a $t3 $t3 255)
    (i-addi a $t3 $t3 (%- 0 type))
    (i-seqz a $t3 $t3)
    (label a no)
    (emit-bool-from-flag c $t3 $a0)))

;; The literal 't is resolved when this file is read, so it is the one symbol
;; the source means whatever package is current at compile time. czero.eqz
;; keeps it when the flag is set and gives zero, which is nil, when not.
(define (emit-bool-from-flag c flag-reg dst)
  (let ((a (cx-asm c)) (tsym 't))
    (emit-literal c tsym dst)
    (i-czero-eqz a dst dst flag-reg)))

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
          (i-mv a $lit-save $s1)
          (i-lobj a $s1 $t0 (%* 4 clo-code)))
        (begin
          ;; A call by a function to its own name can skip the check above:
          ;; the closure is the one in this frame and the count is known to
          ;; be right. Variadic functions are left alone, because the
          ;; rest-list code reads the count out of t1.
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
          ;; s1 is this function's own code object, hanging off the closure.
          ;; Every constant, symbol and inner code object the body mentions
          ;; is one load from there.
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

;; Once every local is known: size the frame and patch the prologue. A leaf
;; has no frame, and instead has its assumption checked.
(define (finish-frame c)
  (if (cx-leaf c) (check-leaf c) (size-frame c)))

;; The pre-pass decides leaf-ness from the source, and could be wrong. This
;; reads the code that came out: if anything in a leaf's own code writes ra,
;; the function would return to the wrong place, and a build failure is the
;; right outcome.
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
              ;; c.jal, which nothing emits
              (if (%= #x2001 (%logand lo #xe003))
                  (error "compile: a leaf that calls" (cx-name c))
                  nil)
              (set! i (%+ i 2))))))
    0))

(define (size-frame c)
  (let* ((a (cx-asm c))
         ;; Rounded up to eight with one spare word below the last local, so
         ;; a stray store cannot reach the caller.
         (frame (%logand (%+ (%+ frame-fixed (%* 4 (cx-maxlocals c))) 15) -8))
         (off (cx-framefix c))
         (save (asm-len a)))
    (if (%> frame 2000) (error "compile: frame too large in" (cx-name c)) nil)
    (set-asm-len! a off)
    (i-addi-w a $sp $sp (%- 0 frame))
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

;; Ordinary names that mean an intrinsic at the right argument count, so
;; that (< i n) in a loop is one instruction rather than a call to the
;; variadic `<`. Redefining one of these does not affect code already
;; compiled against it.
;;
;; `+`, `-` and `*` are the trapping forms, so two-argument arithmetic
;; promotes to a bignum the way the variadic ones do. `ash` has no alias:
;; `%ash` takes the shift count modulo 32, which is wrong for (ash 1 100).
;; `peek` and `poke` have none: a tagged load drops bit 31.
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

;; ---------------------------------------------------------------- constant argument
;; A second operand that is written down needs no register and no instruction
;; to load it, and a shift by a written-down amount needs no run-time choice
;; of direction. Entries are (name fits? emitter); the emitter is handed the
;; context and the constant, with the first argument in a0.
(define *const-arg* nil)

;; The custom-3 immediate is the constant itself, doubled by the instruction,
;; so the range is the twelve signed bits of the field, and the negation a
;; subtraction uses has to fit as well.
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

(define (emit-add-const c k) (i-faddi (cx-asm c) $a0 $a0 k))
(define (emit-sub-const c k) (i-faddi (cx-asm c) $a0 $a0 (%- 0 k)))
;; and and or keep the tag bit when both sides have it, so the constant goes
;; in tagged and the answer comes out tagged. xor would need a correcting
;; ori, so it is not here.
(define (emit-and-const c k) (i-fandi (cx-asm c) $a0 $a0 k))
(define (emit-or-const c k) (i-fori (cx-asm c) $a0 $a0 k))

;; One instruction, which does its own untagging and retagging.
(define (emit-shift-const c k arith)
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
  (let ((a (cx-asm c))
        (ty (cadr e))
        (i (cadr args)))
    (if (caddr e)
        (begin
          (compile-args c (list (%car args) (caddr args)) 2)
          (i-stxi a $a1 $a0 i ty)
          (i-mv a $a0 $a1))
        (begin
          (compile-expr c (%car args) nil)
          (i-ldxi a $a0 $a0 i ty)))
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
  ;; One custom-0 instruction each, with the tag checked on the way past.
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
  (definline '%+ 2 (lambda (c) (i-fadd (cx-asm c) $a0 $a0 $a1)))
  (definline '%- 2 (lambda (c) (i-fsub (cx-asm c) $a0 $a0 $a1)))
  (definline '%* 2 (lambda (c) (i-fmul (cx-asm c) $a0 $a0 $a1)))
  ;; The same three, trapping rather than wrapping when the answer does not
  ;; fit. `+`, `-` and `*` are made of these: the trap handler widens the
  ;; operation into a bignum and resumes, so an integer that fits costs one
  ;; instruction.
  (definline '%+o 2 (lambda (c) (i-faddo (cx-asm c) $a0 $a0 $a1)))
  (definline '%-o 2 (lambda (c) (i-fsubo (cx-asm c) $a0 $a0 $a1)))
  (definline '%*o 2 (lambda (c) (i-fmulo (cx-asm c) $a0 $a0 $a1)))
  (definline '%/ 2 (lambda (c) (i-fdiv (cx-asm c) $a0 $a0 $a1)))
  (definline '%rem 2 (lambda (c) (i-frem (cx-asm c) $a0 $a0 $a1)))
  ;; Euclidean: the sign of the result follows the divisor.
  (definline '%mod 2
    (lambda (c)
      (let ((a (cx-asm c)) (done (gensym-label "mod")))
        (i-frem a $t2 $a0 $a1)
        (i-li a $t3 1)                  ; the fixnum zero
        (i-beq a $t2 $t3 done)
        (i-fxor a $t4 $t2 $a1)
        (i-bge a $t4 $zero done)
        (i-fadd a $t2 $t2 $a1)
        (label a done)
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

  ;; A shift whose direction is only known at run time branches on it. A
  ;; shift by a written-down amount is one instruction; see emit-shift-const.
  (definline '%ash 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (gensym-label "ash"))
            (done (gensym-label "ash")))
        (i-li a $t2 1)                  ; the fixnum zero
        (i-blt a $a1 $t2 right)
        (i-fsll a $a0 $a0 $a1)
        (i-j a done)
        (label a right)
        (i-fsub a $t2 $t2 $a1)
        (i-fsra a $a0 $a0 $t2)
        (label a done))))
  (definline '%lsh 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (gensym-label "lsh"))
            (done (gensym-label "lsh")))
        (i-li a $t2 1)
        (i-blt a $a1 $t2 right)
        (i-fsll a $a0 $a0 $a1)
        (i-j a done)
        (label a right)
        (i-fsub a $t2 $t2 $a1)
        (i-fsrl a $a0 $a0 $t2)
        (label a done))))

  ;; ---- comparisons producing a value ----
  ;; `%eq?` compares identity on values of any kind. The numeric comparisons
  ;; check their operands and widen through the trap handler.
  (definline '%eq? 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-sub a $t2 $a0 $a1)
        (i-seqz a $t2 $t2)
        (emit-bool-from-flag c $t2 $a0))))
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
  ;; a cons is a non-nil word with the low three bits clear
  (definline '%cons? 1
    (lambda (c)
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

  ;; A heap object whose header says so.
  (definline '%string? 1 (lambda (c) (emit-type-test c t-string)))
  (definline '%vector? 1 (lambda (c) (emit-type-test c t-vector)))
  (definline '%bytes? 1 (lambda (c) (emit-type-test c t-bytes)))
  (definline '%symbol? 1 (lambda (c) (emit-type-test c t-symbol)))
  (definline '%closure? 1 (lambda (c) (emit-type-test c t-closure)))
  (definline '%float? 1 (lambda (c) (emit-type-test c t-float)))
  (definline '%bignum? 1 (lambda (c) (emit-type-test c t-bignum)))
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
  ;; The header is read through `lobj`, which checks the tag for the same
  ;; price as the plain load: a fixnum handed to `vector-length` is a typed
  ;; error, not the word before some address.
  (definline '%vector-length 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lobj a $t2 $a0 -4)
        (i-srli a $t2 $t2 8)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%string-length 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lobj a $t2 $a0 -4)
        (i-srli a $t2 $t2 8)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%bytes-length 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lobj a $t2 $a0 -4)
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
  ;; A word or a byte at an address held as a fixnum. The loaded word comes
  ;; back as a fixnum, so bit 31 is lost; `%ld-word` keeps the word as it is.
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
  ;; A word read or written without retagging, for moving tagged words
  ;; around and for reaching the machine's saved registers.
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

  ;; ---- min and max ----
  ;; The comparison is `flt`, which checks its operands and widens through the
  ;; trap handler, and the choice is two conditional zeroes and an or.
  (definline '%min 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-flt a $t2 $a0 $a1)
        (i-czero-eqz a $t3 $a0 $t2)
        (i-czero-nez a $a0 $a1 $t2)
        (i-or a $a0 $a0 $t3))))
  (definline '%max 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-flt a $t2 $a1 $a0)
        (i-czero-eqz a $t3 $a0 $t2)
        (i-czero-nez a $a0 $a1 $t2)
        (i-or a $a0 $a0 $t3))))

  ;; The top sixteen bits of the product of two sixteen-bit numbers. The
  ;; bignum kernel works in halves: a product of two halves has thirty-two
  ;; bits, one more than a fixnum, so the bottom half comes from a wrapping
  ;; `%*` and the top half from here. This is the base `mul`.
  (definline '%mulhi16 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-mul a $t2 $t2 $t3)
        (i-srli a $t2 $t2 16)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))

  ;; ---- bits ----
  (definline '%popcount 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-cpop a $t2 $t2)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))

  ;; A bit array at a raw address, indexed by bit number: the collector's mark
  ;; and pin maps. The map is addressed a word at a time, which puts the low
  ;; five bits of the index where `bext` and `bset` look for them. On a
  ;; little-endian machine bit i of the word at (i >> 5) is bit i & 7 of the
  ;; byte at (i >> 3), so the blitter can still clear a map by the byte.
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
  ;; Through the typed indexed access, so the one instruction also checks
  ;; that it was given a symbol: these are in the checked vocabulary.
  (definline '%symbol-name 1
    (lambda (c) (i-ldxi (cx-asm c) $a0 $a0 sym-name t-symbol)))
  (definline '%symbol-value 1
    (lambda (c) (i-ldxi (cx-asm c) $a0 $a0 sym-value t-symbol)))
  ;; What a reference to this name sees, and how to change it. On the machine
  ;; that is the symbol's value cell, so these are `%symbol-value` again. They
  ;; are spelled apart because the forge's interpreter keeps its own globals
  ;; in a map of its own, and a fluid binding has to land in the world doing
  ;; the reading.
  (definline '%fluid-value 1
    (lambda (c) (i-ldxi (cx-asm c) $a0 $a0 sym-value t-symbol)))
  (definline '%set-fluid-value! 2
    (lambda (c)
      (i-stxi (cx-asm c) $a1 $a0 sym-value t-symbol)
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%set-symbol-value! 2
    (lambda (c)
      (i-stxi (cx-asm c) $a1 $a0 sym-value t-symbol)
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-function 1
    (lambda (c) (i-ldxi (cx-asm c) $a0 $a0 sym-function t-symbol)))
  (definline '%set-symbol-function! 2
    (lambda (c)
      (i-stxi (cx-asm c) $a1 $a0 sym-function t-symbol)
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-plist 1
    (lambda (c) (i-ldxi (cx-asm c) $a0 $a0 sym-plist t-symbol)))
  (definline '%set-symbol-plist! 2
    (lambda (c)
      (i-stxi (cx-asm c) $a1 $a0 sym-plist t-symbol)
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-flags 1
    (lambda (c) (i-ldxi (cx-asm c) $a0 $a0 sym-flags t-symbol)))
  (definline '%set-symbol-flags! 2
    (lambda (c)
      (i-stxi (cx-asm c) $a1 $a0 sym-flags t-symbol)
      (i-mv (cx-asm c) $a0 $a1)))

  ;; ---- machine ----
  ;; Which task is running: s2, dedicated for the life of the machine like the
  ;; cons pointers, and switched with the rest of the registers. It is nil
  ;; before there is an Exec.
  (definline '%this-task 0 (lambda (c) (i-mv (cx-asm c) $a0 $s2)))
  (definline '%set-this-task! 1
    (lambda (c) (i-mv (cx-asm c) $s2 $a0)))

  ;; The stack pointer and the frame pointer, as fixnums. Between them they
  ;; are the whole root-finding interface the collector needs.
  (definline '%stack-pointer 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slli a $a0 $sp 1)
        (i-ori a $a0 $a0 1))))
  (definline '%frame-pointer 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slli a $a0 $s0 1)
        (i-ori a $a0 $a0 1))))

  ;; Write the cons allocator's current run to memory, for anything that
  ;; looks at the heap from outside, such as saving an image. lg-cons-ptr is
  ;; left alone: it is the high-water mark, and gp is only how far the current
  ;; run has got.
  (definline '%sync-cons-run 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-sw a $gp $zero lg-cons-run)
        (i-sw a $tp $zero lg-cons-run-end)
        (i-mv a $a0 $zero))))

  ;; Reload the run from memory. The compactor needs this: after everything
  ;; has moved, gp and tp describe a region of the old heap.
  (definline '%reload-cons-run 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lw a $gp $zero lg-cons-run)
        (i-lw a $tp $zero lg-cons-run-end)
        (i-mv a $a0 $zero))))

  ;; A synchronous trap with a reason in a7. This is how a task asks to be
  ;; rescheduled: the switch happens inside the trap handler, where the whole
  ;; register set is already saved.
  (definline '%ecall 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $a7 $a0 1)
        (i-ecall a)
        (i-mv a $a0 $zero))))

  ;; Point mscratch at a register context. The trap stub restores from
  ;; whatever mscratch names on its way out, so this is the context switch.
  (definline '%set-context! 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-csrrw a $zero csr-mscratch $t2)
        (i-mv a $a0 $zero))))

  ;; Let the timer, the chips and software interrupts through.
  (definline '%enable-interrupt-lines 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-li a $t2 2184)              ; MTIE | MEIE | MSIE
        (i-csrrs a $zero csr-mie $t2)
        (i-mv a $a0 $zero))))

  ;; Stop the processor until something interrupts it.
  (definline '%wait-for-interrupt 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-wfi a)
        (i-mv a $a0 $zero))))

  ;; The immediate that marks a variable with no value yet. A constant, not
  ;; a global: a global holding it could not be read.
  (definline '%unbound 0
    (lambda (c) (i-li (cx-asm c) $a0 (%logior (%lsh imm-unbound 3) 2))))
  ;; The cycle counter, narrowed to thirty bits so that it is a fixnum.
  ;; Differences up to 2^30 cycles come out right.
  (definline '%cycles 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrs a $t2 csr-cycle $zero)
        (i-slli a $t2 $t2 2)
        (i-srli a $t2 $t2 2)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))

  ;; The lowest address the stack pointer may reach before the processor
  ;; faults; see `task-stack-limit` in exec.lisp. An address held as a fixnum.
  (definline '%set-stack-limit! 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-csrrw a $zero csr-stklim $t2)
        (i-mv a $a0 $zero))))
  (definline '%stack-limit 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrs a $t2 csr-stklim $zero)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  ;; The write barrier: 1 to turn it on, 0 to turn it off. See `gc:start`.
  (definline '%set-gc-mode! 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-csrrw a $zero csr-gcmode $t2)
        (i-mv a $a0 $zero))))
  ;; The register context mscratch names: inside a trap, the frame the
  ;; interrupted code was saved into. An address held as a fixnum.
  (definline '%context 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrs a $t2 csr-mscratch $zero)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%halt 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-li a $t3 mmio-base)
        (i-sw a $t2 $t3 0))))
  ;; Turning interrupts off answers whether they were on, which is what makes
  ;; a critical section nestable without a counter: every caller puts back
  ;; what it found.
  (definline '%disable 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrci a $a0 csr-mstatus 8)
        (i-srli a $a0 $a0 3)
        (i-andi a $a0 $a0 1)
        (i-slli a $a0 $a0 1)
        (i-ori a $a0 $a0 1))))
  ;; Put them back the way `%disable` found them. The saved fixnum becomes
  ;; the MIE bit or zero, and setting no bits changes nothing.
  (definline '%restore-interrupts 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $a0 $a0 1)
        (i-slli a $a0 $a0 3)
        (i-csrrs a $zero csr-mstatus $a0)
        (i-mv a $a0 $zero))))
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
        (i-mv a $a0 $zero))))
  ;; Unconditional, for the places that establish a state rather than
  ;; restore one: the kernel starting up, and a task that ends.
  (definline '%enable 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrsi a $zero csr-mstatus 8)
        (i-mv a $a0 $zero))))

  (dolist (e *inline-aliases*)
    (defalias (%car e) (cadr e) (caddr e)))
  nil)

;; ---------------------------------------------------------------- branches
;; A test feeding an `if` or a `while` never builds a value: it becomes the
;; branch.

;; A type test in a test position branches on the tag bits directly, in two
;; or three instructions, rather than building t or nil and testing that.
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

;; Jump to `label` when the test is false. The numeric comparisons go through
;; `flt` and `feq`, which check their operands and widen for bignums, and
;; then branch on the flag; `%eq?` is identity and branches directly.
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
               ((%eq? op '%<) (i-flt a $t2 $a0 $a1) (i-beqz a $t2 label))
               ((%eq? op '%>) (i-flt a $t2 $a1 $a0) (i-beqz a $t2 label))
               ((%eq? op '%<=) (i-flt a $t2 $a1 $a0) (i-bnez a $t2 label))
               ((%eq? op '%>=) (i-flt a $t2 $a0 $a1) (i-bnez a $t2 label))
               ((%eq? op '%=) (i-feq a $t2 $a0 $a1) (i-beqz a $t2 label))
               (else (i-bne a $a0 $a1 label)))))))
     ;; An `if` in a test position is `and`, `or` or `not` spelled out, and
     ;; is walked rather than built: each arm's test becomes its own branch.
     ;; `and` expands to (if a b nil), `or` to (if a a b) through a binding,
     ;; and the kernel's hand-nested (if (if a b nil) c nil) is the same shape.
     ((if (%cons? form) (%eq? (%car form) 'if) nil)
      (emit-if-test-jump-false c form label))
     (else
      (compile-expr c form nil)
      (i-beqz a $a0 label)))))

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

;; Leaves argument i in register a{i}.
(define (compile-args c args n)
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
    ;; pass two: the parked values, while sp still points at them
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
   ((%symbol? form) (emit-load c (location-of c form) reg))
   ((if (%cons? form) (%eq? (%car form) 'quote) nil)
    (emit-const c (cadr form) reg))
   (else (emit-const c form reg))))

;; ---------------------------------------------------------------- calls
;; Arguments nine and up are pushed, so that argument eight lands at 0(sp) on
;; entry and the callee finds the rest above it. A tail call cannot do that,
;; because its epilogue moves the stack out from under them.
(define (compile-call c form tail)
  (let* ((a (cx-asm c))
         (op (%car form))
         (args (%cdr form))
         (n (length args)))
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
;; reads argument 8+j at 4j(s0).
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
          (i-addi a $sp $sp -4)
          (i-sw a $a0 $sp 0))
        nil)
    (dolist (x args)
      (compile-expr c x nil)
      (i-addi a $sp $sp -4)
      (i-sw a $a0 $sp 0))
    ;; Pushed left to right, so argument k is at 4*(n-1-k) from the top.
    (while (%< i 8)
      (i-lw a (%+ $a0 i) $sp (%* 4 (%- (%- n 1) i)))
      (set! i (%+ i 1)))
    ;; Reverse the overflow block in place.
    (set! i 0)
    (while (%< i (%/ extra 2))
      (let ((lo (%* 4 i)) (hi (%* 4 (%- (%- extra 1) i))))
        (i-lw a $t3 $sp lo)
        (i-lw a $t4 $sp hi)
        (i-sw a $t4 $sp lo)
        (i-sw a $t3 $sp hi))
      (set! i (%+ i 1)))
    (if op-on-stack
        (i-lw a $t0 $sp (%* 4 n))
        (emit-load c (location-of c op) $t0))
    (i-li a $t1 n)
    (i-ldxi a $t2 $t0 clo-entry t-closure)
    (i-call-reg a $t2)
    (i-addi a $sp $sp (%* 4 (if op-on-stack (%+ n 1) n)))))

;; A call is a self-call when the operator is this function's own name, that
;; name is not shadowed by a local, and the argument count is the one the
;; prologue was built for. It reuses the closure in this frame and jumps past
;; the arity check. Redefining a function does not reach the self-calls
;; already inside it.
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
          (begin
            (i-lw a $t0 $s0 clo-slot)
            (if tail
                (begin (emit-epilogue c) (i-j a (cx-self-label c)))
                (i-jal a $ra (cx-self-label c))))
          (begin
            (if op-on-stack
                (begin (i-lw a $t0 $sp 0) (i-addi a $sp $sp 4))
                (emit-load c (location-of c op) $t0))
            (i-li a $t1 n)
            ;; The entry point is slot 0 of a closure, loaded with the
            ;; immediate-index instruction so that calling anything that is
            ;; not a closure traps with a report.
            (if tail
                (begin
                  (emit-epilogue c)
                  (i-ldxi a $t2 $t0 clo-entry t-closure)
                  (i-jr a $t2))
                (begin
                  (i-ldxi a $t2 $t0 clo-entry t-closure)
                  (i-call-reg a $t2))))))))

;; (%apply f list) calls f with the elements of the list as its arguments.
;; Up to eight it is an ordinary call, and a tail call in tail position. Past
;; eight the rest go on the stack, argument 8+j at 4j(sp), as
;; compile-call-many leaves them, except that how far the stack moves is only
;; known at run time. So the stack pointer to come back to waits in a local,
;; tagged as a fixnum so the collector passes over it. The space is cleared
;; before it is filled, because the collector reads every word of a frame as
;; a value. A list that does not end in nil stops at the count, on the typed
;; cdr.
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
    (i-beqz a $t3 counted)
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
          (i-ldxi a $t2 $t0 clo-entry t-closure)
          (i-jr a $t2))
        (begin
          (i-ldxi a $t2 $t0 clo-entry t-closure)
          (i-call-reg a $t2)
          (i-j a done)))
    ;; more than eight: t4 words of stack, cleared a checked push at a time
    (label a many)
    (i-addi a $t3 $sp 1)
    (store-local c slot $t3)
    (label a clear)
    (i-addi a $sp $sp -4)
    (i-sw a $zero $sp 0)
    (i-addi a $t4 $t4 -1)
    (i-bnez a $t4 clear)
    ;; then filled from the ninth element on, upwards
    (i-mv a $t3 $a1)
    (while (%< k 8) (i-cdr a $t3 $t3) (set! k (%+ k 1)))
    (i-mv a $t4 $sp)
    (label a fill)
    (i-car a $t5 $t3)
    (i-sw a $t5 $t4 0)
    (i-addi a $t4 $t4 4)
    (i-cdr a $t3 $t3)
    (i-bnez a $t3 fill)
    (emit-apply-registers c)
    (i-ldxi a $t2 $t0 clo-entry t-closure)
    (i-call-reg a $t2)
    (load-local c slot $t3)
    (i-addi a $sp $t3 -1)
    (label a done)
    (set-cx-nlocals! c saved-n)
    (if tail (emit-return c) nil)))

;; The first eight elements of the list in a1 into a0..a7, as far as it goes.
;; t3 takes the list before a1 is written.
(define (emit-apply-registers c)
  (let ((a (cx-asm c)) (end (gensym-label "aregs")) (k 0))
    (i-mv a $t3 $a1)
    (while (%< k 8)
      (i-beqz a $t3 end)
      (i-car a (%+ $a0 k) $t3)
      (i-cdr a $t3 $t3)
      (set! k (%+ k 1)))
    (label a end)))

;; ---------------------------------------------------------------- expressions
;; ---------------------------------------------------------------- unsafe
;; A raw operation, or a function that hands out raw memory, is a name with
;; the `sym-unsafe` bit (see `unsafe-names`). The compiler refuses to compile
;; a call to one, or a reference to one as a value, unless the site is inside
;; an `unsafe` form or the file said `(unsafe-file)` at its top. So the raw
;; vocabulary is still there, but every place it is used says so, and can
;; be found. What is not raw cannot fault the machine: it can only get a
;; typed error.
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

(define (compile-expr c form tail)
  (let ((a (cx-asm c)))
    (cond
     ;; ---- constants ----
     ((%null? form) (i-mv a $a0 $zero) (if tail (emit-return c) nil))
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
      (begin (i-mv (cx-asm c) $a0 $zero) (if tail (emit-return c) nil))
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

;; Replace the slot's value with a one-cell box holding it. Never reached in
;; a leaf: boxing is a cons, and anything that conses is not one.
(define (emit-make-box c slot)
  (let ((a (cx-asm c)))
    (load-local c slot $a2)
    (emit-cons c $a2 $zero $a2 4)
    (store-local c slot $a2)))

(define (compile-while c form tail)
  (let* ((a (cx-asm c))
         (top (gensym-label "while"))
         (done (gensym-label "wend")))
    (label a top)
    (emit-test-jump-false c (cadr form) done)
    (dolist (x (cddr form)) (compile-expr c x nil))
    (i-j a top)
    (label a done)
    (i-mv a $a0 $zero)
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
;; form appears, the enclosing function emits the instructions that build a
;; closure and copy the captured values into it. The inner function is named
;; by its code object, so nothing here mentions a code address.
(define (compile-closure c params body name)
  (let* ((a (cx-asm c))
         (free (filter (lambda (s) (cx-lookup c s))
                       (dedup (free-vars (%cons 'lambda (%cons params body)) nil))))
         ;; A captured variable that lives in a box stays boxed inside the
         ;; closure, so the inner function has to know which of its free
         ;; variables to dereference.
         (free-boxed (map (lambda (s) (boxed-location? (location-of c s))) free))
         (entry-and-code (compile-function params body name free free-boxed))
         (entry (%car entry-and-code))
         (code (%cdr entry-and-code))
         (nfree (length free))
         (i 0))
    (emit-literal c code $a0)
    (i-li a $a1 (%logior (%lsh nfree 1) 1))
    (emit-load c (list 'global 'make-closure) $t0)
    (i-li a $t1 2)
    (i-ldxi a $t2 $t0 clo-entry t-closure)
    (i-call-reg a $t2)
    ;; a0 is the fresh closure; fill in the captured values.
    (dolist (s free)
      (emit-load-cell c (location-of c s) $t5)
      (i-sw a $t5 $a0 (%* 4 (%+ clo-free i)))
      (set! i (%+ i 1)))))

(define (dedup xs)
  (let ((acc nil))
    (dolist (x xs) (if (memq x acc) nil (set! acc (%cons x acc))))
    (reverse acc)))

;; ---------------------------------------------------------------- leaf test
;; Three things put a jal or a jalr into a function's own code: an ordinary
;; call, the allocator's slow path, so anything that conses, and building a
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
         ((%eq? h 'unsafe) (leaf-body? (%cdr form) bound))
         ((%eq? h 'while) (leaf-body? (%cdr form) bound))
         ((%eq? h 'set!) (leaf-body? (cddr form) bound))
         ((%eq? h 'let)
          (if (leaf-binds? (cadr form) bound) (leaf-body? (cddr form) bound) nil))
         ((%symbol? h)
          ;; An open-coded operator is a leaf if its arguments are. A name the
          ;; body binds shadows any intrinsic of the same name and makes an
          ;; ordinary call of it; cons is open-coded but its slow path calls
          ;; the collector.
          (cond
           ((memq h bound) nil)
           ((memq h '(%cons cons)) nil)
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

;; Not variadic, because the rest list is a cons. Nothing boxed, because a
;; box is a cons. Locals within the eight registers. And nothing in the body
;; that can call. Captured variables are fine: they are read through t0.
(define (leaf-function? c forms names rest free)
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
    ;; Which variables need boxes, and whether this is a leaf, both have to
    ;; be known before a word is emitted.
    (set-cx-boxed! c (filter (lambda (s) (memq s captured)) (dedup assigned)))
    (set-cx-leaf! c (leaf-function? c expanded names rest free))
    (emit-prologue c nreq (if rest t nil))
    ;; Parameters land in the first local slots. The first eight arrive in
    ;; registers; the rest were pushed by the caller and sit above the frame
    ;; pointer, argument 8+j at 4j(s0). A leaf never has nine parameters,
    ;; because that is nine locals.
    (set! i 0)
    (dolist (p names)
      (if (%eq? p rest)
          nil
          (let ((slot (cx-alloc-local c)))
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
      (i-sw a (%+ $a0 k) $s0 (local-off (%+ spill k)))
      (set! k (%+ k 1)))
    (i-mv a $a2 $zero)                     ; the list under construction
    (i-addi a $t3 $t1 -1)                  ; i = nargs - 1
    (i-li a $t4 nreq)
    (label a loop)
    (i-blt a $t3 $t4 done)
    (i-li a $t5 8)
    (i-blt a $t3 $t5 from-reg)
    (i-addi a $t6 $t3 -8)                  ; argument 8 and up sit above s0
    (i-slli a $t6 $t6 2)
    (i-add a $t6 $t6 $s0)
    (i-lw a $a3 $t6 0)
    (i-j a got)
    (label a from-reg)
    (i-slli a $t6 $t3 2)
    (i-sub a $t6 $s0 $t6)
    (i-lw a $a3 $t6 (local-off spill))
    (label a got)
    (emit-cons c $a3 $a2 $a2 12)
    (i-addi a $t3 $t3 -1)
    (i-j a loop)
    (label a done)
    (i-sw a $a2 $s0 (local-off slot))))

;; ---------------------------------------------------------------- top level
;; A function definition is installed at compile time. Anything else becomes
;; a thunk on the boot list, which the kickstart runs in order when the image
;; starts.
(define *boot-thunks* nil)

(define (add-boot-thunk form)
  (let* ((r (compile-function nil (list form) 'toplevel nil))
         (clo (make-closure (%cdr r) 0)))
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

;; `defrecord` is a macro, so that the interpreter has one to expand. Here it
;; is caught before expansion: the compiler registers the shape so that the
;; accessors are open-coded from here on.
;; Three forms are directives to the compiler as much as code. `in-package`
;; ends an unsafe file, and is then compiled as usual; `(unsafe-file)`
;; begins one and compiles to nothing; `unsafe-names` marks its names now,
;; for the code compiled after it here, as well as at boot for the machine.
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
                     (clo (make-closure (%cdr r) 0)))
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
                 (clo (make-closure (%cdr r) 0)))
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

;; The raw vocabulary: what can read or write any word of RAM, forge a
;; pointer from a number, or set the machine's own state. Every checked
;; operation is not here, and neither are the reads that only hand out an
;; address as a number, which cannot be followed without one of these.
(unsafe-names
 '(%ld-word %st-word! %ld-half %st-half! %ld-fixnum %st-fixnum!
   %ld-byte %st-byte! %bit-ref %bit-set! %addr-of %from-addr
   %slot %set-slot!
   %set-context! %set-stack-limit! %set-gc-mode! %set-this-task!
   %ecall %halt %disable %enable %restore-interrupts %enable-after-trap
   %enable-interrupt-lines %wait-for-interrupt
   %sync-cons-run %reload-cons-run))

;; From here on a record's accessors are open-coded as the record is
;; declared. The shapes declared before this line get done now.
(set! *record-inline-hook* (lambda (s) (install-record-inlines! s)))
(dolist (s *record-shapes*) (install-record-inlines! s))
