# 開発への参加

作業ブランチで変更し、変更理由と検証結果を添えてプルリクエストを提出します。
READMEはプロジェクトの入口とし、詳しい使い方はドキュメントに記載してください。

## 開発環境を用意する

リポジトリのルートにある`Dockerfile`で、Elixir・Erlang・Node・Rustのバージョンを指定しています。
pnpmのバージョンは、フロントエンドのパッケージ定義にあります。
対応するツール、PostgreSQL、C/C++のツールチェーン、Git、curl、autoconf、automake、libtool、pkg-config、OpenSSLの開発用ヘッダーを用意します。

プロジェクトを取得します。

```sh
git clone https://github.com/skopos-org/skopos.git
cd skopos
corepack enable
```

`localhost:5432`に、ユーザー名・パスワードともに`postgres`の開発用PostgreSQLを用意します。
開発は`skopos_dev`、テストは別のデータベース`skopos_test`を使用します。

```sh
mix setup
mix phx.server
```

<http://localhost:4000>を開きます。
フロントエンドの変更は`mix assets.build`でビルドします。

CLIをソースから実行する場合は、次のコマンドを使用します。

```sh
MIX_ENV=cli mix deps.get
MIX_ENV=cli mix run --no-halt -- --help
```

## 開発時のチェック

```sh
mix precommit
mix cmd --cd assets corepack pnpm exec vp test
cargo fmt --manifest-path native/ipmi_nif/Cargo.toml --check
MIX_ENV=cli mix compile --warnings-as-errors
```

## ドキュメント

英語のガイドは`docs/en/`、日本語のガイドは`docs/ja/`にあります。
各言語の`ex_doc.exs`に言語名とナビゲーションの表示名、
`docs/ex_doc.exs`に共通設定とページの順序を記載します。

```sh
mix deps.get
mix docs --warnings-as-errors
EXDOC_LANGUAGE=ja mix docs --warnings-as-errors
```

`doc/en/index.html`と`doc/ja/index.html`を開いて確認します。
ガイド間のリンクはMarkdownの相対リンクで記述します。
Documentationワークフローはプルリクエストを検証し、mainをGitHub Pagesへ公開します。

### 言語を追加する

1. `ko`や`pt-BR`などのBCP 47タグで`docs/LANGUAGE/`を作成します。
2. `docs/en/`と同じファイル名で、８つのガイドを翻訳します。
3. 言語自身の名前と翻訳したナビゲーションの表示名を持つ`ex_doc.exs`を追加します。
4. `EXDOC_LANGUAGE=LANGUAGE mix docs --warnings-as-errors`を実行します。

Apacheライセンスの原文を維持してください。
生成したサイトで、翻訳した本文、ナビゲーションの表示名、検索結果、リンクを確認します。

ExDocの更新時は、検索欄の横にある言語切替、サイト内のページ移動、モバイル表示、同じページへの言語切替を確認してください。
