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
3. **Label `preview`** : crée ce label dans ton dépôt. Seules les PR qui le portent recevront un environnement, ce qui protège ta RAM.
4. **À activer plus tard seulement** : LocalStack, Doppler, le crédit Azure et le domaine Namecheap. Leur compteur démarre à l'activation.

Les secrets ne vont jamais dans le dépôt. Passe-les à Terraform par variables d'environnement :

```bash
export TF_VAR_datadog_api_key="..."
export TF_VAR_github_token="..."
```

**Terminé quand**
- [ ] Le compte Datadog est actif et la clé d'API est notée hors du dépôt
- [ ] Le jeton GitHub existe, en lecture seule
- [ ] Le label `preview` existe

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

Objectif : chaque PR construit les images, les scanne, scanne l'IaC, et publie les images sur GHCR. Tout échec de scan bloque le pipeline.

L'image est taguée `pr-<numéro>-<8 premiers caractères du SHA>`. C'est le format que lira ArgoCD. Attention : sur un événement `pull_request`, `GITHUB_SHA` désigne un commit de fusion, pas le dernier commit de la PR. Il faut utiliser `github.event.pull_request.head.sha`.

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

Rends les images publiques dans les réglages de packages GitHub, pour que le cluster puisse les tirer sans identifiants.

**Terminé quand**
- [ ] Une PR de test produit des images taguées dans GHCR
- [ ] Une vulnérabilité volontaire, par exemple une vieille image de base, fait échouer le pipeline
- [ ] Une erreur Terraform volontaire fait échouer Checkov
- [ ] Les actions sont épinglées par SHA
- [ ] Un faux token volontairement ajouté fait échouer le job Gitleaks

---

## Étape 4 — Créer un environnement par PR (semaine 4)

Objectif : ouvrir une PR avec le label `preview` crée le namespace `pr-<numéro>` ; la fermer le supprime.

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
            - preview
        requeueAfterSeconds: 120
  template:
    metadata:
      name: "pr-{{.number}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/<ton-compte>/<ton-depot>.git
        targetRevision: "{{.head_sha}}"
        path: deploy/overlays/preview
        kustomize:
          images:
            - "ghcr.io/<ton-compte>/micropizzeria-api:pr-{{.number}}-{{.head_short_sha}}"
          patches:
            - target:
                kind: Ingress
                name: micropizzeria
              patch: |-
                - op: replace
                  path: /spec/rules/0/host
                  value: pr-{{.number}}.127.0.0.1.nip.io
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
gh pr create --title "test preview" --body "test" --label preview
kubectl get applications -n argocd -w
```

Si ArgoCD synchronise avant la fin de la CI, les pods restent un moment en `ImagePullBackOff`, puis démarrent dès que l'image existe. C'est normal ; note-le dans une fiche de décision.

**Terminé quand**
- [ ] Une PR avec le label `preview` crée `pr-<numéro>` en moins de 5 minutes environ
- [ ] L'application répond sur `http://pr-<numéro>.127.0.0.1.nip.io`
- [ ] Un nouveau commit sur la PR redéploie la nouvelle image
- [ ] Fermer la PR supprime l'application et le namespace
- [ ] Une PR sans le label ne crée rien

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

- Garde au plus deux PR avec le label `preview` ouvertes en même temps.
- Arrête le cluster en fin de session avec `terraform destroy`, et recrée-le avec `terraform apply`.
- Ferme les applications lourdes pendant les sessions de travail.
- Pour les sessions lourdes, travaille dans GitHub Codespaces, inclus dans le Student Pack, dans la limite de son quota mensuel.

---

## Dépannage rapide

| Symptôme | Piste |
| --- | --- |
| Pods en `ImagePullBackOff` | La CI n'a pas fini, le tag ne correspond pas aux 8 caractères du SHA, ou l'image est privée |
| Aucun environnement créé | Label `preview` absent, jeton GitHub invalide, ou délai de 2 minutes pas encore écoulé |
| L'URL ne répond pas | Vérifie le port 80 du laptop, le NodePort 30080 de Traefik et l'hôte de l'Ingress |
| Le test d'isolation réussit alors qu'il devrait échouer | Le CNI n'applique pas les NetworkPolicy |
| Pods en `Pending` | Quota atteint, ou machine saturée : ferme une PR |
