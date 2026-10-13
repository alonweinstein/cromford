# fly/testhost/Dockerfile — the image of the shared test host app
# bh-testhost-example-org (#1597), the machines bin/remote-gate.sh runs suites on.
#
# Until #1597 this file lived only in one agent session's scratch directory, so
# the host the whole fleet gates on could not be reviewed or rebuilt from the
# repo. It is that image, plus fly/testhost/entrypoint.sh as the boot command
# (litter wiped at boot; /srv/tmp mounted as a tmpfs when the machine env
# carries REMOTE_GATE_TMPFS_SIZE). The toolchain is what the suites need that a
# stock Debian lacks: jq, git, rsync, shellcheck, gawk, python3 with PyYAML
# (python3-yaml, BH-1741: the mergify-template suites parse YAML), node (the
# nodejs.org tarball at the bake.node.version row, the node 22 CI runs; Debian's
# apt nodejs is a node 20 without node:sqlite, BH-1617), codegraph, semgrep and
# actionlint; util-linux brings findmnt, flock and mount.
#
# NO VERSION LITERAL LIVES HERE, the rule fly/Dockerfile follows (BH-1528): each
# pin is an ARG with no default, and the build refuses to run without it.
# NODE_VERSION is the bake.node.version settings row; fly/testhost/node-install.sh
# checks its sha256 and refuses a node without node:sqlite or
# --experimental-strip-types. The other values the machines run today are in
# docs/REMOTE-GATE.md, "Deploying the test host image", with the exact flyctl
# deploy line.
FROM debian:trixie-slim
ARG NODE_VERSION
ARG CODEGRAPH_VERSION
ARG SEMGREP_VERSION
ARG ACTIONLINT_VERSION
RUN test -n "$NODE_VERSION" && test -n "$CODEGRAPH_VERSION" && test -n "$SEMGREP_VERSION" && test -n "$ACTIONLINT_VERSION" \
 || { echo "FATAL: pass --build-arg NODE_VERSION, CODEGRAPH_VERSION, SEMGREP_VERSION and ACTIONLINT_VERSION (docs/REMOTE-GATE.md)" >&2; exit 1; }
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash coreutils jq git curl ca-certificates util-linux procps xz-utils \
      python3 python3-pip python3-yaml rsync shellcheck gawk openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY node-install.sh /usr/local/bin/testhost-node-install.sh
RUN chmod 755 /usr/local/bin/testhost-node-install.sh && /usr/local/bin/testhost-node-install.sh "$NODE_VERSION"
RUN npm install -g "@colbymchenry/codegraph@${CODEGRAPH_VERSION}" \
 && python3 -m pip install --quiet --break-system-packages "semgrep==${SEMGREP_VERSION}" \
 && curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin actionlint
COPY entrypoint.sh /usr/local/bin/testhost-entrypoint.sh
RUN chmod 755 /usr/local/bin/testhost-entrypoint.sh && mkdir -p /srv/runs /srv/tmp
CMD ["/usr/local/bin/testhost-entrypoint.sh"]
