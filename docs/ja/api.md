# APIリファレンス

SkoposのHTTP APIで、外部ツールや自動化を連携します。
APIは`/api/v1`以下にあります。

## OpenAPI仕様

利用するサーバーから仕様を取得します。

```sh
curl --fail --silent --show-error https://skopos.example.org/api/v1/openapi.json \
  --output skopos-openapi.json
```

オリジンをSkoposのURLに置き換えてください。
インストールしたバージョンのエンドポイント、入力、応答、権限を確認できます。

## 認証

認証が必要な操作には`Authorization: Bearer TOKEN`を指定します。
Skoposがアカウントに発行したトークンを使用してください。
APIの操作にも、管理者・運用者・閲覧者の権限が適用されます。

監視のWebhookには、設定したSignalプロバイダーのシークレットを使用します。
運用者のトークンは使用しません。

## リクエストと結果

呼び出す操作の入力形式に従います。
更新や判断には現在のリビジョンが必要で、承認には提案のダイジェストも必要です。
変更の前に、現在のレコードを取得してください。

完了前にIDが返された場合は、そのIDから結果を確認します。
応答が失われた場合も、再送する前に元のリクエストを確認してください。

接続の設定は[初回設定](first-steps.md)、障害対応は[運用](operations.md)、コマンドからの操作は[CLI](cli.md)を参照してください。
