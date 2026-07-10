# Runbook: Git change → Argo Sync → ACM governance (east/west)

This runbook demonstrates **ACM Governance-as-Code** delivered via **OpenShift GitOps/ArgoCD** on the hub cluster.

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

Create the ArgoCD `Application` that syncs `acm/` from Git:

```bash
oc --context acm apply -k bootstrap/argocd-app
```

Verify the app exists:

```bash
oc --context acm -n openshift-gitops get applications.argoproj.io acm-governance -o wide
```

## 2) Target clusters by name (east/west)

Label each managed cluster into its matching cluster set:

```bash
oc --context acm label managedcluster east cluster.open-cluster-management.io/clusterset=east --overwrite
oc --context acm label managedcluster west cluster.open-cluster-management.io/clusterset=west --overwrite
```

## 3) Baseline demo expectations

Current baseline policies:

- `policy-baseline-east` (**inform**): should report **NonCompliant** until you flip it to enforce
- `policy-baseline-west` (**enforce**): should remediate and become **Compliant**

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

## 4) The “Git change” moment (flip east from inform → enforce)

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
- Health may reflect policy compliance (it can show `Degraded` while a policy is `NonCompliant`)

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

## 7) Wrap-up (talk track)

- **Git is the source of truth**: a single commit changed governance intent.
- **ArgoCD reconciled the hub state**: `Policy`/`Placement` objects are delivered from Git.
- **ACM enforced across clusters**: `west` auto-remediated; `east` reported until you flipped it.

