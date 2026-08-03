;;; aws-ssm.el --- Magit-style manager for AWS SSM sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Åsmund Bryne Retterstøl

;; Author: Åsmund Bryne Retterstøl <asmund.retterstol@sporveien.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.4.0"))
;; Keywords: tools, processes, comm
;; URL: https://github.com/retterstol/elisp-aws

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `aws-ssm' opens a Magit-style status buffer listing the SSM connections you
;; have declared in `aws-ssm-connections', grouped by project, with a live view
;; of the sessions currently running.  Point at a line and act on it; press `?'
;; for the transient menu of every available action.
;;
;; A connection is a plist.  The supported keys are:
;;
;;   :name        Unique string identifying the connection.        (required)
;;   :profile     AWS CLI profile name.                            (required)
;;   :type        One of `remote-port', `local-port', `shell' or
;;                `document'.  Defaults to `shell'.
;;   :group       String used to group connections in the status
;;                buffer.  Defaults to "other".
;;   :region      AWS region.  Defaults to `aws-ssm-default-region'.
;;   :bastion-tag Value of the instance's Name tag, used to look up
;;                the target instance.
;;   :filters     Additional EC2 filters as an alist of (NAME . VALUE),
;;                for targets not identified by their Name tag.
;;   :instance-id Skip the lookup entirely and target this instance.
;;   :host        Remote host to forward to.  (`remote-port' only)
;;   :port        Remote port to forward to.
;;   :local-port  Local port to bind.  Defaults to :port.
;;   :document    SSM document name.  (`document' only, and to override
;;                the default document of the other types)
;;   :reason      Value passed to `aws ssm start-session --reason'.
;;   :url-scheme  URL scheme used by `aws-ssm-copy-url'.  Inferred from
;;                the local port when omitted.
;;   :desc        Free-form string shown in the status buffer.
;;
;; For example:
;;
;;   (setq aws-ssm-connections
;;         '((:name "postgres-dev" :group "myapp" :profile "myapp-dev"
;;            :type remote-port :bastion-tag "myapp-bastion"
;;            :host "db.cluster-abc.eu-west-1.rds.amazonaws.com"
;;            :port 5432 :local-port 5432)))
;;
;; The target instance is resolved with `aws ec2 describe-instances' at connect
;; time and cached per profile+region+filter for `aws-ssm-instance-cache-ttl'
;; seconds; `g' in the status buffer refreshes the cache along with the view.

;;; Code:

(require 'transient)
(require 'comint)
(require 'iso8601)
(require 'seq)
(require 'subr-x)

;;;; Customization

(defgroup aws-ssm nil
  "Manage AWS SSM sessions from Emacs."
  :group 'tools
  :prefix "aws-ssm-")

(defcustom aws-ssm-connections nil
  "List of SSM connections, each a plist.

See the Commentary section of aws-ssm.el for the supported keys."
  :type '(repeat plist)
  :group 'aws-ssm)

(defcustom aws-ssm-executable "aws"
  "Name of, or path to, the AWS CLI executable."
  :type 'string
  :group 'aws-ssm)

(defcustom aws-ssm-default-region "eu-west-1"
  "Region used by connections that do not specify one."
  :type 'string
  :group 'aws-ssm)

(defcustom aws-ssm-instance-cache-ttl 3600
  "Seconds a resolved instance ID stays valid before it is looked up again.

Set to 0 to disable caching."
  :type 'natnum
  :group 'aws-ssm)

(defcustom aws-ssm-require-running-instance t
  "When non-nil, only match instances in the `running' state.

This keeps recently terminated instances, which linger in the EC2 API for
about an hour, from being picked as the session target."
  :type 'boolean
  :group 'aws-ssm)

(defcustom aws-ssm-pop-to-session-buffer nil
  "When non-nil, display the session buffer after starting a session.

Port forwards are usually more convenient left in the background; shell
sessions are always displayed regardless of this setting."
  :type 'boolean
  :group 'aws-ssm)

(defcustom aws-ssm-abbreviate-hosts t
  "When non-nil, shorten AWS service suffixes of hosts in the status buffer.

For instance `db-0.cluster-abc.eu-west-1.rds.amazonaws.com' is shown as
`db-0.cluster-abc'.  The full host is always used when connecting."
  :type 'boolean
  :group 'aws-ssm)

(defcustom aws-ssm-sso-cache-directory (expand-file-name "~/.aws/sso/cache/")
  "Directory holding the AWS CLI's cached SSO tokens.

Used to report credential expiry in the status buffer without making a
network call."
  :type 'directory
  :group 'aws-ssm)

(defcustom aws-ssm-login-state-file
  (expand-file-name "aws-ssm/login" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "File remembering the profile last logged in with.

This is a cache, not configuration: it only records which login you last
chose, so the status buffer can show it again after a restart.  Set to
nil to keep the login for the current Emacs session only."
  :type '(choice file (const :tag "Do not persist" nil))
  :group 'aws-ssm)

;;;; Faces

(defface aws-ssm-header-face
  '((t :inherit font-lock-comment-face))
  "Face for the status buffer header line."
  :group 'aws-ssm)

(defface aws-ssm-group-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for group headings in the status buffer."
  :group 'aws-ssm)

(defface aws-ssm-name-face
  '((t :inherit default))
  "Face for connection names."
  :group 'aws-ssm)

(defface aws-ssm-active-face
  '((t :inherit success))
  "Face for the indicator of a running session."
  :group 'aws-ssm)

(defface aws-ssm-dead-face
  '((t :inherit error))
  "Face for the indicator of a session that exited."
  :group 'aws-ssm)

(defface aws-ssm-detail-face
  '((t :inherit shadow))
  "Face for secondary details such as hosts and ports."
  :group 'aws-ssm)

;;;; Connection accessors

(defun aws-ssm-name (conn)
  "Return the name of CONN."
  (plist-get conn :name))

(defun aws-ssm-profile (conn)
  "Return the AWS profile of CONN."
  (plist-get conn :profile))

(defun aws-ssm-region (conn)
  "Return the region of CONN, or `aws-ssm-default-region'."
  (or (plist-get conn :region) aws-ssm-default-region))

(defun aws-ssm-group (conn)
  "Return the group of CONN, or \"other\"."
  (or (plist-get conn :group) "other"))

(defun aws-ssm-type (conn)
  "Return the type of CONN, or `shell'."
  (or (plist-get conn :type) 'shell))

(defun aws-ssm-local-port (conn)
  "Return the local port of CONN, falling back to its remote port."
  (or (plist-get conn :local-port) (plist-get conn :port)))

(defun aws-ssm-connection (name)
  "Return the connection named NAME, or nil."
  (seq-find (lambda (conn) (equal (aws-ssm-name conn) name))
            aws-ssm-connections))

(defun aws-ssm--merge (conn overrides)
  "Return CONN with the non-nil properties of OVERRIDES applied."
  (let ((merged (copy-sequence conn)))
    (dolist (key '(:host :port :local-port :profile :region :document :reason))
      (when-let ((value (plist-get overrides key)))
        (setq merged (plist-put merged key value))))
    merged))

;;;; Running the AWS CLI

(defun aws-ssm--run-async (args callback)
  "Run the AWS CLI with ARGS, then call CALLBACK with (EXIT-CODE OUTPUT)."
  (let ((buffer (generate-new-buffer " *aws-ssm-cli*")))
    (make-process
     :name "aws-ssm-cli"
     :buffer buffer
     :noquery t
     :connection-type 'pipe
     :command (cons aws-ssm-executable args)
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (let ((output (with-current-buffer buffer
                         (string-trim (buffer-string)))))
           (kill-buffer buffer)
           (funcall callback (process-exit-status process) output)))))))

;;;; Instance resolution

(defvar aws-ssm--instance-cache (make-hash-table :test 'equal)
  "Cache mapping a lookup key to a cons of (INSTANCE-ID . TIMESTAMP).")

(defun aws-ssm--filters (conn)
  "Return the EC2 filter arguments identifying the target of CONN."
  (let ((filters (append
                  (when-let ((tag (plist-get conn :bastion-tag)))
                    (list (cons "tag:Name" tag)))
                  (plist-get conn :filters)
                  (when aws-ssm-require-running-instance
                    (list (cons "instance-state-name" "running"))))))
    (mapcar (lambda (filter)
              (format "Name=%s,Values=%s" (car filter) (cdr filter)))
            filters)))

(defun aws-ssm--cache-key (conn)
  "Return the instance cache key for CONN."
  (format "%s|%s|%s"
          (aws-ssm-profile conn)
          (aws-ssm-region conn)
          (string-join (aws-ssm--filters conn) " ")))

(defun aws-ssm--cached-instance (conn)
  "Return the cached instance ID for CONN if it has not expired."
  (when (> aws-ssm-instance-cache-ttl 0)
    (when-let ((entry (gethash (aws-ssm--cache-key conn) aws-ssm--instance-cache)))
      (when (< (float-time (time-since (cdr entry))) aws-ssm-instance-cache-ttl)
        (car entry)))))

(defun aws-ssm-clear-instance-cache ()
  "Discard every cached instance ID."
  (interactive)
  (clrhash aws-ssm--instance-cache)
  (message "aws-ssm: instance cache cleared"))

(defun aws-ssm--resolve-instance (conn force callback)
  "Resolve the target instance of CONN and call CALLBACK with its ID.

With FORCE non-nil, ignore any cached value.  CALLBACK is not called if
the lookup fails; an error is signalled through `message' instead."
  (let ((explicit (plist-get conn :instance-id))
        (cached (unless force (aws-ssm--cached-instance conn))))
    (cond
     (explicit (funcall callback explicit))
     (cached (funcall callback cached))
     (t
      (message "aws-ssm: resolving instance for %s..." (aws-ssm-name conn))
      (aws-ssm--run-async
       (append (list "ec2" "describe-instances"
                     "--profile" (aws-ssm-profile conn)
                     "--region" (aws-ssm-region conn))
               (when-let ((filters (aws-ssm--filters conn)))
                 (cons "--filters" filters))
               (list "--query" "Reservations[*].Instances[*].InstanceId"
                     "--output" "text"))
       (lambda (status output)
         (let ((id (car (split-string output nil t))))
           (cond
            ((/= status 0)
             (aws-ssm--report-cli-failure conn output))
            ((null id)
             (message "aws-ssm: no instance found for %s" (aws-ssm-name conn)))
            (t
             (puthash (aws-ssm--cache-key conn) (cons id (current-time))
                      aws-ssm--instance-cache)
             (funcall callback id))))))))))

(defun aws-ssm--report-cli-failure (conn output)
  "Report a failed CLI call for CONN, showing OUTPUT.

Offers to run `aws sso login' when the failure looks like expired
credentials."
  (if (string-match-p "\\(?:SSO\\|Token\\|ExpiredToken\\|sso login\\|credentials\\)"
                      output)
      (when (y-or-n-p (format "aws-ssm: credentials for %s look expired; log in? "
                              (aws-ssm-profile conn)))
        (aws-ssm-sso-login (aws-ssm-profile conn)))
    (message "aws-ssm: lookup failed for %s: %s"
             (aws-ssm-name conn)
             (car (last (split-string output "\n" t))))))

;;;; Session command construction

(defun aws-ssm--parameters (conn)
  "Return the `--parameters' JSON for CONN, or nil when it takes none."
  (let ((host (plist-get conn :host))
        (port (plist-get conn :port))
        (local-port (aws-ssm-local-port conn)))
    (pcase (aws-ssm-type conn)
      ('remote-port
       (format "{\"host\":[\"%s\"],\"portNumber\":[\"%s\"],\"localPortNumber\":[\"%s\"]}"
               host port local-port))
      ('local-port
       (format "{\"portNumber\":[\"%s\"],\"localPortNumber\":[\"%s\"]}"
               port local-port))
      (_ nil))))

(defun aws-ssm--document (conn)
  "Return the SSM document name for CONN, or nil for a plain shell session."
  (or (plist-get conn :document)
      (pcase (aws-ssm-type conn)
        ('remote-port "AWS-StartPortForwardingSessionToRemoteHost")
        ('local-port "AWS-StartPortForwardingSession")
        (_ nil))))

(defun aws-ssm--session-args (conn instance-id)
  "Return the CLI arguments starting a session to INSTANCE-ID for CONN."
  (append (list "ssm" "start-session"
                "--target" instance-id
                "--region" (aws-ssm-region conn)
                "--profile" (aws-ssm-profile conn))
          (when-let ((document (aws-ssm--document conn)))
            (list "--document-name" document))
          (when-let ((reason (plist-get conn :reason)))
            (list "--reason" reason))
          (when-let ((parameters (aws-ssm--parameters conn)))
            (list "--parameters" parameters))))

;;;; Sessions

(defvar-local aws-ssm--buffer-connection nil
  "The connection a session buffer belongs to.")

(defvar aws-ssm--sessions (make-hash-table :test 'equal)
  "Map of connection name to a session plist.

Each value has the keys :buffer, :process, :connection and :started.")

(defun aws-ssm-session (name)
  "Return the session plist for the connection named NAME, or nil."
  (gethash name aws-ssm--sessions))

(defun aws-ssm-session-live-p (name)
  "Return non-nil when the connection named NAME has a running session."
  (when-let ((session (aws-ssm-session name)))
    (process-live-p (plist-get session :process))))

(defun aws-ssm-live-sessions ()
  "Return the list of live session plists, ordered by start time."
  (let (sessions)
    (maphash (lambda (name session)
               (when (aws-ssm-session-live-p name)
                 (push session sessions)))
             aws-ssm--sessions)
    (sort sessions (lambda (a b)
                     (time-less-p (plist-get a :started)
                                  (plist-get b :started))))))

(defun aws-ssm--session-buffer-name (name)
  "Return the name of the session buffer for the connection named NAME."
  (format "*aws-ssm: %s*" name))

(defun aws-ssm--start-session (conn instance-id)
  "Start a session for CONN targeting INSTANCE-ID."
  (let* ((name (aws-ssm-name conn))
         (buffer (get-buffer-create (aws-ssm--session-buffer-name name)))
         (args (aws-ssm--session-args conn instance-id)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (apply #'make-comint-in-buffer name buffer aws-ssm-executable nil args)
      (setq-local aws-ssm--buffer-connection conn))
    (let ((process (get-buffer-process buffer)))
      (set-process-query-on-exit-flag process nil)
      (add-function :after (process-sentinel process)
                    #'aws-ssm--session-sentinel)
      (puthash name (list :buffer buffer
                          :process process
                          :connection conn
                          :instance-id instance-id
                          :started (current-time))
               aws-ssm--sessions))
    (message "aws-ssm: %s started%s" name
             (if-let ((port (aws-ssm-local-port conn)))
                 (format " on localhost:%s" port)
               ""))
    (when (or aws-ssm-pop-to-session-buffer
              (eq (aws-ssm-type conn) 'shell))
      (pop-to-buffer buffer))
    (aws-ssm--refresh-status-buffer)))

(defun aws-ssm--session-sentinel (process _event)
  "Refresh the status buffer once PROCESS has exited."
  (unless (process-live-p process)
    (aws-ssm--refresh-status-buffer)))

(defun aws-ssm-connect (conn &optional overrides force)
  "Connect CONN, applying OVERRIDES to its properties.

With FORCE non-nil, resolve the target instance rather than using the
cached value.  If the connection is already up, its buffer is displayed
instead of a second session being started."
  (let* ((conn (aws-ssm--merge conn overrides))
         (name (aws-ssm-name conn)))
    (if (aws-ssm-session-live-p name)
        (progn
          (message "aws-ssm: %s is already running" name)
          (pop-to-buffer (plist-get (aws-ssm-session name) :buffer)))
      (aws-ssm--resolve-instance
       conn force
       (lambda (instance-id) (aws-ssm--start-session conn instance-id))))))

(defun aws-ssm-kill-session (name)
  "Terminate the session of the connection named NAME."
  (interactive (list (aws-ssm--read-live-session "Kill session: ")))
  (if-let* ((session (aws-ssm-session name))
            (process (plist-get session :process))
            ((process-live-p process)))
      (progn
        ;; SIGINT lets the CLI tear down the session-manager-plugin child
        ;; cleanly; fall back to SIGKILL if it is still alive shortly after.
        (interrupt-process process)
        (run-at-time 2 nil
                     (lambda ()
                       (when (process-live-p process)
                         (delete-process process))))
        (message "aws-ssm: %s stopped" name)
        (aws-ssm--refresh-status-buffer))
    (message "aws-ssm: %s is not running" name)))

(defun aws-ssm-kill-all-sessions ()
  "Terminate every running session."
  (interactive)
  (let ((sessions (aws-ssm-live-sessions)))
    (if (null sessions)
        (message "aws-ssm: no sessions running")
      (when (y-or-n-p (format "Kill %d running session(s)? " (length sessions)))
        (dolist (session sessions)
          (aws-ssm-kill-session (aws-ssm-name (plist-get session :connection))))))))

(defun aws-ssm-restart-session (name)
  "Restart the session of the connection named NAME."
  (interactive (list (aws-ssm--read-live-session "Restart session: ")))
  (let ((conn (or (plist-get (aws-ssm-session name) :connection)
                  (aws-ssm-connection name))))
    (aws-ssm-kill-session name)
    (run-at-time 1 nil (lambda () (aws-ssm-connect conn nil t)))))

(defun aws-ssm--read-live-session (prompt)
  "Read the name of a live session with PROMPT."
  (let ((names (mapcar (lambda (session)
                         (aws-ssm-name (plist-get session :connection)))
                       (aws-ssm-live-sessions))))
    (unless names (user-error "aws-ssm: no sessions running"))
    (completing-read prompt names nil t)))

;;;; SSO credentials

(defvar aws-ssm-current-login nil
  "Profile most recently logged in with, or chosen with `aws-ssm-set-login'.

Purely informational: connections always use their own :profile.  This
records which login you last picked so the status buffer can show it.")

(defun aws-ssm--load-login ()
  "Restore `aws-ssm-current-login' from `aws-ssm-login-state-file'."
  (when (and aws-ssm-login-state-file
             (file-readable-p aws-ssm-login-state-file))
    (setq aws-ssm-current-login
          (with-temp-buffer
            (insert-file-contents aws-ssm-login-state-file)
            (let ((value (string-trim (buffer-string))))
              (unless (string-empty-p value) value))))))

(defun aws-ssm--save-login (profile)
  "Record PROFILE as the current login and persist it."
  (setq aws-ssm-current-login profile)
  (when aws-ssm-login-state-file
    (condition-case error
        (progn
          (make-directory (file-name-directory aws-ssm-login-state-file) t)
          (with-temp-file aws-ssm-login-state-file
            (insert profile "\n")))
      (file-error
       (message "aws-ssm: could not save login: %s"
                (error-message-string error))))))

(defun aws-ssm-set-login (profile)
  "Record PROFILE as the current login without logging in."
  (interactive (list (aws-ssm-read-profile "Set current login to profile: ")))
  (aws-ssm--save-login profile)
  (aws-ssm--refresh-status-buffer)
  (message "aws-ssm: current login is %s" profile))

(defun aws-ssm-clear-login ()
  "Forget the current login."
  (interactive)
  (setq aws-ssm-current-login nil)
  (when (and aws-ssm-login-state-file
             (file-exists-p aws-ssm-login-state-file))
    (delete-file aws-ssm-login-state-file))
  (aws-ssm--refresh-status-buffer)
  (message "aws-ssm: current login cleared"))

(defun aws-ssm--time-later-p (a b)
  "Return non-nil when time A is later than time B."
  (time-less-p b a))

(defun aws-ssm--sso-expiry ()
  "Return the expiry time of the newest cached SSO access token, or nil."
  (when (file-directory-p aws-ssm-sso-cache-directory)
    (let (expiries)
      (dolist (file (directory-files aws-ssm-sso-cache-directory t "\\.json\\'"))
        (ignore-errors
          (let* ((json (with-temp-buffer
                         (insert-file-contents file)
                         (json-parse-buffer :object-type 'alist)))
                 (token (alist-get 'accessToken json))
                 (expires (alist-get 'expiresAt json)))
            (when (and token expires)
              (push (encode-time (iso8601-parse expires)) expiries)))))
      (car (sort expiries #'aws-ssm--time-later-p)))))

(defun aws-ssm--format-duration (seconds)
  "Format SECONDS as a compact human-readable duration."
  (let* ((seconds (floor (abs seconds)))
         (days (/ seconds 86400))
         (hours (/ (% seconds 86400) 3600))
         (minutes (/ (% seconds 3600) 60)))
    (cond ((> days 0) (format "%dd %dh" days hours))
          ((> hours 0) (format "%dh %dm" hours minutes))
          ((> minutes 0) (format "%dm" minutes))
          (t (format "%ds" seconds)))))

(defun aws-ssm--login-string ()
  "Return the current login for the status buffer header."
  (if aws-ssm-current-login
      (concat (propertize "login " 'face 'aws-ssm-detail-face)
              (propertize aws-ssm-current-login 'face 'aws-ssm-name-face))
    (propertize "no login chosen" 'face 'aws-ssm-detail-face)))

(defun aws-ssm--sso-status-string ()
  "Return a description of the current SSO credential state."
  (if-let ((expiry (aws-ssm--sso-expiry)))
      (let ((remaining (float-time (time-subtract expiry (current-time)))))
        (if (> remaining 0)
            (propertize (format "SSO valid %s" (aws-ssm--format-duration remaining))
                        'face 'aws-ssm-active-face)
          (propertize (format "SSO expired %s ago"
                              (aws-ssm--format-duration remaining))
                      'face 'aws-ssm-dead-face)))
    (propertize "SSO unknown" 'face 'aws-ssm-detail-face)))

(defun aws-ssm-sso-login (&optional profile)
  "Run `aws sso login' for PROFILE, prompting when it is not given.

PROFILE becomes the current login, shown in the status buffer header."
  (interactive)
  (let* ((profile (or profile (aws-ssm-read-profile "SSO login for profile: ")))
         (buffer (get-buffer-create "*aws-ssm: sso login*")))
    (aws-ssm--save-login profile)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (make-comint-in-buffer "aws-sso-login" buffer aws-ssm-executable nil
                             "sso" "login" "--profile" profile))
    (pop-to-buffer buffer)
    (aws-ssm--refresh-status-buffer)
    (message "aws-ssm: logging in to %s; complete the flow in your browser"
             profile)))

(defun aws-ssm-read-profile (prompt)
  "Read an AWS profile with PROMPT, completing over the declared connections."
  (let ((profiles (seq-uniq (mapcar #'aws-ssm-profile aws-ssm-connections))))
    (completing-read prompt profiles nil nil)))

;;;; Connection URLs

(defun aws-ssm--url-scheme (conn)
  "Return the URL scheme for CONN, inferring one from its local port."
  (or (plist-get conn :url-scheme)
      (pcase (aws-ssm-local-port conn)
        (5432 "postgresql")
        (3306 "mysql")
        (27017 "mongodb")
        (6379 "redis")
        (_ nil))))

(defun aws-ssm-connection-url (conn)
  "Return a client URL for the forwarded port of CONN, or nil."
  (when-let ((scheme (aws-ssm--url-scheme conn))
             (port (aws-ssm-local-port conn)))
    (format "%s://localhost:%s/" scheme port)))

(defun aws-ssm-copy-url (conn)
  "Copy a client URL for CONN to the kill ring.

When a session is running, its effective ports are used rather than the
declared ones, so overrides given at connect time are reflected."
  (interactive (list (aws-ssm--connection-at-point-or-read)))
  (when-let* ((session (aws-ssm-session (aws-ssm-name conn)))
              ((aws-ssm-session-live-p (aws-ssm-name conn))))
    (setq conn (plist-get session :connection)))
  (if-let ((url (aws-ssm-connection-url conn)))
      (progn (kill-new url)
             (message "aws-ssm: copied %s" url))
    (message "aws-ssm: %s has no forwarded port to build a URL from"
             (aws-ssm-name conn))))

;;;; Status buffer

(defconst aws-ssm-buffer-name "*aws-ssm*"
  "Name of the status buffer.")

(defvar aws-ssm--collapsed-groups nil
  "List of group names currently folded in the status buffer.")

(defvar aws-ssm--name-width 26
  "Width of the name column, recomputed on each render.")

(defvar aws-ssm--profile-width 11
  "Width of the profile column, recomputed on each render.")

(defun aws-ssm--compute-widths ()
  "Set the column widths to fit the declared connections."
  (setq aws-ssm--name-width
        (+ 2 (apply #'max 12 (mapcar (lambda (conn)
                                       (length (aws-ssm-name conn)))
                                     aws-ssm-connections))))
  (setq aws-ssm--profile-width
        ;; At least wide enough for the "localhost:PORT" of a session row.
        (+ 2 (apply #'max 15 (mapcar (lambda (conn)
                                      (length (or (aws-ssm-profile conn) "")))
                                    aws-ssm-connections)))))

(defun aws-ssm--pad (string width)
  "Pad STRING with spaces on the right to at least WIDTH columns."
  (let ((string (or string "")))
    (concat string
            (make-string (max 1 (- width (string-width string))) ?\s))))

(defun aws-ssm--abbreviate-host (host)
  "Strip the AWS service suffix from HOST when abbreviation is enabled."
  (if (and aws-ssm-abbreviate-hosts host)
      (replace-regexp-in-string
       "\\.[a-z0-9-]+\\.\\(rds\\|docdb\\|cache\\|elasticsearch\\)\\.amazonaws\\.com\\'"
       "" host)
    host))

(defun aws-ssm--connection-summary (conn)
  "Return a short description of what CONN connects to."
  (or (plist-get conn :desc)
      (pcase (aws-ssm-type conn)
        ('remote-port (format "%s → %s:%s"
                              (aws-ssm-local-port conn)
                              (aws-ssm--abbreviate-host (plist-get conn :host))
                              (plist-get conn :port)))
        ('local-port (format "%s → instance:%s"
                             (aws-ssm-local-port conn)
                             (plist-get conn :port)))
        ('document (format "document %s" (aws-ssm--document conn)))
        (_ "shell"))))

(defun aws-ssm--insert-connection (conn)
  "Insert the status buffer line for CONN."
  (let* ((name (aws-ssm-name conn))
         (live (aws-ssm-session-live-p name))
         (start (point)))
    (insert "  "
            (propertize (if live "●" " ")
                        'face (if live 'aws-ssm-active-face 'default))
            " "
            (propertize (aws-ssm--pad name aws-ssm--name-width)
                        'face 'aws-ssm-name-face)
            (propertize (aws-ssm--pad (aws-ssm-profile conn)
                                      aws-ssm--profile-width)
                        'face 'aws-ssm-detail-face)
            (propertize (aws-ssm--connection-summary conn)
                        'face 'aws-ssm-detail-face))
    (put-text-property start (point) 'aws-ssm-connection name)
    (insert "\n")))

(defun aws-ssm--insert-session (session)
  "Insert the status buffer line for SESSION."
  (let* ((conn (plist-get session :connection))
         (name (aws-ssm-name conn))
         (uptime (float-time (time-since (plist-get session :started))))
         (start (point)))
    (insert "  "
            (propertize "●" 'face 'aws-ssm-active-face)
            " "
            (propertize (aws-ssm--pad name aws-ssm--name-width)
                        'face 'aws-ssm-name-face)
            (propertize (aws-ssm--pad (if-let ((port (aws-ssm-local-port conn)))
                                          (format "localhost:%s" port)
                                        "shell")
                                      aws-ssm--profile-width)
                        'face 'aws-ssm-detail-face)
            (propertize (format "up %s" (aws-ssm--format-duration uptime))
                        'face 'aws-ssm-detail-face))
    (put-text-property start (point) 'aws-ssm-connection name)
    (insert "\n")))

(defun aws-ssm--insert-group (group connections)
  "Insert the section for GROUP holding CONNECTIONS."
  (let ((collapsed (member group aws-ssm--collapsed-groups))
        (start (point)))
    (insert (propertize (format "%s (%d)" group (length connections))
                        'face 'aws-ssm-group-face))
    (when collapsed
      (insert (propertize "..." 'face 'aws-ssm-detail-face)))
    (put-text-property start (point) 'aws-ssm-group group)
    (insert "\n")
    (unless collapsed
      (mapc #'aws-ssm--insert-connection connections))
    (insert "\n")))

(defun aws-ssm--groups ()
  "Return an alist of (GROUP . CONNECTIONS), in declaration order."
  (let (groups)
    (dolist (conn aws-ssm-connections)
      (let* ((group (aws-ssm-group conn))
             (entry (assoc group groups)))
        (if entry
            (setcdr entry (append (cdr entry) (list conn)))
          (push (cons group (list conn)) groups))))
    (nreverse groups)))

(defun aws-ssm--render ()
  "Render the status buffer from scratch."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (aws-ssm--compute-widths)
    (erase-buffer)
    (insert (propertize "AWS SSM" 'face 'aws-ssm-group-face)
            "   "
            (aws-ssm--login-string)
            "   "
            (aws-ssm--sso-status-string)
            "\n\n")
    (let ((sessions (aws-ssm-live-sessions)))
      (when sessions
        (insert (propertize (format "Active sessions (%d)" (length sessions))
                            'face 'aws-ssm-group-face)
                "\n")
        (mapc #'aws-ssm--insert-session sessions)
        (insert "\n")))
    (if (null aws-ssm-connections)
        (insert (propertize
                 "No connections declared.  Set `aws-ssm-connections'.\n\n"
                 'face 'aws-ssm-detail-face))
      (pcase-dolist (`(,group . ,connections) (aws-ssm--groups))
        (aws-ssm--insert-group group connections)))
    (insert (propertize
             "? help   RET connect   x kill   r restart   y copy url   g refresh"
             'face 'aws-ssm-header-face)
            "\n")
    (goto-char (point-min))
    (forward-line (1- line))))

(defun aws-ssm--refresh-status-buffer ()
  "Re-render the status buffer if it exists."
  (when-let ((buffer (get-buffer aws-ssm-buffer-name)))
    (with-current-buffer buffer
      (aws-ssm--render))))

(defun aws-ssm-refresh ()
  "Refresh the status buffer, discarding cached instance IDs."
  (interactive)
  (clrhash aws-ssm--instance-cache)
  (aws-ssm--render)
  (message "aws-ssm: refreshed"))

;;;; Status buffer commands

(defun aws-ssm-connection-at-point ()
  "Return the connection on the current line, or nil."
  (when-let ((name (get-text-property (point) 'aws-ssm-connection)))
    (aws-ssm-connection name)))

(defun aws-ssm--connection-at-point-or-read ()
  "Return the connection at point, or read one with completion."
  (or (aws-ssm-connection-at-point)
      (aws-ssm-connection
       (completing-read "Connection: "
                        (mapcar #'aws-ssm-name aws-ssm-connections)
                        nil t))))

(defun aws-ssm--transient-args ()
  "Return the arguments of `aws-ssm-dispatch' when invoked from it."
  (when (eq transient-current-command 'aws-ssm-dispatch)
    (transient-args 'aws-ssm-dispatch)))

(defun aws-ssm--overrides (args)
  "Translate transient ARGS into a connection override plist."
  (let (overrides)
    (when-let ((value (transient-arg-value "--local-port=" args)))
      (setq overrides (plist-put overrides :local-port (string-to-number value))))
    (when-let ((value (transient-arg-value "--port=" args)))
      (setq overrides (plist-put overrides :port (string-to-number value))))
    (when-let ((value (transient-arg-value "--host=" args)))
      (setq overrides (plist-put overrides :host value)))
    (when-let ((value (transient-arg-value "--profile=" args)))
      (setq overrides (plist-put overrides :profile value)))
    overrides))

(defun aws-ssm-connect-at-point (&optional args)
  "Connect the connection at point, applying transient ARGS as overrides."
  (interactive (list (aws-ssm--transient-args)))
  (aws-ssm-connect (aws-ssm--connection-at-point-or-read)
                   (aws-ssm--overrides args)))

(defun aws-ssm-connect-with-local-port (conn port)
  "Connect CONN binding PORT locally instead of its declared local port."
  (interactive
   (let ((conn (aws-ssm--connection-at-point-or-read)))
     (list conn (read-number (format "Local port for %s: " (aws-ssm-name conn))
                             (or (aws-ssm-local-port conn) 0)))))
  (aws-ssm-connect conn (list :local-port port)))

(defun aws-ssm-connect-with-host (conn host)
  "Connect CONN forwarding to HOST instead of its declared host."
  (interactive
   (let ((conn (aws-ssm--connection-at-point-or-read)))
     (list conn (read-string (format "Remote host for %s: " (aws-ssm-name conn))
                             (plist-get conn :host)))))
  (aws-ssm-connect conn (list :host host)))

(defun aws-ssm-connect-with-port (conn port)
  "Connect CONN forwarding to remote PORT, bound to the same port locally."
  (interactive
   (let ((conn (aws-ssm--connection-at-point-or-read)))
     (list conn (read-number (format "Remote port for %s: " (aws-ssm-name conn))
                             (or (plist-get conn :port) 0)))))
  (aws-ssm-connect conn (list :port port :local-port port)))

(defun aws-ssm-kill-session-at-point ()
  "Terminate the session of the connection at point."
  (interactive)
  (if-let ((conn (aws-ssm-connection-at-point)))
      (aws-ssm-kill-session (aws-ssm-name conn))
    (call-interactively #'aws-ssm-kill-session)))

(defun aws-ssm-restart-session-at-point ()
  "Restart the session of the connection at point."
  (interactive)
  (if-let ((conn (aws-ssm-connection-at-point)))
      (aws-ssm-restart-session (aws-ssm-name conn))
    (call-interactively #'aws-ssm-restart-session)))

(defun aws-ssm-show-session-buffer ()
  "Display the session buffer of the connection at point."
  (interactive)
  (let* ((conn (aws-ssm--connection-at-point-or-read))
         (session (aws-ssm-session (aws-ssm-name conn))))
    (if-let ((buffer (and session (plist-get session :buffer)))
             ((buffer-live-p buffer)))
        (pop-to-buffer buffer)
      (message "aws-ssm: %s has no session buffer" (aws-ssm-name conn)))))

(defun aws-ssm-toggle-group ()
  "Fold or unfold the group at point."
  (interactive)
  (if-let ((group (get-text-property (point) 'aws-ssm-group)))
      (progn
        (if (member group aws-ssm--collapsed-groups)
            (setq aws-ssm--collapsed-groups
                  (delete group aws-ssm--collapsed-groups))
          (push group aws-ssm--collapsed-groups))
        (aws-ssm--render))
    (message "aws-ssm: point is not on a group heading")))

(defun aws-ssm-describe-connection ()
  "Show the full plist of the connection at point."
  (interactive)
  (let ((conn (aws-ssm--connection-at-point-or-read)))
    (with-current-buffer (get-buffer-create "*aws-ssm-describe*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (pp conn (current-buffer))
        (goto-char (point-min)))
      (pop-to-buffer (current-buffer)))))

;;;; Transient

(transient-define-prefix aws-ssm-dispatch ()
  "Act on AWS SSM connections and sessions."
  :refresh-suffixes t
  ["Overrides (sticky)"
   :pad-keys t
   ("-l" "Local port"  "--local-port=" :prompt "Local port: "
    :reader transient-read-number-N+)
   ("-p" "Remote port" "--port="       :prompt "Remote port: "
    :reader transient-read-number-N+)
   ("-h" "Remote host" "--host="       :prompt "Remote host: ")
   ("-P" "AWS profile" "--profile="    :prompt "Profile: ")]
  [["Connect"
    ("c" "Connect"        aws-ssm-connect-at-point)
    ("p" "Ask local port" aws-ssm-connect-with-local-port)
    ("P" "Ask remote port" aws-ssm-connect-with-port)
    ("o" "Ask remote host" aws-ssm-connect-with-host)]
   ["Session"
    ("x" "Kill"        aws-ssm-kill-session-at-point)
    ("r" "Restart"     aws-ssm-restart-session-at-point)
    ("s" "Show buffer" aws-ssm-show-session-buffer)
    ("X" "Kill all"    aws-ssm-kill-all-sessions)]
   ["AWS"
    ("L" "SSO login"           aws-ssm-sso-login)
    ("a" "Set current login"   aws-ssm-set-login   :transient t)
    ("A" "Clear current login" aws-ssm-clear-login :transient t)
    ("F" "Clear instance cache" aws-ssm-clear-instance-cache :transient t)]
   ["View"
    ("g"   "Refresh"     aws-ssm-refresh :transient t)
    ("y"   "Copy URL"    aws-ssm-copy-url)
    ("d"   "Describe"    aws-ssm-describe-connection)
    ("TAB" "Fold group"  aws-ssm-toggle-group :transient t)]])

;;;; Mode

(defvar-keymap aws-ssm-mode-map
  :doc "Keymap for `aws-ssm-mode' (evil, motion state)."
  "?"     #'aws-ssm-dispatch
  "RET"   #'aws-ssm-connect-at-point
  "c"     #'aws-ssm-connect-at-point
  "p"     #'aws-ssm-connect-with-local-port
  "P"     #'aws-ssm-connect-with-port
  "o"     #'aws-ssm-connect-with-host
  "x"     #'aws-ssm-kill-session-at-point
  "X"     #'aws-ssm-kill-all-sessions
  "r"     #'aws-ssm-restart-session-at-point
  "s"     #'aws-ssm-show-session-buffer
  "y"     #'aws-ssm-copy-url
  "d"     #'aws-ssm-describe-connection
  "TAB"   #'aws-ssm-toggle-group
  "g r"   #'aws-ssm-refresh
  "g R"   #'aws-ssm-clear-instance-cache
  "q"     #'quit-window)


(define-derived-mode aws-ssm-mode special-mode "AWS-SSM"
  "Major mode for the AWS SSM status buffer.

\\{aws-ssm-mode-map}"
  (setq-local truncate-lines t)
  (setq-local cursor-type 'bar)
  (hl-line-mode 1))

;;;###autoload
(defun aws-ssm ()
  "Open the AWS SSM status buffer."
  (interactive)
  (let ((buffer (get-buffer-create aws-ssm-buffer-name)))
    (aws-ssm--load-login)
    (with-current-buffer buffer
      (unless (derived-mode-p 'aws-ssm-mode)
        (aws-ssm-mode))
      (aws-ssm--render))
    (pop-to-buffer buffer)))

(provide 'aws-ssm)
;;; aws-ssm.el ends here
