# 話者識別 高度化 設計書

**目的**: 議事録の発言を「Speaker 1/2/...」ではなく **個人実名** で記録する。
段階的に高度化することで、初期は手動マッピング、最終的には AI 自動推定で **新規話者でも自動命名** を実現する。

---

## 1. 話者識別の3レベル

| レベル | 機能 | 必要技術 | 実現可能なこと |
|---|---|---|---|
| **L1: Diarization** | 発言区間と話者ID付け (Speaker 1/2/...) | Azure Speech Conversation Transcription | 「異なる人」が分かるが「誰か」は不明 |
| **L2: Identification** | 既知のプロファイルとマッチして名前を割当 | Azure Speaker Recognition + 事前登録 | 登録済みの人なら自動で実名表示 |
| **L3: Recognition + 推定** | 文脈・前後関係から AI が話者を推定 | L2 + Claude による推定 | 未登録話者でも周辺発言から推定 |

---

## 2. レベル別の実装ロードマップ

```
[ Phase 1 ]      L1 Diarization (Speaker 1/2/...)
              + 議事録UI で実名手動マッピング
              + マッピングを保存して再利用 (1回入力で済む)
                          ↓
[ Phase 2 ]      L2 Speaker Identification (Voice Profile事前登録)
              + Profile管理画面 (録音→Enroll)
              + 自動マッチ (90% 一致なら自動命名)
                          ↓
[ Phase 3 ]      L3 LLM 支援推定
              + Claude が「この発言者は前の議題で○○と発言した山田さんに特徴が似ている」と推定
              + Teams Live Transcript の実名と Room の声紋を相互ヒモ付け
              + 確度別 表示 (確定 / 推定 / 不明)
```

---

## 3. Level 1: Diarization + 手動マッピング

### 3.1 現状の出力 (Phase 1 MVP)

Azure Speech Conversation Transcription の出力例:

```json
{
  "recognizedPhrases": [
    { "speaker": 1, "offset": "PT0S",   "duration": "PT3.2S", "nBest": [{"display":"おはようございます"}] },
    { "speaker": 2, "offset": "PT3.5S", "duration": "PT2.8S", "nBest": [{"display":"よろしくお願いします"}] },
    { "speaker": 1, "offset": "PT6.5S", "duration": "PT4.1S", "nBest": [{"display":"本日の議題は..."}] }
  ]
}
```

→ 議事録上は `Speaker 1`, `Speaker 2` と表記される。

### 3.2 マッピングテーブル設計

`storage/speaker-profiles.json` (or Azure Table Storage):

```json
{
  "rooms": {
    "medium": {
      "deviceId": "3F:A8:91:0C:7B:E2",
      "speakerMap": {
        "Speaker 1": { "name": "山田太郎", "email": "yamada@contoso.com", "confidence": "manual" },
        "Speaker 2": { "name": "佐藤花子", "email": "sato@contoso.com",   "confidence": "manual" }
      },
      "lastUpdated": "2026-05-09T15:30:00+09:00"
    }
  }
}
```

> ⚠️ **会議室別**にマッピングを保持する点が重要。同じ会議室で繰返される MTG なら次回以降自動で適用できる。

### 3.3 議事録UI のマッピング機能

GitHub Pages ダッシュボードに「話者編集」モーダルを追加:

```
┌──────────────────────────────────────────────┐
│ 中会議室の議事録 - 2026-05-09 14:00            │ × │
├──────────────────────────────────────────────┤
│  📝 発言者を編集                                 │
│                                              │
│  Speaker 1 (12発言)  →  [山田太郎 ▼] [✓ 保存]  │
│  Speaker 2 (8発言)   →  [佐藤花子 ▼] [✓ 保存]  │
│  Speaker 3 (3発言)   →  [選択... ▼] [+ 新規]  │
│                                              │
│  ☑ この設定を以降の中会議室の議事録にも適用      │
└──────────────────────────────────────────────┘
```

### 3.4 マッピング適用ロジック

```javascript
function applySpeakerMap(transcript, roomId, savedMap) {
  return transcript.map(seg => ({
    ...seg,
    speakerLabel: savedMap?.[`Speaker ${seg.speaker}`]?.name
                  || `Speaker ${seg.speaker}`,
    speakerEmail: savedMap?.[`Speaker ${seg.speaker}`]?.email
  }));
}
```

### 3.5 課題と次フェーズ移行のトリガー

- ❌ 同じ会議室でも、参加メンバーが変わるとマッピングが崩れる
- ❌ 新規参加者が来るたびに毎回手動マッピング必要
- ❌ Speaker N の番号は録音ごとに変わる (Speaker 1 が前回と別人の可能性)

→ **Phase 2 (Voice Profile) へ進む価値あり**

---

## 4. Level 2: Voice Profile 登録と自動識別

### 4.1 Azure Speaker Recognition API

Azure Cognitive Services の **Speaker Recognition** サービスを使用。
※ Conversation Transcription とは別サービスで、別途リソース作成が必要。

#### 4.1.1 機能の種類

| 機能 | 用途 | 必要音声 |
|---|---|---|
| **Speaker Verification** | 1対1認証 ("この声は山田さんか？") | 20秒×3回の登録音声 |
| **Speaker Identification** | 1対多識別 ("この声は誰？") | 同上、複数人を Profile DB に登録 |

本機能では **Speaker Identification** を使用。

### 4.2 Voice Profile 登録フロー

```
[1] 社員ごとに Voice Profile 作成
    POST /speaker/identification/v2.0/text-independent/profiles
    body: { "locale": "ja-JP" }
    ← profileId: uuid

[2] 登録音声を3回送信 (累計20秒以上必要)
    POST /profiles/{id}/enrollments
    body: 音声バイナリ (~10秒・WAV/PCM)
    ← enrollmentStatus: "Enrolled" になるまで繰り返し

[3] Profile DB に対応関係を保存
    profileId: "abc-123" → name: "山田太郎", email: "..."
```

### 4.3 Profile 管理画面 (Web UI)

専用ページを GitHub Pages に追加:

```
/speakers/index.html

┌──────────────────────────────────────────────┐
│  音声プロファイル管理                            │
├──────────────────────────────────────────────┤
│  登録済み: 12名                                  │
│                                              │
│  + 新規登録                                    │
│    ┌──────────────────────────────┐         │
│    │ 名前: [山田太郎    ]          │         │
│    │ メール: [yamada@... ]         │         │
│    │ 録音 ( 0/3 完了 )             │         │
│    │ [● 録音開始 (10秒)]            │         │
│    └──────────────────────────────┘         │
│                                              │
│  既存プロファイル:                              │
│   ✓ 山田太郎    [10秒×3] 100% [⊗削除]         │
│   ✓ 佐藤花子    [10秒×3] 100% [⊗削除]         │
│   ⚠ 田中一郎    [10秒×2] 67% (要追加)         │
└──────────────────────────────────────────────┘
```

### 4.4 議事録生成フローへの組込み

Express の議事録ジョブ処理を拡張:

```javascript
async function processJob(jobId) {
  // 既存: Azure Speech で diarization
  const transcript = await runConversationTranscription(jobId);

  // 新規: 各 speaker の代表音声を切出して Identification
  const speakerSamples = extractRepresentativeSegments(transcript);
  for (const [speakerId, audioBuffer] of Object.entries(speakerSamples)) {
    const result = await identifySpeaker(audioBuffer);
    if (result.confidence >= 0.85) {
      // 高信頼: 自動適用
      transcript.speakerMap[speakerId] = {
        name: result.profile.name,
        email: result.profile.email,
        confidence: "auto",
        score: result.confidence
      };
    } else if (result.confidence >= 0.6) {
      // 中信頼: 候補として表示 (ユーザー確認後に保存)
      transcript.speakerMap[speakerId] = {
        candidates: result.topMatches,
        confidence: "tentative"
      };
    } else {
      // 低信頼: 不明扱い
      transcript.speakerMap[speakerId] = {
        confidence: "unknown"
      };
    }
  }
  // 続けて Claude で議事録生成
}
```

### 4.5 Identification API 呼出

```javascript
async function identifySpeaker(audioBuffer) {
  const profileIds = await getActiveProfileIds(); // DB から
  const r = await axios.post(
    `https://${REGION}.api.cognitive.microsoft.com/speaker/identification/v2.0/text-independent/profiles/identifySingleSpeaker`,
    audioBuffer,
    {
      params: { profileIds: profileIds.join(",") },
      headers: {
        "Ocp-Apim-Subscription-Key": SPEAKER_KEY,
        "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000"
      }
    }
  );
  // r.data.identifiedProfileId, r.data.score
  return { profileId: r.data.identifiedProfileId, confidence: r.data.score };
}
```

### 4.6 Profile データモデル

`storage/voice-profiles.json` (or Azure Table):

```json
{
  "profiles": [
    {
      "profileId": "abc-123-def",
      "name": "山田太郎",
      "email": "yamada@contoso.com",
      "department": "開発部",
      "enrollmentStatus": "Enrolled",
      "enrollmentDuration": 30.5,
      "createdAt": "2026-05-01T10:00:00+09:00",
      "lastIdentifiedAt": "2026-05-09T14:30:00+09:00",
      "totalIdentifiedCount": 47,
      "consentVersion": "v1.0",
      "consentDate": "2026-05-01T09:55:00+09:00"
    }
  ]
}
```

### 4.7 Profile 自動学習

会議で議事録UIから「Speaker N → 山田太郎」と手動で確定したとき、その音声サンプルを既存 Profile に追加 enroll する:

```javascript
async function appendEnrollment(profileId, audioBuffer) {
  await axios.post(
    `https://${REGION}.api.cognitive.microsoft.com/speaker/identification/v2.0/text-independent/profiles/${profileId}/enrollments`,
    audioBuffer,
    { headers: { "Ocp-Apim-Subscription-Key": SPEAKER_KEY }}
  );
  // 数を増やすほど精度向上
}
```

---

## 5. Level 3: LLM 支援による話者推定

Voice Profile が未登録の話者でも、**会話文脈から AI が推定** する仕組み。

### 5.1 Claude を活用した推定プロンプト

```
あなたは会議の話者推定エキスパートです。以下の文字起こしから、各 Speaker N の特徴を分析し、
既知の参加者リストと照合して可能性を提示してください。

## 既知の参加者リスト (Outlook 招待者)
- 山田太郎 (yamada@contoso.com) - 開発部・プロジェクト責任者
- 佐藤花子 (sato@contoso.com) - 経理部
- 田中一郎 (tanaka@contoso.com) - 営業部

## 部分マッチ済み (Voice Profile)
- Speaker 1 → 山田太郎 (Voice Profile match, confidence 0.92)

## 文字起こし
[Speaker 1] このプロジェクトのリリース日は来月15日を予定しています...
[Speaker 2] 予算的には承認していますが、追加コストが発生したら相談してください
[Speaker 3] 営業先からの問い合わせも増えてきているので、タイミング良いです

## 推定タスク
Speaker 2, Speaker 3 が誰なのか、文脈と参加者リストから推定し、信頼度(0-1)付きでJSONで答えてください。

## 出力フォーマット (JSON)
{
  "Speaker 2": {
    "estimatedName": "佐藤花子",
    "confidence": 0.85,
    "reasoning": "「予算」「承認」という発言から経理部の佐藤花子と推定"
  },
  "Speaker 3": {
    "estimatedName": "田中一郎",
    "confidence": 0.78,
    "reasoning": "「営業先からの問い合わせ」発言から営業部の田中一郎と推定"
  }
}
```

### 5.2 Claude API 呼出実装

```javascript
async function estimateSpeakers(transcriptSegments, attendees, knownMappings) {
  const prompt = buildEstimationPrompt(transcriptSegments, attendees, knownMappings);
  const response = await anthropic.messages.create({
    model: "claude-sonnet-4-6",
    max_tokens: 2000,
    system: "You are an expert at speaker estimation from conversational context.",
    messages: [{ role: "user", content: prompt }]
  });
  return JSON.parse(response.content[0].text);
}
```

### 5.3 統合ロジック (3レベル組合せ)

```javascript
async function resolveSpeakers(transcript, roomId) {
  const result = {};

  // L1: Diarization の生データ
  const speakerIds = extractSpeakerIds(transcript);

  // L2: Voice Profile マッチを試行
  for (const sid of speakerIds) {
    const sample = extractSpeakerSample(transcript, sid);
    const match = await identifySpeaker(sample);
    if (match.confidence >= 0.85) {
      result[sid] = { name: match.profile.name, source: "voice_profile", confidence: match.confidence };
    }
  }

  // 残りを L3: Claude 推定
  const unresolved = speakerIds.filter(sid => !result[sid]);
  if (unresolved.length > 0) {
    const attendees = await getOutlookAttendees(meetingId);
    const llmEstimates = await estimateSpeakers(transcript, attendees, result);
    for (const sid of unresolved) {
      const est = llmEstimates[`Speaker ${sid}`];
      if (est && est.confidence >= 0.7) {
        result[sid] = {
          name: est.estimatedName,
          source: "llm_estimate",
          confidence: est.confidence,
          reasoning: est.reasoning
        };
      } else {
        result[sid] = { name: `Speaker ${sid}`, source: "unknown" };
      }
    }
  }

  return result;
}
```

### 5.4 Teams Live Transcript との相互ヒモ付け

ハイブリッド会議では Teams 側は **既に実名つき**。これを活用してRoom側を識別:

```javascript
function correlateRoomAndTeams(roomTranscript, teamsTranscript, timeWindow = 2.0) {
  // Teams 側で同時刻に発言した人がいれば、Room の Speaker N を実名にひも付ける可能性
  const correlations = {};

  for (const roomSeg of roomTranscript) {
    // 0.5〜2秒以内に Teams 側で発言があったか
    const overlap = teamsTranscript.find(ts =>
      Math.abs(ts.start - roomSeg.start) < timeWindow
    );
    if (overlap) {
      // 高い確率で同一人物 (Teams側の音声を Roomマイクが拾った)
      const sid = `Speaker ${roomSeg.speaker}`;
      correlations[sid] = correlations[sid] || {};
      correlations[sid][overlap.speaker] = (correlations[sid][overlap.speaker] || 0) + 1;
    }
  }

  // 各 Room speaker について、最も多く相関した Teams speaker を採用
  const result = {};
  for (const [sid, counts] of Object.entries(correlations)) {
    const top = Object.entries(counts).sort((a,b) => b[1] - a[1])[0];
    if (top[1] >= 3) { // 3回以上相関したら信頼
      result[sid] = { name: top[0], source: "teams_correlation", confidence: 0.8 };
    }
  }
  return result;
}
```

> このロジックは Phase 3 の核となる **「物理空間とリモートを横串で識別」** の仕組み。

---

## 6. UI: 信頼度別の議事録表示

```markdown
## 発言ハイライト

[14:00:05] **山田太郎** (Voice Profile / 0.92): 本日の議題は新製品リリースについてです。
[14:00:12] **佐藤花子** (Teams 実名): 承知しました。まず確認したいのは...
[14:00:25] *田中一郎* ⚠ (推定 / 0.78・経理関連発言から): 予算は問題ないでしょうか
[14:00:38] _Speaker 4_ ❓ (不明): 補足ですが、この件は来週まとめます
```

凡例:
- **太字** = 高信頼 (Voice Profile / Teams 実名)
- *イタリック* + ⚠ = AI 推定 (要確認)
- _下線_ + ❓ = 不明 (手動マッピング推奨)

### 6.1 ダッシュボード モーダルでの編集機能

```
┌──────────────────────────────────────────────┐
│ 話者を確認・修正                                │
├──────────────────────────────────────────────┤
│ Speaker 4 (3発言・26秒)                         │
│ [試聴 ▶ 0:00 / 0:26]                          │
│                                              │
│ 候補:                                         │
│  ◯ 田中一郎 (推定信頼度 0.45)                   │
│  ◯ 鈴木次郎 (推定信頼度 0.38)                   │
│  ● その他: [          ▼]                      │
│                                              │
│  ☑ Voice Profile に追加 (今後自動識別)          │
│  ☑ この設定を以降の中会議室にも適用              │
│  [✗ キャンセル] [✓ 保存]                       │
└──────────────────────────────────────────────┘
```

---

## 7. プライバシー / GDPR 対応

### 7.1 同意取得フロー

声紋は **生体情報** に該当するため、明示的同意が必要:

```
[初回ログイン時]
┌──────────────────────────────────────────────┐
│  音声プロファイル登録のご同意                       │
│                                              │
│  あなたの声紋データ（約30秒の音声）を取得し、       │
│  社内会議の議事録自動生成に使用します。            │
│                                              │
│  - 保管場所: Azure Speech Service (japaneast)  │
│  - 用途: 議事録の話者識別のみ                     │
│  - 保管期間: 2年間 (退職時即時削除)               │
│  - 削除: 設定画面からいつでも削除可能              │
│                                              │
│  [✗ 同意しない] [✓ 同意する]                   │
└──────────────────────────────────────────────┘
```

### 7.2 削除機能 (Right to Erasure)

```javascript
async function deleteSpeakerProfile(profileId) {
  // 1. Azure Speech Service から削除
  await axios.delete(
    `https://${REGION}.api.cognitive.microsoft.com/speaker/identification/v2.0/text-independent/profiles/${profileId}`,
    { headers: { "Ocp-Apim-Subscription-Key": SPEAKER_KEY } }
  );

  // 2. 自社 DB からも削除
  await profileStore.delete(profileId);

  // 3. 過去議事録の identifiedSpeaker を匿名化
  await anonymizeHistoricalMinutes(profileId);

  // 4. 監査ログ
  await auditLog({
    action: "voice_profile_deleted",
    profileId,
    deletedAt: new Date().toISOString(),
    initiatedBy: currentUser.email
  });
}
```

### 7.3 データ保管方針

| データ | 保管先 | 保管期間 | 暗号化 |
|---|---|---|---|
| Voice Profile (声紋) | Azure Speech Service | 2年 (or 退職時即時) | TLS in transit + 保存時自動暗号化 |
| 識別結果ログ | Azure Application Insights | 90日 | TLS |
| 議事録 (.docx) | OneDrive | 規程に従う | M365 暗号化 |

---

## 8. 段階的導入計画

### Phase 1: L1 + 手動マッピング (MVP)

期間: 既存計画の W4 までに含む

成果物:
- 議事録UI で「Speaker 1 → 山田太郎」のマッピング
- マッピングの保存と再利用 (会議室別)

### Phase 2: L2 Voice Profile (本格運用)

期間: 既存計画 W8 完了後の +4 週

タスク:
- [ ] Azure Speaker Recognition リソース作成 (Bicep 追加)
- [ ] Profile 登録 Web UI 作成
- [ ] 同意取得フロー実装
- [ ] Identification ロジック組込
- [ ] 50名のパイロット登録 → 識別精度測定
- [ ] 議事録UI に「自動識別」「手動修正」フロー
- [ ] 自動 enroll (修正時に Profile 強化)

成果物:
- Voice Profile 50名以上登録
- 自動識別率 80% 以上
- 修正による Profile 自動学習

### Phase 3: L3 LLM 推定 + Teams 相互ヒモ付け (高度化)

期間: Phase 2 完了後の +3 週

タスク:
- [ ] Claude 推定プロンプト最適化
- [ ] Outlook 招待者リスト連携
- [ ] Teams 相関ロジック実装
- [ ] 信頼度別 UI 表示 (太字/イタリック/❓)
- [ ] 推定精度の評価 (人手レビュー比較)

成果物:
- 未登録話者でも 70% 以上で推定成功
- ハイブリッド会議で Room/Teams 自動相関

---

## 9. テスト方針

### 9.1 ユニット

- `speakerMapApply()` の純粋関数
- `correlateRoomAndTeams()` の純粋関数
- `parseEstimationResponse()` JSON parse

### 9.2 統合 (Voice Profile)

- ダミー音声3名分を Profile DB に登録 → 識別 → 名前一致
- 未登録音声を投入 → confidence < 0.6 で unknown 扱い
- 既存 Profile に追加 enroll → identification 精度向上を確認

### 9.3 受入

- 実会議 (10名・30分) で議事録生成 → 人手確認
- 識別正解率を計測 (Voice Profile / LLM / Manual)
- 各 source の正解率目標
  - Voice Profile: ≥ 90%
  - Teams Live Transcript: ≥ 95%
  - LLM 推定: ≥ 70%

---

## 10. コスト試算

| 項目 | 単価 | 月間 |
|---|---|---|
| Speaker Recognition (Identification) | $0.40/1000リクエスト | $0.5 (月20会議×平均5話者) |
| Voice Profile Storage | 無料 | $0 |
| Claude 推定 (LLM) | $3/Mtok in, $15/Mtok out | $1.0 (推定が必要な会議のみ) |
| **追加月額** | | **$1.5 (約230円)** |

→ 議事録機能全体に大きな影響なし。コスト効率が良い。

---

## 11. リスクと緩和策

| リスク | 影響 | 緩和策 |
|---|---|---|
| 似た声 (家族・兄弟) で誤識別 | 議事録の発言者間違い | 信頼度 < 0.95 は手動確認を求める |
| 風邪や疲れで声質変化 | 識別失敗 → unknown 扱い | LLM 推定でフォロー |
| Voice Profile 漏洩 | 重大なプライバシー侵害 | Azure RBAC で限定アクセス + 監査ログ + 削除機能 |
| 同意なし収集 | 法的リスク | 初回ログイン時に明示同意フロー |
| 退職者データ放置 | 古い識別が残る | 月次で社員DB と突合し自動削除 |
| LLM が hallucinate | 誤った推定で議事録汚染 | confidence < 0.7 の場合は表示しない |

---

## 12. 関連リンク

- Speaker Recognition: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speaker-recognition-overview
- Identification API Reference: https://learn.microsoft.com/en-us/rest/api/speakerrecognition/
- Conversation Transcription: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/conversation-transcription
- GDPR ガイド: https://learn.microsoft.com/en-us/compliance/regulatory/gdpr

---

**最終更新**: 2026-05-10
**設計者**: Claude / Yoshihiro Tsutsumi
