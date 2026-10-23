# Acceptance scenarios

All 9 scenarios the brief asks for, each run for real at least once during this project's development — not simulated, not asserted. Every scenario below links to its actual evidence file(s) in `docs/evidence/`. Prerequisites, execution, expected result, and cleanup are given for each so they're reproducible by someone else.

## Scenario 1 — Successful release

**Prerequisites**: Argo CD managing `devsecops-dev`, Argo Rollouts installed, dev at a known-good revision.

**Execution**: change the app (e.g. bump `app.version` in `values-dev.yaml`, which also changes the pod template via the `checksum/config` annotation), push, `argocd app sync devsecops-app-dev`.

**Expected result**: the Rollout progresses through its canary steps (`setWeight 25 → pause → analysis → setWeight 50 → pause → setWeight 100`) and reaches `Healthy`.

**Actually observed**: full progression, 3/3 analysis probes passed, `Healthy` in ~30 seconds. `docs/evidence/phase5-good-canary-rollout.txt`, `docs/evidence/phase5-good-canary-analysisruns.yaml`.

**Cleanup**: none needed — this is the normal path.

## Scenario 2 — Test failure

**Prerequisites**: Jenkins running, pipeline job created.

**Execution**: commit a deliberately failing test, push, trigger a build.

**Expected result**: pipeline fails at the Unit tests stage; every later stage (including Build image and Publish) is skipped; the running deployment is untouched (Jenkins never touches the cluster).

**Actually observed**: build #6 failed exactly at Unit tests; 12 subsequent stages skipped; `devsecops-app` Rollout's age was unchanged across the whole run, confirming zero cluster impact. `docs/evidence/phase9-scenario2-test-failure-console.txt`.

**Cleanup**: revert the failing test, push again (done — build reverted in the very next commit).

## Scenario 3 — Secret detection

**Prerequisites**: Jenkins running.

**Execution**: commit a disposable fixture containing a fake credential, push, trigger a build.

**Expected result**: gitleaks catches it, pipeline fails at the Secret scan stage.

**Actually observed, in two parts**:
1. First attempt used AWS's own famous published example key (`AKIAIOSFODNN7EXAMPLE`) — the pipeline **passed**, because gitleaks ships a built-in allowlist for that exact value (it's used so ubiquitously in documentation that flagging it everywhere would be pure noise). A second attempt with an all-same-character fake secret also didn't trigger, for a different reason (insufficient entropy for the generic-secret rule). A properly randomized (still fake) value finally triggered both `aws-access-token` and `generic-api-key`. `docs/evidence/phase9-scenario3-secret-detection-console.txt`.
2. After deleting the fixture file in a later commit, the pipeline **still failed** — gitleaks is git-history-aware, and the commit that introduced the secret is still in history regardless of the later deletion. Fixed non-destructively with `.gitleaksignore` (specific reviewed fingerprints, not a broad silence). `docs/evidence/phase9-scenario3-secret-detection-gitleaks-history-console.txt`.

**Cleanup**: fixture file deleted; its two fingerprints allowlisted in `.gitleaksignore` with a comment explaining why.

## Scenario 4 — Vulnerable dependency

**Prerequisites**: Jenkins running.

**Execution**: pin a dependency version with a known CVE (`PyYAML==5.3`, CVE-2020-14343 and CVE-2020-1747, both CRITICAL) in `requirements.txt`, push, trigger a build.

**Expected result**: trivy's dependency scan catches it and fails the build before the image is built or published.

**Actually observed**: build #10 reported both CVEs as CRITICAL and failed at the Dependency vulnerability scan stage; 7 subsequent stages (including Build image and Publish) skipped. `docs/evidence/phase9-scenario4-vulnerable-dependency-console.txt`.

**Policy distinction** (per the brief's ask to document this): a HIGH finding on the *image* scan is informational (doesn't block, see `docs/SECURITY.md` §3); a HIGH/CRITICAL finding on the *dependency fs* scan always blocks, since at this stage there's no later stage still able to catch it other than redundantly re-scanning the same file after it's baked into the image.

**Cleanup**: pin removed in the next commit.

## Scenario 5 — Kubernetes drift

**Prerequisites**: `devsecops-app-dev` Argo CD Application with `selfHeal: true`.

**Execution**: `kubectl -n devsecops-dev scale deployment devsecops-app --replicas=5` (a direct, out-of-band change bypassing Git).

**Expected result**: Argo CD detects the drift and reverts it automatically.

**Actually observed**: detected as `OutOfSync` within 2 seconds of the scale command; self-healed back to the Git-declared replica count within 5 seconds total — fast enough that it's the controller's resource watch catching it, not the periodic ~3-minute reconciliation sweep. `docs/evidence/phase4-drift-selfheal-transcript.md`.

**Cleanup**: none — self-heal did it automatically.

## Scenario 6 — Unhealthy release

**Prerequisites**: canary AnalysisTemplate wired, `progressDeadlineSeconds`/`progressDeadlineAbort` configured.

**Execution**: deploy a version with `app.simulateUnhealthy: true` (flips `/ready` to 503).

**Expected result**: the bad release is caught before full promotion; the rollout aborts; the last healthy release keeps serving throughout.

**Actually observed**: caught *before* the AnalysisTemplate even ran — the canary pod's own `readinessProbe` never passed, so the Rollout sat at `setWeight: 25, ActualWeight: 0` until `progressDeadlineSeconds` (60s) elapsed and `progressDeadlineAbort` kicked in, scaling the bad canary to 0. A continuous availability probe against the main Service, started *before* the bad release was even pushed, recorded **180/180 successful responses** across the entire sequence. `docs/evidence/phase5-bad-canary-aborted.txt`, `docs/evidence/phase5-availability-during-abort.txt`.

**A real complication found in the same test**: after the abort, Argo Rollouts scaled the stable ReplicaSet back up to restore capacity, and the *new* stable pod also failed its readiness probe — because the bad config value lived in a single ConfigMap shared across every revision, not something baked immutably per-revision. Documented in full as a real limitation, not papered over: `docs/evidence/phase5-shared-configmap-blast-radius.txt`.

**Cleanup**: reverted `app.version`/`simulateUnhealthy` to the last good values; one bad pod needed an explicit `kubectl delete pod` since the ConfigMap fix didn't retroactively fix a pod already running under the old value.

## Scenario 7 — Monitoring alert

**Prerequisites**: Prometheus + Alertmanager running, `AppUnavailable` rule loaded.

**Execution**: scale dev to 0 replicas via Git (a real GitOps-declared failure, not a manual `kubectl` command selfHeal would just revert).

**Expected result**: the alert fires and reaches the configured receiver.

**Actually observed, with a real bug found along the way**: the original rule (`sum(up{...}) == 0`) went `pending` then silently disappeared instead of reaching `firing` — an empty vector (the target vanishing from service discovery entirely) never satisfies `== 0`. Fixed to `absent(up{...} == 1)`, re-ran: `pending` → `firing` in ~55s, Alertmanager got `connection refused` delivering to the now-0-replica app (the receiver *is* the app itself), retried automatically, and succeeded once the app came back, delivering both the `firing` and the later `resolved` notification. `docs/evidence/phase6-alert-firing-transcript.md`.

**Cleanup**: reverted `replicaCount` to 2.

## Scenario 8 — Environment promotion

**Prerequisites**: `devsecops-app-dev` (auto-sync) and `devsecops-app-staging` (no automated sync) both configured against the same Helm chart.

**Execution**: verify dev is healthy, then `argocd app sync devsecops-app-staging` — no rebuild, same image reference, just a different values file (`values-staging.yaml`, 2 replicas vs. dev's 2 at the time, different namespace).

**Expected result**: staging comes up healthy from the already-built artifact, no rebuild triggered.

**Actually observed**: staging went from `OutOfSync`/`Missing` to `Synced`/`Healthy` with the correct replica count immediately after the explicit sync — no CI run involved, confirming promotion doesn't require rebuilding. `docs/evidence/phase4-applications-status.txt`.

**Cleanup**: staging torn down afterward (`kubectl delete namespace devsecops-staging`) specifically to reclaim RAM for later phases — the Application CR itself was left in place, so a single `argocd app sync` brings it straight back.

## Scenario 9 — Reproducible recovery

The brief asks for documented recovery from a failed CI job, an unhealthy rollout, a registry auth failure, or an Argo CD sync issue. Rather than stage an artificial one, this project has *real* incidents from its own development to draw on — arguably more convincing than a manufactured example:

- **Recovered from an accidental resource deletion** (docker-compose project-name collision destroying an unrelated project's container) — confirmed no finalizers, confirmed the data volume was untouched, recreated the container under the *correct* original project name to reattach to the real volume rather than creating an empty new one. `docs/IMPLEMENTATION_PLAN.md` §4a.
- **Recovered from three consecutive pod crash-loops** (Vault) by reading the actual failing component's source each time rather than guessing — three distinct root causes, three distinct targeted fixes, zero trial-and-error flag-guessing. `docs/IMPLEMENTATION_PLAN.md` §4g.
- **Recovered from a secret that couldn't be "un-committed"** — git-history-aware secret scanning kept failing CI even after the offending file was deleted; resolved non-destructively via `.gitleaksignore` rather than rewriting published history. Scenario 3, above.
- **Recovered from a stuck/degraded Argo Rollout** (Scenario 6, above) automatically via `progressDeadlineAbort`, with the previous healthy release never going down.
- **Registry auth failure**: not yet hit for real (GHCR publish isn't exercised — see `docs/IMPLEMENTATION_PLAN.md` §4a) — the documented recovery path is: confirm the `ghcr-credentials` Jenkins credential exists and has `write:packages`; the pipeline's `Publish image` stage already degrades gracefully to "stays local-only" on any failure there, confirmed by code review of the `try/catch` in `Jenkinsfile`, not yet exercised against a real auth failure.

## Summary: which scenarios passed

| # | Scenario | Status |
|---|---|---|
| 1 | Successful release | ✅ Verified |
| 2 | Test failure | ✅ Verified |
| 3 | Secret detection | ✅ Verified (two real findings along the way) |
| 4 | Vulnerable dependency | ✅ Verified |
| 5 | Kubernetes drift | ✅ Verified |
| 6 | Unhealthy release | ✅ Verified (one real complication found and documented) |
| 7 | Monitoring alert | ✅ Verified (one real alert-rule bug found and fixed) |
| 8 | Environment promotion | ✅ Verified |
| 9 | Reproducible recovery | ✅ Verified against real incidents (registry-auth path documented, not yet exercised against a real failure) |
