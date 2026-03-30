FROM node:20

ARG TZ=UTC
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest
ARG GIT_DELTA_VERSION=0.18.2
ARG ZSH_IN_DOCKER_VERSION=1.2.0

# ── Core platform tooling — NO language runtimes ──────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
  less git procps sudo fzf zsh man-db unzip gnupg2 gh \
  iptables ipset iproute2 dnsutils aggregate \
  jq nano vim curl wget ca-certificates apt-transport-https \
  awscli \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── npm global prefix for non-root use ───────────────────────────────────────
RUN mkdir -p /usr/local/share/npm-global \
  && chown -R node:node /usr/local/share

# ── Persist bash/zsh history ─────────────────────────────────────────────────
RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R node /commandhistory

# ── Workspace and Claude config dirs ─────────────────────────────────────────
RUN mkdir -p /workspace /root/.claude \
  && chown -R node:node /workspace

ENV DEVCONTAINER=true

WORKDIR /workspace

# ── git-delta (syntax-highlighting pager for git diffs) ──────────────────────
RUN ARCH=$(dpkg --print-architecture) && \
  wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# ── Non-root user setup ───────────────────────────────────────────────────────
USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# ── Zsh with Oh My Zsh (Powerlevel10k) ───────────────────────────────────────
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# ── Claude Code CLI ───────────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# ── Layer 1 security assets (root required) ───────────────────────────────────
USER root

# COPY 1: Baseline managed settings — policy floor baked into image
# These are the security controls active even when S3 is unreachable
COPY managed-settings/ /etc/cg-managed-settings/
# Directory needs 755 (traversable by all), files need 444 (read-only by all)
RUN chmod 755 /etc/cg-managed-settings && chmod 444 /etc/cg-managed-settings/*

# sync-security-policy.sh — runs at every container start (postStartCommand)
# Fetches COPY 2 from S3, falls back to COPY 1 above if unreachable
COPY scripts/sync-security-policy.sh /usr/local/bin/sync-security-policy.sh
RUN chmod +x /usr/local/bin/sync-security-policy.sh

# init-firewall.sh — best-effort egress control (until Apex)
COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh \
  && echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
     > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall

USER node
