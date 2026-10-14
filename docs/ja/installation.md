# インストール

Skoposサーバーは、Docker Composeとリリースされたコンテナイメージで起動します。
操作にはWebまたはCLIを選びます。CLIを利用する場合は、操作する端末にインストールします。

## サーバーをインストールする

Composeプラグイン付きのDocker、curl、OpenSSLを用意します。

[GitHub Releases](https://github.com/skopos-org/skopos/releases)で利用するバージョンを選びます。
以下の`RELEASE_VERSION`を、先頭の`v`を除いたバージョン番号に置き換えてください。

```sh
mkdir skopos
cd skopos
export SKOPOS_VERSION=RELEASE_VERSION
curl --fail --location \
  "https://raw.githubusercontent.com/skopos-org/skopos/v${SKOPOS_VERSION}/compose.yaml" \
  --output compose.yaml
```

新規インストール時に一度だけ、起動設定を作成します。
`SKOPOS_PUBLIC_URL`には、運用者がアクセスするURLを指定してください。次の例ではローカルサーバーを使用します。

```sh
umask 077
cat > .env <<EOF
SKOPOS_VERSION=${SKOPOS_VERSION}
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SKOPOS_CREDENTIALS_KEY=$(openssl rand -base64 32)
SKOPOS_TOKEN_SIGNING_SECRET=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 64)
SKOPOS_PUBLIC_URL=http://localhost:4000
SKOPOS_PORT=4000
EOF
docker compose pull
docker compose up --no-build -d
docker compose ps --all
```

`migrate`が終了コード0で終了し、`server`が実行中であることを確認します。
設定した公開URLを開き、[初回設定](first-steps.md)へ進みます。

HTTPS、ポート、その他の設定は[設定](configuration.md)を参照してください。
設定変更や更新の際も、既存のシークレットを維持します。

## CLIをインストールする

[GitHub Releases](https://github.com/skopos-org/skopos/releases)で利用するリリースを選びます。
端末に合った実行ファイルと、そのリリースの`SHA256SUMS`をダウンロードします。

| 環境 | 配布ファイル |
| --- | --- |
| Linux x86-64 | `skopos-VERSION-linux_x86_64` |
| Linux ARM64 | `skopos-VERSION-linux_aarch64` |
| macOS Intel | `skopos-VERSION-macos_x86_64` |
| macOS Apple Silicon | `skopos-VERSION-macos_aarch64` |
| Windows x86-64 | `skopos-VERSION-windows_x86_64.exe` |

`SHA256SUMS`でダウンロードしたファイルを検証します。
LinuxとmacOSでは実行権限を付けます。
ファイル名を`skopos`（Windowsでは`skopos.exe`）に変更し、`PATH`に含まれるディレクトリへ配置してください。

```sh
skopos --version
skopos --help
```

[CLIによる初回設定](first-steps.md#cli)へ進みます。

## サーバーを更新する

選んだリリースの変更内容を確認し、そのバージョンの`compose.yaml`を取得します。
既存の`.env`の`SKOPOS_VERSION`を更新先のバージョンに変更し、次のコマンドを実行します。

```sh
docker compose pull
docker compose up --no-build -d
docker compose ps --all
```

`migrate`が終了コード0で終了し、`server`が実行中であることを確認します。
