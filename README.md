# OccupancyCounter プロジェクト

余ったAndroid端末を**会議室の滞在人数IoTセンサー**として再利用し、会議室予約システムへリアルタイムにカウントを反映するプロジェクトです。

```
              ┌─────────────────┐
              │  Android 端末    │
              │ (CameraX +       │  各会議室に1台ずつ設置
              │  ML Kit Face)    │
              └────────┬─────────┘
                       │ POST /ingest/headcount (3〜10秒ごと)
                       │ { device_id, headcount, confidence }
                       ▼
              ┌─────────────────┐
              │ Cloudflare       │
              │ Tunnel (quick)   │  cloudflared tunnel --url 127.0.0.1:3000
              └────────┬─────────┘
                       │
                       ▼
              ┌─────────────────┐
              │ TestDashboard    │  Express on PC (port 3000)
              │ Express server   │  device_id → 会議室マッピング
              └────────┬─────────┘
                       │ GET /api/state (3秒毎)
                       ▼
        ┌─────────────────────────────┐
        │ GitHub Pages ダッシュボード   │  https://ytsutsumi30.github.io/
        │ (静的HTML/CSS/JS)            │  OccupancyCounter/
        └─────────────────────────────┘
```

---

## ディレクトリ構成

```
C:\PRJ2\dev2\
├── README.md                       ← このファイル (全体ナビ)
├── Claude_AI開発推進手順.md         ← 開発フロー解説 (5サイクル)
├── Claude_AI開発推進手順.pptx       ← プレゼン版
│
├── OccupancyCounter\               ★ Androidアプリ + GitHub Pages リポジトリ
│   ├── app\                         (Kotlin/CameraX/ML Kit)
│   ├── docs\                        (GitHub Pages 公開対象)
│   ├── gradle\, build.gradle.kts    (ビルド設定)
│   └── README.md                    (Android 開発手順)
│
├── TestDashboard\                  ★ バックエンド (Express)
│   ├── server.js                    (POST /ingest/headcount, GET /api/state)
│   ├── public\                      (同梱ダッシュボードUI)
│   └── README.md                    (起動手順 + cloudflared 案内)
│
└── docs\                           (旧版 — OccupancyCounter\docs\ に統合済み)
```

---

## 4 会議室と デバイス マッピング

| device_id | 会議室 | 階 | 定員 |
|---|---|---|---|
| `AA:11:11:11:11:11` | **大会議室**   | 3F | 10名 |
| `3F:A8:91:0C:7B:E2` | **中会議室**   | 2F |  6名 |
| `CC:33:33:33:33:33` | **小会議室**   | 2F |  2名 |
| `DD:44:44:44:44:44` | **個別ブース** | 1F |  1名 |

各 Android 端末の **設定画面でデバイスIDを上記のいずれかに変更** すれば、対応する会議室にカウントが反映されます。
変更は `TestDashboard/server.js` の `deviceMap`、または起動後の `POST /api/devices` で動的に追加可能。

---

## クイックスタート（3ステップ）

### 1. バックエンドサーバー起動（PowerShell①）

```powershell
cd C:\PRJ2\dev2\TestDashboard
npm install   # 初回のみ
npm start
```

→ `Listening on http://localhost:3000` が出れば成功

### 2. Cloudflare Tunnel 起動（PowerShell②）

```powershell
cloudflared tunnel --url http://127.0.0.1:3000
```

→ 表示される `https://xxx.trycloudflare.com` をコピー

### 3. ダッシュボードに新URL設定

ブラウザで https://ytsutsumi30.github.io/OccupancyCounter/ を開き、**⚙ 設定** に Tunnel URL を貼付け → 適用

詳細手順・トラブルシュート: [TestDashboard/README.md](./TestDashboard/README.md)

---

## 動作テスト（4会議室を一括反映）

```powershell
$URL = "https://your-tunnel.trycloudflare.com"

curl.exe -X POST "$URL/ingest/headcount" -H "Content-Type: application/json" `
  -d '{"device_id":"AA:11:11:11:11:11","headcount":8,"confidence":"confirmed"}'
curl.exe -X POST "$URL/ingest/headcount" -H "Content-Type: application/json" `
  -d '{"device_id":"3F:A8:91:0C:7B:E2","headcount":5,"confidence":"confirmed"}'
curl.exe -X POST "$URL/ingest/headcount" -H "Content-Type: application/json" `
  -d '{"device_id":"CC:33:33:33:33:33","headcount":2,"confidence":"confirmed"}'
curl.exe -X POST "$URL/ingest/headcount" -H "Content-Type: application/json" `
  -d '{"device_id":"DD:44:44:44:44:44","headcount":1,"confidence":"tentative"}'
```

→ ダッシュボードの 4 会議室カードが一気に更新されることを確認できます。

---

## ドキュメント索引

| トピック | ファイル |
|---|---|
| Android アプリ開発・APKビルド | [OccupancyCounter/README.md](./OccupancyCounter/README.md) |
| GitHub Pages デプロイ | [OccupancyCounter/docs/README.md](./OccupancyCounter/docs/README.md) |
| TestDashboard サーバー起動 | [TestDashboard/README.md](./TestDashboard/README.md) |
| Claude AI 開発推進手順（5サイクル） | [Claude_AI開発推進手順.md](./Claude_AI開発推進手順.md) |

---

## 技術スタック

| 領域 | 採用技術 |
|---|---|
| Android | Kotlin / CameraX 1.3.1 / ML Kit Face Detection / OkHttp 4.12.0 |
| バックエンド | Node.js + Express 4 / port 3000 / CORS有効 |
| 公開層 | GitHub Pages（静的） + Cloudflare Tunnel quick |
| 検出方式 | ML Kit Face Detection（オフライン動作・無料） |
| カウント方式 | スナップショット型（直近5フレーム最頻値） |
| データ送信 | JSON POST（device_id / headcount / confidence） |

---

## 既知の制約

- Cloudflare Tunnel quick (`*.trycloudflare.com`) は **再起動ごとにURLが変わる** — 長期運用には Cloudflare Account 連携の Named Tunnel への移行を推奨
- ML Kit Face Detection は **顔（正面〜やや横）のみ検出** — 後ろ向き/うつむきは未カウント
- 1端末で1会議室を想定 — 1台で複数監視する場合はカメラ切替/座標分割の拡張が必要
- TestDashboard は **メモリ保持型** — プロセス再起動で履歴消失。永続化が必要な場合 SQLite/JSON ファイルへの保存追加を検討
