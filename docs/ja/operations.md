# 運用

WebまたはCLIで、障害対応の進捗、提案された変更、復旧の結果を確認します。

## Web

1. 「ケース」から障害を選び、観測した問題、期待する結果、観測、提案された対処を確認します。
2. 毎回確認モードでは、提案の対象、操作、期待する結果を確認します。
   判断理由を入力し、変更を承認または却下します。
3. 操作と復旧確認の結果を追います。
   変更の完了だけでは復旧を確認できないため、新しい観測が期待する結果を満たしているか確認します。
4. ケースのレポートで結果と証拠を確認します。
   対応が必要なケースでは、理由を確認してから接続、権限、実行上限を修正し、再開します。

対応を停止する場合は、ケースのキャンセル操作で停止を要求します。
操作が`unknown`または`partial`の場合は、対象の状態と記録された証拠を確認してから、再実行するか判断してください。

## CLI

ケースを選び、障害対応の内容を確認します。

```sh
skopos case list --limit 20
skopos case show CASE_ID
skopos case timeline CASE_ID
skopos case proposals CASE_ID
skopos case operations CASE_ID
skopos case verifications CASE_ID
```

承認の前に、`skopos proposal show PROPOSAL_ID`で提案を確認します。
現在の`revision`と`proposal_digest`を`decision.json`へ転記し、
`approved`または`rejected`と判断理由を指定します。

```json
{
  "expected_revision": 1,
  "proposal_digest": "PROPOSAL_DIGEST",
  "decision": "approved",
  "reason": "Explain why this change is approved"
}
```

```sh
skopos proposal decide PROPOSAL_ID --input decision.json
skopos case wait CASE_ID --interval 1000 --timeout 60
skopos case evidence CASE_ID
skopos report list
skopos report read REPORT_ID
```

対応が必要なケースは、`case show`で理由を確認します。
問題を修正した後、`case show`が返す現在のケースのリビジョンと、最新の実行ID・リビジョンを`resume.json`へ転記します。
再開後の権限と実行上限を指定してください。

```json
{
  "expected_case_revision": 1,
  "resolution_run_id": "RUN_ID",
  "expected_run_revision": 1,
  "authority_mode": "ask",
  "max_elapsed_seconds": 3600,
  "max_resolver_turns": 20,
  "max_target_requests": 100,
  "max_effects": 10,
  "max_related_targets": 20,
  "max_ai_usage_units": 1000000,
  "max_no_progress_turns": 3,
  "reason": "Explain what was corrected"
}
```

```sh
skopos case resume CASE_ID --input resume.json
skopos case wait CASE_ID --interval 1000 --timeout 60
```

キャンセルには、ケースの現在のリビジョンを指定します。

```json
{"expected_revision": 1}
```

`cancel.json`として保存し、実行します。

```sh
skopos case cancel CASE_ID --input cancel.json
skopos case show CASE_ID
```

キャンセル要求によって、完了済みの変更が取り消されることはありません。
`unknown`や`partial`の場合は、`operation show OPERATION_ID`と対象の状態を確認してから再実行を判断します。

## 定期監査

Webでは「監査 → 監査スケジュールを追加」を開きます。
対象、調査する条件、cron形式のスケジュール、タイムゾーン、レポートの言語を指定して保存します。
監査の実行結果から、ケースと結果を確認します。

CLIでは、同じ設定を`audit.json`に記載します。

```json
{
  "name": "Hourly infrastructure check",
  "desired_outcome": "Describe the condition to investigate",
  "target_ids": ["TARGET_ID"],
  "cron_expression": "0 * * * *",
  "timezone": "UTC",
  "report_language": "en"
}
```

```sh
skopos audit schedule --input audit.json
skopos audit list
skopos audit-run list
skopos audit-run show RUN_ID
```

## レポート

Webでは「レポート」からケースのレポートを読み、対象期間を指定して運用サマリーを確認します。
レポートを送信する場合は、同じ画面で通知先を設定します。

CLIでは、レポートの閲覧と期間を指定したサマリーの取得を行います。

```sh
skopos report list
skopos report read REPORT_ID
skopos report summary --from START_ISO8601 --to END_ISO8601
skopos delivery list
skopos delivery show DELIVERY_ID
```
