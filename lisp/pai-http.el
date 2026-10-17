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
     ;; The response started but did not finish (--max-time, a reset
     ;; connection): the body is incomplete, not a successful answer.
     ((and (numberp exit-code) (/= exit-code 0))
      (pai-http--emit-error
       st (format "connection ended before the response was complete (curl exit %s): %s"
                  exit-code (string-trim (concat (pai-http--state-buffer st) " " event)))))
     ((null status)
      (pai-http--emit-error st (format "no HTTP response: %s" (string-trim event)))))
    (unless (pai-http--state-done st)
      (setf (pai-http--state-done st) t))
    (when (pai-http--state-on-close st)
      (funcall (pai-http--state-on-close st) exit-code))))

(defun pai-http--write-temp (prefix pieces)
  "Write PIECES (strings) to a new private temp file named after PREFIX.
Multibyte pieces are written as UTF-8, unibyte ones as is.  Return the file."
  (let ((file (with-file-modes #o600 (make-temp-file prefix))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (dolist (piece pieces)
        (insert (if (multibyte-string-p piece) (encode-coding-string piece 'utf-8) piece)))
      (let ((coding-system-for-write 'binary))
        (write-region nil nil file nil 'silent)))
    file))

(defun pai-http-header-file (headers)
  "Write HEADERS, an alist of (NAME . VALUE), to a new private file; return it.
Return nil when HEADERS is empty.  curl reads the file with `-H @FILE', so
header values -- API keys -- never appear in its command line, which any
local user can read (ps, /proc/PID/cmdline).  The caller deletes the file."
  (and headers
       (pai-http--write-temp "pai-http-headers-"
                             (mapcar (lambda (h) (format "%s: %s\n" (car h) (cdr h)))
                                     headers))))

(defun pai-http--delete-files (files)
  "Delete FILES, ignoring errors."
  (dolist (f files) (ignore-errors (delete-file f))))

(cl-defun pai-http-stream (&key url (method "POST") headers body
                                on-frame on-error on-close (timeout pai-request-timeout))
  "Start a streaming HTTP request to URL.
METHOD defaults to POST.  HEADERS is an alist of (NAME . VALUE) strings.
BODY, when non-nil, is sent as the raw request body: a string, or a list of
strings sent one after the other (unibyte strings are sent as is, without
the UTF-8 copy a multibyte string needs; see `pai-provider-encode-body').
Body and headers reach curl through private temp files, deleted when the
process ends: piping a multi-MB body blocked Emacs for seconds, and headers
on the command line exposed API keys to `ps'.

ON-FRAME is called with each SSE frame plist on a 2xx response.  ON-ERROR
is called once with a descriptive string on any HTTP error (>=400) or
transport failure.  ON-CLOSE is called last with the process exit code.

Return the process; kill it to abort the request."
  (let* ((st (pai-http--state-create
              :phase 'headers :on-frame on-frame
              :on-error on-error :on-close on-close))
         (header-file (pai-http-header-file headers))
         (body-file (and body
                         (condition-case err
                             (pai-http--write-temp "pai-http-body-"
                                                   (if (listp body) body (list body)))
                           (error (pai-http--delete-files (list header-file))
                                  (signal (car err) (cdr err))))))
         (files (delq nil (list header-file body-file)))
         (args (append
                (list "-sS" "-N" "--no-buffer" "-i"
                      "-X" method
                      "--max-time" (number-to-string timeout))
                (when header-file (list "-H" (concat "@" header-file)))
                (when body-file (list "--data-binary" (concat "@" body-file)))
                (list url))))
    (condition-case err
        (make-process
         :name "pai-http"
         :command (cons pai-curl-program args)
         :connection-type 'pipe
         :coding 'utf-8
         :noquery t
         :filter (lambda (_p chunk) (pai-http--filter st chunk))
         :sentinel (lambda (p event)
                     (unless (process-live-p p) (pai-http--delete-files files))
                     (pai-http--sentinel st p event (process-exit-status p))))
      (error (pai-http--delete-files files)
             (signal (car err) (cdr err))))))

;;;; One-shot requests

(defun pai-http--parse-response (text)
  "Split curl -i output TEXT into (STATUS HEADERS BODY).
Skips interim blocks (1xx, a proxy's CONNECT reply) so STATUS and HEADERS
are the final response's; HEADERS is an alist with downcased names."
  (let ((status nil) (headers nil) (rest text))
    (while (string-match "\\`HTTP/[0-9.]+ +\\([0-9]+\\)" rest)
      (setq status (string-to-number (match-string 1 rest)) headers nil)
      (let* ((end (string-match "\r?\n\r?\n" rest))
             (block (substring rest 0 end)))
        (setq rest (if end (substring rest (match-end 0)) ""))
        (dolist (line (cdr (split-string block "\r?\n")))
          (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
            (push (cons (downcase (match-string 1 line)) (match-string 2 line)) headers)))))
    (list status (nreverse headers) rest)))

(cl-defun pai-http-request (&key url (method "GET") headers
                                 (connect-timeout 10) (timeout 30) on-done)
  "Perform a one-shot HTTP request to URL in a curl subprocess.
Name lookup, connect and TLS all run in curl: url.el resolves host names
on Emacs' own thread on macOS, which froze the UI whenever DNS hung.
HEADERS (an alist) reach curl on stdin, keeping tokens off the command line.
ON-DONE gets (STATUS HEADERS BODY) once; STATUS is nil on a transport
failure or timeout.  Return the process; deleting it also ends in ON-DONE."
  (let* ((chunks nil)
         (proc (make-process
                :name "pai-http-request"
                :command (append (list pai-curl-program "-sS" "-i" "-X" method
                                       "--connect-timeout" (number-to-string connect-timeout)
                                       "--max-time" (number-to-string timeout))
                                 (when headers (list "-H" "@-"))
                                 (list url))
                :connection-type 'pipe
                :coding 'utf-8
                :noquery t
                :filter (lambda (_p chunk) (push chunk chunks))
                :sentinel
                (lambda (p _event)
                  (unless (process-live-p p)
                    (let ((parsed (pai-http--parse-response
                                   (apply #'concat (nreverse chunks)))))
                      (when on-done
                        (apply on-done (if (and (zerop (process-exit-status p)) (car parsed))
                                           parsed
                                         (list nil nil nil))))))))))
    (when headers
      (process-send-string
       proc (mapconcat (lambda (h) (format "%s: %s\n" (car h) (cdr h))) headers "")))
    (process-send-eof proc)
    proc))

(provide 'pai-http)
;;; pai-http.el ends here
