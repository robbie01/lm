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

;; ---------------------------------------------------------------- ecall codes
(define trap-arity 1)
(define trap-type 2)
(define trap-oom 3)
(define trap-error 4)
(define trap-instance 6)

;; ---------------------------------------------------------------- context
;;  0 asm         1 env          2 nlocals    3 maxlocals   4 freevars
;;  5 boxed       6 name         7 frame-fix  8 outer-env   9 nparams
;; 10 self-label  11 self-arity
(define (cx-new asm name outer-env)
  (let ((c (make-vector-n 12 nil)))
    (%vector-set! c 0 asm)
    (%vector-set! c 1 nil)
    (%vector-set! c 2 0)
    (%vector-set! c 3 0)
    (%vector-set! c 4 nil)
    (%vector-set! c 5 nil)
    (%vector-set! c 6 name)
    (%vector-set! c 7 0)
    (%vector-set! c 8 outer-env)
    (%vector-set! c 9 0)
    (%vector-set! c 10 nil)
    (%vector-set! c 11 nil)
    c))

(define (cx-asm c) (%vector-ref c 0))
(define (cx-env c) (%vector-ref c 1))
(define (cx-set-env! c e) (%vector-set! c 1 e))
(define (cx-name c) (%vector-ref c 6))

(define (cx-alloc-local c)
  (let ((n (%vector-ref c 2)))
    (%vector-set! c 2 (%+ n 1))
    (if (%> (%+ n 1) (%vector-ref c 3)) (%vector-set! c 3 (%+ n 1)) nil)
    n))

(define (cx-bind c sym loc)
  (%vector-set! c 1 (%cons (%cons sym loc) (%vector-ref c 1))))

(define (cx-lookup c sym) (assq sym (%vector-ref c 1)))

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

;; ---------------------------------------------------------------- variables
;; A location is (local n), (boxed-local n), (free n), (boxed-free n) or
;; (global sym).
;; ---------------------------------------------------------------- instances
;; An instance is the state of one running application, and s2 says which one
;; is running. A package declares at most one shape - a package is the code,
;; an instance is its state - so a bare name inside that package can be a slot
;; of the instance rather than a global, and costs one instruction to read
;; where a global costs two.
;;
;;   slot 0   the type, so an instance can say what it is
;;   slot 1   the layout version, so code compiled against an old shape is
;;            caught at the boundary rather than reading the wrong field
;;   slot 2+  the fields, in declaration order
(define inst-tag 0)
(define inst-version 1)
(define inst-fields 2)

(define *instance-layouts* nil)   ; (package . [type version fields])
(define *instance-version* 0)

(define (instance-layout . opt)
  (let ((p (assq (if (%cons? opt) (%car opt) (current-package))
                 *instance-layouts*)))
    (if p (%cdr p) nil)))

(define (layout-type l) (%vector-ref l 0))
(define (layout-version l) (%vector-ref l 1))
(define (layout-fields l) (%vector-ref l 2))

;; A shape is needed twice, the way a macro is: by the compiler running now,
;; and by the machine's own compiler once the image boots. So the declaration
;; leaves a call behind in the boot list, and the machine registers it again
;; from the same numbers.
(define (register-instance-layout-in! pkg-name type version fields)
  (let ((pkg (find-package pkg-name))
        (v (make-vector-n 3 nil)))
    (%vector-set! v 0 type)
    (%vector-set! v 1 version)
    (%vector-set! v 2 fields)
    (if (%> version *instance-version*) (set! *instance-version* version) nil)
    (set! *instance-layouts*
          (%cons (%cons pkg v)
                 (filter (lambda (e) (not (%eq? (%car e) pkg))) *instance-layouts*)))
    v))

(define (register-instance-layout! type fields)
  (set! *instance-version* (%+ *instance-version* 1))
  (register-instance-layout-in! (package-name (current-package))
                                type *instance-version* fields))

;; Which slot, if any, this name is in the instance the current package runs as.
(define (instance-slot sym)
  (let ((l (instance-layout)))
    (if l
        (let ((fs (layout-fields l)) (i inst-fields) (found nil))
          (while (%cons? fs)
            (if (%eq? (%car fs) sym)
                (begin (set! found i) (set! fs nil))
                (begin (set! i (%+ i 1)) (set! fs (%cdr fs)))))
          found)
        nil)))

(define (resolve c sym)
  (let ((p (cx-lookup c sym)))
    (if p
        (%cdr p)
        (let ((k (instance-slot sym)))
          (if k (list 'instance k) (list 'global sym))))))

(define (emit-load c loc reg)
  (let ((a (cx-asm c)) (kind (%car loc)))
    (cond
     ((%eq? kind 'local) (i-lw a reg $s0 (local-off (cadr loc))))
     ((%eq? kind 'boxed-local)
      (i-lw a reg $s0 (local-off (cadr loc)))
      (i-lw a reg reg 0))
     ((%eq? kind 'free)
      (i-lw a $t6 $s0 clo-slot)
      (i-lw a reg $t6 (%* 4 (%+ clo-free (cadr loc)))))
     ((%eq? kind 'boxed-free)
      (i-lw a $t6 $s0 clo-slot)
      (i-lw a reg $t6 (%* 4 (%+ clo-free (cadr loc))))
      (i-lw a reg reg 0))
     ;; One instruction, off the register that says which instance is running.
     ((%eq? kind 'instance) (i-lw a reg $s2 (%* 4 (cadr loc))))
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
     ((%eq? kind 'local) (i-lw a reg $s0 (local-off (cadr loc))))
     ((%eq? kind 'boxed-local) (i-lw a reg $s0 (local-off (cadr loc))))
     ((%eq? kind 'free)
      (i-lw a $t6 $s0 clo-slot)
      (i-lw a reg $t6 (%* 4 (%+ clo-free (cadr loc)))))
     ((%eq? kind 'boxed-free)
      (i-lw a $t6 $s0 clo-slot)
      (i-lw a reg $t6 (%* 4 (%+ clo-free (cadr loc)))))
     (else (emit-load c loc reg)))))

(define (boxed-location? loc)
  (if (%eq? (%car loc) 'boxed-local) t (%eq? (%car loc) 'boxed-free)))

(define (emit-store c loc reg)
  (let ((a (cx-asm c)) (kind (%car loc)))
    (cond
     ((%eq? kind 'local) (i-sw a reg $s0 (local-off (cadr loc))))
     ((%eq? kind 'boxed-local)
      (i-lw a $t6 $s0 (local-off (cadr loc)))
      (i-sw a reg $t6 0))
     ((%eq? kind 'free)
      (i-lw a $t6 $s0 clo-slot)
      (i-sw a reg $t6 (%* 4 (%+ clo-free (cadr loc)))))
     ((%eq? kind 'boxed-free)
      (i-lw a $t6 $s0 clo-slot)
      (i-lw a $t6 $t6 (%* 4 (%+ clo-free (cadr loc))))
      (i-sw a reg $t6 0))
     ((%eq? kind 'instance) (i-sw a reg $s2 (%* 4 (cadr loc))))
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
  (let ((a (cx-asm c)) (tsym 't))
    (i-sub a flag-reg $zero flag-reg)   ; 0 -> 0, 1 -> all ones
    (emit-literal c tsym dst)
    (i-and a dst dst flag-reg)))

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
    ;; A function calling itself by name knows the answer to every question
    ;; the general call sequence asks: which closure (the one it is running),
    ;; how many arguments (the right number, or this would not compile), and
    ;; where the code is (here). So it jumps straight in, past the check it
    ;; would only be proving to itself. Variadic functions are left alone,
    ;; because the rest-list code downstream reads the count out of t1.
    (if variadic
        nil
        (begin (%vector-set! c 10 ok) (%vector-set! c 11 nreq)))
    (i-mv a $t3 $sp)
    (%vector-set! c 7 (asm-len a))      ; the one word that knows the frame size
    (i-addi a $sp $sp 0)                ; patched by finish-frame
    (i-sw a $ra $t3 -4)
    (i-sw a $s0 $t3 -8)
    (i-sw a $t0 $t3 -12)
    (i-sw a $s1 $t3 -16)
    (i-mv a $s0 $t3)
    ;; Point s1 at this function's own literal vector, which lives in the code
    ;; object hanging off the closure. Every constant, symbol and inner code
    ;; object the body mentions is one load from here.
    (i-lw a $s1 $t0 (%* 4 clo-code))))

(define (emit-epilogue c)
  (let ((a (cx-asm c)))
    (i-lw a $ra $s0 -4)
    (i-lw a $t3 $s0 -8)
    (i-lw a $s1 $s0 -16)
    (i-mv a $sp $s0)
    (i-mv a $s0 $t3)))

(define (finish-frame c)
  ;; Now that every local is known, size the frame and patch the single
  ;; instruction in the prologue that mentions it.
  (let* ((a (cx-asm c))
         ;; +15 rather than +7: round up to eight and leave one spare word
         ;; below the last local, so a stray store cannot reach the caller.
         (frame (%logand (%+ (%+ frame-fixed (%* 4 (%vector-ref c 3))) 15) -8))
         (off (%vector-ref c 7))
         (save (%vector-ref a 1)))
    (if (%> frame 2000) (error "compile: frame too large in" (cx-name c)) nil)
    (%vector-set! a 1 off)
    (i-addi a $sp $sp (%- 0 frame))
    (%vector-set! a 1 save)
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
    (peek 1 %ld32) (poke 2 %st32!) (peek8 1 %ld8) (poke8 2 %st8!)))


(define (emit-load-addr c reg)
  ;; a0 holds a tagged fixnum address; leave the raw address in reg.
  (i-srai (cx-asm c) reg $a0 1))

(define (definline name arity fn)
  (%set-car! (compile-info! name) (%cons arity fn)))

(define (defalias name nargs target)
  (let ((ci (compile-info! name)))
    (%set-cdr! ci (%cons (%cons nargs target) (%cdr ci)))))

(define (setup-intrinsics)
  ;; Start from clean: this runs once in the forge and again on the machine,
  ;; and a stale emitter left on a symbol would be a compiler that quietly
  ;; disagrees with itself.
  (dolist (s *inline-syms*) (%set-symbol-function! s nil))
  (set! *inline-syms* nil)

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
  ;; Tagging is 2n+1, so a sum needs one correction and nothing else.
  (definline '%+ 2
    (lambda (c) (i-add (cx-asm c) $a0 $a0 $a1) (i-addi (cx-asm c) $a0 $a0 -1)))
  (definline '%- 2
    (lambda (c) (i-sub (cx-asm c) $a0 $a0 $a1) (i-addi (cx-asm c) $a0 $a0 1)))
  (definline '%* 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-addi a $t3 $a1 -1)
        (i-mul a $a0 $t2 $t3)
        (i-addi a $a0 $a0 1))))
  (definline '%/ 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-div a $a0 $t2 $t3)
        (i-slli a $a0 $a0 1)
        (i-ori a $a0 $a0 1))))
  (definline '%rem 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-rem a $a0 $t2 $t3)
        (i-slli a $a0 $a0 1)
        (i-ori a $a0 $a0 1))))
  (definline '%mod 2
    (lambda (c)
      ;; Euclidean: the sign of the result follows the divisor.
      (let ((a (cx-asm c)) (done (asm-gensym-label "mod")))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-rem a $t4 $t2 $t3)
        (i-beqz a $t4 done)
        (i-xor a $t5 $t4 $t3)
        (i-bge a $t5 $zero done)
        (i-add a $t4 $t4 $t3)
        (asm-label a done)
        (i-slli a $a0 $t4 1)
        (i-ori a $a0 $a0 1))))

  ;; ---- bitwise. The low tag bit survives and/or/xor with a correction. ----
  (definline '%logand 2
    (lambda (c) (i-and (cx-asm c) $a0 $a0 $a1)))
  (definline '%logior 2
    (lambda (c) (i-or (cx-asm c) $a0 $a0 $a1)))
  (definline '%logxor 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-xor a $a0 $a0 $a1)
        (i-ori a $a0 $a0 1))))
  (definline '%lognot 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-not a $a0 $a0)
        (i-ori a $a0 $a0 1))))
  (definline '%ash 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (asm-gensym-label "ash"))
            (done (asm-gensym-label "ash")))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-bltz-helper a $t3 right)
        (i-sll a $t2 $t2 $t3)
        (i-j a done)
        (asm-label a right)
        (i-sub a $t3 $zero $t3)
        (i-sra a $t2 $t2 $t3)
        (asm-label a done)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%lsh 2
    (lambda (c)
      (let ((a (cx-asm c)) (right (asm-gensym-label "lsh"))
            (done (asm-gensym-label "lsh")))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-bltz-helper a $t3 right)
        (i-sll a $t2 $t2 $t3)
        (i-j a done)
        (asm-label a right)
        (i-sub a $t3 $zero $t3)
        (i-srl a $t2 $t2 $t3)
        (asm-label a done)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))

  ;; ---- comparisons producing a value ----
  (definline '%eq? 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-sub a $t2 $a0 $a1)
        (i-seqz a $t2 $t2)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%< 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slt a $t2 $a0 $a1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%> 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slt a $t2 $a1 $a0)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%<= 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slt a $t2 $a1 $a0)
        (i-xori a $t2 $t2 1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%>= 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-slt a $t2 $a0 $a1)
        (i-xori a $t2 $t2 1)
        (emit-bool-from-flag c $t2 $a0))))
  (definline '%= 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-sub a $t2 $a0 $a1)
        (i-seqz a $t2 $t2)
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
        (i-lw a $t2 $a0 -4)
        (i-andi a $t2 $t2 255)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%obj-len 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-lw a $t2 $a0 -4)
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
  (definline '%ld8 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-lbu a $t2 $t2 0)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%ld16 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-lhu a $t2 $t2 0)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%ld32 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-lw a $t2 $t2 0)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%st8! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-sb a $t3 $t2 0)
        (i-mv a $a0 $a1))))
  (definline '%st16! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-sh a $t3 $t2 0)
        (i-mv a $a0 $a1))))
  (definline '%st32! 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-srai a $t3 $a1 1)
        (i-sw a $t3 $t2 0)
        (i-mv a $a0 $a1))))
  ;; Read and write a slot without retagging, for moving raw tagged words
  ;; around, and for reaching the machine's registers from Lisp.
  (definline '%raw-ld 1
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a0 1)
        (i-lw a $a0 $t2 0))))
  (definline '%raw-st! 2
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

  ;; ---- symbols ----
  (definline '%symbol-name 1
    (lambda (c) (i-lw (cx-asm c) $a0 $a0 (%* 4 sym-name))))
  (definline '%symbol-value 1
    (lambda (c) (i-lw (cx-asm c) $a0 $a0 (%* 4 sym-value))))
  (definline '%set-symbol-value! 2
    (lambda (c)
      (i-sw (cx-asm c) $a1 $a0 (%* 4 sym-value))
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-function 1
    (lambda (c) (i-lw (cx-asm c) $a0 $a0 (%* 4 sym-function))))
  (definline '%set-symbol-function! 2
    (lambda (c)
      (i-sw (cx-asm c) $a1 $a0 (%* 4 sym-function))
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-plist 1
    (lambda (c) (i-lw (cx-asm c) $a0 $a0 (%* 4 sym-plist))))
  (definline '%set-symbol-plist! 2
    (lambda (c)
      (i-sw (cx-asm c) $a1 $a0 (%* 4 sym-plist))
      (i-mv (cx-asm c) $a0 $a1)))
  (definline '%symbol-flags 1
    (lambda (c) (i-lw (cx-asm c) $a0 $a0 (%* 4 sym-flags))))
  (definline '%set-symbol-flags! 2
    (lambda (c)
      (i-sw (cx-asm c) $a1 $a0 (%* 4 sym-flags))
      (i-mv (cx-asm c) $a0 $a1)))

  ;; ---- machine ----
  ;; The collector needs to know where the stack currently is, so it can scan
  ;; from there upwards for anything that looks like a pointer.
  ;; Which instance is running. Dedicated for the life of the machine, like
  ;; the cons pointers, and swapped by the context switch for nothing, because
  ;; the trap stub was already saving all thirty two registers.
  (definline '%instance 0 (lambda (c) (i-mv (cx-asm c) $a0 $s2)))
  (definline '%set-instance! 1
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
  (definline '%disable 0
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-csrrci a $zero csr-mstatus 8)
        (i-mv a $a0 $zero))))
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
    (if (fusable-test? form)
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
                 (else (i-bne a $a0 $a1 label))))))
        (begin
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
    (i-lw a $t2 $t0 0)
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
          (if (%vector-ref c 10)
              (if (cx-lookup c op) nil (%= n (%vector-ref c 11)))
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
                (begin (emit-epilogue c) (i-j a (%vector-ref c 10)))
                (i-jal a $ra (%vector-ref c 10))))
          (begin
            (if op-on-stack
                (begin (i-lw a $t0 $sp 0) (i-addi a $sp $sp 4))
                (emit-load c (resolve c op) $t0))
            (i-li a $t1 n)
            (if tail
                (begin
                  (emit-epilogue c)
                  (i-lw a $t2 $t0 0)
                  (i-jr a $t2))
                (begin
                  (i-lw a $t2 $t0 0)
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
         ((%eq? h 'with-instance) (compile-with-instance c form tail))

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

;; (with-instance expr body...) runs the body as that instance. The old one
;; goes on the stack rather than into a register, because everything between
;; sp and the frame link is a tagged value the collector already walks - so an
;; instance held across a collection is held by the same machinery that holds
;; a local.
;;
;; The shape is checked here rather than at every slot access: this is the
;; boundary, and ten instructions once beats one instruction never.
(define (compile-with-instance c form tail)
  ;; A package with no shape of its own can still enter somebody else's -
  ;; that is how a prompt gets inside a running application - it just has no
  ;; bare names for the slots, because they are not its names.
  (let ((a (cx-asm c))
        (l (instance-layout)))
    (compile-expr c (cadr form) nil)
    (emit-instance-check c l)
    (i-addi a $sp $sp -4)
    (i-sw a $s2 $sp 0)
    (i-mv a $s2 $a0)
    (compile-body c (cddr form) nil)
    (i-lw a $s2 $sp 0)
    (i-addi a $sp $sp 4)
    (if tail (emit-return c) nil)))

;; The type and the version, both, and a trap if either is wrong. The indexed
;; loads do the rest: they refuse anything that is not a record and anything
;; whose index is past the end, so a nil or a fixnum never gets this far.
(define (emit-instance-check c l)
  (let ((a (cx-asm c)))
    ;; The indexed load does the rest of the work: it refuses anything that is
    ;; not a record, so nil and fixnums never reach the comparisons.
    (i-li a $t4 (%+ (%* 2 inst-tag) 1))
    (i-ldx a $t2 $a0 $t4 t-record)
    (if l
        (let ((ok (asm-gensym-label "inst"))
              (ok2 (asm-gensym-label "instv")))
          (emit-literal c (layout-type l) $t3)
          (i-beq a $t2 $t3 ok)
          (i-li a $a7 trap-instance)
          (i-ecall a)
          (asm-label a ok)
          (i-li a $t4 (%+ (%* 2 inst-version) 1))
          (i-ldx a $t2 $a0 $t4 t-record)
          (i-li a $t3 (%+ (%* 2 (layout-version l)) 1))
          (i-beq a $t2 $t3 ok2)
          (i-li a $a7 trap-instance)
          (i-ecall a)
          (asm-label a ok2))
        nil)))

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
         (saved-n (%vector-ref c 2))
         (slots nil))
    ;; Initialisers all see the outer scope, so `let` binds in parallel.
    (dolist (b binds)
      (compile-expr c (cadr b) nil)
      (let ((slot (cx-alloc-local c)))
        (i-sw (cx-asm c) $a0 $s0 (local-off slot))
        (set! slots (%cons (%cons (%car b) slot) slots))))
    (dolist (s (reverse slots))
      (cx-bind c (%car s) (box-or-plain c (%car s) (%cdr s))))
    (compile-body c body tail)
    (cx-set-env! c saved-env)
    (%vector-set! c 2 saved-n)))

(define (box-or-plain c sym slot)
  ;; A variable that an inner lambda captures and that something assigns has
  ;; to live in a box, or the closure and the frame would see different values.
  (if (memq sym (%vector-ref c 5))
      (begin
        (emit-make-box c slot)
        (list 'boxed-local slot))
      (list 'local slot)))

(define (emit-make-box c slot)
  ;; Replace the slot's value with a one-cell box holding it.
  (let ((a (cx-asm c)))
    (i-lw a $a2 $s0 (local-off slot))
    (emit-cons c $a2 $zero $a2 4)
    (i-sw a $a2 $s0 (local-off slot))))

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
          (i-sw (cx-asm c) $a0 $s0 (local-off slot))
          (cx-bind c name (list 'local slot))))
      (let ((name (cadr form)))
        (compile-expr c (if (%cons? (cddr form)) (caddr form) nil) nil)
        (let ((slot (cx-alloc-local c)))
          (i-sw (cx-asm c) $a0 $s0 (local-off slot))
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
    (i-lw a $t2 $t0 0)
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

;; Compile a lambda body into fresh code. Returns (entry-address . code-object).
(define (compile-function params body name free . free-boxed-opt)
  (let* ((a (asm-new))
         (c (cx-new a name nil))
         (nreq (param-required params))
         (rest (param-rest params))
         (names (param-names params))
         (expanded (map macroexpand-all body))
         (assigned (assigned-vars (%cons 'begin expanded) nil))
         (captured (captured-vars (%cons 'begin expanded) nil))
         (i 0))
    ;; Decide up front which variables need boxes.
    (%vector-set! c 5 (filter (lambda (s) (memq s captured)) (dedup assigned)))
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
            (if (%< i 8)
                (i-sw a (%+ $a0 i) $s0 (local-off slot))
                (begin
                  (i-lw a $t3 $s0 (%* 4 (%- i 8)))
                  (i-sw a $t3 $s0 (local-off slot))))
            (cx-bind c p (list 'local slot))
            (set! i (%+ i 1)))))
    (if rest
        (let ((slot (cx-alloc-local c)))
          (emit-rest-list c nreq slot)
          (cx-bind c rest (list 'local slot)))
        nil)
    ;; Box the parameters that need it, now that they are in slots.
    (dolist (p names)
      (if (memq p (%vector-ref c 5))
          (let ((loc (%cdr (cx-lookup c p))))
            (emit-make-box c (cadr loc))
            (cx-set-env! c (%cons (%cons p (list 'boxed-local (cadr loc)))
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
         (spill (%vector-ref c 2))
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

(define (compile-top form)
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
         ;; An instance shape has to be known to the compiler before the rest
         ;; of the file is compiled, because it decides what a bare name means
         ;; from here on. So it is registered now and its constructor and
         ;; accessors are compiled as ordinary definitions.
         ((%eq? h 'definstance) (compile-definstance form))
         ((%eq? h 'begin)
          (let ((last nil))
            (dolist (f (%cdr form)) (set! last (compile-top f)))
            last))
         (else (top-level-form form))))
      (top-level-form form)))

(define (field-name spec) (if (%cons? spec) (%car spec) spec))
(define (field-init spec) (if (%cons? spec) (cadr spec) nil))

(define (derived-name base suffix)
  (intern-in (current-package)
             (string-append (%symbol-name base) suffix)))

(define (derived-name2 prefix base suffix)
  (intern-in (current-package)
             (string-append prefix (string-append (%symbol-name base) suffix))))

;; (definstance type (field init) field ...) declares the shape of an instance
;; of this package's application, and gives out:
;;
;;   (make-<type>)          a fresh one, fields set to their initial values
;;   (<field>-of i)         reaching in from outside, where the names are not
;;   (set-<field>-of! i v)  slots because the code is somewhere else
;;   (<type>? x)            is this one of ours
;;   (instances-of '<type>) the ones that are open
;;
;; Inside the package the fields are simply names, which is the whole point.
(define (compile-definstance form)
  (let* ((type (cadr form))
         (specs (cddr form))
         (fields (map field-name specs))
         (reg (derived-name2 "*" type "-instances*"))
         (l (register-instance-layout! type fields)))
    ;; A field may not also be a global here: after packages, a name that
    ;; silently means two things is exactly what we stopped putting up with.
    (dolist (f fields)
      (if (%eq? (%symbol-value f) *unbound*)
          nil
          (error "definstance: this name is already a global" f)))
    ;; The same registration, left in the boot list for the machine.
    (top-level-form (list 'register-instance-layout-in!
                          (package-name (current-package))
                          (list 'quote type)
                          (layout-version l)
                          (list 'quote fields)))
    (compile-top (list 'define reg nil))
    (compile-top
     (list 'define (list (derived-name type "?") 'x)
           (list 'if (list '%record? 'x)
                 (list '%eq? (list '%slot 'x inst-tag) (list 'quote type))
                 nil)))
    ;; The constructor fills the tag and the version first, so that the shape
    ;; check at every with-instance has something to look at.
    (let ((body (list (list '%set-slot! 'i inst-tag (list 'quote type))
                      (list '%set-slot! 'i inst-version (layout-version l))))
          (k inst-fields))
      (dolist (spec specs)
        (set! body (append body (list (list '%set-slot! 'i k (field-init spec)))))
        (set! k (%+ k 1)))
      (compile-top
       (list 'define (list (derived-name2 "make-" type ""))
             (append (list 'let (list (list 'i (list 'make-record
                                                     (%+ inst-fields (length fields))
                                                     (list 'quote type)))))
                     (append body
                             (list (list 'set! reg (list '%cons 'i reg)) 'i))))))
    ;; Closing one takes it off the list, which is the only reason the list
    ;; exists: an instance is opened and closed, the way a library is.
    (compile-top
     (list 'define (list (derived-name2 "close-" type "") 'i)
           (list 'set! reg (list 'remove-eq 'i reg))))
    (let ((k inst-fields))
      (dolist (f fields)
        (compile-top (list 'define (list (derived-name f "-of") 'i)
                           (list '%slot 'i k)))
        (compile-top (list 'define (list (derived-name2 "set-" f "-of!") 'i 'v)
                           (list '%set-slot! 'i k 'v)))
        (set! k (%+ k 1))))
    type))

(define (compile-file-forms forms)
  (dolist (f forms) (compile-top f))
  (length forms))

(setup-intrinsics)

