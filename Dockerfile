# Multi-stage Dockerfile for hermes-agent.
#
# Why multi-stage:
#   The single-stage version drags the entire build toolchain
#   (gcc/build-essential/python3-dev/libffi-dev) and ~3 GB of node_modules
#   into the runtime image. None of it is touched at runtime — node_modules
#   only exists to *produce* hermes_cli/web_dist and hermes_cli/tui_dist,
#   and the Python compile toolchain only exists to *build* the .venv
#   wheels for native extensions. Splitting them out drops image size from
#   ~5.6 GB to ~2.5 GB (with playwright) or ~1.2 GB (without playwright).
#
#   Cold-startup also drops from ~1m40s to ~10s because the entrypoint's
#   `chown -R /opt/hermes/.venv` (133 MB / 6300 files, overlay copy-up) no
#   longer runs when HERMES_BUILD_UID matches the host UID — see the
#   HERMES_BUILD_UID arg below.

FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source


# ============================================================================
# Builder stage: full toolchain. Everything here is discarded — only
# artifacts COPY'd into the runtime stage below survive.
# ============================================================================
FROM debian:13.4 AS builder

ENV PYTHONUNBUFFERED=1
# Outside /opt/data so the runtime volume mount doesn't shadow it.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential curl nodejs npm python3 python3-dev gcc libffi-dev git && \
    rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# Keep `file:` workspace deps as symlinks (npm 10+ default). Debian's
# bundled npm 9 otherwise installs them as copies, producing a hidden
# node_modules/.package-lock.json that permanently disagrees with the
# root lock and trips the TUI launcher's `_tui_need_npm_install()`
# reinstall path at runtime.
ENV npm_config_install_links=false

# ---------- Layer-cached npm install ----------
# Manifests first so `npm install` only re-runs when lockfiles change.
# hermes-ink is copied IN FULL because it's a `file:` workspace dep — npm
# needs the actual content to resolve, not just a bare package.json.
COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/
COPY ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

# ---------- Layer-cached Python deps ----------
# pyproject.toml + uv.lock first so dep resolve / wheel download / native
# compile is cached unless those inputs change. README.md is referenced by
# pyproject.toml's `readme =` field but excluded from the build context by
# .dockerignore — uv stats the path during resolution, so we touch an
# empty placeholder; the real README arrives with the source COPY below.
#
# `--extra all --extra messaging` (not `--all-extras`) deliberately
# excludes `[rl]` (atroposlib/tinker/torch/wandb from git), `[yc-bench]`
# (git dep), and `[termux-all]` (Android), none of which belong in the
# published container.
COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all --extra messaging

# ---------- Source + builds ----------
COPY . .

# Build dashboard (web_dist/) + TUI bundle, then stage tui_dist/entry.js
# under hermes_cli/ where _find_bundled_tui() looks for it. With the
# bundle pre-staged the launcher's `node tui_dist/entry.js` path fires
# directly — no runtime npm install + esbuild rebuild needed (which
# previously failed EACCES whenever the entrypoint's UID remap left
# /opt/hermes/ui-tui/dist owned by the build UID).
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build && \
    mkdir -p /opt/hermes/hermes_cli/tui_dist && \
    cp /opt/hermes/ui-tui/dist/entry.js /opt/hermes/hermes_cli/tui_dist/

# Editable install for the project (no-deps because deps are already in
# .venv from the cached uv sync). Lets `hermes` resolve to
# /opt/hermes/.venv/bin/hermes which entry-points back into this tree.
# The runtime-stage `COPY --from=builder --chown=hermes:hermes` below
# sets hermes ownership on everything under /opt/hermes — superset of
# the .venv + ui-tui + node_modules chown the single-stage version did
# in a separate layer, so lazy_deps.py / TUI runtime npm install still
# work without EACCES.
RUN uv pip install --no-cache-dir --no-deps -e "."

# Trim build-only bulk before the runtime COPY below. web_dist and
# tui_dist already live under hermes_cli/, so the original web/ and
# ui-tui/ trees are dead weight. node_modules across all three trees
# accounts for ~3 GB of the single-stage image's bloat.
RUN find /opt/hermes -name node_modules -type d -prune -exec rm -rf {} + && \
    rm -rf /opt/hermes/web /opt/hermes/ui-tui


# ============================================================================
# Runtime stage: slim base, runtime-only system deps, COPY'd artifacts.
# No gcc, no build-essential, no python3-dev, no libffi-dev — none of
# those are touched once .venv is built.
# ============================================================================
FROM debian:13.4-slim AS runtime

ENV PYTHONUNBUFFERED=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Runtime-only system deps.
#
#   python3      runs the .venv interpreter
#   nodejs       runs the pre-built TUI bundle (tui_dist/entry.js)
#   npm          - agent/lsp/install.py auto-installs language servers
#                  (pyright, ts-language-server, eslint, intelephense, ...)
#                  via `npm install --prefix <staging>` on first use
#                - gateway/platforms/whatsapp.py auto-installs the
#                  whatsapp-web.js bridge deps on first session
#   ripgrep      hermes' fast-search tool path
#   ffmpeg       voice tools (whisper, TTS, audio processing)
#   procps       /proc utilities used by various subprocess-management paths
#   git          hermes' git-aware tools
#   openssh-client  hermes' ssh-using tools
#   docker-cli   hermes' docker-environment sandbox tools
#   tini         PID 1, reaps orphaned MCP/git/bun subprocesses (see #15012)
#   gosu         entrypoint privilege drop
#   ca-certificates  TLS trust store for outbound HTTPS
#   curl         small utility used by various tools + diagnostics
#
# Playwright chromium runtime libraries follow the system tooling. The
# list mirrors what `npx playwright install --with-deps chromium --only-shell`
# fetches in the builder stage. Regenerate after a playwright bump with:
#   docker run --rm -it -e DEBIAN_FRONTEND=noninteractive debian:13.4 \
#     bash -c "apt-get update && apt-get install -y --no-install-recommends \
#       nodejs npm && npx playwright install-deps chromium 2>&1 | \
#       grep -oP 'NEW packages will be installed:\K[^\n]*'"
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 nodejs npm ripgrep ffmpeg procps git openssh-client docker-cli \
        tini ca-certificates curl \
        at-spi2-common fonts-freefont-ttf fonts-ipafont-gothic fonts-liberation \
        fonts-noto-color-emoji fonts-tlwg-loma-otf fonts-unifont fonts-wqy-zenhei \
        libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libavahi-client3 \
        libavahi-common-data libavahi-common3 libcups2t64 libfontenc1 libice6 \
        libnspr4 libnss3 libsm6 libunwind8 libxaw7 libxcomposite1 libxdamage1 \
        libxfont2 libxkbfile1 libxmu6 libxpm4 libxt6t64 x11-xkb-utils \
        xfonts-encodings xfonts-scalable xfonts-utils xserver-common xvfb && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for runtime. UID can be overridden at *build* time via
# `--build-arg HERMES_BUILD_UID=$(id -u)` so the in-container `hermes`
# user matches the host UID. When it does, the entrypoint's usermod /
# groupmod / chown block short-circuits and startup drops from ~1m40s
# (overlay copy-up of .venv) to a few seconds. Default 10000 preserves
# the legacy behavior — users who don't pass the build-arg get the same
# slow-but-portable startup the single-stage image had.
ARG HERMES_BUILD_UID=10000
RUN useradd -u ${HERMES_BUILD_UID} -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# Single trimmed COPY. --chown sets ownership at copy-time so we don't
# need a separate chmod/chown layer — that layer (in the single-stage
# Dockerfile) rewrote every .venv file into a new layer and roughly
# doubled image size on overlay storage.
COPY --from=builder --chown=hermes:hermes /opt/hermes /opt/hermes

# Runtime
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/data/.local/bin:/opt/hermes/.venv/bin:${PATH}"
RUN mkdir -p /opt/data
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]

