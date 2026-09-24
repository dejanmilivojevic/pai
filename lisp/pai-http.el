;;; pai-http.el --- Streaming HTTP (SSE) transport for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; A streaming HTTP client built on `curl' driven through `make-process'.
;; Emacs' built-in `url.el' cannot stream a response body incrementally in a
;; usable way, so we shell out to curl -N and parse Server-Sent Events in the
;; process filter.
;;
;; `pai-http-stream' performs one request.  On a 2xx response it invokes
;; :on-frame for every SSE frame (a plist `(:event NAME :data STRING)').  On a
;; non-2xx response or a transport failure it accumulates the body and invokes
;; :on-error with a descriptive string.  :on-close always runs last with the
;; process exit code.  It returns the process object; kill it to abort.
;;
;; This module is transport-only: it knows nothing about providers or the
;; message model.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-config)

(cl-defstruct (pai-http--state (:constructor pai-http--state-create))
  phase           ; `headers' or `body'
  status          ; integer HTTP status once known
  (buffer "")     ; unparsed input accumulated so far
  (error-body "") ; body accumulated when status is an error
  on-frame on-error on-close
  done)           ; non-nil once terminated

(defun pai-http--emit-error (st msg)
  "Invoke ST's on-error with MSG once."
  (unless (pai-http--state-done st)
    (setf (pai-http--state-done st) t)
    (when (pai-http--state-on-error st)
      (funcall (pai-http--state-on-error st) msg))))

(defun pai-http--parse-sse-block (block)
  "Parse a single SSE BLOCK (text between blank lines) into a frame plist.
Return `(:event NAME :data STRING)' or nil when the block has no data."
  (let (event (data-lines '()))
    (dolist (line (split-string block "\n"))
      (setq line (string-remove-suffix "\r" line))
      (cond
       ((string-prefix-p ":" line) nil)          ;comment
       ((string-prefix-p "event:" line)
        (setq event (string-trim (substring line 6))))
       ((string-prefix-p "data:" line)
        (push (string-trim-left (substring line 5) " ") data-lines))
       ((string-prefix-p "data" line)            ;bare "data"
        (push "" data-lines))))
    (when data-lines
      (list :event event :data (string-join (nreverse data-lines) "\n")))))

(defun pai-http--process-body (st)
  "Consume complete SSE frames from ST's buffer, calling on-frame for each."
  (let ((buf (pai-http--state-buffer st)))
    ;; SSE frames are separated by a blank line (\n\n, tolerating \r).
    (while (string-match "\r?\n\r?\n" buf)
      (let ((block (substring buf 0 (match-beginning 0)))
            (rest (substring buf (match-end 0))))
        (setq buf rest)
        (let ((frame (pai-http--parse-sse-block block)))
          (when (and frame (pai-http--state-on-frame st)
                     (not (pai-http--state-done st)))
            (funcall (pai-http--state-on-frame st) frame)))))
    (setf (pai-http--state-buffer st) buf)))

(defun pai-http--process-headers (st)
  "Parse HTTP header block(s) from ST's buffer.
Advance to the `body' phase once a final (non-1xx) status header block ends."
  (let ((buf (pai-http--state-buffer st))
        (continue t))
    (while (and continue (string-match "\r?\n" buf))
      (let ((line (substring buf 0 (match-beginning 0)))
            (rest (substring buf (match-end 0))))
        (cond
         ;; Blank line: end of a header block.
         ((string-empty-p (string-remove-suffix "\r" line))
          (setq buf rest)
          (if (and (pai-http--state-status st)
                   (>= (pai-http--state-status st) 200))
              (progn (setf (pai-http--state-phase st) 'body
                           continue nil))
            ;; 1xx or unknown: keep reading further header blocks.
            nil))
         ;; Status line.
         ((string-match "\\`HTTP/[0-9.]+ +\\([0-9]+\\)" line)
          (setf (pai-http--state-status st)
                (string-to-number (match-string 1 line)))
          (setq buf rest))
         ;; Other header line: ignore.
         (t (setq buf rest)))))
    (setf (pai-http--state-buffer st) buf)))

(defun pai-http--filter (st chunk)
  "Process filter body: handle CHUNK for state ST."
  (setf (pai-http--state-buffer st)
        (concat (pai-http--state-buffer st) chunk))
  (when (eq (pai-http--state-phase st) 'headers)
    (pai-http--process-headers st))
  (when (eq (pai-http--state-phase st) 'body)
    (let ((status (pai-http--state-status st)))
      (if (and status (>= status 400))
          ;; Error: accumulate body, do not emit frames.
          (progn
            (setf (pai-http--state-error-body st)
                  (concat (pai-http--state-error-body st)
                          (pai-http--state-buffer st)))
            (setf (pai-http--state-buffer st) ""))
        (pai-http--process-body st)))))

(defun pai-http--sentinel (st _proc event exit-code)
  "Handle process termination EVENT with EXIT-CODE for state ST."
  (let ((status (pai-http--state-status st)))
    (cond
     ((and status (>= status 400))
      (pai-http--emit-error
       st (format "HTTP %d: %s" status
                  (string-trim (pai-http--state-error-body st)))))
     ((and (numberp exit-code) (/= exit-code 0) (null status))
      (pai-http--emit-error
       st (format "curl failed (exit %s): %s" exit-code (string-trim event))))
     ((null status)
      (pai-http--emit-error st (format "no HTTP response: %s" (string-trim event)))))
    (unless (pai-http--state-done st)
      (setf (pai-http--state-done st) t))
    (when (pai-http--state-on-close st)
      (funcall (pai-http--state-on-close st) exit-code))))

(cl-defun pai-http-stream (&key url (method "POST") headers body
                                on-frame on-error on-close (timeout pai-request-timeout))
  "Start a streaming HTTP request to URL.
METHOD defaults to POST.  HEADERS is an alist of (NAME . VALUE) strings.
BODY, when non-nil, is sent as the raw request body via stdin.

ON-FRAME is called with each SSE frame plist on a 2xx response.  ON-ERROR
is called once with a descriptive string on any HTTP error (>=400) or
transport failure.  ON-CLOSE is called last with the process exit code.

Return the process; kill it to abort the request."
  (let* ((st (pai-http--state-create
              :phase 'headers :on-frame on-frame
              :on-error on-error :on-close on-close))
         (args (append
                (list "-sS" "-N" "--no-buffer" "-i"
                      "-X" method
                      "--max-time" (number-to-string timeout))
                (mapcan (lambda (h) (list "-H" (format "%s: %s" (car h) (cdr h))))
                        headers)
                (when body (list "--data-binary" "@-"))
                (list url)))
         (proc (make-process
                :name "pai-http"
                :command (cons pai-curl-program args)
                :connection-type 'pipe
                :coding 'utf-8
                :noquery t
                :filter (lambda (_p chunk) (pai-http--filter st chunk))
                :sentinel (lambda (p event)
                            (pai-http--sentinel st p event (process-exit-status p))))))
    (when body
      (process-send-string proc body)
      (process-send-eof proc))
    proc))

(provide 'pai-http)
;;; pai-http.el ends here
