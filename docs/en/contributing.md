# Contributing

Use a working branch and submit a pull request with the reason for your change
and relevant validation. Keep README as the project entry point and detailed
usage instructions in the documentation.

## Development setup

The root `Dockerfile` specifies Elixir, Erlang, Node, and Rust versions.
The frontend package manifest specifies pnpm. Install these versions, PostgreSQL,
a C/C++ toolchain, Git, curl, autoconf, automake, libtool, pkg-config, and OpenSSL
development headers.

Clone the project:

```sh
git clone https://github.com/skopos-org/skopos.git
cd skopos
corepack enable
```

Prepare development PostgreSQL on `localhost:5432`, with username and password
`postgres`. Development uses `skopos_dev`; tests use the separate `skopos_test`.

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000>. Run `mix assets.build` to build frontend changes.

To run the CLI from source:

```sh
MIX_ENV=cli mix deps.get
MIX_ENV=cli mix run --no-halt -- --help
```

## Checks

```sh
mix precommit
mix cmd --cd assets corepack pnpm exec vp test
cargo fmt --manifest-path native/ipmi_nif/Cargo.toml --check
MIX_ENV=cli mix compile --warnings-as-errors
```

## Documentation

English guides are in `docs/en/`, Japanese guides in `docs/ja/`.
Each locale's `ex_doc.exs` contains its name and navigation labels;
`docs/ex_doc.exs` contains shared settings and page order.

```sh
mix deps.get
mix docs --warnings-as-errors
EXDOC_LANGUAGE=ja mix docs --warnings-as-errors
```

Preview `doc/en/index.html` and `doc/ja/index.html`.
Use relative Markdown links between guides.
The Documentation workflow validates pull requests and publishes main to
GitHub Pages.

### Add a language

1. Create `docs/LANGUAGE/` using a BCP 47 tag such as `ko` or `pt-BR`.
2. Translate all eight guides, keeping the same filenames as `docs/en/`.
3. Add `ex_doc.exs` with the language's own name and translated navigation labels.
4. Run `EXDOC_LANGUAGE=LANGUAGE mix docs --warnings-as-errors`.

Keep the Apache license text unchanged. Check the translated guides, navigation
labels, search results, and links in the generated site.

After an ExDoc update, check the language selector beside search, internal page
navigation, mobile layout, and switching between corresponding pages.
