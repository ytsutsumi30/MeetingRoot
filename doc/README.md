# システム設計書 目次

**プロジェクト名**: OccupancyCounter + 議事録自動生成システム  
**最終更新**: 2026-05-15  

---

## ドキュメント一覧

| # | ドキュメント | 概要 |
|---|---|---|
| 1 | [システム全体概要](./01_system_overview.md) | プロジェクトの目的・スコープ・全体アーキテクチャ |
| 2 | [コンポーネント設計](./02_component_design.md) | 各コンポーネントの責務・内部構造・インターフェース |
| 3 | [データフロー・シーケンス設計](./03_data_flow.md) | 主要ユースケースのデータフロー・シーケンス図 |
| 4 | [データモデル設計](./04_data_model.md) | データ構造・状態遷移・ストレージ設計 |
| 5 | [API設計](./05_api_design.md) | REST API 仕様・外部API連携 |
| 6 | [インフラ・デプロイ設計](./06_infrastructure.md) | Azure リソース・IaC・CI/CD・環境構成 |
| 7 | [セキュリティ・運用設計](./07_security_operations.md) | 認証認可・データ保護・監視・運用手順 |

---

## 技術スタック サマリ

| 領域 | 技術 |
|---|---|
| Android | Kotlin / CameraX 1.3.1 / ML Kit Face Detection / OkHttp 4.12 |
| バックエンド | Node.js 18+ / Express 4 / multer |
| Webhook | Azure Functions v4 (Node.js) |
| 音声認識 | Azure Speech Service (Conversation Transcription) |
| 話者識別 | Azure Speaker Recognition |
| AI要約 | Anthropic Claude (claude-sonnet-4-5) |
| ドキュメント生成 | docx (npm) |
| クラウドストレージ | Microsoft OneDrive (Graph API) |
| メッセージング | Azure Queue Storage / Azure Blob Storage |
| インフラ | Azure Bicep (IaC) |
| フロントエンド | GitHub Pages (静的HTML/CSS/JS) |
| トンネル | Cloudflare Tunnel |
