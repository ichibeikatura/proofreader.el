# proofreader.el

Gemini CLI を使った日本語テキスト校正ワークフローを Emacs で完結させるパッケージ。

## 必要環境

- Emacs 27.1+
- [Gemini CLI](https://github.com/google-gemini/gemini-cli)

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
   - バッファ全体を Gemini CLI に送信
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

## カスタマイズ

```elisp
;; Gemini モデルを変更
(setq proofreader-gemini-model "gemini-2.5-flash")

;; JSON ファイル名を変更
(setq proofreader-json-filename "corrections.json")

;; プロンプトをカスタマイズ
(setq proofreader-prompt-template "...")
```

## JSON 形式

```json
[
  {"old": "誤った文字列", "new": "正しい文字列", "reason": "修正理由"}
]
```

## License

MIT
