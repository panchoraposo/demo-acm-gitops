# demo-acm-gitops

Demo repository to show the value of using **Red Hat Advanced Cluster Management (ACM)** together with **GitOps (OpenShift GitOps/ArgoCD)**:

- GitOps applies the desired state (declarative) from Git to the hub.
- ACM enforces and reports compliance (Governance) on managed clusters through `Policy`/`Placement`.

## Demo goal

With two AWS managed clusters (for example `east` and `west`):

- `east`: policies run in **inform** mode (report only).
- `west`: policies run in **enforce** mode (auto-remediate).

The infrastructure team should be able to see:

- versioned changes in Git (PR → merge),
- continuous reconciliation (ArgoCD),
- centralized compliance reporting (ACM Governance),
- consistent remediation by environment.

## Prerequisites

- Logged into the hub using the `acm` context.
- ACM Governance enabled on the hub.
- Two managed clusters imported (commonly `east` and `west` in this environment).

## Bootstrap (one time)

1) Install OpenShift GitOps (on the hub) using an ACM `OperatorPolicy`:

```bash
oc --context acm apply -k bootstrap/gitops-operator
```

2) Wait until the `openshift-gitops` namespace exists and the operator-managed ArgoCD instance is ready.

3) Create the ArgoCD `Application` that syncs this repo (Governance-as-Code):

```bash
oc --context acm apply -k bootstrap/argocd-app
```

## Set targeting (east/west)

Assign clusters to cluster sets:

```bash
oc --context acm label managedcluster east cluster.open-cluster-management.io/clusterset=east --overwrite
oc --context acm label managedcluster west cluster.open-cluster-management.io/clusterset=west --overwrite
```

## What gets synced from Git

ArgoCD syncs `acm/`, which creates:

- `ManagedClusterSet`: `east`, `west`
- `ManagedClusterSetBinding` in `open-cluster-management-policies`
- `Placement` resources for targeting
- Policies:
  - `policy-baseline-east` (inform)
  - `policy-baseline-west` (enforce)

## Suggested demo script (10–15 min)

1) Show the repo path `acm/policies/baseline/`.
2) In the ArgoCD UI, show the app is **Synced/Healthy**.
3) In ACM → Governance, show compliance by cluster (east vs west).
4) Make a small Git change:
   - switch `policy-baseline-east` to `enforce` (or change a required object)
5) ArgoCD reconciles and ACM reflects the new compliance/remediation.

## Quick troubleshooting

- If clusters are not selected by a `Placement`, verify:
  - `cluster.open-cluster-management.io/clusterset` label on each `ManagedCluster`
  - `ManagedClusterSetBinding` exists in `open-cluster-management-policies`

