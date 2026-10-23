# Phase 6 — real alert fire → deliver → resolve (not simulated)

Trigger: `helm/devsecops-app/values-dev.yaml` `replicaCount` set to `0`, committed, pushed, and synced via Argo CD — a real GitOps-declared change, not a manual `kubectl scale` (which selfHeal would have reverted instantly).

## First attempt — found a real bug

Original rule: `sum(up{job="kubernetes-pods", app="devsecops-app"}) == 0`

```
t+50s: AppUnavailable=pending
t+55s: AppUnavailable=pending
...then it silently disappeared from /api/v1/alerts entirely.
```

Direct query once the target was fully gone from service discovery:

```
$ curl .../api/v1/query?query=sum(up{job="kubernetes-pods",app="devsecops-app"})==0
{"result":[]}          <- empty vector never matches "== 0"

$ curl .../api/v1/query?query=absent(up{job="kubernetes-pods",app="devsecops-app"})
{"result":[{"value":[...,"1"]}]}   <- absent() correctly sees it
```

`sum(...) == 0` only catches a target present in service discovery but failing to scrape — the much more common case (pods actually gone, scaled to 0, crashed) produces an empty vector that never satisfies `== 0`, so the alert silently stopped firing instead of staying firing. Fixed to `absent(up{job="kubernetes-pods", app="devsecops-app"} == 1)`, which correctly covers both "no series at all" and "series present but not 1".

## Second attempt — fixed rule, full pipeline verified

```
t+50s: AppUnavailable=pending
t+55s: AppUnavailable=firing      <- stayed firing this time
```

Alertmanager (`kubectl -n monitoring logs deploy/alertmanager`):

```
level=warn ... msg="Notify attempt failed, will retry later" attempts=1 err="... connect: connection refused"
level=error ... msg="Notify for alerts failed" num_alerts=1 err="... notify retry canceled after 10 attempts: ... connection refused"
level=warn ... msg="Notify attempt failed, will retry later" attempts=1 err="... connection refused"
level=info ... msg="Notify success" attempts=8 duration=384.644774ms
```

The first delivery attempts genuinely failed — because the webhook receiver *is* `devsecops-app` itself, which was at 0 replicas for this exact test. Reverting `replicaCount` back to 2 and letting Argo CD resync brought the app back; Alertmanager's own retry logic then delivered successfully on attempt 8.

## A second real finding: in-memory alert storage is per-pod

With 2 replicas, the load-balanced webhook POST landed on only one of them:

```
$ kubectl exec into pod 9fxtd -> GET /webhooks/alerts -> []            (0 alerts)
$ kubectl exec into pod wff6n -> GET /webhooks/alerts -> [2 entries]   (firing + resolved)
```

Both the `firing` and the `resolved` notification (Alertmanager re-sent once Prometheus confirmed the target was back `up`) were captured, with the real Alertmanager webhook payload shape intact. This is a genuine limitation of the in-memory `AlertStore` (see `app/routers/webhooks.py`) with more than one replica — documented, not silently papered over. A real fix would share state (e.g. Redis) or accept that this endpoint is a demo/debugging aid, not a source of truth for alert history.
