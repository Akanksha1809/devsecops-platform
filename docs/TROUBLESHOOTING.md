# Troubleshooting

Every entry here is a real issue hit during this project's own development, not a hypothetical. Cross-references point to the fuller account in `docs/IMPLEMENTATION_PLAN.md`.

## "The app isn't reachable at the NodePort"

**Symptom**: `curl http://localhost:30080/health` hangs — TCP connects, then nothing, ever.

**Cause**: a real Colima quirk, not a bug in this project. Confirmed: the exact same request succeeds instantly from *inside* the kind node container (`docker exec devsecops-platform-control-plane curl ...`), proving the Service/kube-proxy/pod chain is fine — the break is specifically in Colima's SSH-based host↔VM port forwarding for this port mapping.

**Fix**: use `kubectl port-forward` instead — it tunnels through the already-working Kubernetes API connection, not Colima's separate port-forwarding path. `docs/IMPLEMENTATION_PLAN.md` §4b.

## "My docker-compose project deleted another container"

**Symptom**: a container from an unrelated project disappears after running `docker-compose up -d` in a directory that happens to also be named `jenkins`.

**Cause**: Compose derives a default project name from the directory name when none is set explicitly. Two unrelated projects both living in a directory literally named `jenkins`, both defining a service also named `jenkins`, collide — Compose matches the existing container as "this project's jenkins service" and replaces it.

**Fix**: always set an explicit top-level `name:` in `docker-compose.yml` (this project's `docker/jenkins/docker-compose.yml` does). If it's already happened: check for finalizers/cascade behavior (none here), confirm the underlying data volume is untouched (`docker volume inspect`), then recreate the container with the *same* project name the volume was originally created under (`docker-compose -p <original-name> up -d`) — using a *different* project name creates a second, empty volume instead of reusing the real one. `docs/IMPLEMENTATION_PLAN.md` §4a.

## "`/tmp/whatever` doesn't exist inside a container, even though I just created it"

**Cause**: Colima's automount mirrors the home directory into its VM, **not** `/tmp`. A file at `/tmp/foo` on macOS resolves to the *VM's own, unrelated* `/tmp/foo` when bind-mounted into a container — which might not exist, or might be a stale directory from something else entirely ("is a directory" errors on a file you just wrote are the telltale sign).

**Fix**: use a path under the project directory, or Claude's own scratchpad directory, for anything you need to bind-mount into a container on this setup. `docs/IMPLEMENTATION_PLAN.md` §4e.

## "checkov reports zero findings against a directory that clearly has YAML in it"

**Cause**: a bind-mounted directory sometimes triggers a spurious `FileNotFoundError` in checkov's forked worker processes on this Colima setup, even though the file is readable from the host and via a plain `docker exec`.

**Fix**: `docker cp` the file(s) into the container instead of bind-mounting, then run checkov against that in-container path. `docs/IMPLEMENTATION_PLAN.md` §4b.

## "My Jenkins pipeline fails with `MissingPropertyException`"

**Cause**: a plain top-level Groovy `def` variable set in one stage's `script{}` block, read from a different stage (or a function called from one). Jenkins' CPS runtime doesn't reliably persist these across stage boundaries.

**Fix**: use `env.VAR = value` (persists correctly) instead of a bare `def`, or resolve the value fresh each time (e.g. `$(hostname)` in shell, not a cached Groovy variable). `docs/PIPELINE_WALKTHROUGH.md`.

## "Argo Rollouts' AnalysisRun can't reach my canary Service" / "a cross-namespace call silently times out"

**Cause**: this kind cluster's CNI (kindnet) **does** enforce `NetworkPolicy`, contrary to general kindnet folklore. If a NetworkPolicy exists for the target pod's namespace and doesn't explicitly allow the caller's namespace, the connection just times out — no explicit rejection, which makes it look like a DNS or networking problem rather than a policy one.

**Fix**: add an explicit `namespaceSelector` ingress rule for the calling namespace. Check with a two-sided test: same-namespace curl (works) vs. cross-namespace curl (fails) isolates it immediately. `docs/IMPLEMENTATION_PLAN.md` §4d.

## "A Vault pod I'm customizing crash-loops"

Three distinct real causes, each confirmed by reading the actual `docker-entrypoint.sh` rather than guessing:

1. `VAULT_LOCAL_CONFIG` set → entrypoint tries to write `/vault/config/local.json` → "Permission denied" if that path isn't writable. **Fix**: don't set it; dev mode doesn't need it.
2. `capabilities.drop: ["ALL"]` → the entrypoint's `setcap cap_ipc_lock=+ep` fails (`CAP_SETFCAP` removed). **Fix**: `SKIP_SETCAP=true` (a real, documented entrypoint env var).
3. Same dropped capabilities → `su-exec`'s root→vault-user privilege drop fails (`setgroups: Operation not permitted`). **Fix**: set `runAsUser`/`runAsGroup` to the image's own built-in non-root user directly, so the entrypoint never attempts the root→non-root transition at all.

`docs/IMPLEMENTATION_PLAN.md` §4g.

## "A secret I deleted in a later commit still fails the gitleaks gate"

**Cause**: gitleaks here is git-history-aware by design (see the Secret scan stage). Deleting a file in a later commit does not remove it from git history — the commit that introduced it is still there, and gitleaks correctly keeps flagging it.

**Fix (non-destructive)**: add the specific fingerprint(s) to `.gitleaksignore` after manually confirming the finding is safe (e.g. a disposable test fixture). **Not** a way to silence the scanner broadly — only acknowledges specific, reviewed findings. The alternative (rewriting published git history) is far more disruptive and wasn't warranted here. `docs/FAILURE_SCENARIOS.md` Scenario 3.

## "Jenkins' pipeline shows stale security findings" / "my new directory isn't being scanned"

**Cause**: Jenkins only validates whatever commit it last checked out. If the pipeline hasn't been triggered since new directories/files were added, every "this pipeline validates X" claim for that new content is aspirational, not actually run — this project hit exactly this between Phases 2 and 7.

**Fix**: re-run the pipeline whenever you want current evidence, don't assume an old green build still reflects new content.

## "A script that worked fine when I typed it hangs forever when run headless/recorded"

**Symptom**: `git log` (or any command that can invoke a pager) runs fine interactively but hangs indefinitely — 30+ minutes, no output — when run inside something that creates a pty without a real attached terminal (e.g. `asciinema rec --command "..."` for a headless recording).

**Cause**: git detects what looks like a TTY and invokes `less` as a pager; with no real keyboard attached, `less` waits forever for input that never arrives.

**Fix**: `export GIT_PAGER=cat PAGER=cat` before running anything non-interactively. Diagnosed by checking `ps aux` for the actual hung process, not assumed.

## "`timeout 70 some-command` silently does nothing on macOS"

**Cause**: `timeout` is a GNU coreutils command, not present on macOS by default (no `timeout`, no `gtimeout` unless coreutils is installed via brew). The command fails with "command not found" — which, inside a backgrounded/wrapped shell, can silently skip the whole line rather than visibly erroring, since the subsequent `|| true` swallows the failure.

**Fix**: use a background-process-plus-`sleep`-plus-`kill` pattern instead: `cmd & PID=$!; sleep N; kill "$PID"`.

## "Everything on the cluster gets flaky — probes time out, port-forwards drop, even basic `kubectl` commands hang"

**Cause**: host-level CPU contention, not a bug in this project. Confirmed via `docker stats`: two kind clusters together briefly exceeded 400% CPU on a 4-CPU Colima VM, enough that even this project's own simple FastAPI app failed its own liveness probe (`context deadline exceeded`) and crash-looped — collateral damage from an unrelated process, not a regression in this app.

**Fix**: `docker stats --no-stream` to confirm it's genuinely contention and not a real failure; if another project's cluster is the cause, `docker stop <that container>` (not delete) frees the CPU immediately, with the other project able to resume later via `docker start`. Always confirm with the owner before stopping another project's container — this isn't something to do unprompted.

## "`terraform plan` keeps showing a change I didn't make"

**Cause**: a resource co-managed by Terraform and another controller (Argo CD's `CreateNamespace=true` stamping a `tracking-id` annotation onto a Terraform-managed namespace is this project's real example). Both tools are legitimately right about the piece they manage; neither is "wrong."

**Fix**: `lifecycle { ignore_changes = [...] }` on the specific field the other tool owns. `docs/IMPLEMENTATION_PLAN.md` §4f.

## Recovery from a failed CI job, an unhealthy rollout, or an Argo CD sync issue

- **Failed CI job**: check which stage failed (`docs/PIPELINE_WALKTHROUGH.md` lists all of them); fix the root cause, push again. No manual cleanup needed — Jenkins never touches the cluster, so a failed build leaves the running deployment untouched (verified directly in `docs/FAILURE_SCENARIOS.md` Scenario 2).
- **Unhealthy/stuck rollout**: `kubectl argo rollouts get rollout devsecops-app -n devsecops-dev` to see exactly which step it's stuck on. If it's degraded, the previous stable ReplicaSet is still serving — verified with a continuous availability probe during a real abort, see `docs/FAILURE_SCENARIOS.md` Scenario 6. `kubectl argo rollouts retry rollout devsecops-app -n devsecops-dev` to retry after fixing the cause.
- **Argo CD sync failure**: `argocd app get <name>` for the specific error; `argocd app sync <name> --force` as a last resort. Check for the same kind of multi-tool-ownership conflict described above before assuming it's a real failure.
