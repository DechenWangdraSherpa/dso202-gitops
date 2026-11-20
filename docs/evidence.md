<!-- =====================================================================
File        : docs/evidence.md
Assignment  : DSO202 Assignment 4
Descriptor  : Unit IV 4.1-4.4 - evidence for every task
Purpose     : Command output recorded as text, one section per task. Every block
              shows the command that was run and its real output. Credential
              values, the sealing key and the admin password never appear here:
              they are passed by command substitution or tested by key name only.
====================================================================== -->

# Evidence — DSO202 Assignment 4 (GitOps with Argo CD)

Cluster: kind `dso202-gitops` (3 nodes, Kubernetes v1.36.1). Repository:
`https://github.com/DechenWangdraSherpa/dso202-gitops.git`. Times are local (UTC+6).

> Tasks 1 and 2 were re-run (read-only checks) after the Task 9 rebuild, because the
> original text captures were lost when the host rebooted between Task 2 and Task 3;
> the original Task 1 terminal images are `screenshots/01`–`02` of the report. Pod ages
> therefore show the rebuilt cluster. Everything from Task 3 onwards is the original run.

## Task 1 — Repository, chart contract, cluster

Tool check (section 3.2), the two `helm lint` runs, the kinds the chart renders, the
`kind` cluster list, nodes and the host port mapping:

```text
$ docker version --format '{{.Server.Version}}'
29.9.3
$ kind version
kind v0.32.0 go1.26.3 linux/amd64
$ kubectl version --client
Client Version: v1.36.6
Kustomize Version: v5.8.1
$ helm version --short
v4.3.1+gc0d08d0
$ git --version
git version 2.53.0
$ argocd version --client --short
argocd: v3.5.6+c2b1e30
$ kubeseal --version
kubeseal version: 0.40.0
$ helm search repo sealed-secrets/sealed-secrets --versions | head -5
NAME                         	CHART VERSION	APP VERSION	DESCRIPTION                                  
sealed-secrets/sealed-secrets	2.22.0       	0.41.2     	Helm chart for the sealed-secrets controller.
sealed-secrets/sealed-secrets	2.21.0       	0.41.2     	Helm chart for the sealed-secrets controller.
sealed-secrets/sealed-secrets	2.20.0       	0.40.0     	Helm chart for the sealed-secrets controller.
sealed-secrets/sealed-secrets	2.19.3       	0.39.1     	Helm chart for the sealed-secrets controller.
$ helm lint charts/tasktracker -f environments/dev/values.yaml
==> Linting charts/tasktracker
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
$ helm lint charts/tasktracker -f environments/staging/values.yaml
==> Linting charts/tasktracker
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
$ helm template tasktracker charts/tasktracker -f environments/dev/values.yaml | grep -E '^kind:' | sort | uniq -c
      1 kind: ConfigMap
      2 kind: Deployment
      1 kind: Job
      3 kind: Service
      1 kind: ServiceAccount
      1 kind: StatefulSet
$ kind get clusters
dso202
dso202-gitops
dso202-p5
$ kubectl config current-context
kind-dso202-gitops
$ kubectl get nodes
NAME            STATUS   ROLES           AGE     VERSION
control-plane   Ready    control-plane   8m48s   v1.36.1
worker-node-1   Ready    <none>          8m38s   v1.36.1
worker-node-2   Ready    <none>          8m38s   v1.36.1
$ docker ps --filter name=dso202-gitops --format '{{.Names}}   {{.Ports}}'
dso202-gitops-control-plane   127.0.0.1:30080->30080/tcp, 127.0.0.1:34813->6443/tcp
dso202-gitops-worker2   
dso202-gitops-worker   
```

`dso202` and `dso202-p5` in `kind get clusters` are clusters from earlier practicals.
They were **stopped** (`docker stop`), not deleted, so host port 30080 was free; the new
cluster maps it on its control-plane node (`127.0.0.1:30080->30080/tcp`).

`.gitignore` is the first commit of the repository (`git log --reverse | head -1`):
`f19ac4c Add .gitignore before any other file (Listing 1)`.

### Chart contract

| # | Requirement | Where it is satisfied (file : key) |
|---|---|---|
| C1 | Image repository and tag are values per tier | `charts/tasktracker/values.yaml` : `database.image`, `backend.image`, `frontend.image` (`repository`, `tag`); templates call `tasktracker.image` in `templates/_helpers.tpl` — no tag in any template |
| C2 | Per-tier configuration from values | `values.yaml` : `backend.env` / `frontend.env` / `database.env`, rendered by `tasktracker.extraEnv` (`_helpers.tpl`) into each container. Proven in Task 7: `DB_SSLMODE` was added by a values change only |
| C3 | Chart never renders a Secret; `existingSecret` | No Secret template. `values.yaml` and `environments/*/values.yaml` : `existingSecret: tasktracker-credentials`; used by `secretKeyRef` in `templates/backend.yaml` and `templates/database.yaml` |
| C4 | Readiness probes on all three tiers | `templates/database.yaml` (`pg_isready`), `templates/backend.yaml` (`GET /api/status`), `templates/frontend.yaml` (`GET /`) |
| C5 | Sync waves database 0, backend 1, frontend 2 | `argocd.argoproj.io/sync-wave` in `templates/database.yaml` ("0", with ConfigMap and ServiceAccount also "0"), `templates/backend.yaml` ("1"), `templates/frontend.yaml` ("2") |
| C6 | `progressDeadlineSeconds: 120` on backend and frontend | `values.yaml` : `progressDeadlineSeconds: 120`, used in `templates/backend.yaml` and `templates/frontend.yaml` |
| C7 | Requests and limits on every container | `values.yaml` : `database.resources`, `backend.resources`, `frontend.resources`; `templates/smoke-test-job.yaml` : `resources` |
| C8 | No Namespace, ResourceQuota, LimitRange, Role, RoleBinding | Chart renders only ConfigMap, Deployment, Job, Service, ServiceAccount, StatefulSet (kind list above); those objects live in `platform/<env>/` |
| C9 | Ingress disabled by default | No Ingress template exists; `values.yaml` : `ingress.enabled: false` documents it |
| C10 | Frontend NodePort, port is a value | `templates/frontend.yaml` : `type: NodePort`, `nodePort: {{ .Values.frontend.service.nodePort }}`; `environments/dev/values.yaml` 30080, `environments/staging/values.yaml` 30081 |
| C11 | `helm lint` clean, `helm template` works for both | Output above: `1 chart(s) linted, 0 chart(s) failed` for both values files |

## Task 2 — Argo CD installed from pinned Kustomize files

Render checks (6 Deployments + 1 StatefulSet, everything in `argocd`, images from
ghcr.io / public.ecr.aws / quay.io with tag v3.5.6), seven Pods, three CRDs, the
`argocd-cm` excerpt and `argocd version`:

```text
$ kubectl kustomize bootstrap/argocd | grep -E '^kind: (Deployment|StatefulSet)' | sort | uniq -c
      6 kind: Deployment
      1 kind: StatefulSet
$ kubectl kustomize bootstrap/argocd | grep -E '^  namespace:' | sort | uniq -c
     59   namespace: argocd
$ kubectl kustomize bootstrap/argocd | grep 'image:' | sort -u
        image: ghcr.io/dexidp/dex:v2.45.1
        image: public.ecr.aws/docker/library/redis:8.2.3-alpine
        image: quay.io/argoproj/argocd:v3.5.6
$ kubectl get pods -n argocd
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          6m57s
argocd-applicationset-controller-58bb5c7479-4k6rj   1/1     Running   0          6m57s
argocd-dex-server-dd6b85d9c-dp8g4                   1/1     Running   0          6m57s
argocd-notifications-controller-6b85c65458-qz8bw    1/1     Running   0          6m57s
argocd-redis-869b85489d-dnx45                       1/1     Running   0          6m57s
argocd-repo-server-5bf66565cd-hlqdz                 1/1     Running   0          6m57s
argocd-server-7474bb8f76-jwn98                      1/1     Running   0          6m57s
$ kubectl get crd | grep argoproj.io
applications.argoproj.io      2026-11-20T09:39:50Z
applicationsets.argoproj.io   2026-11-20T09:39:51Z
appprojects.argoproj.io       2026-11-20T09:39:51Z
$ kubectl get configmap argocd-cm -n argocd -o yaml | grep -E 'timeout|accounts|health.argoproj'
  accounts.reviewer: login
  resource.customizations.health.argoproj.io_Application: |
  timeout.reconciliation: 60s
  timeout.reconciliation.jitter: 10s
$ argocd version --short
argocd: v3.5.6+c2b1e30
argocd-server: v3.5.6
$ argocd login localhost:8080 --username admin --password "$(argocd admin initial-password -n argocd | head -1)" --insecure
'admin:login' logged in successfully
Context 'localhost:8080' updated
```

Applied with `kubectl apply -k bootstrap/argocd --server-side --force-conflicts`
(client-side apply would fail on the ApplicationSet CRD annotation size). Signed in with
`argocd login localhost:8080 --username admin --password "$(argocd admin initial-password -n argocd | head -1)" --insecure`
→ `'admin:login' logged in successfully`. UI screenshot: report `screenshots/04-task2-argocd-ui.png`.

## Task 3 — AppProjects and the root Application

```text
$ kubectl apply -f bootstrap/root
appproject.argoproj.io/platform created
Warning: metadata.finalizers: "resources-finalizer.argocd.argoproj.io": prefer a domain-qualified finalizer name including a path (/) to avoid accidental conflicts with other finalizer writers
application.argoproj.io/root created
$ kubectl get appproject,application -n argocd
NAME                              AGE
appproject.argoproj.io/default    33h
appproject.argoproj.io/dso202     37s
appproject.argoproj.io/platform   40s

NAME                           SYNC STATUS   HEALTH STATUS
application.argoproj.io/root   Synced        Healthy
$ argocd app get root
Name:               argocd/root
Project:            platform
Server:             https://kubernetes.default.svc
Namespace:          argocd
URL:                https://localhost:8080/applications/root
Source:
- Repo:             https://github.com/DechenWangdraSherpa/dso202-gitops.git
  Target:           main
  Path:             argocd
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (51d9964)
Health Status:      Healthy

GROUP        KIND        NAMESPACE  NAME    STATUS  HEALTH  HOOK  MESSAGE
argoproj.io  AppProject  argocd     dso202  Synced                appproject.argoproj.io/dso202 unchanged
```

`dso202` appears in the resource list of `argocd app get root`, so it was created by the
root Application, not by hand. Project and final whitelist:

```text
$ argocd proj get dso202
Name:                        dso202
Description:                 Task Tracker workloads for the dev and staging environments
Destinations:                https://kubernetes.default.svc,dso202-dev
                             https://kubernetes.default.svc,dso202-staging
Repositories:                https://github.com/DechenWangdraSherpa/dso202-gitops.git
Source Namespaces:           <none>
Scoped Repositories:         <none>
Allowed Cluster Resources:   <none>
Scoped Clusters:             <none>
Denied Namespaced Resources: <none>
Signature keys:              <none>
Orphaned Resources:          disabled
$ kubectl get appproject dso202 -n argocd -o jsonpath='{range .spec.namespaceResourceWhitelist[*]}{.group}/{.kind}{"\n"}{end}'
apps/Deployment
apps/StatefulSet
/Service
/ConfigMap
/ServiceAccount
batch/Job
$ helm template tasktracker charts/tasktracker -f environments/dev/values.yaml | grep -E '^kind:' | sort -u
kind: ConfigMap
kind: Deployment
kind: Service
kind: ServiceAccount
kind: StatefulSet
```

The whitelist names exactly the kinds rendered by the chart (ConfigMap, Deployment,
Job, Service, ServiceAccount, StatefulSet). During Task 6 two kinds were added with a
comment in `argocd/projects/dso202.yaml`: **ReplicaSet** and **Pod**. The chart renders
neither; Argo CD hides live resources whose kind the project does not permit, so without
them Pods were missing from the resource tree and no logs could be served (see Task 6).
Nothing cluster-scoped and no Quota/LimitRange/Role/RoleBinding/SealedSecret is allowed.

## Task 4 — Sealed Secrets and the platform layer

Controller installed from Git (child Application `sealed-secrets`), CRD present, key backed up
outside the repository (`../dso202-keys/`, mode 600 — contents never shown):

```text
$ kubectl get applications -n argocd
NAME             SYNC STATUS   HEALTH STATUS
root             Synced        Healthy
sealed-secrets   Synced        Healthy
$ kubectl get pods -n sealed-secrets
NAME                                        READY   STATUS    RESTARTS   AGE
sealed-secrets-controller-8b5ffdf69-xdhgm   1/1     Running   0          20s
$ kubectl get crd sealedsecrets.bitnami.com
NAME                        CREATED AT
sealedsecrets.bitnami.com   2026-11-20T08:09:20Z
$ mkdir -p ../dso202-keys
$ kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ../dso202-keys/sealing-key.backup.yaml
$ chmod 600 ../dso202-keys/sealing-key.backup.yaml
$ ls -l ../dso202-keys/
total 8
-rw------- 1 dw4ngsh3rs dw4ngsh3rs 7087 Nov 20 14:09 sealing-key.backup.yaml
```

Sealing (plaintext inputs were `secrets-plain/{dev,staging}.env`, mode 600, git-ignored,
written by a script so no value reached the shell history; deleted after sealing):

```text
$ export SEALED_SECRETS_CONTROLLER_NAMESPACE=sealed-secrets
kubectl create secret generic tasktracker-credentials \
  --namespace dso202-dev \
  --from-env-file=secrets-plain/dev.env \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > platform/dev/tasktracker-credentials.sealed.yaml
$ export SEALED_SECRETS_CONTROLLER_NAMESPACE=sealed-secrets
kubectl create secret generic tasktracker-credentials \
  --namespace dso202-staging \
  --from-env-file=secrets-plain/staging.env \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > platform/staging/tasktracker-credentials.sealed.yaml
$ grep -E 'kind|name:|namespace:|DB_|POSTGRES_' platform/dev/tasktracker-credentials.sealed.yaml | cut -c1-90
kind: SealedSecret
  name: tasktracker-credentials
  namespace: dso202-dev
    DB_PASSWORD: AgCj6r5Eo9v5vSclQ35wYkzZeu7GLKnrSgqNuKoV4iNa3PWx/LBStBFWOGKIpqhXivhM9Lg/Q
    DB_USER: AgA4xtsBsw9gSCUTzBRo/FJv4UdCJDRpML6SJ2VzuSafZH6Z+mxkNS7qV/o4U2xYz4mtZbpmH7rDR
    POSTGRES_PASSWORD: AgBYl9fltVGMOAqHPpXgeKsLLvmJUebPAGSqeqV7f7gGdVEfFP2PpHZcaRpyMkkEDQy
    POSTGRES_USER: AgAmqLZe4PWyvbsW7AfmUoqPrjD1vlu3LzrxYP+x31XVR1wR7rmpcdGJHGdTO4o5xhqPuu3
      name: tasktracker-credentials
      namespace: dso202-dev
$ rm secrets-plain/*.env
$ git status --short --ignored
?? platform/dev/tasktracker-credentials.sealed.yaml
?? platform/staging/tasktracker-credentials.sealed.yaml
```

Platform Applications healthy, namespaces, SealedSecret, decrypted Secret (key names and
sizes only), quota and limits:

```text
$ kubectl get applications -n argocd
NAME               SYNC STATUS   HEALTH STATUS
platform-dev       Synced        Healthy
platform-staging   Synced        Healthy
root               Synced        Healthy
sealed-secrets     Synced        Healthy
$ kubectl get namespaces | grep dso202
dso202-dev           Active   14s
dso202-staging       Active   14s
$ kubectl get sealedsecret -n dso202-dev
NAME                      STATUS   SYNCED   AGE
tasktracker-credentials            True     13s
$ kubectl describe secret tasktracker-credentials -n dso202-dev
Name:         tasktracker-credentials
Namespace:    dso202-dev
Labels:       <none>
Annotations:  <none>

Type:  Opaque

Data
====
DB_PASSWORD:        24 bytes
DB_USER:            11 bytes
POSTGRES_PASSWORD:  24 bytes
POSTGRES_USER:      11 bytes
$ kubectl get secret tasktracker-credentials -n dso202-staging
NAME                      TYPE     DATA   AGE
tasktracker-credentials   Opaque   4      13s
$ kubectl get resourcequota,limitrange -n dso202-dev -o custom-columns=KIND:.kind,NAME:.metadata.name,MANAGED-BY:.metadata.labels.dso202/managed-by
KIND            NAME                MANAGED-BY
ResourceQuota   assignment-quota    argocd
LimitRange      assignment-limits   argocd
```

No plaintext in Git. Keys tested: `DB_USER` and `DB_PASSWORD` for dev and for staging
(`POSTGRES_*` carry the same values). Each value was searched in plaintext and in base64
across the whole history (`git log -p --all -S`); every search returned 0 lines. A string
that *is* in history returns 10 lines, proving the search works:

```text
$ i=0
while IFS='=' read -r key value; do
  i=$((i+1)); env=$([ $i -le 4 ] && echo dev || echo staging)
  [ "${key#POSTGRES_}" != "$key" ] && continue   # same values as DB_*
  plain=$(git log -p --all -S"$value" | head | wc -l)
  b64=$(git log -p --all -S"$(printf %s "$value" | base64)" | head | wc -l)
  echo "$env $key: plaintext matches=$plain base64 matches=$b64"
done < ../dso202-keys/tasktracker-credentials.txt
dev DB_USER: plaintext matches=0 base64 matches=0
dev DB_PASSWORD: plaintext matches=0 base64 matches=0
staging DB_USER: plaintext matches=0 base64 matches=0
staging DB_PASSWORD: plaintext matches=0 base64 matches=0
$ git log -p --all -S'kind: SealedSecret' | head | wc -l   # control: a string that IS in history
10
$ git ls-files | grep -c -E '\.key$|sealing-key|\.backup\.yaml|secrets-plain|-plain\.yaml'
0
$ git status --short --ignored
```

## Task 5 — Workloads in two environments

All Applications, the Pod creation order in dev (database ready → backend created; backend
ready → frontend created; frontend ready → smoke test), and the smoke-test log:

```text
$ kubectl get applications -n argocd
NAME                  SYNC STATUS   HEALTH STATUS
platform-dev          Synced        Healthy
platform-staging      Synced        Healthy
root                  Synced        Healthy
sealed-secrets        Synced        Healthy
tasktracker-dev       Synced        Healthy
tasktracker-staging   OutOfSync     Missing
$ grep -E 'Pending +0 +0s|1/1 +Running|Completed' ../evidence/task5-dev-pods-watch.log | awk '!seen[$2 $4]++'
14:18:10  database-0   0/1     Pending   0          0s
14:18:19  database-0   1/1     Running             0          9s
14:18:19  backend-6566fcc54d-zbhsb   0/1     Pending             0          0s
14:18:25  backend-6566fcc54d-zbhsb   1/1     Running             0          6s
14:18:25  frontend-5cf56bdb9c-wfwbs   0/1     Pending             0          0s
14:18:31  frontend-5cf56bdb9c-wfwbs   1/1     Running             0          6s
14:18:31  tasktracker-smoke-test-cqwlf   0/1     Pending             0          0s
14:18:33  tasktracker-smoke-test-cqwlf   1/1     Running             0          2s
14:18:33  tasktracker-smoke-test-cqwlf   0/1     Completed           0          2s
$ kubectl get job -n dso202-dev
NAME                     STATUS     COMPLETIONS   DURATION   AGE
tasktracker-smoke-test   Complete   1/1           4s         41s
$ kubectl logs job/tasktracker-smoke-test -n dso202-dev | cut -c1-120
[{"id":1,"title":"Set up kind cluster","description":"Bring up the local cluster from Practical 1","status":"done","crea
```

`argocd app get` for both environments, and the root Application **before** the first staging sync:

```text
$ argocd app get tasktracker-dev
Name:               argocd/tasktracker-dev
Project:            dso202
Server:             https://kubernetes.default.svc
Namespace:          dso202-dev
URL:                https://localhost:8080/applications/tasktracker-dev
Source:
- Repo:             https://github.com/DechenWangdraSherpa/dso202-gitops.git
  Target:           main
  Path:             charts/tasktracker
  Helm Values:      ../../environments/dev/values.yaml
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (0becf1d)
Health Status:      Healthy

GROUP  KIND            NAMESPACE   NAME                    STATUS     HEALTH   HOOK      MESSAGE
       ServiceAccount  dso202-dev  tasktracker             Synced                        serviceaccount/tasktracker created
       ConfigMap       dso202-dev  app-config              Synced                        configmap/app-config created
       Service         dso202-dev  db-svc                  Synced     Healthy            service/db-svc created
apps   StatefulSet     dso202-dev  database                Synced     Healthy            statefulset rolling update complete 1 pods at revision database-685d6b59bc...
       Service         dso202-dev  backend-svc             Synced     Healthy            service/backend-svc created
apps   Deployment      dso202-dev  backend                 Synced     Healthy            deployment.apps/backend created
       Service         dso202-dev  frontend-svc            Synced     Healthy            service/frontend-svc created
apps   Deployment      dso202-dev  frontend                Synced     Healthy            deployment.apps/frontend created
batch  Job             dso202-dev  tasktracker-smoke-test  Succeeded  Synced   PostSync  Reached expected number of succeeded pods
$ argocd app get tasktracker-staging
Name:               argocd/tasktracker-staging
Project:            dso202
Server:             https://kubernetes.default.svc
Namespace:          dso202-staging
URL:                https://localhost:8080/applications/tasktracker-staging
Source:
- Repo:             https://github.com/DechenWangdraSherpa/dso202-gitops.git
  Target:           v1.0.0
  Path:             charts/tasktracker
  Helm Values:      ../../environments/staging/values.yaml
SyncWindow:         Sync Allowed
Sync Policy:        Manual
Sync Status:        OutOfSync from v1.0.0 (e2e7fd9)
Health Status:      Missing

GROUP  KIND            NAMESPACE       NAME          STATUS     HEALTH   HOOK  MESSAGE
       ConfigMap       dso202-staging  app-config    OutOfSync  Missing        
       Service         dso202-staging  backend-svc   OutOfSync  Missing        
       Service         dso202-staging  db-svc        OutOfSync  Missing        
       Service         dso202-staging  frontend-svc  OutOfSync  Missing        
       ServiceAccount  dso202-staging  tasktracker   OutOfSync  Missing        
apps   Deployment      dso202-staging  backend       OutOfSync  Missing        
apps   Deployment      dso202-staging  frontend      OutOfSync  Missing        
apps   StatefulSet     dso202-staging  database      OutOfSync  Missing        
$ kubectl get application root tasktracker-staging -n argocd   # root BEFORE the first staging sync
NAME                  SYNC STATUS   HEALTH STATUS
root                  Synced        Healthy
tasktracker-staging   OutOfSync     Missing
```

First manual sync of staging and the root Application **after** it:

```text
$ argocd app sync tasktracker-staging --timeout 300 | tail -12
Message:            successfully synced (no more tasks)

GROUP  KIND            NAMESPACE       NAME                    STATUS     HEALTH   HOOK      MESSAGE
       ServiceAccount  dso202-staging  tasktracker             Synced                        serviceaccount/tasktracker created
       ConfigMap       dso202-staging  app-config              Synced                        configmap/app-config created
       Service         dso202-staging  db-svc                  Synced     Healthy            service/db-svc created
apps   StatefulSet     dso202-staging  database                Synced     Healthy            statefulset rolling update complete 1 pods at revision database-7d54444bf8...
       Service         dso202-staging  backend-svc             Synced     Healthy            service/backend-svc created
apps   Deployment      dso202-staging  backend                 Synced     Healthy            deployment.apps/backend created
       Service         dso202-staging  frontend-svc            Synced     Healthy            service/frontend-svc created
apps   Deployment      dso202-staging  frontend                Synced     Healthy            deployment.apps/frontend created
batch  Job             dso202-staging  tasktracker-smoke-test  Succeeded  Synced   PostSync  Reached expected number of succeeded pods
$ kubectl get application root tasktracker-staging -n argocd   # root AFTER the first staging sync
NAME                  SYNC STATUS   HEALTH STATUS
root                  Synced        Healthy
tasktracker-staging   Synced        Healthy
$ kubectl get svc -n dso202-staging
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
backend-svc    ClusterIP   10.96.230.56    <none>        8080/TCP       16s
db-svc         ClusterIP   None            <none>        5432/TCP       25s
frontend-svc   NodePort    10.96.253.120   <none>        80:30081/TCP   10s
$ kubectl logs job/tasktracker-smoke-test -n dso202-staging | cut -c1-100
[{"id":1,"title":"Set up kind cluster","description":"Bring up the local cluster from Practical 1","
```

Observation on the root: the brief expects `root` to stay `Progressing` while staging has
never been synced. Here it reported `Healthy` with the child `tasktracker-staging` at
`Missing`. The restored health check *does* pass child health upwards — `root` went to
`Progressing` while `tasktracker-dev` was progressing through its waves (see
`evidence/task5-applications-watch.log`, 14:18:09–14:18:31) and to `Degraded` in Task 7 —
but in Argo CD v3.5.6 a child reporting `Missing` did not lower the parent's health.

Both frontends serve, and a CRUD cycle in dev (through the backend API, which the browser
UI also calls):

```text
$ kubectl port-forward -n dso202-staging svc/frontend-svc 8081:80 &
Forwarding from 127.0.0.1:8081 -> 8080
Forwarding from [::1]:8081 -> 8080
$ kubectl port-forward -n dso202-dev svc/backend-svc 8082:8080 &
Forwarding from 127.0.0.1:8082 -> 8080
Forwarding from [::1]:8082 -> 8080
$ curl -s http://localhost:30080 | grep -E '<h1>|subhead'
        <h1>Field&nbsp;Log</h1>
      <p class="subhead">task tracker &mdash; unit i deployment demo</p>
$ curl -s http://localhost:8081 | grep -E '<h1>|subhead'
        <h1>Field&nbsp;Log</h1>
      <p class="subhead">task tracker &mdash; unit i deployment demo</p>
$ curl -s -X POST http://localhost:8082/api/tasks -H 'Content-Type: application/json' -d '{"title":"GitOps CRUD check","description":"created in dev"}'
{"id":4,"title":"GitOps CRUD check","description":"created in dev","status":"pending","created_at":"2026-11-20T08:19:59.441Z"}
$ curl -s http://localhost:8082/api/tasks/4
{"id":4,"title":"GitOps CRUD check","description":"created in dev","status":"pending","created_at":"2026-11-20T08:19:59.441Z"}
$ curl -s -X PUT http://localhost:8082/api/tasks/4 -H 'Content-Type: application/json' -d '{"status":"done"}'
{"id":4,"title":"GitOps CRUD check","description":"created in dev","status":"done","created_at":"2026-11-20T08:19:59.441Z"}
$ curl -s -X DELETE -o /dev/null -w '%{http_code}\n' http://localhost:8082/api/tasks/4
204
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8082/api/tasks/4
404
$ kill %1 %2
```

## Task 6 — Argo CD access control

`reviewer` exists, password set (from a file outside the repository), separate context,
and the three permission states:

```text
$ argocd account list
NAME      ENABLED  CAPABILITIES
admin     true     login
reviewer  true     login
$ argocd account update-password --account reviewer \
  --current-password "$(argocd admin initial-password -n argocd | head -1)" \
  --new-password "$(cat ../dso202-keys/argocd-reviewer-password.txt)"
Password updated
$ argocd login localhost:8080 --username reviewer --password "$(cat ../dso202-keys/argocd-reviewer-password.txt)" --insecure --name reviewer
'reviewer:login' logged in successfully
Context 'reviewer' updated
$ argocd --argocd-context reviewer app list -o name
argocd/tasktracker-dev
argocd/tasktracker-staging
$ argocd --argocd-context reviewer account can-i get applications 'dso202/*'
yes
$ argocd --argocd-context reviewer account can-i sync applications 'dso202/*'
no
$ argocd --argocd-context reviewer account can-i get logs 'dso202/tasktracker-dev'
no
$ argocd --argocd-context reviewer proj get platform
{"level":"fatal","msg":"rpc error: code = PermissionDenied desc = permission denied: projects, get, platform, sub: reviewer, iat: 2026-11-20T08:20:56Z","time":"2026-11-20T14:20:56+06:00"}
```

Log rule enabled by commit `4bbf56f`, then the bootstrap layer re-applied by hand
(git alone does not deliver it). `can-i get logs` turns from `no` to `yes`; the CLI is
returned to the admin context:

```text
$ git log --oneline -1 -- bootstrap/argocd/argocd-rbac-cm-patch.yaml
4bbf56f Grant reviewer read access to logs in the dso202 project (Task 6)
$ argocd --argocd-context reviewer account can-i get logs 'dso202/tasktracker-dev'   # before re-applying the bootstrap layer
no
$ kubectl apply -k bootstrap/argocd --server-side --force-conflicts | grep -E 'configmap/argocd-(rbac-)?cm'
configmap/argocd-cm serverside-applied
configmap/argocd-cmd-params-cm serverside-applied
configmap/argocd-rbac-cm serverside-applied
$ sleep 20; argocd --argocd-context reviewer account can-i get logs 'dso202/tasktracker-dev'
yes
$ argocd --argocd-context reviewer app logs tasktracker-dev --kind Deployment --group apps --name backend --tail 5
[db] connected
[server] listening on :8080
$ argocd login localhost:8080 --username admin --password "$(argocd admin initial-password -n argocd | head -1)" --insecure
'admin:login' logged in successfully
Context 'localhost:8080' updated
$ argocd context
CURRENT  NAME            SERVER
*        localhost:8080  localhost:8080
         reviewer        localhost:8080
```

Reviewer UI session showing Pod logs: report `screenshots/19-task6-reviewer-logs-ui.png`.
This needed commit `3a45b61` (ReplicaSet and Pod added to the `dso202` whitelist): before
it, `argocd app logs` returned nothing even for admin, because Argo CD omits resources of
non-permitted kinds from the application tree.

## Task 7 — Release, failure and recovery through Git

Pull requests (all squash-merged):

```text
$ curl -s 'https://api.github.com/repos/DechenWangdraSherpa/dso202-gitops/pulls?state=all&direction=asc' | jq -r '.[] | "#\(.number)  \(.state)  merged=\(.merged_at != null)  \(.head.ref) -> \(.base.ref)  \(.title)"'
#1  closed  merged=true  release/frontend-1.1 -> main  Release frontend 1.1 to dev and staging values
#2  closed  merged=true  promote/staging-v1.1.0 -> main  Promote staging to v1.1.0
#3  closed  merged=true  release/backend-1.1 -> main  Release backend 1.1 to dev and staging values
#4  closed  merged=true  revert/backend-1.1 -> main  Revert "Release backend 1.1 to dev and staging values (#3)"
#5  closed  merged=true  fix/backend-1.1-sslmode -> main  Fix forward: backend 1.1 with DB_SSLMODE=disable
#6  closed  merged=true  promote/staging-v1.2.0 -> main  Promote staging to v1.2.0
$ git log --oneline --graph --decorate -n 15
* b074c7a (HEAD -> main, origin/main, origin/HEAD) Promote staging to v1.2.0 (#6)
* 8847839 (tag: v1.2.0) Fix forward: backend 1.1 with DB_SSLMODE=disable (#5)
* 55844bb Revert "Release backend 1.1 to dev and staging values (#3)" (#4)
* 52f24e6 Release backend 1.1 to dev and staging values (#3)
* 76010b6 Promote staging to v1.1.0 (#2)
* 5100179 (tag: v1.1.0) Release frontend 1.1 to dev and staging values (#1)
* 3a45b61 Permit controller-created ReplicaSets and Pods in dso202 so Pod logs are visible (Task 6)
* 4bbf56f Grant reviewer read access to logs in the dso202 project (Task 6)
* 0becf1d Add tasktracker-dev (main, automated) and tasktracker-staging (v1.0.0, manual) Applications (Listings 14, 15)
* e2e7fd9 (tag: v1.0.0) Add PostSync smoke-test hook Job to the chart (Listing 13)
* 276a8f4 Add platform-dev and platform-staging Applications (Listing 10)
* 2c77ad1 Add sealed Task Tracker credentials for dev and staging (Listing 12)
* 9f55e84 Install Sealed Secrets controller 0.40.0 (chart 2.20.0) through Argo CD (Listing 9)
* 51d9964 Add platform and dso202 AppProjects and the root Application (Listings 6-8)
* 2f5ce51 Add pinned Argo CD v3.5.6 bootstrap (Kustomize, Listings 2-5)
```

**Part A.** Frontend 1.1 reaches dev (frontend replaced, smoke test re-runs, header shows
the release); staging still serves the old page:

```text
$ grep -E 'frontend|smoke' ../evidence/task7-dev-pods-watch.log | grep -E 'Pending +0 +0s|1/1 +Running|Terminating|Completed' | awk '!seen[$2 $4]++'
14:32:11  frontend-5cf56bdb9c-wfwbs      1/1     Running     0          13m
14:32:11  tasktracker-smoke-test-cqwlf   0/1     Completed   0          13m
14:39:02  frontend-66bcbf457b-pv8vt      0/1     Pending     0          0s
14:39:08  frontend-66bcbf457b-pv8vt      1/1     Running             0          6s
14:39:08  frontend-5cf56bdb9c-wfwbs      1/1     Terminating         0          20m
14:39:09  tasktracker-smoke-test-4vl44   0/1     Pending             0          0s
14:39:09  frontend-5cf56bdb9c-wfwbs      0/1     Completed           0          20m
14:39:10  tasktracker-smoke-test-4vl44   1/1     Running             0          1s
14:39:10  tasktracker-smoke-test-4vl44   0/1     Completed           0          1s
$ argocd app history tasktracker-dev
SOURCE  https://github.com/DechenWangdraSherpa/dso202-gitops.git
ID      DATE                           REVISION
0       2026-11-20 14:18:35 +0600 +06  main (0becf1d)
1       2026-11-20 14:39:12 +0600 +06  main (5100179)
$ kubectl get deploy frontend -n dso202-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
dwangshers/dso202-amd64-frontend:1.1
$ curl -s http://localhost:30080 | grep '<h1>'       # dev
        <h1>Field&nbsp;Log <small class="release">release 1.1</small></h1>
$ curl -s http://localhost:8081 | grep '<h1>'        # staging (port-forward)
        <h1>Field&nbsp;Log</h1>
```

Promotion: tag `v1.1.0`, PR #2 moves the staging gate; staging is `OutOfSync` and still old
until a person syncs it:

```text
$ argocd app get tasktracker-staging | sed -n '/^Source/,/^Health/p;/frontend /p'
Source:
- Repo:             https://github.com/DechenWangdraSherpa/dso202-gitops.git
  Target:           v1.1.0
  Path:             charts/tasktracker
  Helm Values:      ../../environments/staging/values.yaml
SyncWindow:         Sync Allowed
Sync Policy:        Manual
Sync Status:        OutOfSync from v1.1.0 (5100179)
Health Status:      Healthy
apps   Deployment      dso202-staging  frontend                OutOfSync  Healthy            deployment.apps/frontend created
$ curl -s http://localhost:8081 | grep '<h1>'        # staging still old before the sync
        <h1>Field&nbsp;Log</h1>
$ argocd app sync tasktracker-staging --timeout 300 | grep -E 'Sync Revision|Phase|Message|frontend |smoke'
2026-11-20T14:43:21+06:00   apps  Deployment      dso202-staging              frontend    OutOfSync  Healthy              
2026-11-20T14:43:21+06:00  batch         Job      dso202-staging  tasktracker-smoke-test             Healthy              
2026-11-20T14:43:26+06:00   apps  Deployment  dso202-staging              frontend    Synced  Progressing              
2026-11-20T14:43:28+06:00   apps  Deployment  dso202-staging              frontend    Synced  Progressing              deployment.apps/frontend configured
2026-11-20T14:43:32+06:00   apps  Deployment  dso202-staging              frontend    Synced  Healthy              deployment.apps/frontend configured
2026-11-20T14:43:32+06:00  batch         Job  dso202-staging  tasktracker-smoke-test   Running   Synced    PostSync  job.batch/tasktracker-smoke-test created
2026-11-20T14:43:36+06:00  batch         Job  dso202-staging  tasktracker-smoke-test  Succeeded   Synced    PostSync  Reached expected number of succeeded pods
Sync Revision:      51001797238b78acc89d972548e1d789056beede
Phase:              Succeeded
Message:            successfully synced (no more tasks)
apps   Deployment      dso202-staging  frontend                Synced     Healthy            deployment.apps/frontend configured
batch  Job             dso202-staging  tasktracker-smoke-test  Succeeded  Synced   PostSync  Reached expected number of succeeded pods
$ kubectl port-forward -n dso202-staging svc/frontend-svc 8081:80 &   # old Pod was replaced, so forward again
Forwarding from 127.0.0.1:8081 -> 8080
Forwarding from [::1]:8081 -> 8080
$ curl -s http://localhost:8081 | grep '<h1>'        # staging after the manual sync
        <h1>Field&nbsp;Log <small class="release">release 1.1</small></h1>
$ argocd app history tasktracker-staging
SOURCE  https://github.com/DechenWangdraSherpa/dso202-gitops.git
ID      DATE                           REVISION
0       2026-11-20 14:19:46 +0600 +06  v1.0.0 (e2e7fd9)
1       2026-11-20 14:43:36 +0600 +06  v1.1.0 (5100179)
```

**Part B.** Bad commit on `main`: `52f24e6` (PR #3). Observations in dev without
intervening — new backend Pod `CrashLoopBackOff`, old Pod still `Running` and serving,
Application `Synced` + `Degraded` after the 120 s progress deadline, root `Degraded`, smoke
test **not** re-run (the Job shown is the previous one), frontend still HTTP 200:

```text
$ kubectl get applications -n argocd
NAME                  SYNC STATUS   HEALTH STATUS
platform-dev          Synced        Healthy
platform-staging      Synced        Healthy
root                  Synced        Degraded
sealed-secrets        Synced        Healthy
tasktracker-dev       Synced        Degraded
tasktracker-staging   Synced        Healthy
$ kubectl get pods -n dso202-dev
NAME                           READY   STATUS             RESTARTS      AGE
backend-6566fcc54d-zbhsb       1/1     Running            0             31m
backend-6bd9494747-cm48x       0/1     CrashLoopBackOff   4 (31s ago)   2m11s
database-0                     1/1     Running            0             31m
frontend-66bcbf457b-pv8vt      1/1     Running            0             10m
tasktracker-smoke-test-4vl44   0/1     Completed          0             10m
$ argocd app get tasktracker-dev | grep -E 'Sync Status|Health Status|Deployment .*backend|smoke'
Sync Status:        Synced to main (52f24e6)
Health Status:      Degraded
apps   Deployment      dso202-dev  backend                 Synced  Degraded        Deployment "backend" exceeded its progress deadline
batch  Job             dso202-dev  tasktracker-smoke-test          Healthy         
$ kubectl get deploy backend -n dso202-dev -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
Available=True MinimumReplicasAvailable: Deployment has minimum availability.
Progressing=False ProgressDeadlineExceeded: ReplicaSet "backend-6bd9494747" has timed out progressing.
$ curl -s -o /dev/null -w 'dev frontend HTTP %{http_code}\n' http://localhost:30080
dev frontend HTTP 200
$ curl -s http://localhost:8082/api/status; echo
{"status":"ok","db":"connected"}
```

Diagnosis and the rollback refusal. The log line: `[config] FATAL: required environment
variable DB_SSLMODE is not set (DB_SSLMODE must be one of: disable, require)`.

```text
$ kubectl describe pod backend-6bd9494747-cm48x -n dso202-dev | sed -n '/^Containers:/,/^Conditions:/p' | grep -E 'Image:|State:|Reason:|Exit Code|Restart Count|Last State'
    Image:          dwangshers/dso202-amd64-backend:1.1
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
    Restart Count:  4
$ kubectl describe pod backend-6bd9494747-cm48x -n dso202-dev | sed -n '/^Events:/,$p' | tail -5
  Normal   Scheduled  2m12s                default-scheduler  Successfully assigned dso202-dev/backend-6bd9494747-cm48x to worker-node-2
  Normal   Pulled     33s (x5 over 2m12s)  kubelet            spec.containers{api}: Container image "dwangshers/dso202-amd64-backend:1.1" already present on machine and can be accessed by the pod
  Normal   Created    33s (x5 over 2m12s)  kubelet            spec.containers{api}: Container created
  Normal   Started    33s (x5 over 2m11s)  kubelet            spec.containers{api}: Container started
  Warning  BackOff    31s (x7 over 2m9s)   kubelet            spec.containers{api}: Back-off restarting failed container api in pod backend-6bd9494747-cm48x_dso202-dev(debb42ce-bd2e-452d-9183-84c01bf71b49)
$ kubectl logs backend-6bd9494747-cm48x -n dso202-dev
[config] FATAL: required environment variable DB_SSLMODE is not set (DB_SSLMODE must be one of: disable, require)
$ argocd app rollback tasktracker-dev
{"level":"fatal","msg":"rpc error: code = FailedPrecondition desc = rollback cannot be initiated when auto-sync is enabled","time":"2026-11-20T14:49:48+06:00"}
```

Recovery by `git revert` (PR #4, commit `55844bb`). The revert's automated sync started
only at 14:57:59, when the sync of the bad commit finished failing after its 5 retries;
the bad revision never appears in `app history` because only successful syncs are recorded:

```text
$ git log --oneline -4
55844bb Revert "Release backend 1.1 to dev and staging values (#3)" (#4)
52f24e6 Release backend 1.1 to dev and staging values (#3)
76010b6 Promote staging to v1.1.0 (#2)
5100179 Release frontend 1.1 to dev and staging values (#1)
$ kubectl get events -n argocd --field-selector involvedObject.name=tasktracker-dev --sort-by=.lastTimestamp | grep -E 'Operation' | tail -4 | cut -c1-175
11m         Normal    OperationStarted     application/tasktracker-dev   Initiated automated sync to '52f24e6dd656dedf5701380eeff0c03a4f779ca6'
37s         Warning   OperationCompleted   application/tasktracker-dev   Sync operation to 52f24e6dd656dedf5701380eeff0c03a4f779ca6 failed: one or more synchronization tasks c
36s         Normal    OperationStarted     application/tasktracker-dev   Initiated automated sync to '55844bb864c0e25a0bddf744772d427ed98e1ad6'
24s         Normal    OperationCompleted   application/tasktracker-dev   Sync operation to 55844bb864c0e25a0bddf744772d427ed98e1ad6 succeeded
$ argocd app history tasktracker-dev
SOURCE  https://github.com/DechenWangdraSherpa/dso202-gitops.git
ID      DATE                           REVISION
0       2026-11-20 14:18:35 +0600 +06  main (0becf1d)
1       2026-11-20 14:39:12 +0600 +06  main (5100179)
2       2026-11-20 14:58:11 +0600 +06  main (55844bb)
$ kubectl get applications tasktracker-dev root -n argocd
NAME              SYNC STATUS   HEALTH STATUS
tasktracker-dev   Synced        Healthy
root              Synced        Healthy
$ kubectl get pods -n dso202-dev
NAME                           READY   STATUS      RESTARTS   AGE
backend-6566fcc54d-zbhsb       1/1     Running     0          40m
database-0                     1/1     Running     0          40m
frontend-66bcbf457b-pv8vt      1/1     Running     0          19m
tasktracker-smoke-test-mc4c9   0/1     Completed   0          29s
$ kubectl get deploy backend -n dso202-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
dwangshers/dso202-amd64-backend:1.0
```

Fix forward (PR #5, `8847839`): backend 1.1 plus `backend.env.DB_SSLMODE: disable`:

```text
$ kubectl get pods -n dso202-dev
NAME                           READY   STATUS      RESTARTS   AGE
backend-66896f5474-mhbk5       1/1     Running     0          58s
database-0                     1/1     Running     0          43m
frontend-66bcbf457b-pv8vt      1/1     Running     0          22m
tasktracker-smoke-test-vpsf7   0/1     Completed   0          51s
$ kubectl get deploy backend -n dso202-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
dwangshers/dso202-amd64-backend:1.1
$ kubectl logs backend-66896f5474-mhbk5 -n dso202-dev
[config] release 1.1, sslmode=disable
[db] connected
[server] listening on :8080
$ kubectl logs job/tasktracker-smoke-test -n dso202-dev | cut -c1-100
[{"id":1,"title":"Set up kind cluster","description":"Bring up the local cluster from Practical 1","
$ argocd app get tasktracker-dev | grep -E 'Sync Status|Health Status'
Sync Status:        Synced to main (8847839)
Health Status:      Healthy
$ argocd app history tasktracker-dev
SOURCE  https://github.com/DechenWangdraSherpa/dso202-gitops.git
ID      DATE                           REVISION
0       2026-11-20 14:18:35 +0600 +06  main (0becf1d)
1       2026-11-20 14:39:12 +0600 +06  main (5100179)
2       2026-11-20 14:58:11 +0600 +06  main (55844bb)
3       2026-11-20 15:00:37 +0600 +06  main (8847839)
```

Promotion of the fixed release (tag `v1.2.0`, PR #6, manual sync). Staging history contains
v1.0.0, v1.1.0 and v1.2.0 only; the faulty combination (backend 1.1 without `DB_SSLMODE`,
commit `52f24e6`) was never a staging revision:

```text
$ argocd app get tasktracker-staging | grep -E 'Target|Sync Status|Health Status|Deployment .*backend'
  Target:           v1.2.0
Sync Status:        OutOfSync from v1.2.0 (8847839)
Health Status:      Healthy
apps   Deployment      dso202-staging  backend                 OutOfSync  Healthy            deployment.apps/backend unchanged
$ argocd app sync tasktracker-staging --timeout 300 | grep -E '^(Sync Revision|Phase|Message):'
Sync Revision:      8847839ba9933c396480a708e77d7d951339f027
Phase:              Succeeded
Message:            successfully synced (no more tasks)
$ kubectl get deploy backend -n dso202-staging -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
dwangshers/dso202-amd64-backend:1.1
$ argocd app get tasktracker-staging | grep -E 'Sync Status|Health Status|smoke'
Sync Status:        Synced to v1.2.0 (8847839)
Health Status:      Healthy
batch  Job             dso202-staging  tasktracker-smoke-test  Succeeded  Synced   PostSync  Reached expected number of succeeded pods
$ argocd app history tasktracker-staging
SOURCE  https://github.com/DechenWangdraSherpa/dso202-gitops.git
ID      DATE                           REVISION
0       2026-11-20 14:19:46 +0600 +06  v1.0.0 (e2e7fd9)
1       2026-11-20 14:43:36 +0600 +06  v1.1.0 (5100179)
2       2026-11-20 15:06:25 +0600 +06  v1.2.0 (8847839)
$ for rev in v1.0.0 v1.1.0 52f24e6 v1.2.0; do
  f=$(git show ${rev}:environments/staging/values.yaml)
  printf '%-7s backend %s  DB_SSLMODE=%s\n' $rev \
    "$(echo $f | grep -A5 '^backend:' | grep -o 'tag: "[0-9.]*"')" "$(echo $f | grep -o 'DB_SSLMODE: [a-z]*' | cut -d' ' -f2)"
done
v1.0.0  backend tag: "1.0"  DB_SSLMODE=
v1.1.0  backend tag: "1.0"  DB_SSLMODE=
52f24e6 backend tag: "1.1"  DB_SSLMODE=
v1.2.0  backend tag: "1.1"  DB_SSLMODE=disable
```

## Task 8 — Drift drills

**Drill 1 — drift in dev.**
*Prediction:* scaling `backend` to 3 by hand is reverted to 1 within seconds, because
`tasktracker-dev` has `selfHeal: true`.

```text
$ kubectl get deployment/backend -n dso202-dev -w | while IFS= read -r l; do print -r -- "$(date +%T)  $l"; done > ../evidence/task8-drill1-dev-watch.log &
$ kubectl scale deployment/backend -n dso202-dev --replicas=3
deployment.apps/backend scaled
$ cat ../evidence/task8-drill1-dev-watch.log
15:06:56  NAME      READY   UP-TO-DATE   AVAILABLE   AGE
15:06:56  backend   1/1     1            1           48m
15:06:59  backend   1/3     1            1           48m
15:06:59  backend   1/3     1            1           48m
15:06:59  backend   1/3     1            1           48m
15:06:59  backend   1/3     3            1           48m
15:06:59  backend   1/1     3            1           48m
15:06:59  backend   1/1     3            1           48m
15:06:59  backend   1/1     3            1           48m
15:06:59  backend   1/1     1            1           48m
15:07:30  backend   1/1     1            1           49m
15:07:31  backend   1/1     1            1           49m
$ kubectl get events -n argocd --field-selector involvedObject.name=tasktracker-dev --sort-by=.lastTimestamp | grep -E 'OutOfSync|Partial sync' | tail -2 | cut -c1-150
41s         Normal    OperationCompleted   application/tasktracker-dev   Partial sync operation to b074c7ac6ac45afd1dbd7cda73d00e6d7d967269 succeeded
41s         Normal    ResourceUpdated      application/tasktracker-dev   Updated sync status: OutOfSync -> Synced
$ kubectl get deployment/backend -n dso202-dev
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
backend   1/1     1            1           49m
```

*Result:* prediction held. The scale to 3 at 15:06:59 was undone in the same second
(`UP-TO-DATE 3 → 1`) by a self-heal "partial sync" — principle 4, `selfHeal: true`.

**Drill 2 — drift in staging.**
*Prediction:* the scale stays at 3; Argo CD reports `OutOfSync` with a `replicas` diff but
changes nothing until a person syncs, because staging has no `automated` block.

```text
$ kubectl scale deployment/backend -n dso202-staging --replicas=3
deployment.apps/backend scaled
$ sleep 75; kubectl get deployment/backend -n dso202-staging   # 75 s later: not reverted
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
backend   3/3     3            3           49m
$ argocd app get tasktracker-staging | grep -E 'Sync Policy|Sync Status|Health Status|Deployment .*backend'
Sync Policy:        Manual
Sync Status:        OutOfSync from v1.2.0 (8847839)
Health Status:      Healthy
apps   Deployment      dso202-staging  backend                 OutOfSync  Healthy            deployment.apps/backend configured
$ argocd app diff tasktracker-staging

===== apps/Deployment dso202-staging/backend ======
207c207
<   replicas: 3
---
>   replicas: 1
$ argocd app sync tasktracker-staging --timeout 300 | grep -E '^(Phase|Message):'
Phase:              Succeeded
Message:            successfully synced (no more tasks)
$ kubectl get deployment/backend -n dso202-staging
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
backend   1/1     1            1           49m
```

*Result:* prediction held — 3/3 replicas 75 s later, `OutOfSync`, diff `replicas: 3` vs
`1`; the manual sync restored 1. Detection is continuous; correction is gated (manual sync policy).

**Drill 3 — removing a file prunes the object.**
*Prediction:* the ConfigMap appears after the add commit and is deleted after the `git rm`
commit, because `platform-dev` has `prune: true`.

```text
$ git log --oneline -1 -- platform/dev/prune-drill.yaml
0ee9e15 Drill 3: add prune-drill ConfigMap (Listing 16)
$ kubectl get configmap prune-drill -n dso202-dev
NAME          DATA   AGE
prune-drill   1      4s
$ git log --oneline -2 -- platform/dev/prune-drill.yaml
3aee28f Drill 3: remove prune-drill ConfigMap from Git
0ee9e15 Drill 3: add prune-drill ConfigMap (Listing 16)
$ kubectl get configmap prune-drill -n dso202-dev
Error from server (NotFound): configmaps "prune-drill" not found
$ kubectl get events -n argocd --field-selector involvedObject.name=platform-dev --sort-by=.lastTimestamp | grep -i -E 'prune|deleted|Operation' | tail -3 | cut -c1-160
111s        Normal   OperationCompleted   application/platform-dev   Sync operation to 0ee9e1524c5e74f14cd6136e745df9d751f117e3 succeeded
5s          Normal   OperationStarted     application/platform-dev   Initiated automated sync to '3aee28f6f3685868f8d1c4e9f702005563de3ffc'
4s          Normal   OperationCompleted   application/platform-dev   Sync operation to 3aee28f6f3685868f8d1c4e9f702005563de3ffc succeeded
$ argocd app get platform-dev | grep -E 'Sync Status|Health Status'
Sync Status:        Synced to main (3aee28f)
Health Status:      Healthy
$ kubectl get namespace dso202-dev -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}{"\n"}'
Prune=false
```

*Result:* prediction held — `NotFound` after the removal commit `3aee28f`. The namespace
carries `argocd.argoproj.io/sync-options: Prune=false`, so deleting
`platform/dev/namespace.yaml` would *not* delete `dso202-dev` and everything in it; that
protection was explained, not tested.

**Drill 4 — the project rejects a kind it does not permit.**
*Prediction:* the sync of `tasktracker-dev` is refused with a "not permitted in project
dso202" message, nothing is created, and staging is unaffected because it reads tag `v1.2.0`,
which does not contain the drill commit.

```text
$ argocd app get tasktracker-dev | grep -E 'Sync Status|Health Status|ResourceQuota'
Sync Status:        OutOfSync from main (02c081b)
Health Status:      Healthy
       ResourceQuota   dso202-dev  drill-quota             Unknown  Missing        resource :ResourceQuota is not permitted in project dso202
$ kubectl get application tasktracker-dev -n argocd -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
Running: one or more synchronization tasks are not valid: resource :ResourceQuota is not permitted in project dso202. Retrying attempt #3 at 9:20AM.
$ kubectl get applications -n argocd
NAME                  SYNC STATUS   HEALTH STATUS
platform-dev          Synced        Healthy
platform-staging      Synced        Healthy
root                  Synced        Healthy
sealed-secrets        Synced        Healthy
tasktracker-dev       OutOfSync     Healthy
tasktracker-staging   Synced        Healthy
$ kubectl get resourcequota -n dso202-dev -o name
resourcequota/assignment-quota
$ argocd app get tasktracker-staging | grep -E 'Target|Sync Status|Health Status'
  Target:           v1.2.0
Sync Status:        Synced to v1.2.0 (8847839)
Health Status:      Healthy
$ git log --oneline -2
53ebfd7 Revert "Drill 4: add a ResourceQuota to the workload chart (Listing 17)"
02c081b Drill 4: add a ResourceQuota to the workload chart (Listing 17)
$ argocd app get tasktracker-dev --show-operation | grep -E '^(Sync Revision|Phase|Sync Status|Health Status):'
Sync Status:        Synced to main (53ebfd7)
Health Status:      Healthy
Sync Revision:      02c081b1713975bca2683c13d7e073b47fa3df6c
Phase:              Failed
```

*Result:* prediction held. Exact message: `one or more synchronization tasks are not valid:
resource :ResourceQuota is not permitted in project dso202`. Dev stayed `Healthy` (nothing
applied), staging stayed `Synced` on `v1.2.0`. After the revert (`53ebfd7`) dev is `Synced`
again; the last *operation* still reads `Failed` because it is the exhausted sync of
`02c081b` — the revert's manifests equal the live state, so no new operation was needed.
Explained by `namespaceResourceWhitelist` in `argocd/projects/dso202.yaml` (least privilege).

## Task 9 — Rebuild from the repository and one key

Step 1 — fresh backup and the record to compare against:

```text
$ kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ../dso202-keys/sealing-key.backup.yaml && chmod 600 ../dso202-keys/sealing-key.backup.yaml
$ ls -l ../dso202-keys/sealing-key.backup.yaml
-rw------- 1 dw4ngsh3rs dw4ngsh3rs 7087 Nov 20 15:37 ../dso202-keys/sealing-key.backup.yaml
$ kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key
NAME                      TYPE                DATA   AGE
sealed-secrets-keyfl2m8   kubernetes.io/tls   2      88m
$ git rev-parse HEAD
53ebfd79cb75637718a88b714956870be85fb648
$ kubectl get applications -n argocd
NAME                  SYNC STATUS   HEALTH STATUS
platform-dev          Synced        Healthy
platform-staging      Synced        Healthy
root                  Synced        Healthy
sealed-secrets        Synced        Healthy
tasktracker-dev       Synced        Healthy
tasktracker-staging   Synced        Healthy
$ argocd app get tasktracker-staging | grep Target
  Target:           v1.2.0
```

Steps 2–3 — delete, create, load images from the host (section 13: the `1.1` images are not
on Docker Hub), restore the key **before** the controller exists:

```text
$ date
Fri Nov 20 03:37:44 PM +06 2026
$ kind delete cluster --name dso202-gitops
Deleting cluster "dso202-gitops" ...
Deleted nodes: ["dso202-gitops-control-plane" "dso202-gitops-worker" "dso202-gitops-worker2"]
$ date +%T && kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml 2>&1 | tail -4
15:37:48

kubectl cluster-info --context kind-dso202-gitops

Have a nice day! 👋
$ kubectl get nodes
NAME            STATUS     ROLES           AGE   VERSION
control-plane   NotReady   control-plane   10s   v1.36.1
worker-node-1   NotReady   <none>          0s    v1.36.1
worker-node-2   NotReady   <none>          0s    v1.36.1
$ for img in quay.io/argoproj/argocd:v3.5.6 ghcr.io/dexidp/dex:v2.45.1 public.ecr.aws/docker/library/redis:8.2.3-alpine \
    docker.io/bitnami/sealed-secrets-controller:0.40.0 busybox:1.37 dwangshers/dso202-amd64-db:1.0 \
    dwangshers/dso202-amd64-frontend:1.1 dwangshers/dso202-amd64-backend:1.1; do
  kind load docker-image $img --name dso202-gitops >/dev/null 2>&1 && echo "loaded $img"
done
loaded quay.io/argoproj/argocd:v3.5.6
loaded ghcr.io/dexidp/dex:v2.45.1
loaded public.ecr.aws/docker/library/redis:8.2.3-alpine
loaded docker.io/bitnami/sealed-secrets-controller:0.40.0
loaded busybox:1.37
loaded dwangshers/dso202-amd64-db:1.0
loaded dwangshers/dso202-amd64-frontend:1.1
loaded dwangshers/dso202-amd64-backend:1.1
$ kubectl create namespace sealed-secrets
namespace/sealed-secrets created
$ kubectl apply -f ../dso202-keys/sealing-key.backup.yaml
secret/sealed-secrets-keyfl2m8 created
$ kubectl get secret -n sealed-secrets
NAME                      TYPE                DATA   AGE
sealed-secrets-keyfl2m8   kubernetes.io/tls   2      0s
```

Step 4 — the two bootstrap steps, nothing else applied by hand:

```text
$ kubectl apply -k bootstrap/argocd --server-side --force-conflicts | tail -2
networkpolicy.networking.k8s.io/argocd-repo-server-network-policy serverside-applied
networkpolicy.networking.k8s.io/argocd-server-network-policy serverside-applied
$ kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
deployment.apps/argocd-applicationset-controller condition met
deployment.apps/argocd-dex-server condition met
deployment.apps/argocd-notifications-controller condition met
deployment.apps/argocd-redis condition met
deployment.apps/argocd-repo-server condition met
deployment.apps/argocd-server condition met
$ kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
partitioned roll out complete: 1 new pods have been updated...
$ kubectl apply -f bootstrap/root
appproject.argoproj.io/platform created
Warning: metadata.finalizers: "resources-finalizer.argocd.argoproj.io": prefer a domain-qualified finalizer name including a path (/) to avoid accidental conflicts with other finalizer writers
application.argoproj.io/root created
```

Step 5 — order in which the Applications became `Synced`+`Healthy` (full watch in
`evidence/task9-applications-watch.log`). The platform Applications became Healthy, so the
restored key decrypted both SealedSecrets:

```text
$ head -1 ../evidence/task9-applications-watch.log; awk '$3=="Synced" && $4=="Healthy" && !seen[$2]++' ../evidence/task9-applications-watch.log
15:40:28  NAME   SYNC STATUS   HEALTH STATUS
15:40:38  sealed-secrets   Synced        Healthy
15:40:40  platform-dev       Synced        Healthy
15:40:40  platform-staging   Synced        Healthy
15:40:41  root                  Synced        Healthy
15:41:03  tasktracker-dev       Synced        Healthy
$ kubectl get applications -n argocd
NAME                  SYNC STATUS   HEALTH STATUS
platform-dev          Synced        Healthy
platform-staging      Synced        Healthy
root                  Synced        Healthy
sealed-secrets        Synced        Healthy
tasktracker-dev       Synced        Healthy
tasktracker-staging   OutOfSync     Missing
$ kubectl get sealedsecret -A
NAMESPACE        NAME                      STATUS   SYNCED   AGE
dso202-dev       tasktracker-credentials            True     42s
dso202-staging   tasktracker-credentials            True     42s
```

Steps 6–7 — sign in again (new admin password), manual staging sync, both smoke tests:

```text
$ argocd login localhost:8080 --username admin --password "$(argocd admin initial-password -n argocd | head -1)" --insecure
'admin:login' logged in successfully
Context 'localhost:8080' updated
$ argocd app sync tasktracker-staging --timeout 300 | grep -E '^(Sync Revision|Phase|Message):'
Sync Revision:      8847839ba9933c396480a708e77d7d951339f027
Phase:              Succeeded
Message:            successfully synced (no more tasks)
$ argocd app get tasktracker-staging | grep -E 'Target|Sync Status|Health Status'
  Target:           v1.2.0
Sync Status:        Synced to v1.2.0 (8847839)
Health Status:      Healthy
$ kubectl get applications -n argocd
NAME                  SYNC STATUS   HEALTH STATUS
platform-dev          Synced        Healthy
platform-staging      Synced        Healthy
root                  Synced        Healthy
sealed-secrets        Synced        Healthy
tasktracker-dev       Synced        Healthy
tasktracker-staging   Synced        Healthy
$ kubectl get job -A -l app=task-tracker
NAMESPACE        NAME                     STATUS     COMPLETIONS   DURATION   AGE
dso202-dev       tasktracker-smoke-test   Complete   1/1           4s         67s
dso202-staging   tasktracker-smoke-test   Complete   1/1           4s         15s
```

Step 7–8 — both frontends, one task created in each environment (the databases are new and
empty apart from the seed rows), fresh key backup, and the end time:

```text
$ kubectl port-forward -n dso202-staging svc/frontend-svc 8081:80 &
Forwarding from 127.0.0.1:8081 -> 8080
Forwarding from [::1]:8081 -> 8080
$ kubectl port-forward -n dso202-dev svc/backend-svc 8082:8080 &
Forwarding from 127.0.0.1:8082 -> 8080
Forwarding from [::1]:8082 -> 8080
$ kubectl port-forward -n dso202-staging svc/backend-svc 8083:8080 &
Forwarding from 127.0.0.1:8083 -> 8080
Forwarding from [::1]:8083 -> 8080
$ curl -s http://localhost:30080 | grep '<h1>'    # dev frontend (NodePort)
        <h1>Field&nbsp;Log <small class="release">release 1.1</small></h1>
$ curl -s http://localhost:8081 | grep '<h1>'     # staging frontend (port-forward)
        <h1>Field&nbsp;Log <small class="release">release 1.1</small></h1>
$ curl -s -X POST http://localhost:8082/api/tasks -H 'Content-Type: application/json' -d '{"title":"Rebuilt dev"}'; echo
{"id":4,"title":"Rebuilt dev","description":null,"status":"pending","created_at":"2026-11-20T09:42:13.604Z"}
$ curl -s -X POST http://localhost:8083/api/tasks -H 'Content-Type: application/json' -d '{"title":"Rebuilt staging"}'; echo
{"id":4,"title":"Rebuilt staging","description":null,"status":"pending","created_at":"2026-11-20T09:42:13.628Z"}
$ kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key
NAME                      TYPE                DATA   AGE
sealed-secrets-keyfl2m8   kubernetes.io/tls   2      2m34s
$ kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ../dso202-keys/sealing-key.backup.yaml && chmod 600 ../dso202-keys/sealing-key.backup.yaml && ls -l ../dso202-keys/sealing-key.backup.yaml
-rw------- 1 dw4ngsh3rs dw4ngsh3rs 14199 Nov 20 15:42 ../dso202-keys/sealing-key.backup.yaml
$ date
Fri Nov 20 03:42:13 PM +06 2026
```

**Elapsed time.** Start `date`: 15:37:44. `kind create cluster` started 15:37:48; the dev
frontend answered HTTP 200 at **15:41:12** — **3 min 24 s** from `kind create` to a working
dev frontend (images were loaded from the host cache). End `date`: 15:42:13 (4 min 29 s in
total). Staging is at the same tag as before the rebuild (`v1.2.0`). The new backup is
larger (14199 vs 7087 bytes) only because `kubectl apply` added a
`last-applied-configuration` annotation to the restored key; there is still exactly one key.

## Task 10 (bonus) — multi-source Application

`argocd/applications/tasktracker-dev.yaml` now has `sources:` (chart + `ref: values`), and
the values file is referenced as `$values/environments/dev/values.yaml`:

```text
$ argocd app get tasktracker-dev --refresh | sed -n '1,/^Health Status/p'
Name:               argocd/tasktracker-dev
Project:            dso202
Server:             https://kubernetes.default.svc
Namespace:          dso202-dev
URL:                https://localhost:8080/applications/tasktracker-dev
Sources:
- Repo:             https://github.com/DechenWangdraSherpa/dso202-gitops.git
  Target:           main
  Path:             charts/tasktracker
  Helm Values:      $values/environments/dev/values.yaml
- Repo:             https://github.com/DechenWangdraSherpa/dso202-gitops.git
  Target:           main
  Ref:              values
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main
Health Status:      Healthy
$ kubectl get application tasktracker-dev -n argocd -o jsonpath='{.status.sync.revisions}{"\n"}'
["7fe951b557bd6447141f4ef6f8387274404c2ed1","7fe951b557bd6447141f4ef6f8387274404c2ed1"]
$ kubectl get applications -n argocd
NAME                  SYNC STATUS   HEALTH STATUS
platform-dev          Synced        Healthy
platform-staging      Synced        Healthy
root                  Synced        Healthy
sealed-secrets        Synced        Healthy
tasktracker-dev       Synced        Healthy
tasktracker-staging   Synced        Healthy
```

Separating the sources is useful when the chart and the configuration change at different
speeds or are owned by different people: for example, a platform team publishes the chart
and pins it to a reviewed tag (`targetRevision: v1.2.0`), while each environment's values
follow a branch in a separate configuration repository that the application team may change
daily. A values change then cannot pull in an untested chart change, and a chart upgrade is
a deliberate, single-line promotion.
