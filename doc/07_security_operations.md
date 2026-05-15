# 7. セキュリティ・運用設計

**最終更新**: 2026-05-15

---

## 7.1 認証・認可設計

```mermaid
graph TB
    subgraph "認証フロー"
        AAD["Azure AD<br/>App Registration"]
        CC["client_credentials<br/>grant"]
        TOKEN["Access Token<br/>(1時間有効)"]
    end

    subgraph "利用先"
        GRAPH["Microsoft Graph API"]
        OD["OneDrive"]
        TEAMS["Teams Transcript"]
    end

    AAD -->|"client_id + secret"| CC
    CC -->|"POST /oauth2/v2.0/token"| TOKEN
    TOKEN --> GRAPH
    GRAPH --> OD
    GRAPH --> TEAMS
```

### Azure AD App 必要権限 (Application permissions)

| API | 権限 | 用途 |
|---|---|---|
| Microsoft Graph | Files.ReadWrite.All | OneDrive 書込 |
| Microsoft Graph | Sites.ReadWrite.All | SharePoint 書込 |
| Microsoft Graph | OnlineMeetings.Read.All | Teams 会議メタ取得 |
| Microsoft Graph | OnlineMeetingTranscript.Read.All | Teams Transcript取得 |
| Microsoft Graph | User.Read.All | 出席者情報取得 |
| Microsoft Graph | Calendars.Read | Outlook予定表連携 |

> すべて **Admin consent** が必要。IT管理者への依頼が必須。

### API キー認証

| サービス | 認証方式 | キー名 |
|---|---|---|
| Azure Speech | ヘッダー `Ocp-Apim-Subscription-Key` | AZURE_SPEECH_KEY |
| Azure Speaker Recognition | ヘッダー `Ocp-Apim-Subscription-Key` | SPEAKER_RECOGNITION_KEY |
| Anthropic Claude | ヘッダー `x-api-key` | ANTHROPIC_API_KEY |
| Azure Storage | ConnectionString | AZURE_STORAGE_CONNECTION_STRING |

---

## 7.2 データ保護

### データ分類と保管方針

| データ | 機密度 | 保管先 | 保管期間 | 暗号化 |
|---|---|---|---|---|
| 音声ファイル (.m4a) | 高 | Express PC recordings/ | 議事録完了後7日で削除 | TLS in transit |
| Transcript JSON | 中 | Express PC storage/transcripts/ | 90日 | TLS in transit |
| 議事録 (.docx) | 中 | OneDrive (永続) | 社内規程に準拠 | M365暗号化 |
| Speaker Profile (声紋) | 高 (生体情報) | Azure Speech Service + `storage/speaker-profiles.json` | 2年 (退職時即時削除) | Azure保存時暗号化 |
| API キー / シークレット | 最高 | .env ファイル (ローカル) | — | Git除外必須 |

### .gitignore による保護

```
.env
.env.*
!.env.example
storage/
recordings/
azurite-data/
```

---

## 7.3 セキュリティ対策

```mermaid
flowchart TD
    subgraph "入力検証"
        V1["multipart サイズ制限 (200MB)"]
        V2["device_id 形式検証"]
        V3["JSON スキーマ検証"]
    end

    subgraph "通信保護"
        T1["Cloudflare Tunnel (HTTPS)"]
        T2["Azure SDK (TLS)"]
        T3["CORS 設定"]
    end

    subgraph "認証情報管理"
        A1[".env Git除外"]
        A2["Azure Key Vault (将来)"]
        A3["キーローテーション (6ヶ月)"]
        A4["Client Secret 有効期限 (24ヶ月)"]
    end

    subgraph "プライバシー"
        P1["録音同意ダイアログ (Android)"]
        P2["Speaker Profile 同意取得"]
        P3["Right to Erasure 対応"]
        P4["議事録に REDACTED 表記"]
    end
```

### Webhook セキュリティ

| 対策 | 実装 |
|---|---|
| clientState 検証 | 通知ごとに `WEBHOOK_CLIENT_STATE` と一致確認 |
| fail-closed | `WEBHOOK_CLIENT_STATE` 未設定時は通知を拒否 |
| validationToken | Subscription作成時の検証トークン応答 |
| HTTPS 必須 | Azure Functions の HTTPS エンドポイント |

---

## 7.4 録音同意

```mermaid
flowchart TD
    START["会議開始ボタン"] --> CONSENT["録音同意ダイアログ表示"]
    CONSENT -->|"同意する"| REC["録音開始"]
    CONSENT -->|"同意しない"| CANCEL["録音キャンセル"]
    REC --> NOTIFY["画面に録音中表示"]
    NOTIFY --> END["会議終了 → 送信"]
```

- Android アプリで録音開始時に **音声＋画面表示** で告知
- 議事録冒頭にも「自動文字起こし対象会議」と明記
- 就業規則・労使協定への追記が必要 (人事・法務確認)

---

## 7.5 運用手順

### ローカル開発起動

```powershell
# 方法1: 一括起動
.\start-dev.ps1

# 方法2: 個別起動
# Terminal 1: Azurite
azurite --location azurite-data --debug azurite-data/debug.log --silent

# Terminal 2: Express
cd TestDashboard
npm start

# Terminal 3: Cloudflare Tunnel
cloudflared tunnel --url http://127.0.0.1:3000
```

### スモークテスト

```powershell
.\scripts\run-smoke-test.ps1 -BASE "http://localhost:3000"
```

### ログローテーション

```powershell
.\scripts\rotate-azurite-log.ps1 -MaxSizeMB 10 -KeepDays 7
```

---

## 7.6 監視設計

```mermaid
graph TB
    subgraph "監視対象"
        HL["GET /healthz<br/>(Express稼働確認)"]
        JOB["ジョブステータス<br/>(/api/jobs)"]
        SUB["Subscription状態<br/>(Azure Table)"]
        LOG["server.log<br/>(Express ログ)"]
    end

    subgraph "Azure 監視"
        AI["Application Insights<br/>(Functions)"]
        ALERT["アラートルール<br/>(subscription失敗検知)"]
    end

    subgraph "メトリクス"
        M1["SubscriptionsRenewed"]
        M2["SubscriptionsRecreated"]
        M3["SubscriptionsFailed"]
    end

    AI --> M1
    AI --> M2
    AI --> M3
    M3 -->|"≥3回連続"| ALERT
```

### KQL クエリ例

```kusto
-- 直近24時間の更新履歴
traces
| where timestamp > ago(24h)
| where message startswith "[renew]"
| project timestamp, message, severityLevel
| order by timestamp desc
```

---

## 7.7 エラーハンドリング

### リトライ戦略

| エラー | 戦略 | 最大試行 |
|---|---|---|
| 429 Throttled | Exponential backoff (1s→2s→4s→8s→16s) | 5回 |
| 503 Service Unavailable | Exponential backoff | 5回 |
| Network timeout | Exponential backoff | 5回 |
| 401 Unauthorized | Token再取得 → 即リトライ | 2回 |
| 403 Forbidden | **リトライしない** → アラート | — |
| 400 Bad Request | **リトライしない** → ログ | — |
| 404 Subscription gone | DB上 dead → Timer次回で再作成 | — |

### ジョブ失敗時の復旧

```mermaid
flowchart TD
    FAIL["ジョブ失敗<br/>(status: failed)"]
    LOG["エラーログ記録<br/>jobs/{id}.json"]
    CHECK{"手動確認"}
    FIX["原因修正<br/>(API キー/権限等)"]
    RETRY["POST /api/minutes/:id/reprocess"]
    OK["status: completed"]

    FAIL --> LOG --> CHECK
    CHECK -->|修正可能| FIX --> RETRY --> OK
    CHECK -->|修正不可| LOG
```

---

## 7.8 既知の制約・リスク

| リスク | 影響 | 対策 |
|---|---|---|
| Cloudflare Tunnel URL変更 | Azure Speech が音声取得不可 | Named Tunnel or Blob経由 (PUBLISH_MODE=blob) |
| ML Kit 顔検出精度 | 後ろ向き・うつむきは未カウント | 許容範囲内として運用 |
| Azure Speech 固有名詞誤認識 | 議事録品質低下 | Custom Speech モデルで学習 |
| Claude hallucination | 誤情報拡散 | プロンプトで「推測しない」厳守 + 人手レビュー |
| 長時間会議 (>2h) | Azure Speech タイムアウト | 30分分割アップロード |
| メモリ保持型 headcount | サーバー再起動で消失 | SQLite/JSON永続化を検討 |
| Client Secret 期限切れ | Graph API 全停止 | 24ヶ月設定 + ローテーション監視 |

---

## 7.9 将来ロードマップ

```mermaid
gantt
    title 機能拡張ロードマップ
    dateFormat YYYY-MM
    axisFormat %Y-%m

    section V1.x
    話者プロファイル登録       :v11, 2026-06, 4w
    Outlook予定表連携          :v12, after v11, 2w
    リアルタイム文字起こし      :v13, after v12, 4w

    section V2.x
    Teams Bot参加              :v20, 2026-09, 6w
    多言語対応                 :v21, after v20, 3w
    議事録検索・横断分析        :v22, after v21, 4w

    section V3.x
    オンプレWhisperX移行       :v30, 2027-01, 6w
```
