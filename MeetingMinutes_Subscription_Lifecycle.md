# Microsoft Graph Webhook Subscription ライフサイクル設計書

**目的**: Teams Online Meeting Transcript Webhook の subscription を**自動で維持**し、期限切れ・無効化・再認証を運用フリーで処理する。

---

## 1. Microsoft Graph Subscription の制約

### 1.1 リソース別 最大有効期限

| リソース | 最大有効期間 | 推奨更新間隔 |
|---|---|---|
| **Online Meeting Transcripts** | 4230 分 (≈ 70.5h) | **48時間ごと** に更新 |
| Online Meeting Recording | 4230 分 | 同上 |
| Calendar / Mail | 4230 分 | 同上 |
| Drive / OneDrive | 30 日 | 24日ごと |
| Group conversations | 4230 分 | 同上 |

> Online Meeting系は **約3日が上限**。1日1回更新を推奨します。

### 1.2 更新失敗時の挙動

- 期限切れ後の subscription は **使用不可**（404）
- ライフサイクル通知 `subscriptionRemoved` が届く
- 過去のテナント承認 (admin consent) は維持されるので、**再 subscribe で復旧可**
- 落ちている間の通知は **失われる**（重要）

---

## 2. Lifecycle 通知の3種類

通常の通知 (resource change) とは **別チャンネル** で、subscription 自体の状態変化を伝える通知が届きます。

| 種別 | 発生タイミング | 必要な対応 |
|---|---|---|
| **`reauthorizationRequired`** | 認証情報の再検証が必要（証明書ローテ等） | `POST /reauthorize` で再認証 |
| **`subscriptionRemoved`** | テナント側から削除された (Graph 側都合) | 新規 subscription を作り直す |
| **`missed`** | 通知配信失敗を検知（ネットワーク/Webhook障害） | 次の poll で同期するか、recovery 必要 |

### 2.1 通知エンドポイントの設計

通常通知と同じ URL で受け付け、ペイロードの `lifecycleEvent` キーで判別します:

```javascript
module.exports = async function (context, req) {
  // 検証応答 (省略)
  const events = req.body?.value || [];
  for (const e of events) {
    if (e.lifecycleEvent) {
      // ライフサイクル通知
      await handleLifecycle(context, e);
    } else {
      // 通常通知
      await handleNotification(context, e);
    }
  }
};

async function handleLifecycle(context, event) {
  const { lifecycleEvent, subscriptionId, clientState } = event;
  if (clientState !== process.env.WEBHOOK_CLIENT_STATE) return;

  switch (lifecycleEvent) {
    case "reauthorizationRequired":
      context.log.warn(`Reauth required for ${subscriptionId}`);
      await reauthorizeSubscription(subscriptionId);
      break;
    case "subscriptionRemoved":
      context.log.error(`Subscription removed: ${subscriptionId}`);
      await markSubscriptionDead(subscriptionId);
      // Timer Trigger が次回作り直す
      break;
    case "missed":
      context.log.warn(`Missed notifications: ${subscriptionId}`);
      await scheduleRecovery(subscriptionId);
      break;
  }
}
```

---

## 3. 更新戦略の選択肢

| 戦略 | 概要 | メリット | デメリット |
|---|---|---|---|
| **A. Timer Trigger 定期更新** ★推奨 | 12時間ごとにすべての subscription を更新 | シンプル・確実 | 並列実行の制御必要 |
| B. 期限直前 Trigger | 期限まで残り時間を計算してスケジュール | 最小回数で済む | 実装複雑、state 必要 |
| C. Lifecycle 通知駆動 | reauthRequired を受けたら更新 | リアクティブ | 通知欠損で失敗するリスク |
| D. ハイブリッド (A + C) | 定期更新 + 通知駆動の二重防御 | 可用性最高 | 実装量増 |

**本設計では A (Timer Trigger) を採用** + Lifecycle 通知をログ・監視に活用します。

---

## 4. 状態管理 (Azure Table Storage)

### 4.1 スキーマ

| プロパティ | 型 | 用途 |
|---|---|---|
| `PartitionKey` | string | `"subscriptions"` 固定 |
| `RowKey` | string | Microsoft Graph subscription ID |
| `resource` | string | `communications/onlineMeetings/...` |
| `notificationUrl` | string | Webhook URL |
| `expirationDateTime` | ISO8601 | 現在の有効期限 |
| `clientState` | string | 検証用シークレット |
| `userId` | string | organizer UPN |
| `status` | string | `active` / `expired` / `dead` |
| `createdAt` | ISO8601 | 初回作成日時 |
| `lastRenewedAt` | ISO8601 | 最終更新日時 |
| `renewCount` | int | 累積更新回数 |
| `lastError` | string | 直近の失敗内容 (任意) |

### 4.2 Bicep 追記（Table 追加）

`infra/bicep/modules/storage.bicep` に追加:

```bicep
@description('Subscription 状態管理用 Table 名')
param subscriptionTableName string = 'subscriptions'

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource subscriptionsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: subscriptionTableName
}

output subscriptionTableName string = subscriptionsTable.name
```

---

## 5. Functions 構成（追加）

```
functions/
├── notifications/                既存: 通知受信
├── subscriptions-renew/          NEW: Timer 12時間ごと更新
│   ├── function.json
│   └── index.js
├── subscriptions-bootstrap/      NEW: HTTP 初回作成 (手動キック)
│   ├── function.json
│   └── index.js
└── shared/
    ├── graphAuth.js              MSAL トークン管理
    ├── subscriptionStore.js      Azure Table CRUD
    └── subscriptionService.js    create / renew / reauthorize
```

### 5.1 `shared/graphAuth.js` (MSAL)

```javascript
const { ClientSecretCredential } = require("@azure/identity");
const cred = new ClientSecretCredential(
  process.env.MS_TENANT_ID,
  process.env.MS_CLIENT_ID,
  process.env.MS_CLIENT_SECRET
);

let cachedToken = null;
async function getGraphToken() {
  // 5分以上残ってればキャッシュ使う
  if (cachedToken && cachedToken.expiresOnTimestamp > Date.now() + 300_000) {
    return cachedToken.token;
  }
  const t = await cred.getToken("https://graph.microsoft.com/.default");
  cachedToken = t;
  return t.token;
}
module.exports = { getGraphToken };
```

### 5.2 `shared/subscriptionStore.js` (Table CRUD)

```javascript
const { TableClient, AzureNamedKeyCredential } = require("@azure/data-tables");

const account = "meetminstxxx";
const accountKey = process.env.AZURE_STORAGE_KEY;
const credential = new AzureNamedKeyCredential(account, accountKey);
const client = new TableClient(`https://${account}.table.core.windows.net`, "subscriptions", credential);

async function upsertSubscription(sub) {
  await client.upsertEntity({
    partitionKey: "subscriptions",
    rowKey: sub.id,
    resource: sub.resource,
    notificationUrl: sub.notificationUrl,
    expirationDateTime: sub.expirationDateTime,
    clientState: sub.clientState,
    userId: sub.userId,
    status: sub.status || "active",
    createdAt: sub.createdAt || new Date().toISOString(),
    lastRenewedAt: new Date().toISOString(),
    renewCount: (sub.renewCount || 0) + 1
  });
}

async function listActiveSubscriptions() {
  const results = [];
  for await (const e of client.listEntities({
    queryOptions: { filter: "status eq 'active'" }
  })) {
    results.push(e);
  }
  return results;
}

async function markStatus(id, status, error = null) {
  await client.updateEntity({
    partitionKey: "subscriptions",
    rowKey: id,
    status,
    lastError: error
  }, "Merge");
}

module.exports = { upsertSubscription, listActiveSubscriptions, markStatus };
```

### 5.3 `shared/subscriptionService.js`

```javascript
const axios = require("axios");
const { getGraphToken } = require("./graphAuth");
const { upsertSubscription, markStatus } = require("./subscriptionStore");

const GRAPH = "https://graph.microsoft.com/v1.0";
const NOTIFICATION_URL = process.env.WEBHOOK_NOTIFICATION_URL;
const LIFECYCLE_URL = process.env.WEBHOOK_NOTIFICATION_URL.replace("/notifications", "/lifecycle");
const CLIENT_STATE = process.env.WEBHOOK_CLIENT_STATE;

const MAX_LIFETIME_MIN = 4230; // Online Meeting 系の上限
const TARGET_LIFETIME_MIN = 4200; // 余裕を持って 70 時間

function newExpiration() {
  return new Date(Date.now() + TARGET_LIFETIME_MIN * 60 * 1000).toISOString();
}

async function createSubscription(userId) {
  const token = await getGraphToken();
  const body = {
    changeType: "created",
    notificationUrl: NOTIFICATION_URL,
    lifecycleNotificationUrl: LIFECYCLE_URL,
    resource: `communications/onlineMeetings/getAllTranscripts(meetingOrganizerUserId='${userId}')`,
    expirationDateTime: newExpiration(),
    clientState: CLIENT_STATE
  };
  const r = await axios.post(`${GRAPH}/subscriptions`, body, {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }
  });
  await upsertSubscription({ ...r.data, userId });
  return r.data;
}

async function renewSubscription(subId) {
  const token = await getGraphToken();
  try {
    const r = await axios.patch(`${GRAPH}/subscriptions/${subId}`, {
      expirationDateTime: newExpiration()
    }, { headers: { Authorization: `Bearer ${token}` } });
    await upsertSubscription(r.data);
    return r.data;
  } catch (err) {
    if (err.response?.status === 404) {
      // 既に消えている → 再作成フローへ
      await markStatus(subId, "dead", "Subscription not found, will recreate");
      return null;
    }
    await markStatus(subId, "active", err.message);
    throw err;
  }
}

async function reauthorizeSubscription(subId) {
  const token = await getGraphToken();
  await axios.post(`${GRAPH}/subscriptions/${subId}/reauthorize`, null, {
    headers: { Authorization: `Bearer ${token}` }
  });
  // reauthorize 後も expirationDateTime は変わらないので、続けて renew する
  return await renewSubscription(subId);
}

module.exports = { createSubscription, renewSubscription, reauthorizeSubscription };
```

### 5.4 Timer Trigger: `subscriptions-renew/function.json`

```json
{
  "bindings": [
    {
      "name": "myTimer",
      "type": "timerTrigger",
      "direction": "in",
      "schedule": "0 0 */12 * * *"
    }
  ]
}
```

> **NCRONTAB**: `0 0 */12 * * *` = **12時間ごと**（00:00 と 12:00 JST）

### 5.5 Timer Trigger: `subscriptions-renew/index.js`

```javascript
const { listActiveSubscriptions, markStatus } = require("../shared/subscriptionStore");
const { renewSubscription, reauthorizeSubscription, createSubscription } = require("../shared/subscriptionService");

module.exports = async function (context, myTimer) {
  context.log("[renew] start");
  const subs = await listActiveSubscriptions();
  context.log(`[renew] active subscriptions: ${subs.length}`);

  const results = { renewed: 0, recreated: 0, failed: 0 };

  for (const s of subs) {
    const remainingMs = new Date(s.expirationDateTime) - Date.now();
    const remainingHours = remainingMs / 3600 / 1000;

    if (remainingHours > 36) {
      context.log(`  ${s.rowKey} 残り${remainingHours.toFixed(1)}h スキップ`);
      continue;
    }

    try {
      const r = await renewSubscription(s.rowKey);
      if (r === null) {
        // 再作成
        await createSubscription(s.userId);
        context.log(`  ${s.rowKey} 再作成 (元死亡)`);
        results.recreated++;
      } else {
        context.log(`  ${s.rowKey} 更新成功 (新有効期限 ${r.expirationDateTime})`);
        results.renewed++;
      }
    } catch (err) {
      context.log.error(`  ${s.rowKey} 更新失敗: ${err.message}`);
      results.failed++;
    }
  }

  context.log(`[renew] done: ${JSON.stringify(results)}`);
};
```

### 5.6 HTTP Trigger: `subscriptions-bootstrap/index.js`

初回や復旧時に手動でキックできるエンドポイント:

```javascript
const { listActiveSubscriptions } = require("../shared/subscriptionStore");
const { createSubscription } = require("../shared/subscriptionService");

module.exports = async function (context, req) {
  // 認証 (Azure AD or Function key)
  const userId = req.body?.userId || process.env.SUBSCRIPTION_USER_ID;
  if (!userId) {
    context.res = { status: 400, body: "userId required" };
    return;
  }

  const existing = await listActiveSubscriptions();
  if (existing.find(s => s.userId === userId)) {
    context.res = { status: 200, body: { ok: true, message: "already active" } };
    return;
  }

  try {
    const sub = await createSubscription(userId);
    context.res = { status: 201, body: { ok: true, subscriptionId: sub.id, expirationDateTime: sub.expirationDateTime } };
  } catch (err) {
    context.log.error("bootstrap failed", err);
    context.res = { status: 500, body: { ok: false, error: err.message } };
  }
};
```

---

## 6. エラーハンドリング パターン

### 6.1 一時的エラー (リトライ可)

| 症状 | 対処 |
|---|---|
| 429 Throttled | exponential backoff (1s, 2s, 4s, 8s, 16s) |
| 503 ServiceUnavailable | 同上 |
| Network timeout | 同上 |

### 6.2 永続的エラー (即座に対応)

| 症状 | 対処 |
|---|---|
| 401 Unauthorized | Token 再取得（5分キャッシュ後）、再試行 |
| 403 Forbidden | アプリ権限不足。アラート + Slack 通知 |
| 400 Validation failed | パラメータエラー。コードバグなのでアラート |
| 404 Subscription not found | DB上 dead に更新、Timer 次回で再作成 |

### 6.3 リトライ実装

```javascript
async function retryWithBackoff(fn, maxAttempts = 5) {
  let lastErr;
  for (let i = 0; i < maxAttempts; i++) {
    try { return await fn(); } catch (err) {
      lastErr = err;
      const status = err.response?.status;
      if (status >= 500 || status === 429) {
        const wait = Math.min(1000 * 2 ** i, 16000);
        await new Promise(r => setTimeout(r, wait));
        continue;
      }
      throw err; // 4xx は即終了
    }
  }
  throw lastErr;
}
```

---

## 7. 監視とアラート

### 7.1 Application Insights カスタム メトリクス

`subscriptions-renew/index.js` 末尾に追加:

```javascript
const appInsights = require("applicationinsights");
appInsights.setup().start();
const client = appInsights.defaultClient;

client.trackMetric({ name: "SubscriptionsRenewed",  value: results.renewed });
client.trackMetric({ name: "SubscriptionsRecreated", value: results.recreated });
client.trackMetric({ name: "SubscriptionsFailed",   value: results.failed });
if (results.failed > 0) {
  client.trackEvent({ name: "SubscriptionRenewalFailed", properties: { count: results.failed } });
}
```

### 7.2 KQL クエリ (Application Insights Logs)

直近24時間の更新履歴:

```kusto
traces
| where timestamp > ago(24h)
| where message startswith "[renew]"
| project timestamp, message, severityLevel
| order by timestamp desc
```

失敗が3回連続したらアラート:

```kusto
customEvents
| where timestamp > ago(36h)
| where name == "SubscriptionRenewalFailed"
| summarize count() by bin(timestamp, 12h)
| where count_ >= 3
```

### 7.3 アラートルール (Bicep)

```bicep
resource alertRule 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${appName}-subscription-failure-alert'
  location: location
  properties: {
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT12H'
    scopes: [appInsights.id]
    criteria: {
      allOf: [{
        query: 'customEvents | where name == "SubscriptionRenewalFailed"'
        operator: 'GreaterThan'
        threshold: 0
        timeAggregation: 'Count'
      }]
    }
    actions: { actionGroups: [/* Slack/Teams 通知用 */] }
  }
}
```

---

## 8. テスト計画

### 8.1 ユニットテスト

```javascript
// __tests__/subscriptionService.test.js
const { createSubscription, renewSubscription } = require("../shared/subscriptionService");

jest.mock("axios");
jest.mock("../shared/graphAuth");

test("renewSubscription updates expirationDateTime", async () => {
  axios.patch.mockResolvedValue({ data: { id: "sub-123", expirationDateTime: "2026-05-12T00:00:00Z" } });
  const r = await renewSubscription("sub-123");
  expect(r.expirationDateTime).toBe("2026-05-12T00:00:00Z");
});

test("renewSubscription handles 404 by marking dead", async () => {
  axios.patch.mockRejectedValue({ response: { status: 404 } });
  const r = await renewSubscription("sub-dead");
  expect(r).toBeNull();
});
```

### 8.2 統合テスト (ローカル)

```powershell
# 1. Azurite + Functions 起動 (start-local-dev.ps1)
# 2. 擬似 subscription を Table に投入
$now = Get-Date
$almostExpired = $now.AddMinutes(60).ToString("o")
az storage entity insert `
  --table-name subscriptions `
  --connection-string "UseDevelopmentStorage=true" `
  --entity PartitionKey=subscriptions RowKey=test-sub-001 `
                  resource="communications/..." `
                  expirationDateTime=$almostExpired `
                  status=active

# 3. Timer Trigger を手動キック
curl.exe -X POST http://localhost:7071/admin/functions/subscriptions-renew

# 4. ログを確認
# 5. Table の lastRenewedAt が更新されているか確認
```

### 8.3 障害注入テスト

| シナリオ | 期待動作 |
|---|---|
| Graph API が 404 を返す | DB 上 dead → 次の Timer で recreate |
| Token 取得が失敗 | retryWithBackoff で 5回再試行 → 最後失敗ならアラート |
| Subscription Removed 通知が届く | DB 上 dead → 次の Timer で recreate |
| reauthorizationRequired 通知 | reauthorize API 呼出 → 続けて renew |
| Functions 自体がダウン中 | 復旧後 Timer 次実行で全 sub を更新（差分なし） |

---

## 9. 運用手順

### 9.1 初回セットアップ

```powershell
# 1. Azure リソースデプロイ
.\infra\deploy-azure.ps1

# 2. Functions をデプロイ
cd functions
func azure functionapp publish $env:FUNCTION_APP_NAME

# 3. App Settings を設定
$envFile = ".env.azure"
Get-Content $envFile | ForEach-Object {
    if ($_ -match "^([^=]+)=(.+)$") {
        az functionapp config appsettings set `
            --name $env:FUNCTION_APP_NAME `
            --resource-group rg-meeting-minutes-dev `
            --settings "$($matches[1])=$($matches[2])"
    }
}

# 4. 初回 Subscription 作成
$webhookUrl = "https://$env:FUNCTION_APP_NAME.azurewebsites.net/api/subscriptions-bootstrap"
$key = az functionapp keys list -n $env:FUNCTION_APP_NAME -g rg-meeting-minutes-dev --query functionKeys.default -o tsv

curl.exe -X POST "$webhookUrl?code=$key" `
  -H "Content-Type: application/json" `
  -d '{"userId":"meetingbot@contoso.onmicrosoft.com"}'
```

### 9.2 日常運用チェック

- Application Insights ダッシュボードで「12時間ごとに renew が成功している」ことを確認
- 失敗イベントが連続発生していないか
- 月1回、`subscriptions` Table をエクスポートしてバックアップ

### 9.3 トラブル対応

| 症状 | 一次対応 |
|---|---|
| 通知が来ない | 1) Subscription 状態確認 2) Timer 履歴確認 3) Webhook URL 疎通確認 |
| Renew 失敗連続 | 1) Token 取得確認 2) Application permission 確認 3) Manual bootstrap |
| Lifecycle 通知だけ届く | App permission の reauth、もしくは Client Secret 期限切れ |

---

## 10. 設計図 (シーケンス)

```
[Timer 12h]                  [Functions]               [Graph API]              [Table]
    │                           │                           │                       │
    │ tick                      │                           │                       │
    ├──────────────────────────►│                           │                       │
    │                           │ list active               │                       │
    │                           ├──────────────────────────────────────────────────►│
    │                           │← entities ────────────────────────────────────────┤
    │                           │ for each sub              │                       │
    │                           │ ├ remaining > 36h → skip  │                       │
    │                           │ ├ otherwise:              │                       │
    │                           │ │   PATCH expirationDateTime ────────────────────►│
    │                           │ │   ← ok / 404            │                       │
    │                           │ │   if 404: createSubscription                    │
    │                           │ │     POST /subscriptions ────────────────────────►│
    │                           │ │     ← new sub                                   │
    │                           │ │   upsertEntity ───────────────────────────────► │
    │                           │ track metrics             │                       │
    │                           │                           │                       │
```

---

## 11. 関連リンク

- Microsoft Graph Subscription: https://learn.microsoft.com/en-us/graph/api/subscription-post-subscriptions
- Online Meeting Transcripts: https://learn.microsoft.com/en-us/graph/api/calltranscript-list
- Lifecycle Notifications: https://learn.microsoft.com/en-us/graph/webhooks-lifecycle
- NCRONTAB: https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-timer

---

**最終更新**: 2026-05-10
**設計者**: Claude / Yoshihiro Tsutsumi
