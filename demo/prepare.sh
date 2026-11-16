#!/usr/bin/env bash
# Checks that the platform is ready for a PRVue demo. Read-only: it never changes or deletes anything.
# Exit code 0 = ready, 1 = at least one FAIL. See demo/DEMO_SCRIPT.md for the reset procedure.
set -u

REPO=sana-Benz/MicroPizzeria
FAILS=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }

echo "Cluster"
ctx=$(kubectl config current-context 2>/dev/null)
[ "$ctx" = "kind-previews" ] && pass "kubectl context: $ctx" || fail "kubectl context is '$ctx', expected kind-previews"
kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready " && pass "node Ready" || fail "node not Ready (is Docker running? terraform apply?)"

echo "Traefik"
kubectl rollout status -n traefik deploy/traefik --timeout=5s >/dev/null 2>&1 && pass "traefik running" || fail "traefik not ready"
kubectl get deploy -n traefik traefik -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q "ingressendpoint.ip=127.0.0.1" \
  && pass "Ingress status published as 127.0.0.1 (needed for Healthy)" || fail "Traefik does not publish 127.0.0.1 (values/traefik.yaml not applied?)"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost/)
[ "$code" = "404" ] && pass "http://localhost answers 404 (Traefik, no route)" || fail "http://localhost answered '$code', expected 404"
ip=$(getent hosts check.127-0-0-1.nip.io | awk '{print $1}')
[ "$ip" = "127.0.0.1" ] && pass "nip.io resolves to 127.0.0.1" || fail "nip.io resolves to '$ip' (no Internet / DNS?)"

echo "Argo CD"
notready=$(kubectl get deploy,statefulset -n argocd --no-headers 2>/dev/null | awk '{split($2,r,"/"); if (r[1]!=r[2]) print $1}')
[ -z "$notready" ] && pass "all Argo CD components ready" || fail "not ready: $notready"
kubectl get appproject -n argocd previews >/dev/null 2>&1 && pass "AppProject previews exists" || fail "AppProject previews missing (kubectl apply -f platform/argocd/appproject.yaml)"
if kubectl get applicationset -n argocd micropizzeria-previews >/dev/null 2>&1; then
  err=$(kubectl get applicationset -n argocd micropizzeria-previews -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].status}')
  [ "$err" = "False" ] && pass "ApplicationSet micropizzeria-previews, no error" || fail "ApplicationSet reports an error: kubectl describe applicationset -n argocd micropizzeria-previews"
else
  fail "ApplicationSet missing (kubectl apply -f platform/argocd/applicationset.yaml)"
fi
if kubectl get secret github-token -n argocd >/dev/null 2>&1; then   # never prints the value
  pass "Secret github-token exists"
  kubectl get secret github-token -n argocd -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}' | grep -q scm-creds \
    && pass "github-token has the scm-creds label" || warn "github-token has no scm-creds label (only required in strict mode)"
else
  fail "Secret github-token missing (see GUIDE, step 4)"
fi

echo "Starting from zero previews"
managed=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.spec.destination.namespace}{"\n"}{end}' 2>/dev/null)
found=0
for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^pr-'); do
  found=1
  if echo "$managed" | grep -qx "$ns"; then
    warn "$ns is an open preview (managed by Argo CD): close its PR to remove it"
  else
    fail "$ns is NOT managed by Argo CD (leftover manual test): kubectl delete namespace $ns"
  fi
done
[ $found -eq 0 ] && pass "no pr-* namespace"
if command -v gh >/dev/null 2>&1; then
  open=$(gh pr list -R "$REPO" --label preview-ready --state open --json number --jq '[.[].number] | join(" ")' 2>/dev/null)
  [ -z "$open" ] && pass "no open PR labeled preview-ready" || warn "open PRs with preview-ready: $open (they will get a preview)"
else
  warn "gh not installed: open PRs not checked"
fi

echo "Laptop"
avail=$(free -m | awk '/^Mem:/ {print $7}')
[ "$avail" -ge 3000 ] && pass "available RAM: ${avail} MiB (2 previews ≈ 2.6 GiB requested)" || warn "available RAM: ${avail} MiB, less than 3 GiB: close other apps"

echo
if [ $FAILS -eq 0 ]; then echo "Ready for the demo."; else echo "$FAILS check(s) failed: see demo/DEMO_SCRIPT.md, section Reset."; fi
[ $FAILS -eq 0 ]
