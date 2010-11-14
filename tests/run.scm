(use test)
(use sql-de-lite)
(use files) ; create-temporary-file
(use posix) ; delete-file

;; Concatenate string literals into a single literal at compile time.
;; (string-literal "a" "b" "c") -> "abc"
(define-syntax string-literal
  (lambda (f r c)
    (apply string-append (cdr f))))

#|

(begin
  (define stmt (prepare db "create table cache(key text primary key, val text);"))
  (step stmt)
  (step (prepare db "insert into cache values('ostrich', 'bird');"))
  (step (prepare db "insert into cache values('orangutan', 'monkey');"))
)

(use sqlite3-simple)
(raise-database-errors #t)
(define db (open-database "a.db"))
(define stmt2 (prepare db "select rowid, key, val from cache;"))
(step stmt2)
(column-count stmt2)  ; => 3
(column-type stmt2 0) ; => integer
(column-type stmt2 1) ; => text
(column-type stmt2 2) ; => text
(column-data stmt2 0) ; => 1
(column-data stmt2 1) ; => "ostrich"
(column-data stmt2 2) ; => "orangutan"
(row-data stmt2)
(row-alist stmt2)
(define stmt3 (prepare db "select rowid, key, val from cache where key = ?;"))
(fetch (bind (reset stmt3) 1 "orangutan"))
(fetch (bind (reset stmt3) 1 (string->blob "orangutan"))) ; fails.  dunno why
(step (bind (prepare db "insert into cache values(?, 'z');")
            1 (string->blob "orange2")))
(blob->string (alist-ref 'key (fetch-alist (bind (reset stmt3) 1 (string->blob "orange2"))))) ; -> "orange2"
(fetch stmt3)
(define stmt4 (prepare db "select rowid, key, val from cache where rowid = ?;"))
(fetch (bind (reset stmt4) 1 2))

(call-with-database "a.db" (lambda (db) (fetch (prepare db "select * from cache;"))))
  ; -> ("ostrich" "bird")  + finalization warning

(call-with-database "a.db" (lambda (db) (call-with-prepared-statements db (list "select * from cache;" "select rowid, key, value from cache;") (lambda (s1 s2) (and s1 s2 (list (fetch s1) (fetch s2)))))))   ; #f (or error) -- invalid column name
(call-with-database "a.db" (lambda (db) (call-with-prepared-statements db (list "select * from cache;" "select rowid, key, val from cache;") (lambda (s1 s2) (and s1 s2 (list (fetch s1) (fetch s2)))))))     ; (("ostrich" "bird") (1 "ostrich" "bird"))


(call-with-database ":memory:" (lambda (db) (with-transaction db (lambda () (fetch (execute-sql db "select 1 union select 2")) (error 'oops))))) ; => same as above but error is thrown
(call-with-database ":memory:" (lambda (db) (with-transaction db (lambda () (call-with-prepared-statement db "select 1 union select 2" (lambda (s) (fetch (execute s)) (error 'oops))) #f))))   ; => error, same as previous
(call-with-database ":memory:" (lambda (db) (with-transaction db (lambda () (call-with-prepared-statement db "select 1 union select 2" (lambda (s) (fetch (execute s)))) #f))))   ; => #f, statement finalized by call-with-prepared-statement

|#

(raise-database-errors #t)

(test-group
 "autocommit"
 (test "autocommit? reports #t outside transaction" #t
       (call-with-database ":memory:"
         (lambda (db)
           (autocommit? db))))
 (test "autocommit? reports #f during transaction" #f
       (call-with-database ":memory:"
         (lambda (db)
           (with-transaction db
             (lambda ()
               (autocommit? db)))))))

(test-group
 "rollback"
 (test-error "Open read queries prevent SQL ROLLBACK" ; will throw SQLITE_BUSY
             (call-with-database ":memory:"
               (lambda (db)
                 (exec (sql db "begin;"))
                 (or (equal? '(1)
                             (fetch (prepare db "select 1 union select 2")))
                     (error 'fetch "fetch failed during test"))
                 (exec (sql db "rollback;")))))
 (test "Open read queries ok with SQL COMMIT"
       #t
       (call-with-database ":memory:"
         (lambda (db)
           (exec (sql db "begin;"))
           (or (equal? '(1)
                       (fetch (prepare db "select 1 union select 2")))
               (error 'fetch "fetch failed during test"))
           (exec (sql db "commit;"))
           #t)))
 (test "(rollback) resets open cached queries"
       0
       ;; We assume reset worked if no error; should we explicitly test it?
       (call-with-database ":memory:"
         (lambda (db)
           (exec (sql db "begin;"))
           (or (equal? '(1)
                       (fetch (prepare db "select 1 union select 2")))
               (error 'fetch "fetch failed during test"))
           (rollback db))))
 (test "(rollback) resets open transient queries (and warns)"
       0
       (call-with-database ":memory:"
         (lambda (db)
           (exec (sql db "begin;"))
           (or (equal? '(1)
                       (fetch (prepare-transient db
                                                 "select 1 union select 2")))
               (error 'fetch "fetch failed during test"))
           (rollback db))))
 (test "with-transaction rollback resets open queries"
       #f
       ;; We assume reset worked if no error; should we explicitly test it?
       (call-with-database ":memory:"
         (lambda (db)
           (with-transaction db
             (lambda ()
               (or (equal? '(1)
                           (fetch (prepare db "select 1 union select 2")))
                   (error 'fetch "fetch failed during test"))
               #f ; rollback
               ))))))

(test-group
 "reset"
 (test "query resets statement immediately (normal exit)"
       '((1) (1))
       (call-with-database ":memory:"
         (lambda (db)
           (let ((s (sql db "select 1 union select 2;")))
             (list (query fetch s)
                   (fetch s))))))
 (test "query resets statement immediately (error exit)"
       '((oops) (1))
       (call-with-database ":memory:"
         (lambda (db)
           (let ((s (sql db "select 1 union select 2;")))
             (list (handle-exceptions exn '(oops)
                     (query (lambda (s) (fetch s) (error 'oops))
                            s))
                   (fetch s))))))
 (test "exec resets query immediately"
       '((1) (1))
       (call-with-database ":memory:"
         (lambda (db)
           (let ((s (sql db "select 1 union select 2;")))
             (list (exec s)
                   (fetch s))))))
 (test "exec resets even when column count = 0 (requires >= 3.7.0)"
             ;; Fails with status/misuse in < 3.7.0.  In >= 3.7.0,
             ;; statements are automatically reset by the library,
             ;; even though we do not reset it.
       '(1 ())
             (call-with-database ":memory:"
               (lambda (db)
                 (exec (sql db "create table a(k,v);"))
                 (let ((s (sql db "insert or ignore into a values(1,2);")))
                   (list (exec s)
                         (fetch s))))))
 )

(test-group
 "fetch"

(test "fetch first row via fetch"
      '(1 2)
      (call-with-database ":memory:"
        (lambda (db)
          (let ((s (prepare db "select 1, 2 union select 3, 4;")))
            (fetch s)))))

(test "fetch first row via exec"
      '(1 2)
      (call-with-database ":memory:"
        (lambda (db)
          (let ((s (sql db "select 1, 2 union select 3, 4;")))
            (exec s)))))

(test "fetch first row via (query fetch ...)"
      '(1 2)
      (call-with-database ":memory:"
        (lambda (db)
          (let ((s (sql db "select 1, 2 union select 3, 4;")))
            (query fetch s)))))

(test "fetch all rows twice via fetch-all + reset + fetch-all"
      '(((1 2) (3 4) (5 6)) reset ((1 2) (3 4) (5 6)))
      (call-with-database ":memory:"
        (lambda (db)
          (let ((s (prepare db (string-literal "select 1, 2 union "
                                               "select 3, 4 union "
                                               "select 5, 6;"))))
            (list (fetch-all s)
                  (begin (reset s) 'reset)
                  (fetch-all s))))))

(test "fetch all rows twice via fetch-all + fetch-all (requires >= 3.7.0)"
      '(((1 2) (3 4) (5 6)) library-reset ((1 2) (3 4) (5 6)))
      (call-with-database ":memory:"
        (lambda (db)
          (let ((s (prepare db (string-literal "select 1, 2 union "
                                               "select 3, 4 union "
                                               "select 5, 6;"))))
            (list (fetch-all s)
                  'library-reset
                  (fetch-all s))))))

(test "fetch all rows twice via (query fetch-all ...) x 2"
      '(((1 2) (3 4) (5 6)) ((1 2) (3 4) (5 6)))
      (call-with-database ":memory:"
        (lambda (db)
          (let ((s (prepare db (string-literal "select 1, 2 union "
                                               "select 3, 4 union "
                                               "select 5, 6;"))))
            (list (query fetch-all s)
                  ; reset not required
                  (query fetch-all s))))))

(test "fetch-all reads remaining rows mid-query"
      '((1 2) fetch ((3 4) (5 6)))
      (call-with-database ":memory:"
        (lambda (db)
          (let ((s (prepare db (string-literal "select 1, 2 union "
                                               "select 3, 4 union "
                                               "select 5, 6;"))))
            (list (fetch s)
                  'fetch
                  (fetch-all s))))))
)

;; No way to really test this other than inspecting warnings
;; (test "Pending cached queries are finalized when DB is closed"
;;       '((1) (3))
;;       (let* ((db (open-database ":memory:"))
;;              (s1 (prepare db "select 1 union select 2"))
;;              (s2 (prepare db "select 3 union select 4")))
;;         (let ((rv (list (fetch s1) (fetch s2))))
;;           (close-database db) ; finalize here
;;           rv)))

;; let-prepare finalization will error when database is closed
;; Should actually succeed, as ideally statements will be set to #f
;; upon database close.
(test "Finalizing previously finalized statement OK even after DB is closed"
      '((1) (3))
      (let ((db (open-database ":memory:")))
        (let ((s1 (prepare-transient db "select 1 union select 2"))
              (s2 (prepare-transient db "select 3 union select 4")))
          (let ((rv (list (fetch s1)
                          (fetch s2))))
            (close-database db)
            (finalize s1)
            (finalize s2)
            rv))))

(test "Transient statements are finalized but not FINALIZED? in call/db"
      ;; They are finalized (you may receive a warning), but don't show
      ;; up as FINALIZED?.  Currently, we do not confirm finalization
      ;; other than through manually inspecting the warning.
      #f
      (let ((s1 #f) (s2 #f))
        (handle-exceptions ex
            (and (finalized? s1) (finalized? s2))
          (call-with-database ":memory:"
            (lambda (db)
              (set! s1 (prepare-transient db "select 1 union select 2"))
              (set! s2 (prepare-transient db "select 3 union select 4"))
              (step s1)
              (error 'oops))))))
(test "Cached statements are finalized on error in call-with-database"
      #t
      (let ((s1 #f) (s2 #f))
        (handle-exceptions ex
            (and (finalized? s1) (finalized? s2))
          (call-with-database ":memory:"
            (lambda (db)
              (set! s1 (prepare db "select 1 union select 2"))
              (set! s2 (prepare db "select 3 union select 4"))
              (step s1)
              (error 'oops))))))

(test "Reset cached statement may be pulled from cache"
      #t   ; Cannot currently dig into statement to test it; just ensure no error
      (call-with-database 'memory
        (lambda (db)
          (let* ((sql "select 1;")
                 (s1 (prepare db sql))
                 (s2 (prepare db sql)))
            #t))))

(test "create / insert one row via execute-sql"
      1
      (call-with-database ":memory:"
        (lambda (db)
          (exec (sql db "create table cache(k,v);"))
          (exec (sql db "insert into cache values('jml', 'oak');")))))

(test-group
 "finalization"
 (test ;; operation on finalized statement
  "exec after finalize succeeds (statement resurrected)"
  1
  (call-with-database ":memory:"
    (lambda (db)
      (exec (sql db "create table cache(k,v);"))
      (let ((s (prepare-transient
                db "insert into cache values('jml', 'oak');")))
        (finalize s)
        (exec s)))))
 (test
  "reset after finalize ok"
  #t
  (call-with-database ":memory:"
    (lambda (db)
      (exec (sql db "create table cache(k,v);"))
      (let ((s (prepare-transient
                db "insert into cache values('jml', 'oak');")))
        (finalize s)
        (reset s)
        #t)))) 

 (test-error ;;  operation on closed database
  ;; Expected: Warning: finalizing pending statement: "insert into cache values('jml', 'oak');"
  "Operating on statement fails after database close (cache enabled)"
  (let ((s (call-with-database ":memory:"
             (lambda (db)
               (exec (sql db "create table cache(k,v);"))
               (prepare db "insert into cache values('jml', 'oak');")))))
    (exec s)))
 (test-error ;;  operation on closed database
  ;; Expected: Warning: finalizing pending statement: "insert into cache values('jml', 'oak');"
  "Operating on statement fails after database close (cache disabled)"
  (let ((s (call-with-database ":memory:"
             (lambda (db)
               (exec (sql db "create table cache(k,v);"))
               (prepare-transient
                db "insert into cache values('jml', 'oak');")))))
    (exec s))))

(test "Successful rollback outside transaction"
      #t
      (call-with-database ":memory:"
        (lambda (db) (rollback db))))

(test "Successful commit outside transaction"
      #t
      (call-with-database ":memory:"
        (lambda (db) (commit db))))

(test "insert ... select executes in one step"
      '((3 4) (5 6))
      (call-with-database ":memory:"
        (lambda (db)
          (define (e x) (exec (sql db x)))
          (e "create table a(k,v);")
          (e "create table b(k,v);")
          (e "insert into a values(3,4);")
          (e "insert into a values(5,6);")
          (step (prepare db "insert into b select * from a;")) ; the test
          (query fetch-all (sql db "select * from b;")))))

(test "cached statement may be exec'ed multiple times"
      0
      (call-with-database ":memory:"
          (lambda (db)
            (exec (sql db "create table a(k primary key, v);"))
            (exec (sql db "insert into a values(?,?)")
                  "foo" "bar")
            (exec (sql db "insert or ignore into a values(?,?)")
                  "foo" "bar")
            (exec (sql db "insert or ignore into a values(?,?)")
                  "foo" "bar"))))

(test-error "invalid bound parameter type (procedure) throws error"
            (call-with-database 'memory
              (lambda (db)
                (exec (sql db "create table a(k,v);"))
                (exec (sql db "select * from a where k = ?;")
                      identity))))

(test-group
 "open-database"
 (test "open in-memory database using 'memory"
       '(1 2)
       (call-with-database 'memory
         (lambda (db) (exec (sql db "select 1,2;")))))
 (test "open temp database using 'temp"
       '(1 2)
       (call-with-database 'temp
         (lambda (db) (exec (sql db "select 1,2;")))))
 (test "open temp database using 'temporary"
       '(1 2)
       (call-with-database 'temporary
         (lambda (db) (exec (sql db "select 1,2;")))))
 ;;(test "home directory expansion")
 )

(test-group
 "statement traversal"
 (call-with-database
  ":memory:"
  (lambda (db)
    (let ((s (sql db (string-literal "select 1, 2 union "
                                     "select 3, 4 union "
                                     "select 5, 6;"))))
      (test "map-rows"
            '(3 7 11)
            (query (map-rows (lambda (r) (apply + r))) s))
      (test "map-rows*"
            '(3 7 11)
            (query (map-rows* +) s))
      (test "for-each-row"
            21
            (let ((sum 0))
              (query (for-each-row (lambda (r)
                                     (set! sum (+ sum (apply + r)))))
                     s)
              sum))
      (test "for-each-row*"
            21
            (let ((sum 0))
              (query (for-each-row* (lambda (x y)
                                     (set! sum (+ sum (+ x y)))))
                     s)
              sum))
      (test "fold-rows"
            44
            (query (fold-rows (lambda (r seed)
                                (+ (apply * r)
                                   seed))
                              0)
                   s))
      (test "fold-rows*"
            44
            (query (fold-rows* (lambda (x y seed)
                                 (+ (* x y)
                                    seed))
                               0)
                   s))
      ))))

(test-group
 "large integers"
 ;; note int64 range on 32-bit is -2^53 ~ 2^53-1 where 2^53=9007199254740992
 ;; note max int64 range on 64-bit is -2^62 ~ 2^62-1;
 ;;     inexact will decrease range to 2^53
 ;; note numbers egg requires exact->inexact for non-fixnum; therefore
 ;;     injudicious application on 64-bit system reduces range to 2^53
 (call-with-database ":memory:"
   (lambda (db)
     (let ((rowid 1234567890125))
       (exec (sql db "create table cache(k,v);"))
       ;; Note the hardcoded insert to ensure the value is correct.
       (exec (sql db "insert into cache(rowid,k,v) values(1234567890125, 'jimmy', 'dunno');"))
       (test (conc "last-insert-rowid on int64 rowid (fails w/ numbers) " rowid)
             rowid
             (last-insert-rowid db))
       (test (conc "retrieve row containing int64 rowid (fails w/ numbers) " rowid)
             `(,rowid "jimmy" "dunno")
             (exec (sql db "select rowid, * from cache where rowid = ?;")
                   rowid))
       (test (conc "last-insert-rowid on int64 rowid (numbers ok) " rowid)
             (exact->inexact rowid)
             (last-insert-rowid db))
       (test (conc "retrieve row containing int64 rowid (numbers ok) " rowid)
             `(,(exact->inexact rowid) "jimmy" "dunno")
             (exec (sql db "select rowid, * from cache where rowid = ?;")
                   (exact->inexact rowid)))))))

(test-group
 "multiple connections"
 (let ((db-name (create-temporary-file "db")))
   (call-with-database db-name
     (lambda (db1)
       (call-with-database db-name
         (lambda (db2)
           (exec (sql db1 "create table c(k,v);"))
           (exec (sql db1 "create table q(k,v);"))
           (exec (sql db1 "insert into c(k,v) values(?,?);") "foo" "bar")
           (exec (sql db1 "insert into c(k,v) values(?,?);") "baz" "quux")
           (let ((s (prepare db1 "select * from c;"))
                 (ic (prepare db2 "insert into c(k,v) values(?,?);"))
                 (iq (prepare db2 "insert into q(k,v) values(?,?);")))
             (test "select step in db1" '("foo" "bar") (fetch s))
             (test "insert step in db2 during select in db1 returns busy"
                   'busy
                   (sqlite-exception-status
                    (handle-exceptions e e (exec iq "phlegm" "snot"))))

             (test "retry the busy insert, expecting busy again"
                   ;; ensure statement is reset properly; if not, we will get a bind error
                   ;; Perform a step here to show iq is reset after BUSY in step; see next test
                   'busy
                   (sqlite-exception-status
                    (handle-exceptions e e (step iq))))

             ;; (If we don't reset iq after BUSY--currently automatically done in step--
             ;;  then this step will mysteriously "succeed".  I suspect misuse of interface.)
             (test "different insert in db2 also returns busy"
                   'busy
                   (sqlite-exception-status
                    (handle-exceptions e e (exec ic "hyper" "meta"))))
             
             (test "another step in db1"
                   '("baz" "quux")
                   (fetch s))
             (test "another step in db1" '() (fetch s))

             (test "reset and restep read in db1 ok, insert lock was reset"
                   '("foo" "bar")
                   (begin (reset s) (fetch s)))


             ;; Old tests -- step formerly did not reset on statement BUSY
;;              (test "reset and restep read in db1, returns BUSY due to pending insert"
;;                    'busy
;;                    (sqlite-exception-status
;;                     (handle-exceptions e e (reset s) (fetch s))))

;;              (test "reset and query* fetch in s, expect BUSY, plus s should be reset by query*"
;;                    'busy
;;                    (begin
;;                      (reset s)
;;                      (sqlite-exception-status
;;                       (handle-exceptions e e (query* fetch s)))))

;;              (test "reset open db2 write, reset and restep read in db1"
;;                    '("foo" "bar")
;;                    (begin (reset iq)
;;                           (reset s)
;;                           (fetch s)))

             (test-error "prepare on executing select fails"
                   (begin
                     (step s)
                     (prepare db1 "select * from c;")))
             
           )))))
   (delete-file db-name)))

;;; Future tests

;; ;; test result: reset should fail with 'operation on finalized statement'
;; (use posix)
;; (call-with-database "a.db"
;;   (lambda (db)
;;     (let-prepare db ((s "select * from cache;"))
;;       (set! *s1* s)
;;       (sleep 10)        ; database must get locked exclusive elsewhere now
;;       (parameterize ((raise-database-errors #f))
;;         (and (step s) (error "step should have failed due to lock"))))
;;     ;; Statement should successfully be finalized in let-prepare
;;     (reset *s1*)))    ;; reset should fail with finalized statement error

(test-exit)