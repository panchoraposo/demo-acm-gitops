# Runbook: validate demo + execute step-by-step (GitOps → ACM governance → east/west behavior)

This runbook is the **demo script** and also the **validation checklist**. It shows how:

- **GitOps (ArgoCD on the hub)** delivers desired state from Git
- **ACM Governance** enforces policies, reports compliance, and remediates (where enabled)
- **east vs west** behave differently due to policy-driven NetworkPolicies and guardrails

## Prerequisites

- `oc` contexts available: `acm`, `east`, `west`
- Don’t use any other cluster contexts during the demo.
- `east` and `west` are imported into ACM and `Available=True`
- Console banners are configured locally (not via ACM Policies):
  - `East Cluster`
  - `West Cluster`

## 0) Safety pre-flight

```bash
oc --context acm whoami --show-server
oc --context east whoami --show-server
oc --context west whoami --show-server
```

## 1) Validate GitOps on the hub (ArgoCD)

ArgoCD runs on the **hub** (`acm`) and syncs this repo.

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io \
  acm-governance cluster-apps fb-east fb-west -o wide

oc --context acm -n openshift-gitops get applicationsets.argoproj.io frontend-backend
```

Expected:
- All apps are `Synced` and `Healthy`

## 2) Validate ACM governance status (hub)

```bash
oc --context acm -n open-cluster-management-policies get policy -o wide
```

Expected (key talking points):
- `policy-baseline-east` is **inform + NonCompliant** (it reports drift; it does not remediate)
- `policy-baseline-west` is **enforce + Compliant** (it remediates)
- `policy-app-east` and `policy-app-west` are **Compliant**
- `policy-no-latest` is **Compliant** (guardrail active)

## 3) Validate namespace governance (east/west)

These namespaces are delivered by policy:

```bash
for ctx in east west; do
  echo "=== $ctx ==="
  oc --context $ctx get ns frontend backend -o jsonpath='{range .items[*]}{.metadata.name}{" labels="}{.metadata.labels}{"\n"}{end}'
  oc --context $ctx -n frontend get resourcequota,limitrange
  oc --context $ctx -n backend get resourcequota,limitrange
done
```

Fish equivalent:

```fish
for ctx in east west
  echo "=== $ctx ==="
  oc --context $ctx get ns frontend backend -o jsonpath='{range .items[*]}{.metadata.name}{" labels="}{.metadata.labels}{"\n"}{end}'
  oc --context $ctx -n frontend get resourcequota,limitrange
  oc --context $ctx -n backend get resourcequota,limitrange
end
```

## 4) Demo moment: NetworkPolicy impact (east vs west)

The app is the same, but policies make behavior different:

- **east**: frontend → backend **allowed**
- **west**: frontend → backend **blocked**

### 4.1 Open the frontends

```bash
echo -n "EAST URL: " && oc --context east -n frontend get route frontend -o jsonpath='https://{.spec.host}{"\n"}'
echo -n "WEST URL: " && oc --context west -n frontend get route frontend -o jsonpath='https://{.spec.host}{"\n"}'
```

Expected:
- Before clicking **Ping**, the UI does **not** show backend status.
- After clicking **Ping**:
  - **east** shows a **green selected indicator** and the **backend pod name**
  - **west** shows a **red selected indicator** and **blocked**

### 4.2 Prove scaling changes the backend pod name (east)

```bash
oc --context east -n backend scale deploy/backend --replicas=5
oc --context east -n backend rollout status deploy/backend --timeout=180s
```

Now click **Ping** multiple times in the **east** UI.

Expected:
- The backend pod name **changes between clicks** (random backend pod selection)

Scale back:

```bash
oc --context east -n backend scale deploy/backend --replicas=1
oc --context east -n backend rollout status deploy/backend --timeout=180s
```

### 4.3 Optional CLI verification (no browser)

```bash
EAST_HOST=$(oc --context east -n frontend get route frontend -o jsonpath='{.spec.host}')
WEST_HOST=$(oc --context west -n frontend get route frontend -o jsonpath='{.spec.host}')

curl -k -s --max-time 10 "https://$EAST_HOST/api/backendinfo" | python3 -c 'import sys,json; print(json.load(sys.stdin)["hostname"])'
curl -k -s --max-time 10 "https://$WEST_HOST/api/backendinfo" | python3 -c 'import sys; print(sys.stdin.read().strip())'
```

## 5) Validate NetworkPolicies (east allows, west blocks)

```bash
for ctx in east west; do
  echo "=== $ctx netpols ==="
  oc --context $ctx -n frontend get netpol
  oc --context $ctx -n backend get netpol
done
```

Fish equivalent:

```fish
for ctx in east west
  echo "=== $ctx netpols ==="
  oc --context $ctx -n frontend get netpol
  oc --context $ctx -n backend get netpol
end
```

Connectivity check from an existing container (no new pods needed):

```bash
for ctx in east west; do
  echo "=== $ctx frontend -> backend ==="
  POD="$(oc --context $ctx -n frontend get pod -l app.kubernetes.io/name=frontend -o jsonpath='{.items[0].metadata.name}')"
  if host="$(oc --context $ctx -n frontend exec "$POD" -c backendinfo -- python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen(\"http://backend.backend.svc:9898/api/info\",timeout=2))[\"hostname\"])' 2>/dev/null)"; then
    echo "OK backend=$host"
  else
    echo "FAIL (expected on west)"
  fi
done
```

Fish equivalent:

```fish
for ctx in east west
  echo "=== $ctx frontend -> backend ==="
  set POD (oc --context $ctx -n frontend get pod -l app.kubernetes.io/name=frontend -o jsonpath='{.items[0].metadata.name}')
  set host (oc --context $ctx -n frontend exec $POD -c backendinfo -- python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen("http://backend.backend.svc:9898/api/info",timeout=2))["hostname"])' 2>/dev/null)
  if test $status -eq 0
    echo "OK backend=$host"
  else
    echo "FAIL (expected on west)"
  end
end
```

Expected:
- **east** prints `OK`
- **west** prints `FAIL ... timed out`

## 6) Guardrail demos (ACM governance)

### 6.1 Exceed the desired footprint and watch ACM remediate (replicas)

This is the “ACM keeps the cluster safe” moment: a Git change tries to scale the **frontend** to `replicas: 10`, but ACM enforces `replicas: 1`.

**Important:** ArgoCD and ACM are both reconcilers. For this specific demo step, we temporarily disable ArgoCD self-heal to avoid a tug-of-war.

1) Edit `gitops/applicationsets/frontend-backend.yaml`:

- Set both elements to use `apps/frontend-backend/overlays/bad-replicas`
- Temporarily disable self-heal:
  - `syncPolicy.automated.selfHeal: false`

Commit + push:

```bash
git add gitops/applicationsets/frontend-backend.yaml
git commit -m "Demo: try to scale frontend beyond policy"
git push
```

Watch:

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io fb-east fb-west -o wide
oc --context acm -n open-cluster-management-policies get policy policy-replica-guard -o wide

# ACM enforces replicas back to 1 (even though Git asked for 10)
oc --context east -n frontend get deploy frontend -o jsonpath='{.spec.replicas}{"\n"}'
oc --context west -n frontend get deploy frontend -o jsonpath='{.spec.replicas}{"\n"}'
```

Revert the ApplicationSet back to `overlays/east` and `overlays/west` and restore `selfHeal: true`, then commit + push:

```bash
git add gitops/applicationsets/frontend-backend.yaml
git commit -m "Fix: restore normal app overlays"
git push
```

### 6.2 Block `:latest`

#### 6.2.1 Git change (recommended for the demo narrative)

Edit `gitops/applicationsets/frontend-backend.yaml` and change both cluster elements:

- `path: apps/frontend-backend/overlays/east` → `path: apps/frontend-backend/overlays/bad-latest`
- `path: apps/frontend-backend/overlays/west` → `path: apps/frontend-backend/overlays/bad-latest`

Commit + push:

```bash
git add gitops/applicationsets/frontend-backend.yaml
git commit -m "Demo: attempt to deploy :latest (should be denied)"
git push
```

Expected:
- Argo apps `fb-east`/`fb-west` show sync errors
- The admission policy `disallow-latest-tag` denies the rollout

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io fb-east fb-west -o wide
```

#### 6.2.2 Fix (switch back to pinned tags)

Revert paths back to `overlays/east` and `overlays/west`, then commit + push:

```bash
git add gitops/applicationsets/frontend-backend.yaml
git commit -m "Fix: deploy pinned image tags"
git push
```

## 7) Governance remediation demo: flip east baseline from inform → enforce

Today:
- west baseline is enforced and already remediated
- east baseline is inform-only and intentionally NonCompliant

### 7.1 Create a new project and watch policy drift (east)

This is the “new namespace” moment: you create a brand new project on **east** and ACM immediately evaluates it against the baseline policy.

```bash
# Create the project/namespace (new)
oc --context east create ns demo-infra || true

# Policy still reports drift (inform-only, so it does not remediate)
oc --context acm -n open-cluster-management-policies get policy policy-baseline-east -o wide
oc --context acm -n east get policy open-cluster-management-policies.policy-baseline-east -o yaml | rg -n \"NonCompliant|not found\"
```

Fish equivalent:

```fish
oc --context east create ns demo-infra; or true

oc --context acm -n open-cluster-management-policies get policy policy-baseline-east -o wide
oc --context acm -n east get policy open-cluster-management-policies.policy-baseline-east -o yaml | rg -n \"NonCompliant|not found\"
```

Show the difference:

```bash
oc --context west get ns demo-infra
oc --context east get ns demo-infra || true
oc --context acm -n open-cluster-management-policies get policy policy-baseline-east policy-baseline-west -o wide
```

Now flip east to enforce:

1) Edit `acm/policies/baseline/policy-baseline-east.yaml`
2) Change `spec.remediationAction: inform` → `enforce`
3) (Optional) also change each embedded `ConfigurationPolicy.spec.remediationAction` to `enforce`

Commit + push:

```bash
git add acm/policies/baseline/policy-baseline-east.yaml
git commit -m "Enforce baseline on east"
git push
```

Watch GitOps apply it:

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io acm-governance -o wide
```

Then confirm remediation happened:

```bash
oc --context acm -n open-cluster-management-policies get policy policy-baseline-east -o wide
oc --context east get ns demo-infra
oc --context east -n demo-infra get resourcequota,limitrange,networkpolicy,rolebinding
```

## 8) Wrap-up (talk track)

- **Git is the source of truth**: policies and apps change via commits
- **ArgoCD syncs from Git** (hub GitOps)
- **ACM shows compliance and remediates** where enabled
- **east/west differ by policy**, not by manual config

