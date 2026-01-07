;;; proofreader.el --- Proofreading workflow with Gemini CLI -*- lexical-binding: t; -*-

;; Author: ichibeikatura
;; URL: https://github.com/ichibeikatura/proofreader
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, writing, proofreading

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Emacs package for Japanese text proofreading using Gemini CLI.
;; 
;; Usage:
;;   1. M-x proofreader-send-buffer  - Send buffer to Gemini CLI
;;   2. Edit generated replacements.json as needed
;;   3. M-x proofreader-apply        - Apply replacements from JSON
;;
;; Configuration:
;;   (setq proofreader-gemini-model "gemini-2.5-pro")
;;   (setq proofreader-json-filename "replacements.json")

;;; Code:

(require 'json)

(defgroup proofreader nil
  "Proofreading with Gemini CLI."
  :group 'tools
  :prefix "proofreader-")

(defcustom proofreader-gemini-command "gemini"
  "Command to invoke Gemini CLI."
  :type 'string
  :group 'proofreader)

(defcustom proofreader-gemini-model "gemini-2.5-pro"
  "Gemini model to use."
  :type 'string
  :group 'proofreader)

(defcustom proofreader-json-filename "replacements.json"
  "Filename for replacement JSON output."
  :type 'string
  :group 'proofreader)

(defcustom proofreader-prompt-template
  "以下のテキストを校正してください。

## 修正対象
- 誤字脱字、変換ミス
- 入力ミスに起因する「てにをは」のズレや係り受けの崩れ

## 修正対象外（変更しない）
- 歴史的仮名遣い、旧字体
- Markdown形式の引用文（> で始まる行）
- 固有名詞、史実に関する記述
- 文体や表現の好み

## 出力形式
JSONのみを出力してください。説明文や```json```マークダウンは不要です。

[
  {\"old\": \"原文の修正箇所（一字一句変えずコピー）\", \"new\": \"修正後\", \"reason\": \"理由\"}
]

修正箇所がない場合は [] を出力してください。

---
対象テキスト：

%s"
  "Prompt template for proofreading. %s is replaced with buffer content."
  :type 'string
  :group 'proofreader)

(defvar proofreader--process nil
  "Current Gemini process.")

(defvar proofreader--output-buffer nil
  "Buffer for Gemini output.")

(defvar proofreader--source-buffer nil
  "Source buffer being proofread.")

(defvar proofreader--json-path nil
  "Path to output JSON file.")

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
  "Extract JSON array from OUTPUT string."
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    ;; Skip any leading text until we find [
    (when (re-search-forward "\\[" nil t)
      (goto-char (match-beginning 0))
      (let ((start (point)))
        ;; Find matching ]
        (condition-case nil
            (progn
              (forward-sexp)
              (buffer-substring-no-properties start (point)))
          (error nil))))))

(defun proofreader--process-sentinel (proc event)
  "Process sentinel for PROC with EVENT."
  (when (memq (process-status proc) '(exit signal))
    (if (= (process-exit-status proc) 0)
        (proofreader--handle-success)
      (proofreader--handle-error event))))

(defun proofreader--handle-success ()
  "Handle successful Gemini response."
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
  "Handle Gemini error with EVENT."
  (message "Gemini CLIエラー: %s" event)
  (switch-to-buffer-other-window proofreader--output-buffer))

;;;###autoload
(defun proofreader-send-buffer ()
  "Send current buffer to Gemini CLI for proofreading."
  (interactive)
  (when (and proofreader--process
             (process-live-p proofreader--process))
    (user-error "既に校正処理が実行中です"))
  (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
         (prompt (proofreader--build-prompt text)))
    (setq proofreader--source-buffer (current-buffer))
    (setq proofreader--json-path (proofreader--get-json-path))
    (setq proofreader--output-buffer (get-buffer-create "*proofreader-output*"))
    (with-current-buffer proofreader--output-buffer
      (erase-buffer))
    (message "Geminiに送信中...")
    (setq proofreader--process
          (make-process
           :name "proofreader"
           :buffer proofreader--output-buffer
           :command (list proofreader-gemini-command
                          "-m" proofreader-gemini-model
                          "-o" "text")
           :connection-type 'pipe
           :sentinel #'proofreader--process-sentinel))
    (process-send-string proofreader--process prompt)
    (process-send-eof proofreader--process)))

;;;###autoload
(defun proofreader-send-region (start end)
  "Send region from START to END to Gemini CLI for proofreading."
  (interactive "r")
  (when (and proofreader--process
             (process-live-p proofreader--process))
    (user-error "既に校正処理が実行中です"))
  (let* ((text (buffer-substring-no-properties start end))
         (prompt (proofreader--build-prompt text)))
    (setq proofreader--source-buffer (current-buffer))
    (setq proofreader--json-path (proofreader--get-json-path))
    (setq proofreader--output-buffer (get-buffer-create "*proofreader-output*"))
    (with-current-buffer proofreader--output-buffer
      (erase-buffer))
    (message "Geminiに送信中...")
    (setq proofreader--process
          (make-process
           :name "proofreader"
           :buffer proofreader--output-buffer
           :command (list proofreader-gemini-command
                          "-m" proofreader-gemini-model
                          "-o" "text")
           :connection-type 'pipe
           :sentinel #'proofreader--process-sentinel))
    (process-send-string proofreader--process prompt)
    (process-send-eof proofreader--process)))

;;;###autoload
(defun proofreader-apply ()
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
(defun proofreader-apply-interactive ()
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
(defun proofreader-cancel ()
  "Cancel running proofreader process."
  (interactive)
  (when (and proofreader--process
             (process-live-p proofreader--process))
    (kill-process proofreader--process)
    (message "校正処理をキャンセルしました")))

(provide 'proofreader)
;;; proofreader.el ends here
