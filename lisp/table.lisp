;;; table.lisp - hash tables keyed by identity.
;;;
;;; A symbol's identity is a small integer handed out by the one counter both
;;; the forge and the machine intern through, and any other object's is a
;;; number its header keeps; `eq-hash` in runtime.lisp says what each key
;;; hashes by. Open addressing over two parallel vectors, with linear
;;; probing: a table stores nothing but its keys and values, and the count of
;;; moves below.

(in-package lm)

(defrecord (table tbl) keys vals count dead moves)

;; Two objects nothing else can reach, so they can never be mistaken for a key
;; somebody stored.
(define *table-empty* (%cons 'empty nil))
(define *table-gone* (%cons 'gone nil))

;; ---------------------------------------------------------------- moves
;; A pair hashes by its address, having no header to keep a hash in, and so
;; does a capability that is no object. What an address names can move: the
;; compactor slides pairs down on the way into an image, and the forge
;; slides object space, and the capabilities into it, in an image on the
;; disk. Whatever moves anything counts the move here before anything can
;; look in a table again: the compactor with interrupts still off, and an
;; image as it resumes.
;;
;; A table holding a key hashed by its address keeps the count it laid its
;; keys out at; one holding none keeps nil, and no move concerns it. A probe
;; that misses in a table laid out before the last move is made again once
;; the table has been laid out afresh, and a new key goes in only where a
;; layout made since says. A probe that hits found its key by `eq?`,
;; wherever it started, and is right whatever has moved. That is the whole
;; price of a pair having no header: a table of symbols and objects is never
;; laid out again.
;;
;; Laying a table out again is a write, and a lookup can make it, so a table
;; more than one task uses needs the lock its writes need anyway.
(define *moves* 0)

(define (note-move!) (set! *moves* (%+ *moves* 1)) nil)

;; Whether something has moved since the table laid out a key hashed by its
;; address.
(defsubst (table-stale? tbl)
  (let ((m (tbl-moves tbl))) (if m (if (%eq? m *moves*) nil t) nil)))

(define (make-table . opts)
  (let* ((cap (if (%cons? opts) (%car opts) 8))
         (r (tbl-alloc)))
    (set-tbl-keys! r (make-vector-n cap *table-empty*))
    (set-tbl-vals! r (make-vector-n cap nil))
    (set-tbl-count! r 0)
    (set-tbl-dead! r 0)
    (set-tbl-moves! r nil)
    r))

(define (table-count tbl) (tbl-count tbl))
(define (table-capacity tbl) (%vector-length (tbl-keys tbl)))

;; ---------------------------------------------------------------- probing
;; Where a key lives, or -1. Stops at an empty slot and steps over deleted
;; ones.
(define (table-find-slot keys key)
  (let* ((n (%vector-length keys))
         (mask (%- n 1))
         (i (%logand (eq-hash key) mask))
         (found -1)
         (go t))
    (while go
      (let ((k (%vector-ref keys i)))
        (cond ((%eq? k *table-empty*) (set! go nil))
              ((%eq? k key) (set! found i) (set! go nil))
              (else (set! i (%logand (%+ i 1) mask))))))
    found))

;; Where a key a probe missed in a stale table lives after all, or -1: the
;; table is laid out afresh and the probe made again, until nothing moves in
;; between.
(define (table-find-again tbl key)
  (table-rebuild! tbl (table-capacity tbl))
  (let ((i (table-find-slot (tbl-keys tbl) key)))
    (if (%>= i 0) i (if (table-stale? tbl) (table-find-again tbl key) -1))))

;; Where a key lives, or where it should go. A deleted slot is reused only
;; after the whole probe has failed to find the key further along, or one key
;; could be stored twice.
(define (table-insert-slot keys key)
  (let* ((n (%vector-length keys))
         (mask (%- n 1))
         (i (%logand (eq-hash key) mask))
         (spare -1)
         (found -1)
         (go t))
    (while go
      (let ((k (%vector-ref keys i)))
        (cond ((%eq? k *table-empty*)
               (set! found (if (%>= spare 0) spare i))
               (set! go nil))
              ((%eq? k *table-gone*)
               (if (%< spare 0) (set! spare i) nil)
               (set! i (%logand (%+ i 1) mask)))
              ((%eq? k key) (set! found i) (set! go nil))
              (else (set! i (%logand (%+ i 1) mask))))))
    found))

;; ---------------------------------------------------------------- access
(define (table-ref tbl key . opts)
  (let ((i (table-find-slot (tbl-keys tbl) key)))
    (if (%< i 0) (if (table-stale? tbl) (set! i (table-find-again tbl key)) nil) nil)
    (if (%>= i 0)
        (%vector-ref (tbl-vals tbl) i)
        (if (%cons? opts) (%car opts) nil))))

(define (table-has? tbl key)
  (if (%>= (table-find-slot (tbl-keys tbl) key) 0)
      t
      (if (table-stale? tbl) (%>= (table-find-again tbl key) 0) nil)))

;; The keys laid out afresh in vectors of `cap` slots, and the deleted slots
;; do not come along. The count of moves is read first, so a move while this
;; runs leaves the table stale.
(define (table-rebuild! tbl cap)
  (let* ((moves (if (tbl-moves tbl) *moves* nil))
         (old-keys (tbl-keys tbl))
         (old-vals (tbl-vals tbl))
         (n (%vector-length old-keys))
         (keys (make-vector-n cap *table-empty*))
         (vals (make-vector-n cap nil))
         (i 0))
    (while (%< i n)
      (let ((k (%vector-ref old-keys i)))
        (if (if (%eq? k *table-empty*) nil (not (%eq? k *table-gone*)))
            (let ((j (table-insert-slot keys k)))
              (%vector-set! keys j k)
              (%vector-set! vals j (%vector-ref old-vals i)))
            nil))
      (set! i (%+ i 1)))
    (set-tbl-keys! tbl keys)
    (set-tbl-vals! tbl vals)
    (set-tbl-dead! tbl 0)
    (set-tbl-moves! tbl moves)
    tbl))

;; Twice the size.
(define (table-grow! tbl) (table-rebuild! tbl (%* (table-capacity tbl) 2)))

;; Grown at three quarters full, counting the deleted slots: they cost a probe
;; step each. The first key hashed by its address, a pair or a capability
;; that is no object, starts the table's count before the probe, and whether
;; anything has moved since is asked after it, so a new key goes in only
;; where a layout made since the last move says.
(define (table-set! tbl key val)
  (let ((used (%+ (tbl-count tbl) (tbl-dead tbl))))
    (if (%>= (%* (%+ used 1) 4) (%* (table-capacity tbl) 3))
        (table-grow! tbl)
        nil))
  (if (tbl-moves tbl)
      nil
      (if (%cap-tag? key)
          (if (%object? key) nil (if (%null? key) nil (set-tbl-moves! tbl *moves*)))
          nil))
  (let* ((keys (tbl-keys tbl))
         (i (table-insert-slot keys key))
         (k (%vector-ref keys i)))
    (cond ((%eq? k key)
           (%vector-set! (tbl-vals tbl) i val))
          ((table-stale? tbl)
           (table-rebuild! tbl (table-capacity tbl))
           (table-set! tbl key val))
          (else
           (if (%eq? k *table-gone*)
               (set-tbl-dead! tbl (%- (tbl-dead tbl) 1))
               nil)
           (%vector-set! keys i key)
           (set-tbl-count! tbl (%+ (tbl-count tbl) 1))
           (%vector-set! (tbl-vals tbl) i val)))
    val))

;; A deleted slot is marked rather than emptied: a key further along the probe
;; may have walked past it.
(define (table-del! tbl key)
  (let ((i (table-find-slot (tbl-keys tbl) key)))
    (if (%< i 0) (if (table-stale? tbl) (set! i (table-find-again tbl key)) nil) nil)
    (if (%< i 0)
        nil
        (begin
          (%vector-set! (tbl-keys tbl) i *table-gone*)
          (%vector-set! (tbl-vals tbl) i nil)
          (set-tbl-count! tbl (%- (tbl-count tbl) 1))
          (set-tbl-dead! tbl (%+ (tbl-dead tbl) 1))
          t))))

;; ---------------------------------------------------------------- walking
(define (table-for-each tbl f)
  (let* ((keys (tbl-keys tbl))
         (vals (tbl-vals tbl))
         (n (%vector-length keys))
         (i 0))
    (while (%< i n)
      (let ((k (%vector-ref keys i)))
        (if (if (%eq? k *table-empty*) nil (not (%eq? k *table-gone*)))
            (%funcall f k (%vector-ref vals i))
            nil))
      (set! i (%+ i 1)))
    nil))

(define (table-keys tbl)
  (let ((acc nil))
    (table-for-each tbl (lambda (k v) (set! acc (%cons k acc))))
    acc))

(define (table->alist tbl)
  (let ((acc nil))
    (table-for-each tbl (lambda (k v) (set! acc (%cons (%cons k v) acc))))
    acc))

(define (alist->table al)
  (let ((tbl (make-table)))
    (dolist (p al) (table-set! tbl (%car p) (%cdr p)))
    tbl))
