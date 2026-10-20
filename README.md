# gitops-rollouts

[![CI](https://github.com/nivedmahendran/gitops-rollouts/actions/workflows/ci.yml/badge.svg)](https://github.com/nivedmahendran/gitops-rollouts/actions/workflows/ci.yml)
[![Argo Rollouts](https://img.shields.io/badge/Argo%20Rollouts-canary-EF7B4D?logo=argo)](https://argoproj.github.io/rollouts/)
[![K3s](https://img.shields.io/badge/K3s-v1.35-FFC61C?logo=kubernetes)](https://k3s.io)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Progressive delivery on Kubernetes with **Argo Rollouts**: a canary release that
shifts real traffic in measured steps and **rolls itself back automatically**
when Prometheus says the new version is unhealthy.

## The problem this solves

A Kubernetes `Deployment` rolling update replaces pods as fast as it can. You
get no control over how much live traffic reaches the new version, and if the
release is broken, nothing stops it — you find out from users.

A `Rollout` with a canary strategy lets you:

1. Send a **small percentage of real traffic** to the new version
2. **Pause** to let observed behaviour accumulate
3. **Query Prometheus** and let the result decide
4. **Promote or abort** — automatically, without a human awake

## The release it performs

```
  setWeight: 20%
        │
        ▼
    pause 2m          ← real traffic accumulates; cold-start noise averages out
        │
        ▼
  analysis: success-rate >= 0.95   ← queries Prometheus
        │  pass                              │  fail
        ▼                                    ▼
  setWeight: 50%                        ABORT + revert
        │                               to last good ReplicaSet
        ▼
    pause 5m          ← confirm the result holds under higher load
        │
        ▼
  analysis: success-rate >= 0.95
        │
        ▼
   setWeight: 100%    ← canary ReplicaSet becomes stable
```

## Why the details matter

**`setWeight`, not `setCanaryScale`.** With only four replicas, scaling the
canary by percentage is too coarse to be a meaningful signal (25% of 4 pods is
one pod). Shifting *traffic* weight gives fine-grained control regardless of
replica count.

**Wall-clock pauses, not just analysis.** An immediate check only sees
cold-start behaviour. Pauses let the canary serve real requests before being
judged.

**Traefik as the traffic router.** Traefik is already the K3s default ingress,
so this reuses it rather than introducing a service mesh. The `Ingress` points
at a `TraefikService` (not a plain Service) and the rollout controller edits the
weights on that object as it progresses.

**`ignoreDifferences` in the ArgoCD Application.** The Rollout controller mutates
the `TraefikService` weights during a promotion. Without telling ArgoCD to ignore
that field, `selfHeal` fights the controller and reverts a canary mid-flight —
a genuinely confusing bug to diagnose.

**`ServiceMonitor` is a hard dependency.** The analysis queries
`http_requests_total{job="demo-app"}`. If Prometheus is not scraping the pods, the
query returns no data, and a no-data result **fails** the analysis, aborting every
release. The demo app therefore explicitly exports that metric.

## Layout

```
gitops-rollouts/
├── rollout/                      # everything ArgoCD syncs
│   ├── kustomization.yml
│   ├── namespace.yml
│   ├── rollout.yml               # the canary strategy
│   ├── services.yml              # stable + canary Services, and the TraefikService
│   ├── analysis-template.yml     # the Prometheus gate
│   ├── servicemonitor.yml        # makes the metric exist
│   └── ingress.yml               # points at the weighted service
├── argocd/
│   └── application.yml           # the Application CR
├── app/                          # demo service + Dockerfile
├── ansible/
│   └── rollouts.yml              # installs the Argo Rollouts controller
├── scripts/
│   └── demo-rollout.sh           # demonstrates promotion AND rollback
├── .github/workflows/ci.yml
└── .yamllint
```

## Install

Argo Rollouts is a **controller**, not just a CRD. Applying a Rollout manifest
without the controller running gives you an object the API server accepts and
nothing ever reconciles — the app silently never appears.

```bash
ansible-playbook -i inventory.ini ansible/rollouts.yml
```

Then let ArgoCD take over:

```bash
k3s kubectl apply -f argocd/application.yml
```

Prerequisites: a K3s cluster, Traefik (ships with K3s), and
kube-prometheus-stack for the Prometheus Operator CRDs the `ServiceMonitor` needs.

## Seeing it work

```bash
./scripts/demo-rollout.sh
```

The script releases a healthy version and watches it promote through 20% → 50%
→ 100%. It then releases a deliberately broken version and shows the analysis
failing and the rollout reverting on its own.

Manual control, which is what you actually use during an incident:

```bash
kubectl argo rollouts get rollout demo-app -n demo --watch
kubectl argo rollouts promote demo-app -n demo     # move past a pause
kubectl argo rollouts abort demo-app -n demo       # stop now
kubectl argo rollouts undo demo-app -n demo        # revert to last good
```

## CI

Every push:

1. **yamllint** — manifest formatting
2. **ansible-lint** — playbook at the `production` profile
3. **kubeconform + kustomize build** — manifests validate and render
4. **Trivy** — misconfiguration scan on manifests and Dockerfile
5. **docker build + smoke test** — image starts, `/healthz` responds, and
   `/metrics` exports `http_requests_total`

## Verified locally

| Check | Result |
|---|---|
| `yamllint` | clean, 0 warnings |
| `ansible-lint` (production profile) | 0 failures, 0 warnings |
| `kustomize build` | 8 objects render |
| Rollout spec vs Argo Rollouts CRD | all keys valid |
| Canary steps vs CRD schema | 7/7 valid |
| `trafficRouting.traefik` vs CRD | valid |
| AnalysisTemplate vs CRD | valid |
| PromQL query | parses |
| `python -m py_compile app/main.py` | clean |

## License

MIT — see [LICENSE](LICENSE).
