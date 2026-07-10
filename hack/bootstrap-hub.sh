#!/usr/bin/env bash
set -euo pipefail

CTX="${CTX:-acm}"

echo "[1/4] Installing OpenShift GitOps operator via ACM OperatorPolicy (hub only)..."
oc --context "$CTX" apply -k bootstrap/gitops-operator

echo "[2/4] Waiting for OpenShift GitOps operator to create namespaces/CRDs..."
until oc --context "$CTX" get ns openshift-gitops >/dev/null 2>&1; do
  sleep 5
done

until oc --context "$CTX" get crd applications.argoproj.io >/dev/null 2>&1; do
  sleep 5
done

echo "[3/4] Creating ArgoCD Application (sync acm/)..."
oc --context "$CTX" apply -k bootstrap/argocd-app

echo "[4/4] Done. You can now watch sync in ArgoCD (openshift-gitops)."

