# Claude AI 開発推進手順 - 実プロンプト付き

Android 滞在人数カウントアプリ（`OccupancyCounter`）の開発を題材として、Claudeを使ったAI開発推進フローを5ステップでまとめます。**各ステップに、今回実際に入力したプロンプトと、再利用できるテンプレートプロンプトを併記** しているので、別プロジェクトでもそのまま流用可能です。

---

## Step 1. 要件の言語化と選択肢提示

### 今回実際に入力したプロンプト

```
ANDOROID STUDIOで開発をしたいので、ANDROIDのカメラから「滞在人数カウント」
をしたいです。この「滞在人数カウント」、アンドロイドで動くアプリで、
ファイル形式も.apk 形式です。
```

### Claude側のリアクション

入力が短いことを察知し、**4つの選択肢付き質問** を返してきました。

| 質問項目 | 選択肢 |
|---|---|
| 検出方式 | ML Kit Face / Object Detection / TensorFlow Lite / MediaPipe |
| カウント方式 | スナップショット型 / 入退室型 / 両方 |
| サーバー連携 | Cloudflareエンドポイント送信 / ローカル表示のみ / 両方対応 |
| ビルド方式 | ソース提供 / サンドボックスでapk生成 / 両方 |

### 再利用テンプレート

```
【目的】<何を作りたいか1-2行>
【プラットフォーム】<例: Android Studio / Web / バックエンドAPI>
【入出力】
  - 入力: <例: スマホ内蔵カメラ映像>
  - 出力: <例: .apk / .docx / REST API レスポンス>
【関連する既存環境】<連携先URL、既存システム、社内ルール等>

要件が曖昧な箇所は、選択肢付きで質問してください。
```

> **コツ**: 「選択肢付きで質問してください」と一言添えるだけで、Claudeが論点を構造化して聞き返してくれます。

---

## Step 2. タスク分解と進捗の可視化

### 起こったこと

要件確定後、Claudeが自動で **TodoList（5タスク）** を作成し、`in_progress → completed` で進捗を逐次更新しながら作業しました。

```
1. app/build.gradle.kts と AndroidManifest.xml の作成
2. MainActivity.kt と FaceAnalyzer.kt の実装
3. SettingsActivity.kt と ServerClient.kt の実装
4. レイアウトXML、リソース、テーマ作成
5. README作成と最終検証
```

### 再利用テンプレート

タスク化が自動で走らない場合、以下を追加で指示。

```
作業に着手する前に、TodoList（タスク分解）を作って進捗を可視化してください。
1タスクずつ in_progress / completed を更新しながら進めてください。
```

> **コツ**: 中規模以上の作業（ファイル3つ以上、ステップ3つ以上）では必ずタスク化させると、抜け漏れが防げます。

---

## Step 3. ファイル一括生成（プロジェクトの土台作り）

### 今回はClaude側が自動進行

要件確定とTodoList作成までで、ファイル36個の生成が自動で開始しました。生成順は以下のとおり「依存関係の浅い順」。

1. **ビルド構成** (`build.gradle.kts`, `AndroidManifest.xml`, `gradle.properties`, `settings.gradle.kts`)
2. **ロジック層** (`FaceAnalyzer.kt`, `ServerClient.kt`, `AppPrefs.kt`)
3. **画面層** (`MainActivity.kt`, `SettingsActivity.kt`, レイアウトXML)
4. **リソース** (`strings.xml`, `themes.xml`, `colors.xml`, アイコン一式)
5. **ドキュメント** (`README.md`)

### 再利用テンプレート（追加機能の依頼に使う）

```
<機能名>を追加してください。
- 関連ファイル: <例: MainActivity.kt, ServerClient.kt>
- 期待する挙動: <例: 5秒に1度サーバーへPOST>
- 影響範囲: <例: UIの下部表示、SharedPreferences>

実装時は、依存関係の浅い順に編集 → 編集差分を都度提示してください。
```

> **コツ**: 「依存関係の浅い順」と明示すると、後続ファイルから前のファイルを参照する破綻が起きにくいです。

---

## Step 4. 連携先システムの実態確認

### 今回実際に入力したプロンプト（① URLを直接渡したケース）

```
以下のURLを分析して会議室の予約状況を確認してください。
[会議室管理システム](https://bright-amendments-employer-notebooks.trycloudflare.com/)
```

→ Cowork環境のネットワーク許可リストに `*.trycloudflare.com` が無く、WebFetch失敗。

### 今回実際に入力したプロンプト（② スクリーンショット添付に切り替え）

```
以下のスナップショットから会議室の利用状況を確認してください。
（画面キャプチャを添付）
```

→ Claudeがマルチモーダルで画像を解析し、4室の名称・定員・現在カウント・次の予約時刻まで抽出できました。

### 再利用テンプレート

```
連携先システムの画面/挙動を確認してほしいです。
（添付: スクリーンショット or HTMLソース or APIレスポンス例）

このシステムから読み取れる情報を以下の観点で抽出してください:
1. データ構造（一覧／カード／タイムライン等）
2. 値のフォーマット（日時、ID、状態フラグ）
3. 想定される API エンドポイント
4. アプリ側で連携するための制約
```

> **コツ**: 社内システム / Cloudflare Tunnel / 認証必須サイト等、WebFetchが届かない場合は **スクリーンショット貼り付けが最速** です。

---

## Step 5. エラー駆動のリファイン

### 今回実際に入力したプロンプト（① 発生事象を簡潔に）

```
C:\PRJ2\ANDROIDのIOTデバイス化と会議室予約アプリ\OccupancyCounterで
gradleがどプさしません。
```

→ 不足ファイル（`gradle-wrapper.jar` / `gradlew.bat`）を特定し、GitHubから取得して配置。

### 今回実際に入力したプロンプト（② StackTrace全文を貼る）

```
Build file 'C:\PRJ2\...\app\build.gradle.kts' line: 1
An exception occurred applying plugin request [id: 'com.android.application']
> Failed to apply plugin 'com.android.internal.application'.
   > Your project path contains non-ASCII characters. ...
（以下、Stack Trace全文）
```

→ 「非ASCIIパス」が原因と特定 → `android.overridePathCheck=true` を `gradle.properties` に追記して解消。

### 再利用テンプレート

```
以下のエラーが出ました。原因特定と修正案を提示してください。
- 操作: <例: Android Studio で Sync Project>
- 環境: <例: Windows 11, AGP 8.13.2, Gradle 8.13>
- ログ全文（省略せず貼る）:
  ```
  <Stack Trace 全文>
  ```

修正後、トラブルシューティング章をREADMEに追記してください。
```

| 発生した問題 | 対処 |
|---|---|
| `gradle-wrapper.jar` / `gradlew.bat` が無い | GitHub から git clone で取得 |
| `Your project path contains non-ASCII characters` | `gradle.properties` に `android.overridePathCheck=true` を追記 |

> **コツ**: Stack Trace は省略せず **全文** を貼る。`Caused by:` 以降の真の原因まで読み解いてくれます。

---

## ステップ別 プロンプト早見表

| Step | フェーズ | 短縮プロンプト例 |
|---|---|---|
| 1 | 要件確認 | `<目的> を作りたい。曖昧な箇所は選択肢付きで質問して` |
| 2 | タスク分解 | `TodoList作って進捗を逐次更新しながら進めて` |
| 3 | 実装 | `<機能> を追加。依存関係の浅い順に編集して` |
| 4 | 連携先確認 | `（スクショ添付）この画面の構造を抽出して` |
| 5 | エラー対処 | `（StackTrace全文）原因特定と修正案を提示して` |

---

## 学び - 役割分担マトリクス

| フェーズ | Claudeに任せるべきこと | 人間が判断すべきこと |
|---|---|---|
| 設計 | 選択肢の整理、技術スタック比較 | 最終選択、業務制約の提示 |
| 実装 | コード生成、依存解決、設定ファイル | 動作する環境の準備（SDK、デバイス） |
| テスト | エラー解析、修正パッチ生成 | 実機検証、UI/UX評価 |
| 運用 | トラブルシューティング文書化 | 本番環境への配置、固定URL化 |

---

## 共通で再利用できる5サイクル

```
┌──────────────────────────────────────────────┐
│  1. 要件確認（選択肢付き質問で具体化）        │
│           ↓                                  │
│  2. タスク分解（TodoListで可視化）            │
│           ↓                                  │
│  3. 段階的実装（依存関係の浅い順）            │
│           ↓                                  │
│  4. 連携先確認（スクショ／HTML／API仕様共有） │
│           ↓                                  │
│  5. エラー駆動修正（StackTrace全文を渡す）    │
│           ↺ 必要に応じて1〜4へ戻る           │
└──────────────────────────────────────────────┘
```

このフローは、別のAndroid／Web／バックエンド開発でもそのまま流用可能です。

---

## 補足 - 今回のプロジェクト成果物

- 場所: `C:\PRJ2\ANDROIDのIOTデバイス化と会議室予約アプリ\OccupancyCounter`
- 技術スタック: Kotlin / CameraX 1.3.1 / ML Kit Face Detection / OkHttp
- 出力: `.apk`（Android Studioでビルド後、`app/build/outputs/apk/debug/app-debug.apk`）
- 連携先: `https://bright-amendments-employer-notebooks.trycloudflare.com/api/occupancy`

### プロジェクト構成（36ファイル）

```
OccupancyCounter/
├── build.gradle.kts                 (Top-level)
├── settings.gradle.kts
├── gradle.properties
├── gradlew / gradlew.bat
├── gradle/wrapper/
│   ├── gradle-wrapper.jar
│   └── gradle-wrapper.properties
├── README.md
└── app/
    ├── build.gradle.kts
    ├── proguard-rules.pro
    └── src/main/
        ├── AndroidManifest.xml
        ├── java/com/example/occupancycounter/
        │   ├── MainActivity.kt
        │   ├── FaceAnalyzer.kt
        │   ├── ServerClient.kt
        │   ├── SettingsActivity.kt
        │   └── AppPrefs.kt
        └── res/
            ├── layout/activity_main.xml
            ├── layout/activity_settings.xml
            ├── xml/preferences.xml
            ├── values/strings.xml (英語)
            ├── values-ja/strings.xml (日本語)
            ├── values/colors.xml
            ├── values/themes.xml
            ├── drawable/ic_launcher_*.xml
            └── mipmap-*/ic_launcher*.png
```
