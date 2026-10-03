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

---

## Concepts compris

- **kubectl ne fonctionne pas « seul »** : c'est une télécommande qui envoie des ordres à un cluster. Sans cluster allumé, il affiche `connection refused`. Il lit la liste des clusters dans `~/.kube/config` (les **contextes**) :
  ```bash
  kubectl config get-contexts
  kubectl config use-context <nom>
  ```
- **kind remplace Minikube** : même rôle (un cluster local), mais il est plus léger et se pilote bien avec Terraform. Ne pas faire tourner les deux en même temps (`minikube stop`).
- **Ingress ≠ Ingress Controller** : l'Ingress contient les règles de routage (YAML), le controller est le programme qui les applique. On garde l'Ingress, et on remplace seulement le controller **Nginx Ingress** (projet arrêté par Kubernetes, plus mis à jour depuis mars 2026) par **Traefik**.
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
- [ ] Étape 1 du README : écrire ce cluster en Terraform, avec Traefik et ArgoCD
