# Contributing

Skopos uses one Phoenix/Elixir application and a React/TypeScript frontend. The
product CLI is an Elixir API client. Native protocol bindings require Rust and C
build tools.

## Development environment

The root `Dockerfile` owns the build tool versions. Use matching Elixir/Erlang,
Node, and Rust versions; the frontend package manifest specifies pnpm. You also
need PostgreSQL and the native build prerequisites used by CI: a C/C++ toolchain,
Git, curl, autoconf, automake, libtool, pkg-config, and OpenSSL development headers.

For development, `config/dev.exs` expects PostgreSQL on `localhost:5432` with the
username and password `postgres`; the database is `skopos_dev`. Prepare a dedicated
development database before running setup.

```sh
corepack enable
mix setup
mix phx.server
```

Open <http://localhost:4000>. Frontend changes are built with `mix assets.build`.

## Checks

Use the existing development checks before submitting a change:

```sh
mix precommit
mix cmd --cd assets corepack pnpm exec vp test
cargo fmt --manifest-path native/ipmi_nif/Cargo.toml --check
MIX_ENV=cli mix compile --warnings-as-errors
```

Tests use the separate `skopos_test` PostgreSQL database configured in
`config/test.exs`. Keep development and test databases separate from an operated
installation.

## Documentation

Documentation is generated with ExDoc, a development dependency. Shared settings
and page order live in `docs/ex_doc.exs`. English originals live in `docs/en/`,
with their navigation labels in `docs/en/ex_doc.exs`. Generated HTML goes to
git-ignored `doc/en/`.

```sh
mix deps.get
mix docs --warnings-as-errors
```

Open `doc/en/index.html` to preview the documentation. Changes to Markdown should use relative
links to the other guide files so they work both in GitHub and in generated HTML.
The Documentation workflow builds pull requests and publishes main to GitHub Pages.

### Add a translation

Create `docs/LANGUAGE/` using a BCP 47 language tag, for example `ja` or `pt-BR`.
Keep the same Markdown filenames as the English originals and translate their
contents. Add an `ex_doc.exs` with the language's own name and translated
navigation labels, following `docs/en/ex_doc.exs`.

```sh
EXDOC_LANGUAGE=ja mix docs --warnings-as-errors
```

Each language has its own output directory, canonical URLs, and search index.
The workflow discovers language configurations and builds all of them into the
same Pages artifact. A language menu appears when more than one language is
configured. The site root opens English documentation. The shared Apache license
remains the original text in every language's documentation.

ExDoc's language setting identifies the content language; it does not translate
its built-in interface. Translated prose and navigation labels belong to the
language's source files and configuration.

Use a working branch and submit a pull request with the reason for the change and
relevant validation. Keep README as the project entry point; put detailed
installation and operation instructions in these guides.
