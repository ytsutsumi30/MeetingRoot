# Serena MCP - Windows + Claude Desktop 導入手順

**作成日**: 2026-05-11
**対象**: Windows 11 + Claude Desktop
**目的**: OccupancyCounter / TestDashboard / functions 全体を **Serena (LSP ベースの MCP サーバー)** から扱えるようにする

---

## 1. 何をするか（5ステップ）

1. **uv** (Python パッケージマネージャ) をインストール
2. **Serena** を初回ダウンロード（uvx キャッシュ生成）
3. **Claude Desktop の設定ファイル** に MCP サーバー追記
4. Claude Desktop を **完全終了 → 再起動**
5. 新規チャットで **接続確認**

所要時間: 10〜15分（初回ダウンロードを含む）

---

## 2. Step 1: uv のインストール

PowerShell（管理者でなくてOK）を開いて:

```powershell
# 推奨: winget で一発インストール
winget install --id astral-sh.uv --accept-package-agreements --accept-source-agreements
```

完了後、**PowerShell を一度閉じて開き直し** て確認:

```powershell
uv --version
```

→ `uv 0.x.x (xxxxx 2026-xx-xx)` のように出ればOK。

### winget が使えない場合

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

または公式 GitHub Releases から `uv-x86_64-pc-windows-msvc.zip` を手動ダウンロード:
https://github.com/astral-sh/uv/releases/latest

---

## 3. Step 2: Serena の初回ダウンロード（キャッシュ生成）

```powershell
uvx --from git+https://github.com/oraios/serena serena-mcp-server --help
```

初回は GitHub から Serena 本体と依存パッケージをダウンロードします（数十秒〜2分）。
`--help` が表示されれば成功。**このコマンドは1回だけ実行すれば良い** です。

---

## 4. Step 3: Claude Desktop の設定ファイル編集

### 3-1. 設定ファイルの場所を開く

PowerShell で:

```powershell
notepad "$env:APPDATA\Claude\claude_desktop_config.json"
```

ファイルが存在しない場合は新規作成されます。

### 3-2. 内容を追記

既存の `mcpServers` セクションがあればその中に追加、なければ以下をまるごとコピペ:

```json
{
  "mcpServers": {
    "serena": {
      "command": "uvx",
      "args": [
        "--from",
        "git+https://github.com/oraios/serena",
        "serena-mcp-server",
        "--context",
        "ide-assistant",
        "--project",
        "C:/PRJ2/dev2"
      ]
    }
  }
}
```

**重要**:
- `--project` のパスは `C:/PRJ2/dev2`（**バックスラッシュではなくスラッシュ** または `C:\\PRJ2\\dev2` のエスケープ）
- 既に他の `mcpServers` があれば、その後に `,` で続けて `serena` を追加
- JSON 構文エラーがあると Claude Desktop が読み込みません

### 3-3. JSON が壊れていないか確認

PowerShell で:

```powershell
Get-Content "$env:APPDATA\Claude\claude_desktop_config.json" | ConvertFrom-Json
```

エラーが出なければ OK。エラーが出たらカンマ忘れや引用符の対応を再確認。

---

## 5. Step 4: Claude Desktop を完全再起動

「×」で閉じるだけでは不十分です。**タスクトレイ** (画面右下) の Claude アイコンを右クリック → **Quit** で完全終了させてから、もう一度起動してください。

### 起動確認

Claude Desktop を起動して新規チャットを開き:

```
今接続されているMCPサーバーを一覧表示してください
```

→ `serena` が表示されればOK。表示されない場合は次の節へ。

---

## 6. Step 5: 動作確認

新規チャットで Claude にこう聞いてみてください:

```
Serena の find_symbol を使って、MeetingRecorder クラスを探して、
クラス内のメソッド一覧を出してください
```

Claude が `mcp__serena__find_symbol` を呼び出し、`MeetingRecorder.kt` 内の
`start()`, `stop()`, `cancel()`, `durationSec()` 等が返ってくれば成功です。

---

## 7. トラブルシューティング

### `uvx: command not found`

PATH が反映されていません。新しい PowerShell ウィンドウを開いてください。
それでも認識されない場合は以下を試す:

```powershell
# uv のインストール先確認
Get-Command uv -ErrorAction SilentlyContinue | Select-Object Source
# 例: C:\Users\xxxxx\.local\bin\uv.exe

# PATH 一時追加
$env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"

# PATH 永続追加 (現ユーザー)
[Environment]::SetEnvironmentVariable("Path",
  "$([Environment]::GetEnvironmentVariable('Path','User'));$env:USERPROFILE\.local\bin",
  "User")
```

### Claude Desktop に serena が表示されない

1. JSON 構文確認（前述）
2. **タスクトレイから完全終了** したか確認
3. 設定 → 開発者 → MCP サーバー → エラーログを確認
4. 初回起動時は Serena のサブモジュール（言語サーバー）をDLするため、認識まで30秒〜1分かかる場合あり

### `Cannot find a suitable language server`

言語サーバーが見つからない警告。**初回その言語のファイルを開いた瞬間**にダウンロードされます。例:
- Kotlin: 初回はAndroid Studio などで使われている JDK が要る
- JavaScript/TypeScript: Node.js 必要 (既にインストール済み)

Kotlin が動かない場合は、Java 17+ をインストール:
```powershell
winget install --id Microsoft.OpenJDK.17
```

### Python が見つからないエラー

Serena 内部で使う Python が無い場合 uv が自動DLします。手動で確認:
```powershell
uv python install 3.12
```

---

## 8. 接続後の便利な使い方

### A. プロジェクトメモリ
> 「device_id の MAC形式（AA:BB:CC:DD:EE:FF）と4会議室マッピングのルールを記憶して」

→ `.serena/memories/device-mapping.md` に保存され、次回以降のセッションで自動参照される

### B. シンボル単位でのリファクタ
> 「`startJob` 関数の中身を、エラーハンドリングを追加した版に書き換えて」

→ ファイル全体を読まずに**該当関数だけ**を編集（差分が小さい・速い）

### C. クロス言語の参照検索
> 「`POST /ingest/recording` を実装している箇所、それを呼んでいる箇所を全部見つけて」

→ Express の server.js と Kotlin の RecordingUploader.kt を両方ヒット

### D. 構造把握
> 「TestDashboard の services/ 配下にあるモジュールの依存関係を可視化して」

→ 各 require/export を辿ってグラフ化

---

## 9. アンインストール

不要になったら:

```powershell
# 1. claude_desktop_config.json から serena エントリを削除
notepad "$env:APPDATA\Claude\claude_desktop_config.json"

# 2. uv キャッシュをクリア
uv cache clean

# 3. Serena のメモリディレクトリ削除 (任意)
Remove-Item -Recurse C:\PRJ2\dev2\.serena
```

---

## 10. 関連リンク

- Serena GitHub: https://github.com/oraios/serena
- uv 公式: https://docs.astral.sh/uv/
- Claude Desktop MCP 公式: https://modelcontextprotocol.io/

---

## 11. 完了後の次のステップ

W4 (Microsoft Graph 連携) を再開します:
1. Serena 接続を Claude Desktop で動作確認
2. 同じプロジェクトを新規チャットで開く
3. 「W4 (Microsoft Graph + OneDrive 保存) を再開して」とリクエスト

**Cowork セッション (このチャット) では Serena は使えません** — Claude Desktop で新規セッションを開く必要があります。
