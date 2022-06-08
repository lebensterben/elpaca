;;; parcel.el --- An elisp package manager           -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Nicholas Vollmer

;; Author: Nicholas Vollmer
;; URL: https://github.com/progfolio/parcel
;; Created: Jan 1, 2022
;; Keywords: tools, convenience, lisp
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.0.0

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; An elisp package manager

;;; Code:
(eval-and-compile (require 'cl-lib))
(cl-declaim (optimize (safety 0) (speed 3)))
(require 'text-property-search)
(require 'parcel-process)
(declare-function autoload-rubric "autoload")
(declare-function info-initialize "info")
(declare-function url-filename    "url-parse")
(declare-function url-host        "url-parse")
(defvar autoload-timestamps)
(defvar generated-autoload-file)
(defvar Info-directory-list)

(defgroup parcel nil
  "An elisp package manager."
  :group 'parcel
  :prefix "parcel-")

(defface parcel-finished
  '((t (:weight bold :foreground "#00FF00")))
  "Indicates an order is finished.")

(defface parcel-blocked
  '((t (:weight bold :foreground "#FFC1CC")))
  "Indicates an order is blocked.")

(defface parcel-failed
  '((t (:weight bold :foreground "#FF1818")))
  "Indicates an order has failed.")

(defvar parcel--order-info-timer nil "Timer to debounce order info printing.")
(defvar parcel--pre-built-steps
  '(parcel--queue-dependencies parcel--add-info-path parcel--activate-package)
  "List of steps for packages which are already built.")

(defcustom parcel-after-init-hook nil
  "Parcel's analogue to `after-init-hook'.
This is run after all orders queued during init have finished processing.
It is only run once after init.
Note a blocked process will prevent this hook from being run."
  :type 'hook)

(defcustom parcel-post-queue-hook nil
  "Hook run after a queue is finished processing.
Note blocked or failed orders will prevent this hook from being run."
  :type 'hook)

(defcustom parcel-cache-autoloads t
  "If non-nil, cache package autoloads and load all at once.
Results in faster start-up time.
However, loading errors will prevent later package autoloads from loading."
  :type 'boolean)

(defcustom parcel-cache-menu-items t
  "When non-nil, menu-items ares cached. Speeds up init load."
  :type 'boolean)

(defcustom parcel-directory (expand-file-name "parcel" user-emacs-directory)
  "Location of the parcel package store."
  :type 'directory)

(defvar parcel-cache-directory (expand-file-name "cache" parcel-directory)
  "Location of the cache directory.")

(defcustom parcel-makeinfo-executable (executable-find "makeinfo")
  "Path of the makeinfo executable."
  :type 'string)

(defcustom parcel-install-info-executable
  (executable-find "install-info")
  "Path of the install-info executable."
  :type 'string)

(defcustom parcel-order-info-debounce-interval 0.02
  "Number of idle seconds to wait before printing order statuses.
Setting this to too low may cause the status buffer to block more.
Setting it too high causes prints fewer status updates."
  :type 'number)

(defcustom parcel--process-busy-interval 5
  "Seconds to wait between subprocess outputs before declaring process blocked."
  :type 'number)

(defcustom parcel-use-build-step-short-names t
  "When non-nil, recipe :build functions are auto-prefixed with `parcel--`."
  :type 'boolean)

(defcustom parcel-build-steps '(parcel--clone
                                parcel--add-remotes
                                parcel--checkout-ref
                                parcel--run-pre-build-commands
                                parcel--clone-dependencies
                                parcel--link-build-files
                                parcel--byte-compile
                                parcel--generate-autoloads-async
                                parcel--compile-info
                                parcel--install-info
                                parcel--add-info-path
                                parcel--run-post-build-commands
                                parcel--activate-package)
  "List of steps which are run when installing/building a package."
  :type 'list)

(defvar parcel-default-files-directive
  '("*.el" "*.el.in" "dir"
    "*.info" "*.texi" "*.texinfo"
    "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
    (:exclude ".dir-locals.el" "test.el" "tests.el" "*-test.el" "*-tests.el" "LICENSE"
              "README*"))
  "Default value for the `:files' directive in recipes.
It is also spliced in at any point where the `:defaults' keyword
is used in a `:files' directive.")

(defun parcel-order-defaults (_order)
  "Default order modifications. Matches any order."
  (list :protocol 'https :remotes "origin" :inherit t :depth 1))

(defcustom parcel-order-functions '(parcel-order-defaults)
  "Abnormal hook run to alter orders.
Each element must be a unary function which accepts an order.
An order may be nil, a symbol naming a package, or a plist.
The function may return nil or a plist to be merged with the order.
This hook is run via `run-hook-with-args-until-success'."
  :type 'hook)

(defun parcel-recipe-defaults (order)
  "Default ORDER modifications. Matches any ORDER."
  (let ((plist))
    (unless (plist-get order :files)
      (push (list :defaults) plist)
      (push :files plist))
    (when-let ((url (plist-get order :url))
               ((string-match-p "depp.brause.cc" url)))
      (push nil plist)
      (push :depth plist))
    plist))

(defcustom parcel-recipe-functions '(parcel-recipe-defaults)
  "Abnormal hook run to alter recipes.
Each element must be a unary function which accepts an recipe plist.
The function may return nil or a plist to be merged with the recipe.
This hook is run via `run-hook-with-args-until-success'."
  :type 'hook)

(defcustom parcel-menu-functions '(parcel-menu-org parcel-menu-melpa parcel-menu-gnu-elpa-mirror)
  "Abnormal hook to lookup packages in menus.
Each function is passed a request, which may be any of the follwoing symbols:
  - `index`
     Must return a alist of the menu's package candidates.
     Each candidate is a cell of form:
     (PACKAGE-NAME . (:source SOURCE-NAME :recipe RECIPE-PLIST))
  - `update`
     Updates the menu's package candidate list."
  :type 'hook)

(defvar parcel-ignored-dependencies
  '(emacs cl-lib cl-generic nadvice org org-mode map seq json parcel)
  "Ignore these unless the user explicitly requests they be installed.")

(defvar parcel-overriding-prompt nil "Overriding prompt for interactive functions.")

(defun parcel--read-file (path)
  "Read file at PATH into memory."
  (when (file-exists-p path)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents-literally path)
          (read (current-buffer)))
      ((error) (warn "Error reading %S into memory: %S" path err)))))

(defmacro parcel--write-file (file &rest body)
  "Write FILE using BODY.
`standard-output' and print variables are lexically bound for convenience.
e.g. elisp forms may be printed via `prin1'."
  (declare (indent 1) (debug t))
  `(let ((coding-system-for-write 'utf-8))
     (with-temp-file ,file
       (let* ((standard-output (current-buffer))
              (print-circle nil)
              (print-level  nil)
              (print-length nil))
         ,@body
         nil))))

(defun parcel--read-menu-cache ()
  "Read the menu-cache."
  (parcel--read-file (expand-file-name "menu-items.el" parcel-cache-directory)))

(defvar parcel-menu--candidates-cache
  (when parcel-cache-menu-items (parcel--read-menu-cache))
  "Cache for menu candidates.")

(defvar parcel--package-requires-regexp
  "\\(?:[[:space:]]*;+[[:space:]]*Package-Requires:[[:space:]]*\\(([^z-a]*?))\\)\\)"
  "Regexp matching the Package-Requires metadata in an elisp source file.")

(defvar parcel-recipe-keywords '( :branch :depth :fork :host :nonrecursive :package
                                  :post-build :pre-build :protocol :remote :repo)
  "Recognized parcel recipe keywords.")

(defvar parcel--queues nil
  "List of parcel queue objects.")

(cl-defstruct (parcel-queue (:constructor parcel-queue-create)
                            (:type list)
                            (:copier nil)
                            (:named))
  "Queue to hold parcel orders."
  (type (unless after-init-time 'init))
  (id   (length parcel--queues))
  (processed 0)
  (status 'incomplete)
  (time (current-time))
  autoloads forms orders)

(setq parcel--queues (list (parcel-queue-create)))

(defun parcel-merge-plists (&rest plists)
  "Return plist with set of unique keys from PLISTS.
Values for each key are that of the right-most plist containing that key."
  (let ((plists (delq nil plists))
        current plist)
    (while (setq current (pop plists))
      (while current (setq plist (plist-put plist (pop current) (pop current)))))
    plist))

(defun parcel--write-menu-cache ()
  "Write menu item cache to disk."
  (unless (file-exists-p parcel-cache-directory)
    (make-directory parcel-cache-directory))
  (parcel--write-file (expand-file-name "menu-items.el" parcel-cache-directory)
    (prin1 parcel-menu--candidates-cache)))

;;@TODO: allow passing in menu functions.
(defun parcel-menu--candidates (&optional recache)
  "Return alist of `parcel-menu-functions' candidates.
If RECACHE is non-nil, recompute `parcel-menu--candidates-cache'."
  (or (and (not recache) parcel-menu--candidates-cache)
      (prog1
          (setq parcel-menu--candidates-cache
                (sort (copy-tree
                       (cl-loop for fn in parcel-menu-functions
                                ;; Allows adding a symbol prior menu installation.
                                append (and (functionp fn) (funcall fn 'index))))
                      (lambda (a b) (string-lessp (car a) (car b)))))
        (when parcel-cache-menu-items (parcel--write-menu-cache)))))

(defsubst parcel-alist-get (key alist)
  "Return KEY's value in ALIST.
Simplified version of `alist-get'."
  (cdr (assq key alist)))

;;@TODO: clean up interface.
;;;###autoload
(defun parcel-menu-item (&optional interactive symbol menus filter no-descriptions)
  "Return menu item matching SYMBOL in MENUS or `parcel-menu-functions'.
If SYMBOL is nil, prompt for it.
If INTERACTIVE is equivalent to \\[universal-argument] prompt for MENUS.
FILTER must be a function which accepts a candidate.
If it returns nil, the candidate is not considered for selection.
If NO-DESCRIPTIONS is non-nil, candidate descriptions are not included.
This is faster (what you want with non-interactive calls)."
  (interactive "P")
  (let* ((menus (if interactive
                    (mapcar #'intern-soft
                            (cl-remove-duplicates
                             (completing-read-multiple
                              "Menus: "
                              parcel-menu-functions
                              nil 'require-match)
                             :test #'equal))
                  (or menus parcel-menu-functions (user-error "No menus found"))))
         (parcel-menu-functions menus)
         (candidates
          (let ((c (if filter
                       (cl-remove-if-not filter (parcel-menu--candidates))
                     (parcel-menu--candidates))))
            (if no-descriptions
                c
              (mapcar (lambda (candidate)
                        (propertize
                         (format "%-30s %s" (car candidate)
                                 (or (plist-get (cdr candidate) :description) ""))
                         'candidate candidate))
                      c))))
         (symbol (or symbol
                     (intern
                      (let ((choice
                             (completing-read (or parcel-overriding-prompt "Package: ")
                                              candidates nil t)))
                        (if no-descriptions
                            choice
                          (car (split-string choice "\\(?:[[:space:]]+\\)")))))))
         (candidate (parcel-alist-get symbol
                                      (if no-descriptions
                                          candidates
                                        (mapcar (lambda (c) (get-text-property 0 'candidate c))
                                                candidates))))
         (recipe (plist-get candidate :recipe)))
    (if (called-interactively-p 'interactive)
        (progn
          (unless recipe (user-error "No menu recipe for %s" symbol))
          (kill-new (format "%S" recipe))
          (message "%S menu recipe for %s copied to kill ring:\n%S"
                   (plist-get candidate :source) symbol recipe))
      recipe)))

;;;###autoload
(defun parcel-update-menus (&optional sources)
  "Update all menus in SOURCES or `parcel-menu-functions'."
  (interactive (list (mapcar #'intern
                             (completing-read-multiple
                              "Update Menus: " parcel-menu-functions))))
  (let ((parcel-menu-functions (or sources parcel-menu-functions)))
    (run-hook-with-args 'parcel-menu-functions 'update))
  (parcel-menu--candidates 'recache))

(defsubst parcel--inheritance-disabled-p (plist)
  "Return t if PLIST explicitly has :inherit nil key val, nil otherwise."
  (when-let ((member (plist-member plist :inherit)))
    (not (cadr member))))

;;;###autoload
(defun parcel-recipe (&optional item)
  "Return recipe computed from ITEM.
ITEM is any of the following values:
  - nil. The order is prompted for.
  - a symbol which will be looked up via `parcel-menu-functions'
  - an order list."
  (interactive)
  (let ((parcel-overriding-prompt "Recipe: ")
        (interactive (called-interactively-p 'interactive))
        package
        ingredients)
    (cond
     ((or (null item) (symbolp item))
      (let ((menu-item (parcel-menu-item nil item nil nil (not interactive))))
        (unless menu-item (user-error "No menu-item for %S" item))
        (when parcel-order-functions
          (push (run-hook-with-args-until-success 'parcel-order-functions item)
                ingredients))
        (push menu-item ingredients)))
     ((listp item)
      (setq package (pop item))
      (unless (parcel--inheritance-disabled-p item)
        (when-let ((parcel-order-functions)
                   (mods (run-hook-with-args-until-success 'parcel-order-functions item)))
          (push mods ingredients)
          (when (or (plist-get item :inherit) (plist-get mods :inherit))
            (push (parcel-menu-item nil package nil nil 'no-descriptions) ingredients))))
      (push item ingredients)
      (setq ingredients (nreverse ingredients)))
     (t (signal 'wrong-type-argument `((null symbolp listp) . ,item))))
    (if-let ((recipe (apply #'parcel-merge-plists ingredients)))
        (progn
          (unless (plist-get recipe :package)
            (setq recipe (plist-put recipe :package (format "%S" package))))
          (when-let ((parcel-recipe-functions)
                     (recipe-mods (run-hook-with-args-until-success
                                   'parcel-recipe-functions recipe)))
            (setq recipe (parcel-merge-plists recipe recipe-mods)))
          (if interactive
              (progn
                (kill-new (format "%S" recipe))
                (message "%S recipe copied to kill-ring:\n%S" (plist-get recipe :package) recipe))
            recipe))
      (when interactive (user-error "No recipe for %S" package)))))

(defsubst parcel--emacs-path ()
  "Return path to running Emacs."
  (concat invocation-directory invocation-name))

(defsubst parcel--repo-name (string)
  "Return repo name portion of STRING."
  (substring string (1+ (string-match-p "/" string))))

(defsubst parcel--repo-user (string)
  "Return user name portion of STRING."
  (substring string 0 (string-match-p "/" string)))

(defun parcel--full-repo-protocol-p (string)
  "Return t if STRING specifies a protocol."
  ;;@TODO: this needs to be more robust.
  (and (string-match-p ":" string) t))

(defun parcel-repo-dir (recipe)
  "Return path to repo given RECIPE."
  (let* ((url (plist-get recipe :url))
         (repo (or (plist-get recipe :repo) url))
         (local-repo (plist-get recipe :local-repo))
         (host (or (plist-get recipe :host) (plist-get recipe :fetcher)))
         (dir (if (parcel--full-repo-protocol-p repo)
                  (progn
                    (unless (featurep 'url-parse) (require 'url-parse))
                    (let ((url (url-generic-parse-url repo)))
                      (format "%s._.%s" ; repo._.host
                              (or local-repo
                                  (file-name-sans-extension
                                   (replace-regexp-in-string ".*/" "" (url-filename url))))
                              (url-host url))))
                ;;repo-or-local-repo.user.host
                (concat (or local-repo (parcel--repo-name repo))
                        "."
                        (parcel--repo-user repo)
                        "."
                        (symbol-name host)))))
    (expand-file-name (concat "repos/" dir) parcel-directory)))

(defun parcel-build-dir (recipe)
  "Return RECIPE's build dir."
  (expand-file-name (plist-get recipe :package)
                    (expand-file-name "builds/" parcel-directory)))

(defun parcel--repo-uri (recipe)
  "Return repo URI from RECIPE."
  (cl-destructuring-bind (&key (protocol 'https)
                               url
                               fetcher
                               (host fetcher)
                               (repo url) &allow-other-keys)
      recipe
    (if (parcel--full-repo-protocol-p repo)
        repo
      (let ((protocol (pcase protocol
                        ('https '("https://" . "/"))
                        ('ssh   '("git@" . ":"))
                        (_      (signal 'wrong-type-argument `((https ssh) ,protocol)))))
            (host     (pcase host
                        ('github       "github.com")
                        ('gitlab       "gitlab.com")
                        ((pred stringp) host)
                        (_              (signal 'wrong-type-argument
                                                `(:host (github gitlab stringp) ,host ,recipe))))))
        (format "%s%s%s%s.git" (car protocol) host (cdr protocol) repo)))))

(defsubst parcel--first (obj)
  "Return `car' of OBJ if it is a list, else OBJ."
  (if (listp obj) (car obj) obj))

(defun parcel--build-steps (item)
  "Return a list of build functions for ITEM."
  (let* ((order (alist-get item (parcel--queued-orders)))
         (recipe (or (and order (parcel-order-recipe order))
                     (parcel-recipe item)))
         (build (plist-member recipe :build))
         (steps (cadr build))
         (removep (and (eq (car-safe steps) :not) (pop steps))))
    (when (and parcel-use-build-step-short-names (listp steps))
      (setq steps (cl-loop for step in steps
                           collect (intern (concat "parcel--" (symbol-name step))))))
    (cond
     ((or (not build) (eq steps t)) parcel-build-steps)
     (removep (cl-set-difference parcel-build-steps steps))
     ((listp steps) steps))))

(cl-defstruct (parcel-order (:constructor parcel--order-create)
                            (:type list)
                            (:named))
  "Order for queued processing."
  id package item statuses
  repo-dir build-dir mono-repo
  files build-steps recipe
  dependencies dependents includes
  (queue-id (1- (length parcel--queues)))
  (queue-time (current-time))
  (init (not after-init-time))
  process log)

(defmacro parcel--required-order-arg (try info)
  "TRY to set arg. If error, fail order with INFO."
  (declare (indent 1) (debug t))
  `(condition-case err ,try
     ((error) (setq status 'failed info (format ,info err)) nil)))

(defsubst parcel--order-mono-repo (repo-dir)
  "Return previously queued order with REPO-DIR."
  (cl-some (lambda (queued)
             (and-let* ((order (cdr queued))
                        ((equal repo-dir (parcel-order-repo-dir order)))
                        order)))
           (reverse (parcel--queued-orders))))

(defsubst parcel--order-build-steps (item builtp clonedp mono-repo)
  "Return list of build functions for ITEM.
BUILTP, CLONEDP, and MONO-REPO control which steps are excluded."
  (if builtp
      parcel--pre-built-steps
    (when-let ((steps (parcel--build-steps item)))
      (when (and mono-repo (memq 'ref-checked-out (parcel-order-statuses mono-repo)))
        (setq steps (cl-set-difference steps
                                       '(parcel--clone parcel--add-remotes parcel--checkout-ref))))
      (when clonedp (setq steps (delq 'parcel--clone steps)))
      steps)))

(cl-defun parcel-order-create
    (item &key recipe repo-dir build-dir files mono-repo)
  "Create a new parcel order struct from ITEM.
Keys are as follows:
  RECIPE order recipe
  REPO-DIR package's build-dir
  BUILD-DIR package's repo-dir
  CACHED whether or not the package was read from the cache
  FILES list of package's linked files
  MONO-REPO order which is responsible for cloning repo current order is in."
  (let* ((status 'queued)
         (info "Package queued")
         (id (parcel--first item))
         (recipe (or recipe (parcel--required-order-arg (parcel-recipe item)
                              "No recipe: %S")))
         (repo-dir (or repo-dir (and recipe
                                     (parcel--required-order-arg (parcel-repo-dir recipe)
                                       "Unable to determine repo dir: %S"))))
         (build-dir (or build-dir (and recipe (parcel-build-dir recipe))))
         (clonedp (and repo-dir (file-exists-p repo-dir)))
         (builtp (and clonedp (and build-dir (file-exists-p build-dir))))
         (mono-repo (or mono-repo
                        (when-let (((not builtp))
                                   (order (parcel--order-mono-repo repo-dir)))
                          (setq status 'blocked info (format "Waiting for monorepo %S" repo-dir))
                          order)))
         (build-steps (parcel--order-build-steps item builtp clonedp mono-repo))
         (order (parcel--order-create
                 :id id :package (format "%S" id) :item item :statuses (list status)
                 :repo-dir repo-dir :build-dir build-dir :mono-repo mono-repo
                 :files files :build-steps build-steps :recipe recipe
                 :includes (and mono-repo (list mono-repo))
                 :log (list (list status nil info)))))
    (when mono-repo (cl-pushnew order (parcel-order-includes mono-repo)))
    order))


(defun parcel--fail-order (order &optional reason)
  "Fail ORDER for REASON."
  (let ((item (parcel-order-item order))
        (queue (car (last parcel--queues (1+ (parcel-order-queue-id order))))))
    (setf (parcel-queue-forms queue)
          (assq-delete-all (parcel--first item) (parcel-queue-forms queue))))
  (parcel--update-order-info order reason 'failed)
  (parcel--finalize-order order))

(defsubst parcel-order-status (order)
  "Return `car' of ORDER's statuses."
  (car (parcel-order-statuses order)))

(defun parcel--log-event (order text)
  "Store TEXT in ORDER's log.
Each event is of the form: (STATUS TIME TEXT)"
  (push (list (parcel-order-status order)
              (current-time)
              text)
        (parcel-order-log order)))

(defun parcel--queued-orders (&optional n)
  "Return list of queued orders from queue N.
If ARG is a non-negative integer return Nth queue's orders in `parcel--queues'.
Otherwise return a list of all queued orders."
  (nreverse
   (if n
       (parcel-queue-orders (nth n parcel--queues))
     (cl-loop for queue in parcel--queues append (parcel-queue-orders queue)))))

(defsubst parcel--status-face (status &optional default)
  "Return face for STATUS or DEFAULT if not found."
  (cond
   ((eq status 'blocked)  'parcel-blocked)
   ((eq status 'finished) 'parcel-finished)
   ((eq status 'failed)   'parcel-failed)
   (t                     (or default 'default))))

(defun parcel--run-build-commands (commands)
  "Run build COMMANDS."
  (dolist (command (if (listp (car commands)) commands (list commands)))
    (if (cl-every #'stringp command)
        (parcel-with-process (apply #'parcel-process-call command)
          (if success
              (message stdout)
            (message "Build command error: %S" result)
            (error "Build command failed: %S" stderr)))
      (eval command t))))

(defsubst parcel-order-info (order)
  "Return ORDER's most recent log event info."
  (nth 2 (car (parcel-order-log order))))

(defsubst parcel--run-next-build-step (order)
  "Run ORDER's next build step with ARGS."
  (funcall (or (pop (parcel-order-build-steps order)) #'parcel--finalize-order) order))

(defun parcel--continue-mono-repo-dependency (order)
  "Continue processing ORDER after it's mono-repo is in the proper state."
  (unless (memq (parcel-order-statuses order) '(finished build-linked))
    (parcel--remove-build-steps
     order '(parcel--clone parcel--add-remotes parcel--checkout-ref))
    (parcel--run-next-build-step order)))

(defvar parcel-status-buffer)
(declare-function parcel-status "parcel-status")
(defun parcel--update-order-info (order info &optional status)
  "Update ORDER STATUS.
Print the order status line in `parcel-status-buffer'.
If STATUS is non-nil and differs from ORDER's current STATUS,
signal ORDER's depedentents to check (and possibly change) their status.
If INFO is non-nil, ORDER's info is updated as well."
  (when (and status (not (equal status (parcel-order-status order))))
    (push status (parcel-order-statuses order))
    (when (memq status '(finished failed blocked))
      (mapc #'parcel--order-check-status (parcel-order-dependents order)))
    (when (eq status 'ref-checked-out)
      (mapc #'parcel--continue-mono-repo-dependency (parcel-order-includes order)))
    (when (eq status 'failed) (parcel-status)))
  (when info (parcel--log-event order info))
  (when (and (boundp 'parcel-status-buffer)
             (get-buffer-window parcel-status-buffer t)) ;; Status buffer visible
    (when parcel--order-info-timer (cancel-timer parcel--order-info-timer))
    (setq parcel--order-info-timer (run-at-time parcel-order-info-debounce-interval
                                                nil (lambda () (parcel-status 'all 'noselect))))))

(defun parcel--log-duration (order)
  "Return ORDER's log duration."
  ;;most recent event is car of log
  (let* ((log (parcel-order-log order))
         (end (nth 1 (car log))))
    (time-subtract end (parcel-order-queue-time order))))

;;;###autoload
(defun parcel-split-queue ()
  "Split remaining orders into new queue.
If current queue is empty, it is reused."
  (when (parcel-queue-orders (car parcel--queues))
    (push (parcel-queue-create) parcel--queues)))

;;;###autoload
(defmacro parcel-queue (&rest body)
  "Execute BODY in its own queue."
  (declare (debug t))
  `(progn
     (parcel-split-queue)
     ,@body
     (parcel-split-queue)))

(defvar parcel--finalize-queue-hook nil
  "Private hook run after a queue has been finalized.")

(defun parcel--finalize-queue (queue)
  "Run QUEUE's post isntallation functions:
- load cached autoloads
- evaluate deferred package configuration forms
- possibly run `parcel-after-init-hook'."
  (when-let ((autoloads (parcel-queue-autoloads queue)))
    (eval `(progn ,@autoloads) t))
  (when-let ((forms (parcel-queue-forms queue)))
    (eval `(progn ,@(apply #'append (mapcar #'cdr (nreverse forms)))) t))
  (setf (parcel-queue-status queue) 'complete)
  (let ((next-queue (nth (1+ (parcel-queue-id queue)) (reverse parcel--queues))))
    (if (and (eq (parcel-queue-type queue) 'init)
             (or (null next-queue)
                 (not (eq (parcel-queue-type next-queue) 'init))))
        (progn
          (run-hooks 'parcel-after-init-hook)
          (parcel-split-queue))
      (run-hooks 'parcel--finalize-queue-hook)
      (run-hooks 'parcel-post-queue-hook)
      (when next-queue (parcel--process-queue next-queue)))))

(defun parcel--finalize-order (order)
  "Declare ORDER finished or failed."
  (let ((status (parcel-order-status order)))
    (if (eq  status 'finished)
        (cl-loop for order in (parcel-order-dependents order)
                 unless (eq (parcel-order-status order) 'finished)
                 do (parcel--order-check-status order))
      (unless (eq (parcel-order-status order) 'failed)
        (parcel--update-order-info
         order
         (concat  "✓ " (format-time-string "%s.%3N" (parcel--log-duration order)) " secs")
         'finished))
      (when-let ((queue (car (last parcel--queues (1+ (parcel-order-queue-id order)))))
                 ((= (cl-incf (parcel-queue-processed queue))
                     (length (parcel-queue-orders queue)))))
        (parcel--finalize-queue queue)))))

(defun parcel--queue-order (item)
  "Queue (ITEM . ORDER) in `parcel--queued-orders'.
If STATUS is non-nil, the order is given that initial status.
Return order structure."
  (if (and (not after-init-time) (parcel-alist-get item (parcel--queued-orders)))
      (warn "Duplicate item declaration: %S" item)
    (let* ((order (parcel-order-create item))
           (log (pop (parcel-order-log order)))
           (status (car log))
           (info (nth 2 log)))
      (push (cons (parcel-order-id order) order)
            (parcel-queue-orders (car parcel--queues)))
      (if (eq status 'failed)
          (parcel--fail-order order info)
        (parcel--update-order-info order info status))
      order)))

(defun parcel--add-remotes (order &optional recurse)
  "Add ORDER's repo remotes.
RECURSE is used to keep track of recursive calls."
  (let ((default-directory (parcel-order-repo-dir order))
        (recipe            (parcel-order-recipe   order)))
    (cl-destructuring-bind
        ( &key remotes
          ((:host recipe-host))
          ((:protocol recipe-protocol))
          ((:repo recipe-repo))
          &allow-other-keys)
        recipe
      (unless recurse (parcel--update-order-info order "Adding Remotes"))
      (pcase remotes
        ("origin" nil)
        ((and (pred stringp) remote)
         (parcel-process-call "git" "remote" "rename" "origin" remote))
        ((pred listp)
         (dolist (spec remotes)
           (if (stringp spec)
               (parcel--add-remotes
                (let ((copy (copy-parcel-order order)))
                  (setf (parcel-order-recipe copy)
                        (plist-put (copy-tree recipe) :remotes spec))
                  copy)
                'recurse)
             (pcase-let ((`(,remote . ,props) spec))
               (when props
                 (cl-destructuring-bind
                     (&key (host     recipe-host)
                           (protocol recipe-protocol)
                           (repo     recipe-repo)
                           &allow-other-keys
                           &aux
                           (recipe (list :host host :protocol protocol :repo repo)))
                     props
                   (parcel-process-call
                    "git" "remote" "add" remote (parcel--repo-uri recipe))
                   (unless (equal remote "origin")
                     (parcel-process-call "git" "remote" "rename" "origin" remote))))))))
        (_ (parcel--fail-order
            order (format "(wrong-type-argument ((stringp listp)) %S" remotes))))))
  (unless recurse (parcel--run-next-build-step order)))

(defun parcel--remove-build-steps (order steplist)
  "Remove each step in STEPLIST from ORDER."
  (setf (parcel-order-build-steps order)
        (cl-set-difference (parcel-order-build-steps order) steplist)))

(defun parcel--files (order &optional files nocons)
  "Return alist of ORDER :files to be symlinked: (PATH . TARGET PATH).
FILES and NOCONS are used recursively."
  (let* ((repo-dir          (parcel-order-repo-dir order))
         (default-directory repo-dir)
         (build-dir         (parcel-order-build-dir order))
         (recipe            (parcel-order-recipe order))
         (files             (or files (plist-get recipe :files)))
         (exclusions        nil)
         (targets           nil)
         (with-subdirs      nil))
    (dolist (el files)
      (pcase el
        ((pred stringp) (push (or (file-expand-wildcards el) el) targets))
        (`(:exclude  . ,excluded)
         (push (parcel--files order excluded 'nocons) exclusions)
         nil)
        (:defaults
         (push (parcel--files order parcel-default-files-directive 'nocons) targets))
        ;;@FIX: subdir needn't be same name as globbed path...
        (`(,_subdir . ,paths)
         (cl-loop for path in paths
                  for globbed = (file-expand-wildcards path)
                  do (cl-loop for p in globbed
                              do (push (cons (expand-file-name p repo-dir)
                                             (let ((default-directory build-dir))
                                               (expand-file-name p build-dir)))
                                       with-subdirs))))))
    (if nocons
        targets
      (append
       with-subdirs
       (cl-loop for target in (flatten-tree targets)
                unless (or (not (file-exists-p (expand-file-name target)))
                           (member target (flatten-tree exclusions)))
                collect
                (cons (expand-file-name target)
                      (expand-file-name (file-name-nondirectory target) build-dir)))))))

(defun parcel--link-build-files (order)
  "Link ORDER's :files into it's builds subdirectory."
  (parcel--update-order-info order "Linking build files")
  (let* ((build-dir (parcel-order-build-dir order))
         (files (or (parcel-order-files order)
                    (setf (parcel-order-files order) (parcel--files order)))))
    (when (file-exists-p build-dir) (delete-directory build-dir 'recusrive))
    (make-directory build-dir 'parents)
    (dolist (spec files)
      (let ((file   (car spec))
            (link   (cdr spec)))
        (make-directory (file-name-directory link) 'parents)
        (make-symbolic-link file link 'overwrite))))
  (parcel--update-order-info order "Build files linked" 'build-linked)
  (parcel--run-next-build-step order))

(defun parcel--add-info-path (order)
  "Add the ORDER's info to `Info-directory-list'."
  (let ((build-dir (parcel-order-build-dir order)))
    (if (file-exists-p (expand-file-name "dir" build-dir))
        (progn
          (parcel--update-order-info order "Adding Info path" 'info)
          (with-eval-after-load 'info
            (info-initialize)
            (cl-pushnew build-dir Info-directory-list)))
      (parcel--update-order-info order "No Info dir file found" 'info))
    (parcel--run-next-build-step order)))

(defun parcel--process-busy (process)
  "Update order status when PROCESS has stopped producing output."
  (when-let (((eq (process-status process) 'run))
             (order (process-get process :order)))
    (parcel--update-order-info order (process-get process :result) 'blocked)))

(defun parcel--process-filter (process output &optional pattern status)
  "Filter PROCESS OUTPUT.
PATTERN is a string which is checked against the entire process output.
If it matches, the order associated with process has its STATUS updated."
  (process-put process :raw-output (concat (process-get process :raw-output) output))
  (let* ((order  (process-get process :order))
         (result (process-get process :result))
         (timer  (process-get process :timer))
         (lines  (split-string (concat result output) parcel-process-newline-regexp))
         (last-is-full-line-p (string-empty-p (car (last lines)))))
    (when timer (cancel-timer timer))
    (process-put process :timer (run-at-time parcel--process-busy-interval nil
                                             (lambda () (parcel--process-busy process))))
    (unless last-is-full-line-p
      (process-put process :result (car (last lines)))
      (setq lines (butlast lines)))
    (dolist (line lines)
      (unless (string-empty-p line)
        (parcel--update-order-info
         order line
         (when (and pattern (string-match-p pattern line))
           status))))
    (when (and pattern (string-match-p pattern output))
      (process-put process :result nil)
      (if (eq status 'failed)
          (parcel--fail-order order output)
        (parcel--update-order-info order output status)))))

(defun parcel--compile-info-process-sentinel (process event)
  "Sentinel for info compilation PROCESS EVENT."
  (let ((order  (process-get process :order)))
    (parcel--update-order-info
     order (if (equal event "finished\n")
               "Info compiled"
             (format "Failed to compile Info: %S" (string-trim event))))
    (parcel--run-next-build-step order)))

(defun parcel--compile-info (order)
  "Compile ORDER's .texi files."
  (parcel--update-order-info order "Compiling Info files" 'info)
  (if-let ((files
            (cl-loop for (repo-file . build-file) in
                     (or (parcel-order-files order)
                         (setf (parcel-order-files order) (parcel--files order)))
                     for f = (when-let (((string-match-p "\\.texi\\(nfo\\)?$" repo-file))
                                        (info (concat (file-name-sans-extension build-file) ".info"))
                                        ((not (file-exists-p info))))
                               (list repo-file "-o" info))
                     when f collect f))
           (command `(,parcel-makeinfo-executable ,@(apply #'append files)))
           (process (make-process
                     :name (format "parcel-compile-info-%s" (parcel-order-package order))
                     :command command
                     :filter   #'parcel--process-filter
                     :sentinel #'parcel--compile-info-process-sentinel)))
      (process-put process :order order)
    (parcel--update-order-info order "No .info files found")
    (parcel--remove-build-steps order '(parcel--install-info parcel--add-info-path))
    (parcel--run-next-build-step order)))

;;@TODO: make async
(defun parcel--install-info (order)
  "Install ORDER's info files."
  (parcel--update-order-info order "Installing Info files")
  (when-let ((dir (expand-file-name "dir" (parcel-order-build-dir order)))
             ((not (file-exists-p dir))))
    (cl-loop for (repo-file . build-file) in
             (or (parcel-order-files order)
                 (setf (parcel-order-files order) (parcel--files order)))
             for f = (cond
                      ((string-match-p "\\.info$" build-file) build-file)
                      ((string-match-p "\\.texi\\(nfo\\)?$" repo-file)
                       (concat (file-name-sans-extension build-file) ".info")))
             when (and f (file-exists-p f))
             do (parcel-with-process
                    (parcel-process-call parcel-install-info-executable f dir)
                  (unless success (parcel--update-order-info order result)))))
  (parcel--run-next-build-step order))

(defun parcel--dispatch-build-commands-process-sentinel (process event)
  "PROCESS EVENT."
  (let ((order (process-get process :order))
        (type  (process-get process :build-type)))
    (cond
     ((equal event "finished\n")
      (parcel--update-order-info order
                                 (format "%s steps finished" type)
                                 (intern (substring (symbol-name type) 1)))
      (parcel--run-next-build-step order))
     ((string-match-p "abnormally" event)
      (parcel--fail-order
       order
       ;; We want the event prior to the last "exited abnormally" event.
       (nth 2 (car (last (parcel-order-log order) 2))))))))

(defun parcel--dispatch-build-commands (order type)
  "Run ORDER's TYPE commands for.
TYPE is either the keyword :pre-build, or :post-build.
Each command is either an elisp form to be evaluated or a list of
strings to be executed in a shell context of the form:

  (\"executable\" \"arg\"...)

Commands are exectued in the ORDER's repository directory.
The keyword's value is expected to be one of the following:

  - A single command
  - A list of commands
  - nil, in which case no commands are executed.
    Note if :build is nil, :pre/post-build commands are not executed."
  (if-let ((recipe   (parcel-order-recipe order))
           (commands (plist-get recipe type)))
      (progn
        (parcel--update-order-info order (format "Running %S commands" type))
        (let* ((default-directory (parcel-order-repo-dir order))
               (emacs             (parcel--emacs-path))
               (program           `(progn
                                     (require 'parcel)
                                     (normal-top-level-add-subdirs-to-load-path)
                                     (parcel--run-build-commands ',commands)))
               (process (make-process
                         :name (format "parcel-%s-%s" type (plist-get recipe :package))
                         :command (list
                                   emacs "-Q"
                                   "-L" "./"
                                   "-L" (expand-file-name "repos/parcel/" parcel-directory)
                                   "--batch"
                                   "--eval" (let (print-level print-length)
                                              (format "%S" program)))
                         :filter   #'parcel--process-filter
                         :sentinel #'parcel--dispatch-build-commands-process-sentinel)))
          (process-put process :order order)
          (process-put process :build-type type)))
    (parcel--run-next-build-step order)))

(defun parcel--run-pre-build-commands (order)
  "Run ORDER's :pre-build commands."
  (parcel--dispatch-build-commands order :pre-build))

(defun parcel--run-post-build-commands (order)
  "Run ORDER's :post-build commands."
  (parcel--dispatch-build-commands order :post-build))

;;@HACK: It seems like `directory-files-recursively' is a little slow because it
;;covers all sorts of general edge cases. e.g. tramp remote files. We shouldn't
;;need that here.
(defun parcel--directory-files-recursively (directory regexp)
  "Return DIRECTORY files matching REGEXP."
  (let ((default-directory (expand-file-name directory)))
    (flatten-tree
     (cl-loop for file in (directory-files ".")
              unless (member file '("." ".." ".git"))
              collect (if (file-directory-p file)
                          (unless (file-symlink-p file)
                            (parcel--directory-files-recursively file regexp))
                        (when (string-match-p regexp file) (expand-file-name file)))))))

(defun parcel--dependencies (order)
  "Return a list of ORDER's dependencies."
  (or (mapcar (lambda (o) (cons (cadr o) nil)) (parcel-order-dependencies order))
      (let* ((default-directory (parcel-order-repo-dir order))
             (package (file-name-sans-extension (parcel-order-package order)))
             (name (concat package ".el"))
             (regexp (concat "^" name "$"))
             (main (or
                    (plist-get (parcel-order-recipe order) :main)
                    (cl-some (lambda (f) (let ((e (expand-file-name f)))
                                           (and (file-exists-p e) e)))
                             (list (concat package "-pkg.el")
                                   name
                                   (concat "./lisp/" name)
                                   (concat "./elisp/" name)))
                    (car (directory-files default-directory nil regexp))
                    (car (parcel--directory-files-recursively default-directory regexp))
                    ;; Best guess if there is no file matching the package name...
                    (car (directory-files default-directory nil "\\.el$" 'nosort))
                    (error "Unable to find main elisp file for %S" package))))
        (unless (file-exists-p default-directory)
          (error "Package repository not on disk: %S" (parcel-order-recipe order)))
        (with-temp-buffer
          (insert-file-contents-literally main)
          (goto-char (point-min))
          (if (string-suffix-p "-pkg.el" main)
              (eval (nth 4 (read (current-buffer))))
            (let ((case-fold-search t))
              (when (re-search-forward parcel--package-requires-regexp nil 'noerror)
                (condition-case err
                    ;; Replace comment delimiters in multi-line package-requires metadata.
                    (read (replace-regexp-in-string ";" "" (match-string 1)))
                  ((error)
                   (error "Unable to parse %S Package-Requires metadata: %S" main err))))))))))

;;@DECOMPOSE: The body of this function is similar to `parcel--clone-dependencies'.
;; Refactor into a macro to operate on dependencies?
(defun parcel--queue-dependencies (order)
  "Queue ORDER's dependencies."
  (parcel--update-order-info order "Queueing Dependencies" 'queueing-deps)
  (let* ((dependencies (or (parcel-order-dependencies order)
                           (parcel--dependencies order)))
         (orders       (parcel--queued-orders))
         (queued-deps
          (cl-loop for (dependency . _) in dependencies
                   unless (memq dependency parcel-ignored-dependencies)
                   for dep-order = (or (parcel-alist-get dependency orders)
                                       (parcel--queue-order dependency))
                   when dep-order do
                   (progn
                     (cl-pushnew dep-order (parcel-order-dependencies order))
                     (cl-pushnew order (parcel-order-dependents dep-order)))
                   when dep-order collect dep-order)))
    (if queued-deps
        ;; We do this in two steps so that ORDER is aware of all its
        ;; dependencies before any single dependency starts its build.
        ;; Otherwise a dependency may finish prior to other dependencies being
        ;; registered. This will cause the dependent order to become unblocked
        ;; multiple times and run its build steps simultaneously/out of order.
        (mapc #'parcel--run-next-build-step queued-deps)
      (parcel--update-order-info order "No external dependencies detected")
      (parcel--run-next-build-step order))))

;;@TODO: fix possible race similar to queue--dependencies.
(defun parcel--clone-dependencies (order)
  "Clone ORDER's dependencies."
  (parcel--update-order-info order "Cloning Dependencies" 'cloning-deps)
  (let* ((dependencies (parcel--dependencies order))
         (externals    (let ((seen))
                         (cl-loop for dependency in dependencies
                                  for item = (car dependency)
                                  unless (or (memq item parcel-ignored-dependencies)
                                             (memq item seen))
                                  collect dependency
                                  do (push item seen)))))
    (if-let ((emacs (assoc 'emacs dependencies))
             ((version< emacs-version (cadr emacs))))
        (parcel--fail-order order (format "Requires %S; running %S" emacs emacs-version))
      (if externals
          ;;@TODO: Major Version conflict checks?
          (let ((finished 0))
            (dolist (spec externals)
              (let* ((dependency (car spec))
                     (queued     (parcel-alist-get dependency (parcel--queued-orders)))
                     (dep-order  (or queued (parcel--queue-order dependency)))
                     (included   (member dep-order (parcel-order-includes order)))
                     (blocked    (eq (parcel-order-status dep-order) 'blocked)))
                (cl-pushnew dep-order (parcel-order-dependencies order))
                (cl-pushnew order (parcel-order-dependents dep-order))
                (if queued
                    (when (eq (parcel-order-status queued) 'finished) (cl-incf finished))
                  (if included
                      ;; Unblock dependency published in same repo...
                      (when blocked (parcel--clone-dependencies dep-order))
                    (unless blocked (parcel--run-next-build-step dep-order))))))
            (when (= (length externals) finished) ; Our dependencies beat us to the punch
              (parcel--run-next-build-step order)))
        (parcel--update-order-info order "No external dependencies detected")
        (parcel--run-next-build-step order)))))

(defun parcel--checkout-ref-process-sentinel (process event)
  "PROCESS EVENT."
  (when-let (((equal event "finished\n"))
             (order             (process-get process   :order))
             (recipe            (parcel-order-recipe   order))
             (default-directory (parcel-order-repo-dir order)))
    (let* ((remotes (plist-get recipe :remotes))
           (remote (parcel--first remotes))
           (ref (plist-get recipe :ref))
           (tag (plist-get recipe :tag))
           (branch (or (plist-get (cdr-safe (car-safe remotes)) :branch)
                       (plist-get recipe :branch)))
           (target (or ref tag branch)))
      (when target
        (parcel-with-process
            (apply #'parcel-process-call
                   `("git"
                     ,@(cond
                        (ref    (list "checkout" ref))
                        (tag    (list "checkout" (concat ".git/refs/tags/" tag)))
                        (branch (list "switch" "-C" branch
                                      (format "%s/%s" (parcel--first remote) branch))))))
          (unless success
            (parcel--fail-order
             order (format "Unable to check out ref: %S " (string-trim stderr))))))
      (unless (eq (parcel-order-status order) 'failed)
        (parcel--update-order-info
         order
         (if target (format "%S ref checked out" target) "Default ref checked out")
         'ref-checked-out)
        (parcel--run-next-build-step order)))))

(defun parcel--checkout-ref (order)
  "Checkout ORDER's :ref.
The :branch and :tag keywords are syntatic sugar and are handled here, too."
  (parcel--update-order-info order "Checking out repo ref")
  (let* ((default-directory (parcel-order-repo-dir order))
         (package           (parcel-order-package order))
         (recipe            (parcel-order-recipe order))
         (ref               (plist-get recipe :ref))
         (remotes           (plist-get recipe :remotes))
         (branch            (or (plist-get (cdr-safe (car-safe remotes)) :branch)
                                (plist-get recipe :branch)))
         (tag               (plist-get recipe :tag)))
    (unless remotes (signal 'wrong-type-argument `((stringp listp) ,remotes ,recipe)))
    (when (or ref branch tag)
      (cond
       ((and ref branch) (warn "Recipe :ref overriding :branch %S" recipe))
       ((and ref tag)    (warn "Recipe :ref overriding :tag %S" recipe))
       ((and tag branch) (error "Recipe :ref ambiguous :tag and :branch %S" recipe))))
    (let* ((process
            (make-process
             :name     (format "parcel-fetch-%s" package)
             :command  '("git" "fetch" "--all")
             :filter   (lambda (process output)
                         (parcel--process-filter process output "fatal" 'failed))
             :sentinel #'parcel--checkout-ref-process-sentinel)))
      (process-put process :order order)
      (setf (parcel-order-process order) process))))

(defun parcel--order-check-status (order)
  "Called when one of an ORDER's dependencies have changed status.
Possibly kicks off next build step, or changes order status."
  (unless (eq (parcel-order-status order) 'finished)
    (let (failed blocked)
      (cl-loop for dep-order in (parcel-order-dependencies order)
               for status = (parcel-order-status dep-order)
               unless (eq status 'finished)
               do (if (eq status 'failed)
                      (push (parcel-order-package dep-order) failed)
                    (push (parcel-order-package dep-order) blocked)))
      (cond
       (failed (parcel--fail-order order (format "Failed dependencies: %S" failed)))
       (blocked (parcel--update-order-info
                 order (format "Blocked by dependencies: %s" blocked) 'blocked))
       (t (parcel--run-next-build-step order))))))

(defun parcel--clone-process-sentinel (process _event)
  "Sentinel for clone PROCESS."
  (let ((order      (process-get process :order))
        (raw-output (process-get process :raw-output)))
    (if (and (string-match-p "fatal" raw-output)
             (not (string-match-p "already exists" raw-output)))
        (parcel--fail-order order (nth 2 (car (parcel-order-log order))))
      (parcel--run-next-build-step order))))

(defun parcel--clone (order)
  "Clone repo to `parcel-directory' from ORDER.
If FORCE is non-nil, ignore order queue."
  (let* ((recipe  (parcel-order-recipe order))
         (package (plist-get recipe :package))
         (depth   (plist-get recipe :depth))
         (repodir (parcel-order-repo-dir order))
         (URI     (parcel--repo-uri recipe))
         (default-directory parcel-directory))
    (push 'cloning (parcel-order-statuses order))
    (let ((process
           (make-process
            :name     (format "parcel-clone-%s" package)
            :command  `("git" "clone"
                        ;;@TODO: certain refs will necessitate full clone
                        ;; or specific branch...
                        ,@(when depth (list "--depth" (number-to-string depth)
                                            "--no-single-branch"))
                        ,URI ,repodir)
            :filter   (lambda (process output)
                        (parcel--process-filter
                         process output
                         "\\(?:^\\(?:Password\\|Username\\|passphrase\\)\\)" 'blocked))
            :sentinel #'parcel--clone-process-sentinel)))
      (process-put process :order order)
      (setf (parcel-order-process order) process))))

(defun parcel-generate-autoloads (package dir)
  "Generate autoloads in DIR for PACKAGE."
  (let* ((auto-name (format "%s-autoloads.el" package))
         (output    (expand-file-name auto-name dir))
         (autoload-timestamps nil)
         (backup-inhibited t)
         (version-control 'never)
         ;; Prevents spurious parens in autoloads
         (left-margin 0))
    (unless (file-exists-p output)
      (require 'autoload)
      (let ((generated-autoload-file output)
            (find-file-hook nil) ;; Don't clobber recentf
            (write-file-functions nil))
        (write-region (autoload-rubric output nil 'feature) nil output nil 'silent)
        (if (fboundp 'make-directory-autoloads)
            (make-directory-autoloads dir output)
          ;; Compatibility for Emacs < 28.1
          (with-no-warnings (update-directory-autoloads dir)))))
    (when-let ((buf (find-buffer-visiting output)))
      (kill-buffer buf))
    auto-name))

(defun parcel--generate-autoloads-async-process-sentinel (process event)
  "PROCESS autoload generation EVENT."
  (when (equal event "finished\n")
    (let ((order  (process-get process :order)))
      (unless (eq (parcel-order-status order) 'failed)
        (parcel--update-order-info order "Autoloads Generated")
        (parcel--run-next-build-step order)))))

(defun parcel--generate-autoloads-async (order)
  "Generate ORDER's autoloads.
Async wrapper for `parcel-generate-autoloads'."
  (parcel--update-order-info order "Generating autoloads" 'autoloads)
  (let* ((emacs             (parcel--emacs-path))
         (package           (parcel-order-package  order))
         (build-dir         (parcel-order-build-dir order))
         (default-directory build-dir)
         (parcel            (expand-file-name "repos/parcel/" parcel-directory))
         (command
          (list emacs "-Q"
                "-L" parcel
                "-L" build-dir ; Is this necessary?
                "-l" (expand-file-name "parcel.el" parcel)
                "--batch" "--eval"
                (format "(parcel-generate-autoloads %S %S)" package build-dir)))
         (process
          (make-process
           :name     (format "parcel-autoloads-%s" package)
           :command  command
           :filter   #'parcel--process-filter
           :sentinel #'parcel--generate-autoloads-async-process-sentinel)))
    (process-put process :order order)))

(defun parcel--activate-package (order)
  "Activate ORDER's package."
  (parcel--update-order-info order "Activating package" 'activation)
  (let* ((build-dir (parcel-order-build-dir order))
         (default-directory build-dir)
         (package           (parcel-order-package order))
         (autoloads         (expand-file-name (format "%s-autoloads.el" package))))
    (cl-pushnew default-directory load-path)
    ;;@TODO: condition on a slot we set on the order to indicate cached recipe?
    (parcel--update-order-info order "Package build dir added to load-path")
    (if (and parcel-cache-autoloads (file-exists-p autoloads))
        (let ((forms nil))
          (parcel--update-order-info order "Caching autoloads")
          (with-temp-buffer
            (insert-file-contents autoloads)
            (goto-char (point-min))
            (condition-case _
                (while t (push (read (current-buffer)) forms))
              ((end-of-file)))
            (push `(let ((load-file-name ,autoloads)
                         (load-in-progress t)
                         (package ,package))
                     (condition-case err
                         (eval '(progn ,@(nreverse forms)) t)
                       ((error) (warn "Error loading %S autoloads: %S" package err))))
                  (parcel-queue-autoloads (car (last parcel--queues (1+ (parcel-order-queue-id order)))))))
          (parcel--update-order-info order "Autoloads cached"))
      (condition-case err
          (progn
            (load autoloads nil 'nomessage)
            (parcel--update-order-info order "Package activated" 'activated))
        ((error) (parcel--update-order-info
                  order (format "Failed to load %S: %S" autoloads err) 'failed-to-activate))))
    (parcel--run-next-build-step order)))

(defun parcel--byte-compile-process-sentinel (process event)
  "PROCESS byte-compilation EVENT."
  (when-let (((equal event "finished\n"))
             (order (process-get process :order))
             ((not (eq (parcel-order-status order) 'failed))))
    (parcel--update-order-info order "Successfully byte compiled")
    (parcel--run-next-build-step order)))

(defun parcel--byte-compile (order)
  "Byte compile package from ORDER."
  ;; Assumes all dependencies are 'built
  (parcel--update-order-info order "Byte compiling" 'byte-compilation)
  (let* ((build-dir         (parcel-order-build-dir order))
         (default-directory build-dir)
         (emacs             (parcel--emacs-path))
         (dependency-dirs
          (cl-loop for item in (parcel-dependencies (intern (parcel-order-package order))
                                                    parcel-ignored-dependencies)
                   when item
                   for build-dir = (parcel-order-build-dir (parcel-alist-get item (parcel--queued-orders)))
                   when build-dir
                   collect build-dir))
         (program `(progn
                     (mapc (lambda (dir) (let ((default-directory dir))
                                           (add-to-list 'load-path dir)
                                           (normal-top-level-add-subdirs-to-load-path)))
                           ',(append dependency-dirs (list build-dir)))
                     (byte-recompile-directory ,build-dir 0 'force)))
         (print-level nil)
         (print-circle nil)
         (process
          (make-process
           :name     (format "parcel-byte-compile-%s" (parcel-order-package order))
           :command  `(,emacs "-Q" "--batch" "--eval" ,(format "%S" program))
           :filter   #'parcel--process-filter
           :sentinel #'parcel--byte-compile-process-sentinel)))
    (process-put process :order order)))

(defun parcel-dependencies (item &optional ignore recurse)
  "Return recursive list of ITEM's dependencies.
IGNORE may be a list of symbols which are not included in the resulting list.
RECURSE is used to track recursive calls."
  (if-let ((order (or (parcel-alist-get item (parcel--queued-orders))
                      (unless (member item parcel-ignored-dependencies)
                        (parcel-order-create item))))
           (dependencies (parcel--dependencies order)))
      (let ((transitives (cl-loop for dependency in dependencies
                                  for name = (car dependency)
                                  unless (memq name ignore)
                                  collect
                                  (cons name (parcel-dependencies name ignore 'recurse)))))
        (delete-dups (flatten-tree transitives)))
    (when recurse item)))

(defun parcel-dependents (item &optional recurse)
  "Return recursive list of packages which depend on ITEM.
RECURSE is used to keep track of recursive calls."
  (if-let ((order (parcel-alist-get item (parcel--queued-orders)))
           (dependents (parcel-order-dependents order)))
      (let ((transitives (cl-loop for dependent in dependents
                                  collect
                                  (let ((i (intern (parcel-order-package dependent))))
                                    (cons i (parcel-dependents i 'recurse))))))
        (delete-dups (nreverse (flatten-tree transitives))))
    (when recurse item)))

;;;; COMMANDS/MACROS
;;;###autoload
(defmacro parcel (order &rest body)
  "Install ORDER, then execute BODY.
If ORDER is `nil`, defer BODY until orders have been processed."
  (when (equal 'quote (car-safe order)) (setq order (cadr order)))
  (declare (indent 1))
  `(progn
     ,@(when body
         (list `(push ',(cons (parcel--first order) body)
                      (parcel-queue-forms (car parcel--queues)))))
     ,@(unless (null order) (list `(parcel--queue-order
                                    ,(if (equal '\` (car-safe order))
                                         order
                                       (list 'quote order)))))))

;;;###autoload
(defmacro parcel-use-package (order &rest body)
  "Execute BODY in `use-package' declartion after ORDER is finished.
If the :disabled keyword is present in body, the package is completely ignored.
This happens regardless of the value associated with :disabled.
The expansion is a string indicating the package has been disabled."
  (declare (indent 1))
  (if (memq :disabled body)
      (format "%S :disabled by parcel-use-package" order)
    `(parcel ,order (use-package ,(parcel--first order) ,@body))))

;;;###autoload
(defun parcel-try-package (&rest orders)
  "Try ORDERS.
Install the repo/build files on disk.
Activate the corresponding package for the current session.
ORDER's package is not made available during subsequent sessions."
  (interactive (list
                (let ((recipe (parcel-menu-item
                               nil nil nil
                               (lambda (candidate)
                                 (not (parcel-alist-get (car candidate)
                                                        (parcel--queued-orders)))))))
                  (append (list (intern (plist-get recipe :package)))
                          recipe))))
  (setq parcel-cache-autoloads nil)
  (parcel-status)
  (dolist (order orders)
    ;;@FIX: wasteful to pad out the order to make it QUEUED.
    (parcel--process-order (cons (parcel--first order) (parcel--queue-order order)))))

(defun parcel--process-order (queued)
  "Process QUEUED order."
  (let ((order (cdr queued)))
    (unless (memq (parcel-order-status order) '(failed blocked))
      (parcel--run-next-build-step order))))

(defun parcel--process-queue (queue)
  "Process orders in QUEUE."
  (mapc #'parcel--process-order (reverse (parcel-queue-orders queue))))

;;@TODO: This could be generalized to find the first incomplete queue and start there.
;;;###autoload
(defun parcel-process-init ()
  "Process init file queues."
  (parcel--process-queue (car (last parcel--queues))))

(defun parcel--order-on-disk-p (item)
  "Return t if ITEM has an associated order and a build or repo dir on disk."
  (when-let ((order (parcel-alist-get item (parcel--queued-orders))))
    (or (file-exists-p (parcel-order-repo-dir order))
        (file-exists-p (parcel-order-build-dir order)))))
;;@INCOMPLETE: We need to determine policy for deleting dependencies.
;; Maybe skip dependencies which weren't declared or dependencies of a declared order.

;;;###autoload
(defun parcel-delete-package (force with-deps &optional package asker)
  "Remove a PACKAGE from all caches and disk.
If WITH-DEPS is non-nil dependencies other than ASKER are deleted.
If FORCE is non-nil do not confirm before deleting."
  (when (or force (yes-or-no-p (format "Delete package %S?" package)))
    (if-let ((order (parcel-alist-get package (parcel--queued-orders))))
        (let ((repo-dir      (parcel-order-repo-dir  order))
              (build-dir     (parcel-order-build-dir order))
              (dependents    (delq asker (parcel-dependents package)))
              (dependencies  (when with-deps
                               (parcel-dependencies package parcel-ignored-dependencies))))
          (if (cl-some #'parcel--order-on-disk-p dependents)
              (message "Cannot delete %S unless dependents %S are deleted first"
                       package dependents)
            (when (file-exists-p repo-dir)  (delete-directory repo-dir  'recursive))
            (when (file-exists-p build-dir) (delete-directory build-dir 'recursive))
            (dolist (queue parcel--queues)
              (setf (parcel-queue-orders queue)
                    (cl-remove package (parcel-queue-orders queue) :key #'car)))
            (when (equal (buffer-name) parcel-status-buffer) (parcel-status))
            (message "Deleted package %S" package)
            (when with-deps
              (dolist (dependency dependencies)
                (parcel-delete-package 'force with-deps dependency package)))))
      (if-let ((recipe (parcel-recipe package)))
          (progn
            (when-let ((repo-dir (parcel-repo-dir recipe))) (delete-directory repo-dir 'recursive))
            (when-let ((build-dir (parcel-build-dir recipe))) (delete-directory build-dir 'recursive)))
        (user-error "%S not a queued order" package)))))

;;;###autoload
(defun parcel-rebuild-package (item &optional hide)
  "Rebuild ITEM's associated package.
If HIDE is non-nil, do not display `parcel-status-buffer'."
  (interactive
   (list (let ((item
                (completing-read "Rebuild package: "
                                 (sort (mapcar #'car (parcel--queued-orders)) #'string<)
                                 nil 'require-match)))
           (if (string-empty-p item)
               (user-error "No package selected")
             (intern item)))))
  (if-let ((queued (assoc item (parcel--queued-orders))))
      (let ((order (cdr queued)))
        (parcel--update-order-info order "Rebuilding" 'rebuilding)
        (setq parcel-cache-autoloads nil)
        (setf (parcel-order-build-steps order)
              (cl-remove #'parcel--clone-dependencies
                         (copy-tree parcel-build-steps)))
        (setf (parcel-order-queue-time order) (current-time))
        (parcel--process-order queued)
        (unless hide (parcel-status)))
    (user-error "Package %S has no queued order" item)))

(defun parcel--log-updates-process-sentinel (process event)
  "Handle PROCESS EVENT."
  (when (equal event "finished\n")
    (let ((order (process-get process :order)))
      (parcel--update-order-info order "End Update log" 'updates-logged)
      (parcel--run-next-build-step order))))

;;@INCOMPLETE:
;; What do we actually want to log here?
;; If the user is on a different branch which has an upstream?
;; Or do we strictly log the difference between the recipe's declared ref and upstream?
;; Probably the latter, because that's the only case we can automatically update.
;; Anything else will require user intervention. ~ NV [2022-03-03]
(defun parcel--log-updates (order)
  "Log ORDER's fetched commits."
  (parcel--update-order-info order "Start Update log" 'log-updates)
  (let* ((default-directory (parcel-order-repo-dir order))
         (recipe (parcel-order-recipe order))
         (remotes (plist-get recipe :remotes))
         (remote (parcel--first remotes))
         (process (make-process
                   :name (format "parcel-log-updates-%s" (parcel-order-package order))
                   ;; Pager will break this process. Complains about terminal functionality.
                   :command
                   (list "git" "--no-pager" "log" (parcel--first remote) "..." "HEAD")
                   :filter   #'parcel--process-filter
                   :sentinel #'parcel--log-updates-process-sentinel)))
    (process-put process :order order)))

(defun parcel--fetch-process-sentinel (process event)
  "Handle PROCESS EVENT."
  (when (equal event "finished\n")
    (let ((order (process-get process :order)))
      (parcel--update-order-info order "Updates fetched" 'updates-fetched)
      (parcel--run-next-build-step order))))

(defun parcel--fetch (order)
  "Fetch ORDER's remote's commits."
  (let* ((default-directory (parcel-order-repo-dir order))
         (process (make-process
                   :name (format "parcel-fetch-%s" (parcel-order-package order))
                   :command  '("git" "fetch" "--all")
                   :filter   #'parcel--process-filter
                   :sentinel #'parcel--fetch-process-sentinel)))
    (process-put process :order order)))

;;;###autoload
(defun parcel-fetch (item &optional hide)
  "Fetch ITEM's associated package remote commits.
This does not merge changes or rebuild the packages.
If HIDE is non-nil don't display `parcel-status-buffer'."
  (interactive
   (list (let ((item
                (completing-read "Fetch updates: "
                                 (sort (mapcar #'car (parcel--queued-orders)) #'string<)
                                 nil 'require-match)))
           (if (string-empty-p item)
               (user-error "No package selected")
             (intern item)))))
  (if-let ((queued (assoc item (parcel--queued-orders))))
      (let ((order (cdr queued)))
        (parcel--update-order-info order "Fetching updates" 'fetching-updates)
        (setf (parcel-order-build-steps order) (list #'parcel--fetch #'parcel--log-updates))
        (setf (parcel-order-queue-time order) (current-time))
        (parcel--process-order queued)
        (unless hide (parcel-status)))
    (user-error "Package %S has no queued order" item)))

;;;###autoload
(defun parcel-fetch-all (&optional hide)
  "Fetch remote commits for every queued order.
If HIDE is non-nil, do not show `parcel-status-buffer'."
  (interactive "P")
  (cl-loop for (item . _) in (cl-remove-duplicates (parcel--queued-orders) :key #'car)
           do (parcel-fetch item hide)))

;;; Lockfiles
(defun parcel-declared-p (item)
  "Return t if ITEM is declared in user's init file, nil otherwise."
  (when-let ((order (parcel-alist-get item (parcel--queued-orders))))
    (or (parcel-order-init order)
        (cl-loop for dependent in (parcel-dependents item)
                 when (parcel-alist-get dependent (parcel--queued-orders))
                 return t))))

(defun parcel-installed-p (item)
  "Return t if ITEM's associated repo directory is on disk, nil otherwise."
  (when-let ((order (parcel-alist-get item (parcel--queued-orders)))
             (repo-dir (parcel-order-repo-dir order))
             ((file-exists-p repo-dir)))
    t))

(defun parcel-worktree-dirty-p (item)
  "Return t if ITEM's associated repository has a dirty worktree, nil otherwise."
  (when-let ((order (parcel-alist-get item (parcel--queued-orders)))
             (recipe (parcel-order-recipe order))
             (repo-dir (parcel-order-repo-dir order))
             ((file-exists-p repo-dir))
             (default-directory repo-dir))
    (not (string-empty-p
          (parcel-process-output "git" "-c" "status.branch=false" "status" "--short")))))

;; @TODO Implement these:
;; (defun parcel-on-default-branch-p (item)
;;   (if-let ((order (parcel-alist-get item (parcel--queued-orders))))
;;       (let* ((default-directory (parcel-repo-dir order)))
;;         (
;;          ;;git ls-remote --symref REMOTE HEAD
;;          ;;git symbolic-ref HEAD  vs :branch
;;          ;; (defun parcel-ui--local-branch-behind-p (package)

(defun parcel-unshallow (item)
  "Convert ITEM's repo to an unshallow repository."
  (when-let ((order (or (alist-get item (parcel--queued-orders))
                        (user-error "%s has no queued order" item)))
             (repo-dir (or (parcel-order-repo-dir order)
                           (user-error "%s has no associated repo dir" item)))
             (default-directory repo-dir)
             ((or (equal
                   (string-trim
                    (parcel-process-output "git" "rev-parse" "--is-shallow-repository"))
                   "true")
                  (user-error "%s is not a shallwow repository" repo-dir)))
             (remotes (plist-get (parcel-order-recipe order) :remotes)))
    (cl-loop for remote in (if (stringp remotes) (list remotes) remotes)
             for name = (parcel--first remote)
             do
             (progn
               (parcel-process-call "git" "config" (format "remote.%s.fetch" name)
                                    (format "+refs/heads/*:refs/remotes/%s/*" name))
               (parcel-process-call "git" "fetch" "--unshallow" name)))))

(defun parcel-load-lockfile (&optional lockfile _force)
  "Load LOCKFILE.
If FORCE is non-nil,."
  (interactive "fLockfile: ")
  (message "%S" lockfile))

(defun parcel-write-lockfile (&optional path)
  "Write lockfile to PATH for current state of package repositories."
  (interactive "FWrite lockfile to: ")
  (unless path (user-error "Need file PATH"))
  (let* ((seen)
         (revisions
          (nreverse
           (cl-loop for queue in parcel--queues
                    append
                    (cl-loop for (item . order) in (parcel-queue-orders queue)
                             unless (member item seen)
                             for rev =
                             (let ((default-directory (parcel-order-repo-dir order)))
                               (parcel-with-process
                                   (parcel-process-call "git" "rev-parse" "HEAD")
                                 (when success (string-trim stdout))))
                             when rev
                             collect (cons item (plist-put (copy-tree (parcel-order-recipe order)) :ref rev))
                             do (push item seen))))))
    (parcel--write-file path (pp revisions))))

(provide 'parcel)
;;; parcel.el ends here
