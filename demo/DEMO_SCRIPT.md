# PRVue demo script

**What it shows (about 12 minutes):** two pull requests on MicroPizzeria each get their own isolated preview, a new commit updates a preview in place without losing its data, and closing a PR deletes its environment while the other keeps running. No manual Kubernetes command during the demo: `kubectl` is only used to **look**.

Timings measured on 2026-11-16 (PR #5): CI ≈ 45 s per commit, preview appears within ≈ 2 min of the label (polling every 120 s), cleanup ≈ 1 min after closing the PR.

---

## 1. Before the demo (T − 30 min)

### Start the platform
```bash
cd ~/Desktop/"personnal projects"/PRVue/platform/terraform && terraform apply    # if the cluster is down
cd ../.. && ./demo/prepare.sh          # must end with "Ready for the demo." (exit code 0)
```
If it reports a FAIL, follow [Reset](#4-reset-before-or-after-a-demo), then run it again.

### Prepare two demo branches (not pushed yet)
Each branch changes the home page title, so the two previews look different:
```bash
cd ~/MicroPizza && git switch main && git pull
git switch -c demo/spring-menu
sed -i 's|Le goût de l’Italie dans chaque bouchée|Menu de printemps 🌸|' frontend/index.html
git commit -am "demo: spring menu title"
git switch main && git switch -c demo/summer-menu
sed -i 's|Le goût de l’Italie dans chaque bouchée|Menu d’été ☀️|' frontend/index.html
git commit -am "demo: summer menu title"
git switch main
```
Check that the `sed` changed something (`git show --stat HEAD` on each branch: `frontend/index.html | 2 +-`).

### Screen layout
| Window | Content |
| --- | --- |
| Browser tab 1 | GitHub, MicroPizzeria pull requests |
| Browser tab 2 | Argo CD UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443`, then https://localhost:8080 (user `admin`, password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d`) |
| Terminal A | `kubectl get applications -n argocd -w` |
| Terminal B | `watch -n 2 'kubectl get ns \| grep pr-; kubectl get pods -A \| grep pr-'` |
| Terminal C | for commands |

---

## 2. The demo

### Step 1: the starting point (1 min)
- Show the architecture diagram (PRVue README). Key sentence: *"GitHub Actions and Argo CD never talk to each other: both compute the same image tag from the PR number and its commit."*
- Terminal B: **no `pr-*` namespace**. Argo CD UI: **no application**.

### Step 2: open PR A (3 min)
```bash
cd ~/MicroPizza && git switch demo/spring-menu && git push -u origin demo/spring-menu
gh pr create -R sana-Benz/MicroPizzeria --base main --head demo/spring-menu --title "Spring menu" --body "Demo PR A"
```
- GitHub: the **Preview images** workflow runs (3 builds in parallel, then `label`), ≈ 45 s.
- The PR receives the **`preview-ready`** label.
- Terminal A: `micropizzeria-pr-<A>` appears (up to 2 min: *"Argo CD polls GitHub; the laptop accepts no incoming connection, so there is no webhook"*), then **Synced / Healthy**.
- Open `http://pr-<A>.127-0-0-1.nip.io`: the title says **Menu de printemps**. Register a user (`alice@demo.dev`) and place an order.

### Step 3: open PR B, a second independent environment (2 min)
```bash
git switch demo/summer-menu && git push -u origin demo/summer-menu
gh pr create -R sana-Benz/MicroPizzeria --base main --head demo/summer-menu --title "Summer menu" --body "Demo PR B"
```
- `micropizzeria-pr-<B>` appears, namespace `pr-<B>`.
- `http://pr-<B>.127-0-0-1.nip.io`: the title says **Menu d’été**.
- **Isolation:** log in as `alice@demo.dev` on B → *Invalid credentials*. Each preview has its own databases.
- Talking point: the AppProject `previews` only allows `pr-*` namespaces; a preview can never land in `default` (show `platform/argocd/appproject.yaml`).

### Step 4: a new commit updates PR A in place (2 min)
Terminal C, availability loop (leave it running):
```bash
while true; do printf "%s %s\n" "$(date +%T)" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://pr-<A>.127-0-0-1.nip.io/api/menu)"; sleep 2; done
```
Another terminal:
```bash
git switch demo/spring-menu
sed -i 's|Menu de printemps 🌸|Menu de printemps 🌸 (v2)|' frontend/index.html
git commit -am "demo: v2" && git push
kubectl get pods -n pr-<A> -w
```
- New `frontend`, `user-service` and `order-service` pods start; each old one stops **after** its replacement is ready. The **MySQL pods don't move**. The loop keeps answering 200.
- Reload the page: **(v2)**. Log in as alice: the order is still there (same namespace, same volumes).

### Step 5: close PR A (1 min)
```bash
gh pr close <A> -R sana-Benz/MicroPizzeria
```
- Within ≈ 1 min: `micropizzeria-pr-<A>` disappears from Argo CD, then namespace `pr-<A>` (Terminal B).
- `http://pr-<B>.127-0-0-1.nip.io` **still works**.

### Step 6: wrap-up (1 min)
- Close PR B the same way; Terminal B ends empty.
- Images stay in GHCR (cleanup is a planned extension).
- Known limitations (PRVue README): demo-only secrets, polling delay, no fork PRs.

---

## Cut plan: from ≈ 12 min recorded to a 4–5 min video

Record everything in real time (proof that nothing is staged), then cut the waits in editing. Rule: **never cut a state change**. Keep the moment each thing appears, and cut the waiting before it. Show a small on-screen timer or caption (e.g. "+45 s", "+2 min") at each cut, so the real delays stay honest.

| Step | Recorded | Final | Keep on screen | Cut or speed up |
| --- | --- | --- | --- | --- |
| 1. Starting point | ≈ 1 min | 0:30 | Architecture diagram (one sentence about the tag contract); Terminal B empty; Argo CD UI empty | Scrolling, setup |
| 2. PR A | ≈ 3–4 min | 1:15 | `gh pr create`; the workflow with its 3 parallel builds + `label` (a few seconds); the `preview-ready` label appearing; `micropizzeria-pr-<A>` appearing in Terminal A, then **Synced/Healthy**; the page with "Menu de printemps"; register + order | **CI (≈ 45 s)**: ×8 speed-up or cut to the green result, caption "+45 s". **Polling (up to 2 min)**: cut, caption "Argo CD polls every 2 min". Pods starting: ×4 |
| 3. PR B + isolation | ≈ 3 min | 1:00 | `gh pr create`; `micropizzeria-pr-<B>` Healthy; "Menu d'été"; the **Invalid credentials** for alice on B (the isolation proof); 5 s on `appproject.yaml` (`pr-*` only) | CI and polling as in step 2, without repeating the explanation |
| 4. New commit on A | ≈ 3 min | 1:00 | `git push`; Terminal C loop answering **200** the whole time (split screen with `kubectl get pods -w`); new pods 1/1 before old ones terminate; MySQL pods unchanged; page shows "(v2)"; alice's order still there | **CI + polling**: cut, caption. **Rollout**: ×2–×4, keeping a frame where old and new pods run together |
| 5. Close A | ≈ 1–2 min | 0:30 | `gh pr close`; the Application disappearing; `pr-<A>` disappearing from Terminal B; B still answering | The wait until the next poll (≈ 1 min): cut, caption "≈ 1 min later" |
| 6. Wrap-up | ≈ 1 min | 0:30 | Terminal B empty after closing B; one slide: limitations and next steps | — |
| **Total** | **≈ 12 min** | **≈ 4:45** | | |

Tips:
- Use **real PR numbers in the captions**; don't rename anything in editing.
- If one step goes wrong (e.g. a 503 right after deployment, P6), keep it only if it's explained in one sentence; otherwise re-record that step.
- The Argo CD UI makes the best visuals for appear/disappear; the terminals are the proof. Show both side by side when possible.

---

## After recording

1. Reset (section below) and check: `./demo/prepare.sh` must pass 14/14.
2. **MicroPizzeria README fix** (closed PR #5 was never merged): open a **new PR** with the README fix (the outdated "pas encore exécuté" line), let it get its preview, then **merge** it. Its preview is deleted when it's merged. Don't do this before recording: an open labeled PR makes `prepare.sh` warn, and its preview would be in the demo.

---

## 3. If something goes wrong during the demo

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| No Application 2 min after the label | Polling not reached yet, or the token expired | Wait one more poll; `kubectl logs -n argocd deploy/argocd-applicationset-controller --since=5m \| grep -iE "error\|401"` |
| No `preview-ready` label | A build failed | Open the workflow run on GitHub |
| Pods in `ImagePullBackOff` | Argo CD saw the commit before CI finished | Normal, it resolves itself (retry delay up to ≈ 5 min); the old version keeps serving |
| Application stays *Progressing* | Ingress without an address | `kubectl get ingress -n pr-<n>`: ADDRESS must be 127.0.0.1 (Traefik values, PROBLEMS.md P7) |
| One `500` right after login | Stale DB connection (PROBLEMS.md P4) | Try again |
| `503` for a few seconds | Traefik not updated yet (P6) | Reload |

---

## 4. Reset (before or after a demo)

Goal: **zero `pr-*` namespaces**, no open demo PR. `./demo/prepare.sh` tells you what is left; it never deletes anything itself.

1. **Close the demo PRs** (Argo CD then deletes their previews; never delete a managed namespace by hand, `selfHeal` would recreate it while the PR is open):
   ```bash
   gh pr list -R sana-Benz/MicroPizzeria --label preview-ready --state open
   gh pr close <n> -R sana-Benz/MicroPizzeria --delete-branch
   ```
2. **Remove leftover namespaces not managed by Argo CD** (flagged as FAIL by `prepare.sh`), for example `pr-2` from the manual Phase 3 test. This deletes everything inside, volumes included:
   ```bash
   kubectl delete namespace pr-2
   ```
3. **Delete the local demo branches:**
   ```bash
   cd ~/MicroPizza && git switch main && git branch -D demo/spring-menu demo/summer-menu
   ```
4. **Check:**
   ```bash
   ./demo/prepare.sh       # "Ready for the demo.", exit code 0
   ```

**Not part of the reset:** the GHCR images of closed PRs stay (by design). Delete them by hand in GitHub → Packages if needed.

**Full reset** (rebuilds everything, ≈ a few minutes): `terraform destroy` then `terraform apply` in `platform/terraform`, then re-create the token Secret (GUIDE, step 4: it isn't managed by Terraform) and re-apply `platform/argocd/appproject.yaml` and `applicationset.yaml`.
