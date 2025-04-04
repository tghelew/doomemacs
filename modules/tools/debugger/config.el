;;; tools/debugger/config.el -*- lexical-binding: t; -*-

(defvar +debugger--realgud-alist
  '((realgud:bashdb    :modes (sh-mode))
    (realgud:gdb)
    (realgud:gub       :modes (go-mode))
    (realgud:kshdb     :modes (sh-mode))
    (realgud:pdb       :modes (python-mode))
    (realgud:perldb    :modes (perl-mode perl6-mode))
    (realgud:rdebug    :modes (ruby-mode))
    (realgud:remake)
    (realgud:trepan    :modes (perl-mode perl6-mode))
    (realgud:trepan2   :modes (python-mode))
    (realgud:trepan3k  :modes (python-mode))
    (realgud:trepanjs  :modes (javascript-mode js2-mode js3-mode))
    (realgud:trepanpl  :modes (perl-mode perl6-mode raku-mode))
    (realgud:zshdb     :modes (sh-mode))))

(defvar +debugger--dap-alist
  `(
    ((:lang zig +lsp)        :after zls         :require (dap-lldb dap-gdb-lldb))
    ((:lang cc +lsp)         :after ccls        :require (dap-lldb dap-gdb-lldb))
    ((:lang elixir +lsp)     :after elixir-mode :require dap-elixir)
    ((:lang go +lsp)         :after go-mode     :require dap-dlv-go)
    ((:lang gdscript +lsp)   :after gdscript-mode :require dap-gdscript)
    ((:lang java +lsp)       :after java-mode   :require lsp-java)
    ((:lang php +lsp)        :after php-mode    :require dap-php)
    ((:lang python +lsp)     :after python      :require dap-python)
    ((:lang ruby +lsp)       :after ruby-mode   :require dap-ruby)
    ((:lang rust +lsp)       :after rustic      :require (dap-lldb dap-cpptools))
    ((:lang javascript +lsp)
     :after (js2-mode typescript-mode)
     :require (dap-node dap-chrome dap-firefox ,@(if (featurep :system 'windows) '(dap-edge)))))
  "TODO")


;;
;;; Packages

;;;###package gdb
(setq gdb-show-main t
      gdb-many-windows t)

(use-package! projectile-variable
  :defer t
  :commands (projectile-variable-put
             projectile-variable-get
             projectile-variable-alist
             projectile-variable-plist))

(use-package! realgud
  :defer t
  :init
  (use-package! realgud-trepan-ni
    :defer t
    :init (add-to-list '+debugger--realgud-alist
                       '(realgud:trepan-ni :modes (javascript-mode js2-mode js3-mode)
                                           :package realgud-trepan-ni)))

  ;; Realgud doesn't generate its autoloads properly so we do it ourselves
  (dolist (debugger +debugger--realgud-alist)
    (autoload (car debugger)
      (if-let* ((sym (plist-get (cdr debugger) :package)))
          (symbol-name sym)
        "realgud")
      nil t))

  :config
  (set-popup-rule! "^\\*\\(?:trepanjs:\\(?:g\\|zsh\\|bash\\)db\\|pdb \\)"
    :size 20 :select nil :quit nil)

  (defadvice! +debugger--cleanup-after-realgud-a (&optional buf)
    "Kill command buffer when debugging session ends (which closes its popup)."
    :after #'realgud:terminate
    (when (stringp buf)
      (setq buf (get-buffer buf)))
    (when-let (cmdbuf (realgud-get-cmdbuf buf))
      (let (kill-buffer-hook)
        (kill-buffer buf))))

  ;; Monkey-patch `realgud:run-process' to run in a popup.
  ;; TODO Find a more elegant solution
  ;; FIXME Causes realgud:cmd-* to focus popup on every invocation
  (defadvice! +debugger--realgud-open-in-other-window-a
    (debugger-name script-filename cmd-args minibuffer-history-var &optional no-reset)
    :override #'realgud:run-process
    (let* ((cmd-buf (apply #'realgud-exec-shell debugger-name script-filename
                           (car cmd-args) no-reset (cdr cmd-args)))
           (process (get-buffer-process cmd-buf)))
      (cond ((and process (eq 'run (process-status process)))
             (pop-to-buffer cmd-buf)
             (when (boundp 'evil-emacs-state-local-map)
               (define-key evil-emacs-state-local-map (kbd "ESC ESC") #'+debugger/quit))
             (realgud:track-set-debugger debugger-name)
             (realgud-cmdbuf-info-in-debugger?= 't)
             (realgud-cmdbuf-info-cmd-args= cmd-args)
             (when cmd-buf
               (switch-to-buffer cmd-buf)
               (when realgud-cmdbuf-info
                 (let* ((info realgud-cmdbuf-info)
                        (cmd-args (realgud-cmdbuf-info-cmd-args info))
                        (cmd-str  (mapconcat #'identity cmd-args " ")))
                   (if (boundp 'starting-directory)
                       (realgud-cmdbuf-info-starting-directory= starting-directory))
                   (set minibuffer-history-var
                        (cl-remove-duplicates (cons cmd-str (eval minibuffer-history-var))
                                              :from-end t))))))
            (t
             (if cmd-buf (switch-to-buffer cmd-buf))
             (message "Error running command: %s" (mapconcat #'identity cmd-args " "))))
      cmd-buf)))


(use-package! dap-mode
  :when (modulep! +lsp)
  :when (modulep! :tools lsp -eglot)
  :hook (dap-mode . dap-tooltip-mode)
  :init
  (setq dap-breakpoints-file (concat doom-data-dir "dap-breakpoints")
        dap-utils-extension-path (concat doom-data-dir "dap-extension/"))
  (after! lsp-mode (require 'dap-mode))
  :config
  (pcase-dolist (`((,category . ,modules) :after ,after :require ,libs)
                 +debugger--dap-alist)
    (when (doom-module-active-p category (car modules) (cadr modules))
      (dolist (lib (ensure-list after))
        (with-eval-after-load lib
          (mapc #'require (ensure-list libs))))))

  (dap-mode 1)

  (define-minor-mode +dap-running-session-mode
    "A mode for adding keybindings to running sessions"
    :init-value nil
    :keymap (make-sparse-keymap)
    (when (bound-and-true-p evil-mode)
      (evil-normalize-keymaps))  ; if you use evil, this is necessary to update the keymaps
    ;; The following code adds to the dap-terminated-hook so that this minor
    ;; mode will be deactivated when the debugger finishes
    (when +dap-running-session-mode
      (let ((session-at-creation (dap--cur-active-session-or-die)))
        (add-hook 'dap-terminated-hook
                  (lambda (session)
                    (when (eq session session-at-creation)
                      (+dap-running-session-mode -1)))))))

  ;; Activate this minor mode when dap is initialized
  (add-hook 'dap-session-created-hook #'+dap-running-session-mode)
  ;; Activate this minor mode when hitting a breakpoint in another file
  (add-hook 'dap-stopped-hook #'+dap-running-session-mode)
  ;; Activate this minor mode when stepping into code in another file
  (add-hook 'dap-stack-frame-changed-hook (lambda (session)
                                            (when (dap--session-running session)
                                              (+dap-running-session-mode 1))))

  (map! :localleader
        :map +dap-running-session-mode-map
        "d" #'dap-hydra))


(use-package! dap-ui
  :when (modulep! +lsp)
  :when (modulep! :tools lsp -eglot)
  :hook (dap-mode . dap-ui-mode)
  :hook (dap-ui-mode . dap-ui-controls-mode))
