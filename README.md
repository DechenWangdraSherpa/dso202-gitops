<!-- =====================================================================
Assignment  : DSO202 Assignment 4
Descriptor  : Unit IV 4.1-4.4 - GitOps with Argo CD
Purpose     : What this repository is, the pinned versions, how to build the
              whole environment from an empty machine, how to clean up, how
              credentials are handled, and the written answers Q1-Q6.
====================================================================== -->

# dso202-gitops

The desired state of the DSO202 **Task Tracker** (frontend, backend, PostgreSQL) in two
environments, `dev` and `staging`, delivered by **Argo CD** from this repository. After a
two-step bootstrap nobody runs `kubectl apply` or `helm install` against the workloads: a
commit is the release, `git revert` is the rollback, and the cluster pulls the change.

| Environment | Namespace | Application | Follows | Sync | Frontend |
|---|---|---|---|---|---|
| dev | `dso202-dev` | `tasktracker-dev` | branch `main` | automated, prune + self-heal | `http://localhost:30080` |
| staging | `dso202-staging` | `tasktracker-staging` | tag (`v1.2.0` now) | manual (the promotion gate) | `kubectl port-forward -n dso202-staging svc/frontend-svc 8081:80` |

Evidence for every task is in [`docs/evidence.md`](docs/evidence.md).

## Layout

```
bootstrap/argocd/   Argo CD v3.5.6 via Kustomize (+ argocd-cm / argocd-rbac-cm patches) - applied by hand
bootstrap/root/     AppProject 'platform' + the root Application (app of apps)       - applied by hand
argocd/projects/    AppProject 'dso202' (workload project, least privilege)          - delivered by root
argocd/applications/ sealed-secrets, platform-dev/-staging, tasktracker-dev/-staging - delivered by root
platform/<env>/     Namespace, ResourceQuota, LimitRange, RBAC, SealedSecret         - platform-<env>
charts/tasktracker/ the Assignment 3 chart, adapted to the chart contract C1-C11    - tasktracker-<env>
environments/<env>/ everything that differs between dev and staging (values only)
cluster/            kind configuration (from Practical 1)
docs/evidence.md    command output for every task
```

Sync waves in the root Application: `dso202` project **-3** → `sealed-secrets` **-2** →
`platform-dev`/`platform-staging` **-1** → `tasktracker-*` **0**. Inside the chart:
database **0** → backend **1** → frontend **2** → PostSync smoke-test Job.

## Pinned versions

| Component | Version |
|---|---|
| Argo CD (server and `argocd` CLI) | v3.5.6 (`bootstrap/argocd/kustomization.yaml` pins the install manifest URL) |
| Sealed Secrets Helm chart | 2.20.0 (`argocd/applications/sealed-secrets.yaml`) |
| Sealed Secrets controller / `kubeseal` | 0.40.0 |
| kind / node image | v0.32.0 / `kindest/node:v1.36.1@sha256:3489c767…` (Practical 1) |
| kubectl / Kustomize | v1.36.x / v5.8.1 |
| Helm | v4.3.1 (Assignment 3) |
| Images | `dwangshers/dso202-amd64-{frontend,backend,db}`: baseline `1.0`, release `1.1` (db stays `1.0`); smoke test `busybox:1.37` |

The `1.1` images are not on Docker Hub; they were built locally from the Assignment 1 source
and loaded into kind with `kind load docker-image` (brief section 13). `latest`, `stable`,
`master` and `HEAD` are not used as a version anywhere.

## Build the whole environment from an empty machine

This is the sequence practised in Task 9 (3 min 24 s from `kind create` to a working dev
frontend). It needs the repository and **one** file kept outside it: the sealing-key backup.

```bash
git clone https://github.com/DechenWangdraSherpa/dso202-gitops.git
cd dso202-gitops

# 1. Cluster (host port 30080 must be free)
kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml

# 1a. Only if images cannot be pulled (rate limit, or the locally built 1.1 images):
for img in dwangshers/dso202-amd64-frontend:1.1 dwangshers/dso202-amd64-backend:1.1 \
           dwangshers/dso202-amd64-db:1.0 busybox:1.37; do
  kind load docker-image "$img" --name dso202-gitops
done

# 2. Restore the sealing key BEFORE the controller exists
kubectl create namespace sealed-secrets
kubectl apply -f ../dso202-keys/sealing-key.backup.yaml

# 3. Bootstrap step 1: Argo CD
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# 4. Bootstrap step 2: platform project + root Application. Nothing else by hand.
kubectl apply -f bootstrap/root
kubectl get applications -n argocd -w        # waves -3, -2, -1, 0

# 5. Sign in and open the staging gate (manual by design)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --username admin \
  --password "$(argocd admin initial-password -n argocd | head -1)" --insecure
argocd app sync tasktracker-staging

# 6. Verify
curl -s http://localhost:30080 | grep '<h1>'                              # dev
kubectl port-forward -n dso202-staging svc/frontend-svc 8081:80 &         # staging
kubectl get applications -n argocd                                        # all Synced/Healthy

# 7. Take a fresh key backup from the new cluster
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > ../dso202-keys/sealing-key.backup.yaml && chmod 600 ../dso202-keys/sealing-key.backup.yaml
```

The reviewer account (Task 6) needs a password after every rebuild:
`argocd account update-password --account reviewer`.

## Cleanup

```bash
kill %1 %2 2>/dev/null                 # port-forwards
kind delete cluster --name dso202-gitops
```

Do **not** `kubectl delete application root` casually: its finalizer deletes every child
Application and, through theirs, every workload. Database contents are not in Git and are lost
with the cluster.

## How credentials are handled

- The chart never renders a Secret (C3). Pods read `DB_*`/`POSTGRES_*` from the Secret
  `tasktracker-credentials`, named by the value `existingSecret`.
- That Secret is created in each namespace by the **Sealed Secrets** controller from
  `platform/<env>/tasktracker-credentials.sealed.yaml`, which was produced by
  `kubectl create secret … --dry-run=client -o yaml | kubeseal --format yaml` — the plaintext
  never touched disk except as a git-ignored, mode-600 input file that was deleted afterwards.
- Each environment is sealed separately (strict scope) with a different password.
- The controller's private key is backed up to `../dso202-keys/` (outside the repository,
  mode 600) and must be re-backed-up after any key renewal (every 30 days) or rebuild.
- `.gitignore` (the first commit) keeps key backups and plaintext inputs out, and a history
  search (`git log -p --all -S`) for every value, plaintext and base64, returns nothing.

## Written answers

### Q1 — Why is `platform` applied by hand while `dso202` is created by the root? What if `dso202` could deploy into `argocd`?

The root Application has to belong to a project, and that project must exist before the root
can be created and before anything can be read from Git — so `platform` is part of the
bootstrap, a chicken-and-egg object applied once by hand. It is also the administrator
project (it may write to `argocd`, `sealed-secrets` and create cluster-scoped kinds), so
keeping it out of the Git-delivered tree means an ordinary commit to `argocd/` cannot widen
it. `dso202` is just another declarative object, so the root delivers it like any Application
(wave -3, before the Applications that use it), which keeps it versioned and reviewed.

If `dso202` were allowed to deploy into `argocd`, a commit to the Task Tracker chart could
create an `Application` or `AppProject` object in that namespace. Argo CD would pick it up,
and that Application could name **any** project (for example `platform`) and deploy anything
anywhere — the workload project would have given itself administrator rights. That is why
only `platform` may target `argocd`, and why `dso202` has `clusterResourceWhitelist: []`
and a short namespaced whitelist.

### Q2 — What does strict scope prevent? What is lost, and what must be done, if the sealing key is lost?

With the default **strict** scope the Secret's name and namespace are part of the encrypted
payload. A SealedSecret copied into another namespace, or renamed, cannot be decrypted, so
someone who can create SealedSecrets in `dso202-dev` cannot replay the staging ciphertext
there to obtain staging credentials, and a manifest cannot be silently retargeted.

If the sealing key is lost, every SealedSecret in Git becomes permanently unreadable — the
ciphertext is useless without the private key, and the values cannot be recovered from Git.
Running Secrets already decrypted in a live cluster keep working until that cluster is
deleted, but a rebuild would leave `platform-*` `Degraded` with `no key could decrypt secret`.
Recovery: let the controller generate a new key, re-seal every credential from the source of
truth (the password manager, or new passwords — then the database passwords must be rotated
to match), commit the new SealedSecrets, and immediately back up the new key. This is why the
key is backed up before anything is sealed and again after every renewal or rebuild.

### Q3 — Difference between `Synced` and `Healthy`, with an example

**Sync status** compares the desired state (Git) with the live state: `Synced` means the
objects in the cluster equal the rendered manifests. **Health** asks whether those objects
actually work (rollout complete, Pods ready, Job succeeded). The two are independent.

Example from this repository (Task 7, `argocd app get tasktracker-dev` after the bad
backend release):

```
Sync Status:        Synced to main (52f24e6)
Health Status:      Degraded
apps   Deployment  dso202-dev  backend  Synced  Degraded  Deployment "backend" exceeded its progress deadline
```

The Deployment in the cluster was exactly what Git said (image `1.1`), so it was `Synced`, but
the new Pod crashed (`DB_SSLMODE` missing) and after `progressDeadlineSeconds: 120` it was
`Degraded`. The reverse case also occurred: in Drill 2 staging was `OutOfSync` (3 replicas
instead of 1) but `Healthy`.

### Q4 — Argo CD RBAC vs Kubernetes RBAC; what would SSO change?

| | Argo CD RBAC | Kubernetes RBAC (Assignment 2) |
|---|---|---|
| Controls | What a **person** may do **through Argo CD** (UI/CLI/API): view, sync, delete, read logs, exec, per Application/project | What an **identity talking to the Kubernetes API** may do: verbs on resources in a namespace |
| Subjects | Argo CD local accounts (`admin`, `reviewer`), SSO users and groups | ServiceAccounts, users, groups known to the API server |
| Configured in | `argocd-rbac-cm` (`policy.csv`, `policy.default`) — `bootstrap/argocd/argocd-rbac-cm-patch.yaml`; accounts in `argocd-cm` | `Role`/`RoleBinding` objects — `platform/<env>/rbac.yaml` |

Argo CD itself acts in the cluster with its own ServiceAccount; Argo CD RBAC decides which
user may ask it to act. `reviewer` cannot sync even though the controller could.

With SSO (Dex or OIDC), local accounts would no longer be needed; the subjects in
`policy.csv` would be the identity provider's **groups**, bound to roles, for example:

```
p, role:dso202-viewer, applications, get, dso202/*, allow
p, role:dso202-viewer, logs, get, dso202/*, allow
g, my-org:dso202-reviewers, role:dso202-viewer
```

plus `scopes: '[groups]'` so the group claim is read. Access is then granted or removed in
the identity provider, not by editing accounts in Argo CD.

### Q5 — Why is `argocd app rollback` refused, what is the GitOps equivalent, why `git revert`?

`tasktracker-dev` has automated sync. A rollback would set the live state to an older
revision while Git still says the newer one; on the next reconciliation automated sync would
apply the newer revision again. Argo CD therefore refuses:
`rollback cannot be initiated when auto-sync is enabled`.

The GitOps equivalent is to change the desired state: `git revert <bad-sha>` in a pull request
(PR #4 here). Argo CD then pulls the reverting commit and applies it like any release.

`git revert` adds a new commit and keeps history intact. Deleting the bad commit (reset +
force-push) rewrites a shared branch, breaks every clone and open branch, and destroys the
audit trail — the record of what was deployed when and why. Here the history shows the release
`52f24e6`, its revert `55844bb`, and the fix `8847839`; a rewrite would also invalidate tags
and Argo CD's recorded revisions.

### Q6 (a) — One repository for chart and configuration: two advantages, two disadvantages

Advantages:
1. **One atomic change.** A chart change and the values it needs (C2: a new variable) land in
   one commit and one tag, so `v1.2.0` is a complete, reproducible release, and staging can be
   pinned to a single reference.
2. **Simple to operate and to audit.** One URL in every project and Application, one place to
   review, one history to search for secrets, and the whole environment rebuilds from one clone.

Disadvantages:
1. **Coupled access and history.** Anyone allowed to change values can change the chart (and the
   Argo CD objects); a configuration tweak and an application change share one review flow and
   one commit stream, which grows noisy as more services are added.
2. **Extra reconciliation and coupled triggers.** Every commit (even a README change) moves `main`,
   so all Applications on `main` refresh; and dev cannot pin the chart to a tested version while
   following configuration on a branch without the multi-source pattern of Task 10.

### Q6 (b) — What is not under GitOps control after the rebuild, and how usually handle it

- **Bootstrap layer (Argo CD install, `argocd-cm`, `argocd-rbac-cm`).** Applied by hand, so a
  committed change (Task 6 log rule) does nothing until re-applied. Teams let Argo CD manage
  itself (an Application pointing at `bootstrap/argocd`) or install it with Terraform/a cluster
  provisioning pipeline.
- **The root Application and the `platform` project.** Created by hand once per cluster. Teams
  create them with the same provisioning tooling (Terraform, Cluster API, Argo CD Autopilot) or
  have a management cluster's Argo CD create them.
- **The sealing key.** Kept outside Git by design. Teams store it in a secrets manager or vault
  with backups and access logging, or replace Sealed Secrets with External Secrets Operator so the
  values live in AWS Secrets Manager/Vault and nothing cluster-specific must be restored.
- **Database contents.** Data is state, not configuration. Teams use scheduled backups and point-in-
  time recovery (e.g. Velero, pgBackRest, a managed database) and test restores regularly.
- **Locally loaded images and runtime credentials** (the `reviewer` password, the generated admin
  password). Teams push images to a registry they control, and manage users through SSO so no
  per-cluster passwords exist.
