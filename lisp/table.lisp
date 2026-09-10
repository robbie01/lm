;;; table.lisp - hash tables, keyed by identity.
;;;
;;; A symbol's identity is a small dense integer, handed out by the one
;;; counter that both the forge and the running machine intern through. That
;;; makes it a perfect hash for the case that matters: no collisions at all,
;;; nothing to recompute, and nothing a collector could invalidate by moving
;;; something.
;;;
;;; Open addressing rather than buckets of pairs, because the whole point of a
;;; table is to be cheaper than the list it replaces, and a chain costs two
;;; conses an entry before it has stored anything. Two parallel vectors and
;;; linear probing store nothing but the keys and the values.

(in-package lm)

(defrecord (table tbl) keys vals count dead)

;; Two objects nothing else can reach, so they can never be mistaken for a key
;; that somebody actually stored.
(define *table-empty* (%cons 'empty nil))
(define *table-gone* (%cons 'gone nil))

(define (eq-hash k)
  ;; Symbols hash by identity. Fixnums and characters hash by value. Anything
  ;; else hashes by address, which is stable only because objects in this
  ;; system never move - see the collector, which compacts pairs and leaves
  ;; objects where they are. If that ever changes, this is the line that has
  ;; to change with it, and every table will need rehashing after a collection.
  (cond ((%symbol? k) (symbol-index k))
        ((%fixnum? k) k)
        ((%char? k) (%char->int k))
        ((%null? k) 0)
        (else (%lsh (%addr-of k) -3))))

(define (make-table . opts)
  (let* ((cap (if (%cons? opts) (%car opts) 8))
         (r (tbl-make)))
    (set-tbl-keys! r (make-vector-n cap *table-empty*))
    (set-tbl-vals! r (make-vector-n cap nil))
    (set-tbl-count! r 0)
    (set-tbl-dead! r 0)
    r))

(define (table-count tbl) (tbl-count tbl))
(define (table-capacity tbl) (%vector-length (tbl-keys tbl)))

;; ---------------------------------------------------------------- probing
;; Where a key lives, or -1. Stops at an empty slot and steps over the ones
;; something used to be in.
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

;; Where a key lives, or where it should go. A slot something was deleted from
;; is reused, but only after the whole probe has failed to find the key
;; further along - otherwise one key could end up stored twice.
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

(define (table-grow! tbl)
  ;; Twice the size, and the deleted slots do not come with it.
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

(define (table-set! tbl key val)
  ;; Grown at three quarters full, counting the deleted slots: they cost a
  ;; probe step each, so a table full of holes is as slow as a table full of
  ;; keys and has to be rebuilt just the same.
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

(define (table-del! tbl key)
  ;; A hole rather than an empty slot: something further along the probe may
  ;; have walked past here to get where it is.
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
