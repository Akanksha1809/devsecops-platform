# Pipeline walkthrough

The full pipeline is `Jenkinsfile` at the repo root. This walks through why each stage exists and what it actually does — not just its name.

## Mechanism: docker-outside-of-docker

Jenkins' own container has only `docker-cli` installed — no Python, no trivy, no checkov, no terraform. Every stage that needs a tool runs that tool as its own short-lived sibling container, reached via `docker run --volumes-from $(hostname)` (where `$(hostname)` resolves to Jenkins' own container ID at runtime). This keeps Jenkins' image small and means adding a new tool to the pipeline never means rebuilding Jenkins' own image.

## Stage by stage

1. **Checkout** — `checkout scm`, then computes `env.SHORT_SHA`/`env.IMAGE_TAG` from `git rev-parse` (done here, not in the top-level `environment{}` block, because that block evaluates *before* checkout runs — a real bug this project hit once, see `docs/IMPLEMENTATION_PLAN.md` §4a).
2. **Install deps** — `pip install` into a shared `devsecops-platform-pip-cache` Docker volume, reused by every later Python stage. Real caching (wheels aren't re-downloaded), not full dependency caching (packages are still re-installed into each ephemeral container).
3. **Lint & format** — `ruff check` + `ruff format --check`.
4. **Unit tests** — `pytest -m "not integration"`, JUnit XML published via the `junit` step.
5. **Integration tests** — `pytest -m integration` (multi-request workflow tests, distinct layer from unit tests — see `tests/test_integration.py`).
6. **Coverage** — `pytest --cov`, HTML report published via `publishHTML`.
7. **Quality gate: coverage threshold** — `pytest --cov-fail-under=${COVERAGE_THRESHOLD}` (parameter, default 80 — see `docs/SECURITY.md` §3 for why 80).
8. **Secret scan (gitleaks)** — git-history-aware (not `--no-git`), so gitignored local files never trip it — only secrets that actually reached a commit do. See `docs/FAILURE_SCENARIOS.md` Scenario 3 for what happens when one does, including the real "deleting it doesn't remove it from history" finding.
9. **Dependency vulnerability scan (trivy fs)** — scans `requirements.txt` directly, fails on HIGH/CRITICAL. See Scenario 4.
10. **Terraform fmt & validate** — `terraform fmt -check -recursive` across `terraform/`, then `terraform init -backend=false` + `terraform validate` inside `terraform/environments/local`.
11. **IaC security scan (checkov)** — scans the whole repo (`.`), soft-fail (reports, never blocks — see `docs/SECURITY.md` §3 for why). Picks up four separate frameworks in one pass: Dockerfile, Kubernetes, Helm (renders the chart correctly, not just scans raw `{{ }}` templates — a real open question going in, confirmed resolved in Phase 7), and Terraform.
12. **Build image** — `docker build`, tagged with both the commit-derived `IMAGE_TAG` and a `latest-local` tag (never relied on as the deployment reference — see `docs/SECURITY.md`'s accepted-findings table for why `latest`-style floating tags are a known, documented tradeoff here, not an oversight).
13. **Image vulnerability scan (trivy image)** — fails on CRITICAL by default (`MAX_IMAGE_SEVERITY` parameter); HIGH is reported but not blocking.
14. **SBOM generation** — CycloneDX format via `trivy image --format cyclonedx`, archived as a build artifact.
15. **Publish image** — gated on the `PUBLISH_IMAGE` boolean parameter (default `false`). If true, attempts `docker login ghcr.io` using a `ghcr-credentials` Jenkins credential; if that credential doesn't exist, catches the failure and logs the local-only fallback rather than crashing the build. Not yet exercised for real — see `docs/IMPLEMENTATION_PLAN.md` §4a.
16. **Build summary** — writes a markdown summary (commit, build number, image tag, gate parameters, result) and archives it.

## Triggering

No GitHub webhook — Jenkins runs on `localhost`, which GitHub's servers can't reach. The job polls every 5 minutes (`H/5 * * * *`). The alternative, used throughout this project's own development, is the REST API: `curl -u admin:<password> -X POST ".../buildWithParameters?PUBLISH_IMAGE=false"`.

## A real bug class this pipeline hit, twice

Plain top-level Groovy `def` variables (not `env.*`, not declared in the `environment{}` block) do not reliably survive from one declarative stage into a function called from a later stage, under Jenkins' CPS runtime. This caused two separate `MissingPropertyException` build failures (`JENKINS_CID`, then `PIP_CACHE_VOLUME`) before the pattern was understood and avoided — see `docs/IMPLEMENTATION_PLAN.md` §4a for the full story. The fix in both cases: resolve the value fresh in shell (`$(hostname)`) or inline it as a literal, rather than caching it in a shared Groovy variable.
