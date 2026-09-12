;;; macros.lisp - the rest of the language.
;;;
;;; The interpreter and the compiler know nine special forms between them.
;;; Everything else a program writes with is a macro here, so there is one
;;; definition of what `cond` means and the two evaluators cannot disagree.
;;;
;;; quasiquote has to be built without quasiquote, which is why its expander
;;; spells out every list it constructs.

(in-package lm)

(defmacro quasiquote (template)
  (qq-expand template 1))

(define (qq-expand x depth)
  (if (%cons? x)
      (let ((h (%car x)))
        (if (%eq? h 'unquote)
            (if (%= depth 1)
                (cadr x)
                (list 'list (list 'quote 'unquote) (qq-expand (cadr x) (%- depth 1))))
            (if (%eq? h 'quasiquote)
                (list 'list (list 'quote 'quasiquote) (qq-expand (cadr x) (%+ depth 1)))
                (qq-list x depth))))
      (if (%vector? x)
          (list 'list->vector (qq-list (vector->list x) depth))
          (if (%symbol? x) (list 'quote x) x))))

;; (append seg1 seg2 ...): an unquote-splicing contributes its own list and
;; everything else a one-element list.
(define (qq-list x depth)
  (if (%null? x)
      nil
      (if (%cons? x)
          (let ((h (%car x)))
            (if (%eq? h 'unquote)
                ;; a dotted (a . ,b) tail
                (if (%= depth 1) (cadr x) (qq-expand x depth))
                (list 'append2
                      (if (if (%cons? h) (%eq? (%car h) 'unquote-splicing) nil)
                          (if (%= depth 1)
                              (cadr h)
                              (list 'list (qq-expand h (%- depth 1))))
                          (list 'list (qq-expand h depth)))
                      (qq-list (%cdr x) depth))))
          (list 'quote x))))

;; ---------------------------------------------------------------- binding
(defmacro let* (binds . body)
  (if (%null? binds)
      `(let () ,@body)
      `(let (,(car binds)) (let* ,(cdr binds) ,@body))))

;; Every name is visible to every initialiser, for mutually recursive local
;; functions.
(defmacro letrec (binds . body)
  `(let ,(map (lambda (b) (list (car b) nil)) binds)
     ,@(map (lambda (b) (list 'set! (car b) (cadr b))) binds)
     ,@body))

(defmacro define-values (names form)
  `(let ((%dv ,form))
     ,@(let ((i -1))
         (map (lambda (n) (set! i (%+ i 1)) `(define ,n (nth ,i %dv))) names))))

;; ---------------------------------------------------------------- control
(defmacro when (test . body)
  `(if ,test (begin ,@body) nil))

(defmacro unless (test . body)
  `(if ,test nil (begin ,@body)))

(defmacro cond clauses
  (if (%null? clauses)
      nil
      (let* ((c (car clauses))
             (test (car c))
             (body (cdr c)))
        (if (%eq? test 'else)
            `(begin ,@body)
            (if (%null? body)
                ;; (cond (x) ...) yields x when x is true
                (let ((tmp (gensym)))
                  `(let ((,tmp ,test))
                     (if ,tmp ,tmp (cond ,@(cdr clauses)))))
                `(if ,test (begin ,@body) (cond ,@(cdr clauses))))))))

(defmacro and args
  (if (%null? args)
      t
      (if (%null? (cdr args))
          (car args)
          `(if ,(car args) (and ,@(cdr args)) nil))))

(defmacro or args
  (if (%null? args)
      nil
      (if (%null? (cdr args))
          (car args)
          (let ((tmp (gensym)))
            `(let ((,tmp ,(car args)))
               (if ,tmp ,tmp (or ,@(cdr args))))))))

(defmacro case (key . clauses)
  (let ((k (gensym)))
    `(let ((,k ,key))
       (cond ,@(map (lambda (c)
                      (if (%eq? (car c) 'else)
                          c
                          (if (%cons? (car c))
                              `((memq ,k ',(car c)) ,@(cdr c))
                              `((%eq? ,k ',(car c)) ,@(cdr c)))))
                    clauses)))))

;; (do ((v init step) ...) (test result ...) body ...)
(defmacro do (binds test-and-result . body)
  (let ((top (gensym)))
    `(let ,(map (lambda (b) (list (car b) (cadr b))) binds)
       (let ((,top nil))
         (set! ,top t)
         (while ,top
           (if ,(car test-and-result)
               (set! ,top nil)
               (begin
                 ,@body
                 ,@(map (lambda (b)
                          (if (%cons? (cddr b))
                              `(set! ,(car b) ,(caddr b))
                              nil))
                        binds)))))
       ,@(cdr test-and-result))))

;; (dolist (x list [result]) body ...)
(defmacro dolist (spec . body)
  (let ((rest (gensym)))
    `(let ((,rest ,(cadr spec)) (,(car spec) nil))
       (while (%cons? ,rest)
         (set! ,(car spec) (%car ,rest))
         ,@body
         (set! ,rest (%cdr ,rest)))
       ,(if (%cons? (cddr spec)) (caddr spec) nil))))

;; (dotimes (i n [result]) body ...)
(defmacro dotimes (spec . body)
  (let ((limit (gensym)))
    `(let ((,(car spec) 0) (,limit ,(cadr spec)))
       (while (%< ,(car spec) ,limit)
         ,@body
         (set! ,(car spec) (%+ ,(car spec) 1)))
       ,(if (%cons? (cddr spec)) (caddr spec) nil))))

(defmacro loop body
  `(while t ,@body))

;; ---------------------------------------------------------------- definition
(defmacro defun (name args . body)
  `(define (,name ,@args) ,@body))

(defmacro defvar (name . val)
  `(define ,name ,(if (%cons? val) (car val) nil)))

(defmacro defparameter (name val)
  `(define ,name ,val))

(defmacro defconstant (name val)
  `(define ,name ,val))

;; ---------------------------------------------------------------- mutation
;; `incf` and `decf` promote, like `+` and `-`.
(defmacro incf (place . delta)
  (let ((d (if (%cons? delta) (car delta) 1)))
    (if (%symbol? place)
        `(set! ,place (+ ,place ,d))
        (setter-form place `(+ ,place ,d)))))

(defmacro decf (place . delta)
  (let ((d (if (%cons? delta) (car delta) 1)))
    (if (%symbol? place)
        `(set! ,place (- ,place ,d))
        (setter-form place `(- ,place ,d)))))

(defmacro push (x place)
  (if (%symbol? place)
      `(set! ,place (%cons ,x ,place))
      (setter-form place `(%cons ,x ,place))))

(defmacro pop (place)
  (let ((tmp (gensym)))
    `(let ((,tmp (%car ,place)))
       ,(if (%symbol? place)
            `(set! ,place (%cdr ,place))
            (setter-form place `(%cdr ,place)))
       ,tmp)))

(defmacro setf (place val)
  (if (%symbol? place)
      `(set! ,place ,val)
      (setter-form place val)))

;; The writer form that matches a reader form.
(define (setter-form place val)
  (let ((head (car place)) (args (cdr place)))
    (cond ((memq head '(car %car first)) `(%set-car! ,(car args) ,val))
          ((memq head '(cdr %cdr rest)) `(%set-cdr! ,(car args) ,val))
          ((memq head '(cadr second)) `(%set-car! (%cdr ,(car args)) ,val))
          ((memq head '(caddr third)) `(%set-car! (%cdr (%cdr ,(car args))) ,val))
          ((memq head '(vector-ref %vector-ref))
           `(%vector-set! ,(car args) ,(cadr args) ,val))
          ((memq head '(string-ref %string-ref))
           `(%string-set! ,(car args) ,(cadr args) ,val))
          ((memq head '(bytes-ref %bytes-ref))
           `(%bytes-set! ,(car args) ,(cadr args) ,val))
          ((memq head '(%slot slot)) `(%set-slot! ,(car args) ,(cadr args) ,val))
          ((memq head '(get)) `(put ,(car args) ,(cadr args) ,val))
          ((memq head '(symbol-value %symbol-value))
           `(%set-symbol-value! ,(car args) ,val))
          ((memq head '(peek32 %ld-fixnum)) `(%st-fixnum! ,(car args) ,val))
          ((memq head '(peek8 %ld-byte)) `(%st-byte! ,(car args) ,val))
          ((memq head '(peek16 %ld-half)) `(%st-half! ,(car args) ,val))
          (else (error "setf does not know how to write to" head)))))

;; ---------------------------------------------------------------- misc sugar
;; (if-let (v expr) then else)
(defmacro if-let (bind then . else)
  `(let ((,(car bind) ,(cadr bind)))
     (if ,(car bind) ,then ,@else)))

(defmacro when-let (bind . body)
  `(let ((,(car bind) ,(cadr bind)))
     (if ,(car bind) (begin ,@body) nil)))

(defmacro assert (test . msg)
  `(if ,test nil (error "assertion failed:" ',test ,@msg)))

(defmacro comment body nil)

(defmacro time (form)
  `(let ((%t0 (cycles)))
     (let ((%v ,form))
       (display "  ") (display (%- (cycles) %t0)) (display " cycles")
       (newline)
       %v)))

;; ---------------------------------------------------------------- records
;; A record is an object whose slot 0 is a symbol naming its type and whose
;; other slots are named fields. `defrecord` is the only place the names are
;; written down:
;;
;;   (defrecord stream put get await)
;;     -> stream-slots, stream-alloc, stream?, stream-put, set-stream-put!, ...
;;   (defrecord (rastport rp) bitmap origin-x origin-y region)
;;     -> rp-bitmap and friends: a prefix, for a type name longer than its fields
;;   (defrecord (node open) succ pred pri name)
;;   (defrecord (task tc) (include node) state sigalloc ...)
;;
;; A field may be written `(name init)` to start as something other than nil.
;;
;; `<prefix>alloc` is the allocator: a record of the right size with its tag
;; and initial values. A constructor that does more is written by hand and
;; called `make-<type>`.
;;
;; `(include base)` puts another record's fields first, so a task is a node and
;; their slots line up; that is what Exec's lists are made of. `open` says
;; other records are built on this one, so its accessors check only that they
;; have a record, not which: a list holding tasks, ports and interrupts has to
;; be walkable by the node accessors.
;;
;; An accessor is an ordinary function, and the compiler open-codes every
;; call to one with the type check inline (see compile.lisp).

(define *record-shapes* nil)      ; (type prefix open . fields)

;; Set by the compiler once it is loaded; from then on a record's accessors
;; are open-coded as they are declared. Shapes declared before that are caught
;; up in one pass at the end of compile.lisp.
(define *record-inline-hook* nil)

(define (record-shape type) (assq type *record-shapes*))
(define (shape-prefix s) (cadr s))
(define (shape-open? s) (caddr s))
(define (shape-fields s) (cdddr s))

;; The type of a record, or nil for anything that is not one.
(define (record-tag r) (if (%record? r) (%slot r 0) nil))

;; `open` and `include` are read in whichever package the declaration is in,
;; so they are matched by name rather than made into exported symbols.
(define (word? x name)
  (if (%symbol? x) (string=? (symbol-name x) name) nil))

;; The options after the type name are `open` and, at most once, the prefix
;; the accessors wear.
(define (record-prefix-of opts type)
  (let ((r nil))
    (dolist (o opts)
      (if (word? o "open") nil (if r nil (set! r o))))
    (string-append (symbol-name (if r r type)) "-")))

(define (record-shape! type prefix open fields)
  (set! *record-shapes*
        (%cons (%cons type (%cons prefix (%cons open fields)))
               (filter (lambda (e) (not (%eq? (%car e) type))) *record-shapes*)))
  (let ((s (record-shape type)))
    (if *record-inline-hook* (%funcall *record-inline-hook* s) nil)
    s))

;; What an accessor does with the wrong kind of record. The open-coded form
;; traps instead and reports the same thing.
(define (record-fault type r)
  (error (string-append "expected a " (symbol-name type)) r))

(define (record-field r i type)
  (if (%eq? (%record-ref r 0) type) (%record-ref r i) (record-fault type r)))

(define (set-record-field! r i type v)
  (if (%eq? (%record-ref r 0) type) (%record-set! r i v) (record-fault type r)))

;; The declaration as ordinary definitions. The interpreter expands the macro
;; below; the compiler calls this directly, so that it can register the shape
;; first and open-code the accessors afterwards.
(define (record-forms form)
  (let* ((head (cadr form))
         (type (if (%cons? head) (%car head) head))
         (opts (if (%cons? head) (%cdr head) nil))
         (prefix (record-prefix-of opts type))
         (open (let ((r nil))
                 (dolist (o opts) (if (word? o "open") (set! r t) nil))
                 r))
         (pkg (symbol-package type))
         (fields nil)
         (inits nil)
         (out nil))
    (dolist (spec (cddr form))
      (if (if (%cons? spec) (word? (%car spec) "include") nil)
          (let ((base (record-shape (cadr spec))))
            (if base nil (error "defrecord: no record to include" (cadr spec)))
            (dolist (f (shape-fields base))
              (set! fields (append fields (list f)))
              (set! inits (append inits (list nil)))))
          (begin
            (set! fields (append fields (list (if (%cons? spec) (%car spec) spec))))
            (set! inits (append inits (list (if (%cons? spec) (cadr spec) nil)))))))
    (record-shape! type prefix open fields)
    (let ((n (%+ 1 (length fields)))
          (k 1)
          (body nil))
      ;; A fresh record is zeroed, and zero reads as nil, so only the fields
      ;; that start as something else are written.
      (dolist (v inits)
        (if v (set! body (append body (list (list '%set-slot! 'r k v)))) nil)
        (set! k (%+ k 1)))
      (set! out
            (list
             (list 'define (intern-in pkg (string-append prefix "slots")) n)
             (list 'define (list (intern-in pkg (string-append (symbol-name type) "?"))
                                 'x)
                   (list 'if (list '%record? 'x)
                         (list '%eq? (list '%slot 'x 0) (list 'quote type))
                         nil))
             (list 'define (list (intern-in pkg (string-append prefix "alloc")))
                   (append (list 'let (list (list 'r (list 'make-record n
                                                           (list 'quote type)))))
                           (append body (list 'r)))))))
    ;; The check is written out in each accessor rather than delegated to
    ;; `record-field`: the forge interprets these bodies, and a call inside a
    ;; call doubled what every field access cost the build.
    (let ((k 1))
      (dolist (f fields)
        (let ((n (symbol-name f)))
          (set! out
                (append
                 out
                 (list
                  (list 'define (list (intern-in pkg (string-append prefix n)) 'r)
                        (if open
                            (list '%record-ref 'r k)
                            (list 'if (list '%eq? (list '%record-ref 'r 0) (list 'quote type))
                                  (list '%record-ref 'r k)
                                  (list 'record-fault (list 'quote type) 'r))))
                  (list 'define (list (intern-in pkg
                                                 (string-append "set-" prefix n "!"))
                                      'r 'v)
                        (if open
                            (list '%record-set! 'r k 'v)
                            (list 'if (list '%eq? (list '%record-ref 'r 0) (list 'quote type))
                                  (list '%record-set! 'r k 'v)
                                  (list 'record-fault (list 'quote type) 'r))))))))
        (set! k (%+ k 1))))
    out))

;; ---------------------------------------------------------------- defsubst
;; A function whose calls are open-coded. The definition stays, so the name is
;; still a value, and a macro beside it expands a call into the body with the
;; arguments bound by `let`: each argument is evaluated once, in the caller's
;; scope. Not for anything recursive or large, since the body is copied to
;; every call site.
(defmacro defsubst (spec . body)
  (let ((name (%car spec))
        (params (%cdr spec)))
    (list 'begin
          (%cons 'define (%cons spec body))
          (list 'defmacro name params
                (%cons 'list
                       (%cons (list 'quote 'let)
                              (%cons (%cons 'list
                                            (map (lambda (v)
                                                   (list 'list (list 'quote v) v))
                                                 params))
                                     (map (lambda (f) (list 'quote f)) body))))))))

(defmacro defrecord spec
  (%cons 'begin (record-forms (%cons 'defrecord spec))))

;; ---------------------------------------------------------------- fluids
;; A place given a value for as long as a body runs, and put back after.
;;
;; A binding is a (place . saved-value) pair on a stack the running task owns,
;; and the scheduler swaps that stack with the registers. Swapping is
;; symmetrical: each entry holds the value that was current when the binding
;; was made, so exchanging the entry with the place leaves the task's value in
;; the entry and the outer value in the place, and exchanging again puts it
;; back. A task that binds nothing shares the globals, and a task that binds
;; and then assigns keeps the assignment, because what is exchanged is the
;; current value.

;; Where the bindings live. Exec installs these once there are tasks; before
;; that, and inside a trap, there is one stack.
(define *binds-get* nil)
(define *binds-set* nil)
(define *boot-binds* nil)

(define (task-binds) (if *binds-get* (%funcall *binds-get*) *boot-binds*))
(define (set-task-binds! v)
  (if *binds-set* (%funcall *binds-set* v) (set! *boot-binds* v)))

;; A place is a symbol, whose value cell is exchanged, or `package`: the
;; current package lives in a machine slot rather than a variable.
(define (place-value p)
  (if (%eq? p 'package) (current-package) (%fluid-value p)))

(define (set-place-value! p v)
  (if (%eq? p 'package) (set-current-package! v) (%set-fluid-value! p v)))

(define (bind-fluid! place value)
  (without-interrupts
    (set-task-binds! (%cons (%cons place (place-value place)) (task-binds)))
    (set-place-value! place value))
  nil)

(define (unbind-fluid!)
  (without-interrupts
    (let ((b (%car (task-binds))))
      (set-place-value! (%car b) (%cdr b))
      (set-task-binds! (%cdr (task-binds)))))
  nil)

;; Back to where the stack stood at `mark`, restoring every place bound since.
;; An error abandons the stack it happened on, so nothing on it unbinds what
;; it bound; the prompt's restart does this instead.
(define (unwind-binds-to! mark)
  (while (if (%cons? (task-binds)) (if (%eq? (task-binds) mark) nil t) nil)
    (unbind-fluid!))
  nil)

(define (swap-one! e)
  (let ((p (%car e)) (v (%cdr e)))
    (%set-cdr! e (place-value p))
    (set-place-value! p v)))

;; Out: innermost first, so a place bound twice ends up holding what it held
;; before the outermost binding.
(define (swap-binds-out! p)
  (while (%cons? p)
    (swap-one! (%car p))
    (set! p (%cdr p))))

;; And back, outermost first. The recursion is as deep as the bindings nest.
(define (swap-binds-in! p)
  (if (%cons? p)
      (begin (swap-binds-in! (%cdr p)) (swap-one! (%car p)))
      nil))

;; Bind the places for the extent of the body and put back what was there.
;; Like `without-interrupts`, this does not unwind on an error: the error
;; restarts a prompt, and `restart-stack` in sys.lisp puts the bindings back.
(defmacro fluid-let args
  (let ((binds (%car args))
        (body (%cdr args))
        (result (gensym))
        (out nil))
    (dolist (b binds)
      (set! out (append out (list (list 'bind-fluid! (list 'quote (%car b))
                                        (cadr b))))))
    (append (%cons 'begin out)
            (list (list 'let (list (list result (%cons 'begin body)))
                        (%cons 'begin (map (lambda (b) (list 'unbind-fluid!)) binds))
                        result)))))

;; ---------------------------------------------------------------- atomicity
;; Run the body with interrupts off, and put them back the way they were.
;;
;; A macro rather than a function taking a thunk: a thunk that captures
;; anything is a closure, which is an allocation, and the collector may not
;; allocate. It does not unwind either; an error inside resets to a prompt,
;; and `abort-to-repl` re-establishes the interrupt state.
(defmacro without-interrupts body
  (let ((saved (gensym)) (result (gensym)))
    `(let ((,saved (%disable)))
       (let ((,result (begin ,@body)))
         (%restore-interrupts ,saved)
         ,result))))
