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
;;; Frame
;;;   s0 + 0        argument 8, if there is one
;;;   s0 - 4        saved ra
;;;   s0 - 8        saved s0
;;;   s0 - 12       the closure
;;;   s0 - 16 - 4i  local slot i
;;;   sp            below all of that; temporaries are pushed under it
;;;
;;; Only one instruction in the prologue depends on the frame size, so the
;;; frame is sized after the body is emitted and that single word is patched.

(define frame-fixed 16)
(define (local-off n) (%- (%- 0 frame-fixed) (%* 4 n)))
(define clo-slot -12)

;; ---------------------------------------------------------------- ecall codes
(define trap-arity 1)
(define trap-type 2)
(define trap-oom 3)
(define trap-error 4)

;; ---------------------------------------------------------------- context
;;  0 asm         1 env          2 nlocals    3 maxlocals   4 freevars
;;  5 boxed       6 name         7 frame-fix  8 outer-env   9 nparams
(define (cx-new asm name outer-env)
  (let ((c (make-vector-n 10 nil)))
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
      ;; A heap object. Nothing moves, so its address goes straight into the
      ;; instruction stream; the object is recorded as a literal so the
      ;; collector can reach it through the code object.
      (asm-literal a v)
      (i-li a reg (%addr-of v))))))

;; ---------------------------------------------------------------- variables
;; A location is (local n), (boxed-local n), (free n), (boxed-free n) or
;; (global sym).
(define (resolve c sym)
  (let ((p (cx-lookup c sym)))
    (if p (%cdr p) (list 'global sym))))

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
     (else
      (let ((sym (cadr loc)))
        (note-global-ref sym)
        (asm-literal a sym)
        (i-li a $t6 (%addr-of sym))
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
     (else
      (let ((sym (cadr loc)))
        (asm-literal a sym)
        (i-li a $t6 (%addr-of sym))
        (i-sw a reg $t6 (%* 4 sym-value)))))))

;; ---------------------------------------------------------------- allocation
;; Inline cons. gp is the bump pointer and tp the limit, both held in registers
;; for the life of the machine, so a fresh pair costs four instructions on the
;; fast path plus one well-predicted branch.
(define (emit-cons c car-reg cdr-reg dst)
  (let ((a (cx-asm c)) (ok (asm-gensym-label "cons")))
    (i-bltu a $gp $tp ok)
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
  (let ((a (cx-asm c)) (tsym (intern-string "t")))
    (asm-literal a tsym)
    (i-sub a flag-reg $zero flag-reg)   ; 0 -> 0, 1 -> all ones
    (i-li a dst (%addr-of tsym))
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
    (i-mv a $t3 $sp)
    (%vector-set! c 7 (asm-len a))      ; the one word that knows the frame size
    (i-addi a $sp $sp 0)                ; patched by finish-frame
    (i-sw a $ra $t3 -4)
    (i-sw a $s0 $t3 -8)
    (i-sw a $t0 $t3 -12)
    (i-mv a $s0 $t3)))

(define (emit-epilogue c)
  (let ((a (cx-asm c)))
    (i-lw a $ra $s0 -4)
    (i-lw a $t3 $s0 -8)
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
;; Each entry is (name arity . emitter). The emitter is handed the context
;; with the arguments already in a0, a1, ... and leaves the result in a0.
(define (intrinsic-entry name) (assq name *intrinsics*))

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

(define (inline-alias name nargs)
  (let ((p *inline-aliases*) (r nil))
    (while (%cons? p)
      (let ((e (%car p)))
        (if (if (%eq? (%car e) name) (%= (cadr e) nargs) nil)
            (begin (set! r (caddr e)) (set! p nil))
            (set! p (%cdr p)))))
    r))

(define (emit-load-addr c reg)
  ;; a0 holds a tagged fixnum address; leave the raw address in reg.
  (i-srai (cx-asm c) reg $a0 1))

(define *intrinsics* nil)

(define (definline name arity fn)
  (set! *intrinsics* (%cons (%cons name (%cons arity fn)) *intrinsics*)))

(define (setup-intrinsics)
  (set! *intrinsics* nil)

  ;; ---- pairs ----
  (definline '%car 1 (lambda (c) (i-lw (cx-asm c) $a0 $a0 0)))
  (definline '%cdr 1 (lambda (c) (i-lw (cx-asm c) $a0 $a0 4)))
  (definline '%set-car! 2
    (lambda (c) (i-sw (cx-asm c) $a1 $a0 0) (i-mv (cx-asm c) $a0 $a1)))
  (definline '%set-cdr! 2
    (lambda (c) (i-sw (cx-asm c) $a1 $a0 4) (i-mv (cx-asm c) $a0 $a1)))
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
  (definline '%slot 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a1 1)
        (i-slli a $t2 $t2 2)
        (i-add a $t2 $t2 $a0)
        (i-lw a $a0 $t2 0))))
  (definline '%set-slot! 3
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a1 1)
        (i-slli a $t2 $t2 2)
        (i-add a $t2 $t2 $a0)
        (i-sw a $a2 $t2 0)
        (i-mv a $a0 $a2))))
  (definline '%vector-ref 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a1 1)
        (i-slli a $t2 $t2 2)
        (i-add a $t2 $t2 $a0)
        (i-lw a $a0 $t2 0))))
  (definline '%vector-set! 3
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a1 1)
        (i-slli a $t2 $t2 2)
        (i-add a $t2 $t2 $a0)
        (i-sw a $a2 $t2 0)
        (i-mv a $a0 $a2))))
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
        (i-srai a $t2 $a1 1)
        (i-add a $t2 $t2 $a0)
        (i-lbu a $t2 $t2 0)
        (i-slli a $a0 $t2 8)
        (i-ori a $a0 $a0 2))))          ; a character immediate
  (definline '%string-set! 3
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a1 1)
        (i-add a $t2 $t2 $a0)
        (i-srli a $t3 $a2 8)
        (i-sb a $t3 $t2 0)
        (i-mv a $a0 $a2))))
  (definline '%bytes-ref 2
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a1 1)
        (i-add a $t2 $t2 $a0)
        (i-lbu a $t2 $t2 0)
        (i-slli a $a0 $t2 1)
        (i-ori a $a0 $a0 1))))
  (definline '%bytes-set! 3
    (lambda (c)
      (let ((a (cx-asm c)))
        (i-srai a $t2 $a1 1)
        (i-add a $t2 $t2 $a0)
        (i-srai a $t3 $a2 1)
        (i-sb a $t3 $t2 0)
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
            (i-call-reg a $t2))))))

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
          (compile-closure c (cadr form) (cddr form) nil)
          (if tail (emit-return c) nil))

         ;; (%funcall f a b) is just a call whose operator happens to be an
         ;; expression, so it compiles to the ordinary call sequence rather
         ;; than to a call to something named %funcall.
         ((%eq? h '%funcall) (compile-call c (%cdr form) tail))

         ;; ---- open-coded operations ----
         ((if (%symbol? h)
              (if (cx-lookup c h)
                  nil
                  (if (intrinsic-entry h) t (inline-alias h (length (%cdr form)))))
              nil)
          (let* ((e (let ((direct (intrinsic-entry h)))
                      (if direct
                          direct
                          (intrinsic-entry (inline-alias h (length (%cdr form)))))))
                 (arity (cadr e))
                 (fn (cddr e))
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
    (emit-cons c $a2 $zero $a2)
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
    (asm-literal a code)
    ;; make-closure is an ordinary global, so this is an ordinary call.
    (i-li a $a0 (%logior (%lsh entry 1) 1))
    (i-li a $a1 (%logior (%lsh nfree 1) 1))
    (i-li a $a2 (%addr-of code))
    (emit-load c (list 'global (intern-string "make-closure")) $t0)
    (i-li a $t1 3)
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
      (%cons entry (asm-code-object a)))))

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
    (emit-cons c $a3 $a2 $a2)
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
         (clo (make-closure (%car r) 0 (%cdr r))))
    (set! *boot-thunks* (%cons clo *boot-thunks*))
    clo))

(define (compile-top form)
  (set! form (macroexpand form))
  (if (%cons? form)
      (let ((h (%car form)))
        (cond
         ((%eq? h 'define)
          (if (%cons? (cadr form))
              (let* ((name (caadr form))
                     (r (compile-function (cdadr form) (cddr form) name nil))
                     (clo (make-closure (%car r) 0 (%cdr r))))
                (%set-symbol-value! name clo)
                name)
              ;; A variable definition is given its value now, because code
              ;; compiled later in the same build will read it as a constant,
              ;; and the initialiser is also recorded so that a booting image
              ;; re-runs it in source order.
              (let ((name (cadr form))
                    (expr (if (%cons? (cddr form)) (caddr form) nil)))
                (%set-symbol-value! name (compile-time-eval expr))
                (record-initialiser name expr)
                name)))
         ;; A macro is needed twice: by the compiler running now, and by the
         ;; machine's own compiler once the image boots. So it is registered
         ;; with whatever expander is in charge here, and compiled into the
         ;; function cell where the other one will look for it.
         ((%eq? h 'defmacro)
          (register-macro form)
          (let* ((name (cadr form))
                 (r (compile-function (caddr form) (cdddr form) name nil))
                 (clo (make-closure (%car r) 0 (%cdr r))))
            (%set-symbol-function! name clo)
            (%set-symbol-flags! name (%logior (%symbol-flags name) 1))
            name))
         ((%eq? h 'begin)
          (let ((last nil))
            (dolist (f (%cdr form)) (set! last (compile-top f)))
            last))
         (else (top-level-form form))))
      (top-level-form form)))

(define (compile-file-forms forms)
  (dolist (f forms) (compile-top f))
  (length forms))

(setup-intrinsics)

