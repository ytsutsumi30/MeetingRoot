# 3. データフロー・シーケンス設計

**最終更新**: 2026-05-17

---

## 3.1 全体データフロー

```mermaid
flowchart LR
    subgraph Input["入力"]
        CAM["📷 カメラ<br/>(顔検出)"]
        MIC_AND["🎤 Androidマイク<br/>(m4a録音)"]
        MIC_WEB["🌐 WEBブラウザ<br/>(WebM録音)"]
        TEAMS["💻 Teams<br/>(Transcript)"]
    end

    subgraph Process["処理"]
        CONV["🔄 WAV変換<br/>(WebM→WAV)"]
        STT["🎤 Azure Speech<br/>文字起こし+分離"]
        MERGE["🔀 Merger<br/>発言マージ"]
        SPKID["🗣️ Speaker ID<br/>声紋識別"]
        AI["🤖 Claude<br/>AI要約"]
        DOCX["📄 docx-builder<br/>Word生成"]
    end

    subgraph Output["出力"]
        DASH["📊 ダッシュボード<br/>(人数表示)"]
        OD["📁 OneDrive<br/>(議事録)"]
        DL["⬇️ Download<br/>(.docx)"]
    end

    CAM -->|headcount| DASH
    MIC_AND -->|m4a| STT
    MIC_WEB -->|WebM| CONV -->|WAV| STT
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

## 3.8 WEB録音 話者識別フロー（ケース5/6）★新

### ケース5: PCブラウザのみ

```mermaid
sequenceDiagram
    participant Browser as 🌐 WEBブラウザ
    participant Express as 🖥️ Express
    participant Conv as 🔄 WAV変換
    participant AzSpeech as 🎤 Azure Speech
    participant SpkID as 🗣️ Speaker ID

    Browser->>Browser: MediaRecorder録音<br/>(WebM/OGG/MP4)
    Browser->>Express: POST /ingest/recording<br/>(meta: device_id="web-browser")
    Express->>Conv: ffmpeg WebM→WAV変換 [I-1]
    Conv-->>Express: PCM WAV 16kHz mono

    Express->>AzSpeech: POST /transcriptions<br/>(diarization:true)
    Note over AzSpeech: Speaker_0, Speaker_1...に分離

    AzSpeech-->>Express: transcript segments

    Express->>SpkID: 各話者の代表セグメント(≥4秒)
    SpkID->>SpkID: Azure Speaker Recognition<br/>identifySingleSpeaker
    Note over SpkID: 登録済み声紋と照合<br/>confidence ≥0.65 → 実名
    SpkID-->>Express: speakerMap

    Express->>Express: Claude 議事録生成
```

### ケース6: WEBブラウザ + Teams同時

```mermaid
sequenceDiagram
    participant Browser as 🌐 WEBブラウザ
    participant Teams as 💻 Teams
    participant Express as 🖥️ Express
    participant Merger as 🔀 TranscriptMerger

    Browser->>Express: POST /ingest/recording<br/>(meta: teams_meeting_id="AAMk...") [I-3]
    Teams->>Express: Queue経由 VTT受信<br/>(実名付き)

    Express->>Express: teams_meeting_id で関連付け
    Express->>Merger: roomSegments[] + teamsSegments[]
    Merger->>Merger: 時系列マージ・重複除去
    Note over Merger: Teams話者名が実名 → 優先<br/>残りは声紋識別

    Merger-->>Express: mergedSegments[]
    Express->>Express: Claude 議事録生成（合成）
```

---

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
