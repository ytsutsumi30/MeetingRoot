# 議事録自動生成機能 詳細設計計画書

**作成日**: 2026-05-09
**対象システム**: OccupancyCounter プロジェクト拡張
**目的**: 会議室での会議を自動録音し、話者分離付き文字起こし → AI要約 → Word議事録生成 → OneDrive/Teams 自動保管

---

## 1. 採用技術スタック（決定）

| 領域 | 採用技術 | 選定理由 |
|---|---|---|
| 録音（物理参加者） | Android MediaRecorder (m4a/AAC 64kbps mono) | 既存OccupancyCounter端末を流用 |
| アップロード | OkHttp multipart/form-data | 既存依存ライブラリ |
| 物理参加者 STT + 話者分離 | **Azure Speech Service - Conversation Transcription** | 日本語最強・Office365統合 |
| **Teams参加者の発言取得** | **Microsoft Graph - Online Meeting Transcript API** | E3/E5 で利用可、話者実名取得 |
| **Webhook受信** | **Azure Functions (HTTP Trigger)** | 安定URL・Tunnel URL変更耐性 |
| **メッセージング** | **Azure Queue Storage** | Functions ↔ Express の疎結合連携 |
| 要約 LLM | **Anthropic Claude (claude-sonnet-4-6)** | 日本語要約品質最高 |
| ストレージ | **Microsoft OneDrive for Business + Teams Channel Files** | 既存M365アカウント活用 |
| 認証 | **Azure AD App Registration (client_credentials)** | バックエンド完結認証 |
| ドキュメント生成 | **docx (npm package)** | 軽量・Word完全互換 |
| バックエンド | Node.js + Express (既存 TestDashboard 拡張) | 既存延長 |

---

## 2. 全体アーキテクチャ（ハイブリッド対応）

```
                      ╔══════════════════════════════════════╗
                      ║   ハイブリッド会議シナリオ              ║
                      ║  (会議室 + Teams リモート 同時進行)     ║
                      ╚══════════════════════════════════════╝

┌──────────────────────────────┐         ┌──────────────────────────────┐
│ 会議室の参加者                  │         │ Teams リモート参加者            │
│  ↓                           │         │  ↓                           │
│ Android (OccupancyCounter)    │         │ Teams Online Meeting          │
│ MediaRecorder で録音           │         │ (organizer がトランスクリプト有効)│
│  ↓ POST /ingest/recording      │         │  ↓ 会議終了で Webhook 発火     │
│                              │         │                              │
└──────────────┬───────────────┘         └──────────────┬───────────────┘
               │                                        │
               │                                        ▼
               │                       ┌──────────────────────────────┐
               │                       │ Azure Functions (HttpTrigger)  │
               │                       │ - Webhook 受信(safe)           │
               │                       │ - Graph API: 文字起こし取得      │
               │                       │ - Azure Blob に transcript.json│
               │                       │ - Azure Queue にメッセージ      │
               │                       └──────────────┬───────────────┘
               │                                      │
               │                                      ▼
               │                       ┌──────────────────────────────┐
               │                       │ Azure Blob + Queue Storage    │
               │                       │ - transcripts/<id>-teams.json │
               │                       │ - queue: minutes-jobs         │
               │                       └──────────────┬───────────────┘
               │                                      │
               ▼                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [Express Backend] TestDashboard (拡張)                                │
│                                                                      │
│  ① POST /ingest/recording 受信                                        │
│  ② Azure Speech に音声送信 → diarization で transcript-room.json      │
│  ③ Azure Queue ポーリング → transcript-teams.json をBlobから取得        │
│  ④ TranscriptMerger: 時系列でマージ → transcript-merged.json           │
│  ⑤ Claude API で議事録Markdown生成                                    │
│  ⑥ docx パッケージで .docx 変換                                        │
│  ⑦ Microsoft Graph で OneDrive へアップロード                           │
│  ⑧ meta.json に保存                                                   │
│                                                                      │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ GET /api/minutes/:roomId
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [GitHub Pages Dashboard]                                              │
│  各会議室カードに「議事録(N件・物理X名+リモートY名)」バッジ                  │
│  クリック → モーダル → .docx DL / OneDrive で開く                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 取り扱う4ケース

| ケース | 物理参加 | Teamsリモート | 議事録の生成元 |
|---|---|---|---|
| 1. 会議室 全員物理 | ◯ | × | Android録音 → Azure Speech のみ |
| 2. Teams 全員リモート | × | ◯ | Teams Live Transcript のみ |
| 3. ハイブリッド | ◯ | ◯ | **両方をマージ** ← 主要シナリオ |
| 4. 会議室で1台がTeams参加 | ◯ | × (扱い物理) | Android録音のみ（スピーカー音もマイクで拾う想定） |

---

## 3. データフロー（シーケンス）

### 録音〜議事録生成

```
[Android]    [Express]    [Azure Speech]   [Claude API]   [Microsoft Graph]
   │            │              │                │                │
   │ 録音開始   │              │                │                │
   ├─会議録音──┤              │                │                │
   │ 録音停止   │              │                │                │
   ├─POST audio─→│              │                │                │
   │            │ ① 保存       │                │                │
   │            ├─upload─────→│                │                │
   │            │← jobUrl ────┤                │                │
   │            │ ② poll      │                │                │
   │← 202 Accepted│              │                │                │
   │            ├─poll status─→│                │                │
   │            │← processing ─┤                │                │
   │            │  (繰返し)    │                │                │
   │            ├─poll status─→│                │                │
   │            │← completed + transcript ──┤   │                │
   │            │ ③ Claude プロンプト生成      │                │
   │            ├──────議事録要約依頼──────→│   │                │
   │            │← Markdown議事録 ──────────┤   │                │
   │            │ ④ docx 生成                                    │
   │            ├──────────────────────────OneDrive upload─────→│
   │            │← sharing_link ───────────────────────────────┤
   │            │ ⑤ meta.json 更新                              │
   │            │                                                │
[Dashboard が 30秒後にポーリングで件数を検知]
```

---

## 4. Android 側 詳細仕様

### 4.1 追加ファイル

| ファイル | 役割 |
|---|---|
| `MeetingRecorder.kt` | MediaRecorder のラッパー。 m4a/AAC 64kbps mono 録音、開始/停止 |
| `MeetingActivity.kt` | 録音UI画面。「会議開始」「終了して送信」ボタン |
| `RecordingUploader.kt` | OkHttp multipart で `/ingest/recording` へPOST |
| `ConsentDialog.kt` | 録音開始前の同意取得ダイアログ |

### 4.2 AndroidManifest 追加権限

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
```

### 4.3 録音設定 (MeetingRecorder.kt)

```kotlin
recorder = MediaRecorder().apply {
    setAudioSource(MediaRecorder.AudioSource.MIC)
    setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
    setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
    setAudioSamplingRate(16000)        // Azure Speech 推奨
    setAudioChannels(1)                 // モノラル(話者分離は単一chでも可)
    setAudioEncodingBitRate(64_000)     // 64kbps で十分
    setOutputFile(audioFile.absolutePath)
    prepare()
    start()
}
```

### 4.4 アップロード仕様

```
POST {SERVER}/ingest/recording
Content-Type: multipart/form-data; boundary=...

[Part 1: metadata]
Content-Disposition: form-data; name="meta"
Content-Type: application/json
{
  "device_id": "3F:A8:91:0C:7B:E2",
  "room_id":   "medium",
  "title":     "週次定例MTG",
  "started_at":"2026-05-09T14:00:00+09:00",
  "ended_at":  "2026-05-09T15:00:00+09:00",
  "attendees_estimated": 4,
  "language":  "ja-JP"
}

[Part 2: audio]
Content-Disposition: form-data; name="audio"; filename="meeting.m4a"
Content-Type: audio/mp4
<binary m4a data>
```

---

## 5. Express バックエンド 詳細仕様

### 5.1 追加モジュール構成

```
TestDashboard/
├── server.js                       既存 (route mount のみ追加)
├── routes/
│   ├── recording.js                NEW: POST /ingest/recording
│   ├── minutes.js                  NEW: GET /api/minutes/*, DELETE
│   └── azure-callback.js           NEW: Azure callback (Optional)
├── services/
│   ├── azure-speech.js             NEW: Conversation Transcription API
│   ├── claude.js                   NEW: Anthropic SDK
│   ├── docx-builder.js             NEW: docx package で議事録生成
│   ├── graph.js                    NEW: Microsoft Graph (OneDrive/Teams)
│   └── job-store.js                NEW: meta.json or SQLite ラッパー
├── prompts/
│   └── meeting-minutes-ja.md       NEW: Claude プロンプトテンプレート
├── storage/
│   ├── audio/                      <job_id>.m4a (一時)
│   ├── transcripts/                <job_id>.json (Azure返却)
│   ├── minutes/                    <job_id>.docx (生成済)
│   └── meta.json                   ジョブメタデータ
└── .env                            NEW: 全シークレット
```

### 5.2 内部 API スペック

#### POST `/ingest/recording`
**目的**: Android からの音声受信、ジョブ起動

**Request**: multipart/form-data (上記 4.4 参照)

**Response (即返却)**:
```json
{
  "ok": true,
  "job_id": "uuid-v4-xxxx",
  "status": "queued",
  "message": "transcription job started"
}
```

**HTTP Code**: `202 Accepted`

**処理**:
1. multer で multipart 受信 → `storage/audio/{job_id}.m4a`
2. meta.json に `{ status: "queued" }` で記録
3. 非同期タスク開始（`processJob(job_id)` を queue）
4. 即 202 を返却

---

#### GET `/api/minutes/:roomId`
**目的**: 会議室別の議事録一覧（ダッシュボード用）

**Response**:
```json
{
  "ok": true,
  "roomId": "medium",
  "minutes": [
    {
      "id": "uuid-v4-xxxx",
      "title": "週次定例MTG",
      "startedAt": "2026-05-09T14:00:00+09:00",
      "durationSec": 3600,
      "speakerCount": 4,
      "status": "ready",
      "downloadPath": "/api/minutes/uuid-v4-xxxx/download",
      "oneDriveLink": "https://contoso.sharepoint.com/...",
      "summary": "週次の定例ミーティング。新規プロジェクト方針について..."
    }
  ]
}
```

---

#### GET `/api/minutes/:id`
議事録詳細（発言記録・サマリ・アクションアイテムを返却）

#### GET `/api/minutes/:id/download`
ローカルの .docx ファイルをダウンロード（attachment ヘッダー付き）

#### POST `/api/minutes/:id/reprocess`
失敗ジョブの再処理（管理者用）

#### DELETE `/api/minutes/:id`
議事録削除（音声・docx・meta から削除）

---

## 6. 外部 API 連携 詳細

### 6.1 Azure Speech - Conversation Transcription

**選定**: REST API バッチモード（>5分の会議に最適）

#### Step 1: Azure Speech へオーディオアップロード
```http
POST https://{REGION}.api.cognitive.microsoft.com/speechtotext/v3.1/transcriptions
Authorization: Ocp-Apim-Subscription-Key: {AZURE_SPEECH_KEY}
Content-Type: application/json

{
  "displayName": "meeting_{job_id}",
  "description": "会議室={room_id}, device={device_id}",
  "locale": "ja-JP",
  "contentUrls": [ "{azure_blob_or_signed_url}" ],
  "properties": {
    "diarizationEnabled": true,
    "diarization": {
      "speakers": { "minCount": 2, "maxCount": 8 }
    },
    "wordLevelTimestampsEnabled": true,
    "punctuationMode": "DictatedAndAutomatic",
    "profanityFilterMode": "Masked"
  }
}
```

**Response 201**:
```json
{
  "self": "https://...transcriptions/abc-123",
  "status": "NotStarted"
}
```

> 💡 **音声URLについて**: Azure Speech は Public URL もしくは Azure Blob Storage SAS URL のみ受付。本実装では **Cloudflare Tunnel 経由で `/audio/<job_id>.m4a` を一時公開** し、そのURLを `contentUrls` に渡す。

#### Step 2: ステータスポーリング
```http
GET https://...transcriptions/abc-123
Authorization: Ocp-Apim-Subscription-Key: {KEY}
```

`status` が `Succeeded` になるまで30秒間隔でポーリング（タイムアウト: 30分）。

#### Step 3: 結果ファイル取得
```http
GET https://...transcriptions/abc-123/files
```

→ `transcription_*.json` ファイルのURLを取得 → ダウンロード。

#### Step 4: パース
```json
{
  "recognizedPhrases": [
    {
      "speaker": 1,
      "offset": "PT0S",
      "duration": "PT3.2S",
      "nBest": [
        { "display": "おはようございます。本日の議題は..." }
      ]
    },
    ...
  ]
}
```

→ `[{ speakerId: 1, start: 0.0, end: 3.2, text: "..." }, ...]` に変換。

### 6.2 Claude API - 議事録要約

```javascript
const Anthropic = require("@anthropic-ai/sdk");
const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

const response = await client.messages.create({
  model: "claude-sonnet-4-6",
  max_tokens: 4096,
  system: SYSTEM_PROMPT_JA,  // prompts/meeting-minutes-ja.md の内容
  messages: [{
    role: "user",
    content: `## 会議メタ情報
会議室: ${roomName}
日時: ${startedAt}
時長: ${duration}分
推定話者数: ${speakerCount}

## 文字起こし（話者分離済）
${transcriptText}

上記から議事録を生成してください。`
  }],
});

const minutesMarkdown = response.content[0].text;
```

#### システムプロンプト (`prompts/meeting-minutes-ja.md`)

```
あなたはプロの議事録作成者です。以下の文字起こしから、構造化された議事録を
Markdown 形式で作成してください。

## 必須セクション
1. **会議サマリ** (3-5文)
2. **議題と要点** (推定3-5項目、各 50-100文字)
3. **発言ハイライト** (重要な発言のみ、時系列、{HH:MM} {Speaker N}: {要約})
4. **決定事項** (箇条書き、5項目以内)
5. **アクションアイテム** (担当 / 内容 / 期限) - 期限は推定でも可
6. **未解決事項** (次回持ち越し)

## ルール
- 推測しない: 文字起こしに無い内容は書かない
- 個人情報配慮: 機密性の高い数値・固有名詞は [REDACTED] と表記
- 簡潔: 1議題あたり最大200文字
- 同一話者連続発言はマージ
- 関係ない雑談 (天気・休憩) は省略
- 出力は素のMarkdownのみ (```マーカー不要)
```

### 6.3 Microsoft Graph - OneDrive アップロード

#### 認証 (client_credentials flow)
```http
POST https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

client_id={APP_ID}
&client_secret={CLIENT_SECRET}
&scope=https://graph.microsoft.com/.default
&grant_type=client_credentials
```

→ `access_token` を取得（1時間有効）。

#### .docx を OneDrive へアップロード
```http
PUT https://graph.microsoft.com/v1.0/users/{USER_PRINCIPAL_NAME}/drive/root:/Apps/MeetingMinutes/{filename}.docx:/content
Authorization: Bearer {access_token}
Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document

<binary docx>
```

**Response**: 作成された DriveItem (id, webUrl 含む)

#### 共有リンク作成（任意）
```http
POST https://graph.microsoft.com/v1.0/drives/{drive-id}/items/{item-id}/createLink
Content-Type: application/json

{ "type": "view", "scope": "organization" }
```

**Response**: `{ "link": { "webUrl": "https://contoso.sharepoint.com/..." } }`

#### Teams Channel 保存（オプション）
```http
PUT https://graph.microsoft.com/v1.0/teams/{team-id}/channels/{channel-id}/filesFolder/children/{filename}.docx/content
```

> **注意**: Teams Channel への直接書き込みは権限 `Group.ReadWrite.All` が必要。OneDriveよりハードル高め。代替として「OneDrive保存後にTeamsチャンネルへリンクをチャット送信」が運用上シンプル。

### 6.4 Microsoft Graph - Teams Online Meeting Transcript

#### 6.4.1 概要

Teams Live Transcript API は **会議終了時** にトランスクリプトを取得できる API です。
組織主催の Teams 会議で「Live Transcript（ライブトランスクリプト）」が有効化されている必要があります。

要件:
- M365 E3/E5 ライセンス
- 会議主催者が「Record and Transcribe」を有効化
- App に `OnlineMeetingTranscript.Read.All` 権限

#### 6.4.2 取得フロー

```
[1] Teams会議終了
       ↓
[2] Microsoft Graph が Webhook 通知 (resource: getAllTranscripts)
       ↓ POST → Azure Functions
[3] 通知から meetingId と transcriptId を抽出
       ↓
[4] 認証 Token取得 (client_credentials flow)
       ↓
[5] Transcript content取得 (VTT形式)
       ↓
[6] Azure Blob 格納 + Azure Queue にメッセージ Push
       ↓
[7] Express がキューを監視 → 取得 → マージ処理
```

#### 6.4.3 トランスクリプト取得 API

```http
GET https://graph.microsoft.com/v1.0/users/{user-id}
       /onlineMeetings/{meeting-id}
       /transcripts/{transcript-id}/content?$format=text/vtt
Authorization: Bearer {access_token}
Accept: text/vtt
```

**Response (VTT形式)**:
```
WEBVTT

00:00:00.000 --> 00:00:05.000
<v 山田太郎>おはようございます。本日の議題は新製品リリースについて...</v>

00:00:05.000 --> 00:00:10.000
<v 佐藤花子>承知しました。まず現在の進捗状況を共有させていただきます...</v>

00:00:10.500 --> 00:00:13.200
<v 田中一郎>質問ですが、リリース日は確定でしょうか？</v>
```

#### 6.4.4 VTT パース実装

```javascript
// services/teams-transcript.js
function parseVtt(vttContent) {
  const segments = [];
  const blocks = vttContent.split(/\n\n/).filter(b => b.includes("-->"));

  for (const block of blocks) {
    const lines = block.trim().split("\n");
    const timeLine = lines.find(l => l.includes("-->"));
    const textLine = lines[lines.length - 1];

    const [startStr, endStr] = timeLine.split(" --> ");
    const speakerMatch = textLine.match(/<v ([^>]+)>([\s\S]*?)<\/v>/);

    segments.push({
      start: vttTimeToSeconds(startStr),
      end:   vttTimeToSeconds(endStr),
      speaker: speakerMatch ? speakerMatch[1].trim() : "Unknown",
      text:    speakerMatch ? speakerMatch[2].trim() : textLine,
      source:  "teams"
    });
  }
  return segments;
}
```

### 6.5 Azure Functions - Webhook Receiver

#### 6.5.1 構成

```
Functions App: meeting-minutes-webhook
├── functions/
│   ├── ValidateSubscription   GET /api/notifications  (検証時)
│   ├── ReceiveNotification    POST /api/notifications (実通知時)
│   └── RenewSubscription      Timer trigger (毎日)
├── shared/
│   ├── graphClient.js         MSAL + Graph SDK
│   └── blobQueue.js           Azure Storage SDK
├── host.json
└── local.settings.json
```

#### 6.5.2 Webhook 検証 (subscription 作成時)

Microsoft Graph は subscription 作成時に `validationToken` を付けて GET します。
Functions はこれをそのまま 200 で返却する必要があります。

```javascript
// functions/ValidateSubscription/index.js
module.exports = async function (context, req) {
  const validationToken = req.query.validationToken;
  if (validationToken) {
    context.res = {
      status: 200,
      headers: { "Content-Type": "text/plain" },
      body: validationToken
    };
    return;
  }
  // 通常通知へフォールスルー
  await handleNotification(context, req);
};
```

#### 6.5.3 通知受信処理

```javascript
async function handleNotification(context, req) {
  const notifications = req.body.value || [];
  for (const n of notifications) {
    // clientState 検証 (なりすまし防止)
    if (n.clientState !== process.env.WEBHOOK_CLIENT_STATE) {
      context.log.error("Invalid clientState"); continue;
    }

    // resource: "communications/onlineMeetings('AAMk...')/transcripts('MSMm...')"
    const m = n.resource.match(/onlineMeetings\('([^']+)'\)\/transcripts\('([^']+)'\)/);
    if (!m) continue;
    const [, meetingId, transcriptId] = m;

    // Graph APIから transcript 取得
    const token = await getGraphToken();
    const vtt   = await fetchTranscript(token, meetingId, transcriptId);

    // Blob 保存
    const blobName = `transcripts/${meetingId}/${transcriptId}.vtt`;
    await uploadBlob(blobName, vtt);

    // Queue へメッセージ
    await sendQueueMessage("minutes-jobs", {
      meetingId,
      transcriptId,
      blobUrl: blobName,
      receivedAt: new Date().toISOString()
    });
  }
  context.res = { status: 202 };
}
```

#### 6.5.4 Subscription 自動更新 (Timer Trigger)

Microsoft Graph subscription は **最大3日間**しか有効でないため、毎日12時間ごとに更新:

```javascript
// functions/RenewSubscription/index.js
// CRON: "0 0 */12 * * *" (12時間毎)
module.exports = async function (context, myTimer) {
  const token = await getGraphToken();
  const subs = await listSubscriptions(token);
  for (const s of subs) {
    if (new Date(s.expirationDateTime) - Date.now() < 24*3600*1000) {
      await renewSubscription(token, s.id, addDays(new Date(), 3));
      context.log(`Renewed subscription ${s.id}`);
    }
  }
};
```

### 6.6 Azure Queue Storage - Express からの取り込み

Express側ではキューをポーリングして新しいトランスクリプトを取り込みます:

```javascript
// services/teams-queue-poller.js
const { QueueClient } = require("@azure/storage-queue");
const queue = new QueueClient(CONN_STRING, "minutes-jobs");

setInterval(async () => {
  const { receivedMessageItems } = await queue.receiveMessages({ numberOfMessages: 10 });
  for (const msg of receivedMessageItems) {
    const job = JSON.parse(Buffer.from(msg.messageText, "base64").toString());
    await processTeamsTranscript(job);
    await queue.deleteMessage(msg.messageId, msg.popReceipt);
  }
}, 30000);
```

### 6.7 トランスクリプトマージ (核心ロジック)

物理参加者の発言と Teams 参加者の発言を **時系列でマージ** し、議事録を生成します。

```javascript
// services/transcript-merger.js
function mergeTranscripts(roomSegments, teamsSegments, meetingStartTimeIso) {
  const meetingStart = new Date(meetingStartTimeIso).getTime();

  // Teams側のタイムスタンプは会議開始からの相対秒
  // Room側のタイムスタンプも録音開始からの相対秒（録音開始 ≈ 会議開始と仮定）
  // 必要に応じてオフセット調整

  const all = [
    ...roomSegments.map(s => ({
      ...s,
      source: "room",
      speaker: `Room-${s.speakerId}`,    // Speaker 1 → Room-1
      absoluteTimestamp: new Date(meetingStart + s.start * 1000).toISOString()
    })),
    ...teamsSegments.map(s => ({
      ...s,
      source: "teams",
      speaker: s.speaker,                 // 既に実名
      absoluteTimestamp: new Date(meetingStart + s.start * 1000).toISOString()
    }))
  ];

  // 開始時刻でソート
  all.sort((a, b) => a.start - b.start);

  // 同時発言の重複除去 (Teams の transcript と Room のマイクが同じ声を拾う場合)
  return deduplicateOverlap(all);
}

function deduplicateOverlap(segments) {
  // 0.5秒以内に同じ話者の発言があれば1つにマージ
  // または Teams 側を優先（実名つきのほうが優位）
  // ...
}
```

### 6.8 マージ後の議事録例

```markdown
## 発言ハイライト

[14:00:05] 山田太郎 (Teams): 本日の議題は新製品リリースについてです。

[14:00:12] Room-1 (会議室): ありがとうございます。資料の準備はできています。

[14:00:18] 佐藤花子 (Teams): 私から進捗を共有します。先週の課題3件中2件は完了。

[14:00:34] Room-2 (会議室): 残りの1件について教えてください。

[14:00:42] 田中一郎 (Teams): 残課題はAPIの仕様変更で、来週月曜まで延長したいです。
...
```

物理参加者は `Room-1`/`Room-2` のラベル、Teams参加者は実名で表示されます。
ダッシュボードで Room ラベルを後から実名にマップ可能（次回会議で再利用）。

---

## 7. Azure AD App Registration

### 7.1 必要な権限（Application permissions）

| API | 権限 | 用途 |
|---|---|---|
| Microsoft Graph | **Files.ReadWrite.All** | OneDrive/SharePoint 書込 |
| Microsoft Graph | **Sites.ReadWrite.All** | SharePoint Library 書込（社内共有用） |
| Microsoft Graph | **OnlineMeetings.Read.All** | Teams 会議メタ情報取得 |
| Microsoft Graph | **OnlineMeetingTranscript.Read.All** | **Teams Live Transcript取得（重要）** |
| Microsoft Graph | OnlineMeetingRecording.Read.All | （任意）Teams 録画も取得する場合 |
| Microsoft Graph | User.Read.All | 出席者情報取得 |
| Microsoft Graph | Calendars.Read | Outlook予定表から会議名取得 |

> ChannelMessage.Send / Group.ReadWrite.All は今回不要（Teams保存はファイルAPIで代替）。
> **OnlineMeetingTranscript.Read.All** はTeams Live Transcript用に必須。Application permission として承認依頼が必要。

### 7.2 管理者依頼テンプレート

以下を IT 管理者に提出します:

```
件名: 議事録自動生成システムのため Azure AD App Registration をお願いします

依頼内容:
- App名: OccupancyCounter-MeetingMinutes
- Sign-in audience: Single tenant
- Required Application permissions:
  - Microsoft Graph > Files.ReadWrite.All (Application)
  - Microsoft Graph > Sites.ReadWrite.All (Application)  ※社内SharePoint Library 書込が必要な場合
  - Microsoft Graph > OnlineMeetings.Read.All (Application)
  - Microsoft Graph > OnlineMeetingTranscript.Read.All (Application)  ※Teams Live Transcript用
  - Microsoft Graph > User.Read.All (Application)
  - Microsoft Graph > Calendars.Read (Application)
- Admin consent: 必要

追加で必要なAzureリソース:
- Azure Functions (Consumption Plan で月数百円〜)
- Azure Storage Account (Blob + Queue 用)
- Azure AI Speech Service (japaneast region)

提供してほしい情報:
- Tenant ID
- Application (client) ID
- Client secret value (有効期限24ヶ月推奨)
- 議事録保存先の Drive ID もしくは Site ID
  (例: contoso-my.sharepoint.com の特定ライブラリ)
- Azure Functions / Storage 用の Resource Group とサブスクリプション ID
- Teams 会議のorganizer になるサービスアカウントUPN
  (例: meetingbot@contoso.onmicrosoft.com)
```

### 7.3 サービスアカウント設計

Teams Live Transcript API は **organizer のオンライン会議**のみ取得可能。
そのため運用設計では以下を推奨:

**A. 各社員が主催した会議を取得する場合**
- App permission `OnlineMeetingTranscript.Read.All` で組織内全会議が対象
- ただし会議主催者が「Live Transcript を有効化」している必要あり

**B. 専用「議事録ボット」アカウントを作成する場合**
- 会議招待時に `meetingbot@contoso.com` を必須参加者に追加するルール
- 議事録機能ON運用が明確になる
- ただし会議主催者の同意が必要（録音と同義）

---

## 8. 環境変数定義 (.env)

### 8.1 Express バックエンド (TestDashboard)

```bash
# === Azure Speech ===
AZURE_SPEECH_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
AZURE_SPEECH_REGION=japaneast

# === Anthropic Claude ===
ANTHROPIC_API_KEY=sk-ant-api03-xxxxxxx
CLAUDE_MODEL=claude-sonnet-4-6

# === Microsoft Graph (Azure AD App) ===
MS_TENANT_ID=00000000-0000-0000-0000-000000000000
MS_CLIENT_ID=11111111-1111-1111-1111-111111111111
MS_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxx
MS_USER_UPN=meetingbot@contoso.onmicrosoft.com
MS_DRIVE_PATH=/Apps/MeetingMinutes

# === Azure Storage (Functions と共有) ===
AZURE_STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=...
AZURE_QUEUE_NAME=minutes-jobs
AZURE_BLOB_CONTAINER=transcripts

# === 任意: Teams 連携 ===
MS_TEAMS_TEAM_ID=zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz
MS_TEAMS_CHANNEL_ID=channel-id-here

# === Server ===
PORT=3000
PUBLIC_BASE_URL=https://your-tunnel.trycloudflare.com
CORS_ORIGIN=*
```

### 8.2 Azure Functions (meeting-minutes-webhook)

```bash
# === Microsoft Graph (Express と同じ App を使用) ===
MS_TENANT_ID=00000000-0000-0000-0000-000000000000
MS_CLIENT_ID=11111111-1111-1111-1111-111111111111
MS_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxx

# === Webhook security ===
WEBHOOK_CLIENT_STATE=long-random-string-for-validation
WEBHOOK_NOTIFICATION_URL=https://meeting-minutes-webhook.azurewebsites.net/api/notifications

# === Azure Storage (Express と共有) ===
AZURE_STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=...
AZURE_QUEUE_NAME=minutes-jobs
AZURE_BLOB_CONTAINER=transcripts

# === Subscription resource ===
# 監視対象会議のorganizer UPN (例: 専用議事録ボット)
SUBSCRIPTION_USER_ID=meetingbot@contoso.onmicrosoft.com
SUBSCRIPTION_EXPIRATION_HOURS=72   # Microsoft Graph上限は4230分=70.5時間
```

---

## 9. データモデル

### 9.1 `storage/meta.json` 構造

```json
{
  "version": 1,
  "minutes": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "roomId": "medium",
      "deviceId": "3F:A8:91:0C:7B:E2",
      "title": "週次定例MTG",
      "startedAt": "2026-05-09T14:00:00+09:00",
      "endedAt":   "2026-05-09T15:00:00+09:00",
      "durationSec": 3600,
      "language": "ja-JP",
      "attendees": { "estimated": 4, "fromFaceDetection": 4 },

      "files": {
        "audio":  "audio/550e8400.m4a",
        "transcript": "transcripts/550e8400.json",
        "docxLocal":  "minutes/550e8400.docx",
        "docxOneDrive": {
          "driveItemId": "01XXXX...",
          "webUrl": "https://contoso-my.sharepoint.com/...",
          "shareLink": "https://contoso-my.sharepoint.com/:w:/g/...",
          "uploadedAt": "2026-05-09T15:05:32+09:00"
        }
      },

      "transcription": {
        "sources": ["room", "teams"],
        "speakerCountTotal": 5,
        "wordCount": 8421,
        "room": {
          "provider": "azure-speech",
          "azureJobUrl": "https://...transcriptions/abc-123",
          "speakerCount": 2
        },
        "teams": {
          "provider": "ms-graph-transcript",
          "meetingId": "AAMkAGI2NGFiNjAxLT...",
          "transcriptId": "MSMmMjQyZGYxLTIzZGUtNDY...",
          "speakers": ["山田太郎", "佐藤花子", "田中一郎"],
          "speakerCount": 3
        }
      },
      "attendees": {
        "physical": ["Room-1", "Room-2"],
        "remote":   ["山田太郎", "佐藤花子", "田中一郎"],
        "total":    5
      },

      "summary": {
        "provider": "claude-sonnet-4-6",
        "tokensIn": 12500,
        "tokensOut": 1850,
        "summary": "週次の定例ミーティング。新規プロジェクト...",
        "topics": ["プロジェクト進捗", "リソース調整", "次週優先事項"],
        "decisions": [...],
        "actionItems": [...]
      },

      "status": "ready",
      "errors": []
    }
  ]
}
```

`status` の遷移: `queued` → `transcribing` → `summarizing` → `uploading` → `ready` / `failed`

### 9.2 状態遷移図

```
[Android upload]
    ↓
queued  ──→  transcribing  ──→  summarizing  ──→  uploading  ──→  ready
                  ↓                  ↓                  ↓
                 failed            failed            failed
                  ↓
              [retry possible via POST /api/minutes/:id/reprocess]
```

---

## 10. .docx 生成仕様（docx-builder.js）

`docx` npm パッケージで以下構造を出力:

```
[ヘッダー]
─────────────────────
        会議議事録
─────────────────────

[メタ情報テーブル]
| 項目 | 値 |
|---|---|
| 会議名 | 週次定例MTG |
| 日時 | 2026-05-09 14:00 〜 15:00 (60分) |
| 場所 | 中会議室 |
| 出席者数 | 4名（推定）|
| 録音端末 | 3F:A8:91:0C:7B:E2 |

[サマリ]
（Claude生成のサマリ）

[議題と要点]
1. ...
2. ...

[発言ハイライト]
14:00 Speaker 1: ...
14:03 Speaker 2: ...
...

[決定事項]
- ...

[アクションアイテム]
| 担当 | 内容 | 期限 |
|---|---|---|
| Speaker 1 | ... | 5/16 |

[未解決事項]
- ...

[フッター]
本議事録は OccupancyCounter Auto-Minutes により自動生成されました
生成: 2026-05-09 15:05 JST
```

---

## 11. ダッシュボード（GitHub Pages）拡張仕様

### 11.1 各会議室カードへの追加要素

```html
<div class="room">
  <div class="room-name">中会議室</div>
  <div class="headcount">5/6</div>
  <!-- 既存 -->

  <!-- 新規 -->
  <div class="minutes-badge" onclick="openMinutes('medium')">
    📄 議事録 (3件 ・ 物理2 + リモート3)
  </div>
</div>
```

各議事録カードでは「物理 N名 + リモート M名」を表示し、ハイブリッド会議であることを視覚化:

```
┌──────────────────────────────────────────┐
│ 📄 週次定例MTG                             │
│    2026-05-09 14:00 (60分)                │
│    🏢 物理 2名 + 💻 リモート 3名 = 5名      │
│    [Word DL] [OneDriveで開く]              │
└──────────────────────────────────────────┘
```

### 11.2 議事録モーダル

```
┌──────────────────────────────────────────┐
│ 中会議室の議事録 (3件)                    │ × │
├──────────────────────────────────────────┤
│  📄 週次定例MTG                            │
│     2026-05-09 14:00 (60分・4名)           │
│     新規プロジェクト方針について議論...      │
│     [Word DL] [OneDriveで開く]              │
├──────────────────────────────────────────┤
│  📄 緊急対応会議                           │
│     2026-05-08 16:30 (30分・3名)           │
│     ...                                   │
│     [Word DL] [OneDriveで開く]              │
└──────────────────────────────────────────┘
```

### 11.3 dashboard.js への追加処理

- 既存ポーリングで `data.minutesCount[roomId]` を取得
- バッジに件数を反映
- クリックで `/api/minutes/:roomId` を fetch → モーダル表示

---

## 12. Phase別 実装計画（8週間）

| Week | フェーズ | 主要タスク | 完了条件 |
|---|---|---|---|
| W1 | Android 録音 | MeetingRecorder + UI + Manifest 権限 + Uploader | スマホで録音 → m4a が手元PCに到達 |
| W2 | Azure Speech 連携 | upload → transcription → poll → parse | Azure Speech 結果 JSON が取得できる |
| W3 | Claude 要約 | プロンプト + API呼出 + .docx生成 | ローカルで .docx ファイルが完成 |
| W4 | Microsoft Graph (OneDrive) | 認証 + OneDrive 書込 + sharing link | OneDrive に .docx 自動配置される |
| W5 | **Azure Functions 構築** | Functions プロジェクト作成 + Storage Account + Subscription登録 | Webhook が validation を返却・通知が受信できる |
| W6 | **Teams Live Transcript 連携** | VTT パース + Blob/Queue 連携 | Teams会議終了後にqueueにメッセージが入る |
| W7 | **Transcript Merger 実装** | room/teams マージ + 重複除去 + 議事録生成 | ハイブリッド会議で1つの議事録が生成される |
| W8 | ダッシュボード統合 + E2E検証 | Modal UI + バッジ + テスト + ドキュメント | 一連フロー完成・本番運用可能 |

---

## 13. コスト試算（月間）

前提: **月20会議 × 平均1時間**、ハイブリッド会議で半数（10件）が物理＋Teams、残り半数は片方のみ

| サービス | 単価 | 月額 | 備考 |
|---|---|---|---|
| Azure Speech Conversation Transcription | $1.40/時間 | **$21.0** | 物理参加分のみ計上 (15件) |
| Microsoft Graph Teams Transcript | 無料 (M365ライセンス内) | **$0** | E3/E5に含まれる |
| Anthropic Claude Sonnet 4.6 | $3/Mtok in, $15/Mtok out | **$3.4** | 全会議共通 |
| Azure Functions (Consumption) | $0.20/100万実行 | **$0.5** | 月100実行未満想定 |
| Azure Blob Storage | $0.018/GB/月 | **$0.3** | transcript<10MB×100件想定 |
| Azure Queue Storage | $0.045/100万操作 | **$0.1** | |
| Microsoft Graph API | 無料 | $0 | |
| **合計** | | **約 $25 ≒ 3,800円** |

> **改善**: Teams会議分はAzure Speechがゼロ円なので、Teams中心の運用ならコストはむしろ下がります。

**コスト削減オプション**:
- Teams 主体運用に切替 → Azure Speech 不要 → -$15 ($10/月)
- Claude Haiku 4.5 へ変更 → -$2 (3,200円/月)
- Azure Functions Consumption → Premium へ移行は不要（規模次第）

**追加コスト要因**:
- Azure Speech batch transcription はストレージI/Oも課金あり (微小)
- 大規模化で会議数が10倍以上になる場合、Azure Functions も Premium plan 検討

---

## 14. セキュリティ考慮事項

### 14.1 データの取扱い

| データ | 一時保存場所 | 削除タイミング | 暗号化 |
|---|---|---|---|
| 音声ファイル (.m4a) | Express PC `storage/audio/` | 議事録生成完了後7日 | TLS in transit |
| Transcript JSON | Express PC `storage/transcripts/` | 90日 | TLS in transit |
| 議事録 (.docx) | OneDrive (永続) | 規程に従う | M365暗号化 |

### 14.2 認証情報管理

- `.env` ファイルは **絶対に Git コミットしない** (`.gitignore` 追加)
- Client Secret は Azure Key Vault への移行を推奨（運用フェーズ）
- API キーローテーション: 6ヶ月ごと

### 14.3 録音同意

- Android アプリで録音開始時に **音声＋画面表示** で告知
- 議事録冒頭にも「自動文字起こし対象会議」と明記
- 就業規則・労使協定に追記（人事・法務確認）

### 14.4 アクセス制御

- 議事録の OneDrive リンクは **組織内のみ** にスコープ制限
- ダッシュボードの議事録ダウンロードは将来的にBASIC認証 or M365 SSO化

---

## 15. テスト計画

### 単体テスト
- `services/azure-speech.js` モック化（実APIキー不要）
- `services/claude.js` 固定プロンプト→固定出力検証
- `services/docx-builder.js` 出力 .docx を python-docx でパース確認

### 統合テスト
- 短い test.m4a (10秒・2話者) で全フロー実行
- 各ステップごとの `meta.json` 状態確認
- エラー注入テスト: Azure Speech 502, Claude rate limit, Graph 401

### 受入テスト
- 実際の30分会議で議事録生成 → 人手レビュー
- 話者ラベル精度を測定（正解ラベルとの一致率）
- 議事録要約品質を5段階評価

---

## 16. 既知の制約・リスク

| リスク | 影響 | 対策 |
|---|---|---|
| Azure Speech が固有名詞を誤認識 | 議事録品質低下 | Custom Speech モデルで会社固有用語を学習（W6以降） |
| 話者ラベルが Speaker 1/2... のまま | 誰の発言か不明 | 議事録UI で実名にマップ → 次回会議で再利用 |
| Claude が事実誤認した要約 | 誤情報拡散 | プロンプトで「文字起こし以外推測しない」厳守、人手レビュー必須 |
| OneDrive の容量上限 | 保存失敗 | 1GB以上のファイルは事前圧縮、古い音声を自動削除 |
| 長時間会議 (>2時間) でAzure Speech タイムアウト | 失敗 | 30分ごとに分割アップロード、複数ジョブを後でマージ |
| Cloudflare Tunnel URL 変更 | Azure Speech が音声取得できず失敗 | 固定URL移行（Named Tunnel or Azure Blob 経由に） |

---

## 17. 拡張ロードマップ（将来）

| Phase | 機能 |
|---|---|
| V1.1 | 話者プロファイル登録（音声サンプルから個人特定） |
| V1.2 | Outlook 予定表連携（会議名・出席者自動入力） |
| V1.3 | リアルタイム文字起こし（会議中に画面表示） |
| V2.0 | Teams Bot として参加 → Teams 会議自体を録音 |
| V2.1 | 多言語対応（英語混在会議で自動言語判定） |
| V2.2 | 議事録の検索・横断分析（過去会議の決定事項検索） |
| V3.0 | Plan B 移行（オンプレ WhisperX へ切替可能設計） |

---

## 18. 次の具体的アクション

### 即時（今日〜来週）

1. **IT管理者に Azure AD App Registration 依頼書を提出**（Section 7.2 のテンプレ使用）
2. **Azure サブスクリプション準備** （未契約なら）
   - Azure Portal で Free Trial 申請
   - Speech Service リソース作成 (japaneast region)
3. **Anthropic API キー取得**
   - https://console.anthropic.com → API Keys → Create

### W1 開始時

4. Android アプリに録音モジュール追加（既存リポジトリにブランチ作成）
5. Express バックエンドに `routes/recording.js` 追加（multer 受信のみ）

### 環境準備チェックリスト

- [ ] Azure サブスクリプション (Speech + Functions + Storage 利用可)
- [ ] Azure AD App ID / Client Secret / Tenant ID
- [ ] **Azure AD App に `OnlineMeetingTranscript.Read.All` 権限付与済み**
- [ ] **議事録ボット用サービスアカウント（meetingbot@... 等）**
- [ ] **Azure Storage Account (Blob + Queue)**
- [ ] **Azure Functions リソース作成 (Consumption プラン)**
- [ ] OneDrive または SharePoint 保存先パス
- [ ] Anthropic API Key
- [ ] `.env` ファイル雛形 (Section 8 のテンプレ使用)
- [ ] 録音同意ポリシー（人事確認済み）
- [ ] **Teams 会議で「Live Transcript」を有効化する社内ガイドライン**
- [ ] テスト用ハイブリッド会議の手配（物理2名 + Teams 2名・15分）

### Azure リソース構築順（Functions構築フェーズ用）

1. **Azure Storage Account** 作成 (kind: StorageV2)
2. **Blob Container** `transcripts` 作成
3. **Queue** `minutes-jobs` 作成
4. **Functions App** 作成 (Node.js 22, Consumption Plan, japaneast)
5. App Settings に MS_TENANT_ID 等の環境変数を設定
6. Functions コードをデプロイ (`func azure functionapp publish meeting-minutes-webhook`)
7. **Microsoft Graph subscription を作成**:
   ```bash
   curl -X POST 'https://graph.microsoft.com/v1.0/subscriptions' \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "changeType": "created",
       "notificationUrl": "https://meeting-minutes-webhook.azurewebsites.net/api/notifications",
       "resource": "communications/onlineMeetings/getAllTranscripts(meetingOrganizerUserId='\''SUBSCRIPTION_USER_ID'\'')",
       "expirationDateTime": "2026-05-12T00:00:00Z",
       "clientState": "WEBHOOK_CLIENT_STATE"
     }'
   ```
8. Express バックエンド側に Queue Poller を追加デプロイ

---

## 19. 関連ドキュメント

- 既存システム概要: [`README.md`](./README.md)
- 既存サーバー仕様: [`TestDashboard/README.md`](./TestDashboard/README.md)
- Android アプリ仕様: [`OccupancyCounter/README.md`](./OccupancyCounter/README.md)
- 検証レポート: [`VALIDATION_REPORT.md`](./VALIDATION_REPORT.md)
- AI開発推進手順: [`Claude_AI開発推進手順.md`](./Claude_AI開発推進手順.md)

---

**最終更新**: 2026-05-09 / **承認待ち**: IT管理者依頼書（Section 7.2）
