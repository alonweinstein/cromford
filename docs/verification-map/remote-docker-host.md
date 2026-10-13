# Remote docker host for the suite runner (DOCKER_HOST, one place)

**What it is:** `bin/run-tests-in-docker.sh` runs the shell suite in containers.
Since BH-1193 it runs them against whatever daemon `bin/lib/docker-host.sh`
resolves — the local one by default, a remote one when `DOCKER_HOST` is set —
and on a remote endpoint it SHIPS the checkout into the container instead of
bind-mounting it, because a bind mount resolves on the daemon's host and would
give the container an empty `/repo`.

**How an operator reaches it:** two commands, no cron lane, nothing to turn on.

| what | how |
|---|---|
| local, unchanged | `bin/run-tests-in-docker.sh tests/verification-map-build-test.sh` |
| against a remote host | `DOCKER_HOST=ssh://root@<host> bin/run-tests-in-docker.sh tests/verification-map-build-test.sh` |
| set once for a box | `DOCKER_HOST=ssh://root@<host>` in `<env dir>/global.env` (template: `env-templates/lanes/370-remote-docker-host.env.example`) |

Every run prints `run-in-docker: running on <endpoint>` or `running on the local
docker daemon` before it starts, so a green run says where it ran.

**Preconditions:** docker on this machine (the client) and on the host; `rsync`
on PATH for the remote path; ssh able to reach the host as the user in the
endpoint. Nothing else — the image is built on the host on the first run (with
no build context: the Dockerfile goes over stdin, so nothing uploads the
checkout first) and kept there.

**Verify it works:** the endpoint line names the host, the suite's own output
comes back, and the exit status is the number of failing suites. `exit 2` means
the run could not happen (docker missing, daemon not answering, rsync missing,
staging or `create`/`cp` failed, or a container that never reached `exited`) —
a configured endpoint that does not answer is always 2 and never a quiet local
run, and a docker-level failure of `docker start` is 2 rather than the "1
failing suite" its own status would otherwise read as.

**How to drive it:**

| what | how |
|---|---|
| the resolver's precedence, the nine local/remote classifications, the local path unchanged, the remote `create`/`cp`/`start` order with no `-v`, the empty stdin, the cleanup, fail-closed, a container that never ran, the image tag and its empty context, two concurrent runs (BH-1193) | `bash tests/run-tests-in-docker.bh-1193-test.sh` |
| the container's stdin and the local argv, from the other side | `bash tests/run-tests-in-docker-harness-test.sh` |
| the image tag moves with the package list | `bash tests/run-tests-in-docker.bh-1128-test.sh` |

All three stub `docker` on PATH. **Nothing in `tests/` contacts a real daemon**,
which is also what a suite here may never do.

The first one needs a real `rsync` to stage a real tree, and without one its
remote sections cannot run. A laptop without `rsync` gets a skip line; CI gets a
failure, because `.github/workflows/harness-ci.yml` exports `RSYNC_REQUIRED=1`
next to `CODEGRAPH_REQUIRED` / `AGE_REQUIRED` / `SEMGREP_REQUIRED` and
guard-installs `rsync` next to `age` and `zstd`. `fly/Dockerfile` bakes it in as
well, since the `bh-ci` image is the runner that had no `rsync`. Section F of
that suite pins all three, so the gate cannot be left with nothing behind it.

**Manual-only / not automatable:** a real remote host. The ticket's "ten
concurrent suites without a SIGKILL" needs a machine with docker on it and is an
operator check: stand the host up, point `DOCKER_HOST` at it, run ten suites at
once and watch the Mac's load. No suite here proves that, and a build that says
it did is claiming a rung it did not reach.

**Files it writes on a live box:** none that survive. Per run: one `mktemp -d`
staging tree and one container, both removed by an `EXIT`/`INT`/`TERM` trap.
No state, no lock, no ledger row.
