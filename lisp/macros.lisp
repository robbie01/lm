;;; macros.lisp - the rest of the language.
;;;
;;; The interpreter and the compiler between them know only nine special
;;; forms. Everything a program actually writes with lives here, as macros, so
;;; there is exactly one definition of what `cond` means and no way for the two
;;; evaluators to disagree.
;;;
;;; quasiquote has to be built without quasiquote, which is why the expander
;;; below spells out every list it constructs.

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
          ((memq head '(peek32 %ld32)) `(%st32! ,(car args) ,val))
          ((memq head '(peek8 %ld8)) `(%st8! ,(car args) ,val))
          ((memq head '(peek16 %ld16)) `(%st16! ,(car args) ,val))
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
