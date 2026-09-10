;;; read.lisp - the reader.
;;;
;;; There is one of these. The forge used to carry a second reader written in
;;; Rust that had to agree with this one about what a name means - the same
;;; hash, the same package rules, the same treatment of pkg:name - and every
;;; change to either had to be made twice. Now the bootstrap brings this one
;;; up on a minimal interpreter and reads everything, itself included, with
;;; it; what is left in Rust is a reader that knows only how to make a list.
;;;
;;; Characters come from the current stream, so the same code reads the serial
;;; console, a window, and a source file the forge hands over as a string.

(in-package lm)

(define *peeked* nil)

(define (read-char-or-nil)
  (if *peeked*
      (let ((c *peeked*)) (set! *peeked* nil) c)
      (get-char)))

;; Reading from a console never ends: when there is nothing there yet, wait.
;; Reading from a string does end, and then a character that is not coming has
;; to be admitted to rather than waited for.
(define *eof-ok* nil)

(define (wait-char)
  (let ((c nil) (go t))
    (while (if go (%null? c) nil)
      (set! c (read-char-or-nil))
      (if (%null? c)
          (if *eof-ok* (set! go nil) (await-char))
          nil))
    c))

(define (peek-char)
  (if *peeked* *peeked* (begin (set! *peeked* (wait-char)) *peeked*)))

(define (delimiter? c)
  ;; End of input ends a token as surely as a space does. On a console that
  ;; never happens; on a string it happens at the last character, and a reader
  ;; that did not know it would keep asking for a character that is not coming.
  (if (%null? c)
      t
      (if (char-whitespace? c)
          t
          (if (%eq? c #\() t
              (if (%eq? c #\)) t
                  (if (%eq? c #\") t (%eq? c #\;)))))))

(define (skip-space)
  (let ((go t))
    (while go
      (let ((c (peek-char)))
        (cond
         ((%null? c) (set! go nil))
         ((char-whitespace? c) (wait-char))
         ((%eq? c #\;)
          (let ((d (wait-char)) (going t))
            (while going
              (cond ((%null? d) (set! going nil))
                    ((%eq? d #\newline) (set! going nil))
                    (else (set! d (wait-char)))))))
         (else (set! go nil)))))))

(define (read-form)
  (skip-space)
  (let ((c (peek-char)))
    (cond
     ((%eq? c #\() (wait-char) (read-list))
     ((%eq? c #\)) (wait-char) (error "unexpected )"))
     ((%eq? c #\') (wait-char) (list 'quote (read-form)))
     ((%eq? c #\`) (wait-char) (list 'quasiquote (read-form)))
     ((%eq? c #\,)
      (wait-char)
      (if (%eq? (peek-char) #\@)
          (begin (wait-char) (list 'unquote-splicing (read-form)))
          (list 'unquote (read-form))))
     ((%eq? c #\") (wait-char) (read-string-literal))
     ((%eq? c #\#) (wait-char) (read-hash))
     (else (read-atom)))))

(define (read-list)
  (let ((acc nil) (go t) (tail nil) (outer-raw *read-raw*))
    (set! *read-depth* (%+ *read-depth* 1))
    (while go
      (skip-space)
      (let ((c (peek-char)))
        (cond
         ((%null? c) (error "unterminated list"))
         ((%eq? c #\)) (wait-char) (set! go nil))
         ((if (%eq? c #\.) (dot-follows?) nil)
          (wait-char)
          (set! tail (read-form))
          (skip-space)
          (wait-char)
          (set! go nil))
         (else
          (let ((v (read-form)))
            ;; The head of an outermost form decides how the rest is read.
            (if (if (%null? acc) (%= *read-depth* 1) nil)
                (if (%symbol? v)
                    (if (if (string=? (%symbol-name v) "defpackage") t
                            (string=? (%symbol-name v) "in-package"))
                        (set! *read-raw* t)
                        nil)
                    nil)
                nil)
            (set! acc (%cons v acc)))))))
    (set! *read-raw* outer-raw)
    (set! *read-depth* (%- *read-depth* 1))
    (revappend acc tail)))

(define (dot-follows?)
  ;; A lone dot is the dotted-pair marker; a dot that starts a token is part
  ;; of a symbol.
  (wait-char)
  (let ((c (peek-char)))
    (if (delimiter? c)
        t
        (begin (set! *peeked* #\.) nil))))

(define (read-string-literal)
  (let ((acc nil) (go t))
    (while go
      (let ((c (wait-char)))
        (cond
         ((%null? c) (error "unterminated string"))
         ((%eq? c #\") (set! go nil))
         ((%eq? c #\\)
          (let ((e (wait-char)))
            (set! acc (%cons (cond ((%eq? e #\n) #\newline)
                                   ((%eq? e #\t) #\tab)
                                   ((%eq? e #\r) (%int->char 13))
                                   (else e))
                             acc))))
         (else (set! acc (%cons c acc))))))
    (list->string (reverse acc))))

(define (read-hash)
  (let ((c (wait-char)))
    (cond
     ((%eq? c #\() (list->vector (read-list)))
     ((%eq? c #\\) (read-char-literal))
     ((%eq? c #\t) t)
     ((%eq? c #\f) nil)
     ((%eq? c #\x) (string->number-radix (read-token) 16))
     ((%eq? c #\b) (string->number-radix (read-token) 2))
     (else (error "unknown # syntax")))))

(define (read-char-literal)
  (let ((first (wait-char)))
    (if (char-alphabetic? first)
        (let ((name (string-append (string first) (read-token))))
          (cond ((%= 1 (%string-length name)) first)
                ((string=? name "space") #\space)
                ((string=? name "newline") #\newline)
                ((string=? name "tab") #\tab)
                ((string=? name "return") (%int->char 13))
                ((string=? name "backspace") (%int->char 8))
                (else (error "unknown character name" name))))
        first)))

(define (read-token)
  (let ((acc nil) (go t))
    (while go
      (let ((c (peek-char)))
        (if (delimiter? c)
            (set! go nil)
            (set! acc (%cons (wait-char) acc)))))
    (list->string (reverse acc))))

;; Inside a defpackage or in-package form the names are the names of packages
;; that may not exist yet, so they are read as names and not as symbols -
;; interning them would put them in whatever package happens to be current,
;; which is exactly the wrong one. Only the outermost form counts: a define of
;; defpackage is a definition of it, not a use.
(define *read-raw* nil)
(define *read-depth* 0)

(define (token->symbol tok)
  ;; pkg:name is the exported symbol of that name in that package; pkg::name
  ;; is any symbol of that name, interning one if there is none.
  (let ((i (string-index tok #\:)))
    (if (if i (%> i 0) nil)
        (let* ((internal (if (%< (%+ i 1) (%string-length tok))
                             (%eq? (%string-ref tok (%+ i 1)) #\:)
                             nil))
               (pname (substring tok 0 i))
               (name (substring tok (%+ i (if internal 2 1)) (%string-length tok)))
               (pkg (find-package pname)))
          (if (%null? pkg) (error "no package named" pname) nil)
          (let ((sym (find-symbol-in pkg name)))
            (cond ((if sym (if internal t (symbol-exported? sym)) nil) sym)
                  (internal (intern-in pkg name))
                  (else (error "not exported" tok)))))
        (intern-visible (current-package) tok))))

(define (read-atom)
  (let ((tok (read-token)))
    (if (%= 0 (%string-length tok))
        (begin (wait-char) nil)
        (if *read-raw*
            tok
            (let ((n (string->number tok)))
              (cond (n n)
                    ((string=? tok "nil") nil)
                    (else (token->symbol tok))))))))

(define (string->number-radix s radix)
  (let ((i 0) (n (%string-length s)) (acc 0) (neg nil))
    (if (%> n 0)
        (if (%eq? (%string-ref s 0) #\-) (begin (set! neg t) (set! i 1)) nil)
        nil)
    (while (%< i n)
      (let* ((c (%char->int (%string-ref s i)))
             (d (cond ((if (%>= c 48) (%<= c 57) nil) (%- c 48))
                      ((if (%>= c 97) (%<= c 102) nil) (%- c 87))
                      ((if (%>= c 65) (%<= c 70) nil) (%- c 55))
                      (else 99))))
        (if (%>= d radix) (error "bad digit in" s) nil)
        (set! acc (%+ (%* acc radix) d))
        (set! i (%+ i 1))))
    (if neg (%- 0 acc) acc)))

;; ---------------------------------------------------------------- strings
;; Reading a source file is reading a stream that happens to be a string. The
;; forge hands whole files over this way, which is how the machine's reader
;; came to be the only reader there is.
(define (string-stream s)
  (let ((i 0) (n (%string-length s)))
    (make-stream
     (lambda (c) nil)
     (lambda ()
       (if (%< i n)
           (let ((c (%string-ref s i))) (set! i (%+ i 1)) c)
           nil))
     (lambda () nil))))

(define (with-input-from-string s thunk)
  ;; Three places given other values for as long as the thunk runs, which is
  ;; what a fluid binding is for. This used to save and restore them by hand.
  (let ((in (string-stream s)))
    (fluid-let ((*out* (stream-put in))
                (*in* (stream-get in))
                (*await* (stream-await in))
                (*peeked* nil)
                (*eof-ok* t))
      (%funcall thunk))))

;; A file says which package it is in, and everything after that line has to be
;; read in it - so the reader has to act on these two as it goes rather than
;; wait for somebody to evaluate them. Reading a whole file and evaluating it
;; afterwards, which is what the forge does, would otherwise read the whole
;; thing in whatever package the previous file left behind.
;;
;; They are matched by name, because the symbol they are spelled with is
;; whatever the package being left behind happened to have.
;; The real package forms. They are macros so that their arguments are names
;; rather than expressions, whichever reader read them - the bootstrap reader
;; hands over symbols and this one hands over strings, and a macro can quote
;; either without evaluating it. They live here, with the reader, because they
;; are read-time business and because this is the first file that runs after
;; the forge has something to allocate a package with.
(defmacro in-package (name) (list 'set-package-by-name (list 'quote name)))
(defmacro defpackage words (list 'define-package-by-name (list 'quote words)))

(define (form-head-named? f name)
  (if (%cons? f)
      (if (%symbol? (%car f)) (string=? (%symbol-name (%car f)) name) nil)
      nil))

(define (act-on-package-form f)
  (cond ((form-head-named? f "in-package") (set-package-by-name (cadr f)))
        ((form-head-named? f "defpackage") (define-package-by-name (%cdr f)))
        (else nil)))

;; Reading a form at a time, so that what a form does can affect how the next
;; one is read. That is not a nicety: an export list has to be read in the
;; package it exports from, and the form that says so is the one before it.
(define *reader-eof* (%cons 'eof nil))
(define *reader-saved* nil)

(define (start-reading-string s)
  (set! *reader-saved*
        (%cons (current-stream) (%cons *peeked* (%cons *eof-ok* *reader-saved*))))
  (use-stream! (string-stream s))
  (set! *peeked* nil)
  (set! *eof-ok* t)
  nil)

(define (stop-reading)
  (use-stream! (%car *reader-saved*))
  (set! *peeked* (cadr *reader-saved*))
  (set! *eof-ok* (caddr *reader-saved*))
  (set! *reader-saved* (cdddr *reader-saved*))
  nil)

(define (read-next)
  (skip-space)
  (if (%null? (peek-char))
      *reader-eof*
      (let ((f (read-form))) (act-on-package-form f) f)))

(define (read-forms-from-string s)
  ;; Every form in the text, in order. Reading stops at the end rather than
  ;; waiting for more, which is the only difference between a file and a
  ;; console.
  (start-reading-string s)
  (let ((acc nil) (go t))
    (while go
      (let ((f (read-next)))
        (if (%eq? f *reader-eof*) (set! go nil) (set! acc (%cons f acc)))))
    (stop-reading)
    (reverse acc)))

(define (read-from-string s)
  (with-input-from-string s (lambda () (read-form))))
