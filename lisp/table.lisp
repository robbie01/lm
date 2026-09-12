;;; table.lisp - hash tables keyed by identity.
;;;
;;; A symbol's identity is a small dense integer handed out by the one counter
;;; both the forge and the machine intern through, which makes it a perfect
;;; hash. Open addressing over two parallel vectors, with linear probing: a
;;; table stores nothing but its keys and values.

(in-package lm)

(defrecord (table tbl) keys vals count dead)

;; Two objects nothing else can reach, so they can never be mistaken for a key
;; somebody stored.
(define *table-empty* (%cons 'empty nil))
(define *table-gone* (%cons 'gone nil))

;; Symbols hash by identity, fixnums and characters by value, and anything
;; else by address. Objects never move, so an address is stable; if that ever
;; changes, every table has to be rehashed after a collection.
(define (eq-hash k)
  (cond ((%symbol? k) (symbol-index k))
        ((%fixnum? k) k)
        ((%char? k) (%char->int k))
        ((%null? k) 0)
        (else (%lsh (%addr-of k) -3))))

(define (make-table . opts)
  (let* ((cap (if (%cons? opts) (%car opts) 8))
         (r (tbl-alloc)))
    (set-tbl-keys! r (make-vector-n cap *table-empty*))
    (set-tbl-vals! r (make-vector-n cap nil))
    (set-tbl-count! r 0)
    (set-tbl-dead! r 0)
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
    (if (%>= i 0)
        (%vector-ref (tbl-vals tbl) i)
        (if (%cons? opts) (%car opts) nil))))

(define (table-has? tbl key)
  (%>= (table-find-slot (tbl-keys tbl) key) 0))

;; Twice the size, and the deleted slots do not come along.
(define (table-grow! tbl)
  (let* ((old-keys (tbl-keys tbl))
         (old-vals (tbl-vals tbl))
         (n (%vector-length old-keys))
         (cap (%* n 2))
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
    tbl))

;; Grown at three quarters full, counting the deleted slots: they cost a probe
;; step each.
(define (table-set! tbl key val)
  (let ((used (%+ (tbl-count tbl) (tbl-dead tbl))))
    (if (%>= (%* (%+ used 1) 4) (%* (table-capacity tbl) 3))
        (table-grow! tbl)
        nil))
  (let* ((keys (tbl-keys tbl))
         (i (table-insert-slot keys key))
         (k (%vector-ref keys i)))
    (if (%eq? k key)
        nil
        (begin
          (if (%eq? k *table-gone*)
              (set-tbl-dead! tbl (%- (tbl-dead tbl) 1))
              nil)
          (%vector-set! keys i key)
          (set-tbl-count! tbl (%+ (tbl-count tbl) 1))))
    (%vector-set! (tbl-vals tbl) i val)
    val))

;; A deleted slot is marked rather than emptied: a key further along the probe
;; may have walked past it.
(define (table-del! tbl key)
  (let ((i (table-find-slot (tbl-keys tbl) key)))
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
