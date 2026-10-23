# Phase 4 — real drift/self-heal run (not simulated)

Preconditions: `devsecops-app-dev` Application already `Synced`/`Healthy`, deployed via Argo CD (not plain `helm install`), `syncPolicy.automated.selfHeal: true`.

```
$ kubectl -n devsecops-dev get deployment devsecops-app -o jsonpath='{.spec.replicas}'
1

$ kubectl -n devsecops-dev scale deployment devsecops-app --replicas=5
deployment.apps/devsecops-app scaled

$ kubectl -n devsecops-dev get deployment devsecops-app -o jsonpath='{.spec.replicas}'   # immediately after
5

$ kubectl -n argocd get application devsecops-app-dev -o jsonpath='{.status.sync.status}'   # immediately after
OutOfSync
```

Polled every 5s after that:

```
t+5s: replicas=1 sync=Synced   <- already healed
```

```
$ kubectl -n devsecops-dev get pods
NAME                             READY   STATUS        RESTARTS   AGE
devsecops-app-7566fcb5f8-chr8c   0/1     Terminating   0          12s
devsecops-app-7566fcb5f8-mvdw2   1/1     Running       0          74s
devsecops-app-7566fcb5f8-mvgdc   0/1     Terminating   0          12s
devsecops-app-7566fcb5f8-s9fc6   0/1     Terminating   0          12s
devsecops-app-7566fcb5f8-t75tr   0/1     Terminating   0          12s
```

Argo CD's selfHeal reverted a manual `kubectl scale` to 5 replicas back to the Git-declared 1 within 5 seconds — not on the periodic 3-minute reconciliation sweep, but near-instantly, because Argo CD's controller watches the resources it manages rather than only polling. The 4 extra pods were already `Terminating` by the time this was captured.

This is the real result of Kubernetes Drift scenario from the acceptance-scenario list (formal write-up with prerequisites/cleanup steps comes in Phase 9) — demonstrated here as part of verifying Phase 4 actually works, per the project's rule against claiming a stage works without running it.
