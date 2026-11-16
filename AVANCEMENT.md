# Avancement du projet PRVue

Journal de ce qui a été fait, avec le pourquoi de chaque choix.

---

## Organisation choisie

PRVue déploie automatiquement ma propre application, **MicroPizzeria**, réalisée lors d'un projet précédent.

| Dépôt | Contenu | Rôle |
| --- | --- | --- |
| `sana-Benz/MicroPizzeria` | L'application (frontend, user-service, order-service) | Les pull requests ouvertes ici déclencheront les previews |
| `PRVue` | La plateforme (Terraform, ArgoCD) | Surveille les PR de MicroPizzeria et crée un environnement par PR |

**Pourquoi deux dépôts plutôt que copier MicroPizzeria dans PRVue ?**
- Pas de code en double à maintenir à deux endroits.
- Un dépôt Git imbriqué dans un autre pose des problèmes.
- Ça reproduit le fonctionnement en entreprise : une équipe plateforme d'un côté, des équipes applicatives de l'autre.

---

## Fait le 2026-10-02

### 1. Sauvegarde de l'ancienne version de MicroPizzeria (tag Git)

Avant de modifier MicroPizzeria pour PRVue, j'ai posé un **tag** sur sa version actuelle (celle déployée avec Minikube).

```bash
cd ~/MicroPizza
git tag v1-minikube
git push origin v1-minikube
```

- Un **tag** est une étiquette fixe sur un commit : contrairement à une branche, il ne bouge jamais.
- Il pointe sur le commit `e64028a` (« adding project report »).
- Visible sur GitHub : menu déroulant `main` → onglet **Tags**.

**Vérifier :**
```bash
git tag                        # tags locaux
git ls-remote --tags origin    # tags présents sur GitHub
```

**À retenir :** pas besoin de dupliquer un projet pour garder une ancienne version, l'historique Git et les tags s'en chargent.

### 2. Protection de la branche `main` de MicroPizzeria

Créée sur GitHub : **Settings → Rules → Rulesets → New branch ruleset**.

| Réglage | Valeur |
| --- | --- |
| Nom | `protect-main` |
| Statut | Active |
| Cible | Branche par défaut (`main`) |
| Restrict deletions | ✅ personne ne peut supprimer `main` |
| Block force pushes | ✅ personne ne peut réécrire l'historique |
| Require a pull request before merging | ✅ avec **0 approbation requise** |

- Seuls le propriétaire et les collaborateurs invités peuvent pousser sur un dépôt. La protection sert surtout contre **mes propres erreurs** (force push, suppression accidentelle).
- **0 approbation** : en travaillant seule, je ne peux pas approuver ma propre PR. Avec 1 approbation obligatoire, je serais bloquée.
- Passer par des PR est exactement le fonctionnement dont PRVue a besoin : chaque PR créera un environnement de preview.
- Les rulesets sont appliqués gratuitement sur les dépôts **publics** (c'est le cas).

**Vérifié** avec l'API GitHub : les règles `deletion`, `non_fast_forward` (force push) et `pull_request` sont actives sur `main`.

**Plus tard :** ajouter *Require status checks to pass* quand la CI existera.

**Remarque :** le dépôt a été renommé de `MicroPizza-` en `MicroPizzeria`. Pour mettre à jour l'adresse locale :
```bash
git remote set-url origin git@github.com:sana-Benz/MicroPizzeria.git
```

### 3. Installation des outils

Système : Ubuntu 24.04, x86_64.

| Outil | Version | Rôle | Installation |
| --- | --- | --- | --- |
| kubectl | v1.35.1 | « Télécommande » de Kubernetes | Déjà installé |
| kind | v0.33.0 | Cluster Kubernetes local, dont les nœuds sont des conteneurs Docker | Binaire téléchargé dans `/usr/local/bin` |
| Terraform | v1.16.5 | Infrastructure as Code : créer et détruire le socle en une commande | Dépôt apt officiel HashiCorp |
| Helm | v4.3.0 | Gestionnaire de paquets de Kubernetes (installe Traefik, ArgoCD…) | `snap` |
| gh | v2.102.0 | GitHub en ligne de commande (ouvrir et fermer des PR de test) | Dépôt apt officiel GitHub |

- `gh auth login` : connexion via le navigateur, protocole **SSH**. L'étape « Upload your SSH public key » a été passée (**Skip**), car ma clé `~/.ssh/id_ed25519.pub` était déjà enregistrée sur GitHub.
- Ne jamais partager un token (`gho_...`) en entier.

**Vérifier :**
```bash
kind version; terraform version | head -1; helm version --short; gh --version | head -1; kubectl version --client | head -1; gh auth status
```

## Fait le 2026-10-03

### 4. Création du dépôt PRVue

- Dépôt GitHub `sana-Benz/PRVue`, **privé pour l'instant**. À passer en public quand il sera présentable (visibilité pour les recruteurs, et ruleset appliqué gratuitement seulement sur les dépôts publics).
- Le guide du projet a été renommé `GUIDE.md` : `README.md` sera la vitrine finale du projet.
- `.gitignore` : `*.tfstate`, `*.tfstate.*`, `.terraform/`, `*.tfvars`. Le state Terraform et les fichiers de variables peuvent contenir des secrets.

```bash
git init -b main
git remote add origin git@github.com:sana-Benz/PRVue.git
git pull origin main
```

### 5. Choix : local d'abord, Azure à la fin

- Terraform ne sert pas qu'au cloud : il pilote tout ce qui a un **provider** (kind, Azure, GitHub, Datadog…).
- Tout est construit en **local avec kind** : gratuit, sans limite, et les erreurs sont sans conséquence.
- Le **crédit Azure étudiant (100 $)** est gardé pour la fin (extension 4 du guide) : on remplacera seulement la ressource du cluster (`kind_cluster` → `azurerm_kubernetes_cluster`) pour une démo, puis on détruira tout le jour même. Ne pas l'activer avant.

### 6. Le cluster kind en Terraform

Fichiers dans `platform/terraform/` :

| Fichier | Rôle |
| --- | --- |
| `providers.tf` | Déclare le provider `tehcyx/kind`, version `~> 0.11` (toute version 0.11.x) |
| `cluster.tf` | Décrit le cluster `previews` : 1 node control-plane, et le port 80 du laptop relié au port 30080 du node |

```bash
cd platform/terraform
terraform init       # télécharge le provider
terraform plan       # "Plan: 1 to add" → va créer le cluster
terraform apply      # crée le cluster
terraform apply      # relancé : "No changes", le cluster existe déjà
terraform destroy    # supprime tout
terraform apply      # recrée à l'identique
```

- **`extra_port_mappings`** : le node est une boîte Docker fermée. On « perce un trou » entre le port 80 du laptop et le port 30080 du node, où écoutera Traefik. Visible avec `docker ps` : `0.0.0.0:80->30080/tcp`.
- **`listen_address = "127.0.0.1"`** : sans cette ligne, le port 80 écoutait sur `0.0.0.0` (toutes les interfaces), donc il était joignable par les autres appareils du même Wi-Fi. Maintenant, seul le laptop y accède (`docker ps` : `127.0.0.1:80->30080/tcp`). Ce changement a forcé la recréation du cluster (« forces replacement »).
- **Décrire son infrastructure n'est pas un risque** : le plan peut être public, seules les clés doivent rester secrètes. Cacher le plan s'appelle la « sécurité par l'obscurité », et ça ne protège pas.
- **Terraform décrit un résultat** : relancer `apply` ne recrée pas le cluster. À la main, `kind create cluster` aurait donné une erreur « already exists ».

**Fichiers générés par Terraform :**

| Fichier | Sur GitHub ? | Pourquoi |
| --- | --- | --- |
| `.terraform/` | ❌ | Providers téléchargés, lourds et re-téléchargeables |
| `terraform.tfstate` (+ `.backup`) | ❌ | La mémoire de Terraform, peut contenir des secrets |
| `.terraform.lock.hcl` | ✅ | Fige la version exacte des providers : tout le monde utilise les mêmes |
| `previews-config` | ❌ | Kubeconfig créé par le provider kind = **clé d'accès au cluster**. Ajouté au `.gitignore` (`*-config`) |
| `.terraform.tfstate.lock.info` | ❌ | Verrou temporaire pendant un `apply`, disparaît tout seul |

**À retenir :** toujours lancer `git status` avant un commit pour vérifier qu'aucun fichier sensible ne part sur GitHub.

### 7. Traefik et ArgoCD installés avec Terraform

Le socle a trois morceaux : le **cluster** (le bâtiment), **Traefik** (l'accueil, qui dirige les visiteurs selon les règles Ingress) et **ArgoCD** (le gérant, qui surveillera GitHub et installera une copie de MicroPizzeria par PR).

| Fichier | Rôle |
| --- | --- |
| `providers.tf` | Ajout du provider `hashicorp/helm` (`~> 3.3`) et de sa connexion au cluster : adresse (`host`) + badge (`client_certificate`, `client_key`) + vérification du cluster (`cluster_ca_certificate`), tous pris dans `kind_cluster.this` |
| `platform.tf` | Deux `helm_release` : Traefik (chart `41.6.1`) et ArgoCD (chart `10.9.6`), chacun dans son namespace, avec versions épinglées et `timeout = 600` |
| `values/traefik.yaml` | 1 réplica, Service en **NodePort**, port `web` sur **30080** (la porte ouverte dans `cluster.tf`) |
| `values/argocd.yaml` | `dex` désactivé : pas de connexion GitHub/Google, donc moins de RAM |

- Terraform lit **tous les `.tf` du dossier ensemble**. Les noms de fichiers servent seulement à ranger.
- La référence `kind_cluster.this.endpoint` crée une **dépendance** : Terraform s'occupe d'abord du cluster, ensuite des installations.
- Chemin d'une requête : navigateur → port 80 du laptop → `extra_port_mappings` → port 30080 du node → `nodePort` de Traefik → (plus tard) MicroPizzeria.

**Vérifier :**
```bash
kubectl get svc -n traefik      # TYPE NodePort, 80:30080
terraform state list            # helm_release.argocd, helm_release.traefik, kind_cluster.this
curl http://localhost           # "404 page not found" = le chemin complet fonctionne, mais aucune règle Ingress n'existe encore
```

**Incident et débogage (bon exemple pour un entretien) :**
1. `terraform apply` a échoué sur Traefik : `context deadline exceeded` (délai dépassé).
2. Fausse piste : la lenteur des téléchargements. Ajouter du temps n'a rien changé.
3. Le réflexe qui a trouvé la cause : regarder ce que Kubernetes avait **réellement** créé avec `kubectl get all -n traefik`. Le Service était en `LoadBalancer`, avec `EXTERNAL-IP <pending>`.
4. **Cause** : dans le chart Traefik 41.x, l'option est `service.spec.type`, et non plus `service.type` (l'ancienne structure du guide). Helm a **ignoré sans prévenir** l'option mal placée et gardé la valeur par défaut, `LoadBalancer`. Sur kind, aucun fournisseur cloud ne donne d'IP externe, donc Helm attendait pour toujours.
5. **Correction** : `service.spec.type: NodePort` dans les values, puis `helm uninstall traefik -n traefik` (la release en échec n'était pas dans le state Terraform et bloquait le nom), puis `terraform apply`.

**À retenir :**
- Toujours lire la fin de `terraform apply`, les erreurs sont faciles à rater.
- `terraform state list` montre ce que Terraform gère. Ce qui tourne sans y figurer lui échappe.
- Vérifier les options d'un chart dans **sa version exacte** : `helm show values traefik/traefik --version 41.6.1`.
- Une erreur peut cacher la vraie cause : il faut observer l'état réel avant de corriger.

## Fait le 2026-11-16

### 8. Vérification du socle : ArgoCD manquait

Avant de construire le MVP, vérification de ce qui tourne **réellement** :

| Vérification | Résultat |
| --- | --- |
| `kubectl get nodes` | `previews-control-plane` Ready ✅ |
| `curl http://localhost` | `404` : Traefik répond ✅ |
| `terraform state list` | `kind_cluster.this`, `helm_release.traefik`… mais **pas** `helm_release.argocd` ❌ |
| `terraform plan` | `Plan: 1 to add` → ArgoCD n'avait jamais été installé |

- Pas de release en échec, pas de namespace `argocd` : rien à nettoyer, l'`apply` n'était simplement jamais allé jusqu'à ArgoCD.
- Correction : `terraform plan -out=...` puis `terraform apply` **de ce plan précis** (1 ajout, 0 destruction). ArgoCD installé en **48 s**.

**Vérifié :**
```bash
kubectl get pods -n argocd                         # 6 pods Running, dont argocd-applicationset-controller
kubectl get crd | grep argoproj                    # applications, applicationsets, appprojects
terraform plan -detailed-exitcode                  # code 0 : plus aucune différence
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080 → HTTP 200, ArgoCD v3.5.3
```

**À retenir :** un commit ne prouve pas que l'infrastructure existe. `terraform plan` compare le code à la réalité : s'il propose d'ajouter quelque chose, c'est que ça n'existe pas.

### 9. Manifests de MicroPizzeria pour les previews (Kustomize)

**Choix : réutiliser les fichiers `k8s/` existants sur place, sans dossier `deploy/`.** Un seul `kustomization.yaml` à la racine de MicroPizzeria liste les fichiers là où ils sont. ArgoCD n'a besoin que d'un chemin : `.`.

| Fichier (dans MicroPizzeria) | Changement |
| --- | --- |
| `*/k8s/*.yaml`, `rbac.yaml` | **Aucun** |
| `ingress.yaml` | Modifié : Nginx → Traefik (`ingressClassName: traefik`, chemins `Prefix`, un `host` par environnement, TLS retiré) |
| `kustomization.yaml` | Nouveau : liste des fichiers + réglages des previews |
| `namespace.yaml` | Nouveau : le namespace fait partie de l'application, donc ArgoCD pourra le supprimer |
| `traefik-middleware.yaml` | Nouveau : `stripPrefix /api`, remplace le `rewrite-target` de Nginx |

**Une seule entrée : le namespace.** On change `namespace: micropizzeria` en `pr-12`, et Kustomize en déduit tout le reste :
- le namespace de chaque ressource (il remplace même les `namespace: default` écrits dans les fichiers, y compris dans les `RoleBinding`) ;
- le nom de la ressource `Namespace` ;
- le host `pr-12.127-0-0-1.nip.io` et la référence au middleware `pr-12-strip-api@kubernetescrd` (avec `replacements`).

Autres réglages du `kustomization.yaml` :
- `secretGenerator` : crée `user-service-secret` et `order-service-secret` avec des valeurs **jetables** (`preview-only-not-a-secret`). Chaque preview a ses propres bases, supprimées avec la PR. Les vrais `secret.yaml` restent hors de Git. `disableNameSuffixHash` garde les noms exacts utilisés par les deployments et `rbac.yaml`.
- `imagePullPolicy: IfNotPresent` : un tag de preview (`pr-12-abcd1234`) ne change jamais, inutile de le retélécharger.
- Les images restent `sanabns/*:latest` dans les fichiers ; ArgoCD les remplacera par `ghcr.io/sana-benz/micropizzeria-<service>:pr-<numéro>-<sha>`.

**Test manuel (en simulant ArgoCD)** : copie du dépôt, `namespace: pr-1` (puis `pr-2`) et bloc `images:` ajoutés, images construites en local et chargées avec `kind load docker-image`, puis `kubectl apply -k .`.

| Vérification | Résultat |
| --- | --- |
| Pods dans `pr-1` et `pr-2` | 5 + 5 `Running`, 2 PVC `Bound` par namespace |
| Frontend, CSS, `/api/menu` sur chaque URL | 200, 17 articles |
| pr-1 : inscription, connexion, `/api/users/me`, commande, historique | 201, 200, 200, 201, 1 commande |
| Connexion d'alice (créée dans pr-1) sur pr-2 | **401** : bases indépendantes ✅ |
| Redémarrage de MySQL | Les données restent (PVC) ✅ |
| `kubectl delete namespace pr-1` | Supprimé en 16 s **avec ses PV** ; pr-2 répond toujours ✅ |

**Incident 1 : nip.io lisait mal l'adresse.** `pr-1.127.0.0.1.nip.io` donnait l'IP `1.127.0.0` : nip.io prend les 4 premiers nombres du nom, et le `1` de `pr-1` en faisait partie. Même problème avec sslip.io. Repéré avec `getent hosts`, et confirmé avec `curl --resolve` (Traefik répondait bien 200). **Correction** : IP écrite avec des tirets, `pr-12.127-0-0-1.nip.io`. README et GUIDE mis à jour.

**Incident 2 : une erreur 500 juste après un redémarrage de MySQL.** Log : `Lost connection to MySQL server`. Le user-service garde des connexions ouvertes vers l'**ancien** pod MySQL ; la première requête échoue, les suivantes marchent. Comportement existant de l'application, pas lié à PRVue. Non corrigé pour le MVP ; correction possible plus tard : `SQLALCHEMY_ENGINE_OPTIONS = {"pool_pre_ping": True}` dans `config.py`.

**À retenir :**
- Tester une hypothèse sur une copie jetable avant de toucher au vrai dépôt.
- « Running » ne prouve pas que l'application marche : tester le vrai parcours utilisateur.
- Quand un test échoue, lire le log avant de conclure.

### 10. Workflow GitHub Actions des images (écrit, pas encore exécuté)

Fichier : `.github/workflows/preview.yml` dans MicroPizzeria. Les décisions sont détaillées dans PROBLEMS.md (D10 à D13).

- 3 images (`frontend`, `user-service`, `order-service`) construites à chaque `opened`, `synchronize`, `reopened`, publiées sur `ghcr.io/sana-benz/micropizzeria-<service>`.
- Tags : `pr-<numéro>-<8 caractères du SHA>` (immuable) + `pr-<numéro>` (mobile). Checkout et tag à partir de `github.event.pull_request.head.sha`, jamais du commit de fusion.
- Job `label` (`needs: build`) : ajoute `preview-ready` seulement si les 3 builds réussissent. Le label est posé une fois et jamais retiré.

**Vérifié :**
- YAML lu par Python : 2 jobs, `label` dépend de `build`, permissions séparées.
- Calcul du tag en bash : `pr-12-db9fec4c` (8 caractères ; `git rev-parse --short` en donnait 7).
- Aucun Deployment n'utilise `Recreate` : les 5 sont en `RollingUpdate` (vu sur `pr-2`).
- Doc Argo CD v3.5 : `head_short_sha` fait 8 caractères ; pas de filtre sur le statut de la CI ; `requeueAfterSeconds` vaut 30 min par défaut ; le finalizer est ajouté par le contrôleur d'ApplicationSet ; un namespace créé par `CreateNamespace=true` n'est pas supprimé.

**Pas encore vérifié :** le workflow n'a jamais tourné (il faut une PR). `actionlint` (outil de vérification des workflows) n'a pas pu être lancé : la commande Docker a été refusée par les permissions de Claude Code.

**À faire avant la PR du workflow :**
```bash
gh label create preview-ready -R sana-Benz/MicroPizzeria --color 0E8A16 \
  --description "Images built: PRVue can deploy this PR"
```
Après le premier push : passer les 3 packages GHCR en public (GUIDE, étape 3).

**Résultat du premier run (PR #4)** : les 4 jobs verts ; 3 images × 2 tags (`pr-4`, `pr-4-5b6f929c`) ; label `preview-ready` posé ; packages **déjà publics** sans action manuelle, et liés au dépôt (barre latérale *Packages*). Détails : PROBLEMS.md, D10 et D12.

### 11. Phase 4b : AppProject et ApplicationSet (écrits, vérifiés à blanc, pas encore appliqués)

Fichiers dans PRVue : `platform/argocd/appproject.yaml`, `platform/argocd/applicationset.yaml`, et `platform/terraform/values/traefik.yaml` (modifié).

**Vérifié avant d'appliquer :**
- Jeton : Secret `github-token` présent (`kubectl get secret`, sans afficher la valeur). Le label `scm-creds` n'est exigé qu'en « strict mode », désactivé par défaut (code source v3.5.3) : on le pose quand même.
- Doc et code source v3.5 : `head_short_sha` = 8 caractères ; le générateur ne liste que les PR ouvertes ; le finalizer est ajouté par le contrôleur ; `clusterResourceWhitelist` accepte un `name`.
- **Rendu à blanc** avec le kustomize d'ArgoCD, à partir de Git (`git archive 5b6f929c`), pour une fausse PR 99 : namespace `pr-99` partout, 3 images `pr-99-5b6f929c`, host `pr-99.127-0-0-1.nip.io`, 7 références de secrets toutes satisfaites.
- Le nœud kind tire l'image publique de GHCR sans identifiants.
- `kubectl apply --dry-run=server` accepte les deux manifests ; `terraform plan` : 0 ajout, 1 modification (Traefik), 0 suppression.

**Problème trouvé avant d'appliquer (P7)** : ArgoCD ne déclare un Ingress *Healthy* que s'il a une adresse dans son statut, et Traefik n'en écrit pas (Service `NodePort`). Les previews seraient restées *Progressing* pour toujours. Correction proposée : Traefik écrit `127.0.0.1` dans le statut des Ingress.

**Tableau de parité** avec le déploiement manuel de la phase 3 : PROBLEMS.md, D16.

**Appliqué le 2026-11-16 (étapes 1 et 2 du plan de test) :**
- Traefik : `terraform apply` d'un plan enregistré (1 modification). Les Ingress ont maintenant `ADDRESS 127.0.0.1` ; pr-2 répond toujours 200.
- AppProject `previews` appliqué. **Test de clôture** : une Application qui rendait dans `micropizzeria` et une autre qui visait `default` ont toutes les deux été **refusées**, sans rien créer (PROBLEMS.md, D15).
- ApplicationSet appliqué : `ParametersGenerated=True`, `generated 0 applications` (aucune PR ouverte avec le label), relance toutes les 2 min, aucune erreur.

**Étapes 3 et 4 réussies : première preview automatique (PR #5).** CI verte → label → `micropizzeria-pr-5` *Synced/Healthy* sans aucune commande manuelle. Images `pr-5-f7f4bde7` (= 8 premiers caractères du commit de tête), 5 pods `Running`, 2 PVC `Bound`, Ingress avec `ADDRESS 127.0.0.1`, finalizer présent sur l'Application générée, namespace possédé par ArgoCD. L'application répond via Traefik, et le compte et la commande créés dans le navigateur sont dans les bases de `pr-5`. Détails : PROBLEMS.md, D16.

**Étape 5 réussie : deuxième commit sur la PR #5** (`0c90bebf`, CI en 43 s). Mise à jour progressive : chaque nouveau pod applicatif est passé 1/1 avant l'arrêt de l'ancien, les pods MySQL n'ont pas bougé. Même namespace (même date de création), mêmes volumes, même utilisateur, même commande.

**Étape 6 réussie : PR #5 fermée sans fusion.** Environ 1 min après : Application supprimée, namespace `pr-5` introuvable, 0 volume restant. pr-2 intact (mêmes UID), et les 9 tags d'images de pr-5 toujours lisibles sur GHCR.

**Le cycle de vie complet fonctionne sans aucune commande manuelle** : ouverture → preview → mise à jour sur place → fermeture → nettoyage.

**Mesures** : CI ≈ 45 s par commit ; nettoyage ≈ 1 min après la fermeture.

**Reste à montrer** : deux previews automatiques en même temps (pendant la démo).

**À faire :**
- ~~Label `scm-creds` sur le Secret `github-token`~~ : posé (vérifié par `demo/prepare.sh`).
- ~~`pr-2` (reste manuel de la phase 3)~~ : supprimé ; `demo/prepare.sh` passe 14/14.
- Tag `v0.1-mvp` : MVP, cycle de vie automatique des previews (étapes 1 à 4).

**Après l'enregistrement de la démo :**
- Reset, puis `demo/prepare.sh` à 14/14.
- Correction du README de MicroPizzeria (la ligne « pas encore exécuté ») : la PR #5 a été fermée sans fusion pour le test. Ouvrir une **nouvelle PR** avec cette correction, puis la **fusionner**. Pas avant l'enregistrement : une PR ouverte avec le label ferait échouer la préparation.

---

## Concepts compris

- **kubectl ne fonctionne pas « seul »** : c'est une télécommande qui envoie des ordres à un cluster. Sans cluster allumé, il affiche `connection refused`. Il lit la liste des clusters dans `~/.kube/config` (les **contextes**) :
  ```bash
  kubectl config get-contexts
  kubectl config use-context <nom>
  ```
- **kind remplace Minikube** : même rôle (un cluster local), mais il est plus léger et se pilote bien avec Terraform. Ne pas faire tourner les deux en même temps (`minikube stop`).
- **Ingress ≠ Ingress Controller** : l'Ingress contient les règles de routage (YAML), le controller est le programme qui les applique. On garde l'Ingress, et on remplace seulement le controller **Nginx Ingress** (projet arrêté par Kubernetes, plus mis à jour depuis mars 2026) par **Traefik**.
- **Fichiers à ne jamais pousser** :
  - Terraform : `terraform.tfstate` (+ `.backup`, contient tout en clair, secrets compris), `*.tfvars` (valeurs des variables).
  - Kubernetes : kubeconfig (`~/.kube/config`, `previews-config`, accès complet au cluster), fichiers `Secret` (le base64 n'est **pas** un chiffrement), clés privées et certificats (`*.key`, `*.pem`).
  - En général : `.env`, clé SSH privée (sans `.pub`), tokens (`gho_...`, clé Datadog).
  - Le `.gitignore` agit seulement **avant** le commit : un secret déjà poussé doit être considéré comme volé et **changé**.
  - Toujours `git status` avant `git add`. Vérifier une règle : `git check-ignore -v <fichier>`.
- **Gitleaks (idée ajoutée)** : détecteur de secrets, en hook local + en CI. Avec le `.gitignore`, ça fait trois couches = défense en profondeur.
- **Terraform ≠ YAML Kubernetes** : le YAML décrit ce qui tourne *dans* le cluster, Terraform décrit le cluster *lui-même* et ce qu'on installe dessus. MicroPizzeria n'utilisait pas Terraform (installation à la main avec `minikube` + `deploy.sh`).

---

## Prochaine étape

- [x] Mettre à jour l'adresse du dépôt (`git remote set-url`, voir plus haut)
- [x] Créer un cluster kind **à la main** pour comprendre ce que Terraform automatisera (node = un conteneur Docker, visible avec `docker ps` ; les pods sont dedans, visibles avec `kubectl get pods -A`) :
  ```bash
  minikube stop
  kind create cluster --name test
  kubectl get nodes
  docker ps                      # le nœud est un conteneur Docker
  kind delete cluster --name test
  ```
- [x] Créer le dépôt PRVue et son `.gitignore`
- [x] Étape 1 du guide, partie 1 : écrire le cluster kind seul en Terraform
- [x] Étape 1 du guide, partie 2 : ajouter Traefik et ArgoCD
- [ ] Étape 1, validation : `terraform destroy` puis `time terraform apply` depuis zéro, sans intervention, et noter le temps (première mesure du README)
- [ ] Gitleaks : hook pre-commit local (après l'étape 1)
- [ ] Gitleaks : job de CI dans PRVue et MicroPizzeria (étape 3)
