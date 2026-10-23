# Contributing

This started as a solo portfolio project, but the workflow below is the real one used throughout its development (every commit in this repo's history follows it), not a template pasted in at the end.

## Branch strategy

- `main` is always deployable — every commit on it passed the full Jenkins pipeline.
- Feature work happens on a branch, merged via pull request. Branch protection on `main` (require the pipeline to pass, require review) is recommended once more than one person is working on this.
- `devsecops-app-dev` auto-syncs from `main`; `devsecops-app-staging` requires an explicit `argocd app sync` — see [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) §4c for why that's the deliberate promotion gate.

## Commit conventions

Commit messages in this repo describe *why*, not just *what* — especially for a fix, the root cause and how it was confirmed (not guessed). See the git log for the pattern; it's been consistent since the first commit.

## Before opening a PR

```bash
make test        # unit + integration tests, coverage gate
make lint         # ruff
helm lint helm/devsecops-app -f helm/devsecops-app/values-dev.yaml
terraform -chdir=terraform fmt -check -recursive
./scripts/validate.sh   # runs all of the above plus live cluster checks if you have a context active
```

All of the above also run in CI (`Jenkinsfile`) — running them locally first just gets you a faster feedback loop, not a different bar.

## Release tagging

This project doesn't currently use semantic version tags (no external consumers yet), but the convention if/when needed: `vMAJOR.MINOR.PATCH`, with the image tag format already in place (`<build-number>-<short-sha>`) giving full build-to-commit traceability without needing a separate tag scheme.

## Security issues

If you find a real security issue in this project (as opposed to one of the deliberately-accepted findings catalogued in [docs/SECURITY.md](docs/SECURITY.md)), please open an issue describing it rather than a PR with the fix, so it can be reviewed before any exploit detail is made public.
