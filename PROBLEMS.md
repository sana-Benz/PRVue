# PRVue: problems, decisions and concepts

A technical learning journal: what went wrong, how it was investigated, what was decided and why.

How to read this file:
- **Confirmed** means checked with a command or a test, with the output shown.
- **Hypothesis** means a likely explanation that was not proven.
- **Not tested yet** means planned, and not verified.

The day-by-day log is in [AVANCEMENT.md](AVANCEMENT.md) (French). This file is organized by topic.

## Contents

**Problems**
- [P1. Traefik install stuck: Service in `LoadBalancer`, `EXTERNAL-IP <pending>`](#p1-traefik-install-stuck-service-in-loadbalancer-external-ip-pending)
- [P2. ArgoCD was never installed](#p2-argocd-was-never-installed)
- [P3. Preview URLs did not resolve to the laptop (nip.io)](#p3-preview-urls-did-not-resolve-to-the-laptop-nipio)
- [P4. One HTTP 500 right after a MySQL restart](#p4-one-http-500-right-after-a-mysql-restart)
- [P5. False alarm: server-side dry run says "namespace not found"](#p5-false-alarm-server-side-dry-run-says-namespace-not-found)
- [P6. Brief 503 and "middleware does not exist" right after a deployment](#p6-brief-503-and-middleware-does-not-exist-right-after-a-deployment)
- [P7. Previews would never be "Healthy": empty Ingress status](#p7-previews-would-never-be-healthy-empty-ingress-status)

**Decisions**
- [D1. Two repositories: MicroPizzeria (app) and PRVue (platform)](#d1-two-repositories-micropizzeria-app-and-prvue-platform)
- [D2. Kubernetes manifests live in MicroPizzeria, reused in place](#d2-kubernetes-manifests-live-in-micropizzeria-reused-in-place)
- [D3. Kustomize to adapt the manifests per pull request](#d3-kustomize-to-adapt-the-manifests-per-pull-request)
- [D4. Dynamic namespaces: the namespace is the only input](#d4-dynamic-namespaces-the-namespace-is-the-only-input)
- [D5. Traefik instead of Nginx Ingress](#d5-traefik-instead-of-nginx-ingress)
- [D6. nip.io for local preview URLs](#d6-nipio-for-local-preview-urls)
- [D7. Database isolation: two MySQL instances per preview](#d7-database-isolation-two-mysql-instances-per-preview)
- [D8. Throwaway secrets for previews](#d8-throwaway-secrets-for-previews)
- [D9. `imagePullPolicy: IfNotPresent` and unique image tags](#d9-imagepullpolicy-ifnotpresent-and-unique-image-tags)
- [D10. Three images, GHCR, and the tag contract](#d10-three-images-ghcr-and-the-tag-contract)
- [D11. The `preview-ready` label as the deployment gate](#d11-the-preview-ready-label-as-the-deployment-gate)
- [D12. Public GHCR packages](#d12-public-ghcr-packages)
- [D13. Deleting the namespace when a PR closes (Phase 5, decided, not tested)](#d13-deleting-the-namespace-when-a-pr-closes-phase-5-decided-not-tested)
- [D14. A dedicated AppProject as the real namespace safeguard](#d14-a-dedicated-appproject-as-the-real-namespace-safeguard)
- [D15. The `previews` AppProject: an allow list of kinds](#d15-the-previews-appproject-an-allow-list-of-kinds)
- [D16. The ApplicationSet, and parity with the Phase 3 manual deploy](#d16-the-applicationset-and-parity-with-the-phase-3-manual-deploy)
- [D17. The GitHub token: created with kubectl, not Terraform](#d17-the-github-token-created-with-kubectl-not-terraform)

**Concepts**
- [C1. DNS and hostname resolution](#c1-dns-and-hostname-resolution)
- [C2. Kubernetes namespaces](#c2-kubernetes-namespaces)
- [C3. Deployments and Services](#c3-deployments-and-services)
- [C4. Ingress, Ingress controller and Traefik](#c4-ingress-ingress-controller-and-traefik)
- [C5. Kustomize](#c5-kustomize)
- [C6. PersistentVolumes and PersistentVolumeClaims](#c6-persistentvolumes-and-persistentvolumeclaims)
- [C7. Docker image tags](#c7-docker-image-tags)
- [C8. GitOps](#c8-gitops)
- [C9. ArgoCD ApplicationSets](#c9-argocd-applicationsets)
- [C10. `pull_request` events: merge commit vs head commit](#c10-pull_request-events-merge-commit-vs-head-commit)
- [C11. Rolling updates](#c11-rolling-updates)

---

# Problems

## P1. Traefik install stuck: Service in `LoadBalancer`, `EXTERNAL-IP <pending>`

*2026-10-03, step 1 (Terraform foundation). Full story in AVANCEMENT.md, section 7.*

**Symptoms**
- `terraform apply` failed on `helm_release.traefik` with `context deadline exceeded`.
- `kubectl get all -n traefik` showed the Service as `LoadBalancer` with `EXTERNAL-IP <pending>`.

**Investigation**
1. First guess: slow image downloads. Adding more time changed nothing, so the guess was wrong.
2. Looking at what Kubernetes had **actually** created showed the wrong Service type.

**Root cause (confirmed)**
In Traefik chart 41.x, the option is `service.spec.type`, not `service.type`. Helm **silently ignored** the misplaced option and kept the default, `LoadBalancer`. kind has no cloud provider to hand out an external IP, so Helm waited forever for one.

**Solution**
Set `service.spec.type: NodePort` in [values/traefik.yaml](platform/terraform/values/traefik.yaml). Then `helm uninstall traefik -n traefik`: the failed release wasn't in the Terraform state and was blocking the name. Then `terraform apply` again.

**Lessons**
- Check a chart's options for its **exact version**: `helm show values traefik/traefik --version 41.6.1`.
- Helm doesn't warn about unknown values.
- An error message (a timeout) can hide the real cause (a wrong Service type).

---

## P2. ArgoCD was never installed

*2026-11-16, MVP Phase 2.*

**Symptoms**
- The commit history said ArgoCD had been added, but no ArgoCD pods were running.
- `terraform state list` showed `kind_cluster.this` and `helm_release.traefik`, but not `helm_release.argocd`.
- `terraform plan` showed `Plan: 1 to add` (`helm_release.argocd will be created`).

**Investigation**
```bash
terraform state list        # what Terraform manages
terraform plan              # difference between the code and reality
helm list -A -a             # releases, including failed ones (-a)
kubectl get ns              # no "argocd" namespace
```
There was no failed release and no namespace, so there was nothing half-installed to clean up (unlike P1).

**Root cause**
- **Confirmed:** ArgoCD was not installed, and Terraform knew it (`plan` wanted to add it).
- **Hypothesis:** `terraform apply` was never run, or never finished, after ArgoCD was added to `platform.tf`. There is no record that proves which.

**Solution**
```bash
terraform plan -out=argocd.tfplan   # save the exact plan: 1 to add, 0 to destroy
terraform apply argocd.tfplan       # apply exactly that plan, nothing else
```
ArgoCD was installed in 48 s. Checked afterwards: 6 pods `Running`, `terraform plan -detailed-exitcode` returns code 0 (no differences), and the UI answers HTTP 200 (ArgoCD v3.5.3).

**Why a saved plan:** `terraform apply` without a file recomputes the plan, which could differ from the one that was reviewed. Applying a saved plan guarantees that what was reviewed is exactly what runs.

**Lesson:** a commit proves that code exists, not that infrastructure exists. `terraform plan` compares the two.

---

## P3. Preview URLs did not resolve to the laptop (nip.io)

*2026-11-16, MVP Phase 3, during the manual test of `pr-1` and `pr-2`.*

### Problem description

The plan (README, GUIDE) used URLs like `http://pr-12.127.0.0.1.nip.io`. All pods were `Running` and the Ingress existed, but the preview URL didn't work.

### Symptoms

- `curl http://pr-1.127.0.0.1.nip.io/` **hung** with no answer and no error, until the command was stopped after 120 s.
- No error came from Kubernetes or Traefik: every pod was `Running` and every resource was created.

### Investigation

The question was which part of the chain fails: **DNS**, or **Traefik and the app**?

```
browser → DNS: "pr-1.127.0.0.1.nip.io" = which IP? → 127.0.0.1:80 → kind node :30080 → Traefik → frontend
          └──────── step 1 ────────┘                 └─────────────── step 2 ───────────────┘
```

**Step 1: test DNS on its own.**
```bash
$ getent hosts pr-1.127.0.0.1.nip.io      # asks the system resolver, the same path as curl and the browser
1.127.0.0       pr-1.127.0.0.1.nip.io       # ← wrong! should be 127.0.0.1

$ dig +short pr-1.127.0.0.1.nip.io        # asks the DNS server directly
1.127.0.0

$ resolvectl status | grep "Current DNS"
Current DNS Server: 192.168.1.254         # the home router; it forwards the question to nip.io
```

**Step 2: test Traefik on its own, skipping DNS.** `curl --resolve` means "for this name, use this IP, don't ask DNS":
```bash
$ curl -s -o /dev/null -w "%{http_code}\n" --resolve pr-1.127.0.0.1.nip.io:80:127.0.0.1 http://pr-1.127.0.0.1.nip.io/
200
```
Traefik and the application work. Only DNS is wrong.

### Root cause

- **Confirmed:** nip.io returns `1.127.0.0` for `pr-1.127.0.0.1.nip.io`, and `12.127.0.0` for `pr-12.127.0.0.1.nip.io`. The bug affects **every** PR number. sslip.io, a similar service, gives the same wrong answer.
- **Hypothesis (inferred from the results, not from nip.io's source code):** nip.io looks for the **first** four numbers in the name. In `pr-12.127.0.0.1`, it finds `12.127.0.0` first, because the number at the end of `pr-12` is next to the IP.
- **Hypothesis:** curl hung instead of failing because `1.127.0.0` is a real Internet address that doesn't answer, so the connection waits for a long time. Tip: always add a timeout to test commands (`curl -m 10`).

### Formats considered

Each format was tested with `getent hosts <name>`:

| Format | Resolves to | Verdict |
|---|---|---|
| `pr-12.127.0.0.1.nip.io` (original plan) | `12.127.0.0` | ❌ broken |
| `pr-12.127.0.0.1.sslip.io` | `12.127.0.0` | ❌ same bug |
| `pr1.127.0.0.1.nip.io` | `127.0.0.1` | ✅ but `pr1` no longer matches the namespace name `pr-1` |
| `pr-1-app.127.0.0.1.nip.io` | `127.0.0.1` | ✅ |
| `pr-12-micropizzeria.127.0.0.1.nip.io` | `127.0.0.1` | ✅ but longer |
| **`pr-12.127-0-0-1.nip.io`** | `127.0.0.1` | ✅ **chosen** |
| `pr-12.localhost` | `::1` (IPv6) | ⚠️ see below |

### Solution

In MicroPizzeria's `ingress.yaml`, the host is now `NAMESPACE.127-0-0-1.nip.io`, which Kustomize turns into `pr-12.127-0-0-1.nip.io`. README.md and GUIDE.md were updated to match.

Checked after the fix:
```bash
$ getent hosts pr-1.127-0-0-1.nip.io
127.0.0.1       pr-1.127-0-0-1.nip.io
$ curl -s -m 15 -o /dev/null -w "%{http_code}\n" http://pr-1.127-0-0-1.nip.io/
200
```
The full user flow (register, login, order) then worked on both `pr-1` and `pr-2`.

### Why this solution

- It keeps the same service (nip.io) and the same idea, so no new tool was needed.
- The first label is still exactly the namespace (`pr-12`), so the URL tells you which environment you're on.
- It needed a one-word change in a single file.

### Rejected alternatives

- **`pr-12-micropizzeria.127.0.0.1.nip.io`:** works, but it's longer. It could become useful if PRVue previews several apps one day.
- **`pr-12.localhost`:** needs no external DNS at all. But the system resolves it to `::1` (IPv6), while the kind cluster only listens on the IPv4 address `127.0.0.1` (`listen_address` in `cluster.tf`). Many tools fall back to IPv4 and would work, but that depends on the tool, so it's fragile. **Not tested with curl or a browser.** It was rejected on this risk alone.
- **Editing `/etc/hosts` for each PR:** has to be done by hand for every new PR, so it defeats the automation.

---

## P4. One HTTP 500 right after a MySQL restart

*2026-11-16, MVP Phase 3, during the persistence test.*

**Symptoms**
After deleting the `mysql-user` pod (Kubernetes recreates it) and waiting for it to be Ready:
```
login #1 after restart -> 500
login #2 after restart -> 200
login #3 after restart -> 200
```

**Investigation**
```bash
kubectl logs -n pr-2 deploy/user-service --since=2m | grep -i error
# pymysql.err.OperationalError: (2013, 'Lost connection to MySQL server during query')
```

**Root cause**
- **Confirmed:** the 500 is a `Lost connection to MySQL server` error, it happens only on the first request, and **the data is still there** (logins #2 and #3 succeed, so the PVC works).
- **Hypothesis (very likely, matches the pattern):** SQLAlchemy keeps a *pool* of open connections. The first request reuses a connection to the **old** MySQL pod, which no longer exists. SQLAlchemy then throws that connection away, and the next request opens a new one.
- This is existing MicroPizzeria behavior, not caused by PRVue.

**Solution:** none for the MVP. In a preview, MySQL only restarts after a crash, and the error fixes itself on the next request. MicroPizzeria's code is left unchanged on purpose.

**Possible fix (not tested):** `SQLALCHEMY_ENGINE_OPTIONS = {"pool_pre_ping": True}` in each service's `config.py`. SQLAlchemy then checks that a connection is alive before using it.

**Lesson:** I deleted `pr-1` before investigating this error, and had to reproduce it in `pr-2`. Keep the broken state until you've read the logs.

---

## P5. False alarm: server-side dry run says "namespace not found"

*2026-11-16, MVP Phase 3.*

**Symptoms:** `kubectl apply --dry-run=server -f out.yaml` printed `namespaces "pr-1" not found` for every resource.

**Cause (confirmed):** a dry run creates nothing, **including** the `Namespace` resource at the top of the file. The resources that live inside `pr-1` then can't find it. The real `kubectl apply -k .` creates the Namespace first, and everything worked.

**Lesson:** a dry run doesn't fully reproduce resources that depend on each other.

---

## P6. Brief 503 and "middleware does not exist" right after a deployment

*2026-11-16, while testing the default `kubectl apply -k .` (namespace `micropizzeria`) for the MicroPizzeria README.*

**Symptoms**
- Right after `kubectl wait ... --for=condition=available` succeeded, `GET /` returned 200 and `/api/menu` returned 200, but `POST /api/auth/register` returned **503**.
- Retried a few seconds later: register returned 201 three times, and login returned 200.
- Traefik logs, at the moment of the `apply`:
  ```
  ERR error="middleware \"micropizzeria-strip-api@kubernetescrd\" does not exist" ... routerName=...-api-users@kubernetes
  ```

**Investigation**
```bash
kubectl get pods,endpointslices -n micropizzeria          # all Ready, all have an endpoint
kubectl logs -n micropizzeria deploy/user-service         # no register request: the 503 didn't reach Flask
kubectl logs -n traefik deploy/traefik --since=5m | grep -iE "micropizzeria|error"
```

**Root cause**
- **Confirmed:** the 503 came from Traefik, not from the application. user-service never logged the request.
- **Confirmed:** `kubectl apply` created the Ingress **before** the Middleware (`middleware.traefik.io/strip-api created` is the last line of the output). For a few seconds, Traefik saw an Ingress referring to a middleware that didn't exist yet, and logged errors.
- **Hypothesis:** the 503 itself happened because Traefik hadn't yet added user-service as a ready backend. Traefik updates its configuration a little after Kubernetes. user-service was the last deployment to become available, and the menu (order-service) already worked at that moment.

**Solution:** none needed. Both cases fixed themselves within seconds.

**Consequence for later (Phase 5 health check):** one attempt isn't enough. The check must **retry** for a while before declaring a preview broken.

---

## P7. Previews would never be "Healthy": empty Ingress status

*2026-11-16, Phase 4b. Found **before** applying the ApplicationSet, by reading the code and the cluster state.*

**Symptom (expected, not observed yet):** generated Applications would stay *Progressing* forever instead of *Healthy*, even with every pod running.

**Investigation**
```bash
kubectl get ingress -n pr-2 -o jsonpath='{.items[0].status.loadBalancer}'   # {}  ← empty
kubectl get svc -n traefik traefik -o jsonpath='{.spec.type} {.status.loadBalancer}'   # NodePort {}
```
- Argo CD v3.5 docs, health checks: an Ingress is healthy when "the `status.loadBalancer.ingress` list is non-empty". The docs don't say what happens otherwise.
- Argo CD source v3.5.3, `gitops-engine/pkg/health/health_ingress.go`: `if len(ingresses) > 0 { Healthy } else { Progressing }`.
- Traefik chart 41.6.1 values: `providers.kubernetesIngress.publishedService.enabled: true` by default, which copies the status **of Traefik's Service** into every Ingress. Our Service is a `NodePort`, which has no load balancer address, so the status is always empty.

**Root cause (confirmed from code and state):** Argo CD reports an Ingress without an address as *Progressing*, and Traefik never writes an address.

**Phase 3 missed it** because `kubectl wait --for=condition=available deploy` only looks at Deployments.

**Solution (applied 2026-11-16):** in `platform/terraform/values/traefik.yaml`:
```yaml
providers:
  kubernetesIngress:
    publishedService:
      enabled: false
    ingressEndpoint:
      ip: "127.0.0.1"
```
- `helm template` confirmed the chart then generates `--providers.kubernetesingress.ingressendpoint.ip=127.0.0.1`, instead of `...publishedservice=traefik/traefik`.
- `terraform plan`: `0 to add, 1 to change, 0 to destroy` (in-place Helm upgrade of Traefik).
- **Applied and confirmed:** `terraform apply` changed 1 resource in 13 s, the Traefik pod runs with `--providers.kubernetesingress.ingressendpoint.ip=127.0.0.1`, and `kubectl get ingress -n pr-2` now shows `ADDRESS 127.0.0.1`. pr-2 still answers 200 (page and API).
- **Confirmed (PR #5):** the generated Application `micropizzeria-pr-5` reached **Synced / Healthy**, and its Ingress has `ADDRESS 127.0.0.1`.

**Why:** `127.0.0.1` is the **true** address of the previews, so the status says something real.

**Alternatives rejected**
- **A custom Argo CD health check** (Lua) that always reports Ingresses as Healthy: it hides the real state.
- **Accepting "Progressing":** the Definition of Done needs *Healthy*, and a permanently "Progressing" app hides real problems.
- **Changing the Traefik Service to `LoadBalancer`:** that's exactly the problem from P1 (no load balancer on kind).

---

# Decisions

## D1. Two repositories: MicroPizzeria (app) and PRVue (platform)

**Decision:** MicroPizzeria holds the application and its manifests. PRVue holds the platform: Terraform (kind, Traefik, ArgoCD) and, in Phase 4, the ArgoCD ApplicationSet.

**Why**
- This mirrors companies: a platform team provides the tooling, and application teams use it.
- No code duplicated in two places.
- The ApplicationSet belongs to the platform. It describes *how* to create previews, not *what* the app is. Another app could reuse PRVue later.

**Alternatives rejected**
- **Copying MicroPizzeria into PRVue:** duplicated code that would drift apart.
- **A Git repo nested inside another:** causes Git problems.

---

## D2. Kubernetes manifests live in MicroPizzeria, reused in place

**Decision:** the existing `*/k8s/*.yaml` files are **unchanged**. A single `kustomization.yaml` at the root of MicroPizzeria lists them where they are. There is no new `deploy/` folder, unlike GUIDE.md's original plan.

**Why in MicroPizzeria**
- A pull request can change both the code and the manifests, for example a new environment variable. ArgoCD deploys the manifests **from the PR's commit**, so the preview matches the PR exactly.

**Why no `deploy/` folder**
- Kustomize can point to files where they already are, so moving them would add nothing.
- It's the smallest change: the old `deploy.sh` flow still finds its files in the same places.

**Alternatives rejected**
- **Manifests in PRVue:** a PR that needs a manifest change couldn't be previewed correctly.
- **Moving everything to `deploy/base` and `deploy/overlays/preview`:** more files and a reorganization, for no benefit in the MVP.

---

## D3. Kustomize to adapt the manifests per pull request

**Decision:** use Kustomize, which is built into `kubectl` (`kubectl apply -k`) and into ArgoCD.

**Why**
- The manifests already exist as plain YAML. Kustomize **adapts** them (namespace, image tags, secrets, patches) without rewriting them.
- Nothing to install: it's built into kubectl (v5.7.1 here) and ArgoCD.
- ArgoCD can set the namespace and images per PR (`kustomize.namespace`, `kustomize.images`).

**Alternatives rejected**
- **A Helm chart for MicroPizzeria:** every file would become a template (`{{ .Values... }}`). That's more to learn and maintain, for an app with a single configuration.
- **`sed` or `envsubst` in a script:** fragile, and ArgoCD doesn't run your scripts.

---

## D4. Dynamic namespaces: the namespace is the only input

**Decision:** `kustomization.yaml` contains `namespace: micropizzeria` by default. For PR 12 it becomes `namespace: pr-12`, and Kustomize derives everything else from that value:

| What | How | Result for PR 12 |
|---|---|---|
| The namespace of every resource | Kustomize's `namespace:` field | `namespace: pr-12` |
| The `Namespace` resource's name | Same field | `pr-12` |
| `RoleBinding` subjects (were `default`) | Same field | `pr-12` |
| Ingress host | `replacements` (first `.`-separated part) | `pr-12.127-0-0-1.nip.io` |
| Traefik middleware reference | `replacements` (first `-`-separated part) | `pr-12-strip-api@kubernetescrd` |

**Confirmed** on a throwaway copy before touching the real repo, then with the real deployment of `pr-1` and `pr-2`.

**Why the `Namespace` resource is in the manifests:** ArgoCD's `CreateNamespace=true` option creates a namespace but doesn't delete it when the app is deleted. If the namespace is part of the app's resources, it can be deleted along with the PR.
- **Confirmed:** `kubectl delete namespace pr-1` deletes everything inside, including the volumes.
- **Not tested yet:** the automatic deletion by ArgoCD when a PR is closed. That's Phase 5.

**Why `replacements`:** Traefik references a middleware as `<namespace>-<name>@kubernetescrd`, so the namespace is part of the name. Without `replacements`, ArgoCD would have to patch both the host and that annotation.

**Alternative rejected:** two patches written in the ApplicationSet. That works, but then a manual test (`kubectl apply -k`) wouldn't match what ArgoCD deploys.

---

## D5. Traefik instead of Nginx Ingress

**Decision:** Traefik is the Ingress controller (Helm chart 41.6.1, installed by Terraform). MicroPizzeria's `ingress.yaml` was adapted: `ingressClassName: traefik`, `Prefix` paths, and a `strip-api` middleware instead of the Nginx regex `rewrite-target`.

**Why**
- The ingress-nginx project was retired by Kubernetes (no updates since March 2026).
- Traefik is lightweight, maintained, and its Helm chart is simple.

**What changed in the routing:**

| Request | Nginx (before) | Traefik (now) |
|---|---|---|
| `/api/users/me` | regex `/api(/)((?:users|auth).*)` + `rewrite-target: /$2` | `Prefix /api/users` + middleware `stripPrefix /api` |
| user-service receives | `/users/me` | `/users/me` (same) |

**TLS removed** for previews: the old certificate was a secret created by hand. Previews use plain HTTP and only listen on `127.0.0.1`. TLS can be added later.

---

## D6. nip.io for local preview URLs

**Decision:** preview URLs use the format `http://pr-<number>.127-0-0-1.nip.io`.

**Why a wildcard DNS service:** each PR needs its own hostname, because Traefik routes by hostname. nip.io answers any name containing an IP with that IP, without any configuration. A new PR gets a working URL immediately.

**Why `127-0-0-1` with dashes:** see [P3](#p3-preview-urls-did-not-resolve-to-the-laptop-nipio). The dotted format is misread by nip.io.

**Limitation:** resolving the name requires Internet access (the DNS question goes to nip.io's servers). The traffic itself stays on the laptop.

**Alternatives rejected:** `/etc/hosts` (manual for every PR), a local DNS server like dnsmasq (an extra tool to install and maintain), and `.localhost` (IPv6 risk, see P3).

---

## D7. Database isolation: two MySQL instances per preview

**Decision:** every preview gets its own `mysql-user` and `mysql-order`, each with its own 1 GiB PVC. These are the existing MicroPizzeria manifests, unchanged.

**How the isolation works**
- Services use **short DNS names** (`mysql-user`, `user-service`). Inside namespace `pr-12`, `mysql-user` means `mysql-user.pr-12.svc.cluster.local`. Each environment automatically talks to its own databases, without any configuration.
- PVCs are namespaced, so each preview has its own disks.

**Confirmed**
- alice, registered in `pr-1`, gets `401 Invalid credentials` in `pr-2`.
- Data survives a MySQL pod restart.
- Deleting `pr-1` deleted its two volumes, while `pr-2` kept its own.

**Cost:** about 1.3 GiB of requested memory per preview (two MySQL instances requesting 512Mi each). Two previews at the same time fit on this laptop (15 GiB).

**Alternatives rejected**
- **One shared MySQL for all previews:** PRs would see each other's data, and one PR's migration could break the others.
- **`emptyDir` instead of a PVC:** simpler, but data would be lost on every MySQL restart. It would also mean changing the existing manifests.

---

## D8. Throwaway secrets for previews

**Decision:** a `secretGenerator` in `kustomization.yaml` creates `user-service-secret` and `order-service-secret`, with the same keys as the real files and the value `preview-only-not-a-secret`. These values are committed to Git. The real `*/k8s/secret.yaml` files stay gitignored.

**Why**
- ArgoCD can only deploy what is in Git, so a secret created by hand would be missing from every new PR namespace.
- These values protect nothing real: each preview's databases are internal to its namespace, contain test data, and are deleted with the PR.
- `disableNameSuffixHash: true` keeps the exact names that the deployments and `rbac.yaml` use.

**Alternatives rejected for the MVP**
- **`kubectl create secret` for each PR:** manual, so it breaks the automation.
- **A secret manager (Doppler, Sealed Secrets, External Secrets):** the right long-term solution. Doppler is planned as an extension.

---

## D9. `imagePullPolicy: IfNotPresent` and unique image tags

**Decision:** a Kustomize patch sets `IfNotPresent` on all Deployments. The original manifests used `Always`.

**Why**
- Preview images will have a unique tag per commit (`pr-12-abcd1234`), and the content of a tag never changes. Downloading it again on every pod start is pointless.
- It also allowed the Phase 3 test with images built locally and loaded into kind (`kind load docker-image`). With `Always`, Kubernetes would have tried to download them from GHCR, where they didn't exist yet.

---

## D10. Three images, GHCR, and the tag contract

*2026-11-16, Phase 4. Workflow: `.github/workflows/preview.yml` in MicroPizzeria.*

**First run: PR #4, head `5b6f929c2e3b…677d`. Confirmed from the workflow logs:**
- All 4 jobs succeeded: 3 builds, then `label`.
- Each image was pushed with exactly two tags, `pr-4-5b6f929c` and `pr-4`, and both point to the same digest. No `latest`.
- Labels: `revision` = the full head SHA (not the merge commit), `source` = `https://github.com/sana-Benz/MicroPizzeria`.
- The PR received `preview-ready`.

**Decisions**
- **Three images**, one per piece of our own code: `frontend`, `user-service`, `order-service`, built with the existing Dockerfiles. `mysql:8.0` and `busybox:1.35` are upstream images and are never rebuilt.
- **GHCR only**: `ghcr.io/sana-benz/micropizzeria-<service>` (lowercase is required). CI logs in with the built-in `GITHUB_TOKEN`, so no token needs to be created.
- **Two tags per build**:
  - `pr-<number>-<first 8 chars of the head SHA>`: immutable. Deployments always use it, so every new commit triggers a rollout.
  - `pr-<number>`: moving, for humans only.
- **All three images are rebuilt** on every `opened`, `synchronize` and `reopened` event.
- **Images are kept in GHCR** after the PR closes. Cleanup is a later extension.

**The tag contract:** CI and ArgoCD never talk to each other. Both compute the same name from the PR number and the PR's head commit:
- CI: `pr-${PR_NUMBER}-${HEAD_SHA::8}`, with `HEAD_SHA = github.event.pull_request.head.sha`.
- ArgoCD: `pr-{{.number}}-{{.head_short_sha}}`.

**Confirmed in the Argo CD v3.5 docs:** `head_short_sha` is 8 characters (`head_short_sha_7` also exists, and must not be used here).
**Confirmed locally:** `git rev-parse --short` gave 7 characters (`db9fec4`), so it would break the contract.

**Why not `:latest` or a moving tag in the deployments:** with a tag that moves, nobody knows exactly which commit is running, and with `IfNotPresent` a new build would never be pulled.

**Alternatives rejected**
- **Docker Hub (`sanabns/*`):** a second account and token to manage. GHCR comes with the repo.
- **Building only the images that changed:** less build time, but conditional logic. The tag contract also needs all three images to exist under every commit's tag.
- **Using the `pr-<number>` tag in deployments:** see above.

---

## D11. The `preview-ready` label as the deployment gate

*2026-11-16, Phase 4. **Not run yet.***

**The problem:** when a PR is opened, CI and ArgoCD both react. If ArgoCD deploys before the images exist, the pods fail with `ImagePullBackOff`. **Confirmed in the v3.5 docs:** the Pull Request generator can filter on labels, branches and title, but **not on CI status**.

**Decision**
- A final `label` job with `needs: build` runs only if **all three** matrix builds succeeded. It runs `gh pr edit --add-label preview-ready`.
- Adding a label that is already there changes nothing, so the job runs on every successful build without checking first.
- `pull-requests: write` is granted to that job only.
- The label is added **once** and never removed. ArgoCD only lists PRs that carry it.

**Why "never removed":** a label belongs to a **PR**, not to a commit. Removing it at the start of each build would make the PR stop matching the ApplicationSet, so ArgoCD would delete the whole environment (namespace and databases) on every commit and recreate it afterwards.

**What protects later commits:** rolling updates ([C11](#c11-rolling-updates)).
- **Confirmed** on the rendered `pr-2`: none of the 5 Deployments sets `strategy`, so all use `RollingUpdate` (maxSurge 25%, maxUnavailable 25%, 1 replica). No `Recreate` anywhere.

**Accepted limitations**
- **A new commit can show `ImagePullBackOff` for a few minutes:** ArgoCD may see the commit before its images are published. The old pod keeps serving, and Kubernetes retries the pull with an increasing delay (up to about 5 minutes between attempts), so the switch can lag behind CI.
- **A failed build on a later commit** leaves the old version running, and the Application shows *Degraded*.
- **PRs from forks** get no preview: their `GITHUB_TOKEN` is read-only.
- **The label must exist** in the repo before the first run: `gh label create preview-ready ...` (see GUIDE, step 0). Otherwise `gh pr edit --add-label` fails.
- **No webhooks, so there's a delay.** The cluster only listens on `127.0.0.1`, so GitHub can't notify ArgoCD, which polls instead. Expected delay between a push and the updated preview: CI build time + up to 120 s (`requeueAfterSeconds`) + possibly the image-pull retry delay (up to about 5 minutes).
- **The ApplicationSet must use a GitHub token (`tokenRef`).** Anonymous API access is limited to 60 requests/hour: 120 s polling fits, but with no margin. With a token, the limit is 5,000/hour.

**Tag confirmed exact** (metadata-action v6 README): default tags apply only "if `tags` input is empty", and `latest=auto` only adds `latest` for `ref,event=tag`, `semver`, `pep440` and `match`, never for `raw`. The workflow also sets `flavor: latest=false` explicitly. Each image gets exactly `pr-<n>-<sha8>` and `pr-<n>`. **Not tested yet:** to check in GHCR after the first run.

**Alternatives rejected**
- **No gate at all:** the first deployment would always race CI and fail for a while. A PR whose build never succeeds would still get a broken environment.
- **Removing and re-adding the label on every build:** destroys the environment on every commit (see above).
- **CI writing the tag into Git, or ArgoCD Image Updater:** gates every commit exactly, but needs commit-back logic or an extra tool. Too much for the MVP.
- **A human `preview` label (the original plan):** dropped. Every PR gets a preview once its build succeeds.

---

## D12. Public GHCR packages

*2026-11-16, Phase 4.*

**Decision:** the three packages are **public**. Each image carries the `org.opencontainers.image.source` label pointing at the MicroPizzeria repo, which links the package to the repo.

**First run (PR #4, 2026-11-16):** the packages were **already public**. An anonymous manifest read returned HTTP 200 for all 3, so the planned manual step wasn't needed.
- **Confirmed:** visibility was **not** changed by hand. The 3 packages became public on their own.
- **Confirmed:** the 3 packages are **linked to the MicroPizzeria repo** (checked in the repo's *Packages* sidebar).
- **Confirmed:** the kind node pulls `ghcr.io/sana-benz/micropizzeria-frontend:pr-4-5b6f929c` **without credentials** (`crictl pull` inside the node, 4 s).
- **Hypothesis (likely mechanism, not documented here):** a package created by a workflow in a **public** repo and linked to it inherits the repo's visibility. The plan had assumed new packages are always private; that was wrong here.
- **Lesson:** GHCR's token endpoint gives a token to anyone, even for a private image. Only reading the manifest proves the access (see GUIDE, step 3).

**Why**
- A private image would need an image pull secret in **every** `pr-N` namespace. These namespaces are new for each PR, and the secret holds a real token, so it can't be committed like the preview secrets (D8).
- The MicroPizzeria repo is already public, so the images only contain code anyone can read.

**Alternatives rejected**
- **A pull secret copied into each namespace** by a tool (Kyverno, reflector): an extra technology.
- **Registry credentials on the kind node** (containerd configuration, via Terraform): works for every namespace, but more advanced. A good option if the images ever need to be private.

---

## D13. Deleting the namespace when a PR closes (Phase 5, decided, not tested)

**Decision:** the namespace is a resource **owned by ArgoCD**, so it's deleted along with the Application. MicroPizzeria's `namespace.yaml` is already in `kustomization.yaml`, and Kustomize renames it to `pr-<number>`.

**What the Argo CD v3.5 docs say**
- `CreateNamespace=true`: "The generated namespace is normally not tracked with Argo CD", so it is not deleted with the Application.
- A `Namespace` manifest in the application "will take precedence" over `managedNamespaceMetadata`.
- The ApplicationSet controller adds `resources-finalizer.argocd.argoproj.io` to generated Applications **by itself**, so deleting the Application deletes its resources. Adding it in the template too would be harmless, but redundant.
- The docs don't clearly say whether the GitHub generator lists only open PRs.

**Rejected: a GitHub Actions `closed` job running `kubectl delete namespace pr-<N>`.** A GitHub runner can't reach the cluster: it runs on the laptop, the API server only listens on `127.0.0.1`, and nothing comes in (pull model). Making it work would mean exposing the API server to the Internet, or installing a self-hosted runner on the laptop. Both go against PRVue's security model.

**Rendering checked (2026-11-16)** with **ArgoCD's own kustomize** (v5.8.1, inside the `argocd-repo-server` pod; kubectl has v5.7.1), on a temporary copy, running the same commands ArgoCD runs:
```bash
kustomize edit set namespace pr-99
kustomize edit set image sanabns/frontend=ghcr.io/sana-benz/micropizzeria-frontend:pr-99-abcd1234 ...
kustomize build .
```
- **Confirmed:** the `Namespace` object is named `pr-99`. All 26 resources and the RoleBinding subjects are in `pr-99`, and the only cluster-scoped resource is `Namespace/pr-99`. No `default` and no `micropizzeria` is left.
- **Risk found:** without the namespace override, everything goes into `micropizzeria`. That's never `default`, but it is **shared by every PR**: two Applications would own the same Namespace, and closing one PR would delete the other's environment.
- **Safeguards:** see [D14](#d14-a-dedicated-appproject-as-the-real-namespace-safeguard). `missingkey=error` is **not** one of them: it only catches template variables that don't exist, not a forgotten `kustomize.namespace` field.

**Cascade deletion, confirmed for a plain Application (2026-11-16, during the D14 test):** an Application with `resources-finalizer.argocd.argoproj.io`, once deleted, removed all its resources, **the `pr-98` namespace** (owned by ArgoCD: annotation `argocd.argoproj.io/tracking-id: check-override:/Namespace:pr-98/pr-98`) and its 2 volumes, in 42 s.

**Confirmed for a generated Application (PR #5, 2026-11-16):** the finalizer was on `micropizzeria-pr-5`. Closing the PR deleted the Application, then the namespace and both volumes, in about 1 minute, with nothing done by hand. See D16, step 6.

**Original checklist (all done):** is the finalizer really on the generated Application (`kubectl get application -n argocd pr-<n> -o yaml`), closing a PR deletes the Application, the namespace and the volumes, and the other preview stays up.

---

## D14. A dedicated AppProject as the real namespace safeguard

*2026-11-16. Decided for the ApplicationSet step, and **tested on the cluster** with a throwaway project, since deleted.*

**The risk:** if the ApplicationSet forgets `kustomize.namespace`, every PR renders into the shared `micropizzeria` namespace (see D13).

**What doesn't protect against it:** `goTemplateOptions: ["missingkey=error"]`. It only fails on template variables that don't exist (for example `{{.numbr}}`). A missing `kustomize.namespace` field has no variable to fail on. It's still useful, just not for this.

**What does: an AppProject** that only allows previews:
```yaml
spec:
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "pr-*"
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
      name: "pr-*"
```

**What the v3.5 docs say:**
- `clusterResourceWhitelist` entries take `group`, `kind` **and `name`**, with glob patterns. The docs' example restricts `Namespace` to `team1-*`. So the original assumption, "group/kind only, no names", is outdated for v3.5.
- The docs **don't say** whether `destinations` is checked per resource, or only against `spec.destination.namespace`. That's why it was tested.

**Test** (project `prvue-check`, Application on MicroPizzeria `main`, destination `pr-98`):

| Case | Result |
|---|---|
| **No** `kustomize.namespace` (everything renders into `micropizzeria`) | Sync **refused**: `namespace micropizzeria is not permitted in project 'prvue-check'; resource :Namespace is not permitted in project prvue-check`. Neither `micropizzeria` nor `pr-98` was created |
| `kustomize.namespace: pr-98` | `Synced`, namespace `pr-98` created and tracked by ArgoCD |

**Confirmed:**
- ArgoCD checks **each resource's own namespace** against `destinations`. The Application's destination was the allowed `pr-98`, but the resources' `micropizzeria` was still refused.
- The `name: pr-*` whitelist entry blocks a `Namespace` object with another name.
- A sync with any invalid task is refused **as a whole**: nothing is applied.

**Conclusion:** the namespace is protected by the AppProject itself, not only by the Kustomize override and code review. The ApplicationSet must use this project, never `default`, which allows everything.

---

## D15. The `previews` AppProject: an allow list of kinds

*2026-11-16. File: `platform/argocd/appproject.yaml`. Server-side dry run OK; **not applied yet**.*

**Rules**
- `sourceRepos`: only `https://github.com/sana-Benz/MicroPizzeria.git`.
- `destinations`: the in-cluster server, namespaces `pr-*`.
- `clusterResourceWhitelist`: only `Namespace` with `name: pr-*`. Name patterns are supported in v3.5: the CRD field list is `group, kind, name`, and the docs give an example.
- `namespaceResourceWhitelist`: exactly the **9 namespaced kinds** that MicroPizzeria renders (taken from the dry run): `ServiceAccount`, `Secret`, `Service`, `PersistentVolumeClaim`, `apps/Deployment`, `rbac/Role`, `rbac/RoleBinding`, `networking.k8s.io/Ingress`, `traefik.io/Middleware`.

**Why an allow list**
- A PR can't introduce new kinds of resources without PRVue agreeing (a platform-team decision).
- It's not too restrictive: Pods and ReplicaSets are created by the Deployment controller, not by Argo CD, so they don't need to be listed.

**Cost:** a new kind (a `ConfigMap`, the Phase 5 health-check `Job`) must first be added here. Otherwise the whole sync is refused, with an error naming the kind.

**Allowed on purpose:** `Role` and `RoleBinding`. MicroPizzeria's `rbac.yaml` needs them, and a Role only grants rights inside its own namespace.

**Applied 2026-11-16. Fence test confirmed** with two throwaway Applications in project `previews`, since deleted:

| Test | Result |
|---|---|
| No `kustomize.namespace`, so everything renders into `micropizzeria` (destination `pr-97`) | Sync refused: `namespace micropizzeria is not permitted in project 'previews'; resource :Namespace is not permitted in project previews` |
| `kustomize.namespace: default`, destination `default` | Rejected **before any sync**: `InvalidSpecError: application destination server 'https://kubernetes.default.svc' and namespace 'default' do not match any of the allowed destinations in project 'previews'` |

Nothing was created: `micropizzeria` and `pr-97` don't exist, and the `default` namespace is unchanged (`resourceVersion` 21 before and after, no new objects).

---

## D16. The ApplicationSet, and parity with the Phase 3 manual deploy

*2026-11-16. File: `platform/argocd/applicationset.yaml`.*

**Applied 2026-11-16. Controller confirmed healthy:**
- `ParametersGenerated=True` and `ErrorOccurred=False`, so the GitHub API call with the token works.
- Log: `generated 0 applications ... requeueAfter=2m0s`. 0 is expected, because no open PR carries `preview-ready` yet (PR #4 is merged).
- No errors or warnings in the logs.
**Step 4 confirmed: first automatic preview, PR #5** (branch `docs/readme-workflow-status`, head `f7f4bde726b0…1032`). It went *Missing → Progressing → Synced/Healthy* with no manual step.

| Check | Result |
|---|---|
| CI | 3 × `build` + `label` passed, PR labeled `preview-ready` |
| Application | `micropizzeria-pr-5`, project `previews`, owner `ApplicationSet/micropizzeria-previews`, **synced revision = head SHA** |
| Finalizer | `resources-finalizer.argocd.argoproj.io` present on the **generated** Application |
| Images | `ghcr.io/sana-benz/micropizzeria-{frontend,user-service,order-service}:pr-5-f7f4bde7`, so **tag contract confirmed end to end**. MySQL keeps `mysql:8.0` |
| Pods / PVC | 5/5 `Running` (0 restarts), 2 PVC `Bound` |
| Ingress | `pr-5.127-0-0-1.nip.io`, `ADDRESS 127.0.0.1` |
| Namespace | ArgoCD-owned: `tracking-id=micropizzeria-pr-5:/Namespace:pr-5/pr-5` |
| Through Traefik | `/` 200, `/api/menu` 17 items, `/api/users/me` without a token 401 |
| Data from the browser | 1 user (`jean.dupont@test.com`) and 1 order (`pending`, 33.50) in the preview's own databases |

**Step 5 confirmed: second commit on PR #5** (new head `0c90bebf5013…6ec9`, CI 43 s):
- Application `Synced/Healthy` at revision `0c90bebf…`. The 3 Deployments moved to `pr-5-0c90bebf`.
- **Rolling update** (watched by hand): each new `frontend`, `user-service` and `order-service` pod reached 1/1 **before** its old pod terminated. No `ImagePullBackOff`, so this time CI finished before ArgoCD's next poll. The new README text was visible in the preview.
- **Same environment, data kept.** These match the values saved before the push:

  | Check | Before = after |
  |---|---|
  | Namespace `creationTimestamp` | `2026-11-16T15:11:52Z` |
  | MySQL pods (restarts) | `mysql-order-bb8f6f467-tsvw5` (0), `mysql-user-75469dd7db-x6s99` (0): not recreated |
  | PVCs → volumes | `pvc-09258ebb-…`, `pvc-2749b739-…` |
  | `user` table | `1 jean dupont jean.dupont@test.com` |
  | `order` table | `1 1 pending 33.5` |

  The test user could still log in and see the order in the browser.

**Step 6 confirmed: PR #5 closed without merging** (`gh pr close 5`, 15:26:58 UTC, `mergedAt=null`):
- Log: `Deleted application micropizzeria-pr-5` at 15:27:56 UTC, about **1 min** after the close (within one 120 s poll).
- Application gone. **Namespace `pr-5`: NotFound**. **PVs for pr-5: 0** (2 before).
- **pr-2 untouched:** identical UIDs for the namespace, the 5 pods and the 2 PVCs, and it still answers 200.
- **Images kept in GHCR:** an anonymous manifest read returned 200 for all 9 tags (3 images × `pr-5-f7f4bde7`, `pr-5-0c90bebf`, `pr-5`).

**Full PR lifecycle confirmed end to end: open → preview → update in place → close → cleanup, with no manual command.**

**Not tested yet:** two automatic previews **at the same time**. pr-2 (manual) stood in for "the other environment" in step 6. To show in the demo.

**Warning:** deleting the ApplicationSet deletes **all** its Applications, and their finalizers delete every preview namespace. Update it with `kubectl apply`, never delete and recreate it.

**Main settings**
- `goTemplate: true`, `missingkey=error`.
- Pull Request generator: `sana-Benz/MicroPizzeria`, `tokenRef` → `github-token`/`token`, `labels: [preview-ready]`, `requeueAfterSeconds: 120`.
- Template: name `micropizzeria-pr-{{.number}}`, project `previews`, `targetRevision: {{.head_sha}}`, `path: .`, `kustomize.namespace` and `kustomize.images`, destination `pr-{{.number}}`, and `automated` with `prune` and `selfHeal`.
- **No `CreateNamespace=true`:** the Namespace is part of the manifests (D13).

**Checked in the docs or the source (v3.5 / v3.5.3)**
- `head_short_sha`: "8 characters long". It matches the CI's `${HEAD_SHA::8}` (D10).
- **Only open PRs:** the generator calls GitHub's `PullRequests.List` **without a `state` option**, and the GitHub API defaults to `state=open`. A closed or merged PR disappears from the list, so its Application is deleted.
- **Finalizer:** the docs say the ApplicationSet controller adds `resources-finalizer.argocd.argoproj.io`. The template also sets it explicitly, which is harmless and makes the intent visible. Cascade deletion including the Argo CD-owned Namespace was **confirmed for a plain Application** (D13). It will be confirmed for a generated one in Phase 5.

**Parity table: everything `deploy-preview.sh` (Phase 3) did, and what replaces it**

| Phase 3 (by hand) | Phase 4b (Argo CD) | Check |
|---|---|---|
| Copy the working tree into a temp folder | Argo CD clones MicroPizzeria **at `{{.head_sha}}`**: only **committed** content counts | Dry run from `git archive 5b6f929c` |
| `sed` the `namespace:` line | `kustomize.namespace: pr-{{.number}}` (Argo CD runs `kustomize edit set namespace`) | Dry run: 25/25 resources and the Namespace object are `pr-99` |
| Append an `images:` block | `kustomize.images` (3 entries) | Dry run: 3 × `ghcr.io/sana-benz/micropizzeria-*:pr-99-5b6f929c` |
| **Ingress host per PR** | **Already derived from the namespace** by the `replacements` in `kustomization.yaml` (committed in PR #3). No patch needed in the ApplicationSet; a patch would be a second source of truth that could drift | Dry run: `pr-99.127-0-0-1.nip.io`, middleware `pr-99-strip-api@kubernetescrd` |
| **Secrets** | `secretGenerator` in `kustomization.yaml` (committed) generates `user-service-secret` and `order-service-secret` with **throwaway values** (D8). The gitignored `secret.yaml` files were never used by previews | Dry run: 7/7 secret references point to existing keys |
| `kubectl apply -k .` | `syncPolicy.automated` (+ `prune`, `selfHeal`) | — |
| Build the images + `kind load docker-image` | CI publishes to GHCR (D10); public packages (D12) | `crictl pull` from the node without credentials |
| `imagePullPolicy` | `IfNotPresent` patch in `kustomization.yaml` | Dry run |
| Ordering (MySQL before Flask) | The `wait-for-mysql` init containers (in the manifests). Argo CD also applies the Namespace before namespaced resources | D14 test: sync succeeded without `CreateNamespace` |
| `kubectl wait ... deploy` | Argo CD health. **Gap found: the Ingress would never be Healthy**, see [P7](#p7-previews-would-never-be-healthy-empty-ingress-status) | Fix proposed (Traefik values) |
| `kubectl delete namespace` | PR closed → Application deleted → finalizer → Namespace deleted | Plain Application: confirmed (D13). Generated: Phase 5 |
| *(not needed in Phase 3)* | AppProject `previews` (D15), token Secret (D17) | — |

---

## D17. The GitHub token: created with kubectl, not Terraform

*2026-11-16.*

**Token:** fine-grained, repository access *MicroPizzeria only*, permissions **Pull requests: read-only** and **Metadata: read-only**, expires in 90 days. Stored as Secret `github-token` (key `token`) in `argocd`, created with `kubectl` from `read -s` (see GUIDE, step 4).

**Why not Terraform** (the original GUIDE plan): a `kubernetes_secret` resource would write the token **in plain text** in `terraform.tfstate`.

**The `scm-creds` label:** the docs don't mention any label for `tokenRef` Secrets. The source code (v3.5.3, `applicationset/utils/kubernetes.go`) has a **strict mode**: if it's on, a Secret without the label `argocd.argoproj.io/secret-type=scm-creds` is refused (`ErrDisallowedSecretAccess`).
- **Confirmed:** strict mode is off by default (`--token-ref-strict-mode`, default `false`), and our `argocd-cmd-params-cm` doesn't enable it.
- So the label isn't required now. It's added anyway, in case strict mode is ever turned on.
- Note: the label it checks is not `app.kubernetes.io/part-of: argocd`.

**Renewal:** create the new token, replace the Secret's value with `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`, then check the controller logs. The source re-reads the Secret on every generation, so no restart is needed.
- **Not verified:** what happens to existing previews when the token expires.

---

# Concepts

## C1. DNS and hostname resolution

DNS works like a phone book: it turns a **name** (`pr-12.127-0-0-1.nip.io`) into an **IP address** (`127.0.0.1`). The browser needs the IP to connect.

Path of a DNS question on this laptop: application → system resolver (`systemd-resolved`) → router (`192.168.1.254`) → Internet → the nip.io servers, which compute the answer from the name.

```bash
getent hosts <name>       # answer of the system resolver (what curl and the browser use)
dig +short <name>         # answer of the DNS server directly
resolvectl status         # which DNS server the laptop uses
curl --resolve <name>:80:127.0.0.1 http://<name>/   # skip DNS to test the server on its own
```

**Hostname-based routing:** Traefik receives every request on the same port 80. It reads the `Host:` header (the name typed in the browser) to pick the right environment. This is why each PR needs its own name.

## C2. Kubernetes namespaces

A namespace is a **folder** inside the cluster. Two resources can have the same name (`mysql-user`) if they're in different namespaces. Deleting a namespace deletes **everything** inside it.

```bash
kubectl get ns                         # list namespaces
kubectl get pods -n pr-12              # resources of one namespace
kubectl delete namespace pr-12         # deletes everything inside
```

In PRVue, one namespace = one pull request = one complete environment.

## C3. Deployments and Services

- A **Pod** is one or more running containers. It is temporary: it can be recreated at any time, with a new IP address.
- A **Deployment** says "I want N pods running this image". It recreates them when they crash or are deleted (that's how the MySQL restart test worked).
- A **Service** gives a group of pods a **stable name and IP** (`user-service:5001`), even when the pods change. Other pods use that name.

```bash
kubectl get deploy,svc,pods -n pr-12
kubectl logs -n pr-12 deploy/user-service
```

## C4. Ingress, Ingress controller and Traefik

- An **Ingress** is a list of **rules** (YAML): "host X, path /api/users → service user-service".
- An **Ingress controller** is the **program** that reads these rules and routes the real traffic. Without a controller, an Ingress does nothing.
- **Traefik** is the controller in PRVue. Its **Middlewares** transform requests along the way, for example `stripPrefix` removes `/api`.

Full path of a request: browser → `127.0.0.1:80` → kind node port 30080 (`extra_port_mappings` in `cluster.tf`) → Traefik (NodePort 30080) → Ingress rule → Service → Pod.

## C5. Kustomize

Kustomize **modifies** existing YAML without templates. A `kustomization.yaml` lists files (`resources`) and transformations: `namespace`, `images`, `patches`, `secretGenerator`, `replacements`.

```bash
kubectl kustomize .          # show the final YAML without applying it: always check this first
kubectl apply -k .           # build and apply
```

Helm uses templates with variables (`{{ .Values.x }}`). Kustomize starts from real, valid YAML and changes it. That makes it a good fit when the manifests already exist.

## C6. PersistentVolumes and PersistentVolumeClaims

- A container's disk disappears with the container, so MySQL needs a disk that lives longer.
- A **PersistentVolumeClaim (PVC)** is a **request**: "I need 1 GiB".
- A **PersistentVolume (PV)** is the real disk that answers the request. On kind, the `standard` StorageClass (local-path) creates it automatically in a folder on the node.
- `RECLAIMPOLICY Delete` means that when the PVC is deleted, the PV and its data are deleted too. This is what cleans up a preview's data.

```bash
kubectl get pvc -n pr-12     # STATUS Bound = a disk was attached
kubectl get pv               # all the disks of the cluster
kubectl get storageclass
```

## C7. Docker image tags

An image name is `registry/owner/name:tag`, for example `ghcr.io/sana-benz/micropizzeria-frontend:pr-12-abcd1234`.

- **`:latest`** is just a tag that is moved to each new build. Nobody knows which version is actually running.
- **A unique tag per commit** (`pr-<number>-<short sha>`) always points to the same content. You know exactly what is running, and two PRs never overwrite each other's images.

PRVue's tag contract is `pr-<number>-<first 8 chars of the head SHA>` ([D10](#d10-three-images-ghcr-and-the-tag-contract)). CI computes it as `${HEAD_SHA::8}` (bash: the first 8 characters of the variable), because ArgoCD's `head_short_sha` is 8 characters, as confirmed in the v3.5 docs. If they differ, the image is never found (`ImagePullBackOff`).

A **label on an image** (`org.opencontainers.image.source`, `...revision`) is metadata stored inside the image. GHCR uses `source` to link the package to its repository.

## C8. GitOps

Git is the **single source of truth**. You don't run `kubectl apply` by hand; a tool inside the cluster (ArgoCD) reads Git and makes the cluster match it.

**Pull model:** ArgoCD goes to GitHub to fetch the desired state. GitHub never connects to the laptop, so nothing needs to be open to the Internet. A *push* model, where CI runs `kubectl apply`, would need the cluster to be reachable from GitHub.

## C9. ArgoCD ApplicationSets

**Not implemented yet (Phase 4). This describes the plan.**

- An ArgoCD **Application** says "deploy this Git folder, at this commit, into this namespace".
- An **ApplicationSet** is an Application **factory**. A *generator* produces a list, and the ApplicationSet creates one Application per item.
- The **Pull Request generator** asks the GitHub API for PRs (here, those with the `preview-ready` label). PR #12 labeled → Application `pr-12` created. PR closed → Application deleted.
- The template uses variables such as `{{.number}}`, `{{.head_sha}}` and `{{.head_short_sha}}` (8 characters).
- The generator **polls**: `requeueAfterSeconds` sets how often. **It defaults to 30 minutes** (Argo CD v3.5 docs), so PRVue must set it lower. A webhook would remove the delay, but it would need GitHub to reach the laptop.
- Without a GitHub token, requests are anonymous and get a lower rate limit.

## C10. `pull_request` events: merge commit vs head commit

When a workflow runs on `pull_request`, GitHub creates a **temporary merge commit**: your PR merged into `main`, without actually merging anything. By default, `GITHUB_SHA` and `actions/checkout` use **that** commit.

```
main:     A───B
               \
PR branch:      C───D        ← head commit (github.event.pull_request.head.sha) = what ArgoCD deploys
                     \
merge commit:         M      ← default GITHUB_SHA / checkout
```

PRVue deploys **D** (ArgoCD's `head_sha`). If CI built **M** and tagged it with D's SHA, the image would contain code (main's B) that isn't in the commit it claims to be. That's why the workflow uses `github.event.pull_request.head.sha` everywhere: for the checkout (`ref:`), the tag, and the `revision` label (`DOCKER_METADATA_PR_HEAD_SHA: true`).

## C11. Rolling updates

When a Deployment's pod template changes (for example, a new image tag), the default `RollingUpdate` strategy replaces pods **gradually**:
1. Start a new pod with the new version (`maxSurge`: how many extra pods are allowed).
2. Wait until it's Ready.
3. Only then stop an old pod (`maxUnavailable`: how many can be missing).

With 1 replica and the defaults (25%), `maxSurge` rounds **up** to 1 and `maxUnavailable` rounds **down** to 0. Kubernetes keeps the old pod until the new one is Ready. If the new image can't be pulled, the new pod stays in `ImagePullBackOff` and **the old version keeps serving**.

The other strategy, `Recreate`, stops all old pods first. With a missing image, the app would be down.

```bash
kubectl get deploy -n pr-12 -o custom-columns=NAME:.metadata.name,STRATEGY:.spec.strategy.type
kubectl rollout status deploy/frontend -n pr-12
```
