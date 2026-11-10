# proofreader.el

Antigravity CLI (`agy`) を使った日本語テキスト校正ワークフローを Emacs で完結させるパッケージ。

旧 Gemini CLI は個人利用向けの提供が 2026-06-18 に終了したため、現在は後継の
Antigravity CLI を Gemini AI Pro の OAuth ログイン経由で呼び出す。

## 必要環境

- Emacs 27.1+
- Antigravity CLI (`agy` コマンドが `exec-path` から見えること)
- Elpaca

## インストール

### elpaca / straight.el

```elisp
(use-package proofreader
  :ensure (proofreader
           :url "https://github.com/ichibeikatura/proofreader.el")
  :bind (("C-c p s" . proofreader-send-buffer)
         ("C-c p i" . proofreader-apply-interactive)
         ("C-c p r" . proofreader-send-region)
         ("C-c p o" . proofreader-open-json)
         ("C-c p m" . proofreader-select-model)
         ("C-c p a" . proofreader-apply)))
```

### 手動

```elisp
(add-to-list 'load-path "/path/to/proofreader")
(require 'proofreader)
```

## 使い方

### 基本ワークフロー

1. **校正対象のバッファで** `M-x proofreader-send-buffer`
   - バッファ全体を agy に送信
   - 同ディレクトリに `replacements.json` を生成

2. **校正対象のバッファで** `M-x proofreader-apply-interactive`
   - 一件ずつ確認しながら置換（`y/n` で取捨選択）

### コマンド一覧

| コマンド | 説明 |
|----------|------|
| `proofreader-send-buffer` | バッファ全体を送信 |
| `proofreader-send-region` | 選択範囲を送信 |
| `proofreader-apply` | JSON から一括置換 |
| `proofreader-apply-interactive` | 確認しながら置換 |
| `proofreader-open-json` | JSON ファイルを開く |
| `proofreader-cancel` | 実行中の処理をキャンセル |
| `proofreader-select-model` | `agy models` の一覧からモデルを選ぶ（`C-u` で一覧を再取得） |

## カスタマイズ

```elisp
;; agy コマンドを変更
(setq proofreader-command "agy")

;; 選んだモデルの保存先（既定は user-emacs-directory 直下の proofreader-state.eld）
(setq proofreader-state-file
      (expand-file-name "proofreader-state.eld" no-littering-var-directory))

;; モデルを init で固定したい場合のみ（通常は不要。下の「優先順位」を参照）
;; (setq proofreader-model "<agy models の表示名>")

;; JSON ファイル名を変更
(setq proofreader-json-filename "corrections.json")

;; プロンプトをカスタマイズ
(setq proofreader-prompt-template "...")
```

### モデルを切り替える

`M-x proofreader-select-model`（上の例では `C-c p m`）で `agy models` の一覧から選ぶ。

- 現在のモデルには一覧で `← 現在` が付き、空入力のままでも現在値が選ばれる。
- 選んだあとに保存するか聞かれる。`y` なら `proofreader-state-file` に書いて次回
  以降も有効、`n` ならこの Emacs セッションのみ。保存は Customize / `custom-file`
  を使わないので、`custom-file` を読み込まない設定でも再起動後に残る。
- 一覧は取得に数秒かかるのでセッション内でキャッシュする。新しいモデルが出た直後
  など取り直したいときは `C-u M-x proofreader-select-model`。

### モデルの優先順位

実際に使われるモデルは、次のうち最初に値があるもの。

1. このセッションで選んだモデル（`proofreader-select-model`、または自動フォールバック）
2. init や Customize で明示した `proofreader-model`
3. `proofreader-state-file` に保存したモデル
4. なし（`--model` を付けずに実行し、agy 自身の既定に任せる）

`proofreader-model` の既定値は `nil`。agy のモデル名は数か月で入れ替わるため、
パッケージ側に特定の名前を持たせていない。init で `proofreader-model` を明示して
いると起動のたびにそれが保存値より優先されるので、`proofreader-select-model` の
保存を効かせたいときは init の設定を外す（保存時にその旨の警告が出る）。

### モデルが変わったとき

agy 側で提供モデルの一覧は入れ替わる。指定したモデルが使えなくなった場合、
proofreader は自動的に `agy models` を引いて同系列の最新モデル
（例: `Gemini 3.5 Flash (Medium)` → `Gemini 3.7 Flash (Medium)`）に切り替え、
そのまま再試行する。該当がなければモデル指定なしで再試行する。

自動で選ばれたモデルはその Emacs セッション限りなので、恒久的に変えるには
`M-x proofreader-select-model` で選び直して保存する。

## JSON 形式

```json
[
  {"old": "誤った文字列", "new": "正しい文字列", "reason": "修正理由"}
]
```

## License

MIT
