# CLI

CLIで、接続と権限の設定、対象の管理、障害対応、監査の予約、レポートの閲覧を行います。

[CLIをインストール](installation.md)した後、[CLIによる初回設定](first-steps.md#cli)でサーバーに接続し、利用する環境を設定します。

## コマンド

| 操作 | コマンド |
| --- | --- |
| サーバーと認証 | `config set-server`、`config show`、`auth login`、`auth status`、`auth logout` |
| アカウント | `account list`、`account create`、`account change-role` |
| 接続 | `provider services`、`provider list`、`provider create`、`provider check`、`provider enable`、`provider update` |
| AI役割と権限 | `ai-role list`、`provider usage`、`authority show`、`authority set` |
| 管理対象 | `target-type list`、`target create`、`target list`、`target show`、`target update` |
| アクセス方法 | `access-method create`、`access-method check`、`access-method list`、`access-method update` |
| 外部IDと関係 | `identity create`、`identity list`、`relationship create`、`relationship list` |
| インベントリ | `inventory preview-manual`、`inventory preview-provider`、`inventory rows`、`inventory apply` |
| 障害対応 | `case create`、`case show`、`case timeline`、`case resume`、`case cancel` |
| 判断と結果 | `proposal show`、`proposal decide`、`operation show`、`verification show` |
| 監視 | `signal list`、`signal show`、`signal events` |
| 監査 | `audit schedule`、`audit list`、`audit-run list`、`audit-run show` |
| レポートと配送 | `report list`、`report read`、`report summary`、`delivery create`、`delivery show` |
| 対象のファイル | `file upload`、`file list`、`file download`、`file revoke` |

コマンドの構文は`skopos --help`で確認します。

## 入力と出力

JSONを入力するコマンドには、`--input FILE`でファイル、`--input -`で標準入力を渡します。
[設定の入力例](configuration.md)のように、リソースのフィールドを直接指定します。

一覧はページごとに返されます。`--limit`と`--after`で続きを取得できます。
以降の操作には、返されたIDと現在のリビジョンを使用します。

プロバイダーと監査スケジュールの登録では、送信前に登録IDを標準エラー出力へ表示します。
応答が失われたときに元の登録を確認できるよう、IDを保管してください。

## 完了を待つ

```sh
skopos case wait CASE_ID --interval 1000 --timeout 60
skopos operation wait OPERATION_ID --interval 1000 --timeout 60
skopos verification wait VERIFICATION_ID --interval 1000 --timeout 60
skopos delivery wait DELIVERY_ID --interval 1000 --timeout 60
```

`--interval`はミリ秒、`--timeout`は秒です。

## 終了コード

| コード | 意味 |
| --- | --- |
| `0` | 成功または解決済み |
| `2` | コマンドの使用方法に誤り |
| `3` | 認証エラー |
| `4` | リクエストの拒否またはローカルエラー |
| `5` | 通信エラー |
| `10` | 受付済みまたは解決中 |
| `11` | 承認待ち |
| `12` | 対応が必要 |
| `13` | 失敗 |
| `14` | 部分完了 |
| `15` | 結果不明 |
| `16` | キャンセル要求済み |

自動化では、終了コードに加えて結果の状態とIDを確認します。
管理対象への変更後に通信エラーや結果不明になる場合があります。
