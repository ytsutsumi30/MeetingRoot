# 最終検証レポート

**検証日**: 2026-05-12（最終更新）  
**初版**: 2026-05-09  
**対象**: OccupancyCounter プロジェクト全体（`C:\PRJ2\dev2`）

---

## サマリ

| 項目 | 結果 |
|------|------|
| W1 headcount インジェスト | ✅ PASS |
| W2 録音アップロード + 文字起こし | ✅ PASS |
| W3 議事録生成（DOCX/Markdown） | ✅ PASS |
| P4 Azure Queue 統合 | ✅ PASS |
| TC-P4-01 parseVttToSegments | ✅ PASS（バグ修正込み） |
| Android ユニットテスト | ✅ BUILD SUCCESSFUL |
| セキュリティ (.env 除外 / npm audit) | ✅ PASS |
| インフラ (Azurite / rotate / healthz) | ✅ PASS |
| **スモークテスト 23ケース** | **✅ 23/23 PASS（2回連続）** |

---

## システム構成図（最新）

```
Android (OccupancyCounter)
  │  POST /ingest/headcount  ← 人数カウント
  │  POST /ingest/recording  ← 会議録音アップロード
  ▼
TestDashboard (Node.js / Express :3000)
  ├─ services/job-processor.js   ← ジョブ管理 (storage/jobs/ に永続化)
  ├─ services/azure-speech.js    ← 文字起こし (Mock対応)
  ├─ services/claude.js          ← 議事録生成 (Mock対応)
  ├─ services/docx-builder.js    ← DOCX生成
  ├─ services/graph.js           ← Teams連携 + OneDriveアップロード (Mock対応)
  ├─ services/audio-publisher.js ← 音声ファイル公開 (local/blob)
  └─ services/queue-consumer.js  ← Azure Storage Queue ポーリング (Mock対応)

functions/ (Azure Functions)
  └─ notifications/index.js ← Teams Webhookを受信 → Queue "minutes-jobs" にエンキュー

Azurite (ローカル Azure Storage エミュレーター)
  ├─ Blob Service  http://127.0.0.1:10000
  ├─ Queue Service http://127.0.0.1:10001
  └─ Table Service http://127.0.0.1:10002
```

---

## 検証実行環境

| 項目 | 値 |
|------|-----|
| OS | Windows 11 |
| Node.js | v22.17.1 |
| 検証日時 | 2026-05-12 01:00〜01:20 JST |
| モード | 全モック有効（AZURE_SPEECH_MOCK / CLAUDE_MOCK / GRAPH_MOCK / QUEUE_CONSUMER_MOCK = true） |
| スモークテスト | `scripts/run-smoke-test.ps1 -BASE http://localhost:3000 -JobWaitSec 25` |

---

## W1: headcount インジェスト検証

### TC-W1-01 ✅ PASS — headcount 送信・state反映

```
POST /api/devices  {"device_id":"TEST:00:11:22:33:44","room_id":"large"} → ok:true
POST /ingest/headcount  {"device_id":"TEST:00:11:22:33:44","headcount":7}
GET /api/state → rooms[large].headcount = 7 ✅
```

### TC-W1-02 ✅ PASS — 複数デバイス同時送信

```
POST /ingest/headcount {"device_id":"3F:A8:91:0C:7B:E2","headcount":4}
→ rooms[medium].headcount = 4 ✅
```

### TC-W1-03 ✅ PASS — state リセット

```
DELETE /api/state → 全室 headcount=0 ✅
```

### TC-W1-04 ✅ PASS — 未登録デバイス拒否

```
POST /ingest/headcount {"device_id":"AA:BB:CC:DD:EE:01"}
→ {"ok":false,"message":"device_id AA:BB:CC:DD:EE:01 は未登録です..."} ✅
```

---

## W2: 録音アップロード・文字起こし検証

### TC-W2-01 ✅ PASS — 録音アップロード

```
POST /ingest/recording [multipart: audio=*.m4a]
→ {"ok":true,"job_id":"srv-...","status":"received","message":"transcription started"}
```

### TC-W2-02 ✅ PASS — ジョブ完了（約500ms）

```
GET /api/jobs/<jobId>
→ {"status":"completed","transcript":{"speakerCount":2,"wordCount":64,"segments":[3件]}}
```

### TC-W2-03 ✅ PASS — transcript ファイル保存

```
storage/transcripts/smoke-20260512-010037.json (1443 bytes) ✅
```

### TC-W2-04 ✅ PASS — ジョブ一覧 API

```
GET /api/jobs → {"ok":true,"count":8,"jobs":[...全件 status=completed]}
```

---

## W3: 議事録生成・ダウンロード検証

### TC-W3-01 ✅ PASS — DOCX 生成

```
storage/minutes/smoke-20260512-010037.docx (8971 bytes) ✅
Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document
```

### TC-W3-02 ✅ PASS — DOCX ダウンロード

```
GET /api/minutes/<jobId>/download → HTTP 200, 8935 bytes ✅
```

### TC-W3-03 ✅ PASS — Markdown プレビュー

```
GET /api/minutes/<jobId>/markdown
→ "# 会議サマリ\n... 議題と要点 ... 発言ハイライト ..." (553文字以上) ✅
```

---

## P4: Azure Storage Queue 統合検証

### TC-P4-01 ✅ PASS — parseVttToSegments（バグ修正済み）

**修正前**: 閉じタグ `</v>` がない VTT では `speakerLabel: "Unknown"` になる  
**修正後**: `(?:<\/v>)?` で省略形式に対応

```javascript
// services/graph.js 修正後
const vTagMatch = rawText.match(/^<v\s+([^>]+)>([\s\S]*?)(?:<\/v>)?$/s);
```

```
segment数: 3、speakerLabel: "Speaker 1" / "Speaker 2" 正常抽出 ✅
TC-P4-01: PASSED
```

### TC-P4-02 ✅ PASS — startJobFromTeams（Teams→議事録フロー）

```
jp.startJobFromTeams({segments:[...], meta:{title:"Teams統合テスト"}})
→ status after 8s: completed ✅
→ storage/minutes/teams-test-001.docx (8905 bytes) 生成 ✅
```

### TC-P4-03 ✅ PASS — Queue Mock モード

```
QUEUE_CONSUMER_MOCK=true → ポーリング無効 ✅
```

### TC-P4-04 ✅ PASS — job-processor 永続化 / Azurite Queue 統合

```

追加確認:

```
Azurite Queue (11001) → queue-consumer → startJobFromTeams → completed
jobId: teams-87654321
```
storage/jobs/persist-test-001.json EXISTS ✅
saved status: completed ✅
```

---

## Android ユニットテスト

### TC-AND-01 ✅ BUILD SUCCESSFUL

```
.\gradlew test --no-daemon
BUILD SUCCESSFUL in 10s
27 actionable tasks: 27 up-to-date
```

---

## インフラ検証

### TC-INF-01 ✅ PASS — rotate スクリプト＆ログアーカイブ確認

```
scripts/rotate-azurite-log.ps1 存在 ✅
azurite-data/debug.log.20260511_233825 (14.5MB) アーカイブ ✅
```

### TC-INF-02 ✅ PASS — start-dev.ps1

```
.env 読み込み: OK / azurite 起動: OK / rotate スクリプト: OK
```

### TC-INF-03 ✅ PASS — Azurite 起動

```
Azurite Blob service is successfully listening at http://127.0.0.1:10000
Azurite Queue service is successfully listening at http://127.0.0.1:10001
Azurite Table service is successfully listening at http://127.0.0.1:10002
```

### TC-INF-04 ✅ PASS — /healthz エンドポイント

```
GET /healthz → {"ok":true,"ts":"2026-05-11T16:16:15.764Z"}
```

---

## セキュリティ検証

### TC-SEC-01 ✅ PASS — .env が Git 管理外

```
git ls-files .env → (空) ✅ .gitignore で除外済み
```

### TC-SEC-04 ✅ PASS — npm audit クリーン

```
npm audit --audit-level=high → found 0 vulnerabilities ✅
```

---

## スモークテスト総合結果

```
============================================
 Test Results
============================================
  PASS: 23
  WARN: 0
  FAIL: 0

All tests passed!
```

2回連続実行して両回とも 23/23 PASS を確認済み。

---

## 既知の制限事項

| # | 項目 | 状態 |
|---|------|------|
| 1 | curl -F でmeta JSONを送ると `meta is not valid JSON` エラー（シェルの`{}`解釈の問題） | ⚠ 既知（metaなし送信で回避可） |
| 2 | AZURE_SPEECH_MOCK=true → リアル音声認識は未検証 | 本番時に再検証 |
| 3 | GRAPH_MOCK=true → 実際のTeams/OneDrive連携は未検証 | 本番時に再検証 |
| 4 | Azure Functions (`functions/`) のローカル起動未検証 | `func start` で確認推奨 |
| 5 | Android E2E テスト（実機/エミュレータ）は未実施 | Android Studio で手動確認推奨 |

追加確認:

```
Android assembleDebug: BUILD SUCCESSFUL
APK: OccupancyCounter/app/build/outputs/apk/debug/app-debug.apk
apksigner verify: Verified using v2 scheme = true
```

### TC-INF-03 ✅ PASS — Bicep build

```
bicep build infra/bicep/main.bicep --outfile infra/bicep/main.json
結果: build成功
警告: 0件（no-unused-vars / outputs-should-not-contain-secrets / BCP334 は修正済み）
```

---

## 変更履歴

| 日付 | 内容 |
|------|------|
| 2026-05-09 | W1 headcount 検証完了（初版） |
| 2026-05-12 | W2/W3/P4 全検証完了、VTTパースバグ修正（graph.js）、レポート全面更新 |
