# 初回設定

AIサービスと管理対象を接続し、権限を設定した後、ケースを作成して結果を確認します。
以下のWebまたはCLIの手順を使用してください。
接続の追加と権限の変更には、管理者アカウントが必要です。

## Web

1. サーバーのURLを開き、ログイン画面の「初回利用ですか？ 管理者を作成」を選びます。
   メールアドレス、12文字以上のパスワード、確認用パスワードを入力し、「管理者を作成」を選びます。
2. 「Skoposを環境へ接続」で「AIを設定」を選びます。
   サービスを選択し、モデルと認証情報を入力して、AIの役割を選びます。
   ResolverとReviewerの両方に割り当てる場合は「両方（Resolver・Reviewer）」を選びます。
   接続を保存し、「接続確認」、続いて「有効化」を選びます。
3. 「AI → AI権限と制限」を開きます。
   権限モード、実行上限、変更理由を入力して保存します。
   設定中は「受信Signalから解決を開始」を無効にします。[権限の設定](configuration.md)も参照してください。
4. 「対象 → Targetを追加」を開きます。
   カテゴリーと種類を選び、名前を入力して保存します。
   対象の画面で「接続経路を追加 → 接続を新規登録」を選びます。
   プロトコルを選び、接続先と認証情報を入力して接続を作成します。
   接続経路を追加した後、「接続確認」を選びます。
   「接続経路を編集」で許可する操作能力を選択し、保存します。
5. 「Signal → Signal接続を追加」を開きます。
   監視アダプターを選び、送信元名とWebhookシークレットを入力して保存し、接続確認と有効化を行います。
   表示されたWebhook URLとシークレットを監視システムの送信先に設定します。
   送信側の対象参照に一致する外部IDを、対象に追加します。
6. 「ケース → ケースを作成」を開きます。
   対象を選び、観測した問題と期待する結果を入力して作成します。
   「サービスを再起動する」といった操作ではなく、対象上で確認できる結果を記載してください。
7. 作成したケースを開き、観測、変更提案、復旧確認を追います。
   毎回確認モードでは、提案された変更を承認または却下します。
   [運用](operations.md)の手順で、復旧の証拠とレポートを確認します。

## CLI

ブラウザーを利用できる端末で`skopos auth login`を実行し、開いた画面でログインしてCLIを認可します。
新規インストールでは、そのログイン画面から最初の管理者を作成して認可してください。

`https://skopos.example.org`を、利用するSkoposサーバーのURLに置き換えます。

```sh
skopos config set-server https://skopos.example.org
skopos auth login
skopos auth status
```

[設定](configuration.md)のJSONファイルを用意します。
以下のIDには、各コマンドが返した値を使用します。
接続確認や有効化の前に、対象リソースの現在の`revision`を`revision.json`に指定してください。

1. AI接続を登録し、接続確認と有効化を行います。

   ```sh
   skopos provider services
   skopos provider create --input ai.json
   skopos provider show AI_PROVIDER_ID
   skopos provider check AI_PROVIDER_ID --input revision.json
   skopos provider show AI_PROVIDER_ID
   skopos provider enable AI_PROVIDER_ID --input revision.json
   skopos ai-role list
   ```

2. 権限設定を取得し、選んだモードと実行上限を保存します。

   ```sh
   skopos authority show
   skopos authority set --input authority.json
   ```

3. 対象と接続を登録します。
   プロバイダーを有効化した後、返されたリビジョンを`method.json`に指定します。

   ```sh
   skopos target-type list
   skopos target create --input target.json
   skopos provider create --input target-provider.json
   skopos provider show TARGET_PROVIDER_ID
   skopos provider enable TARGET_PROVIDER_ID --input revision.json
   skopos access-method create --input method.json
   skopos access-method show METHOD_ID
   skopos access-method check METHOD_ID --input revision.json
   ```

4. 監視接続を登録して有効化します。
   アダプターのWebhook URLと設定したシークレットを送信側に指定し、対応する対象の外部IDを登録します。

   ```sh
   skopos provider create --input signal.json
   skopos provider show SIGNAL_PROVIDER_ID
   skopos provider check SIGNAL_PROVIDER_ID --input revision.json
   skopos provider show SIGNAL_PROVIDER_ID
   skopos provider enable SIGNAL_PROVIDER_ID --input revision.json
   skopos identity create --input identity.json
   ```

5. ケースを作成し、結果を確認します。

   ```sh
   skopos case create --input case.json
   skopos case show CASE_ID
   skopos case wait CASE_ID --interval 1000 --timeout 60
   ```

毎回確認モードでは、ケースが承認待ちになります。
[CLIでの承認と結果確認](operations.md#cli)を行い、再度完了を待ちます。

接続とケースの結果を確認した後、Webの権限設定、または`skopos authority set`で`signal_automation_enabled`を`true`に設定し、
「受信Signalから解決を開始」を有効化します。
