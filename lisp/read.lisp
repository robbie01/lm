;;; read.lisp - the reader.
;;;
;;; The one reader: the forge brings it up on the bootstrap interpreter and
;;; reads everything with it from then on, itself included, so a name means
;;; the same thing at build time and at run time. Characters come from the
;;; current stream, so the same code reads the serial console, a window, and
;;; a source file the forge hands over as a string.

(in-package lm)

(define *peeked* nil)

;; `*peeked*` holds one character looked at and not taken, or a list of
;; them: `skip-space` has to look past a `#` to see whether a comment follows,
;; and puts both back when one does not.
(define (read-char-or-nil)
  (cond ((%null? *peeked*) (get-char))
        ((%cons? *peeked*)
         (let ((c (%car *peeked*))) (set! *peeked* (%cdr *peeked*)) c))
        (else (let ((c *peeked*)) (set! *peeked* nil) c))))

;; Reading from a console never ends: when nothing is there yet, wait. Reading
;; from a string does end, and then a character that is not coming is nil.
(define *eof-ok* nil)

(define (wait-char)
  (let ((c nil) (go t))
    (while (if go (%null? c) nil)
      (set! c (read-char-or-nil))
      (if (%null? c)
          (if *eof-ok* (set! go nil) (await-char))
          nil))
    c))

;; The next character, left where it is. The stream usually has one ready, and
;; then this asks once rather than going through `wait-char`.
(define (peek-char)
  (cond ((%cons? *peeked*) (%car *peeked*))
        (*peeked* *peeked*)
        (else
         (let ((c (get-char)))
           (set! *peeked* (if c c (wait-char)))
           *peeked*))))

;; End of input ends a token as a space does. Whitespace is never above the
;; space character, so a letter is settled by one comparison.
(define (delimiter? c)
  (if (%null? c)
      t
      (if (%> (%char->int c) 32)
          (if (%eq? c #\() t
              (if (%eq? c #\)) t
                  (if (%eq? c #\") t (%eq? c #\;))))
          (char-whitespace? c))))

(define (skip-space)
  (let ((go t))
    (while go
      (let ((c (peek-char)))
        (cond
         ((%null? c) (set! go nil))
         ;; A peeked character is taken by forgetting it.
         ((if (%eq? c #\space) t (char-whitespace? c)) (set! *peeked* nil))
         ((%eq? c #\;)
          (set! *peeked* nil)
          (let ((going t))
            (while going
              (let ((d (get-char)))
                (if (%null? d) (set! d (wait-char)) nil)
                (if (%null? d)
                    (set! going nil)
                    (if (%eq? d #\newline) (set! going nil) nil))))))
         ;; `#|` opens a block comment, which nests, and `#;` comments out
         ;; the datum after it. Any other `#` starts a datum and goes back.
         ((%eq? c #\#)
          (read-char-or-nil)
          (let ((d (peek-char)))
            (cond ((%eq? d #\|) (read-char-or-nil) (skip-block-comment))
                  ((%eq? d #\;) (read-char-or-nil) (read-form))
                  (else (set! *peeked* (%cons #\# (%cons d nil)))
                        (set! go nil)))))
         (else (set! go nil)))))))

;; After `#|`: to the matching `|#`, counting the ones opened inside.
(define (skip-block-comment)
  (let ((depth 1))
    (while (%> depth 0)
      (let ((d (wait-char)))
        (cond ((%null? d) (error "end of input inside #| |#"))
              ((if (%eq? d #\|) (%eq? (peek-char) #\#) nil)
               (read-char-or-nil)
               (set! depth (%- depth 1)))
              ((if (%eq? d #\#) (%eq? (peek-char) #\|) nil)
               (read-char-or-nil)
               (set! depth (%+ depth 1)))
              (else nil))))))

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

;; A form at top level. The two pieces of state below describe the form being
;; read, and an error inside a form leaves them where the error found them;
;; starting a new one puts them back.
(define (read-toplevel)
  (set! *read-raw* nil)
  (set! *read-depth* 0)
  (read-form))

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

;; A lone dot is the dotted-pair marker; a dot that starts a token is part of
;; a symbol.
(define (dot-follows?)
  (wait-char)
  (let ((c (peek-char)))
    (if (delimiter? c)
        t
        (begin (set! *peeked* #\.) nil))))

(define (read-string-literal)
  (let ((acc nil) (n 0) (go t))
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
                             acc))
            (set! n (%+ n 1))))
         (else (set! acc (%cons c acc)) (set! n (%+ n 1))))))
    (reversed->string acc n)))

;; n characters collected last first, as a string, filled from the end.
(define (reversed->string acc n)
  (let ((s (make-string-n n)))
    (while (%cons? acc)
      (set! n (%- n 1))
      (%string-set! s n (%car acc))
      (set! acc (%cdr acc)))
    s))

(define (read-hash)
  (let ((c (wait-char)))
    (cond
     ((%eq? c #\() (list->vector (read-list)))
     ((%eq? c #\\) (read-char-literal))
     ((%eq? c #\t) t)
     ((%eq? c #\f) nil)
     ((%eq? c #\x) (string->number-radix (read-token) 16))
     ((%eq? c #\o) (string->number-radix (read-token) 8))
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
  (let ((acc nil) (n 0) (go t))
    (while go
      (let ((c (peek-char)))
        (if (delimiter? c)
            (set! go nil)
            (begin
              (set! *peeked* nil)
              (set! acc (%cons c acc))
              (set! n (%+ n 1))))))
    (reversed->string acc n)))

;; Inside a defpackage or in-package form the names are the names of packages
;; that may not exist yet, so they are read as strings and not interned into
;; whatever package happens to be current. Only the outermost form counts: a
;; define of defpackage is a definition of it, not a use.
(define *read-raw* nil)
(define *read-depth* 0)

;; pkg:name is the exported symbol of that name in that package; pkg::name is
;; any symbol of that name there, interned if there is none.
(define (token->symbol tok)
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

;; Promoting, like `string->number`: a literal wider than a fixnum reads as a
;; bignum in every radix.
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
        (set! acc (+ (* acc radix) d))
        (set! i (%+ i 1))))
    (if neg (- 0 acc) acc)))

;; ---------------------------------------------------------------- strings
;; A source file is a stream that happens to be a string.
(define (string-stream s)
  (let ((i 0) (n (%string-length s)))
    (make-stream
     (lambda (c) nil)
     ;; No `let`: in the forge's interpreter a let is a frame, and this runs
     ;; once per character of every file the forge reads.
     (lambda ()
       (if (%< i n)
           (begin (set! i (%+ i 1)) (%string-ref s (%- i 1)))
           nil))
     (lambda () nil))))

(define (with-input-from-string s thunk)
  (let ((in (string-stream s)))
    (fluid-let ((*out* (stream-put in))
                (*in* (stream-get in))
                (*await* (stream-await in))
                (*peeked* nil)
                (*eof-ok* t))
      (%funcall thunk))))

;; The real package forms. Macros, so that their arguments are names rather
;; than expressions whichever reader read them: the bootstrap reader hands
;; over symbols and this one strings. The reader acts on them as it goes,
;; because everything after one in a file is read in the package it names.
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

;; A form at a time, so that what a form does can affect how the next one is
;; read: an export list has to be read in the package it exports from.
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
      (let ((f (read-toplevel))) (act-on-package-form f) f)))

;; Every form in the text, in order.
(define (read-forms-from-string s)
  (start-reading-string s)
  (let ((acc nil) (go t))
    (while go
      (let ((f (read-next)))
        (if (%eq? f *reader-eof*) (set! go nil) (set! acc (%cons f acc)))))
    (stop-reading)
    (reverse acc)))

(define (read-from-string s)
  (with-input-from-string s (lambda () (read-toplevel))))
