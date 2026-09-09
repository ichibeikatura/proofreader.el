;;; proofreader.el --- Proofreading workflow with Antigravity CLI (agy) -*- lexical-binding: t; -*-

;; Author: ichibeikatura
;; URL: https://github.com/ichibeikatura/proofreader.el
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, writing, proofreading

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Emacs package for Japanese text proofreading using the Antigravity CLI (agy).
;;
;; Usage:
;;   1. M-x proofreader-send-buffer  - Send buffer to agy
;;   2. Edit generated replacements.json as needed
;;   3. M-x proofreader-apply        - Apply replacements from JSON
;;
;; Configuration:
;;   (setq proofreader-model "Gemini 3.7 Flash (Medium)")
;;   (setq proofreader-json-filename "replacements.json")
;;
;; Note: the former Gemini CLI was retired for individual use on 2026-06-18.
;; This package now drives its successor, the Antigravity CLI (command `agy`),
;; via your Gemini AI Pro OAuth login.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup proofreader nil
  "Proofreading with the Antigravity CLI (agy)."
  :group 'tools
  :prefix "proofreader-")

(defcustom proofreader-command "agy"
  "Command to invoke the Antigravity CLI.
If Emacs cannot find it on `exec-path' (e.g. when launched from the GUI),
set this to an absolute path or fix `exec-path' (e.g. exec-path-from-shell)."
  :type 'string
  :group 'proofreader)

(defcustom proofreader-model "Gemini 3.7 Flash (Medium)"
  "Model to use with agy.
This must match a name listed by `agy models' verbatim (including spaces
and the parenthesized thinking level), since it is passed straight to
`agy --model'."
  :type 'string
  :group 'proofreader)

(defcustom proofreader-json-filename "replacements.json"
  "Filename for replacement JSON output."
  :type 'string
  :group 'proofreader)

(defcustom proofreader-prompt-template
  "以下のテキストを校正してください。

## 修正してよいもの
- 明らかな誤字・脱字（入力ミスと断定できるもの）
- IME変換ミス（同じ読みで誤った漢字になった場合）
- 入力ミスに起因する「てにをは」の脱落・重複

## 修正しないもの（絶対禁止）
- 語句の言い換え・置き換え（例：「今一番」→「アンコール」のような交換は禁止。たとえ意味が近くても不可）
- 歴史的仮名遣い、旧字体、方言、古風・時代的な表現
- Markdown形式の引用文（> で始まる行）
- 固有名詞、史実・時代背景に関する記述
- 文体・語彙・表現スタイル
- 漢字を無理にひながなにしない
- 意図的かどうか判断できないもの

## 原則
疑わしいときは修正しない。原文の語句を別の語句に置き換えることは禁止。
修正の数は評価対象とならない。正確性と慎重さを重視する。

## 出力形式
JSONのみを出力してください。説明文や```json```マークダウンは不要です。

[
  {\"old\": \"原文の修正箇所（一字一句変えずコピー）\", \"new\": \"修正後\", \"reason\": \"理由(簡潔に)\"}
]

修正箇所がない場合は [] を出力してください。

---
対象テキスト：

%s"
  "Prompt template for proofreading. %s is replaced with buffer content."
  :type 'string
  :group 'proofreader)

(defvar proofreader--process nil
  "Current agy process.")

(defvar proofreader--output-buffer nil
  "Buffer for agy stdout.")

(defvar proofreader--source-buffer nil
  "Source buffer being proofread.")

(defvar proofreader--json-path nil
  "Path to output JSON file.")

(defvar proofreader--stderr-buffer nil
  "Buffer for agy stderr output.")

(defvar proofreader--prompt nil
  "Prompt of the current run, kept so it can be retried.")

(defvar proofreader--retried nil
  "Non-nil once the current run has been retried with a fallback model.")

(defvar proofreader--models-cache nil
  "Models `agy models' last reported, or nil when it has not been asked yet.
The command goes over the network and takes a couple of seconds, so the
list is kept for the rest of the session; see `proofreader--list-models'.")

(defun proofreader--get-json-path ()
  "Get path for replacements.json in current buffer's directory."
  (let ((dir (or (and buffer-file-name
                      (file-name-directory buffer-file-name))
                 default-directory)))
    (expand-file-name proofreader-json-filename dir)))

(defun proofreader--build-prompt (text)
  "Build prompt with TEXT."
  (format proofreader-prompt-template text))

(defun proofreader--extract-json (output)
  "Extract the first valid JSON array from OUTPUT.
Tolerates surrounding text, agent chrome, and Markdown code fences that
agy may emit around the JSON.  Returns the JSON substring, or nil."
  (let ((text (replace-regexp-in-string "```\\(?:json\\)?" "" output)))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((result nil))
        ;; Scan each '[' and accept the first span that parses as a JSON array.
        (while (and (not result)
                    (re-search-forward "\\[" nil t))
          (let ((bracket (match-beginning 0)))
            (goto-char bracket)
            (condition-case nil
                (let ((val (json-parse-buffer :array-type 'array)))
                  (when (arrayp val)
                    (setq result
                          (buffer-substring-no-properties bracket (point)))))
              (error
               ;; Not valid JSON here; resume searching past this bracket.
               (goto-char (1+ bracket))))))
        result))))

(defun proofreader--fetch-models ()
  "Run `agy models' and return an alist of (SLUG . DISPLAY).
Returns nil when the command fails or prints nothing usable."
  (with-temp-buffer
    (when (eq 0 (call-process proofreader-command nil (list t nil) nil "models"))
      (goto-char (point-min))
      (let (models)
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            ;; Each entry is "slug<TAB>Display Name"; other chatter has no tab.
            (when (string-match "\\`\\([^\t]+\\)\t\\(.+\\)\\'" line)
              (push (cons (match-string 1 line) (match-string 2 line)) models)))
          (forward-line 1))
        (nreverse models)))))

(defun proofreader--list-models (&optional refresh)
  "Return the models `agy models' reports, as an alist of (SLUG . DISPLAY).
The list is cached for the session; with non-nil REFRESH, ask agy again.
A failed lookup is not cached, so the next call retries."
  (when (or refresh (null proofreader--models-cache))
    (setq proofreader--models-cache (proofreader--fetch-models)))
  proofreader--models-cache)

(defun proofreader--model-parts (name)
  "Split model NAME into a list (WORDS VERSION LEVEL).
For \"Gemini 3.7 Flash (Medium)\" that is ((\"Gemini\" \"Flash\") \"3.7\" \"Medium\")."
  (let* ((level (when (string-match "(\\([^()]+\\))[ \t]*\\'" name)
                  (match-string 1 name)))
         (base (if level (substring name 0 (match-beginning 0)) name))
         (tokens (split-string base "[ \t]+" t))
         (numberp (lambda (tk) (string-match-p "\\`[0-9][0-9.]*\\'" tk))))
    (list (seq-remove numberp tokens)
          (seq-find numberp tokens)
          level)))

(defun proofreader--version-lessp (a b)
  "Return non-nil if version string A sorts before B, treating nil as lowest."
  (cond ((null b) nil)
        ((null a) t)
        (t (ignore-errors (version< a b)))))

(defun proofreader--pick-fallback-model (desired models)
  "Pick the entry of MODELS closest to DESIRED, or nil if nothing matches.
MODELS is an alist of (SLUG . DISPLAY).  A candidate qualifies when it
contains every non-numeric word of DESIRED (so \"Gemini ... Flash\" only
matches other Gemini Flash models); among those the same thinking level
wins first, then the highest version number."
  (pcase-let ((`(,words ,_version ,level) (proofreader--model-parts desired)))
    (let (best best-version best-score)
      (dolist (model models)
        (pcase-let ((`(,cand-words ,cand-version ,cand-level)
                     (proofreader--model-parts (cdr model))))
          (when (cl-subsetp words cand-words :test #'string-equal)
            (let ((score (if (equal level cand-level) 1 0)))
              (when (or (null best)
                        (> score best-score)
                        (and (= score best-score)
                             (proofreader--version-lessp best-version cand-version)))
                (setq best model
                      best-version cand-version
                      best-score score))))))
      best)))

(defun proofreader--retry-with-fallback ()
  "Re-run the current prompt after agy rejected `proofreader-model'.
Switches to the closest model `agy models' offers, or drops --model
altogether so agy uses its own default."
  (setq proofreader--retried t)
  (let* ((stale proofreader-model)
         ;; The cached list is what named the retired model, so ask agy again.
         (models (proofreader--list-models t))
         (pick (and models (proofreader--pick-fallback-model stale models)))
         (prompt proofreader--prompt))
    ;; The sentinel runs in an arbitrary buffer; restore the source buffer so
    ;; the retry writes its JSON next to the text being proofread.
    (with-current-buffer (if (buffer-live-p proofreader--source-buffer)
                             proofreader--source-buffer
                           (current-buffer))
      (cond
       (pick
        (setq proofreader-model (cdr pick))
        (message "モデル「%s」は使えません。「%s」で再試行します (この設定は今回のみ。M-x proofreader-select-model で保存できます)"
                 stale proofreader-model)
        (proofreader--start prompt))
       (t
        (message "モデル「%s」は使えません。モデル指定なしで再試行します (M-x proofreader-select-model で選び直せます)"
                 stale)
        (proofreader--start prompt 'no-model))))))

(defun proofreader--process-sentinel (proc event)
  "Process sentinel for PROC with EVENT."
  (when (memq (process-status proc) '(exit signal))
    (if (= (process-exit-status proc) 0)
        (proofreader--handle-success)
      (proofreader--handle-error event))))

(defun proofreader--handle-success ()
  "Handle successful agy response."
  (let* ((output (with-current-buffer proofreader--output-buffer
                   (buffer-string)))
         (json-str (proofreader--extract-json output)))
    (if json-str
        (progn
          (with-temp-file proofreader--json-path
            (insert json-str))
          (message "校正完了: %s (proofreader-apply-interactive で適用)"
                   proofreader--json-path))
      (message "JSONの抽出に失敗しました。出力を確認してください。")
      (switch-to-buffer-other-window proofreader--output-buffer))))

(defun proofreader--handle-error (event)
  "Handle agy error with EVENT.
agy reports startup failures (unknown model, auth, etc.) on stderr and
leaves stdout empty, so show stderr when there is anything there."
  (let ((stderr (and (buffer-live-p proofreader--stderr-buffer)
                     (with-current-buffer proofreader--stderr-buffer
                       (buffer-string)))))
    (cond
     ;; agy retires model names over time; recover instead of failing.
     ((and (not proofreader--retried)
           stderr
           (string-match-p "invalid model selection" stderr)
           proofreader--prompt)
      (proofreader--retry-with-fallback))
     ((and stderr (not (string-empty-p (string-trim stderr))))
      (message "agy エラー: %s\n%s" (string-trim event) (string-trim stderr))
      (switch-to-buffer-other-window proofreader--stderr-buffer))
     (t
      (message "agy エラー: %s" event)
      (switch-to-buffer-other-window proofreader--output-buffer)))))

(defun proofreader--start (prompt &optional no-model)
  "Start the agy process with PROMPT, capturing stdout for JSON extraction.
With NO-MODEL non-nil, omit --model so agy falls back to its own default.
PROMPT is passed as a command-line argument, but agy still waits for stdin to
reach EOF before it prints and exits, even in print (-p) mode.  Since Emacs
keeps the process stdin open as a pipe, we must close it explicitly with
`process-send-eof', otherwise agy hangs with no output."
  (when (and proofreader--process
             (process-live-p proofreader--process))
    (user-error "既に校正処理が実行中です"))
  (setq proofreader--source-buffer (current-buffer))
  (setq proofreader--prompt prompt)
  (setq proofreader--json-path (proofreader--get-json-path))
  (setq proofreader--output-buffer (get-buffer-create "*proofreader-output*"))
  (setq proofreader--stderr-buffer (get-buffer-create "*proofreader-stderr*"))
  (with-current-buffer proofreader--output-buffer
    (erase-buffer))
  (with-current-buffer proofreader--stderr-buffer
    (erase-buffer))
  (message "agy に送信中...")
  (setq proofreader--process
        (make-process
         :name "proofreader"
         :buffer proofreader--output-buffer
         :stderr proofreader--stderr-buffer
         :command (append (list proofreader-command)
                          (unless no-model
                            (list "--model" proofreader-model))
                          (list "-p" prompt))
         :connection-type 'pipe
         :sentinel #'proofreader--process-sentinel))
  ;; agy waits for stdin EOF before printing; close it so it doesn't hang.
  (process-send-eof proofreader--process))

;;;###autoload
(defun proofreader-send-buffer ()
  "Send current buffer to agy for proofreading."
  (interactive)
  (setq proofreader--retried nil)
  (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
         (prompt (proofreader--build-prompt text)))
    (proofreader--start prompt)))

;;;###autoload
(defun proofreader-send-region (start end)
  "Send region from START to END to agy for proofreading."
  (interactive "r")
  (setq proofreader--retried nil)
  (let* ((text (buffer-substring-no-properties start end))
         (prompt (proofreader--build-prompt text)))
    (proofreader--start prompt)))

;;;###autoload
(cl-defun proofreader-apply ()
  "Apply replacements from JSON file to source buffer."
  (interactive)
  (let ((json-path (proofreader--get-json-path)))
    (unless (file-exists-p json-path)
      (user-error "%s が見つかりません" json-path))
    (let* ((json-array-type 'list)
           (json-object-type 'alist)
           (replacements (json-read-file json-path))
           (count 0)
           (failed '()))
      (when (null replacements)
        (message "修正箇所なし")
        (cl-return-from proofreader-apply))
      (save-excursion
        (dolist (item replacements)
          (let ((old (alist-get 'old item))
                (new (alist-get 'new item)))
            (goto-char (point-min))
            (if (search-forward old nil t)
                (progn
                  (replace-match new t t)
                  (cl-incf count))
              (push (alist-get 'reason item) failed)))))
      (if failed
          (message "完了: %d件置換、%d件失敗 (%s)"
                   count (length failed)
                   (string-join failed ", "))
        (message "完了: %d件の置換を適用" count)))))

;;;###autoload
(cl-defun proofreader-apply-interactive ()
  "Apply replacements interactively, confirming each one."
  (interactive)
  (let ((json-path (proofreader--get-json-path)))
    (unless (file-exists-p json-path)
      (user-error "%s が見つかりません" json-path))
    (let* ((json-array-type 'list)
           (json-object-type 'alist)
           (replacements (json-read-file json-path))
           (applied 0)
           (skipped 0))
      (when (null replacements)
        (message "修正箇所なし")
        (cl-return-from proofreader-apply-interactive))
      (save-excursion
        (dolist (item replacements)
          (let ((old (alist-get 'old item))
                (new (alist-get 'new item))
                (reason (alist-get 'reason item)))
            (goto-char (point-min))
            (when (search-forward old nil t)
              (goto-char (match-beginning 0))
              (pulse-momentary-highlight-region (match-beginning 0) (match-end 0))
              (if (y-or-n-p (format "[%s]\n「%s」→「%s」に置換？ "
                                    reason old new))
                  (progn
                    (replace-match new t t)
                    (cl-incf applied))
                (cl-incf skipped))))))
      (message "完了: %d件適用、%d件スキップ" applied skipped))))

;;;###autoload
(defun proofreader-open-json ()
  "Open the replacements JSON file."
  (interactive)
  (let ((json-path (proofreader--get-json-path)))
    (if (file-exists-p json-path)
        (find-file json-path)
      (user-error "%s が見つかりません" json-path))))

;;;###autoload
(defun proofreader-select-model (&optional refresh)
  "Set `proofreader-model' by picking from what `agy models' reports.
The current model is annotated in the list and is what empty input picks.
After choosing you say whether to keep it for good, which saves it through
Customize, or only for this Emacs session.
The list is cached for the session; with a prefix argument REFRESH, ask agy
for it again."
  (interactive "P")
  (let ((models (proofreader--list-models refresh)))
    (unless models
      (user-error "`%s models' からモデル一覧を取得できませんでした" proofreader-command))
    (let* ((current proofreader-model)
           (completion-extra-properties
            (list :annotation-function
                  (lambda (name)
                    (when (string-equal name current) "  ← 現在"))))
           (choice (completing-read
                    (format "モデル (現在: %s): " current)
                    (mapcar #'cdr models) nil t nil nil current)))
      (if (y-or-n-p (format "「%s」を既定として保存する？ (n ならこのセッションのみ) "
                            choice))
          (progn
            (customize-save-variable 'proofreader-model choice)
            (message "モデルを「%s」に設定し保存しました" choice))
        (setq proofreader-model choice)
        (message "モデルを「%s」に設定しました (このセッションのみ)" choice)))))

;;;###autoload
(defun proofreader-cancel ()
  "Cancel running proofreader process."
  (interactive)
  (when (and proofreader--process
             (process-live-p proofreader--process))
    (kill-process proofreader--process)
    (message "校正処理をキャンセルしました")))

(provide 'proofreader)
;;; proofreader.el ends here
