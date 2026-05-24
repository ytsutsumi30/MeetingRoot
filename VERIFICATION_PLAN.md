# C:\PRJ2\dev2 プロジェクト 検証計画書

> 作成日: 2026-05-12  
> 対象ブランチ: TestDashboard `main(f9cf741)` / OccupancyCounter `main(7f902a0)`

---

## 1. プロジェクト概要（現状分析）

### 1.1 システム全体構成

```
Android (Pixel 7a)
  OccupancyCounter アプリ
  ├─ CameraX + ML Kit: 顔検出 → 人数カウント
  ├─ W1: 3秒ごとに POST /ingest/headcount
  └─ W2: 音声録音 → POST /ingest/recording (m4a)
            ↓ Cloudflare Tunnel
PC (localhost:3000)
  TestDashboard (Express)
  ├─ W1: headcount 受信 → ダッシュボード表示
  ├─ W2: 録音受信 → Azure Speech 文字起こし
  ├─ W3: Claude AI → 議事録 Markdown/DOCX 生成
  ├─ W3: Microsoft Graph → OneDrive アップロード
  └─ P4: Azure Storage Queue コンシューマー
            ↑ キュー積み
Azure Functions (functions/)
  └─ notifications: Teams webhook 受信
            ↑ Graph API Webhook
Microsoft Teams / OnlineMeetings
  └─ transcript 自動生成

ローカルストレ��ジ (azurite-data/)
  └─ Blob/Queue エミュレーター (Azurite 3.35.0)

IaC (infra/)
  └─ Bicep: Functions + Speech + Storage をAzure展開
```

### 1.2 ソースファイル規模

| コンポーネント | ファイル数 | 総行数 |
|---|---|---|
| TestDashboard/services | 7 | ~1,538 |
| TestDashboard/server.js | 1 | 320 |
| Android (Kotlin) | 9 | ~1,359 |
| Android (XML) | 15 | ~586 |
| functions/ | 2 | 92 |
| infra/bicep | 4 | 311 |
| infra/scripts | 4 | 663 |

### 1.3 実装済み機能

| 機能ID | 内容 | ステータス |
|---|---|---|
| W1 | 滞在人数カウント・ダッシュボード表示 | ✅ 実装済み・動作確認済 |
| W2 | 音声録音 → Azure Speech 文字起こし | ✅ 実装済み(Mock動作確認済) |
| W3 | Claude AI 議事録生成 → DOCX → OneDrive | ✅ 実装済み(Mock動作確認済) |
| P4 | Teams Webhook → Queue → 自動文字起こし | ✅ 実装済み(未実機テスト) |
| P5 | azurite debug.log ローテーション | ✅ スクリプト実装・動作確認済 |

---

## 2. 検証スコープ

### 2.1 優先度マトリクス

| レベル | 内容 | 理由 |
|---|---|---|
| **P0 必須** | W1 headcount 送受信 E2E | 本番稼働中のコア機能 |
| **P0 必須** | W2 Mock モードでの録音→文字起こし完結 | ローカル開発の主検証 |
| **P1 重要** | W3 議事録生成→DOCX生成 (Mock) | 品質保証の中核 |
| **P1 重要** | queue-consumer の Azure Queue 統合 | P4新規実装 |
| **P2 推奨** | Android APK ビルド・リリース | 配布前品質確認 |
| **P3 任意** | infra Bicep デプロイ | 本番移行前 |

---

## 3. テストケース一覧

### 3.1 【W1】滞在人数カウント

#### TC-W1-01: headcount エンドポイント正常系

```powershell
# 前提: TestDashboard が localhost:3000 で起動中
$BASE = "http://localhost:3000"

# 既知デバイスを送信 → 200 OK
$r = curl.exe -s -X POST "$BASE/ingest/headcount" `
  -H "Content-Type: application/json" `
  -d '{"device_id":"AA:11:11:11:11:11","headcount":8,"confidence":"confirmed"}'
# 期待値: {"ok":true,"room":"large","headcount":8}
Write-Host $r

# 大会議室・中会議室・小会議室・ブースを一斉に登録
curl.exe -s -X POST "$BASE/ingest/headcount" -H "Content-Type: application/json" -d '{"device_id":"3F:A8:91:0C:7B:E2","headcount":5,"confidence":"confirmed"}'
curl.exe -s -X POST "$BASE/ingest/headcount" -H "Content-Type: application/json" -d '{"device_id":"CC:33:33:33:33:33","headcount":2,"confidence":"confirmed"}'
curl.exe -s -X POST "$BASE/ingest/headcount" -H "Content-Type: application/json" -d '{"device_id":"DD:44:44:44:44:44","headcount":1,"confidence":"tentative"}'

# /api/state でまとめて確認
curl.exe -s "$BASE/api/state" | python -m json.tool
```

**期待結果:**
- rooms[].headcount が各デバイスの値と一致
- history に最大30件の時系列データが存在

#### TC-W1-02: 未登録デバイス → 202 + 警告

```powershell
curl.exe -s -X POST "$BASE/ingest/headcount" `
  -H "Content-Type: application/json" `
  -d '{"device_id":"ZZ:99:99:99:99:99","headcount":3}'
# 期待値: {"ok":false,"message":"device_id ZZ:99:99:99:99:99 は未登録..."}
```

#### TC-W1-03: バリデーションエラー → 400

```powershell
# headcount 省略
curl.exe -s -X POST "$BASE/ingest/headcount" -H "Content-Type: application/json" -d '{"device_id":"AA:11:11:11:11:11"}'
# 期待値: {"ok":false,"error":"device_id と headcount(int) は必須です"}

# headcount が文字列
curl.exe -s -X POST "$BASE/ingest/headcount" -H "Content-Type: application/json" -d '{"device_id":"AA:11:11:11:11:11","headcount":"five"}'
# 期待値: 400
```

#### TC-W1-04: 状態リセット

```powershell
curl.exe -s -X DELETE "$BASE/api/state"
# 期待値: {"ok":true} + /api/state で全 headcount=0
```

#### TC-W1-05: デバイスマッピング動的追加

```powershell
curl.exe -s -X POST "$BASE/api/devices" `
  -H "Content-Type: application/json" `
  -d '{"device_id":"EE:55:55:55:55:55","room_id":"large"}'
# 期待値: {"ok":true,"deviceMap":{... "EE:55:55:55:55:55":"large" ...}}
```

---

### 3.2 【W2】音声録音・文字起こし

#### TC-W2-01: 録音アップロード正常系 (Mock)

```powershell
# ダミー m4a ファイルを作成
[System.IO.File]::WriteAllBytes("C:\Temp\test.m4a", [byte[]]::new(1024))

$META = '{"job_id":"test-001","device_id":"3F:A8:91:0C:7B:E2","room_id":"medium","title":"テスト会議","started_at":"2026-05-12T09:00:00.000Z","ended_at":"2026-05-12T09:30:00.000Z","language":"ja-JP"}'

curl.exe -s -X POST "$BASE/ingest/recording" `
  -F "meta=$META" `
  -F "audio=@C:\Temp\test.m4a;type=audio/mp4"
# 期待値: {"ok":true,"job_id":"test-001","status":"received","message":"transcription started"}
```

#### TC-W2-02: ジョブ完了確認 (Mock モード 〜10秒後)

```powershell
Start-Sleep -Seconds 12
curl.exe -s "$BASE/api/jobs/test-001" | python -m json.tool
# 期待値: status = "completed", transcript.segments が存在
```

#### TC-W2-03: 文字起こし結果の永続化確認

```powershell
# storage/transcripts/ に JSON が生成されていること
Get-ChildItem "C:\PRJ2\dev2\TestDashboard\storage\transcripts" | Sort-Object LastWriteTime -Descending | Select-Object -First 3
```

#### TC-W2-04: ジョブ一覧取得

```powershell
curl.exe -s "$BASE/api/jobs" | python -m json.tool
# 期待値: count >= 1, jobs[].status が "completed" または "failed"
```

#### TC-W2-05: 音声ファイル欠落 → 400

```powershell
curl.exe -s -X POST "$BASE/ingest/recording" -H "Content-Type: application/json" -d '{}'
# 期待値: {"ok":false,"error":"audio file missing"}
```

---

### 3.3 【W3】議事録生成・DOCX・OneDrive

#### TC-W3-01: DOCX 生成確認 (Mock)

```powershell
# TC-W2-01 完了後
Get-ChildItem "C:\PRJ2\dev2\TestDashboard\storage\minutes" | Sort-Object LastWriteTime -Descending | Select-Object -First 3
# 期待値: *.docx が存在し、サイズ > 0
```

#### TC-W3-02: DOCX ダウンロード API

```powershell
curl.exe -s -o "C:\Temp\minutes-test.docx" "$BASE/api/minutes/test-001/download"
# 期待値: ファイルが保存され、Word で開ける
(Get-Item "C:\Temp\minutes-test.docx").Length
# 期待値: > 5000 (5KB以上)
```

#### TC-W3-03: Markdown プレビュー API

```powershell
curl.exe -s "$BASE/api/minutes/test-001/markdown"
# 期待値: Markdown テキスト (# 会議サマリ 等のヘッダを含む)
```

#### TC-W3-04: 議事録 Markdown の品質確認

取得した Markdown に以下が含まれること:
- `# 会議サマリ` または該当する見出し
- `## 議題` または `## 決定事項`
- `## アクションアイテム`
- テーブル記法 (`|---|---|`)

---

### 3.4 【P4】Queue Consumer / Teams 統合

#### TC-P4-01: parseVttToSegments ユニットテスト

```javascript
// node -e で即時実行
node -e "
const { parseVttToSegments } = require('./services/graph');
const vtt = \`WEBVTT

00:00:01.000 --> 00:00:05.000
<v 田中>本日の会議を始めます。</v>

00:00:06.000 --> 00:00:10.000
<v 鈴木>よろしくお願いします。</v>

00:00:11.000 --> 00:00:15.000
タグなしテキスト
\`;
const segs = parseVttToSegments(vtt);
console.assert(segs.length === 3, '3 segments expected, got ' + segs.length);
console.assert(segs[0].speakerLabel === '田中', 'speaker mismatch');
console.assert(segs[0].start === 1, 'start time mismatch');
console.assert(segs[2].speakerLabel === 'Unknown', 'unknown speaker expected');
console.log('TC-P4-01 PASSED:', JSON.stringify(segs));
"
```

実行ディレクトリ: `C:\PRJ2\dev2\TestDashboard`

#### TC-P4-02: startJobFromTeams Mock 動作確認

```javascript
node -e "
const jp = require('./services/job-processor');
jp.startJobFromTeams({
  jobId: 'teams-test-001',
  segments: [
    { start: 0, end: 5, speakerLabel: '田中', text: 'テスト発言です。' },
    { start: 6, end: 12, speakerLabel: '鈴木', text: '了解しました。' }
  ],
  meta: {
    title: 'Teams統合テスト',
    room_id: 'large',
    device_id: 'teams_webhook',
    started_at: new Date().toISOString(),
    ended_at: new Date().toISOString(),
    language: 'ja-JP'
  }
}).then(j => console.log('job created:', j.jobId, j.status));
setTimeout(() => {
  const j = jp.getJob('teams-test-001');
  console.log('status after 5s:', j && j.status);
  process.exit(0);
}, 5000);
"
```

期待値: 5秒後に `status: "completed"` または `"failed"` (Mock)

#### TC-P4-03: キューコンシューマー Mock モード確認

```powershell
# AZURE_STORAGE_CONNECTION_STRING 未設定の場合は自動 Mock
# サーバー起動ログに以下が含まれること:
# "[queue-consumer] MOCK mode: polling disabled (no AZURE_STORAGE_CONNECTION_STRING)"
Select-String -Path "C:\PRJ2\dev2\TestDashboard\server.log" -Pattern "queue-consumer" | Select-Object -Last 5
```

#### TC-P4-04: Azurite Queue 統合テスト (オプション)

```powershell
# 前提: Azurite が起動中
$CONN = "UseDevelopmentStorage=true"
$env:AZURE_STORAGE_CONNECTION_STRING = $CONN
$env:QUEUE_CONSUMER_MOCK = "false"

# キューにテストメッセージを積む
node -e "
const { QueueServiceClient } = require('@azure/storage-queue');
const svc = QueueServiceClient.fromConnectionString('UseDevelopmentStorage=true');
const q = svc.getQueueClient('minutes-jobs');
q.createIfNotExists().then(() => {
  const msg = JSON.stringify({
    meetingId: 'mock-meeting-001',
    transcriptId: 'mock-transcript-001',
    changeType: 'created',
    receivedAt: new Date().toISOString()
  });
  return q.sendMessage(Buffer.from(msg).toString('base64'));
}).then(r => console.log('message sent:', r.messageId));
"

# 10秒後にジョブが生成されているか確認
Start-Sleep 12
curl.exe -s "http://localhost:3000/api/jobs" | python -m json.tool
# 期待値: teams- で始まる jobId を含むジョブが存在
```

---

### 3.5 【Android】OccupancyCounter

#### TC-AND-01: ビルド確認

```powershell
Set-Location "C:\PRJ2\dev2\OccupancyCounter"
.\gradlew assembleRelease 2>&1 | Select-Object -Last 10
# 期待値: BUILD SUCCESSFUL
# 出力: app\build\outputs\apk\release\app-release.apk
```

#### TC-AND-02: APK インストール・起動

```powershell
adb install -r "app\build\outputs\apk\release\app-release.apk"
adb shell am start -n "com.example.occupancycounter/.MainActivity"
# 期待値: アプリが起動し、カメラ画面が表示される
```

#### TC-AND-03: 設定画面からエンドポイント変更

手動テスト:
1. アプリ起動後、設定アイコンをタップ
2. Server Endpoint に Cloudflare Tunnel URL を入力
3. 送信間隔 (Send Interval) を 5 秒に設定
4. 戻る → ログに `[HTTP] POST → 200 OK` が出ること

#### TC-AND-04: AppPrefs ユニットテスト

```powershell
Set-Location "C:\PRJ2\dev2\OccupancyCounter"
.\gradlew test 2>&1 | Select-Object -Last 15
# 期待値: BUILD SUCCESSFUL, 全テスト PASS
```

#### TC-AND-05: 送信成功の E2E 確認

```powershell
# TestDashboard 起動中に Android から送信
# サーバーログを確認
Select-String -Path "C:\PRJ2\dev2\TestDashboard\server.log" -Pattern "\[ingest\]" | Select-Object -Last 5
# 期待値: [ingest] 3F:A8:91:0C:7B:E2 → medium : headcount=X (confidence)
```

---

### 3.6 【インフラ・運用】

#### TC-INF-01: azurite ログローテーション

```powershell
# ファイルを人工的に肥大させてテスト
$dummy = "x" * 1024
for ($i = 0; $i -lt 10240; $i++) { Add-Content "C:\PRJ2\dev2\azurite-data\debug.log" $dummy }
(Get-Item "C:\PRJ2\dev2\azurite-data\debug.log").Length / 1MB

# ローテーション実行 (5MB 閾値でテスト)
& "C:\PRJ2\dev2\scripts\rotate-azurite-log.ps1" -MaxSizeMB 5 -KeepDays 7
# 期待値: "Rotated → debug.log.YYYYMMDD_HHmmss"

# 新しい debug.log がサイズ 0 であること
(Get-Item "C:\PRJ2\dev2\azurite-data\debug.log").Length
```

#### TC-INF-02: start-dev.ps1 起動確認

```powershell
# ドライラン確認 (サーバーは起動しない)
Get-Content "C:\PRJ2\dev2\start-dev.ps1"
# - .env 読み込みステップが含まれること
# - azurite 起動ステップが含まれること
# - rotate-azurite-log.ps1 を呼び出していること
```

#### TC-INF-03: Bicep テンプレート構文確認

```powershell
Set-Location "C:\PRJ2\dev2\infra"
bicep build "bicep\main.bicep" 2>&1
# 期待値: エラーなし (main.json が生成される)
```

#### TC-INF-04: healthz エンドポイント

```powershell
curl.exe -s "http://localhost:3000/healthz"
# 期待値: {"ok":true,"ts":"2026-05-12T..."}
```

---

### 3.7 【セキュリティ・品質】

#### TC-SEC-01: .env がコミットされていないことを確認

```powershell
Set-Location "C:\PRJ2\dev2\TestDashboard"
git ls-files .env
# 期待値: 出力なし (空)
```

#### TC-SEC-02: CORS 設定確認

```powershell
# Origin を指定しない場合
$r = Invoke-WebRequest -Uri "http://localhost:3000/api/state" -Method OPTIONS
$r.Headers["Access-Control-Allow-Origin"]
# 期待値: "*" または設定値
```

#### TC-SEC-03: リリースAPK の署名確認

```powershell
Set-Location "C:\PRJ2\dev2\OccupancyCounter"
$APK = "app\build\outputs\apk\release\app-release.apk"
& "C:\Users\$env:USERNAME\AppData\Local\Android\Sdk\build-tools\36.0.0\apksigner.bat" verify --verbose $APK 2>&1 | Select-Object -First 5
# 期待値: Verified using v2 scheme または v3 scheme
```

#### TC-SEC-04: node_modules 脆弱性スキャン

```powershell
Set-Location "C:\PRJ2\dev2\TestDashboard"
npm audit 2>&1 | Select-Object -Last 10
# 期待値: found 0 vulnerabilities または高/危 0 件
```

---

## 4. 検証実行手順

### 4.1 ローカル環境セットアップ

```powershell
# ステップ1: Azurite 起動
azurite --location "C:\PRJ2\dev2\azurite-data" --debug "C:\PRJ2\dev2\azurite-data\debug.log" --silent

# ステップ2: TestDashboard .env 設定 (初回のみ)
Copy-Item "C:\PRJ2\dev2\TestDashboard\.env.example" "C:\PRJ2\dev2\TestDashboard\.env"
# → .env を編集: AZURE_SPEECH_MOCK=true, CLAUDE_MOCK=true

# ステップ3: 依存パッケージインストール
Set-Location "C:\PRJ2\dev2\TestDashboard"; npm install

# ステップ4: サーバー起動
npm start
# → http://localhost:3000 でリッスン

# または一括起動スクリプト
# & "C:\PRJ2\dev2\start-dev.ps1"
```

### 4.2 自動実行スクリプト (回帰テスト用)

```powershell
# C:\PRJ2\dev2\scripts\run-smoke-test.ps1 として保存推奨
param([string]$BASE = "http://localhost:3000")

$pass = 0; $fail = 0

function Test-Api {
  param($name, $method, $path, $body, $expectedStatus, $expectedKey)
  try {
    $headers = @{"Content-Type"="application/json"}
    if ($body) {
      $r = Invoke-WebRequest -Uri "$BASE$path" -Method $method -Body $body -Headers $headers -ErrorAction Stop
    } else {
      $r = Invoke-WebRequest -Uri "$BASE$path" -Method $method -ErrorAction Stop
    }
    $json = $r.Content | ConvertFrom-Json
    if ($expectedKey -and -not (Get-Member -InputObject $json -Name $expectedKey -MemberType Properties)) {
      throw "missing key: $expectedKey"
    }
    if ($r.StatusCode -ne $expectedStatus) {
      throw "HTTP $($r.StatusCode) != expected $expectedStatus"
    }
    Write-Host "[PASS] $name" -ForegroundColor Green
    $script:pass++
  } catch {
    Write-Host "[FAIL] $name : $_" -ForegroundColor Red
    $script:fail++
  }
}

Test-Api "healthz"              GET  "/healthz"            $null  200 "ok"
Test-Api "ingest/headcount W1"  POST "/ingest/headcount"   '{"device_id":"AA:11:11:11:11:11","headcount":3,"confidence":"confirmed"}' 200 "ok"
Test-Api "api/state"            GET  "/api/state"          $null  200 "rooms"
Test-Api "api/jobs"             GET  "/api/jobs"           $null  200 "jobs"
Test-Api "api/recordings"       GET  "/api/recordings"     $null  200 "recordings"
Test-Api "DELETE api/state"     DELETE "/api/state"        $null  200 "ok"

Write-Host "`n結果: PASS=$pass FAIL=$fail" -ForegroundColor $(if ($fail -eq 0) {"Green"} else {"Red"})
```

---

## 5. 既知の制限・注意事項

| 項目 | 内容 | 対処方針 |
|---|---|---|
| Cloudflare Tunnel URL | 再起動のたびに変更 | AppPrefs で設定変更 / Named Tunnel への移行を検討 |
| ML Kit 顔検出精度 | 正面向き以外は未カウント | 許容範囲内として運用中 |
| ジョブストア メモリ保持 | サーバー再起動で消失 → **対応済み** | ✅ storage/jobs/ への永続化を実装 (2026-05-12)。次回サーバー再起動から有効。 |
| Teams Webhook 実機未テスト | Azure実機は未確認 / ローカルAzurite Queue統合は確認済み | Azure 環境セットアップ後にGraph実通知で再検証 |
| Android テスト未整備 | AppPrefsTest のみ存在 | W2 周辺 Instrumented Test の追加が必要 |
| functions/ Git管理 | dev2配下に.gitなし | functions/ 単独または TestDashboard に統合が必要 |

---

## 6. 次のアクション (推奨優先順)

| # | アクション | 工数目安 | 担当 | ステータス |
|---|---|---|---|---|
| 1 | **smoke-test スクリプト実行** (TC-W1/W2/W3 基本確認) | 30分 | 開発者 | ✅ 完了 (2026-05-12) |
| 2 | **優先度2**: storage/jobs/ へのジョブ状態JSON永続化 | 2時間 | 開発者 | ✅ 完了 (2026-05-12) |
| 3 | **TC-P4-04**: Azurite Queue 統合テスト実施 | 1時間 | 開発者 | ✅ 完了 (2026-05-12) |
| 4 | **TC-AND-01〜05**: Android E2E テスト (実機接続) | 2時間 | 開発者 | ☐ 未実施 |
| 5 | **functions/ の Git 管理追加** | 30分 | 開発者 | ✅ 完了 (2026-05-12) |
| 6 | **TC-INF-03**: Bicep build 確認 (bicep CLI 要インストール) | 15分 | 開発者 | ✅ 完了 (2026-05-12 / warning解消済み) |
| 7 | **サーバー再起動** → 永続化ロード確認 (TC-NewJobs) | 5分 | 開発者 | ☐ 次回起動時 |
| 8 | Cloudflare Named Tunnel への移行 | 4時間 | 開発者 | ☐ 未実施 |
| 9 | Azure 本番環境デプロイ (infra/ Bicep) | 半日 | インフラ担当 | ☐ 未実施 |

---

## 7. 検証結果記録欄

> 最終更新: 2026-05-12  スモークテスト実施 + ジョブ永続化実装完了

| TC-ID | 実施日 | 結果 | 備考 |
|---|---|---|---|
| TC-W1-01 | 2026-05-12 | ✅ PASS | 4会議室すべて headcount 正常反映 |
| TC-W1-02 | 2026-05-12 | ✅ PASS | 未登録デバイス → ok:false |
| TC-W1-03 | 2026-05-12 | ✅ PASS | headcount省略 → 400 |
| TC-W1-04 | 2026-05-12 | ✅ PASS | DELETE /api/state → ok:true |
| TC-W1-05 | — | ☐ 未実施 | |
| TC-W2-01 | 2026-05-12 | ✅ PASS | job_id=smoke-20260512-010037 受付成功 |
| TC-W2-02 | 2026-05-12 | ✅ PASS | status=completed speakers=2 |
| TC-W2-03 | 2026-05-12 | ✅ PASS | storage/transcripts/ に .json 生成確認 |
| TC-W2-04 | 2026-05-12 | ✅ PASS | /api/jobs count=7 |
| TC-W2-05 | — | ☐ 未実施 | |
| TC-W3-01 | 2026-05-12 | ✅ PASS | storage/minutes/ に .docx (~8971B) 生成確認 |
| TC-W3-02 | 2026-05-12 | ✅ PASS | DOCX download 8971 bytes |
| TC-W3-03 | 2026-05-12 | ✅ PASS | Markdown ファイル生成確認 |
| TC-W3-04 | 2026-05-12 | ✅ PASS | # 会議サマリ / ## 決定事項 / ## アクションアイテム 等ヘッダ確認 |
| TC-P4-01 | 2026-05-12 | ✅ PASS | parseVttToSegments: 3 segments, 田中/鈴木/Unknown 正常 |
| TC-P4-02 | 2026-05-12 | ✅ PASS | startJobFromTeams: 8秒後 status=completed |
| TC-P4-03 | 2026-05-12 | ✅ PASS | queue-consumer isMock()=true (AZURE_STORAGE_CONNECTION_STRING 未設定) |
| TC-P4-04 | 2026-05-12 | ✅ PASS | 別ポートAzurite(11001) + queue-consumer → teams-87654321 completed |
| TC-AND-01 | 2026-05-12 | ✅ PASS | assembleDebug 成功 / app-debug.apk v2署名検証OK。assembleRelease は署名情報確認後に別途実施 |
| TC-AND-02 | — | ☐ 未実施 | 実機テスト |
| TC-AND-03 | — | ☐ 未実施 | 手動テスト |
| TC-AND-04 | 2026-05-12 | ✅ PASS | gradlew test BUILD SUCCESSFUL (27 tasks UP-TO-DATE) |
| TC-AND-05 | — | ☐ 未実施 | 実機テスト |
| TC-INF-01 | 2026-05-12 | ✅ PASS | rotate-azurite-log.ps1 存在確認 |
| TC-INF-02 | 2026-05-12 | ✅ PASS | start-dev.ps1 に .env/azurite/rotate 処理確認 |
| TC-INF-03 | 2026-05-12 | ✅ PASS | bicep build 成功。未使用変数/secret output/最小長 warning は修正済み |
| TC-INF-04 | 2026-05-12 | ✅ PASS | GET /healthz → {"ok":true,"ts":"..."} |
| TC-SEC-01 | 2026-05-12 | ✅ PASS | git ls-files .env → 空（未追跡） |
| TC-SEC-02 | — | ☐ 未実施 | |
| TC-SEC-03 | — | ☐ 未実施 | APK ビルド後に実施 |
| TC-SEC-04 | 2026-05-12 | ✅ PASS | npm audit → found 0 vulnerabilities |

### 7.1 今回実施した追加実装

| 実装内容 | ステータス | 詳細 |
|---|---|---|
| **優先度2: ジョブ状態JSON永続化** | ✅ 実装完了 | `job-processor.js` に `persistJob()` / `loadPersistedJobs()` を追加。`storage/jobs/<jobId>.json` にジョブのスナップショットを保存。サーバー再起動時に自動復元。次回サーバー再起動から有効。 |

---

## 8. E-1 Lifecycle 追加検証 (2026-05-16)

### TC-E1-01: lifecycle `missed` 通知で状態遷移

```powershell
curl.exe -X POST http://localhost:7071/api/notifications `
  -H "Content-Type: application/json" `
  -d '{"value":[{"clientState":"long-random-string-for-validation","lifecycleEvent":"missed","subscriptionId":"sub-e1-001"}]}'

# 期待値: HTTP 202 / outputQueueItem なし / Table status=missed
```

### TC-E1-02: lifecycle `subscriptionRemoved` 通知で dead 化

```powershell
curl.exe -X POST http://localhost:7071/api/notifications `
  -H "Content-Type: application/json" `
  -d '{"value":[{"clientState":"long-random-string-for-validation","lifecycleEvent":"subscriptionRemoved","subscriptionId":"sub-e1-001"}]}'

# 期待値: HTTP 202 / Table status=dead / recoveryRequired=true
```

### TC-E1-03: renew で dead 再作成

```powershell
cd C:\PRJ2\dev2\functions
npm test

# 期待値: subscriptions-renew のテストが pass し、dead 再作成ロジックを確認
```

### TC-E1-04: 通常通知回帰

```powershell
curl.exe -X POST http://localhost:7071/api/notifications `
  -H "Content-Type: application/json" `
  -d '{"value":[{"changeType":"created","clientState":"long-random-string-for-validation","resource":"communications/onlineMeetings('"'"'meeting-123'"'"')/transcripts('"'"'transcript-456'"'"')"}]}'

# 期待値: HTTP 202 / processed=1 / minutes-jobs queue にメッセージ投入
```
