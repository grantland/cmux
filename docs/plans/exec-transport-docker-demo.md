# Testing the generic exec transport with `docker exec`

A self-contained, reproducible test of the `exec` remote transport on a machine with Docker.
This is the upstream-facing demo (no Meta-internal tooling). It exercises the full path:
named `cmux.json` transport → resolve → **auto-upload** `cmuxd-remote` over `docker exec` stdin →
hello → a real shell inside the container.

## Prereqs

- Docker running (`docker ps` works).
- Go toolchain (to build a Linux daemon binary for the Debug app — release builds skip this; see note).
- This branch checked out: `git checkout exec-transport` (and `./scripts/setup.sh` if first build).

## 1. Build a Linux `cmuxd-remote` for the container

Debug builds don't embed the daemon manifest, so the app needs a local Linux binary to upload.
Build a **static** (CGO-free) Linux/amd64 binary so it runs on Alpine:

```bash
cd daemon/remote
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w -X main.version=demo" \
  -o /tmp/cmuxd-remote-linux-amd64 ./cmd/cmuxd-remote
file /tmp/cmuxd-remote-linux-amd64   # ELF 64-bit ... x86-64, statically linked
cd ../..
```

(Apple Silicon: also fine — this cross-compiles. If your container is arm64, use `GOARCH=arm64`.)

## 2. Start a throwaway container

```bash
docker run -d --name cmux-demo alpine sleep infinity
```

## 3. Build + launch the tagged Debug app with the daemon binary

`CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1` is already set for tagged builds; just point it at the
binary from step 1 (the env passes through `reload.sh`'s launch):

```bash
CMUX_REMOTE_DAEMON_BINARY=/tmp/cmuxd-remote-linux-amd64 \
CMUX_SKIP_ZIG_BUILD=1 \
  ./scripts/reload.sh --tag exec-transport --launch
```

(`CMUX_SKIP_ZIG_BUILD=1` stubs the ghostty CLI helper, only needed if your local `zig` isn't the
pinned version — harmless to always pass.)

## 4. Add a `docker` transport to cmux.json

Use a project-local `cmux.json` (so you don't touch your global config):

```bash
mkdir -p /tmp/cmux-docker-demo && cd /tmp/cmux-docker-demo
cat > cmux.json <<'JSON'
{
  "remoteTransports": {
    "docker": { "exec": ["docker", "exec", "-i", "%host"] }
  }
}
JSON
```

## 5. Open the workspace over `docker exec`

From the same directory (so cmux picks up the project `cmux.json`), drive the tagged app's CLI:

```bash
REPO=/path/to/cmux   # this repo checkout
CMUX_TAG=exec-transport "$REPO/scripts/cmux-debug-cli.sh" ssh --transport docker cmux-demo
```

(Or, from a terminal *inside* the running `cmux DEV exec-transport` app, just run
`cmux ssh --transport docker cmux-demo` — the bundled CLI is on PATH there.)

## 6. Verify

Look at the new workspace in the **cmux DEV exec-transport** window — you should land in a shell
**inside the container**. Confirm via the CLI:

```bash
CMUX_TAG=exec-transport "$REPO/scripts/cmux-debug-cli.sh" send --workspace workspace:<N> "echo DEMO=\$(hostname); cat /etc/os-release | head -1"
CMUX_TAG=exec-transport "$REPO/scripts/cmux-debug-cli.sh" send-key --workspace workspace:<N> enter
CMUX_TAG=exec-transport "$REPO/scripts/cmux-debug-cli.sh" read-screen --workspace workspace:<N> --lines 10
# Expect: DEMO=<container-id> and 'NAME="Alpine Linux"'.
```

Confirm the daemon was auto-uploaded into the container:

```bash
docker exec cmux-demo sh -c 'ls ~/.cmux/bin/cmuxd-remote/*/linux-amd64/cmuxd-remote'
```

## Variant: pre-placed daemon (no auto-upload)

To test the `remoteDaemonPath` override instead of auto-upload:

```bash
docker cp /tmp/cmuxd-remote-linux-amd64 cmux-demo:/cmuxd-remote
# cmux.json: { "remoteTransports": { "docker": {
#   "exec": ["docker","exec","-i","%host"], "remoteDaemonPath": "/cmuxd-remote" } } }
cmux ssh --transport docker cmux-demo   # skips upload, hellos at /cmuxd-remote
```

## Cleanup

```bash
docker rm -f cmux-demo
rm -f /tmp/cmuxd-remote-linux-amd64
# close the demo workspace(s) in the tagged app
```

## Notes

- The `exec` array is the wrapper; cmux appends the daemon command and bridges its stdio.
  `%host`/`%port`/`%user` are substituted from the destination/`--port`.
- This is the identical code path used for any exec transport (ssh-wrappers, `kubectl exec`, SSM).
- Release/nightly builds embed the daemon manifest and auto-download the pinned binary, so steps 1
  and `CMUX_REMOTE_DAEMON_BINARY` are only needed for local Debug builds.
