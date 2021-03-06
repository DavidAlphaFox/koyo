#lang racket/base

(require racket/contract
         racket/file
         racket/format
         racket/future
         racket/match
         racket/path
         racket/string
         racket/system)

(provide
 run-forever)

(define-logger runner)
(define-logger watcher)

(define racket-exe (find-executable-path "racket"))
(define raco-exe (find-executable-path "raco"))
(define (raco . args)
  (apply system*/exit-code raco-exe args))

(define (track-file? p)
  (if (directory-exists? p)
      (match/values (split-path p)
        [(_ (app path->string (regexp "^\\.")) _) #f]
        [(_ (app path->string "compiled")      _) #f]
        [(_ (app path->string "migrations")    _) #f]
        [(_ (app path->string "node_modules")  _) #f]
        [(_ _                                  _) #t])
      (case (path-get-extension p)
        [(#".rkt" #".rktd" #".ss") #t]
        [(#".html" #".sql")        #t]
        [else                      #f])))

(define (collect-tracked-files path)
  (map simplify-path (find-files track-file? path #:skip-filtered-directory? #t)))

(define (code-change-evt root-path)
  (define custodian (make-custodian))
  (parameterize ([current-custodian custodian])
    (apply
     choice-evt
     (for/list ([p (in-list (collect-tracked-files root-path))] #:when (file-exists? p))
       (handle-evt
        (filesystem-change-evt p)
        (lambda _
          (begin0 p
            (custodian-shutdown-all custodian))))))))

(define/contract (run-forever dynamic-module-path
                              #:recompile? [recompile? #t]
                              #:errortrace? [errortrace? #t])
  (->* (path-string?)
       (#:recompile? boolean?
        #:errortrace? boolean?) void?)

  (file-stream-buffer-mode (current-output-port) 'line)
  (file-stream-buffer-mode (current-error-port) 'line)

  (define root-path (simplify-path (build-path dynamic-module-path 'up 'up)))
  (define command-args
    (if errortrace?
        (list "-l" "errortrace" "-t" dynamic-module-path)
        (list dynamic-module-path)))

  (define (run)
    (define-values (stderr-in stderr-out)
      (make-pipe))
    (match-define (list in out pid err control)
      (parameterize ([subprocess-group-enabled #t])
        (apply process*/ports
               (current-output-port)
               (current-input-port)
               stderr-out
               racket-exe
               command-args)))

    (define ready? (make-semaphore))
    (define stderr-filter
      (thread
       (lambda ()
         (parameterize ([current-output-port (current-error-port)])
           (for ([line (in-lines stderr-in)])
             (when (string-contains? line "server: listening")
               (semaphore-post ready?))
             (displayln line))))))

    (define stopped-evt
      (handle-evt
       (thread
        (lambda ()
          (control 'wait)))
       (lambda (_)
         (control 'status))))

    (unless (sync/timeout 10 stopped-evt ready?)
      (log-runner-warning "timed out while waiting for 'listening' output"))
    (log-runner-info "application process started with pid ~a" pid)

    (values
     stopped-evt
     (lambda ()
       (control 'interrupt)
       (control 'wait)
       (close-output-port stderr-out))))

  (define (make! [parallel? #f])
    (if parallel?
        (raco "make" "-j" (~a (processor-count)) dynamic-module-path)
        (raco "make" dynamic-module-path)))

  (when recompile?
    (log-runner-info "compiling application")
    (make! #t))

  (log-runner-info "starting application process")
  (let loop ()
    (let-values ([(stopped-evt stop) (run)])
      (with-handlers ([exn:break?
                       (lambda _
                         (stop))])
        (sync/enable-break
         (handle-evt
          stopped-evt
          (lambda (status)
            (when (eq? status 'done-error)
              (log-runner-warning "application process failed; waiting for changes before reloading")
              (sync (code-change-evt root-path)))

            (log-runner-info "restarting application process")
            (loop)))
         (handle-evt
          (code-change-evt root-path)
          (lambda (changed-path)
            (when recompile?
              (log-runner-info (format "recompiling because '~a' changed" changed-path))
              (make!))
            (when stop
              (log-runner-info "stopping application process")
              (stop))
            (loop))))))))
