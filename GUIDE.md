# PRVue Plateforme d'environnements de preview éphémères

Chaque pull request de **MicroPizzeria** reçoit son propre environnement Kubernetes isolé. Il est créé automatiquement, vérifié par un health check, surveillé dans Datadog, puis supprimé à la fermeture de la PR.

```
Pull request ──> GitHub Actions ──> GHCR (image pr-42-xxxxxxxx)
     ▲            build, Trivy,           ▲
     │            Checkov                 │ tire l'image
     │ lit les PR / statut + URL          │
┌────┴──────────── laptop : cluster kind (Terraform) ─────────────┐
│ ArgoCD ApplicationSet ──crée──> namespace pr-42 ──> agent Datadog │
│ (générateur Pull Request)       app + NetworkPolicy + quotas      │
└──────────────────────────────────────────────────────────────────┘
Toutes les connexions partent du laptop : aucune n'y entre.
```

**Coût : 0 €**, à condition que le dépôt soit public.

---

## Sommaire

0. [Préparer les comptes](#étape-0--préparer-les-comptes)
1. [Monter le socle local](#étape-1--monter-le-socle-local-semaines-1-et-2)
2. [Écrire les manifests de MicroPizzeria](#étape-2--écrire-les-manifests-de-micropizzeria-semaine-2)
3. [Mettre en place la CI](#étape-3--mettre-en-place-la-ci-semaine-3)
4. [Créer un environnement par PR](#étape-4--créer-un-environnement-par-pr-semaine-4)
5. [Vérifier et notifier](#étape-5--vérifier-et-notifier-semaine-5)
6. [Brancher Datadog](#étape-6--brancher-datadog-semaine-5)
7. [Mesurer et documenter](#étape-7--mesurer-et-documenter-semaine-6)
8. [Extensions](#extensions)

Chaque étape se termine par une section **Terminé quand** : ne passe à la suivante que lorsque tout est coché.

---

## Prérequis

| Outil | Rôle |
| --- | --- |
| Docker | Fait tourner les nœuds kind |
| kind | Cluster Kubernetes local |
| kubectl | Client Kubernetes |
| Terraform (ou OpenTofu) | Monte et détruit le socle |
| Helm | Utile pour inspecter les charts installés par Terraform |
| GitHub CLI (`gh`) | Ouvrir et fermer des PR de test rapidement |

Machine : 8 Go de RAM suffisent, à condition de suivre la section [Économiser la RAM](#économiser-la-ram).

---

## Structure du dépôt

```
.
├── app/                         # code de MicroPizzeria, un dossier par service
├── deploy/
│   ├── base/                    # Deployments, Services, Ingress communs
│   └── overlays/
│       └── preview/             # NetworkPolicy, quotas, health check des environnements de PR
├── platform/
│   ├── terraform/               # socle : kind, Traefik, ArgoCD, Datadog
│   │   └── values/              # fichiers values des charts Helm
│   └── argocd/
│       └── applicationset.yaml  # un environnement par PR
├── .github/workflows/ci.yml     # build, scans, publication des images
└── docs/
    ├── adr/                     # fiches de décision
    └── runbook.md
```

Ajoute dès le début un `.gitignore` contenant au minimum `*.tfstate*`, `.terraform/` et `*.tfvars`.

---

## Étape 0 — Préparer les comptes

1. **Datadog** : active l'offre du Student Pack sur la page du programme étudiant Datadog. Récupère une clé d'API et note le site de ton compte (`datadoghq.com`, `datadoghq.eu`…).
2. **Jeton GitHub pour ArgoCD** : crée un jeton *fine-grained* limité à ton dépôt, en lecture seule sur *Pull requests* et *Metadata*. Sans lui, l'API GitHub bloque vite les requêtes d'ArgoCD.
3. **Label `preview-ready`** : crée-le **une fois** dans MicroPizzeria. Tu ne le poses jamais à la main : c'est la CI qui l'ajoute, après le premier build réussi des trois images. ArgoCD ne déploie que les PR qui le portent.
   ```bash
   gh label create preview-ready -R sana-Benz/MicroPizzeria --color 0E8A16 \
     --description "Images built: PRVue can deploy this PR"
   ```
   Sans ce label, l'étape `gh pr edit --add-label` de la CI échoue.
4. **À activer plus tard seulement** : LocalStack, Doppler, le crédit Azure et le domaine Namecheap. Leur compteur démarre à l'activation.

Les secrets ne vont jamais dans le dépôt. Passe-les à Terraform par variables d'environnement :

```bash
export TF_VAR_datadog_api_key="..."
export TF_VAR_github_token="..."
```

**Terminé quand**
- [ ] Le compte Datadog est actif et la clé d'API est notée hors du dépôt
- [ ] Le jeton GitHub existe, en lecture seule
- [ ] Le label `preview-ready` existe dans MicroPizzeria

---

## Étape 1 — Monter le socle local (semaines 1 et 2)

Objectif : `terraform apply` crée le cluster kind et y installe Traefik et ArgoCD. `terraform destroy` supprime tout.

### Providers

```hcl
# platform/terraform/providers.tf
terraform {
  required_providers {
    kind       = { source = "tehcyx/kind", version = "~> 0.11" }
    helm       = { source = "hashicorp/helm", version = "~> 3.3" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.3" }   # utile à partir de l'étape 4
  }
}

provider "kubernetes" {   # utile à partir de l'étape 4
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}
```

Versions vérifiées le 2026-10-03. Attention : en version 3 du provider Helm, on écrit `kubernetes = {` **avec un `=`**. Beaucoup d'exemples sur Internet utilisent encore l'ancienne syntaxe `kubernetes {`, sans `=`, qui ne fonctionne plus.

### Cluster kind

Le port 80 de ton laptop est relié au NodePort 30080, où écoutera Traefik.

```hcl
# platform/terraform/cluster.tf
resource "kind_cluster" "this" {
  name           = "previews"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      extra_port_mappings {
        container_port = 30080
        host_port      = 80
        listen_address = "127.0.0.1"   # joignable seulement depuis le laptop, pas depuis le Wi-Fi
      }
    }
  }
}
```

### Traefik et ArgoCD

```hcl
# platform/terraform/platform.tf
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "41.6.1"
  namespace        = "traefik"
  create_namespace = true
  timeout          = 600
  values           = [file("${path.module}/values/traefik.yaml")]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.6"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600   # la première installation télécharge beaucoup d'images
  values           = [file("${path.module}/values/argocd.yaml")]
}
```

```yaml
# platform/terraform/values/traefik.yaml
deployment:
  replicas: 1
service:
  spec:
    type: NodePort      # dans les charts récents, sous service.spec (et non service.type)
ports:
  web:
    nodePort: 30080
```

```yaml
# platform/terraform/values/argocd.yaml
dex:
  enabled: false        # pas de SSO : économise de la RAM
```

Les versions des charts sont épinglées avec l'argument `version`. Avant de changer de version, vérifie les options disponibles avec `helm show values <chart> --version <x>` : les options changent de place d'une version à l'autre, et Helm **ignore sans prévenir** une option mal placée. Avec le type `LoadBalancer` (la valeur par défaut de Traefik), le Service attend pour toujours une IP externe que kind ne fournit pas, et `terraform apply` échoue sur `context deadline exceeded`.

### Lancer

```bash
cd platform/terraform
terraform init
terraform apply
kubectl get pods -A
```

**Terminé quand**
- [ ] `terraform apply` part de zéro et aboutit sans intervention
- [ ] Tous les pods de `traefik` et `argocd` sont `Running`
- [ ] `terraform destroy` puis `terraform apply` redonnent le même résultat
- [ ] Le temps de création du socle est noté (première mesure du README)

---

## Étape 2 — Écrire les manifests de MicroPizzeria (semaine 2)

Objectif : MicroPizzeria se déploie avec Kustomize dans un namespace isolé.

### Base

Dans `deploy/base/` : un Deployment et un Service par service, un Ingress nommé `micropizzeria`, et un `kustomization.yaml` qui les liste. Chaque conteneur déclare ses `requests` et `limits` de CPU et de mémoire, et expose un endpoint `/health`.

### Overlay `preview`

L'overlay ajoute l'isolation et les garde-fous. Les quatre NetworkPolicy suivantes interdisent tout par défaut, puis autorisent seulement le nécessaire.

```yaml
# deploy/overlays/preview/networkpolicies.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-traefik
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
```

Les quotas limitent chaque environnement. Ajuste les valeurs après tes premières mesures.

```yaml
# deploy/overlays/preview/quotas.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: preview-quota
spec:
  hard:
    requests.memory: 768Mi
    limits.memory: 1Gi
    pods: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: preview-defaults
spec:
  limits:
    - type: Container
      default:
        memory: 256Mi
      defaultRequest:
        memory: 128Mi
```

### Tester l'isolation

Déploie l'overlay à la main dans deux namespaces, puis vérifie qu'un environnement ne peut pas joindre l'autre :

```bash
kubectl create namespace pr-1 && kubectl apply -k deploy/overlays/preview -n pr-1
kubectl create namespace pr-2 && kubectl apply -k deploy/overlays/preview -n pr-2

# Doit réussir : même namespace
kubectl -n pr-1 run test --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- -T 3 http://<service>:<port>/health

# Doit échouer : autre namespace
kubectl -n pr-1 run test --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- -T 3 http://<service>.pr-2.svc.cluster.local:<port>/health
```

Si la seconde commande réussit, ton CNI n'applique pas les NetworkPolicy. Installe Cilium ou Calico, puis recommence le test. Capture ce test pour le README final : il prouve l'isolation mieux que les manifests.

**Terminé quand**
- [ ] MicroPizzeria répond via Traefik dans un namespace de test
- [ ] Le test d'isolation échoue entre deux namespaces et réussit dans un même namespace
- [ ] La RAM consommée par un environnement est notée

---

## Étape 3 — Mettre en place la CI (semaine 3)

Objectif du MVP : chaque PR construit les trois images de MicroPizzeria et les publie sur GHCR. Les scans (Trivy, Checkov, Gitleaks) viennent **après le MVP**, voir plus bas.

### MVP : `.github/workflows/preview.yml` (dans MicroPizzeria)

Le workflow réel est dans le dépôt MicroPizzeria. Ses règles :

| Règle | Détail |
| --- | --- |
| Déclencheurs | `pull_request` : `opened`, `synchronize` (nouveau commit), `reopened` |
| Images | 3 images construites avec les Dockerfiles existants : `frontend`, `user-service`, `order-service`. MySQL et busybox restent les images officielles, jamais reconstruites |
| Registre | `ghcr.io/sana-benz/micropizzeria-<service>` (GHCR exige des minuscules) |
| Tags | `pr-<numéro>-<8 premiers caractères du SHA>` (immuable, utilisé par les déploiements) + `pr-<numéro>` (mobile, pour les humains) |
| Commit construit | `actions/checkout` avec `ref: github.event.pull_request.head.sha` |
| Lien avec le dépôt | label d'image `org.opencontainers.image.source` (via `docker/metadata-action`) |
| Feu vert | job `label` (`needs: build`) : ajoute `preview-ready` seulement si les 3 builds ont réussi |
| Permissions | `packages: write` pour `build`, `pull-requests: write` pour `label` seulement |

**Le contrat de tag** : la CI et ArgoCD calculent le même nom chacun de leur côté, à partir du numéro de PR et du commit de tête. ArgoCD fournit `head_short_sha`, qui fait **8 caractères**. La CI calcule donc `${HEAD_SHA::8}` elle-même, jamais avec `git rev-parse --short` (7 caractères en général).

**Piège du commit de fusion** : sur un événement `pull_request`, `GITHUB_SHA` et le checkout par défaut désignent un commit de fusion temporaire (la PR fusionnée dans `main`), pas le dernier commit de la PR. Or ArgoCD déploie le dernier commit. Il faut utiliser `github.event.pull_request.head.sha` partout : checkout, tag, et label `revision` (`DOCKER_METADATA_PR_HEAD_SHA: true`).

**Une fois, après le tout premier push : vérifier que les packages sont publics.** Le cluster doit pouvoir les tirer sans identifiants. Lors du premier run (PR #4), ils étaient **déjà publics** : hypothèse, un package créé par un workflow d'un dépôt public et lié à ce dépôt en hérite la visibilité. S'ils sont privés, passe chacun des trois en public :
GitHub → ton profil → **Packages** → `micropizzeria-<service>` → **Package settings** → *Danger Zone* → **Change visibility** → **Public**.

Vérification sans être connecté (le jeton anonyme est toujours délivré, c'est la lecture du manifest qui compte) :
```bash
S=frontend; TAG=pr-4-5b6f929c
T=$(curl -s "https://ghcr.io/token?scope=repository:sana-benz/micropizzeria-$S:pull" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $T" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  "https://ghcr.io/v2/sana-benz/micropizzeria-$S/manifests/$TAG"     # 200 = public
```

**Limite connue** : les PR venues d'un fork reçoivent un `GITHUB_TOKEN` en lecture seule. Leurs images ne peuvent pas être publiées, donc elles n'ont pas de preview.

### Après le MVP : scans de sécurité

Exemple de départ, à fusionner avec le workflow du MVP :

```yaml
# .github/workflows/ci.yml
name: ci

on:
  pull_request:

permissions:
  contents: read
  packages: write

jobs:
  iac-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bridgecrewio/checkov-action@v12
        with:
          directory: .
          framework: terraform,kubernetes

  build-scan-push:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [api, front]          # adapte à tes services
    env:
      IMAGE: ghcr.io/<ton-compte-en-minuscules>/micropizzeria-${{ matrix.service }}
    steps:
      - uses: actions/checkout@v4

      - name: Calculer le tag
        env:
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
          PR: ${{ github.event.pull_request.number }}
        run: echo "TAG=pr-${PR}-${HEAD_SHA:0:8}" >> "$GITHUB_ENV"

      - name: Construire
        run: docker build -t "$IMAGE:$TAG" app/${{ matrix.service }}

      - name: Scanner l'image (bloquant)
        uses: aquasecurity/trivy-action@<version>   # voir la note ci-dessous
        with:
          image-ref: ${{ env.IMAGE }}:${{ env.TAG }}
          severity: CRITICAL,HIGH
          ignore-unfixed: true
          exit-code: "1"

      - name: Publier sur GHCR
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          docker push "$IMAGE:$TAG"
```

Trois points de sécurité, à citer en entretien :

- **Épingle chaque action tierce sur un SHA de commit complet** plutôt qu'un tag, qui peut être déplacé par un attaquant. Fais-le dès que le pipeline fonctionne.
- **Les PR venues de forks** n'obtiennent pas de jeton en écriture : leurs images ne sont pas publiées, et c'est voulu.
- **Les exceptions Checkov ou Trivy** se documentent dans le code, avec une justification, jamais en désactivant le scan.

**Détection de secrets avec Gitleaks** : un job `secret-scan` analyse chaque PR avec Gitleaks et bloque le pipeline si un secret (token, clé, mot de passe) est détecté. Ajoute-le dans les deux dépôts, PRVue et MicroPizzeria. En complément, un hook *pre-commit* local bloque le commit avant même qu'il quitte le laptop. Avec le `.gitignore`, cela fait trois couches de protection : c'est la **défense en profondeur**.

**Terminé quand (MVP)**
- [ ] Une PR de test produit les 3 images taguées `pr-<numéro>-<sha8>` et `pr-<numéro>` dans GHCR
- [ ] Les 3 packages sont publics et liés au dépôt MicroPizzeria
- [ ] La PR reçoit le label `preview-ready`, et seulement si les 3 builds ont réussi
- [ ] Un nouveau commit produit un nouveau tag `pr-<numéro>-<sha8>`

**Terminé quand (après le MVP)**
- [ ] Une vulnérabilité volontaire, par exemple une vieille image de base, fait échouer le pipeline
- [ ] Une erreur Terraform volontaire fait échouer Checkov
- [ ] Les actions sont épinglées par SHA
- [ ] Un faux token volontairement ajouté fait échouer le job Gitleaks

---

## Étape 4 — Créer un environnement par PR (semaine 4)

Objectif : une PR dont les images sont construites (label `preview-ready`) obtient le namespace `pr-<numéro>` ; la fermer le supprime.

**Vérifié dans la documentation d'Argo CD v3.5** (avant d'écrire l'ApplicationSet) :
- `head_short_sha` fait 8 caractères (`head_short_sha_7` existe aussi : ne pas l'utiliser).
- Le générateur filtre sur les labels, les branches et le titre, **pas sur le statut de la CI**. D'où le label `preview-ready`.
- `requeueAfterSeconds` vaut **30 minutes par défaut** : il faut le fixer (ici 120 s).
- Le contrôleur d'ApplicationSet ajoute lui-même le finalizer `resources-finalizer.argocd.argoproj.io` aux Applications générées : supprimer l'Application supprime ses ressources. À vérifier en phase 5 (`kubectl get application -n argocd pr-<n> -o yaml`).
- Un namespace créé par `CreateNamespace=true` n'est pas suivi par ArgoCD, donc pas supprimé. C'est pour ça que MicroPizzeria contient son propre `namespace.yaml`.
- La doc ne dit pas clairement si le générateur GitHub ne liste que les PR ouvertes : à tester en phase 5.

**À respecter en écrivant l'ApplicationSet :**
- **Jeton GitHub obligatoire (`tokenRef`).** Sans jeton, l'API GitHub limite à 60 requêtes par heure. Avec un passage toutes les 120 s, ça tient, mais sans aucune marge. Avec un jeton : 5 000 par heure.
- **Toujours fixer `kustomize.namespace: "pr-{{.number}}"`.** Sans lui, Kustomize garde le namespace de base, `micropizzeria`, **partagé par toutes les PR** : fermer une PR supprimerait l'environnement des autres. `missingkey=error` ne protège **pas** contre un oubli de cette ligne : il ne détecte que les variables de template inexistantes (par exemple une faute de frappe dans `{{.numbr}}`).
- **La vraie protection : un projet ArgoCD dédié (`AppProject`)**. **Testé sur le cluster (2026-11-16)** :
  ```yaml
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "pr-*"
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
      name: "pr-*"        # Argo CD v3.5 accepte un motif de nom
  ```
  Sans l'override, la synchronisation est **refusée** et rien n'est créé : `namespace micropizzeria is not permitted in project ...; resource :Namespace is not permitted in project ...`. Avec l'override (`pr-98`), elle réussit. ArgoCD vérifie donc le namespace **de chaque ressource**, et le nom de l'objet `Namespace`.
- Rendu vérifié avec le kustomize d'ArgoCD (v5.8.1, dans le pod `argocd-repo-server`) : avec `edit set namespace pr-99`, les 26 ressources et les sujets des RoleBindings sont dans `pr-99`, l'objet `Namespace` s'appelle `pr-99`, et il ne reste ni `default` ni `micropizzeria`.

**Pas de webhook** : le cluster n'écoute que sur `127.0.0.1`, GitHub ne peut pas le prévenir. Délai attendu entre un push et la mise à jour de la preview = durée de la CI + jusqu'à 120 s (passage du générateur) + éventuellement le délai de réessai du pull d'image (jusqu'à environ 5 minutes si ArgoCD a vu le commit avant la fin de la CI).

Crée d'abord le secret du jeton GitHub, via Terraform avec `TF_VAR_github_token` :

```hcl
# platform/terraform/secrets.tf
variable "github_token" {
  type      = string
  sensitive = true
}

resource "kubernetes_secret" "github_token" {
  metadata {
    name      = "github-token"
    namespace = "argocd"
  }
  data = {
    token = var.github_token
  }
  depends_on = [helm_release.argocd]
}
```

Le secret apparaît en clair dans le fichier d'état Terraform : garde ce fichier local et ignoré par Git. L'extension Doppler règlera ce point.

```yaml
# platform/argocd/applicationset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: micropizzeria-previews
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - pullRequest:
        github:
          owner: <ton-compte>
          repo: <ton-depot>
          tokenRef:
            secretName: github-token
            key: token
          labels:
            - preview-ready          # posé par la CI quand les 3 images existent
        requeueAfterSeconds: 120     # défaut : 30 minutes
  template:
    metadata:
      name: "pr-{{.number}}"
    spec:
      project: previews      # AppProject limité à pr-* (voir plus haut), jamais "default"
      source:
        repoURL: https://github.com/<ton-compte>/<ton-depot>.git
        targetRevision: "{{.head_sha}}"   # manifests du même commit que les images
        path: .                           # kustomization.yaml à la racine de MicroPizzeria
        kustomize:
          namespace: "pr-{{.number}}"     # en déduit aussi le host et le middleware (replacements)
          images:
            - "sanabns/frontend=ghcr.io/sana-benz/micropizzeria-frontend:pr-{{.number}}-{{.head_short_sha}}"
            - "sanabns/user-service=ghcr.io/sana-benz/micropizzeria-user-service:pr-{{.number}}-{{.head_short_sha}}"
            - "sanabns/order-service=ghcr.io/sana-benz/micropizzeria-order-service:pr-{{.number}}-{{.head_short_sha}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "pr-{{.number}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Applique-le, puis teste :

```bash
kubectl apply -f platform/argocd/applicationset.yaml
gh pr create --title "test preview" --body "test"     # la CI posera preview-ready
kubectl get applications -n argocd -w
```

**Limites acceptées pour le MVP** (le label n'est posé qu'une fois, il protège seulement le premier déploiement) :
- **Commits suivants : `ImagePullBackOff` pendant quelques minutes.** ArgoCD voit le nouveau commit avant que la CI ait publié ses images. Le Deployment démarre le nouveau pod *avant* de supprimer l'ancien (RollingUpdate, aucun Deployment n'utilise `Recreate`) : l'ancienne version continue de répondre. Kubernetes réessaie avec un délai croissant (jusqu'à environ 5 minutes entre deux essais), donc le passage à la nouvelle version peut arriver quelques minutes après la fin de la CI.
- **Build en échec sur un commit suivant** : l'ancienne version reste en ligne, le nouveau pod reste bloqué, et l'Application apparaît *Degraded* dans ArgoCD. C'est un signal visible ; le commit suivant qui réussit répare tout.

**Terminé quand**
- [ ] Une PR qui reçoit `preview-ready` crée `pr-<numéro>` en moins de 5 minutes environ
- [ ] L'application répond sur `http://pr-<numéro>.127-0-0-1.nip.io`
- [ ] Un nouveau commit sur la PR redéploie la nouvelle image, dans le même namespace
- [ ] Fermer la PR supprime l'application et le namespace
- [ ] Une PR dont le build a échoué (pas de label) ne crée rien

---

## Étape 5 — Vérifier et notifier (semaine 5)

### Health check après déploiement

Ajoute ce Job à l'overlay `preview`. ArgoCD le lance après chaque synchronisation ; s'il échoue, la synchronisation est marquée en échec.

```yaml
# deploy/overlays/preview/healthcheck.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: healthcheck
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: check
          image: curlimages/curl:8.10.1
          args: ["-fsS", "--retry", "10", "--retry-delay", "5", "--retry-all-errors",
                 "http://<service>:<port>/health"]
          resources:
            requests: { memory: 16Mi }
            limits: { memory: 32Mi }
```

### Retour sur la PR

Le service GitHub d'ArgoCD Notifications publie un statut de commit et un commentaire avec l'URL. Il s'authentifie avec une **GitHub App**, gratuite, que tu crées toi-même :

1. Crée une GitHub App avec les permissions *Commit statuses* et *Pull requests* en écriture, puis installe-la sur ton dépôt.
2. Note l'App ID et l'Installation ID, et génère une clé privée.
3. Ajoute la clé dans le secret `argocd-notifications-secret`, et déclare le service GitHub dans `argocd-notifications-cm`, via les values du chart ArgoCD.
4. Abonne l'ApplicationSet aux déclencheurs `on-deployed` et `on-health-degraded` avec une annotation dans le template.

Suis la documentation officielle d'ArgoCD Notifications, section *GitHub*, pour la syntaxe exacte : elle évolue selon les versions.

**Terminé quand**
- [ ] Un health check en échec marque l'application en erreur dans ArgoCD
- [ ] La PR affiche un statut et un commentaire avec l'URL de l'environnement

---

## Étape 6 — Brancher Datadog (semaine 5)

Ajoute l'agent au socle Terraform :

```hcl
resource "kubernetes_secret" "datadog" {
  metadata {
    name      = "datadog-secret"
    namespace = "datadog"
  }
  data = {
    "api-key" = var.datadog_api_key
  }
  depends_on = [kubernetes_namespace.datadog]
}

resource "helm_release" "datadog" {
  name       = "datadog"
  repository = "https://helm.datadoghq.com"
  chart      = "datadog"
  namespace  = "datadog"
  values     = [file("${path.module}/values/datadog.yaml")]
  depends_on = [kubernetes_secret.datadog]
}
```

Déclare aussi la variable `datadog_api_key` et une ressource `kubernetes_namespace.datadog`, sur le modèle de l'étape 4.

```yaml
# platform/terraform/values/datadog.yaml
datadog:
  apiKeyExistingSecret: datadog-secret
  site: datadoghq.com          # selon la région de ton compte
  clusterName: previews
  kubelet:
    tlsVerify: false           # nécessaire sur kind
  logs:
    enabled: true
    containerCollectAll: true
```

Dans Datadog, crée :

- un dashboard avec une variable `kube_namespace`, montrant la mémoire, le CPU et les redémarrages de pods par environnement ;
- une alerte quand un namespace `pr-*` approche de son quota mémoire.

**Terminé quand**
- [ ] Les métriques et les logs de chaque `pr-<numéro>` sont visibles et filtrables
- [ ] L'alerte se déclenche lors d'un test volontaire

---

## Étape 7 — Mesurer et documenter (semaine 6)

Relève tes vrais chiffres et remplace ce guide par le README final.

| Mesure | Méthode |
| --- | --- |
| Temps entre ouverture de la PR et environnement prêt | Horodatage de la PR et du statut posté par ArgoCD |
| Temps de suppression après fermeture | Même méthode |
| RAM par environnement | Dashboard Datadog |
| Environnements simultanés tenables sur 8 Go | Ouvrir des PR jusqu'à saturation |
| Vulnérabilités bloquées par les gates | Historique des pipelines en échec |

À livrer :

- [ ] README final : schéma, démarrage en une commande, mesures, coûts
- [ ] Vidéo de 2 minutes : ouverture de PR, environnement prêt, URL sur la PR, fermeture, suppression
- [ ] Fiches de décision dans `docs/adr/` : modèle pull plutôt que push, ApplicationSet plutôt que Terraform par PR, namespace plutôt que vcluster, Datadog plutôt que Prometheus, kind plutôt qu'un cluster cloud permanent, Traefik plutôt qu'ingress-nginx
- [ ] `docs/runbook.md` : que faire si un environnement reste bloqué en création

---

## Extensions

À ajouter pendant les candidatures, dans cet ordre :

1. **Secrets avec Doppler** et son opérateur Kubernetes : plus aucun secret dans le fichier d'état Terraform.
2. **Suppression des environnements inactifs** et plafond d'environnements simultanés.
3. **Terraform AWS sur LocalStack** : backend d'état S3, registre ECR, testés sans facture.
4. **Démo sur Azure AKS** avec le crédit étudiant, avec une alerte de budget et une destruction le jour même.
5. **Revue du plan Terraform par un LLM**, commentée dans la PR.

---

## Économiser la RAM

- Garde au plus deux PR ouvertes en même temps : chaque PR dont le build réussit obtient un environnement (environ 1,3 Gio).
- Arrête le cluster en fin de session avec `terraform destroy`, et recrée-le avec `terraform apply`.
- Ferme les applications lourdes pendant les sessions de travail.
- Pour les sessions lourdes, travaille dans GitHub Codespaces, inclus dans le Student Pack, dans la limite de son quota mensuel.

---

## Dépannage rapide

| Symptôme | Piste |
| --- | --- |
| Pods en `ImagePullBackOff` | La CI n'a pas fini, le tag ne correspond pas aux 8 caractères du SHA, ou l'image est privée |
| Aucun environnement créé | Label `preview-ready` absent (build en échec ? label jamais créé ?), jeton GitHub invalide, ou délai de 2 minutes pas encore écoulé |
| L'URL ne répond pas | Vérifie le port 80 du laptop, le NodePort 30080 de Traefik et l'hôte de l'Ingress |
| Le test d'isolation réussit alors qu'il devrait échouer | Le CNI n'applique pas les NetworkPolicy |
| Pods en `Pending` | Quota atteint, ou machine saturée : ferme une PR |
