;;; macros.lisp - the rest of the language.
;;;
;;; The interpreter and the compiler between them know only nine special
;;; forms. Everything a program actually writes with lives here, as macros, so
;;; there is exactly one definition of what `cond` means and no way for the two
;;; evaluators to disagree.
;;;
;;; quasiquote has to be built without quasiquote, which is why the expander
;;; below spells out every list it constructs.

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

(define (qq-list x depth)
  ;; Build (append seg1 seg2 ...) where an unquote-splicing contributes its
  ;; own list and everything else contributes a one-element list.
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

(defmacro letrec (binds . body)
  ;; Every name is visible to every initialiser, which is what makes a set of
  ;; mutually recursive local functions work.
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

(defmacro do (binds test-and-result . body)
  ;; (do ((v init step) ...) (test result ...) body ...)
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

(defmacro dolist (spec . body)
  ;; (dolist (x list [result]) body ...)
  (let ((rest (gensym)))
    `(let ((,rest ,(cadr spec)) (,(car spec) nil))
       (while (%cons? ,rest)
         (set! ,(car spec) (%car ,rest))
         ,@body
         (set! ,rest (%cdr ,rest)))
       ,(if (%cons? (cddr spec)) (caddr spec) nil))))

(defmacro dotimes (spec . body)
  ;; (dotimes (i n [result]) body ...)
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
(defmacro incf (place . delta)
  (let ((d (if (%cons? delta) (car delta) 1)))
    (if (%symbol? place)
        `(set! ,place (%+ ,place ,d))
        (setter-form place `(%+ ,place ,d)))))

(defmacro decf (place . delta)
  (let ((d (if (%cons? delta) (car delta) 1)))
    (if (%symbol? place)
        `(set! ,place (%- ,place ,d))
        (setter-form place `(%- ,place ,d)))))

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

(define (setter-form place val)
  ;; Turn a reader form into the matching writer form.
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
(defmacro if-let (bind then . else)
  ;; (if-let (v expr) then else)
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
;; Slot 0 of a record is a symbol saying what it is; the rest are named
;; fields, and this is where those names are written down. Once:
;;
;;   (defrecord stream put get await)
;;     -> stream-slots, stream-alloc, stream?, stream-put, set-stream-put!, ...
;;
;; `<prefix>alloc` is the allocator, not the constructor: it hands back a
;; record of the right size with the right tag and the declared initial
;; values, and whatever else making one of these means belongs in a
;; `make-<type>` written by hand. There is one public spelling for that and
;; this is not it.
;;   (defrecord (rastport rp) bm bw bh org-x org-y clip)
;;     -> rp-bm and friends, for a type name longer than its fields
;;   (defrecord (node ln open) succ pred pri name)
;;   (defrecord (task tc) (include node) state sigalloc ...)
;;
;; `(include base)` puts another record's fields first, so a task is a node
;; and their slots line up - which is what Exec's lists are made of. `open`
;; says other records are built on this one, so its accessors check that they
;; have a record rather than which record: something has to be able to walk a
;; list holding tasks and ports and interrupts at the same time.
;;
;; The accessors are ordinary functions, so `(map win-x ws)` means what it
;; looks like. The compiler open-codes every call to one - tag check included
;; - the same bargain it already makes for `car`, and one that comes out ahead
;; here because the hand-numbered `(win-get w win-x)` this replaces was a call.

(define *record-shapes* nil)      ; (type prefix open . fields)

;; The compiler sets this once it is loaded, and from then on a record's
;; accessors are open-coded as they are declared. The shapes declared before
;; that - the collector's, the chips', the assembler's - are caught up in one
;; pass at the bottom of compile.lisp.
(define *record-inline-hook* nil)

(define (record-shape type) (assq type *record-shapes*))
(define (shape-prefix s) (cadr s))
(define (shape-open? s) (caddr s))
(define (shape-fields s) (cdddr s))

;; Whatever a record is, slot 0 says so. Safe on anything: a fixnum is not a
;; record and has no tag rather than a wrong one.
(define (record-tag r) (if (%record? r) (%slot r 0) nil))

;; `open` and `include` are read in whichever package the declaration is in,
;; so they are matched by name. Nothing else in a defrecord is a keyword, and
;; making these two into exported symbols would put two more names into every
;; package that ever declares a record.
(define (word? x name)
  (if (%symbol? x) (string=? (symbol-name x) name) nil))

;; The options after the type name are `open` and, at most once, the prefix
;; the accessors wear. Neither has to be there.
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

;; What an accessor does when it is handed the wrong kind of record. The
;; open-coded form traps instead, and says the same thing.
(define (record-fault type r)
  (error (string-append "expected a " (symbol-name type)) r))

(define (record-field r i type)
  (if (%eq? (%record-ref r 0) type) (%record-ref r i) (record-fault type r)))

(define (set-record-field! r i type v)
  (if (%eq? (%record-ref r 0) type) (%record-set! r i v) (record-fault type r)))

;; The declaration, turned into ordinary definitions. Both evaluators use this
;; one function: the interpreter expands the macro below, and the compiler
;; calls it directly so that it can register the shape first and open-code the
;; accessors afterwards.
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
      ;; Only the fields that start as something other than nil are written:
      ;; a fresh record is zeroed, and a zero reads as nil.
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
                            (list 'record-field 'r k (list 'quote type))))
                  (list 'define (list (intern-in pkg
                                                 (string-append "set-" prefix n "!"))
                                      'r 'v)
                        (if open
                            (list '%record-set! 'r k 'v)
                            (list 'set-record-field! 'r k (list 'quote type) 'v)))))))
        (set! k (%+ k 1))))
    out))

;; ---------------------------------------------------------------- defsubst
;; A function whose calls are open-coded. The definition stays - it is still a
;; function, and `(map gc-marked? ps)` means what it looks like - and a macro
;; goes beside it that expands a call into the body with the arguments bound.
;;
;; This is the same bargain the prelude already makes for `car` and that a
;; record's accessors make: a call that costs more in frame protocol than it
;; does in work should not be a call. The collector is where it pays: a
;; collection was one and a half million calls to a dozen functions of two
;; instructions each, and the returns alone were a fifth of everything the
;; machine executed.
;;
;; The arguments are bound with `let`, not substituted, so each is evaluated
;; once and in the caller's scope - `(gc-marked? p)` becoming `(let ((p p)) ...)`
;; is the outer `p` on the right of the binding and the parameter on the left,
;; which is what `let` means.
;;
;; Not for anything recursive, and not for anything large: the body is copied
;; to every call site.
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
;; A place given a value for as long as a body runs, and put back after. What
;; makes it per task is where the record of it is kept: the scheduler swaps a
;; task's bindings in and out with its registers, so two tasks inside the same
;; `fluid-let` see their own values and neither has to know about the other.
;;
;; Swapping is the whole trick, and it is symmetrical. Each entry holds the
;; value that was current when the binding was made; exchanging the entry with
;; the place leaves the task's own value in the entry and the outer value in
;; the place, which is what "this task is not running" means, and exchanging
;; again puts it back. Nothing has to know which of the two states it is in.
;;
;; Two consequences worth stating. A task that never binds anything shares the
;; globals, which is right: it has not asked for anything of its own. And a
;; task that binds and then assigns keeps the assignment, because what is
;; exchanged is the current value rather than the one it started with.

;; Where the bindings live. Exec installs these once there are tasks to hang
;; them on; before that, and inside a trap where there is no task to speak of,
;; there is one stack and nothing competing for it.
(define *binds-get* nil)
(define *binds-set* nil)
(define *boot-binds* nil)

(define (task-binds) (if *binds-get* (%funcall *binds-get*) *boot-binds*))
(define (set-task-binds! v)
  (if *binds-set* (%funcall *binds-set* v) (set! *boot-binds* v)))

;; A place is a symbol, whose value cell is the obvious thing to exchange - or
;; `package`, because the current package lives in a machine slot rather than
;; in a variable, and is per task for exactly the same reasons a stream is.
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

;; Back to where the stack stood at some earlier point, putting every place
;; bound since then back the way it was. An error abandons the stack it
;; happened on, so nothing on it gets to unbind what it bound; this is how the
;; prompt it lands in is not left talking to somebody else's window.
(define (unwind-binds-to! mark)
  (while (if (%cons? (task-binds)) (if (%eq? (task-binds) mark) nil t) nil)
    (unbind-fluid!))
  nil)

(define (swap-one! e)
  (let ((p (%car e)) (v (%cdr e)))
    (%set-cdr! e (place-value p))
    (set-place-value! p v)))

;; Out: innermost first, so that a place bound twice ends up holding what it
;; held before the outermost of them.
(define (swap-binds-out! p)
  (while (%cons? p)
    (swap-one! (%car p))
    (set! p (%cdr p))))

;; And back, outermost first, which is the same walk in reverse. The recursion
;; goes as deep as the bindings are nested, which is single digits.
(define (swap-binds-in! p)
  (if (%cons? p)
      (begin (swap-binds-in! (%cdr p)) (swap-one! (%car p)))
      nil))

;; Give these places these values for the extent of the body, and put back
;; whatever was there. The binding belongs to the task that made it: the
;; scheduler swaps a task's bindings with its registers, so two tasks inside
;; the same `fluid-let` see their own values.
;;
;; Like `without-interrupts`, this does not unwind. An error inside the body
;; does not come back through here; it resets to a prompt, and `restart-stack`
;; is what puts the bindings back on that path.
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
;; A macro rather than something taking a thunk, for two reasons. A thunk that
;; captures anything is a closure, and a closure is an allocation - and the
;; collector, which is the most important caller here, may not allocate. And
;; the expansion is the same straight-line code the raw calls would have been,
;; so nothing pays for the shape.
;;
;; What it does not do is unwind. An error inside the body does not come back
;; through here; it resets to a prompt on a fresh stack, and putting interrupts
;; back is that path's job (see `restart-stack` in sys.lisp). Everything that
;; returns normally, which is everything else, restores exactly what it found.
(defmacro without-interrupts body
  (let ((saved (gensym)) (result (gensym)))
    `(let ((,saved (%disable)))
       (let ((,result (begin ,@body)))
         (%restore-interrupts ,saved)
         ,result))))
