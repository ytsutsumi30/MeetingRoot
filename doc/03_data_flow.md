# 3. データフロー・シーケンス設計

**最終更新**: 2026-05-15

---

## 3.1 全体データフロー

```mermaid
flowchart LR
    subgraph Input["入力"]
        CAM["📷 カメラ<br/>(顔検出)"]
        MIC["🎤 マイク<br/>(録音)"]
        TEAMS["💻 Teams<br/>(Transcript)"]
    end

    subgraph Process["処理"]
        STT["🎤 Azure Speech<br/>文字起こし"]
        MERGE["🔀 Merger<br/>発言マージ"]
        SPKID["🗣️ Speaker ID<br/>話者識別"]
        AI["🤖 Claude<br/>AI要約"]
        DOCX["📄 docx-builder<br/>Word生成"]
    end

    subgraph Output["出力"]
        DASH["📊 ダッシュボード<br/>(人数表示)"]
        OD["📁 OneDrive<br/>(議事録)"]
        DL["⬇️ Download<br/>(.docx)"]
    end

    CAM -->|headcount| DASH
    MIC -->|m4a| STT
    TEAMS -->|VTT| MERGE
    STT -->|segments| MERGE
    MERGE --> SPKID
    SPKID --> AI
    AI -->|markdown| DOCX
    DOCX --> OD
    DOCX --> DL
```

---

## 3.2 滞在人数カウント (W1) シーケンス

```mermaid
sequenceDiagram
    participant Android as 📱 Android
    participant CF as ☁️ Cloudflare Tunnel
    participant Express as 🖥️ Express
    participant Dashboard as 📊 Dashboard

    loop 3-10秒ごと
        Android->>Android: CameraX + ML Kit 顔検出
        Android->>CF: POST /ingest/headcount<br/>{device_id, headcount, confidence}
        CF->>Express: forward
        Express->>Express: deviceMap でルーム特定<br/>state.rooms[roomId] 更新
        Express-->>CF: 200 {ok:true, room, headcount}
        CF-->>Android: response
    end

    loop 3秒ごと
        Dashboard->>CF: GET /api/state
        CF->>Express: forward
        Express-->>Dashboard: {rooms[], history[], deviceMap}
        Dashboard->>Dashboard: UI カード更新
    end
```

---

## 3.3 議事録生成 (W2-W3) シーケンス — 物理参加者のみ

```mermaid
sequenceDiagram
    participant Android as 📱 Android
    participant Express as 🖥️ Express
    participant AzSpeech as 🎤 Azure Speech
    participant SpkID as 🗣️ Speaker ID
    participant Claude as 🤖 Claude API
    participant Graph as 📁 OneDrive

    Android->>Express: POST /ingest/recording<br/>(multipart: meta + audio)
    Express->>Express: multer で保存<br/>jobId 発行
    Express-->>Android: 202 {job_id, status:"received"}

    Note over Express,AzSpeech: 非同期処理開始

    Express->>Express: audio-publisher で音声URL公開
    Express->>AzSpeech: POST /transcriptions<br/>(contentUrls, diarization:true)
    AzSpeech-->>Express: 201 {self, status:"NotStarted"}

    loop 30秒ごとポーリング
        Express->>AzSpeech: GET /transcriptions/{id}
        AzSpeech-->>Express: {status}
    end

    AzSpeech-->>Express: status:"Succeeded"
    Express->>AzSpeech: GET /transcriptions/{id}/files
    AzSpeech-->>Express: transcript JSON

    Express->>Express: パース → segments[]

    Express->>SpkID: 話者識別 (Speaker Profile)
    SpkID-->>Express: speakerMap

    Express->>Claude: 文字起こし + メタ情報
    Claude-->>Express: 議事録 Markdown

    Express->>Express: docx-builder で .docx 生成

    Express->>Graph: PUT .docx → OneDrive
    Graph-->>Express: {webUrl, shareLink}

    Express->>Express: meta.json / jobs/{id}.json 更新
    Note over Express: status: "completed"
```

---

## 3.4 Teams Webhook 連携 (P4) シーケンス

```mermaid
sequenceDiagram
    participant Teams as 💻 Teams Meeting
    participant GraphSvc as Microsoft Graph
    participant AzFunc as ⚡ Azure Functions
    participant Blob as 📦 Azure Blob
    participant Queue as 📨 Azure Queue
    participant Express as 🖥️ Express
    participant Claude as 🤖 Claude

    Teams->>Teams: 会議終了 (Transcript有効)
    GraphSvc->>AzFunc: POST /api/notifications<br/>(Webhook通知)

    AzFunc->>AzFunc: clientState 検証
    AzFunc->>GraphSvc: GET transcript content<br/>(VTT形式)
    GraphSvc-->>AzFunc: VTT テキスト

    AzFunc->>Blob: PUT transcript VTT
    AzFunc->>Queue: sendMessage<br/>{meetingId, transcriptId, blobUrl}
    AzFunc-->>GraphSvc: 202 Accepted

    loop 30秒ごと
        Express->>Queue: receiveMessages
        Queue-->>Express: message
    end

    Express->>Blob: GET transcript VTT
    Blob-->>Express: VTT content

    Express->>Express: parseVttToSegments()
    Express->>Express: startJobFromTeams()

    Note over Express,Claude: 以降は W3 と同じ<br/>Claude要約 → DOCX → OneDrive
```

---

## 3.5 ハイブリッド会議 マージフロー

```mermaid
sequenceDiagram
    participant Room as 🏢 Room録音
    participant Teams as 💻 Teams Transcript
    participant Merger as 🔀 TranscriptMerger
    participant SpkID as 🗣️ Speaker ID
    participant Claude as 🤖 Claude

    Room->>Merger: roomSegments[]<br/>(Speaker 1, 2...)
    Teams->>Merger: teamsSegments[]<br/>(実名: 山田, 佐藤...)

    Merger->>Merger: 時系列ソート
    Merger->>Merger: 重複除去<br/>(0.5秒以内 → Teams優先)
    Merger-->>SpkID: mergedSegments[]

    SpkID->>SpkID: Room話者 → Speaker Profile マッチ
    SpkID->>SpkID: Teams相関<br/>(同時刻発言 → 同一人物推定)
    SpkID-->>Claude: 識別済みセグメント

    Claude->>Claude: 議事録生成
    Note over Claude: [14:00:05] 山田太郎 (Teams): ...<br/>[14:00:12] Room-1 (会議室): ...
```

---

## 3.6 話者識別 3レベルフロー

```mermaid
flowchart TD
    INPUT["文字起こしセグメント<br/>(Speaker 1, 2, ...)"]

    L1["Level 1: Diarization<br/>Azure Speech の話者ID"]
    L2{"Level 2: Speaker Profile<br/>confidence ≥ 0.85?"}
    L3{"Level 3: LLM推定<br/>confidence ≥ 0.7?"}
    MANUAL["手動マッピング<br/>(UI から設定)"]

    AUTO["✅ 自動命名<br/>(実名表示)"]
    TENTATIVE["⚠️ 推定<br/>(要確認)"]
    UNKNOWN["❓ 不明<br/>(Speaker N)"]

    INPUT --> L1
    L1 --> L2
    L2 -->|Yes| AUTO
    L2 -->|No| L3
    L3 -->|Yes| TENTATIVE
    L3 -->|No| UNKNOWN
    UNKNOWN --> MANUAL
    MANUAL --> AUTO
```

---

## 3.7 Graph Webhook Subscription ライフサイクル

```mermaid
sequenceDiagram
    participant Timer as ⏰ Timer (12h)
    participant Func as ⚡ Functions
    participant Graph as Microsoft Graph
    participant Table as Azure Table

    Note over Timer,Table: 初回セットアップ

    Func->>Graph: POST /subscriptions<br/>{resource, notificationUrl, expiration}
    Graph-->>Func: {id, expirationDateTime}
    Func->>Table: upsert (status:active)

    Note over Timer,Table: 定期更新 (12時間ごと)

    Timer->>Func: tick
    Func->>Table: list active subscriptions
    Table-->>Func: [{id, expiration}]

    alt 残り > 36h
        Func->>Func: スキップ
    else 残り ≤ 36h
        Func->>Graph: PATCH /subscriptions/{id}<br/>{newExpiration}
        alt 成功
            Graph-->>Func: {id, newExpiration}
            Func->>Table: upsert (更新)
        else 404 (消失)
            Graph-->>Func: 404
            Func->>Table: mark dead
            Func->>Graph: POST /subscriptions (再作成)
        end
    end
```
