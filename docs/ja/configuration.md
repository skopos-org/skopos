# 設定

サーバーの導入と環境への接続に必要な設定です。
接続とAIの権限は、WebまたはCLIで設定できます。

## サーバーの起動設定

`compose.yaml`と同じディレクトリの`.env`に指定します。

| 変数 | 用途 | 設定値 |
| --- | --- | --- |
| `SKOPOS_VERSION` | コンテナのバージョン | 選んだリリースのバージョン番号。先頭の`v`を除く |
| `SKOPOS_IMAGE` | コンテナのレジストリとイメージ名 | `ghcr.io/skopos-org/skopos` |
| `POSTGRES_PASSWORD` | データベースのパスワード | 必須 |
| `SKOPOS_CREDENTIALS_KEY` | 接続の認証情報を暗号化する鍵 | 必須。32バイトの鍵をBase64でエンコードした値 |
| `SKOPOS_TOKEN_SIGNING_SECRET` | 認証トークンへの署名 | 必須 |
| `SECRET_KEY_BASE` | ブラウザーのセッション保護 | 必須 |
| `SKOPOS_PUBLIC_URL` | 運用者がSkoposへアクセスするURL | `http://localhost:4000` |
| `SKOPOS_PORT` | ホスト側のポート | `4000` |
| `SKOPOS_CASE_COLLECT_SECONDS` | アラートを収集する時間（秒） | `5`。`0`〜`30`の整数 |

`SKOPOS_PUBLIC_URL`には、`https://skopos.example.org`などのHTTP(S)オリジンを指定します。
標準以外のポートは含め、パスやクエリーは含めません。
HTTPSでは、リバースプロキシからサーバーのポート4000へHTTPとWebSocketのリクエストを転送します。

起動設定の変更後は`docker compose up --no-build -d server`を実行します。
既存の暗号鍵と署名用シークレットを維持してください。

## 接続設定

| 接続 | 設定する内容 |
| --- | --- |
| AI | サービス、モデル、認証情報、ResolverとReviewerの役割 |
| 監視 | Webhookアダプター、送信元名、Webhookシークレット |
| 対象へのアクセス | プロトコル、接続先、認証情報、許可する操作能力 |
| インベントリ | 対象を取り込む場合の台帳接続と認証情報 |
| 通知 | レポートを送信する場合の送信先と認証情報 |

管理するインフラを対象（Target）として登録し、アクセス方法を追加します。
監視のラベルと対象を対応付けるには、外部IDを設定します。

## AIの権限と制限

| モード | 変更の承認方法 |
| --- | --- |
| 読み取り専用（Read only） | 管理対象を変更せずに観測する |
| 毎回確認（Ask） | 提案された変更ごとに運用者が承認する |
| 自動（Auto） | 割り当てたReviewerが変更を承認する |
| フルアクセス（Full access） | 人間やReviewerの承認なしに変更を実行できる |

ケースの調査と対処を行うAIをResolverに割り当てます。
自動モードにはReviewerも必要です。１つの接続を両方の役割に使う場合は「両方（Resolver・Reviewer）」を選びます。

経過時間、Resolverのターン数、対象へのリクエスト数、変更数、関連対象数、AI使用量、進展のないターン数の上限を設定します。

**受信Signalから解決を開始**は、受信したアラートから自動的に解決を開始する設定です。
接続先とAIの権限を設定してから有効化してください。

## CLIで使用する入力ファイル

[CLIによる初回設定](first-steps.md#cli)では、次のファイルを使用します。
接続先、認証情報、ID、リビジョンを実際の値に置き換えてください。
SSHと汎用Webhookは接続方法の例です。利用する環境に合ったプロトコルを選択します。

### AI接続: ai.json

`skopos provider services`でサービスを確認し、そのサービスのモデルを選びます。
次の例は、OpenAI接続を両方のAI役割に割り当てます。

```json
{
  "name": "Incident AI",
  "kind": "ai",
  "adapter_type": "req-llm",
  "configuration": {"provider": "openai", "model": "MODEL_ID"},
  "credentials": {"api_key": "API_KEY"},
  "usage_scope": "all",
  "usage_priority": 100
}
```

### 管理対象: target.json

`skopos target-type list`で対象の`type_id`と`kind`を選びます。
次の例は、独自のOSを持つホストを登録します。

```json
{"name": "managed-01", "type_id": "custom-os", "kind": "host"}
```

### 対象への接続: target-provider.json

SSHでは、接続先に対応する信頼済みのホスト鍵フィンガープリントを指定します。

```json
{
  "name": "Managed SSH",
  "kind": "target",
  "adapter_type": "ssh",
  "configuration": {
    "host_key_fingerprints": {
      "ssh://managed.example.org:22": "SHA256:HOST_KEY_FINGERPRINT"
    }
  },
  "credentials": {
    "username": "skopos",
    "auth_method": "password",
    "password": "PASSWORD"
  }
}
```

### アクセス方法: method.json

登録で返された対象IDとプロバイダーIDを使用します。
プロバイダーの現在のリビジョンは`skopos provider show PROVIDER_ID`で確認します。

```json
{
  "target_id": "TARGET_ID",
  "provider_id": "TARGET_PROVIDER_ID",
  "provider_revision": 1,
  "name": "SSH access",
  "method": "ssh",
  "endpoint": "ssh://managed.example.org:22",
  "capabilities": ["request.ssh.effect"]
}
```

### 監視接続: signal.json

```json
{
  "name": "Monitoring",
  "kind": "signal",
  "adapter_type": "generic-webhook",
  "configuration": {"source": "monitoring"},
  "credentials": {"secret": "WEBHOOK_SECRET_AT_LEAST_16_CHARACTERS"}
}
```

このアダプターでは、`https://YOUR_SKOPOS/api/v1/signals/generic/SIGNAL_PROVIDER_ID`と`Authorization: Bearer WEBHOOK_SECRET`を送信側に設定します。
選択したアダプターの送信形式は[API仕様](api.md)で確認してください。

### 監視との対応付け: identity.json

受信アラートの対象参照と同じ送信元、IDの種類、値を使用します。

```json
{
  "target_id": "TARGET_ID",
  "source": "monitoring",
  "kind": "hostname",
  "value": "managed.example.org"
}
```

### 接続確認: revision.json

`provider show`または`access-method show`が返す現在の`revision`を指定します。
接続確認や有効化の前に、この値を更新してください。

```json
{"expected_revision": 1}
```

### 権限設定: authority.json

`skopos authority show`で取得した`setting_revision`を、`expected_setting_revision`に指定します。
上限は利用する環境に合わせて設定します。次の例は、毎回確認モードでアラートからの自動解決を無効にしています。

```json
{
  "expected_setting_revision": 1,
  "authority_mode": "ask",
  "signal_automation_enabled": false,
  "max_elapsed_seconds": 3600,
  "max_resolver_turns": 20,
  "max_target_requests": 100,
  "max_effects": 10,
  "max_related_targets": 20,
  "max_ai_usage_units": 1000000,
  "max_no_progress_turns": 3,
  "reason": "Initial setup"
}
```

### 最初のケース: case.json

観測した問題と、Skoposが確認できる結果を記載します。
手動で作成するケースごとに、異なる`source_ref`を指定してください。

```json
{
  "trigger_kind": "manual",
  "source": "cli",
  "source_ref": "initial-check-001",
  "title": "Investigate the managed system",
  "severity": "info",
  "initial_target_id": "TARGET_ID",
  "initial_context": {
    "observed_problem": "Describe the symptom you observed",
    "desired_outcome": "Describe the observable condition that confirms recovery"
  }
}
```
