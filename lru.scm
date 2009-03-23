(use srfi-69)

;; FIXME: accessors must be updated to silently fail when cache capacity
;; is 0.
;; Optional: accept #t for size; in this case, act as a plain hash table.

(declare
 (fixnum)
 (usual-integrations)
 (no-bound-checks)
 (no-procedure-checks-for-usual-bindings)
 (bound-to-procedure
  ##sys#slot ##sys#setslot)
 (export
  make-lru-cache
  lru-cache-ref
  lru-cache-ref-2
  lru-cache-set!
  lru-cache-walk
  lru-cache-delete!
  lru-cache-flush!
  lru-cache-size
  )
 )

(use record-variants)

(cond-expand
 (compiling)
 (else
  (define-syntax define-inline
    (syntax-rules () ((_ args ...) (define args ...))))))

(define-record lru-cache ht head tail capacity deleter)
(define-record-variant (%lru-cache lru-cache)
  (unsafe unchecked inline)
  ht head tail capacity deleter)

(define-record node prev next key value)
(define-record-variant (%node node)
  (unsafe unchecked inline)
  prev next key value)

;; (define-record-type-variant (%lru-cache lru-cache)
;;   (unsafe unchecked inline)
;;   (make-lru-cache ht head tail capacity deleter)  ; necessary?
;;   (%lru-cache? %check-lru-cache)     
;;   (ht %lru-cache-ht)
;;   (head %lru-cache-head %lru-cache-head-set!)     
;;   (tail %lru-cache-tail %lru-cache-tail-set!)
;;   (capacity %lru-cache-capacity)
;;   (deleter %lru-cache-deleter))

(define make-lru-cache
  (let ((%make-lru-cache make-lru-cache))
    (lambda (capacity comparator #!key (on-delete #f))
      (let ((ht (make-hash-table comparator)))
        (%make-lru-cache ht #f #f capacity on-delete)))))

(define-inline (lookup c k)
  (hash-table-ref/default (lru-cache-ht c) k #f))

(define (lru-cache-ref c k)
  (and-let* ((n (lookup c k)))
    (check-%node n)
    (if (not (%node-prev n))             ; mru
        (%node-value n)
        (let ((nx (%node-next n))   ; next
              (pr (%node-prev n)))  ; prev
          (when pr
            (check-%node pr)
            (%node-next-set! pr nx)
            (%node-prev-set! n #f)
            (when (eq? n (%lru-cache-tail c))
              (%lru-cache-tail-set! c pr)))
          (when nx
            (check-%node nx)
            (%node-prev-set! nx pr))
          (let ((head (%lru-cache-head c)))
            (check-%node head)
            (%node-prev-set! head n)
            (%node-next-set! n head)
            (%lru-cache-head-set! c n)
            (%node-value n)
            )))))

(define (lru-cache-set! c k v)
  (let ((old (lookup c k)))
    (if old
        (node-value-set! old v)
        (let ((new (make-node #f (lru-cache-head c) k v)))
          (when (>= (lru-cache-size c)
                    (lru-cache-capacity c))  ; FIXME assert difference is 0
            (lru-cache-delete! c (node-key (lru-cache-tail c))))
          (unless (lru-cache-tail c)
            (lru-cache-tail-set! c new))
          (when (lru-cache-head c)
            (node-prev-set! (lru-cache-head c) new))
          (lru-cache-head-set! c new)
          (hash-table-set! (lru-cache-ht c) k new)))))

;; Missing association is not an error.
(define (lru-cache-delete! c k)
  (and-let* ((n (lookup c k)))
    (hash-table-delete! (lru-cache-ht c) k)
    (when (eq? n (lru-cache-tail c))
      (lru-cache-tail-set! c (node-prev n)))
    (when (eq? n (lru-cache-head c))
      (lru-cache-head-set! c (node-next n)))
    (let ((nx (node-next n))
          (pr (node-prev n)))
      (when pr (node-next-set! pr nx))
      (when nx (node-prev-set! nx pr)))
    (if (lru-cache-deleter c)
        ((lru-cache-deleter c) k (node-value n))
        #t)))

(define (lru-cache-size c)
  (hash-table-size (lru-cache-ht c)))

;; (define (lru-cache-fold c kons knil)
;;   (do ((n (lru-cache-head n) (node-next n)))
;;       ((not (node-next n)) )
;;       )
;;   (kons )
  
;;   (lru-cache-head c)
  

;;   )

(define (lru-cache-walk c proc)
  (do ((n (lru-cache-head c) (node-next n)))
      ((not n))
    (proc (node-key n) (node-value n))))

(define (lru-cache-flush! c)
  (lru-cache-walk c
                  (lambda (k v)
                    ((lru-cache-deleter c) k v)))
  (let ((ht (lru-cache-ht c)))
    (lru-cache-ht-set! c (make-hash-table (lru-cache-capacity c)
                                          (hash-table-equivalence-function ht)))
    (lru-cache-head-set! c #f)
    (lru-cache-tail-set! c #f)))


#|

(define (walk) (lru-cache-walk C (lambda (k v) (write (cons k v)) (newline))))
(define C (make-lru-cache 5 string=?))
(lru-cache-set! C "hi there" 'hi-there)
(eq? (lru-cache-ref C "hi there") 'hi-there)     ; #t
(eq? (node-value (lru-cache-head C)) 'hi-there)  ; #t

(lru-cache-set! C "bye there" 'bye-there)
(eq? (lru-cache-ref C "bye there") 'bye-there)   ; #t
(eq? (node-value (lru-cache-head C)) 'bye-there) ; #t
(eq? (lru-cache-ref C "hi there") 'hi-there)     ; #t 
(eq? (node-value (lru-cache-head C)) 'hi-there)  ; #t


(lru-cache-set! C "a" 1)
(lru-cache-set! C "b" 2)
(lru-cache-set! C "c" 3)
(lru-cache-ref C "hi there")
(lru-cache-walk C (lambda (k v) (write (cons k v)) (newline)))
     ;; ("hi there" . hi-there)
     ;; ("c" . 3)
     ;; ("b" . 2)
     ;; ("a" . 1)
     ;; ("bye there" . bye-there)

(lru-cache-set! C "d" 4)   ; should roll off "bye there"
(lru-cache-set! C "e" 5)   ; should roll off "a"
(lru-cache-set! C "b" 3)   ; should change value of b to 3, does not alter order


;;; stress test

(use miscmacros)
(define ss
  (list "a" "b" "c" "d" "e" "f" "g"))
(define vs (list->vector ss))

(define C2 (make-lru-cache 5 string=?))
(define (walk C) (lru-cache-walk C (lambda (k v) (write (cons k v)) (newline))))

(for-each (lambda (x)
            (lru-cache-set! C2 x (conc "*" x "*")))
          ss)
(walk C2)

(repeat 10
        (let ((s (vector-ref vs (random (vector-length vs)))))
          (lru-cache-ref C2 s)
          (print "-- chose " s)
          (walk C2)
          ))
(walk C2)


|#
