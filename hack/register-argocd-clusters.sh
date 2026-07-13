#!/usr/bin/env bash
set -euo pipefail

CTX_HUB="${CTX_HUB:-acm}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"

echo "Using contexts: hub=$CTX_HUB east=${CTX_EAST:-east} west=${CTX_WEST:-west}"
echo "Safety: this script only registers east/west into ArgoCD."

register() {
  local cluster_name="$1"
  local ctx="$2"

  echo "== Registering $cluster_name ($ctx) into ArgoCD =="

  # Create a dedicated service account in each managed cluster.
  oc --context "$ctx" -n kube-system get sa argocd-manager >/dev/null 2>&1 || \
    oc --context "$ctx" -n kube-system create sa argocd-manager >/dev/null

  # Grant cluster-admin for demo simplicity (tighten for production).
  oc --context "$ctx" get clusterrolebinding argocd-manager >/dev/null 2>&1 || \
    oc --context "$ctx" create clusterrolebinding argocd-manager \
      --clusterrole=cluster-admin \
      --serviceaccount=kube-system:argocd-manager >/dev/null

  # Create a long-lived token secret (works across multiple OpenShift versions).
  oc --context "$ctx" -n kube-system get secret argocd-manager-token >/dev/null 2>&1 || \
    oc --context "$ctx" -n kube-system apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
YAML

  # Extract token (do not print to stdout).
  token="$(oc --context "$ctx" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)"
  server="$(oc --context "$ctx" whoami --show-server)"
  ca_crt="$(oc --context "$ctx" -n kube-system get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')"
  ca_data="$(printf '%s' "$ca_crt" | base64 | tr -d '\n')"

  # Create/update ArgoCD cluster secret on the hub.
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  printf '%s' "$cluster_name" >"$tmpdir/name"
  printf '%s' "$server" >"$tmpdir/server"
  printf '%s' "$token" >"$tmpdir/token"

  oc --context "$CTX_HUB" -n "$ARGO_NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$cluster_name
  namespace: $ARGO_NS
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: "$cluster_name"
  server: "$server"
  config: |
    {"bearerToken":"$token","tlsClientConfig":{"insecure":false,"caData":"$ca_data"}}
YAML

  echo "OK: cluster secret created/updated: $ARGO_NS/cluster-$cluster_name"
}

register east "${CTX_EAST:-east}"
register west "${CTX_WEST:-west}"

echo
echo "Next: verify ArgoCD sees clusters:"
echo "oc --context $CTX_HUB -n $ARGO_NS get secret -l argocd.argoproj.io/secret-type=cluster"

