ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20260824-slim
ARG NODE_IMAGE=node:24.21.0-bookworm-slim
ARG RUNNER_IMAGE=debian:bookworm-slim
ARG RUST_IMAGE=rust:1.98.0-bookworm

FROM ${RUST_IMAGE} AS rust

FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS assets

WORKDIR /app
COPY assets/package.json assets/pnpm-lock.yaml assets/
RUN corepack enable \
  && cd assets \
  && pnpm install --frozen-lockfile
COPY assets assets
RUN cd assets && pnpm run build

FROM ${ELIXIR_IMAGE} AS builder

COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:${PATH}

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git curl autoconf automake libtool pkg-config libssl-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY rust-toolchain.toml ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY native native
COPY priv priv
COPY config/runtime.exs config/
COPY --from=assets /app/priv/static priv/static

RUN mix compile && mix release skopos_server

FROM ${RUNNER_IMAGE} AS server

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 openssl \
  && rm -rf /var/lib/apt/lists/*

ARG SKOPOS_VERSION=0.1.1
LABEL org.opencontainers.image.title="Skopos" \
      org.opencontainers.image.version="${SKOPOS_VERSION}"

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app
RUN useradd --create-home --uid 10001 skopos
COPY --from=builder --chown=skopos:skopos /app/_build/prod/rel/skopos_server ./

USER skopos
EXPOSE 4000

ENTRYPOINT ["/app/bin/skopos_server"]
CMD ["start"]
