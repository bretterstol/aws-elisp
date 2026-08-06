;;; aws-ssm.el --- Magit-style manager for AWS SSM sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Åsmund Bryne Retterstøl

;; Author: Åsmund Bryne Retterstøl <asmund.retterstol@sporveien.com>
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (transient "0.4.0") (vterm "0.0.2"))
;; Keywords: tools, processes, comm
;; URL: https://github.com/retterstol/elisp-aws

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `aws-ssm' opens a Magit-style status buffer listing the running EC2
;; instances of one AWS profile, along with the SSM sessions you have open.
;; Point at an instance and act on it; press `?' for the transient menu.
;;
;; Nothing is declared up front: the only thing aws-ssm cares about is which
;; profile you are using.  Profiles are read from `aws-ssm-config-file'
;; (~/.aws/config by default), and `P' switches between them.  Instances are
;; listed with `aws ec2 describe-instances' and cached per profile and region
;; for `aws-ssm-instance-cache-ttl' seconds; `g r' refreshes them.
;;
;; Connecting to the instance at point does one of two things:
;;
;;   * With no remote port, it opens a real shell in a vterm buffer, so
;;     tab-completion, colours and full-screen programs work as they would in
;;     any other terminal.
;;
;;   * With a remote port, it starts a port forward in the background.  A port
;;     on its own is forwarded from the instance itself; give a host as well
;;     and the instance acts as a bastion, forwarding to that host.
;;
;; The port is given either through the sticky transient arguments (`-p' and
;; friends in the `?' menu, which then apply to `RET') or ad hoc with `p' and
;; `o'.  The local port defaults to the remote port.
;;
;; `D' skips the typing for databases: it lists the RDS instances and the
;; Aurora and DocumentDB clusters of the profile, writer and reader endpoints
;; alike, and forwards to the chosen one on its own port.

;;; Code:

(require 'transient)
(require 'comint)
(require 'iso8601)
(require 'seq)
(require 'subr-x)

(declare-function vterm-mode "vterm")
(declare-function evil-emacs-state "evil-states")
(defvar vterm-shell)

;;;; Customization

(defgroup aws-ssm nil
  "Manage AWS SSM sessions from Emacs."
  :group 'tools
  :prefix "aws-ssm-")

(defcustom aws-ssm-executable "aws"
  "Name of, or path to, the AWS CLI executable."
  :type 'string
  :group 'aws-ssm)

(defcustom aws-ssm-config-file (expand-file-name "~/.aws/config")
  "AWS CLI configuration file profiles are read from."
  :type 'file
  :group 'aws-ssm)

(defcustom aws-ssm-default-region "eu-west-1"
  "Region used when the current profile does not declare one."
  :type 'string
  :group 'aws-ssm)

(defcustom aws-ssm-instance-cache-ttl 3600
  "Seconds a listing of instances stays valid before it is fetched again.

Set to 0 to disable caching."
  :type 'natnum
  :group 'aws-ssm)

(defcustom aws-ssm-pop-to-session-buffer nil
  "When non-nil, display the session buffer after starting a port forward.

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

(defcustom aws-ssm-profile-state-file
  (expand-file-name "aws-ssm/profile" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "File remembering the profile last used.

This is a cache, not configuration: it only records your last choice, so
the status buffer opens on the same profile after a restart.  Set to nil
to keep the profile for the current Emacs session only."
  :type '(choice file (const :tag "Do not persist" nil))
  :group 'aws-ssm)

;;;; Faces

(defface aws-ssm-header-face
  '((t :inherit font-lock-comment-face))
  "Face for the status buffer header line."
  :group 'aws-ssm)

(defface aws-ssm-group-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for section headings in the status buffer."
  :group 'aws-ssm)

(defface aws-ssm-name-face
  '((t :inherit default))
  "Face for instance names."
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
  "Face for secondary details such as instance IDs and ports."
  :group 'aws-ssm)

;;;; Profiles

(defvar aws-ssm-profile nil
  "Profile the status buffer is currently showing.")

(defun aws-ssm--section-id (header)
  "Return the (TYPE . NAME) a section HEADER names, or nil.

HEADER is the text between the brackets.  Only `default', `profile NAME'
and `sso-session NAME' name something worth reading; the other section
types the AWS CLI allows, such as `services NAME', are ignored so they
cannot be offered as profiles."
  (pcase (split-string header "[ \t]+" t)
    (`("default") (cons 'profile "default"))
    (`("profile" ,name) (cons 'profile name))
    (`("sso-session" ,name) (cons 'sso-session name))
    (_ nil)))

(defun aws-ssm--parse-config ()
  "Return the sections of `aws-ssm-config-file' as an alist.

Each entry maps a (TYPE . NAME) key, as returned by
`aws-ssm--section-id', to an alist of the settings of that section."
  (when (file-readable-p aws-ssm-config-file)
    (with-temp-buffer
      (insert-file-contents aws-ssm-config-file)
      (goto-char (point-min))
      (let (sections current)
        (while (not (eobp))
          (let ((line (string-trim (buffer-substring (line-beginning-position)
                                                     (line-end-position)))))
            (cond
             ((string-match "\\`[#;]" line))
             ((string-match "\\`\\[[ \t]*\\([^]]+?\\)[ \t]*\\]\\'" line)
              (setq current (aws-ssm--section-id (match-string 1 line)))
              (when (and current (not (assoc current sections)))
                (push (cons current nil) sections)))
             ((and current
                   (string-match "\\`\\([A-Za-z0-9_.-]+\\)[ \t]*=[ \t]*\\(.*\\)\\'"
                                 line))
              (let ((entry (assoc current sections))
                    (key (match-string 1 line))
                    (value (string-trim (match-string 2 line))))
                (unless (or (string-empty-p value) (assoc key (cdr entry)))
                  (setcdr entry (cons (cons key value) (cdr entry))))))))
          (forward-line 1))
        (nreverse sections)))))

(defvar aws-ssm--config-cache nil
  "Cons of (STAMP . SECTIONS) holding the last parse of the config file.")

(defun aws-ssm--config-stamp ()
  "Return a value identifying the current state of `aws-ssm-config-file'.

The modification time on its own would miss an edit made within the same
second as the one before it, so the size goes into the stamp as well, as
does the file name to follow a change of `aws-ssm-config-file'."
  (when-let ((attributes (file-attributes aws-ssm-config-file)))
    (list aws-ssm-config-file
          (file-attribute-modification-time attributes)
          (file-attribute-size attributes))))

(defun aws-ssm--config-sections ()
  "Return the sections of `aws-ssm-config-file', parsed at most once per edit.

The status buffer asks for the profile, its region and its SSO session on
every render, so the parse of `aws-ssm--parse-config' is kept until the
file changes on disk."
  (let ((stamp (aws-ssm--config-stamp)))
    (if (and stamp (equal (car aws-ssm--config-cache) stamp))
        (cdr aws-ssm--config-cache)
      (let ((sections (and stamp (aws-ssm--parse-config))))
        (setq aws-ssm--config-cache (and stamp (cons stamp sections)))
        sections))))

(defun aws-ssm--config-profiles ()
  "Return an alist of (PROFILE . SETTINGS) read from `aws-ssm-config-file'."
  (let (profiles)
    (pcase-dolist (`((,type . ,name) . ,settings) (aws-ssm--config-sections))
      (when (eq type 'profile)
        (push (cons name settings) profiles)))
    (nreverse profiles)))

(defun aws-ssm--profile-setting (key &optional profile)
  "Return the setting KEY of PROFILE, defaulting to the current profile."
  (alist-get key
             (alist-get (or profile aws-ssm-profile)
                        (aws-ssm--config-profiles) nil nil #'equal)
             nil nil #'equal))

(defun aws-ssm-profiles ()
  "Return the list of profile names known to the AWS CLI."
  (mapcar #'car (aws-ssm--config-profiles)))

(defun aws-ssm-region ()
  "Return the region of the current profile, or `aws-ssm-default-region'."
  (or (aws-ssm--profile-setting "region")
      aws-ssm-default-region))

(defun aws-ssm--sso-start-url ()
  "Return the SSO start URL of the current profile, or nil.

The URL is either declared by the profile itself or, in the newer
layout, by the `sso-session' section the profile refers to."
  (or (aws-ssm--profile-setting "sso_start_url")
      (when-let* ((session (aws-ssm--profile-setting "sso_session"))
                  (settings (alist-get (cons 'sso-session session)
                                       (aws-ssm--config-sections)
                                       nil nil #'equal)))
        (alist-get "sso_start_url" settings nil nil #'equal))))

(defun aws-ssm-read-profile (prompt)
  "Read an AWS profile with PROMPT, completing over the configured ones."
  (let ((profiles (aws-ssm-profiles)))
    (completing-read prompt profiles nil nil nil nil aws-ssm-profile)))

(defun aws-ssm--load-profile ()
  "Restore `aws-ssm-profile' from `aws-ssm-profile-state-file'."
  (when (and (null aws-ssm-profile)
             aws-ssm-profile-state-file
             (file-readable-p aws-ssm-profile-state-file))
    (setq aws-ssm-profile
          (with-temp-buffer
            (insert-file-contents aws-ssm-profile-state-file)
            (let ((value (string-trim (buffer-string))))
              (unless (string-empty-p value) value))))))

(defun aws-ssm--save-profile (profile)
  "Record PROFILE as the current profile and persist it."
  (setq aws-ssm-profile profile)
  (when aws-ssm-profile-state-file
    (condition-case error
        (progn
          (make-directory (file-name-directory aws-ssm-profile-state-file) t)
          (with-temp-file aws-ssm-profile-state-file
            (insert profile "\n")))
      (file-error
       (message "aws-ssm: could not save profile: %s"
                (error-message-string error))))))

(defun aws-ssm-set-profile (profile)
  "Switch the status buffer to PROFILE and list its instances."
  (interactive (list (aws-ssm-read-profile "Profile: ")))
  (aws-ssm--save-profile profile)
  (aws-ssm--refresh-status-buffer)
  (aws-ssm--load-instances nil))

(defun aws-ssm--ensure-profile ()
  "Return the current profile, prompting for one when none is set."
  (or aws-ssm-profile
      (let ((profile (aws-ssm-read-profile "Profile: ")))
        (aws-ssm--save-profile profile)
        profile)))

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

(defun aws-ssm--report-cli-failure (profile output)
  "Report a failed CLI call for PROFILE, showing OUTPUT.

Offers to run `aws sso login' when the failure looks like expired
credentials."
  (if (string-match-p "\\(?:SSO\\|Token\\|ExpiredToken\\|sso login\\|credentials\\)"
                      output)
      (when (y-or-n-p (format "aws-ssm: credentials for %s look expired; log in? "
                              profile))
        (aws-ssm-sso-login profile))
    (message "aws-ssm: call failed for %s: %s"
             profile
             (car (last (split-string output "\n" t))))))

;;;; Instances

(defvar aws-ssm--instance-cache (make-hash-table :test 'equal)
  "Cache mapping \"PROFILE|REGION\" to a cons of (INSTANCES . TIMESTAMP).")

(defvar aws-ssm--instances nil
  "Instances currently shown in the status buffer.

Each entry is a plist with the keys :id, :name, :type and :ip.")

(defvar aws-ssm--loading nil
  "Non-nil while a listing of instances is in flight.")

(defun aws-ssm-instance-id (instance)
  "Return the instance ID of INSTANCE."
  (plist-get instance :id))

(defun aws-ssm-instance-name (instance)
  "Return the Name tag of INSTANCE, falling back to its ID."
  (or (plist-get instance :name) (plist-get instance :id)))

(defun aws-ssm-instance (id)
  "Return the listed instance with ID, or nil."
  (seq-find (lambda (instance) (equal (aws-ssm-instance-id instance) id))
            aws-ssm--instances))

(defun aws-ssm--cache-key (profile region)
  "Return the instance cache key for PROFILE and REGION."
  (format "%s|%s" profile region))

(defun aws-ssm--cached-instances (profile region)
  "Return the cached instances for PROFILE and REGION unless they expired."
  (when (> aws-ssm-instance-cache-ttl 0)
    (when-let ((entry (gethash (aws-ssm--cache-key profile region)
                               aws-ssm--instance-cache)))
      (when (< (float-time (time-since (cdr entry))) aws-ssm-instance-cache-ttl)
        (car entry)))))

(defun aws-ssm--field (string)
  "Return STRING, or nil when the CLI reported it as absent."
  (unless (or (null string) (equal string "None") (string-empty-p string))
    string))

(defun aws-ssm--parse-instances (output)
  "Parse the tab-separated OUTPUT of `describe-instances' into plists."
  (let (instances)
    (dolist (line (split-string output "\n" t))
      (pcase-let ((`(,id ,name ,type ,ip) (split-string line "\t")))
        (when (aws-ssm--field id)
          (push (list :id id
                      :name (aws-ssm--field name)
                      :type (aws-ssm--field type)
                      :ip (aws-ssm--field ip))
                instances))))
    (sort (nreverse instances)
          (lambda (a b) (string< (aws-ssm-instance-name a)
                                 (aws-ssm-instance-name b))))))

(defun aws-ssm--load-instances (force &optional callback)
  "Load the running instances of the current profile into the status buffer.

With FORCE non-nil, ignore any cached listing.  CALLBACK, when given, is
called with the instances once they are available."
  (let* ((profile (aws-ssm--ensure-profile))
         (region (aws-ssm-region))
         (cached (unless force (aws-ssm--cached-instances profile region))))
    (if cached
        (progn
          (setq aws-ssm--instances cached)
          (aws-ssm--refresh-status-buffer)
          (when callback (funcall callback cached)))
      (setq aws-ssm--loading t)
      (aws-ssm--refresh-status-buffer)
      (aws-ssm--run-async
       (list "ec2" "describe-instances"
             "--profile" profile
             "--region" region
             "--filters" "Name=instance-state-name,Values=running"
             "--query" (concat "Reservations[*].Instances[*].[InstanceId,"
                               "Tags[?Key==`Name`]|[0].Value,"
                               "InstanceType,PrivateIpAddress]")
             "--output" "text")
       (lambda (status output)
         (setq aws-ssm--loading nil)
         (if (/= status 0)
             (progn
               (aws-ssm--refresh-status-buffer)
               (aws-ssm--report-cli-failure profile output))
           (let ((instances (aws-ssm--parse-instances output)))
             (puthash (aws-ssm--cache-key profile region)
                      (cons instances (current-time))
                      aws-ssm--instance-cache)
             (setq aws-ssm--instances instances)
             (aws-ssm--refresh-status-buffer)
             (when callback (funcall callback instances)))))))))

;;;; Databases

(defvar aws-ssm--database-cache (make-hash-table :test 'equal)
  "Cache mapping \"PROFILE|REGION\" to a cons of (DATABASES . TIMESTAMP).")

(defconst aws-ssm--cluster-query
  "DBClusters[*].[DBClusterIdentifier,Engine,Endpoint,ReaderEndpoint,Port]"
  "Query selecting the endpoints of a cluster listing.")

(defconst aws-ssm--db-instance-query
  (concat "DBInstances[*].[DBInstanceIdentifier,Engine,Endpoint.Address,"
          "Endpoint.Port,DBClusterIdentifier]")
  "Query selecting the endpoints of a database instance listing.")

(defun aws-ssm--run-sync (args)
  "Run the AWS CLI with ARGS, returning a cons of (EXIT-CODE . OUTPUT).

Listing databases answers a prompt the user is waiting on, so unlike the
instance listing it is not worth doing in the background."
  (with-temp-buffer
    (let ((status (apply #'call-process aws-ssm-executable nil t nil args)))
      (cons status (string-trim (buffer-string))))))

(defun aws-ssm--engine-label (engine)
  "Return the short name of the database ENGINE."
  (cond ((null engine) "db")
        ((string-prefix-p "aurora-postgresql" engine) "postgres")
        ((string-prefix-p "postgres" engine) "postgres")
        ;; `aurora' on its own is the legacy MySQL 5.6 engine.
        ((string-prefix-p "aurora" engine) "mysql")
        ((string-prefix-p "docdb" engine) "docdb")
        (t engine)))

(defun aws-ssm--database-source-p (service engine)
  "Return non-nil when a database running ENGINE belongs to SERVICE.

The RDS listings also report DocumentDB and Neptune, which would
otherwise show up twice or not be reachable at all."
  (let ((label (aws-ssm--engine-label engine)))
    (if (equal service "docdb")
        (equal label "docdb")
      (not (member label '("docdb" "neptune"))))))

(defun aws-ssm--parse-clusters (output service)
  "Parse the tab-separated cluster OUTPUT of SERVICE into plists.

Each cluster yields one entry per endpoint it publishes, so an Aurora
cluster appears both as its writer and as its reader."
  (let (databases)
    (dolist (line (split-string output "\n" t))
      (pcase-let ((`(,name ,engine ,endpoint ,reader ,port)
                   (split-string line "\t")))
        (when (and (aws-ssm--field name)
                   (aws-ssm--field port)
                   (aws-ssm--database-source-p service engine))
          (pcase-dolist (`(,role . ,host) (list (cons 'writer (aws-ssm--field endpoint))
                                                (cons 'reader (aws-ssm--field reader))))
            (when host
              (push (list :name name
                          :engine (aws-ssm--engine-label engine)
                          :role role
                          :host host
                          :port (string-to-number port))
                    databases))))))
    (nreverse databases)))

(defun aws-ssm--parse-db-instances (output service)
  "Parse the tab-separated instance OUTPUT of SERVICE into plists.

Instances that belong to a cluster are skipped: their cluster already
lists them behind its writer and reader endpoints, which is the endpoint
you want anyway."
  (let (databases)
    (dolist (line (split-string output "\n" t))
      (pcase-let ((`(,name ,engine ,host ,port ,cluster)
                   (split-string line "\t")))
        (when (and (aws-ssm--field name)
                   (aws-ssm--field host)
                   (aws-ssm--field port)
                   (null (aws-ssm--field cluster))
                   (aws-ssm--database-source-p service engine))
          (push (list :name name
                      :engine (aws-ssm--engine-label engine)
                      :role nil
                      :host host
                      :port (string-to-number port))
                databases))))
    (nreverse databases)))

(defconst aws-ssm--database-sources
  `(("rds clusters"   "rds"   "describe-db-clusters"  ,aws-ssm--cluster-query
     aws-ssm--parse-clusters)
    ("docdb clusters" "docdb" "describe-db-clusters"  ,aws-ssm--cluster-query
     aws-ssm--parse-clusters)
    ("rds instances"  "rds"   "describe-db-instances" ,aws-ssm--db-instance-query
     aws-ssm--parse-db-instances))
  "Listings queried for database endpoints.

Each entry is (LABEL SERVICE COMMAND QUERY PARSER).  LABEL names the
listing when it cannot be read.")

(defun aws-ssm--fetch-databases (profile region)
  "Return the database endpoints of PROFILE in REGION, asking the CLI."
  (let (databases failures)
    (pcase-dolist (`(,label ,service ,command ,query ,parser)
                   aws-ssm--database-sources)
      (pcase-let ((`(,status . ,output)
                   (aws-ssm--run-sync
                    (list service command
                          "--profile" profile
                          "--region" region
                          "--query" query
                          "--output" "text"))))
        (if (/= status 0)
            (push (cons label output) failures)
          (setq databases
                (append databases (funcall parser output service))))))
    (cond
     ;; Everything failed: most likely expired credentials, worth the offer.
     ((and failures (null databases))
      (aws-ssm--report-cli-failure profile (cdar failures)))
     ;; One listing failed, often just a missing permission; say so and go on.
     (failures
      (message "aws-ssm: could not list %s"
               (string-join (mapcar #'car (nreverse failures)) " and "))))
    (sort databases (lambda (a b) (string< (aws-ssm--database-label a)
                                           (aws-ssm--database-label b))))))

(defun aws-ssm-databases (&optional force)
  "Return the database endpoints reachable in the current profile.

The listing is cached per profile and region for the same
`aws-ssm-instance-cache-ttl' as the instances are.  With FORCE non-nil,
ignore any cached listing."
  (let* ((profile (aws-ssm--ensure-profile))
         (region (aws-ssm-region))
         (key (aws-ssm--cache-key profile region))
         (entry (unless force
                  (when (> aws-ssm-instance-cache-ttl 0)
                    (gethash key aws-ssm--database-cache)))))
    (if (and entry (< (float-time (time-since (cdr entry)))
                      aws-ssm-instance-cache-ttl))
        (car entry)
      (message "aws-ssm: listing databases in %s..." region)
      (let ((databases (aws-ssm--fetch-databases profile region)))
        (puthash key (cons databases (current-time)) aws-ssm--database-cache)
        databases))))

(defun aws-ssm--database-label (database)
  "Return the completion label of DATABASE."
  (concat (aws-ssm--pad (plist-get database :engine) 10)
          (aws-ssm--pad (if-let ((role (plist-get database :role)))
                            (format "%s (%s)" (plist-get database :name) role)
                          (plist-get database :name))
                        34)
          (aws-ssm--pad (aws-ssm--abbreviate-host (plist-get database :host)) 40)
          (number-to-string (plist-get database :port))))

(defun aws-ssm--completion-table (candidates)
  "Return a completion table over CANDIDATES preserving their order."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string predicate))))

(defun aws-ssm--read-database (prompt)
  "Read a database endpoint with PROMPT."
  (let ((candidates (mapcar (lambda (database)
                              (cons (aws-ssm--database-label database) database))
                            (aws-ssm-databases))))
    (unless candidates
      (user-error "aws-ssm: no databases in %s" (aws-ssm-region)))
    (cdr (assoc (completing-read prompt (aws-ssm--completion-table candidates)
                                 nil t)
                candidates))))

(defun aws-ssm-clear-cache ()
  "Discard every cached listing of instances and databases.

The parsed AWS configuration goes too, which is the way out should an
edit ever slip past the stamp of `aws-ssm--config-stamp'."
  (interactive)
  (clrhash aws-ssm--instance-cache)
  (clrhash aws-ssm--database-cache)
  (setq aws-ssm--config-cache nil)
  (message "aws-ssm: caches cleared"))

;;;; Session command construction

(defun aws-ssm--local-port (spec)
  "Return the local port of SPEC, falling back to its remote port."
  (or (plist-get spec :local-port) (plist-get spec :port)))

(defun aws-ssm--document (spec)
  "Return the SSM document for SPEC, or nil for a plain shell session."
  (let ((port (plist-get spec :port)))
    (cond ((null port) nil)
          ((plist-get spec :host) "AWS-StartPortForwardingSessionToRemoteHost")
          (t "AWS-StartPortForwardingSession"))))

(defun aws-ssm--parameters (spec)
  "Return the `--parameters' JSON for SPEC, or nil when it takes none."
  (let ((host (plist-get spec :host))
        (port (plist-get spec :port))
        (local-port (aws-ssm--local-port spec)))
    (cond
     ((null port) nil)
     (host (format "{\"host\":[\"%s\"],\"portNumber\":[\"%s\"],\"localPortNumber\":[\"%s\"]}"
                   host port local-port))
     (t (format "{\"portNumber\":[\"%s\"],\"localPortNumber\":[\"%s\"]}"
                port local-port)))))

(defun aws-ssm--session-args (instance spec)
  "Return the CLI arguments starting a session to INSTANCE following SPEC."
  (append (list "ssm" "start-session"
                "--target" (aws-ssm-instance-id instance)
                "--region" (aws-ssm-region)
                "--profile" (aws-ssm--ensure-profile))
          (when-let ((document (aws-ssm--document spec)))
            (list "--document-name" document))
          (when-let ((reason (plist-get spec :reason)))
            (list "--reason" reason))
          (when-let ((parameters (aws-ssm--parameters spec)))
            (list "--parameters" parameters))))

;;;; Sessions

(defvar aws-ssm--sessions (make-hash-table :test 'equal)
  "Map of session key to a session plist.

Each value has the keys :key, :buffer, :process, :instance, :profile,
:spec and :started.")

(defun aws-ssm--session-key (instance spec)
  "Return the key identifying the session to INSTANCE following SPEC.

One shell and any number of port forwards can coexist per instance."
  (if-let ((port (aws-ssm--local-port spec)))
      (format "%s/%s" (aws-ssm-instance-id instance) port)
    (format "%s/shell" (aws-ssm-instance-id instance))))

(defun aws-ssm-session (key)
  "Return the session plist for KEY, or nil."
  (gethash key aws-ssm--sessions))

(defun aws-ssm-session-live-p (key)
  "Return non-nil when the session KEY is running."
  (when-let ((session (aws-ssm-session key)))
    (process-live-p (plist-get session :process))))

(defun aws-ssm-live-sessions ()
  "Return the list of live session plists, ordered by start time."
  (let (sessions)
    (maphash (lambda (key session)
               (when (aws-ssm-session-live-p key)
                 (push session sessions)))
             aws-ssm--sessions)
    (sort sessions (lambda (a b)
                     (time-less-p (plist-get a :started)
                                  (plist-get b :started))))))

(defun aws-ssm-instance-session-p (instance)
  "Return non-nil when INSTANCE has at least one live session."
  (seq-find (lambda (session)
              (equal (aws-ssm-instance-id (plist-get session :instance))
                     (aws-ssm-instance-id instance)))
            (aws-ssm-live-sessions)))

(defun aws-ssm--session-buffer-name (instance spec)
  "Return the session buffer name for INSTANCE following SPEC."
  (if-let ((port (aws-ssm--local-port spec)))
      (format "*aws-ssm forward: %s:%s*" (aws-ssm-instance-name instance) port)
    (format "*aws-ssm shell: %s*" (aws-ssm-instance-name instance))))

(defun aws-ssm--register-session (key instance spec buffer)
  "Record the session KEY to INSTANCE following SPEC, running in BUFFER."
  (let ((process (get-buffer-process buffer)))
    (set-process-query-on-exit-flag process nil)
    (add-function :after (process-sentinel process) #'aws-ssm--session-sentinel)
    (puthash key (list :key key
                       :buffer buffer
                       :process process
                       :instance instance
                       :profile aws-ssm-profile
                       :spec spec
                       :started (current-time))
             aws-ssm--sessions)))

(defun aws-ssm--session-sentinel (process _event)
  "Refresh the status buffer once PROCESS has exited."
  (unless (process-live-p process)
    (aws-ssm--refresh-status-buffer)))

(defun aws-ssm--start-shell (key instance spec)
  "Open a vterm shell session KEY on INSTANCE following SPEC."
  (unless (require 'vterm nil t)
    (user-error "aws-ssm: the vterm package is required for shell sessions"))
  (let* ((name (aws-ssm--session-buffer-name instance spec))
         (existing (get-buffer name)))
    ;; vterm starts its shell from `vterm-mode', so a stale buffer has to go
    ;; before a new session can reuse the name.
    (when existing (kill-buffer existing))
    (let* ((command (mapconcat #'shell-quote-argument
                               (cons aws-ssm-executable
                                     (aws-ssm--session-args instance spec))
                               " "))
           (vterm-shell command)
           (buffer (get-buffer-create name)))
      (with-current-buffer buffer
        (vterm-mode)
        ;; Evil's normal state reads j, k, x, : and, worst of all, ESC before
        ;; vterm can forward them, which leaves editors on the instance
        ;; unusable.  Emacs state hands the whole keyboard to the terminal;
        ;; C-z returns to evil for scrolling the buffer.
        (when (fboundp 'evil-emacs-state)
          (evil-emacs-state)))
      (aws-ssm--register-session key instance spec buffer)
      (pop-to-buffer buffer)
      buffer)))

(defun aws-ssm--start-forward (key instance spec)
  "Start the port forward session KEY on INSTANCE following SPEC."
  (let ((buffer (get-buffer-create (aws-ssm--session-buffer-name instance spec)))
        (args (aws-ssm--session-args instance spec)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (apply #'make-comint-in-buffer key buffer aws-ssm-executable nil args))
    (aws-ssm--register-session key instance spec buffer)
    (when aws-ssm-pop-to-session-buffer
      (pop-to-buffer buffer))
    buffer))

(defun aws-ssm-connect (instance &optional spec)
  "Connect to INSTANCE following SPEC.

SPEC is a plist.  With a :port it starts a port forward, binding
:local-port locally (defaulting to :port) and, when :host is given,
forwarding to that host through the instance.  Without a :port it opens
a shell.  If the same session is already up its buffer is displayed
instead of a second one being started."
  (interactive (list (aws-ssm--instance-at-point-or-read)))
  (let ((key (aws-ssm--session-key instance spec)))
    (if (aws-ssm-session-live-p key)
        (progn
          (message "aws-ssm: %s is already running" key)
          (pop-to-buffer (plist-get (aws-ssm-session key) :buffer)))
      (if (plist-get spec :port)
          (aws-ssm--start-forward key instance spec)
        (aws-ssm--start-shell key instance spec))
      (message "aws-ssm: %s started%s"
               (aws-ssm-instance-name instance)
               (if-let ((port (aws-ssm--local-port spec)))
                   (format " on localhost:%s" port)
                 ""))
      (aws-ssm--refresh-status-buffer))))

(defun aws-ssm-kill-session (key)
  "Terminate the session KEY."
  (interactive (list (aws-ssm--read-live-session "Kill session: ")))
  (if-let* ((session (aws-ssm-session key))
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
        (message "aws-ssm: %s stopped" key)
        (aws-ssm--refresh-status-buffer))
    (message "aws-ssm: %s is not running" key)))

(defun aws-ssm-kill-all-sessions ()
  "Terminate every running session."
  (interactive)
  (let ((sessions (aws-ssm-live-sessions)))
    (if (null sessions)
        (message "aws-ssm: no sessions running")
      (when (y-or-n-p (format "Kill %d running session(s)? " (length sessions)))
        (dolist (session sessions)
          (aws-ssm-kill-session (plist-get session :key)))))))

(defun aws-ssm-restart-session (key)
  "Restart the session KEY."
  (interactive (list (aws-ssm--read-live-session "Restart session: ")))
  (if-let ((session (aws-ssm-session key)))
      (let ((instance (plist-get session :instance))
            (spec (plist-get session :spec)))
        (aws-ssm-kill-session key)
        (run-at-time 1 nil (lambda () (aws-ssm-connect instance spec))))
    (message "aws-ssm: %s is not running" key)))

(defun aws-ssm--session-label (session)
  "Return the status buffer label of SESSION."
  (let ((name (aws-ssm-instance-name (plist-get session :instance)))
        (spec (plist-get session :spec)))
    (if-let ((port (aws-ssm--local-port spec)))
        (format "%s  localhost:%s → %s%s" name port
                (if-let ((host (plist-get spec :host)))
                    (concat (aws-ssm--abbreviate-host host) ":")
                  "instance:")
                (plist-get spec :port))
      (format "%s  shell" name))))

(defun aws-ssm--read-live-session (prompt)
  "Read the key of a live session with PROMPT."
  (let ((candidates (mapcar (lambda (session)
                              (cons (aws-ssm--session-label session)
                                    (plist-get session :key)))
                            (aws-ssm-live-sessions))))
    (unless candidates (user-error "aws-ssm: no sessions running"))
    (cdr (assoc (completing-read prompt candidates nil t) candidates))))

;;;; SSO credentials

(defun aws-ssm--time-later-p (a b)
  "Return non-nil when time A is later than time B."
  (time-less-p b a))

(defun aws-ssm--sso-expiry ()
  "Return the expiry time of the cached SSO access token in use, or nil.

Only tokens issued by the SSO start URL of the current profile are
considered, so a login to an unrelated account cannot make the current
one look valid.  When the profile names no start URL the newest token of
the cache is used, which is the best guess available."
  (when (file-directory-p aws-ssm-sso-cache-directory)
    (let ((start-url (aws-ssm--sso-start-url))
          expiries)
      (dolist (file (directory-files aws-ssm-sso-cache-directory t "\\.json\\'"))
        (ignore-errors
          (let* ((json (with-temp-buffer
                         (insert-file-contents file)
                         (json-parse-buffer :object-type 'alist)))
                 (token (alist-get 'accessToken json))
                 (expires (alist-get 'expiresAt json))
                 (issuer (alist-get 'startUrl json)))
            (when (and token expires
                       (or (null start-url) (equal issuer start-url)))
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

(defun aws-ssm--profile-string ()
  "Return the current profile and region for the status buffer header."
  (if aws-ssm-profile
      (concat (propertize "profile " 'face 'aws-ssm-detail-face)
              (propertize aws-ssm-profile 'face 'aws-ssm-name-face)
              (propertize (format " (%s)" (aws-ssm-region))
                          'face 'aws-ssm-detail-face))
    (propertize "no profile chosen" 'face 'aws-ssm-detail-face)))

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

PROFILE becomes the current profile of the status buffer."
  (interactive)
  (let* ((profile (or profile (aws-ssm-read-profile "SSO login for profile: ")))
         (buffer (get-buffer-create "*aws-ssm: sso login*")))
    (aws-ssm--save-profile profile)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (make-comint-in-buffer "aws-sso-login" buffer aws-ssm-executable nil
                             "sso" "login" "--profile" profile))
    (pop-to-buffer buffer)
    (aws-ssm--refresh-status-buffer)
    (message "aws-ssm: logging in to %s; complete the flow in your browser"
             profile)))

;;;; Connection URLs

(defun aws-ssm--url-scheme (port)
  "Return a URL scheme inferred from the local PORT, or nil."
  (pcase port
    (5432 "postgresql")
    (3306 "mysql")
    (27017 "mongodb")
    (6379 "redis")
    (_ nil)))

(defun aws-ssm-copy-url (key)
  "Copy a client URL for the forwarded port of session KEY to the kill ring."
  (interactive (list (aws-ssm--read-live-session "Copy URL of session: ")))
  (let* ((session (aws-ssm-session key))
         (port (aws-ssm--local-port (plist-get session :spec)))
         (scheme (and port (aws-ssm--url-scheme port))))
    (if scheme
        (let ((url (format "%s://localhost:%s/" scheme port)))
          (kill-new url)
          (message "aws-ssm: copied %s" url))
      (message "aws-ssm: no URL scheme known for %s" key))))

;;;; Status buffer

(defconst aws-ssm-buffer-name "*aws-ssm*"
  "Name of the status buffer.")

(defvar aws-ssm--name-width 26
  "Width of the name column, recomputed on each render.")

(defconst aws-ssm--id-width 22
  "Width of the instance ID column.")

(defun aws-ssm--compute-widths ()
  "Set `aws-ssm--name-width' to fit the listed instances."
  (setq aws-ssm--name-width
        (+ 2 (apply #'max 12 (mapcar (lambda (instance)
                                       (string-width (aws-ssm-instance-name instance)))
                                     aws-ssm--instances)))))

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

(defun aws-ssm--insert-instance (instance)
  "Insert the status buffer line for INSTANCE."
  (let ((live (aws-ssm-instance-session-p instance))
        (start (point)))
    (insert "  "
            (propertize (if live "●" " ")
                        'face (if live 'aws-ssm-active-face 'default))
            " "
            (propertize (aws-ssm--pad (aws-ssm-instance-name instance)
                                      aws-ssm--name-width)
                        'face 'aws-ssm-name-face)
            (propertize (aws-ssm--pad (aws-ssm-instance-id instance)
                                      aws-ssm--id-width)
                        'face 'aws-ssm-detail-face)
            (propertize (string-join
                         (delq nil (list (plist-get instance :type)
                                         (plist-get instance :ip)))
                         "  ")
                        'face 'aws-ssm-detail-face))
    (put-text-property start (point) 'aws-ssm-instance
                       (aws-ssm-instance-id instance))
    (insert "\n")))

(defun aws-ssm--insert-session (session)
  "Insert the status buffer line for SESSION."
  (let ((uptime (float-time (time-since (plist-get session :started))))
        (start (point)))
    (insert "  "
            (propertize "●" 'face 'aws-ssm-active-face)
            " "
            (propertize (aws-ssm--pad (aws-ssm--session-label session)
                                      (+ aws-ssm--name-width aws-ssm--id-width))
                        'face 'aws-ssm-name-face)
            (propertize (format "up %s" (aws-ssm--format-duration uptime))
                        'face 'aws-ssm-detail-face))
    (put-text-property start (point) 'aws-ssm-session (plist-get session :key))
    (put-text-property start (point) 'aws-ssm-instance
                       (aws-ssm-instance-id (plist-get session :instance)))
    (insert "\n")))

(defun aws-ssm--render ()
  "Render the status buffer from scratch."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (aws-ssm--compute-widths)
    (erase-buffer)
    (insert (propertize "AWS SSM" 'face 'aws-ssm-group-face)
            "   "
            (aws-ssm--profile-string)
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
    (cond
     (aws-ssm--loading
      (insert (propertize "Instances" 'face 'aws-ssm-group-face) "\n")
      (insert (propertize "  loading...\n\n" 'face 'aws-ssm-detail-face)))
     ((null aws-ssm--instances)
      (insert (propertize "Instances" 'face 'aws-ssm-group-face) "\n")
      (insert (propertize "  no running instances; press g r to refresh\n\n"
                          'face 'aws-ssm-detail-face)))
     (t
      (insert (propertize (format "Instances (%d)" (length aws-ssm--instances))
                          'face 'aws-ssm-group-face)
              "\n")
      (mapc #'aws-ssm--insert-instance aws-ssm--instances)
      (insert "\n")))
    (insert (propertize
             (concat "? help   RET shell   p port   o host   D database   "
                     "x kill   P profile   g r refresh")
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
  "Refresh the status buffer, fetching the instances again."
  (interactive)
  (aws-ssm--load-instances t))

;;;; Status buffer commands

(defun aws-ssm-instance-at-point ()
  "Return the instance on the current line, or nil."
  (when-let ((id (get-text-property (point) 'aws-ssm-instance)))
    (or (aws-ssm-instance id)
        ;; A session line may outlive the listing it was started from.
        (when-let ((session (seq-find
                             (lambda (session)
                               (equal (aws-ssm-instance-id
                                       (plist-get session :instance))
                                      id))
                             (aws-ssm-live-sessions))))
          (plist-get session :instance)))))

(defun aws-ssm--instance-at-point-or-read ()
  "Return the instance at point, or read one with completion."
  (or (aws-ssm-instance-at-point)
      (let ((candidates (mapcar (lambda (instance)
                                  (cons (aws-ssm-instance-name instance) instance))
                                aws-ssm--instances)))
        (unless candidates
          (user-error "aws-ssm: no instances listed; press g r to refresh"))
        (cdr (assoc (completing-read "Instance: " candidates nil t)
                    candidates)))))

(defun aws-ssm-session-at-point ()
  "Return the session key on the current line, or nil."
  (get-text-property (point) 'aws-ssm-session))

(defun aws-ssm--transient-args ()
  "Return the arguments of `aws-ssm-dispatch' when invoked from it."
  (when (eq transient-current-command 'aws-ssm-dispatch)
    (transient-args 'aws-ssm-dispatch)))

(defun aws-ssm--spec (args)
  "Translate transient ARGS into a session spec plist."
  (let (spec)
    (when-let ((value (transient-arg-value "--port=" args)))
      (setq spec (plist-put spec :port (string-to-number value))))
    (when-let ((value (transient-arg-value "--local-port=" args)))
      (setq spec (plist-put spec :local-port (string-to-number value))))
    (when-let ((value (transient-arg-value "--host=" args)))
      (setq spec (plist-put spec :host value)))
    spec))

(defun aws-ssm-connect-at-point (&optional args)
  "Connect to the instance at point.

Without transient ARGS this opens a shell; a `--port=' argument makes it
a port forward instead."
  (interactive (list (aws-ssm--transient-args)))
  (aws-ssm-connect (aws-ssm--instance-at-point-or-read) (aws-ssm--spec args)))

(defun aws-ssm-forward-port (instance port local-port)
  "Forward LOCAL-PORT to PORT on INSTANCE."
  (interactive
   (let* ((instance (aws-ssm--instance-at-point-or-read))
          (port (read-number (format "Remote port on %s: "
                                     (aws-ssm-instance-name instance)))))
     (list instance port (read-number "Local port: " port))))
  (aws-ssm-connect instance (list :port port :local-port local-port)))

(defun aws-ssm-forward-host (instance host port local-port)
  "Forward LOCAL-PORT to HOST:PORT through INSTANCE."
  (interactive
   (let* ((instance (aws-ssm--instance-at-point-or-read))
          (host (read-string (format "Remote host through %s: "
                                     (aws-ssm-instance-name instance))))
          (port (read-number (format "Port on %s: " host))))
     (list instance host port (read-number "Local port: " port))))
  (aws-ssm-connect instance (list :host host :port port :local-port local-port)))

(defun aws-ssm-forward-database (instance database)
  "Forward a local port to DATABASE through INSTANCE.

DATABASE is chosen from the Aurora and DocumentDB clusters of the current
profile, so neither its host nor its port has to be typed.  The local
port is the database's own port."
  (interactive
   (let ((instance (aws-ssm--instance-at-point-or-read)))
     (list instance
           (aws-ssm--read-database (format "Database through %s: "
                                           (aws-ssm-instance-name instance))))))
  (let ((port (plist-get database :port)))
    (aws-ssm-connect instance (list :host (plist-get database :host)
                                    :port port
                                    :local-port port))))

(defun aws-ssm-kill-session-at-point ()
  "Terminate the session on the current line."
  (interactive)
  (if-let ((key (aws-ssm-session-at-point)))
      (aws-ssm-kill-session key)
    (call-interactively #'aws-ssm-kill-session)))

(defun aws-ssm-restart-session-at-point ()
  "Restart the session on the current line."
  (interactive)
  (if-let ((key (aws-ssm-session-at-point)))
      (aws-ssm-restart-session key)
    (call-interactively #'aws-ssm-restart-session)))

(defun aws-ssm-show-session-buffer ()
  "Display the session buffer on the current line."
  (interactive)
  (let* ((key (or (aws-ssm-session-at-point)
                  (aws-ssm--read-live-session "Show session: ")))
         (buffer (plist-get (aws-ssm-session key) :buffer)))
    (if (buffer-live-p buffer)
        (pop-to-buffer buffer)
      (message "aws-ssm: %s has no session buffer" key))))

(defun aws-ssm-describe-instance ()
  "Show the full plist of the instance at point."
  (interactive)
  (let ((instance (aws-ssm--instance-at-point-or-read)))
    (with-current-buffer (get-buffer-create "*aws-ssm-describe*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (pp instance (current-buffer))
        (goto-char (point-min)))
      (pop-to-buffer (current-buffer)))))

;;;; Transient

(transient-define-prefix aws-ssm-dispatch ()
  "Act on AWS SSM instances and sessions."
  :refresh-suffixes t
  ["Port forward (sticky; leave empty for a shell)"
   :pad-keys t
   ("-p" "Remote port" "--port="       :prompt "Remote port: "
    :reader transient-read-number-N+)
   ("-l" "Local port"  "--local-port=" :prompt "Local port: "
    :reader transient-read-number-N+)
   ("-h" "Remote host" "--host="       :prompt "Remote host: ")]
  [["Connect"
    ("c" "Connect"       aws-ssm-connect-at-point)
    ("p" "Ask port"      aws-ssm-forward-port)
    ("o" "Ask host+port" aws-ssm-forward-host)
    ("D" "Database"      aws-ssm-forward-database)]
   ["Session"
    ("x" "Kill"        aws-ssm-kill-session-at-point)
    ("r" "Restart"     aws-ssm-restart-session-at-point)
    ("s" "Show buffer" aws-ssm-show-session-buffer)
    ("X" "Kill all"    aws-ssm-kill-all-sessions)]
   ["AWS"
    ("P" "Switch profile"       aws-ssm-set-profile)
    ("L" "SSO login"            aws-ssm-sso-login)
    ("F" "Clear caches"         aws-ssm-clear-cache :transient t)]
   ["View"
    ("g" "Refresh"   aws-ssm-refresh :transient t)
    ("y" "Copy URL"  aws-ssm-copy-url)
    ("d" "Describe"  aws-ssm-describe-instance)]])

;;;; Mode

(defvar-keymap aws-ssm-mode-map
  :doc "Keymap for `aws-ssm-mode' (evil, motion state)."
  "?"     #'aws-ssm-dispatch
  "RET"   #'aws-ssm-connect-at-point
  "c"     #'aws-ssm-connect-at-point
  "p"     #'aws-ssm-forward-port
  "o"     #'aws-ssm-forward-host
  "D"     #'aws-ssm-forward-database
  "x"     #'aws-ssm-kill-session-at-point
  "X"     #'aws-ssm-kill-all-sessions
  "r"     #'aws-ssm-restart-session-at-point
  "s"     #'aws-ssm-show-session-buffer
  "y"     #'aws-ssm-copy-url
  "d"     #'aws-ssm-describe-instance
  "P"     #'aws-ssm-set-profile
  "L"     #'aws-ssm-sso-login
  "g r"   #'aws-ssm-refresh
  "g R"   #'aws-ssm-clear-cache
  "q"     #'quit-window)

(define-derived-mode aws-ssm-mode special-mode "AWS-SSM"
  "Major mode for the AWS SSM status buffer.

\\{aws-ssm-mode-map}"
  (setq-local truncate-lines t)
  (setq-local cursor-type 'bar)
  (hl-line-mode 1))

;;;; Evil

(declare-function evil-set-initial-state "evil-core")
(declare-function evil-make-overriding-map "evil-core")
(declare-function evil-goto-first-line "evil-commands")
(declare-function evil-goto-line "evil-commands")

;; Evil's state keymaps take precedence over a plain major mode map, so
;; without this `?', `c', `d', `p', `x', `y' and the `g' prefix are read by
;; evil rather than by aws-ssm.  Motion state has no operators, which leaves
;; those keys free; marking the map as overriding hands them back.  The one
;; casualty is evil's `g' map, displaced by `g r', so restore the two motions
;; from it that are worth keeping in a line-oriented buffer.
(with-eval-after-load 'evil
  (keymap-set aws-ssm-mode-map "g g" #'evil-goto-first-line)
  (keymap-set aws-ssm-mode-map "G" #'evil-goto-line)
  (evil-make-overriding-map aws-ssm-mode-map 'motion)
  (evil-set-initial-state 'aws-ssm-mode 'motion))

;;;###autoload
(defun aws-ssm ()
  "Open the AWS SSM status buffer."
  (interactive)
  (let ((buffer (get-buffer-create aws-ssm-buffer-name)))
    (aws-ssm--load-profile)
    (with-current-buffer buffer
      (unless (derived-mode-p 'aws-ssm-mode)
        (aws-ssm-mode))
      (aws-ssm--render))
    (pop-to-buffer buffer)
    (aws-ssm--load-instances nil)))

(provide 'aws-ssm)
;;; aws-ssm.el ends here
