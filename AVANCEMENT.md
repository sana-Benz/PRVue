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
