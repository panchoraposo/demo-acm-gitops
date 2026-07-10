# Runbook (high-impact): Git change → Argo Sync → ACM governance + app delivery (east/west)

This runbook demonstrates how to use **OpenShift GitOps/ArgoCD** as the Git-driven delivery mechanism on the hub, while **ACM Governance** enforces policies and reports compliance across managed clusters (**east** and **west**).

## Prerequisites

- `oc` contexts available: `acm`, `east`, `west`
- `east` and `west` are imported in ACM (ManagedCluster is `Available=True`)
- Console banners exist (local configuration on each cluster):
  - `East Cluster`
  - `West Cluster`

## 1) Bootstrap GitOps on the hub (one time)

Install OpenShift GitOps (operator + ArgoCD instance in the hub):

```bash
oc --context acm apply -k bootstrap/gitops-operator
```

Create the ArgoCD Applications that sync:
- `acm/` (governance-as-code)
- `gitops/` (ApplicationSets for app delivery)

```bash
oc --context acm apply -k bootstrap/argocd-app
```

Verify both apps exist:

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io acm-governance -o wide
oc --context acm -n openshift-gitops get applications.argoproj.io cluster-apps -o wide
```

## 2) Target clusters by name (east/west)

Label each managed cluster into its matching cluster set:

```bash
oc --context acm label managedcluster east cluster.open-cluster-management.io/clusterset=east --overwrite
oc --context acm label managedcluster west cluster.open-cluster-management.io/clusterset=west --overwrite
```

## 3) Baseline demo expectations

Current governance policies:

- `policy-baseline-east` (**inform**): should report **NonCompliant** until you flip it to enforce
- `policy-baseline-west` (**enforce**): should remediate and become **Compliant**
- `policy-app-east` / `policy-app-west` (**enforce**): creates namespaces (`frontend`, `backend`) with labels, quotas, limits and per-cluster NetworkPolicies
- `policy-no-latest` (**enforce**): blocks workloads using `:latest` (native `ValidatingAdmissionPolicy`)

Check in ACM (hub):

```bash
oc --context acm -n open-cluster-management-policies get policy -o wide
```

Validate effects in managed clusters:

```bash
oc --context west get ns demo-infra
oc --context west -n demo-infra get resourcequota,limitrange,networkpolicy,rolebinding

oc --context east get ns demo-infra || true
```

## 4) App delivery via GitOps (ArgoCD to east/west)

### 4.1 Register managed clusters in ArgoCD (one time)

ArgoCD runs on the hub. To deploy apps to managed clusters, register `east` and `west` as ArgoCD destinations:

```bash
chmod +x hack/register-argocd-clusters.sh
./hack/register-argocd-clusters.sh
```

Confirm ArgoCD cluster secrets exist on the hub:

```bash
oc --context acm -n openshift-gitops get secret -l argocd.argoproj.io/secret-type=cluster
```

### 4.2 Observe the ApplicationSet that deploys the demo app

The repo contains an `ApplicationSet` that generates one ArgoCD Application per cluster:

- `fb-east`
- `fb-west`

Check from the hub:

```bash
oc --context acm -n openshift-gitops get applicationsets.argoproj.io frontend-backend
oc --context acm -n openshift-gitops get applications.argoproj.io | rg -n '^fb-'
```

## 5) NetworkPolicy impact test (east vs west)

The same app is deployed, but policies make network behavior different:

- `east`: **frontend → backend allowed**
- `west`: **frontend → backend denied** (deny-ingress + allow-same-namespace)

Get the public URLs (OpenShift Routes):

```bash
echo -n "EAST URL: " && oc --context east -n frontend get route frontend -o jsonpath='https://{.spec.host}{"\n"}'
echo -n "WEST URL: " && oc --context west -n frontend get route frontend -o jsonpath='https://{.spec.host}{"\n"}'
```

Open both URLs in a browser:

- On **east** you should see `backend: reachable`
- On **west** you should see `backend: BLOCKED/UNREACHABLE`

Important note (Route reachability):

- Since `frontend` uses **default-deny ingress**, you must allow traffic from the OpenShift router namespace.
- This demo includes `NetworkPolicy/allow-from-openshift-ingress` in `frontend` to permit traffic from `openshift-ingress`.
- If the Route times out, confirm the policy exists:

```bash
oc --context east -n frontend get networkpolicy allow-from-openshift-ingress
oc --context west -n frontend get networkpolicy allow-from-openshift-ingress
```

Wait for pods:

```bash
oc --context east -n frontend rollout status deploy/frontend
oc --context east -n backend rollout status deploy/backend
oc --context west -n frontend rollout status deploy/frontend
oc --context west -n backend rollout status deploy/backend
```

Connectivity test using Python (no curl needed):

```bash
# EAST: should succeed
POD_EAST="$(oc --context east -n frontend get pod -l app.kubernetes.io/name=frontend -o jsonpath='{.items[0].metadata.name}')"
oc --context east -n frontend exec "$POD_EAST" -- \
  python -c 'import socket; s=socket.create_connection(("backend.backend.svc",8080),timeout=5); print("OK east: frontend -> backend"); s.close()'

# WEST: should fail (timeout or connection refused)
POD_WEST="$(oc --context west -n frontend get pod -l app.kubernetes.io/name=frontend -o jsonpath='{.items[0].metadata.name}')"
oc --context west -n frontend exec "$POD_WEST" -- \
  python -c 'import socket; socket.create_connection(("backend.backend.svc",8080),timeout=5); print("UNEXPECTED: west allowed")'
```

## 6) Policy guardrail: block images using :latest (show the failure, then fix)

### 6.1 Trigger a Git change that deploys a workload using `:latest` (expected to be denied)

Edit `gitops/applicationsets/frontend-backend.yaml` and change:

- `path: apps/frontend-backend/overlays/good`
to
- `path: apps/frontend-backend/overlays/bad-latest`

Commit + push:

```bash
git add gitops/applicationsets/frontend-backend.yaml
git commit -m "Demo: attempt to deploy :latest (should be denied)"
git push
```

Observe ArgoCD sync errors on `fb-east` / `fb-west` (Denied by admission):

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io fb-east fb-west -o wide
oc --context acm -n openshift-gitops get applications.argoproj.io fb-east -o yaml | rg -n 'Denied|disallow-latest-tag|message:'
```

### 6.2 Fix by switching back to pinned tags

Revert the path back to `overlays/good`, then commit + push:

```bash
git add gitops/applicationsets/frontend-backend.yaml
git commit -m "Fix: deploy pinned image tags"
git push
```

ArgoCD should converge back to `Synced`, and pods should run again.

## 7) The “ACM governance Git change” moment (flip east from inform → enforce)

Edit `acm/policies/baseline/policy-baseline-east.yaml`:

- change `spec.remediationAction: inform` to `enforce`
- (optional) also change each embedded `ConfigurationPolicy.spec.remediationAction` to `enforce`

Commit + push:

```bash
git add acm/policies/baseline/policy-baseline-east.yaml
git commit -m "Enforce baseline on east"
git push
```

## 5) Observe ArgoCD syncing from Git

Watch the ArgoCD app on the hub:

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io acm-governance -o wide
```

Expected:
- Sync status becomes `Synced`
- Health can optionally ignore ACM policy compliance (recommended for demos to keep the GitOps app green)

## 6) Observe ACM compliance/remediation in east

On the hub, you should see `policy-baseline-east` move toward `Compliant`:

```bash
oc --context acm -n open-cluster-management-policies get policy policy-baseline-east -o wide
```

On the east managed cluster, the baseline resources should now be created:

```bash
oc --context east get ns demo-infra
oc --context east -n demo-infra get resourcequota,limitrange,networkpolicy,rolebinding
```

## 8) Wrap-up (talk track)

- **Git is the source of truth**: a single commit changed governance intent.
- **ArgoCD delivered both** governance + apps from Git.
- **ACM enforced policy intent** across clusters (compliance + auto-remediation).
- **Guardrails prevented bad deployments** (blocked `:latest`).

