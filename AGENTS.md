# AGENTS.md

Guidance for AI agents (and new contributors) working on this repository: how the
cluster is built, how GitOps works here, and how to debug or deploy applications.

## What this is

`lab254` is a GitOps-managed homelab cluster. **The repository is the source of
truth**; Flux continuously reconciles the cluster against what is pushed to
`main`. Never make permanent changes with `kubectl apply`/`kubectl edit` — they
will be overwritten or pruned. Diagnose with `kubectl`, fix in git, push, and
let Flux roll it out (or force a reconcile).

Repo: `github.com/DB-Vincent/lab254` (SSH deploy key, flux pulls from `main`).

## Cluster at a glance

| Item | Value |
|---|---|
| OS | Talos Linux v1.13.0 (immutable, **no SSH, no shell on nodes**) |
| Kubernetes | v1.36.0 |
| Nodes | `control-01` (10.252.252.157), `worker-01` (.110), `worker-02` (.111) |
| API endpoint / VIP | 10.252.252.199 (kube-vip on control-01) |
| CNI | Cilium (kube-proxy replacement, ingress controller enabled) |
| Ingress LB | `cilium-ingress` LoadBalancer at 10.252.252.32 (80/443) |
| Pod CIDR | 10.244.0.0/16 (cluster-settings: CLUSTER_CIDR 10.42.0.0/16, SERVICE_CIDR 10.43.0.0/16, NODE_CIDR 10.252.252.0/24) |
| Storage | Longhorn (default StorageClass), plus static NFS volumes from 172.16.2.23 (`/Plex` export) |
| TLS | cert-manager: `internal-ca` (LAN), `letsencrypt-prod`, `selfsigned` ClusterIssuers |
| Databases | CloudNativePG operator (`cnpg-system`) |
| Registry cache | spegel (node-local image mirroring) |
| DNS (nodes) | 10.80.80.10, 10.80.80.11 |
| Timezone | Europe/Brussels (TZ env everywhere) |

Node IPs are static, assigned by MAC in `talos/talconfig.yaml`. Machine config
patches live in `talos/patches/` (global patches + control-plane-only
`patches/controller/api-access.yaml`).

## Tooling

Required on the machine where you run commands (all installed here):

- `task` — task runner, entry point is `Taskfile.yaml` (+ `.taskfiles/*.yaml`)
- `kubectl`, `helm` — cluster access
- `flux` CLI — Flux diagnostics/reconcile
- `talosctl`, `talhelper` — node/OS operations (rarely needed day-to-day)
- `sops` + `age` — secrets; age key at `~/.config/sops/age/keys.txt`

Kubeconfig (gitignored, already present on this machine):

```sh
export KUBECONFIG=$(pwd)/kubeconfig        # repo-root copy
# or: export KUBECONFIG=$(pwd)/talos/clusterconfig/kubeconfig   # canonical location
```

## Repo layout

```
Taskfile.yaml              # task entry points: talos / sops / flux
.taskfiles/                # talos.yaml, sops.yaml, flux.yaml
talos/                     # talconfig.yaml (talhelper), patches/, clusterconfig/ (generated)
cilium-values.yaml         # bootstrap-time Cilium values (reference copy)
kubernetes/
  bootstrap/               # applied once before Flux: github-deploy-key.sops.yaml
  flux/
    config/cluster.yaml    # GitRepository + root Kustomization ("cluster")
    repositories.yaml      # Kustomization syncing HelmRepositories
    repositories/helm/     # one file per Helm repo (bjw-s, longhorn, cilium, ...)
    vars/                  # cluster-settings.yaml (ConfigMap), cluster-secrets.sops.yaml
    apps.yaml              # Kustomization "apps" → kubernetes/apps
  apps/                    # ALL workloads, one directory per namespace
    default/               # vaultwarden, immich, glance, headlamp, pocketid, jellyfin, ...
    kube-system/           # cilium, cert-manager, spegel
    media/                 # *arr stack, downloaders, navidrome, ...
    longhorn-system/       # longhorn
    cnpg-system/           # cloudnative-pg operator
```

Each app directory follows the same shape (see `kubernetes/apps/media/sonarr/`):

```
<app>/
  kustomization.yaml   # resources + configMapGenerator turning helm-values.yaml into <app>-helm-values
  helmrelease.yaml     # Flux HelmRelease (usually bjw-s `app-template` chart)
  helm-values.yaml     # the actual app configuration
  secret.sops.yaml     # optional, SOPS-encrypted
```

Some apps in `default/` use raw manifests (Deployment/Service/Ingress/PVC)
instead of Helm — e.g. jellyfin, obsidian-livesync, minecraft, tsgateway.

## How a change reaches the cluster

1. Push to `main`.
2. Flux `GitRepository lab-254` polls every 30m (only the `kubernetes/` dir is
   watched).
3. Root Kustomization `cluster` applies `kubernetes/flux/` (SOPS decryption via
   `sops-age` secret, variable substitution from `cluster-settings` /
   `cluster-secrets`).
4. Child Kustomizations:
   - `repositories` → HelmRepository CRs in flux-system
   - `apps` → everything under `kubernetes/apps/` (with the same SOPS +
     substitution; `prune: true`)
5. HelmRelease CRs then install/upgrade charts (interval 30m, 3 retries,
   cleanupOnFail).

Useful Flux commands:

```sh
flux get kustomizations -A
flux get helmreleases -A
flux reconcile source git lab-254                 # pull latest commit now
flux reconcile kustomization apps --with-source   # re-apply apps immediately
flux suspend/resume kustomization <name>          # emergency stop
```

To verify what Flux currently has applied vs. git:
`kubectl get kustomizations -n flux-system <name> -o yaml`.

## Secrets (SOPS)

- Files named `*.sops.yaml`; only `data`/`stringData` are encrypted
  (rule in `.sops.yaml`; talos sops files are fully encrypted).
- Age key lives at `~/.config/sops/age/keys.txt`; the cluster holds the same key
  in the `sops-age` secret (flux-system) for decryption at reconcile time.
- To edit a secret: `task sops:decrypt -- <file>` (in-place), edit, then
  `task sops:encrypt -- <file>`. New secrets: create plaintext `foo.sops.yaml`,
  encrypt, commit only the encrypted form.
- **Never commit plaintext secrets.** Renovate ignores `**/*.sops.*`.
- Global secrets (available to Flux substitution as `${VAR}`):
  `kubernetes/flux/vars/cluster-secrets.sops.yaml`.

## Conventions

### App deployment (Helm / app-template)

The dominant pattern is the bjw-s **`app-template`** chart (pinned version in
each `helmrelease.yaml`). Chart sources must exist as a HelmRepository under
`kubernetes/flux/repositories/helm/` (add a YAML there + list it in that
directory's `kustomization.yaml`).

- Values live in `helm-values.yaml`, exposed to the HelmRelease via
  `valuesFrom: ConfigMap/<app>-helm-values` generated by `configMapGenerator`
  with `disableNameSuffixHash: true` (so the name is stable).
- After changing `helm-values.yaml`, commit and either wait for the 30m cycle
  or run `flux reconcile kustomization apps && flux reconcile helmrelease <app> -n <ns>`.
- App must be listed in its namespace's `kustomization.yaml` resources.

### Ingress / TLS / DNS

- Ingress class: `cilium` (cluster default), always with:
  ```yaml
  ingress:
    main:
      className: cilium
      annotations:
        ingress.cilium.io/loadbalancer-mode: shared
      hosts:
        - host: <app>.lab254.lab.lan
          paths:
            - path: /
              pathType: Prefix
              service:
                identifier: main
                port: http
  ```
- Internal names resolve as `<app>.lab254.lab.lan` (Cilium/Upstream DNS).
- TLS for LAN hostnames uses the `internal-ca` ClusterIssuer (CA secret
  `ca-keypair` in kube-system); public hostnames use `letsencrypt-prod`.
  Certificates are usually created via ingress annotations or a
  `Certificate` resource in the app namespace.

### Storage

- Default StorageClass: **longhorn** (`WaitForFirstConsumer` is NOT set —
  Immediate binding). Use small PVCs for app config (2–5Gi is typical).
- Large media/data is on **NFS** `172.16.2.23:/Plex`, mounted via
  `persistence.<name>.type: nfs` (optionally with `subPath:`). Nodes have the
  NFS client extension installed (siderolabs/nfs-utils).
- NFS export is `sec=sys` with **root squash**: root inside a container cannot
  chmod/chown files owned by other UIDs — plan permissions accordingly (see
  below). Files created by pods land on NFS with the pod's UID/GID.

### File ownership / PUID / PGID (media & shared-NFS apps)

Apps that share NFS directories all run as **PUID 1000 / PGID 100** (linuxserver
convention and equivalent `runAsUser: 1000` / `runAsGroup: 100`). When several
apps must write to the same NFS tree:

- Give the pod `securityContext.fsGroup: 100` where possible.
- Use a busybox **init container** to pre-create dirs with `chmod 2775`
  (setgid keeps new files group-writable) — see slskd's `prepare-downloads`.
- Keep the shared group (GID 100) consistent across every app mounting the
  share; do not mix arbitrary UIDs.
- Remember root squash: chmod only works as the owner of the file (run init
  containers / one-off pods as the target UID, never as root).

### Misc

- TZ is `Europe/Brussels` everywhere; cluster-wide `${TIMEZONE}` substitution
  also exists via `cluster-settings`.
- Renovate keeps images/charts current (see `.renovaterc.json5`); it manages
  `helm-values.yaml` tags and flux YAML, grouped commits. Never "fix" an image
  tag Renovate tracks unless something is broken — pin intentionally.
- PodSecurity: namespaces are mostly unrestricted/audit; `kube-system` is
  privileged (Cilium). Don't assume `restricted` PSS is enforced.

## Deploying a new app (checklist)

1. **Chart source**: is it a Helm chart? If yes and the repo isn't
   registered yet, add `kubernetes/flux/repositories/helm/<name>.yaml`
   (HelmRepository or OCIRepository) and append it to that folder's
   `kustomization.yaml`.
2. **Directory**: `kubernetes/apps/<namespace>/<app>/` with
   `kustomization.yaml`, `helmrelease.yaml`, `helm-values.yaml`
   (copy sonarr as a template for app-template apps). Raw manifests are fine
   too — follow jellyfin/obsidian-livesync style.
3. **Namespace**: add the app dir to `kubernetes/apps/<ns>/kustomization.yaml`.
   New namespace? Create `namespace.yaml` in the namespace dir, add the
   namespace dir to `kubernetes/apps/kustomization.yaml`.
4. **Secrets**: any credentials → `<app>/secret.sops.yaml` (encrypt before
   committing). Reference via `envFrom.secretRef` / `secretKeyRef` /
   `valuesFrom.secretRef` as appropriate.
5. **Storage**: config → Longhorn PVC (5Gi default); shared data → NFS
   persistence entry with correct `subPath`, matching PUID/PGID/fsGroup.
6. **Ingress**: cilium class, `<app>.lab254.lab.lan` host, TLS via
   `internal-ca` for LAN.
7. **Commit + push**, then reconcile:
   ```sh
   flux reconcile source git lab-254
   flux reconcile kustomization apps --with-source
   flux reconcile helmrelease <app> -n <ns>
   ```
8. Verify: `kubectl -n <ns> get helmrelease,pods,ingress -o wide` and app logs.

## Debugging playbook

Start high, then drill down:

```sh
# 1. Is GitOps healthy? (anything NotReady/failed here explains most outages)
flux get kustomizations -A
flux get helmreleases -A
flux logs --all-namespaces --since=30m | grep -iE "error|fail" | tail -50

# 2. What is the cluster doing?
kubectl get pods -A -o wide | grep -v Running | grep -v Completed
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# 3. App-level
kubectl -n <ns> get helmrelease <app> -o yaml   # conditions tell you why upgrade failed
kubectl -n <ns> describe helmrelease <app>
kubectl -n <ns> logs deploy/<app> -c main --tail=100 --previous   # --previous for crashloops
kubectl -n <ns> exec -it deploy/<app> -c main -- sh              # interactive debug
```

Notes learned the hard way:

- **HelmRelease failed upgrade**: read its `status.conditions` — most often a
  values error or a dependent resource (PVC/HelmRepository/secret) missing.
  Fix the YAML, push, reconcile; `install.remediation.retries: 3` and
  `upgrade.cleanupOnFail: true` are already set on most releases.
- **Flux not picking up commits**: check `flux get sources git` (deploy key
  auth) and whether the file is under `kubernetes/` (the GitRepository ignores
  everything else). Force with `flux reconcile source git lab-254`.
- **Config changes "stuck"**: values come from a ConfigMap
  (`<app>-helm-values`) — after it updates, the HelmRelease must upgrade;
  nudge it with `flux reconcile helmrelease <app> -n <ns>`.
- **Pods stuck Pending**: `kubectl describe pod` — usually Longhorn volume
  issues (`kubectl -n longhorn-system get pods`) or resource requests.
- **PVCs**: `kubectl get pvc -A`; Longhorn UI/reps live in
  `longhorn-system`; don't delete PVCs casually (reclaim policy Delete).
- **NFS problems**: mount issues surface as pod mount errors; the NFS server
  is outside the cluster (172.16.2.23) and not managed by this repo. Nodes
  need the nfs-utils extension (already in talconfig schematic).
- **Permission errors on shared storage**: check PUID/PGID/fsGroup consistency
  and remember root squash (root can't chmod others' files on NFS).
- **Node issues**: you cannot SSH. Use `talosctl -n <ip> ...` with
  `talos/clusterconfig/talosconfig` (e.g. `talosctl logs`, `dmesg`,
  `services`). Reboots/repairs via talosctl only.
- **cert-manager TLS not issuing**: `kubectl get certificates -A`,
  `kubectl describe order/challenge`, check the right ClusterIssuer is used
  (LAN → internal-ca).
- Restart semantics: killing a pod is safe (Deployment/StatefulSet); Helm
  values/secrets changes need a reconcile, not a manual rollout.

## Taskfile quick reference

```sh
task -l                         # list all tasks
task talos:generate-config      # regen machine configs from talconfig.yaml
task talos:apply-config IP=x.x.x.x   # (re)apply machine config (insecure/maintenance)
task talos:bootstrap            # first-time etcd bootstrap
task talos:fetch-kubeconfig
task talos:deploy-cilium        # bootstrap CNI (then HelmRelease takes over)
task talos:reset-cluster        # DESTROYS cluster state — never run casually
task sops:setup                 # create age key
task sops:encrypt -- file.yaml  # encrypt in place
task sops:decrypt -- file.yaml  # decrypt in place (do not commit)
task sops:encrypt-all           # encrypt any unencrypted *.sops.* files
task flux:setup                 # bootstrap Flux (cluster already running — don't rerun)
```

Talos config regeneration after editing `talconfig.yaml`/patches:
`task talos:generate-config`, then `talosctl apply-config` per node if needed.
Generated files in `talos/clusterconfig/` are partially gitignored — check
before assuming they're tracked.

## Safety rules for agents

- **Do not run** `task talos:reset-cluster`, `flux uninstall`, `flux:setup`, or
  `talos:bootstrap` on a healthy cluster.
- **Do not** `kubectl delete` HelmRelease/HelmRepository/PVC/Namespace to
  "fix" things without explicit user approval; prefer git edits + reconcile.
- **Do not** decrypt secrets into the repo tree; keep plaintext out of git and
  out of logs. Redact API keys in any output.
- **Do not** edit cluster-internal Flux objects (the sops-age secret,
  cluster-secrets ConfigMap in flux-system) except through the documented
  task flows.
- Prefer **adding** config in git over mutating live objects; direct kubectl
  edits are for diagnosis (or one-off, documented interventions).
- After changes: verify with `flux get`/`kubectl get`, and confirm the app
  actually comes back Ready — a synced Kustomization doesn't guarantee a
  healthy HelmRelease.
