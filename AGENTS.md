# Argus Project Guide for AI Agents

## ⚠️ CRITICAL INSTRUCTIONS FOR AI AGENTS

1. **Commit policy — do NOT commit unless explicitly asked.** Preview changes,
   show `git diff`, list files, and draft a commit message for approval first.
2. **Documentation policy — ALWAYS update this file when you change the
   project.** Add/update the relevant Section 1 entry, versions, directory
   structure, and the "Last Updated" line, in the same request you ask to commit.

## Project Overview

**Argus** is RPCU's GitOps repo for Kubernetes cluster config, built with Flux
CD. Almost the entire stack is declarative and reconciled by Flux to match
`main`: the clusters (mgmt + openstack), Cilium CNI, Rook/Ceph storage, the full
OpenStack control plane (Yaook operators + service CRs), Neutron/OVN networking,
cert-manager/trust-manager, Gateway API/kgateway, ExternalDNS/Designate, Cluster
API/CAPO lifecycle, and OpenStack tenant resources via Crossplane. No click-ops.

**Adding a compute node is trivial:** don't edit this repo — join the node to the
openstack cluster and apply the right node labels. Yaook operators watch labels
and schedule the OpenStack agents (nova-compute from `nova.yaml`, ovn-controller
from `neutron.yaml`), register the hypervisor, and wire OVN. Node selection:
`compute.configTemplates[].nodeSelectors[].matchLabels` (`infrastructure/yaook/nova.yaml:24`) and
`setup.ovn.controller.configTemplates[].nodeSelectors[].matchLabels` (`infrastructure/yaook/neutron.yaml:94`).
Current `matchLabels: {}` = match-all.

---

## 1. Directory Structure

### Root

- `clusters/` cluster configs · `infrastructure/` reusable components ·
  `nix/` custom Nix packages · `npins/` pinned deps (`npins update`) ·
  `devenv.nix`/`devenv.yaml`/`devenv.lock` · `.envrc` · `renovate.json5`
  (see Section 5).
- `nix/sveltosctl.nix` — Sveltos CLI (v1.9.0).

### clusters/openstack/ (baremetal primary cluster)

Master `kustomization.yaml` plus per-concern Flux Kustomizations:
`cilium`, `cert-manager`, `cert-manager-issuer`, `trust-manager` (setup→configs),
`gateway-api`, `kgateway-crds`→`kgateway`, `external-secrets`, `flux-operator`,
`fluxcd/`, `yaook-operator`, `openstack-exporter` (dependsOn external-secrets +
monitoring, `wait: false`).

- `rook.yaml` — three Kustomizations: `rook-setup` → `rook-ceph-csi`
  (`./infrastructure/rook/csi-drivers`) → `rook-configs`.
- `crossplane.yaml` — `crossplane` (Helm) → `crossplane-openstack` →
  `crossplane-zitadel` → `crossplane-compositions` → `crossplane-resources`
  (overlay `./clusters/openstack/crossplane`, `prune: false`).
- `crossplane/` — **openstack overlay** (concrete instances). `openstack/`:
  OpenStack managed/composite resources (networks, routers, flavors, groups,
  projects, security groups, DNS zone) + `ClusterProviderConfig` (ns yaook).
  `zitadel/`: the SINGLE-owner shared Zitadel platform (org `rpcu`, projects,
  roles, actions) + `ProviderConfig` + the `openstack`/`netbird`/`kubernetes`
  OIDC apps (ns zitadel). The `kubernetes` app is a public/native PKCE client
  with **no client secret**, used by CAPI clusters' apiserver OIDC.
  **The mgmt cluster must NOT manage the Zitadel platform — both clusters share
  one Zitadel instance.**

### clusters/mgmt/ (CAPI management cluster)

Bootstrapped with kind + `clusterctl`; intended to self-manage after
`clusterctl move`. Master `kustomization.yaml` plus:

- `cilium.yaml` — shared base + mgmt patches (k8sServiceHost 172.16.255.212:6443,
  base `socketLB.hostNamespaceOnly: false`). **Cilium LB disabled on mgmt**:
  `l2announcements.enabled: false` + `$patch: delete` of `CiliumLoadBalancerIPPool`
  and `CiliumL2AnnouncementPolicy`. LoadBalancer is served by the OpenStack CCM
  via Octavia.
- `cert-manager.yaml`, `gateway-api.yaml`, `kgateway-crds.yaml`.
- `kgateway.yaml` — patched for mgmt: JSON-6902 removes the Cilium
  `lbipam.cilium.io/ips` annotation; listener hostnames → `*.mgmt.rpcu.lan`;
  cluster-issuer → `root-mgmt`; certificateRefs → `rpcu-lan-wildcard-tls`.
- `cert-manager-issuer.yaml` — mgmt-local chain (independent of openstack's
  `root-rpcu`): `selfsigned` → `root-mgmt` CA (ns cert-manager, isCA, RSA-4096,
  87600h) → `root-mgmt` ClusterIssuer; leaf `rpcu-lan-wildcard-tls`
  (ns kgateway-system, `*.mgmt.rpcu.lan`). `root-mgmt` can sign any `.rpcu.lan`.
- `external-secrets.yaml`, `cluster-api-operator.yaml`, `cluster-api-providers.yaml`.
- `capi-janitor.yaml` — `./infrastructure/capi-janitor` (`dependsOn:
cluster-api-providers`). The capi-janitor-openstack operator; purges dangling
  OpenStack resources (FIPs, Octavia LBs, SGs, Cinder volumes+snapshots, appcred)
  left by OCCM/Cinder-CSI when an `OpenStackCluster` is deleted (finalizer
  `janitor.capi.stackhpc.com`), BEFORE CAPO tears down the network (avoids the
  OCCM-LB-holds-network deadlock).
- `openstack-ccm-identity.yaml` / `openstack-ccm.yaml` — ESO cloud-config +
  OCCM HelmRelease (LoadBalancer via Octavia + Node init).
- `external-snapshotter-crds.yaml` / `external-snapshotter.yaml` (v8.6.0).
- `openstack-cinder-csi.yaml` — Cinder CSI (StorageClass for Cinder PVCs).
- `ceph-csi-cephfs.yaml` + `ceph-csi-cephfs/` overlay — RWX `ceph-cephfs`
  StorageClass backed by openstack `rpcu-fs`; `wait: false` (needs mgmt Vault
  path `secrets-mgmt/ceph-csi`). NOTE: RWX is now served via `csi-driver-nfs`
  (see below); this external ceph-csi path is retained per overlay.
- `external-dns.yaml` — InternalDNS/Designate; `wait: false`.
- `crossplane.yaml`, `crossplane-providers.yaml` (provider-random, unused —
  removal candidate), `crossplane-zitadel.yaml` (provider only).
- `crossplane-resources.yaml` — **mgmt overlay** `./clusters/mgmt/crossplane/zitadel`
  (`prune: false`): mgmt's own Zitadel `ProviderConfig` + the **chihiro** `Oidc`
  app. References the shared org/project by **literal external ID** (org rpcu
  `369994019545117645`, project administration `370001231734928333`) since those
  MRs are owned by openstack. Writes `chihiro-oidc-conn`
  (`attribute.client_id`/`client_secret`) into chihiro-system.
- `chihiro.yaml` — chihiro app (`./clusters/mgmt/apps/chihiro`). `oidc.yaml` ESO
  remaps `chihiro-oidc-conn` → `chihiro-oidc` (`clientId`/`clientSecret`).
  `cm.yaml` `cluster.template` writes the `sveltos.argus.rpcu.io/capo-version`
  **annotation** from a `capoVersion` `select` form field (default sentinel
  `"default"`; options `default`/`v0.14.4`) and add-on opt-in labels via toggles.
  A `select` (not free-text) is required — chihiro hard-errors on an empty
  `{{ chihiro.* }}` create-form placeholder.
- `dragonfly-operator.yaml` — Dragonfly (Redis-compatible) for chihiro sessions.
- `vault.yaml` — `./infrastructure/vault`, dependsOn kgateway +
  openstack-cinder-csi. HA Vault (3-node Raft, no Consul); chart Ingress off,
  HTTPRoute at `vault.mgmt.rpcu.lan`; PVCs request `cinder-delete`. 3 replicas
  need 3 nodes (required podAntiAffinity).
- `kubernetes-rbac.yaml` — bare Group RBAC (`kube-admin`→`cluster-admin`,
  `kube-user`→`view`), matching the Zitadel `groupsClaim` bare names + empty
  ClusterClass `groupsPrefix`. Harmless before OIDC.
- `sveltos.yaml` — `./infrastructure/sveltos`, `prune: true`.
- `monitoring.yaml` — kube-prometheus-stack (patched: Mimir remote_write
  `http://mimir-gateway.monitoring.svc:80/api/v1/push`, `externalLabels.cluster: mgmt`).
- `mimir.yaml` (dependsOn monitoring), `grafana-operator.yaml`, `grafana.yaml`
  (dependsOn monitoring+mimir+grafana-operator, `grafana.mgmt.rpcu.lan`).
- `grafana-alerting.yaml` — split from grafana for blast-radius isolation
  (`wait: false`; its Discord ExternalSecret needs Vault `secrets-mgmt/grafana`).

> **mgmt Crossplane/chihiro OIDC.** The `crossplane-provider-zitadel` admin secret
> (ns zitadel) is created **manually** on mgmt. mgmt must NOT manage the shared
> Zitadel platform — that's owned by the openstack overlay.

### Workload clusters (no `clusters/` dir — fully Sveltos-driven)

The `flux` ClusterProfile bootstraps Flux Operator + a FluxInstance syncing
directly to `./infrastructure/fluxcd/operator` (self-reconciling). Everything
else is pushed per-cluster by labelled Sveltos ClusterProfiles (see
`infrastructure/sveltos`). No shared Git sync path forces an addon onto every
cluster — opt-in addons live in their own labelled ClusterProfiles.

### infrastructure/ — Reusable Components

Each component below is a directory with the usual `helmrepo.yaml` /
`helmrelease.yaml` / `namespace.yaml` / `values.yaml` / `kustomization.yaml`
unless noted. Only non-obvious specifics are listed.

- **cert-manager/** (v1.19.2) — `values.yaml`: `prometheus.enabled: true` +
  `prometheus.servicemonitor.enabled: FALSE` (default OFF) + `labels: {release:
kube-prometheus-stack}`. The SM is **monitoring-gated**: this shared base is
  pushed to mgmt, openstack AND opt-in workload clusters (many WITHOUT
  kube-prometheus-stack), so enabling the SM in the base would hard-fail the
  HelmRelease on `no matches for kind "ServiceMonitor"`. It is re-enabled via an
  inline HelmRelease `values` patch (Helm merges over the ConfigMap, keeping the
  `release:` label) ONLY where the CRD exists: `clusters/mgmt/cert-manager.yaml` +
  `clusters/openstack/cert-manager.yaml` patches, and — for workload clusters —
  the `cert-manager` Sveltos profile's `cert-manager-install` ConfigMap (now
  `projectsveltos.io/template`) which appends the patch only when the Cluster
  carries `sveltos.argus.rpcu.io/monitoring: enabled` (see §8 "monitoring-gated
  ServiceMonitors"). Enabled alone still does NOT make a ServiceMonitor.
- **trust-manager/** (v0.18.0) — `setup/` (chart) + `configs/bundle.yaml` (RPCU root CA).
- **cilium/** (v1.18.6) — `ciliumloadbalancerippool.yaml` (10.0.0.240-253),
  `ciliuml2announcementpolicy.yaml`, `values.yaml`.
- **gateway-api/** (v1.4.1) — remote experimental CRDs.
- **kgateway/** (v2.2.2) — `crds/` (ns kgateway-system, OCI repo), `helmrelease.yaml`,
  `gateway.yaml` (openstack), `httplistenerpolicy.yaml` (WS upgrades + access logs).
  `helmrelease.yaml` sets top-level `resources` (192Mi/384Mi/20m).
- **monitoring/** (kube-prometheus-stack v87.17.0) — Grafana disabled, 6h local
  retention, 5Gi PVC. Per-cluster `remoteWrite`/`externalLabels` via Flux patches.
  **Cardinality control lives here**, split per kubelet endpoint
  (`metricRelabelings`/`cAdvisorMetricRelabelings`/`probesMetricRelabelings` —
  a rule in the wrong list silently never fires, §8). Drops high-cardinality
  apiserver/etcd histograms and disables dependent rule groups
  (`kubeApiserver{Burnrate,Histogram,Slos}`, `k8sContainerMemory{Cache,Swap}`).
  KSM `customResourceState` for Flux CRDs (`gotk_resource_info`); Flux CRD RBAC
  lives under `kube-state-metrics.rbac.extraRules` (top-level), NOT the nested
  `customResourceState.rbac`. KSM resources under the hyphenated
  `kube-state-metrics:` key (192Mi/384Mi/25m), not `kubeStateMetrics.resources`.
- **openstack-exporter/** (image v1.6.0, openstack only) — **plain manifests**
  (upstream chart isn't published). Emits the ONLY `openstack_*` family. ESO
  `SecretStore` reads `keystone-admin` (ns yaook) → `clouds.yaml`
  (`auth_url: https://keystone.yaook.svc:5000/v3` internal, `verify: false`,
  `region_name: hetzner`, `identity_interface: internal`). Deployment
  (`--endpoint-type internal`, distroless — scrape via pod IP) + Service 9180 +
  ServiceMonitor 60s (label `release: kube-prometheus-stack`, scraped by both
  selectors). Does NOT expose hypervisor-capacity nova metrics (absent on this
  cloud); VM counts via `openstack_nova_total_vms` (=11) /
  `openstack_nova_limits_instances_used`; per-VM state via
  `openstack_nova_server_status` (4=ERROR, 0=ACTIVE, 11=SHUTOFF).
- **mimir/** (chart v5.6.0) — `mimir-distributed` monolithic, filesystem, 5Gi PVC,
  72h retention. `httproute.yaml` `mimir.mgmt.rpcu.lan`. Ruler disabled.
- **grafana-operator/** (v5.16.0) — watches all namespaces (DaaS).
- **grafana/** (Operator CRDs v1beta1) — `grafana.yaml` (5Gi PVC, label
  `dashboards: grafana-central`, Zitadel OIDC `grafana-oidc-conn`),
  `mimir-datasource.yaml`, `httproute.yaml` `grafana.mgmt.rpcu.lan`, and
  `dashboards/`: cluster-overview, pvc-storage, node-filesystem,
  ceph-storage (rewritten vs real `ceph_*` names, 20 panels),
  openstack-control-plane (**openstack-only**, pinned `cluster="openstack"`, no
  `$cluster`; only `$node`; every metric verified against the live exporter —
  NO `openstack_*` or latency-histogram panels), palworld (hand-built vs
  Banh-Canh/palworld-exporter-go from the atlas repo, 37 panels, `$cluster`),
  fluxcd (`gotk_resource_info` + `gotk_reconcile_duration_seconds_*`, 17 panels),
  cert-manager (`certmanager_certificate_expiration_timestamp_seconds` +
  `_ready_status`, `$cluster`+`$namespace`).
- **grafana/alerting/** — **own Flux Kustomization** (ns monitoring). Grafana-
  managed alert rules (Mimir ruler + Alertmanager receivers are both off, so
  Grafana unified alerting is the ONLY delivery path). ONE rule set covers every
  cluster remote_writing to Mimir (`cluster` external label auto-appears).
  - `discord-secret.yaml` ESO (`secrets-mgmt/grafana` → `discord-webhook-url`
    via `vault-backend` ClusterSecretStore; ESO adds the KV-v2 `/data/` itself).
  - `folder.yaml` `GrafanaFolder Alerts` (needed — AlertRuleGroup requires a real
    folderRef, unlike dashboards).
  - `contactpoint-discord.yaml` (`receivers[]` form, needs operator ≥5.21.0;
    mgmt runs 5.24.0; URL injected via `valuesFrom`→`targetPath: url`).
  - `notification-policy.yaml` (single global tree; root `discord`; grouped by
    folder/alertname/cluster; critical re-notify hourly).
  - `rules-node.yaml` (interval 1m): `NodeCPUHigh` (>85%, **1h**), `NodeMemoryHigh`
    (>90% MemAvailable, **1h**), `NodeDiskSpaceLow` (>85%, 15m), `NodeNotReady`
    (critical, 10m).
  - `rules-storage.yaml` (5m): `PersistentVolumeSpaceLow` (>85%, 15m).
  - `rules-pods.yaml` (1m): `PodCrashLoopBackOff`, `PodRestartingFrequently`
    (>3/15m), `PodContainerNotReady` (15m, excl. Jobs + Waiting).
  - `rules-openstack.yaml` (5m, all `cluster="openstack"`): `NovaVMInError`
    (server_status==4), `OpenStackServiceDown` (<8 of 8 up), `NovaComputeAgentDown`,
    `OctaviaLoadBalancerNotOnline`.
  - `rules-flux.yaml` (1m): `FluxReconciliationErrors`, `FluxReconciliationTimeouts`,
    `FluxControllerHighErrorRate`, `FluxResourceStale`, `FluxResourceNotReady`
    (`gotk_resource_info{ready="False"}`). **MUST NOT use `$cluster`** (§8).
  - `rules-certmanager.yaml` (5m): expiry Critical (<10% lifetime) / Warning
    (<20% lifetime, percentage-of-lifetime via `label_join`, not fixed days) +
    NotReady (15m). Needs cert-manager metrics + ServiceMonitor sub-toggle.

  Non-obvious rule facts (verified live, do NOT "simplify"):
  - Rule shape is 3 stages: `A` instant PromQL → `B` reduce(last) → `C` threshold
    (`condition: C`).
  - `NodeDiskSpaceLow` MUST keep `and on (cluster,instance,mountpoint)
(node_filesystem_readonly == 0)` — NixOS `/nix/store` is RO + ~100% full.
  - `NodeNotReady` must NOT use `== 0` (that → NoData when healthy); query raw
    `kube_node_status_condition{...,status="true"}` and threshold `lt 1`.
  - `noDataState: OK` is deliberate (a broken Mimir must not fire everything).
  - Panel linking uses `annotations.__dashboardUid__` + `__panelId__` (both
    required; `__panelId__` a quoted string); the CRD `rules[].dashboardUid/panelId`
    fields are deprecated/ignored.

  Manual prereq (`infrastructure/vault/README.md`): a `grafana` Vault policy must
  be attached **alongside** `crossplane` on the `external-secrets` role and the
  webhook seeded at `secrets-mgmt/grafana`, or notifications don't deliver.

- **rook/** (Ceph v19.2.3):
  - `setup/helmrelease.yaml` — rook-ceph chart v1.20.1 (`crds.enabled: true`
    only; since v1.20 the operator no longer deploys CSI drivers — see csi-drivers).
  - `csi-drivers/helmrelease.yaml` — `ceph-csi-drivers` v1.0.3 (targetNamespace
    rook-ceph): `imageSet.name: rook-csi-operator-image-set-configmap`, Driver CRs
    `rook-ceph.{rbd,cephfs}.csi.ceph.com` (KEEP the `rook-ceph.` prefix to match
    existing provisioners); nfs/nvmeof disabled. Do NOT also set CSI values in the
    operator chart.
  - `configs/cephcluster.yaml` — 3 mons (lucy, makise, quinn).
    `monitoring.enabled: true` (creates the `rook-ceph-mgr` ServiceMonitor →
    `ceph_*`; without it Mimir has zero ceph metrics). priorityClassNames
    (mon/osd `system-node-critical`, mgr `system-cluster-critical`); resources
    for mon/mgr/osd — **osd cpu request 500m** (NOT 2; measured peak ~350m;
    over-reservation wedged OVN on quinn — §8), 5Gi req/8Gi limit, no CPU limit.
  - `configs/cephblockpool.yaml` — RBD replica-2 nvme, `pg_autoscale_mode: on`
    - `target_size_ratio: 0.8`. ALL pools must use nvme-classed CRUSH rules (§8).
  - `configs/cephfilesystem.yaml` — `rpcu-fs` (replica-2 metadata + `data0` on
    nvme, MDS activeCount 1 + standby-replay, `preserveFilesystemOnDelete: true`).
    Provides RWX-capable POSIX FS. MDS `system-cluster-critical`, 2Gi/4Gi,
    **required podAntiAffinity** on hostname. `data0` also `pg_autoscale_mode: on`
    - `target_size_ratio: 0.8` (§8 OSD-full incident).
  - `configs/cephobjectstore.yaml` — S3, both pools `deviceClass: nvme`.
  - `configs/storageclassrdb.yaml` (`general`, default, RWO),
    `storageclasscephfs.yaml` (`cephfs`, RWX, not default, in-cluster only).
  - `configs/cephnfs.yaml` — `CephNFS rpcu-nfs` (1 Ganesha) + LoadBalancer pinned
    `10.0.0.245` (via `lbipam.cilium.io/ips` annotation, NOT `spec.loadBalancerIP`)
    on TCP/2049. Exists because Rook is pod-networked (mons/MDS/OSDs advertise
    pod/ClusterIPs unreachable externally). `server`: `system-cluster-critical`,
    500m/1Gi/2Gi (no CPU limit), relaxed livenessProbe (failureThreshold 24,
    periodSeconds 15 ≈ 6min). **`security_label: false` remount trap**: after any
    change, restart ganesha AND force-remount every consuming cluster (statx()
    EREMOTEIO otherwise on Linux 6.x+).
  - `configs/nfs-export-ensure.yaml` — hourly CronJob enforcing the `rpcu-nfs`
    export (mgr `nfs` state, not CR-declarable) + `security_label: false`.
  - `configs/openstack-clients.yaml` — CephClients `glance` + `cinder`.
  - `configs/rook-ceph-config.yaml` — `mon_max_pg_per_osd = 400`.
  - `configs/toolbox-deployment.yaml`, `configs/gateway/httproute-ceph.yaml`.
- **csi-driver-nfs/** (chart v4.13.4) — RWX over NFS for clusters with no local
  Ceph (mgmt + workload VMs). REPLACES external ceph-csi-cephfs (which couldn't
  work: pod-networked Rook). `storageclass.yaml` RWX `ceph-cephfs`
  (`provisioner: nfs.csi.k8s.io`, `server: 10.0.0.245`, `share: /rpcu-fs`,
  `nfsvers=4.1` — keep `server` in sync with the CephNFS LB IP). No secrets;
  only TCP/2049. Consumers: `clusters/mgmt/csi-driver-nfs.yaml` + Sveltos
  `csi-driver-nfs` ClusterProfile. **`security_label: false`** on the export is
  mandatory (statx() EREMOTEIO on Linux 6.x+ breaks Radarr/Jellyfin, etc.).
- **crossplane/** (v2.2.0) — beta features (usages, realtime-compositions).
  Shared bases hold cluster-agnostic pieces only; concrete instances live in
  per-cluster overlays (there is ONE shared Zitadel instance).
- **crossplane-providers/** — provider-random (unused; removal candidate).
- **crossplane-openstack/** — provider-openstack (cluster-scoped).
- **crossplane-zitadel/** — provider-zitadel (provider only; ProviderConfig +
  platform + OIDC apps are per-cluster overlays).
- **crossplane-compositions/** — XRD `externalnetworks.networking.rpcu.io` +
  Composition `external-network` (Network+Subnet+RouterV2) + patch-and-transform
  Function. Kept as its own Kustomization to avoid pruning the in-use XRD.
- **external-secrets/** (v2.3.0).
- **golinky/** (v0.3.1) — link shortener; `LoadBalancer` pinned `10.0.0.241`.
- **openstack-ccm/** (chart v2.35.0 / app v1.35.0) — LoadBalancer via Octavia +
  Node init (removes the CAPO cloud-provider taint). Replaces Cilium LB on mgmt.
  `values.yaml`: image v1.35.0; `enabledControllers` = cloud-node,
  cloud-node-lifecycle, service (route NOT enabled — Cilium owns pod net);
  `secret.create: false`.
- **openstack-ccm-identity/** — ESO renders `kube-system/cloud-config` from
  `capo-variables` (capo-system). `cloud.conf` `[LoadBalancer]`: `lb-provider=ovn`,
  `lb-method=SOURCE_IP_PORT`, `create-monitor=true` with explicit
  `monitor-delay=10s`/`monitor-timeout=10s`/`monitor-max-retries=3` (OVN defaults
  too aggressive → TLS handshake timeouts, §8). Split out so ESO failure can't
  abort the CCM apply.
- **openstack-cinder-csi/** (chart v2.35.0 / app v1.35.0) — StorageClasses
  `cinder-delete`/`cinder-rwx`. Shares the `cloud-config` secret;
  `secret.name: cloud-config`, `clusterID: "mgmt"`.
- **external-snapshotter/** (v8.6.0) — `crds/` + `controller/` remote bases
  (`?ref=v8.6.0`), ns kube-system. Split so CRDs reconcile first.
- **external-dns/** (chart v1.21.1 / app v0.21.0, mgmt only) — inovex Designate
  **webhook** sidecar (in-tree provider removed upstream). Auth via `clouds.yaml`
  (NOT OS\_\* env). `capo-variables` clouds.yaml → `internal-dns/openstack-credentials`.
  **`auth_url` must be the gateway endpoint `https://keystone.rpcu.vpn`.**
  `values.yaml` (mgmt defaults, via `valuesFrom` ConfigMap): `provider.name: webhook`
  (`external-dns-openstack-webhook:2.2.0`), `sources: [ingress, gateway-httproute]`,
  `policy: upsert-only`, `registry: noop`, `OS_CLOUD=openstack`.
  `secret-credentials.yaml` = ns + SA + capo-system Role/RoleBinding + ESO
  SecretStore/ExternalSecret (mgmt-only). Workload clusters reuse this base;
  the Sveltos profile `$patch: delete`s the 4 mgmt-only resources and appends a
  per-cluster override ConfigMap.
- **sveltos/** (core chart v1.10.0, dashboard v1.10.1, mgmt only) — core
  controllers + RBAC + `clusterprofiles/`. `helmrelease.yaml` per-controller
  `resources` (`addonController.controller` 448Mi/1Gi/80m, etc.; agents +
  driftDetectionManager not tunable in chart 1.12.7). Core values via
  `sveltos-core-values` ConfigMap. `clusterprofiles/kustomization.yaml` labels
  everything `argus.rpcu.io/sveltos-clusterprofile=true` so `capi-management` can
  reuse the base and strip profiles with one labelSelector `$patch: delete`.

  ClusterProfiles (all gated by labels; `type: workload` + a per-addon opt-in
  label unless noted):
  - `oidc-rbac.yaml` — binds `kube-admin`→`cluster-admin` on child clusters,
    plus one CRB per name in the Cluster's `chihiro.io/groups` annotation (read
    via `templateResourceRefs` `WorkloadCluster`). Label `.../oidc-rbac`.
  - `cilium.yaml` — CNI bootstrap via inline templated `helmCharts` (v1.18.6;
    values from the mgmt `Cluster` — apiserver host/port, pod CIDR, domain
    REQUIRED). Label `.../cilium`.
  - `cilium-values.yaml` — Flux takeover: pushes per-cluster values ConfigMap +
    the Flux `cilium` Kustomization CR (path `infrastructure/cilium`), which also
    DISABLES Cilium LB (l2announcements off + `$patch: delete` pool/policy) so it
    doesn't race the OpenStack CCM for LoadBalancer. Label `.../cilium`.
  - `flux.yaml` — TWO profiles: `flux` (`syncMode: OneTime`, `dependsOn: cilium`)
    deploys Flux Operator v0.40.0 via OCI helmChart; `flux-instance`
    (`ContinuousWithDriftDetection`, `dependsOn: flux`) pushes the FluxInstance
    (mirrors `infrastructure/fluxcd/instances/flux.yaml` incl. `--concurrent=2`
    - tmpfs patches; `cluster.domain` per-cluster; sync →
      `./infrastructure/fluxcd/operator`). Spine: cilium → flux → flux-instance →
      (all other addons).
  - `capi-management.yaml` (`dependsOn: flux-instance`, label `.../capi-management`)
    — full CAPI/CAPO stack + Sveltos as Flux Kustomization CRs (Sveltos core,
    ClusterProfiles, cert-manager v1.19.2, external-secrets v2.3.0,
    cluster-api-operator v0.27.0, ORC v2.5.0, CAPI providers, capi-janitor
    (`dependsOn: cluster-api-providers`, mirrors `clusters/mgmt/capi-janitor.yaml`
    — so a promoted mgmt cluster can tear down its own `OpenStackCluster`s without
    the OCCM-LB-holds-network deadlock), capo-identity, ClusterClass templates,
    kamaji `wait: false`). Transfers `capo-variables`
    from mgmt via `templateResourceRefs`. Per-cluster CAPO version override via
    the Cluster annotation `sveltos.argus.rpcu.io/capo-version` (templated patch;
    `"default"`/empty = repo-pinned). RBAC via `capi-management-capo-rbac` +
    `addon-controller-argus-template-reader`.
  - `vault-auth.yaml` (`dependsOn: flux-instance`, label `.../vault-auth`) —
    per-cluster Vault k8s auth backend (Crossplane provider-vault MRs on mgmt:
    Policy `secrets-<cluster>`, Backend `clusters/<cluster>`, AuthBackendConfig
    from CAPI `<cluster>-ca`, AuthBackendRole) + pushes ESO base + `vault-backend`
    ClusterSecretStore + `root-mgmt` CA bundle to the workload cluster. No static
    tokens. Wired by EventSource/EventTrigger on ESO up. Secret data seeded out
    of band.
  - `cert-manager.yaml` (`dependsOn: flux-instance`, label `.../cert-manager`) —
    per-cluster cert-manager + `vault-issuer` ClusterIssuer from shared mgmt Vault
    PKI intermediate `pki-int` (chained under `root-mgmt`). SUBDOMAIN ISOLATION
    enforced at the Vault PKI Role: `SecretBackendRole cm-<cluster>`
    `allowedDomains: ["<cluster>.rpcu.lan"]` (allowSubdomains/Bare/Wildcard true;
    Glob/AnyName/Localhost/IpSans false). Separate auth mount
    `pki-clusters/<cluster>`. Prereq: `pki-int` bootstrapped + signed by
    `root-mgmt`.
  - `external-dns.yaml` (`dependsOn: flux-instance`, label `.../external-dns`) —
    per-cluster InternalDNS (Flux takeover, no helmChart) with subdomain
    isolation: shared admin-project DNS app-cred (`dns_manager` role only) from
    mgmt `crossplane-system/cloud-controller-app-cred-dns` +
    per-cluster `domainFilters: [<cluster>.rpcu.lan]` + TXT registry
    (`txtOwnerId: <cluster>`, `txtPrefix: edns-`). Reuses the mgmt base with
    `$patch: delete` of the 4 mgmt-only resources.
  - `ceph-csi-cephfs.yaml` (`dependsOn: [flux-instance, vault-auth]`, label
    `.../ceph-csi-cephfs`) — RWX from openstack `rpcu-fs`. Pushes cluster-values
    ConfigMap (remote FSID + mons) + Flux Kustomization; key seeded in Vault
    per cluster out of band.
  - `dragonfly.yaml` (`dependsOn: flux-instance`, label `.../dragonfly`) —
    installs the DragonflyDB operator (Redis-compatible; `dragonflydb.io/v1alpha1
Dragonfly` CRD) via a Flux takeover of the SAME base mgmt uses,
    `./infrastructure/dragonfly`. ONE thing pushed (Flux Kustomization CR); no
    per-cluster values/secrets. The Dragonfly INSTANCE is app-owned by the
    consuming repo (e.g. atlas production's zot registry uses one as its Redis
    remoteCache), NOT this add-on. Default OFF.
  - `gateway-api-crds.yaml` (`dependsOn: flux-instance`, ALL workload clusters,
    no opt-in) — Gateway API CRDs (cert-manager gateway-shim needs them).
  - `gateway-api.yaml` (label `.../gateway-api`) — TWO profiles: `gateway-api`
    (`dependsOn: gateway-api-crds`) pushes kgateway CRDs + controller Flux
    Kustomizations; `gateway-api-resources` (`dependsOn: gateway-api`) pushes the
    Gateway (`*.cluster.rpcu.lan`, `vault-issuer`), GatewayParameters, wildcard
    Certificate, HTTPRoute, HTTPListenerPolicy. Split so CRs land AFTER CRDs.

- **cluster-api-operator/** (v0.27.0, ns capi-operator-system) — chart-managed
  cert-manager disabled; providers managed separately.
- **cluster-api-providers/** — provider CRs (`operator.cluster.x-k8s.io/v1alpha2`):
  CoreProvider cluster-api v1.13.2, BootstrapProvider kubeadm v1.13.2,
  ControlPlaneProvider kubeadm v1.13.2, InfrastructureProvider openstack/CAPO
  v0.14.4 (configSecret capo-variables), ControlPlaneProvider kamaji v0.20.0.
  `namespaces.yaml` (capi-system, capi-kubeadm-_-system, capo-system).
  `clusterctl._/v1alpha3`inventory CRs are EXCLUDED (CRD not installed by the
operator).`capo-variables` is created **manually** (README). ORC is a hard
  CAPO dependency but is a plain Flux Kustomization, NOT a provider CR.
- **orc/** (v2.5.0) — standalone, fetched by URL (CAPO image resolution).
- **cluster-api-templates/** — versioned base templates (`OpenStackClusterTemplate`
  / `KubeadmControlPlaneTemplate` / `KubeadmConfigTemplate` / `OpenStackMachineTemplate`),
  split per-component with `-vN` suffixes; per-cluster values are ClusterClass
  variables via patches. **The ClusterClasses themselves moved to
  `cluster-api-clusterclasses/`** (own Flux Kustomization, `dependsOn:
cluster-api-templates`, which now runs `wait: true` — templates are statusless
  CRs so kstatus reports them Ready as soon as they exist). WHY THE SPLIT: with
  the ClusterClass and its templates in ONE Kustomization there is no intra-set
  apply ordering, so a `-vN` templateRef rotation lets the ClusterClass reconcile
  against a not-yet-present template → topology/templateRef error that marks the
  WHOLE Kustomization NotReady, dragging the valid templates down and retrying
  forever. The split lands templates first, then the ClusterClasses adopt them.
  See `README.md` for the variable table + `-vN` rotation.
  - `clusterclass.yaml` `openstack-default` — variables: identityRef,
    externalNetworkId, managedSubnetCIDR/AllocationPools, imageName,
    controlPlaneFlavor, workerFlavor, sshKeyName, apiServerFloatingIP, **oidc**.
    `infrastructure.templateRef` → `openstack-default-cluster-v3`. `oidc` is an
    `enabledIf` patch appending `--oidc-*` apiserver flags (targets the shared
    Zitadel `kubernetes` PKCE client, no secret). clientID copied by hand;
    enabling rolls control-plane machines. Group claim = bare names
    (`kube-admin`/`kube-user`), so `usernamePrefix`/`groupsPrefix` empty; RBAC at
    `clusters/mgmt/apps/kubernetes-rbac/`.
  - `clusterclass-v1.yaml` `openstack-default-v1` — legacy class pinning the `-v2`
    infra templateRef for existing clusters (e.g. `mgmt`); `OpenStackCluster.spec`
    is immutable so live clusters can't rotate the infra templateRef.
  - `templates/controlplane*.yaml` — `-v1`; `-v2` adds kubelet
    reserved/eviction flags + kube-controller-manager monitor periods; `-v3` adds
    `encryptionAlgorithm: ECDSA-P256` (cheaper TLS handshakes, §8); `-v4` broken
    (`--watch-cache-sizes`); **`-v5` CURRENT** (=`-v3` minus the broken flag);
    `-v6` prepared/NOT referenced (apiserver memory-tuning flags).
  - `templates/bootstrap*.yaml` — worker `-v1`; `-v2` (kubelet reserved/eviction,
    used by openstack-default + openstack-kamaji).
  - `templates/infracluster.yaml` — `-v1`/`-v2`/`-v3` (ClusterClass → `-v3`).
    `managedSecurityGroups.allowAllInClusterTraffic: true` + only `0.0.0.0/0`
    rules (SSH, DNS egress, NodePort 30000-32767). **`-v3` REMOVES explicit
    `remoteManagedGroups` Cilium rules** — they collide with allow-all → hard
    `409 SecurityGroupRuleExists` (§8). `identityRef` hardcoded `mgmt-cloud-config`.
  - `templates/machines.yaml`, `namespace.yaml` (`mgmt`).
  - Kamaji variants exist (`clusterclass-kamaji*`, `infrakamaji.yaml` with
    `openstack-kamaji-cluster-v5` etc.).

  > **Per-pool worker flavors:** instantiate `default-worker` any number of times
  > under `machineDeployments[]`, override `workerFlavor` (default `xlarge`) /
  > `imageName` / `sshKeyName` per pool via `variables.overrides`.
  > `controlPlaneFlavor` and cluster-wide values can't be per-pool.

  > `cluster-api-templates` `dependsOn: cluster-api-providers` only and now runs
  > `wait: true` (templates are statusless CRs). The `mgmt-cloud-config` secret is
  > in `capo-identity`. The **ClusterClasses live in `cluster-api-clusterclasses/`**
  > (`dependsOn: cluster-api-templates`, `wait` OMITTED — with `wait: true` a `-vN`
  > rotation can wedge the topology controller). The `clusters` Flux Kustomization
  > (the `Cluster` CR) now `dependsOn: cluster-api-clusterclasses`. The `Cluster`
  > CR is at `clusters/mgmt/clusters/mgmt.yaml` (`classRef.name: openstack-default-v1`).
  > MIGRATION NOTE: an in-use ClusterClass is protected from deletion by the CAPI
  > `validation.clusterclass.cluster.x-k8s.io` webhook (verified live), so a stray
  > prune can't destroy `openstack-default`/`openstack-kamaji`.

- **capo-identity/** — ESO projects `capo-variables` (capo-system) →
  `mgmt/mgmt-cloud-config`. Split from templates for blast-radius isolation.
  `caProvider.namespace` must be empty on a namespaced SecretStore.
- **capi-janitor/** (mgmt only, ns capi-janitor-system) — the
  capi-janitor-openstack-go operator (Go rewrite of cluster-api-janitor-openstack,
  azimuth-cloud/capi-janitor-openstack-go), built reproducibly by `../capo-janitor`
  (Nix) and published to `zot.rpcu.io/public/capi-janitor-openstack-go:latest`
  (public repo → no imagePullSecret). **Plain manifests** (namespace / SA /
  ClusterRole / ClusterRoleBinding / single-replica Recreate Deployment), not the
  upstream Helm chart — same direct-manifest approach as openstack-exporter/ORC.
  Watches CAPO `OpenStackCluster` CRs; adds finalizer `janitor.capi.stackhpc.com`;
  on deletion authenticates with `spec.identityRef` and purges OCCM/Cinder-CSI
  leftovers (FIPs, Octavia LBs `kube_service_<cluster>_*`, SGs, Cinder
  volumes+snapshots, appcred) BEFORE CAPO tears down the network (avoids the
  OCCM-LB-holds-network deadlock), then removes its finalizer. The cluster name it
  matches tagged resources against comes from the **`cluster.x-k8s.io/cluster-name`
  label** on the OpenStackCluster (falling back to `metadata.name`) — CAPI's
  topology controller propagates that label onto the generated OpenStackCluster
  automatically (verified live: `mgmt`, `production`), so NO ClusterClass/CR change
  is needed; do NOT hardcode a literal cluster-name in the shared
  OpenStackClusterTemplate. Env: `CAPI_JANITOR_DEFAULT_VOLUMES_POLICY=delete`
  (per-cluster override via the `janitor.capi.stackhpc.com/volumes-policy`
  annotation), `CAPI_JANITOR_RETRY_DEFAULT_DELAY=60`. Health probes on `:8081`
  (`/healthz`/`/readyz`); RBAC mirrors the upstream kubebuilder markers
  (openstackclusters get/list/watch/patch/update; secrets get/delete; events
  create; namespaces + CRDs read).
- **yaook-operator/** (v2.4.0, ns yaook) — CRDs + per-service operators (infra,
  keystone, keystone-resources, glance, nova, nova-compute, neutron, neutron-ovn,
  horizon, octavia, designate, cds, barbican v2.2.0) + SecretStores/ExternalSecrets
  (crossplane creds, rook-ceph cinder/glance) + `gateway/` HTTPRoutes +
  BackendTLSPolicies (TLS re-encrypt to backends w/ RPCU bundle CA).
- **yaook/** — service Deployment CRs (`yaook.cloud/v1`), dependsOn yaook-operator
  - external-secrets. **Every `database` sub-section carries `resources` on
    mariadb-galera + proxy sidecars** (BestEffort-starvation fix, §8):
  * `keystone.yaml`, `glance.yaml` (`show_image_direct_url: true` for RBD COW
    clones — images must be raw), `cinder.yaml`, `octavia.yaml`.
  * `neutron.yaml` — `setup.ovn` sets `resources` on EVERY OVN component (NB/SB
    ovsdb + ssl-terminators, relay, northd, per-node controller.\*); no CPU limits;
    no mem limit on `ovs-vswitchd` (§8). CRD has no priorityClassName knob.
  * `nova.yaml` — libvirt tuning: `disk_cachemodes: [network=writeback]`
    (**MUST be a LIST** — a scalar → `ConfigurationInvalid` + rolling recreate on
    2.4.0), `hw_disk_discard: unmap`, `live_migration_permit_auto_converge: true`,
    `resume_guests_state_on_host_boot: true`. Four DBs (api/cell0/cell1/placement).
  * `designate.yaml` — `policy:` OR-s `role:dns_manager` into recordset CRUD +
    zone/recordset READ (write keeps the PRIMARY guard); zone create/update/delete
    NOT granted. `powerdns.database`/`.proxy` carry resources (§8). CRD exposes no
    resources for the PowerDNS server pod or the Galera ssl-terminator.
  * `barbican.yaml`, `ca-cert.yaml`.
  * `disruptionbudget.yaml` — `YaookDisruptionBudget nova-compute` (match-all,
    `maxUnavailable: 1`, `disruptiveMaintenance: true`, `preventDeletion: false`).
    Any `novaComputeConfig` edit triggers a rolling eviction (§8). One budget per
    node max.
  * `nova-compute-ssh-fix.yaml` — tactical CronJob (every 5min) appending
    `IdentityFile` to each nova-compute pod's ssh_config (image bug, §8). Selects
    `state.yaook.cloud/component=compute,parent-plural=novacomputenodes`; uses
    `docker.io/alpine/k8s` (NOT distroless kubectl images). Racy; force now:
    `kubectl create job -n yaook --from=cronjob/nova-compute-ssh-fix nova-ssh-fix-now`.
- **vault/** (chart v0.30.0, mgmt) — HA Raft (no Consul). `server.standalone: false`,
  `server.ha.raft.enabled: true` + `setNodeId: true`, `global.tlsDisable: true`
  (TLS at Gateway), **readinessProbe on / livenessProbe off** (sealed pods must
  not be killed), Ingress off, PVC 10Gi `cinder-delete`. `httproute.yaml`
  `vault.mgmt.rpcu.lan`. Every pod starts **sealed** (unseal manually). Also
  hosts PKI intermediate `pki-int` (chained under `root-mgmt`) — CSR signed once
  by hand (README).
- **fluxcd/operator/** — Flux operator v0.40.0 ONLY (no ServiceMonitor). This
  base is pushed to EVERY workload cluster by the mandatory `flux-instance`
  spine, so it must NOT carry a ServiceMonitor (CRD absent on monitoring-less
  clusters → `no matches for kind "ServiceMonitor"`).
- **fluxcd/monitoring/** — the split-out headless `flux-metrics` Service +
  `flux-controllers` ServiceMonitor (port 8080, label `release:
kube-prometheus-stack`, SM in ns `monitoring`). Deployed ONLY where the
  Prometheus Operator CRDs exist: `clusters/{mgmt,openstack}/flux-operator.yaml`
  each add a `flux-metrics` Kustomization (`dependsOn: monitoring`), and the
  `monitoring` Sveltos profile pushes this path to opt-in workload clusters (see
  §8 "monitoring-gated ServiceMonitors").
  **fluxcd/instances/flux.yaml** — FluxInstance (kustomize/helm `--concurrent=2`;
  all controllers tmpfs `emptyDir medium: Memory` with sizeLimits + raised mem
  limits: source-controller `data` 1Gi/`tmp` 256Mi @ 2Gi; kustomize/helm `temp`
  512Mi @ 1536Mi).

---

## 2. Technologies & Dependencies

- **GitOps**: Flux CD v2.x, Flux Operator v0.40.0, Kustomize, Helm.
- **Networking**: Cilium v1.18.6, Gateway API v1alpha3 (exp), kgateway v2.2.2,
  L2 announcements on eno1.4000.
- **Storage**: Rook/Ceph v19.2.3 (RBD + S3), external-snapshotter v8.6.0 (mgmt).
- **OpenStack**: Yaook operators v2.2.0 (charts.yaook.cloud); operators infra,
  keystone(+resources), glance, nova(+compute), neutron(+ovn), horizon, octavia,
  designate, cds, barbican. `dns_manager` = narrow custom Keystone role
  (recordset CRUD + zone/recordset read; no zone write) —
  `clusters/mgmt/crossplane/openstack/cloud-controller-dns.yaml`.
- **Certs**: cert-manager v1.19.2.
- **DNS**: ExternalDNS v0.21.0 (chart v1.21.1, Designate, mgmt).
- **Crossplane**: v2.2.0.
- **Cluster API**: capi-operator v0.27.0; CAPI core v1.13.2; kubeadm
  bootstrap/control-plane v1.13.2; CAPO v0.14.4; ORC v2.5.0; clusterctl v1.12.x.
- **Cloud provider**: OCCM chart v2.35.0 / app v1.35.0.
- **Dev tools**: Nix/NixOS flakes, Direnv, DevEnv, pre-commit (shellcheck,
  nixfmt-rfc-style, prettier). devenv commands: jq, yq, runme, code-server,
  go-task, fluxcd, kustomize, kubernetes-helm, kube-capacity, openstackclient,
  sveltosctl (v1.9.0).

### Helm Chart Versions

| Component            | Version | Repository                                     |
| -------------------- | ------- | ---------------------------------------------- |
| cert-manager         | v1.19.2 | jetstack/cert-manager                          |
| cilium               | v1.18.6 | cilium/cilium                                  |
| kgateway             | v2.2.2  | oci://cr.kgateway.dev/kgateway-dev/charts      |
| rook                 | v1.20.1 | rook-release/rook-ceph                         |
| ceph-csi-drivers     | 1.0.3   | ceph.github.io/ceph-csi-operator               |
| crossplane           | 2.2.0   | charts.crossplane.io/stable                    |
| external-secrets     | 2.3.0   | charts.external-secrets.io                     |
| yaook-crds/ops       | 2.2.0   | yaook.cloud                                    |
| capi-operator        | 0.27.0  | kubernetes-sigs.github.io/cluster-api-operator |
| openstack-ccm        | 2.35.0  | kubernetes.github.io/cloud-provider-openstack  |
| openstack-cinder-csi | 2.35.0  | kubernetes.github.io/cloud-provider-openstack  |
| ceph-csi-cephfs      | 3.15.0  | ceph.github.io/csi-charts                      |
| external-dns         | 1.21.1  | kubernetes-sigs.github.io/external-dns/        |
| openstack-exporter   | 1.6.0   | ghcr.io/openstack-exporter/openstack-exporter  |

Sync interval 5m (openstack-exporter 60s SM).

---

## 3. Key Configuration Details

- **Git**: `git@github.com:RPCU/argus.git`, branch `main`, sync 1m, GPG signing,
  SSH auth. Dev branches: dev, dev-vic, ciliumlb.
- **Flux sync** (`infrastructure/fluxcd/instances/flux.yaml`): Flux 2.x; source,
  kustomize, helm, notification controllers; path `./clusters/PLACEHOLDER`;
  `--concurrent=2`; tmpfs ephemeral storage; interval 1m.
- **openstack network**: API 10.0.0.5:6443; VLAN eno1.4000; Cilium `--devices`
  `eno1.4000,br-ex,br-int` (OVN bridges required — §8); L2 on eno1.4000; LB IPs
  10.0.0.240-253 (kgateway).
- **mgmt network**: node subnet `192.168.1.0/24`, allocation pool from `.11`.
- **Ceph**: rook-ceph, 3 mons (lucy, makise, quinn), NVMe, v19.2.3, dashboard on.
- **Formatting**: `.yamllint` (document-start + line-length disabled, indent 2),
  `.prettierrc.yaml` (`proseWrap: preserve`, tabWidth 2, spaces). treefmt/prettier
  does NOT fix inline-comment spacing or YAML doc-start markers.
- **Kubeconfigs**: `~/.kube/configs/rpcu/`.

---

## 4. Deployment & Sync Process

### openstack cluster order

flux-operator → fluxcd → core (cert-manager, cert-manager-issuer, trust-manager,
gateway-api, kgateway-crds→kgateway, cilium, crossplane chain, external-secrets,
rook setup→csi-drivers→configs [health-gated on CephCluster], yaook-operator).

### mgmt cluster order (self-management target)

1. flux-operator → 2. fluxcd → 3. cilium (LB disabled) → 4. cert-manager
   (+ gateway-api → kgateway-crds → kgateway [mgmt-patched] + cert-manager-issuer)
   → 5. external-secrets → 6. cluster-api-operator → 7. orc → 8. cluster-api-providers
   (CoreProvider first) → 9. cluster-api-templates → capi-janitor (`dependsOn:
cluster-api-providers`) → 10. capo-identity (`wait: false`)
   → 11. openstack-ccm-identity (`wait: false`) → 12. openstack-ccm →
2. external-snapshotter-crds → 14. external-snapshotter → 15. openstack-cinder-csi
   → 16. internal-dns (`wait: false`; `auth_url` = gateway endpoint) → 17. crossplane
   → 18. crossplane-zitadel → 19. crossplane-resources (`prune: false`) →
3. chihiro → 21. dragonfly-operator → 22. kubernetes-rbac → 23. sveltos
   (`prune: true`; pushes the opt-in ClusterProfiles listed in §1; `wait: false`) →
4. vault (dependsOn kgateway + openstack-cinder-csi; sealed until unsealed;
   hosts `pki-int` signed once by hand).

### Health checks

`rook.yaml` health-gates `CephCluster/rook-ceph` (rook-ceph ns), 5m timeout.

### Pre-commit test

`devenv.enterTest`: `hello | grep "Welcome"`.

---

## 5. Making Changes

### Common tasks

- **Bump a chart**: edit `infrastructure/<c>/helmrelease.yaml` `spec.chart.version`;
  `fluxcd reconcile helmrelease <name> -n <ns> --with-source`.
- **New cert issuer**: add to `clusters/openstack/cert-manager-issuer/` + its
  `kustomization.yaml`.
- **Cilium policy**: edit `clusters/openstack/cilium.yaml` patches; verify in toolbox.
- **Ceph**: edit `infrastructure/rook/configs/*`; health checks must pass.

### Dev workflow

feature branch → YAML edits → `pre-commit run --all-files` → `fluxcd` test →
commit (`feat: ...`) → push → PR.

### Dependency Updates (Renovate)

`renovate.json5` drives update PRs. **Self-hosted** in GitHub Actions
(`.github/workflows/renovate.yaml`), **no auto-merge**, batched Monday
(Europe/Paris). Runs hourly + `workflow_dispatch`; Renovate's `schedule` gates
PR creation. Auth: short-lived token from the org `rpcu-bot` App (app_id
`3164565`) via `actions/create-github-app-token@v1`, using org secrets `APP_ID`

- `PRIVATE_KEY`. The App needs **Workflows: read/write** (pinGitHubActionDigests
  edits `.github/workflows/*`). Exclude argus from the Mend-hosted `renovate` App
  (app_id `2740`) to avoid double-runs.

Tracks: Flux HelmReleases/HelmRepositories (HTTP+OCI); helm-values images;
custom regex managers — (1) kustomize bases via release-download/raw URLs →
github-releases (orc, gateway-api, dragonfly); (2) `?ref=vX` bases →
github-releases (external-snapshotter); (3) Crossplane packages → docker;
(4) CAPI provider `version:` via inline `# renovate:` markers; (5) Sveltos inline
`helmCharts chartVersion:`; (6) helm-values `tag:` without sibling repository
(kamaji); (7) plain `image:` → docker (rook ceph pinned `v19.2.3`, grouped;
chihiro).

**NOT Renovate-managed:** npins (`.github/workflows/npins-update.yaml`, 6h) and
yaook OpenStack releases (`.github/workflows/yaook-releases.yaml`, weekly —
`targetRelease` in CRs; verify upgrade path before merge). Grouping: yaook ops,
openstack cloud-provider, CAPI providers, cilium, flux-operator; `major`
un-batched + labelled. kamaji chart pinned `0.0.0+latest` (image tracked only).
Adding a dep: standard HelmRelease/values images auto-picked; otherwise add a
`# renovate: datasource=... depName=...` marker. Validate:
`npx --package renovate -- renovate-config-validator renovate.json5`.

---

## 6. Git Hooks & Code Quality

Pre-commit: shellcheck, nixfmt-rfc-style, prettier, treefmt.
`pre-commit run --all-files` (or a specific hook). Auto-format on commit.

---

## 7. Documentation & Resources

Docs: <https://docs.rpcu.io/gitops/>. Upstream: fluxcd.io, docs.cilium.io,
gateway-api.sigs.k8s.io, kgateway.dev, rook.io, cert-manager.io, docs.crossplane.io.
Git aliases: `git br`, `git lg`, `git s`, `git sw`, etc.

---

## 8. Important Notes for AI Agents (traps & incidents)

**Commit policy: DO NOT commit unless explicitly asked** (preview, diff, list
files, draft message). **File safety:** don't touch `.git/config`, lock files,
or Kustomization deps without updating parents; never commit secrets.
**Cluster safety:** test on dev branches; health checks must pass; verify
`fluxcd reconcile kustomization -n flux-system`; never force-delete cert-manager,
cilium, or rook. **Format before committing**; `kustomize build clusters/openstack/`.

Helpful: `fluxcd get kustomizations -A`; `ceph status`/`osd tree`/`pool ls`
(toolbox); `cilium status`; `kubectl get helmrelease/kustomization/gateway/httproute/backendtlspolicy -A`.

### Networking / Cilium

- **`socketLB.hostNamespaceOnly`**: base default `false`; openstack overrides to
  `true` (`clusters/openstack/cilium.yaml`) because its nodes host nested KVM VMs.
- **`--devices` must include `br-int` + `br-ex`** (openstack). With
  `kubeProxyReplacement: true` the eBPF datapath only processes named devices;
  tenant VM traffic enters via the OVN bridges. Omitting them drops VM↔node /
  VM↔Service flows. `--direct-routing-device` stays `eno1.4000`. Update if bridge
  names change.
- **OCCM replaces Cilium L2 LB on mgmt** (`clusters/mgmt/cilium.yaml`:
  `l2announcements.enabled: false` + `$patch: delete` pool/policy). Base keeps
  them for openstack.
- **CAPO managed SGs must open the Cilium overlay** via
  `managedSecurityGroups.allowAllInClusterTraffic: true` (covers VXLAN 8472,
  health 4240, Hubble 4244, ICMP). Without it cross-node pod/DNS fails.
  **Do NOT also add explicit `remoteManagedGroups` rules** — they duplicate the
  allow-all tuples → `409 SecurityGroupRuleExists` aborts the whole SG reconcile
  (fixed in `-cluster-v3`/`-kamaji-v5`). Keep only `0.0.0.0/0` rules
  (SSH/DNS/NodePort/10250).
- **CAPO managed SGs must open NodePort 30000-32767** (`0.0.0.0/0`) for Octavia
  LoadBalancer (VIP DNATs to `<node>:<nodePort>`) — else the LB floating IP times
  out at TCP despite correct VIP/FIP/DNS. In `-cluster-v2` (immutable → new `-vN`).
- **Kamaji CP must open kubelet 10250** (`0.0.0.0/0`) — the apiserver runs as
  mgmt pods outside the workload SGs, so `logs`/`exec`/`top` proxy fails. In
  `-kamaji-cluster-v3`. Kubeadm class already covers this via node-to-node.
- **OCCM health monitor timeouts** → intermittent `TLS handshake timeout` on LB
  backends. Fix: explicit `monitor-delay=10s`/`monitor-timeout=10s`/
  `monitor-max-retries=3` in `openstack-ccm-identity/externalsecret.yaml` (OVN
  defaults ~5s are too aggressive; a healthy backend answers <1s).
- **Tenant MTU**: keep `ml2.path_mtu: 1342` (`neutron.yaml`). Neutron geneve MTU =
  `min(global_physnet_mtu, path_mtu) − 58`. Underlay carries 1400 (proven with
  `ping -M probe`). Do NOT raise (jumbo isn't clean end-to-end) or lower.
- **Cilium auto-MTU inherits `br-int` and poisons the underlay PMTU** (openstack,
  ROOT CAUSE of the long TLS-handshake black hole). Cilium auto-detects MTU as
  the MIN across `--devices`; `br-int` is tenant-sized (1284), so Cilium adopted
  1284 as its HOST MTU and, with `packetizationLayerPMTUDMode: always`, emitted
  ICMP frag-needed for ordinary underlay traffic → peers cache PMTU 1284 → geneve
  left 1226 while Neutron advertises 1284 = 58-byte black hole BOTH directions.
  Feedback loop, so tuning `path_mtu` can't fix it. **Fix: pin `MTU: 1400` in
  `clusters/openstack/cilium.yaml`.** Do NOT remove `br-int` from `--devices`.
  Signature: TCP connects but TLS never completes; LB VIP east-west OK, same
  service via floating IP fails. Rollout: existing VMs keep old MTU until ports
  recreated (roll via CAPI; stopgap `ip link set <if> mtu 1284`). External VPN
  clients: `ip route replace <fip> dev wt0 mtu 1200` until the pin rolls out.
- **Cilium 1.19 `packetizationLayerPMTUDMode: blackhole`** (new default, not in
  1.18.6) silently drops cross-node TCP > route MTU (no ICMP). Pod MSS 1302 >
  route MTU 1292. Fix: `pmtuDiscovery.enabled: true` +
  `packetizationLayerPMTUDMode: "always"` in `infrastructure/cilium/values.yaml`
  - `infrastructure/sveltos/clusterprofiles/cilium.yaml`. Check `helm show values`
    on Cilium bumps for new `pmtuDiscovery` defaults.

### Ceph

- **PG autoscaler breaks on overlapping CRUSH roots**: ALL pools must use
  nvme-classed rules, or `autoscale-status` is EMPTY and `pg_num` never grows
  (pools sat at `pg_num: 1`). Repo: `cephblockpool.yaml`/`cephfilesystem.yaml`
  `pg_autoscale_mode: on` + `target_size_ratio: 0.8`; `cephobjectstore.yaml`
  `deviceClass: nvme`. Any new pool (incl. Rook-implicit `.nfs`) must land on an
  nvme rule. Live one-time fixes: `replicated_nvme` rule + EC profile device-class.
- **OSD CPU over-reservation wedges OVN on quinn** (8 cores vs 12). OSD requested
  2 CPU (usage ~350m); freed by cutting to **500m** (`cephcluster.yaml`) — eviction
  protection comes from `system-node-critical`, not the request.
- **Single OSD full from too-few PGs on the dominant pool** (2026-07-10). "Full"
  is per-OSD: a 95% OSD blocks writes on ALL 14 pools at ~73% cluster usage. K8s
  thin-provisioning + replica-2 ×2 are invisible to it. `rpcu-fs-data0` (~70% of
  raw) was `pg_num: 32`; the upmap balancer balances PG COUNT, not bytes. Durable:
  split to 128 + `mgr/balancer/upmap_max_deviation 1` + `data0`
  `target_size_ratio: 0.8`. Ceph v19 mClock IGNORES `osd_max_backfills`; use
  `osd_mclock_profile high_recovery_ops` during drains (reset after). Set
  `target_size_ratio` on EVERY dominant pool.
- **Mon crash storm = containerd fd limit** (hephaestus). Reconnect storm hit the
  soft `nofile` 1024. Fix in hephaestus `nixosModules/kubernetes/default.nix`:
  `containerd LimitNOFILE = 1048576`. Check `/proc/1/limits` in a mon container.

### Nova / compute

- **ANY `novaComputeConfig` edit triggers a rolling eviction** (operator deletes
  each NovaComputeNode → cold-migrates VMs off — into the ssh bugs below). Now
  guarded by `disruptionbudget.yaml` (`preventDeletion: true`): the operator
  FLAGS `RequiresRecreation` instead of deleting; nodes sit flagged (intended
  steady state) until recreated by hand. Coverage must be total (match-all);
  one budget per node max (else `ConfigurationInvalid`). To apply a config, delete
  ONE NovaComputeNode at a time (lucy→makise→quinn), pre-empting the ssh bugs.
- **Cold-migration ssh, two bugs**: (1) `remote_filesystem_transport` must be
  `rsync` (fixed in `nova.yaml`; OpenSSH 9+ scp uses SFTP, not allow-listed) —
  reconciled only when the operator regenerates config (NOT mid-eviction).
  (2) `IdentityFile` missing from the image's ssh_config + nova home `/var/empty`
  → `Permission denied (publickey)`; **no CR fix** (durable fix is upstream);
  the `nova-compute-ssh-fix` CronJob live-patches it (lost on every pod restart).
  Unwedge: live-patch IdentityFile on all 3 pods, fix the source node's stale
  (immutable) config secret, `os-resetState` ERROR'd VMs to active (from a
  nova-api pod using `keystone-admin`), restart the eviction pod.

### yaook BestEffort starvation (recurring)

**When a yaook service misbehaves, check `.status.qosClass` FIRST.** These pods
ship `resources: {}` → BestEffort → cgroup `cpu.weight` 1 → starved on
hyperconverged nodes → probe timeouts → restart loops.

- **OVN control plane** (2026-07-26): starved ovsdb couldn't answer its own
  liveness appctl (20s) → kill loop → NB raft lost quorum → northd flapped 0/1
  → new VMs failed to boot. Tuning raft timers is NOT enough. Fix: `resources` on
  every `setup.ovn` component (`neutron.yaml`), no CPU limits, no mem limit on
  `ovs-vswitchd`. **northd is the symptom, not the cause — check NB raft first:**
  `ovs-appctl -t /run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound`. Rollout:
  the `controller.*` half restarts `ovs-vswitchd` (dataplane blip); do the
  NB/SB/relay/northd half first.
- **PowerDNS/Galera** (2026-07-26): starved Galera → PowerDNS SERVFAIL → `rpcu.lan`
  dead cluster-wide. Fix: `resources` on `powerdns.database`/`.proxy` (`designate.yaml`).
  Editing restarts the single-replica Galera (DNS drops briefly).
- **All DB pods** (2026-07-30): `resources` on mariadb-galera + proxy sidecars in
  all 9 DB sub-sections across 7 CRs (keystone, glance, neutron, nova×4, cinder,
  octavia, designate). Values: galera 200m/512Mi/2Gi; haproxy 50m/192Mi/512Mi;
  service-reload + create-ca-bundle 10m/32Mi/64Mi. No CPU limits.
  Still unfixable: no `resources` for the Galera `ssl-terminator` or
  `priorityClassName` (needs upstream yaook).

### Monitoring

- **kubelet metricRelabelings are PER-ENDPOINT.** The kubelet SM scrapes
  `/metrics`, `/metrics/cadvisor`, `/metrics/probes` — separate chart lists
  (`metricRelabelings`/`cAdvisorMetricRelabelings`/`probesMetricRelabelings`). A
  rule in the wrong list fires silently on nothing. Setting a list REPLACES the
  chart defaults wholesale (reproduce the 7 cAdvisor rules above an `additions`
  marker). Verify with `count by (metrics_path) ({job="kubelet"})`. When dropping
  a metric, disable dependent rule groups.
- **yaook ServiceMonitors invisible by default** (openstack): 92 SMs carry no
  `release: kube-prometheus-stack`. `clusters/openstack/monitoring.yaml` uses a
  `NotIn` `serviceMonitorSelector` (allow-by-default — re-check cardinality when
  adding operators). Cross-namespace `tlsConfig` secrets work (resolved from the
  SM's own ns). Two upstream bugs: the OVN PodMonitor names wrong ports; the
  `ovsdb`/`ovn_relay` SMs point at the ssl-terminator (only real OVS metrics are
  `socket_up`/`flow_limit`). No `openstack_*` without the exporter.
- **Prometheus OOM was cardinality, not tuning** (mgmt, 2026-07-26). 313k head
  series, apiserver 82%. Dropped 9 histogram families + inert metrics → ~108k
  (−65%); kept `apiserver_request_total`; disabled dependent SLO rule groups. Add
  `GOMEMLIMIT` (~80% of limit — a hard limit alone is an OOM cliff) + bound
  `remoteWrite maxShards`. 6h local retention (Prometheus is a shipper). Separately,
  `mimir-ingester-0` CrashLoop was DISK (stale 2Gi PVC vs 5Gi template — expand
  IN PLACE, do NOT raise the immutable `volumeClaimTemplates`/chart value). Mimir
  chart 6.x silently enabled Kafka/ingest-storage — disable BOTH
  `kafka.enabled: false` + `mimir.structuredConfig.ingest_storage.enabled: false`.
- **KSM customResourceState for Flux CRDs**: `gotk_resource_info`
  (`ready`/`suspended`/`revision`). Flux CRD RBAC under top-level
  `kube-state-metrics.rbac.extraRules` (the nested `customResourceState.rbac` is
  silently ignored by some chart versions). Powers the fluxcd dashboard +
  `FluxResourceNotReady`.
- **monitoring-gated ServiceMonitors** (Aug 2026): `ServiceMonitor` is a
  Prometheus Operator CRD shipped ONLY by the `monitoring` add-on
  (kube-prometheus-stack). Any base that emits a SM and is delivered to workload
  clusters WITHOUT monitoring hard-fails the apply on `no matches for kind
"ServiceMonitor"`. Rule: **a base must NEVER emit a SM unconditionally if it
  reaches monitoring-less clusters.** Two offenders were fixed:
  - **flux SM**: split out of `infrastructure/fluxcd/operator` (pushed to EVERY
    workload cluster by the mandatory `flux-instance` spine) into
    `infrastructure/fluxcd/monitoring`. Delivered only where the CRD exists:
    mgmt/openstack `flux-operator.yaml` add a `flux-metrics` Kustomization
    (`dependsOn: monitoring`); the `monitoring` Sveltos profile pushes a
    `flux-metrics` Flux Kustomization to opt-in workload clusters.
  - **cert-manager SM**: base `values.yaml` now defaults
    `prometheus.servicemonitor.enabled: false`; re-enabled by an inline
    HelmRelease `values` patch (Helm merges over the ConfigMap → keeps the
    `release:` label) on mgmt + openstack `cert-manager.yaml`, and — for workload
    clusters — a templated (`projectsveltos.io/template`) `cert-manager-install`
    ConfigMap in the `cert-manager` Sveltos profile that appends the patch
    `{{- if eq (index .Cluster.metadata.labels "sveltos.argus.rpcu.io/monitoring") "enabled" }}`.
    No dependsOn on monitoring from cert-manager (Flux just retries until the CRD
    lands); avoids a cross-profile HelmRelease-ownership conflict.
- **cert-manager monitoring** (Aug 2026): `prometheus.enabled: true` alone only
  adds scrape annotations (NOT honoured). Need `prometheus.servicemonitor.enabled: true`
  - `labels: {release: kube-prometheus-stack}` (mgmt selector; harmless on
    openstack), but the SM is DEFAULT-OFF in the shared base and re-enabled per
    monitoring-capable cluster (see "monitoring-gated ServiceMonitors" above).
    Metrics: `certmanager_certificate_expiration_timestamp_seconds`,
    `_not_before_timestamp_seconds` (for %-lifetime), `_ready_status`. Expiry alerts
    use %-of-lifetime (10%/20%), not fixed days (avoids false alerts on 72h certs).
- **kube-apiserver CPU is TLS-handshake bound, not request volume** (openstack).
  ~2 cores/apiserver at 2-3 inflight requests: per-connection RSA-2048 handshakes
  - baremetal contention. Fix: ECDSA-P256 keys — baremetal via **hephaestus**
    `kubeadm-bootstrap.nix`; CAPI clusters via `-control-plane-v3`. Only affects
    certs at init/renewal. Caveat: cumulative counters are per-apiserver-process;
    `--raw /metrics` is LB'd across replicas, so counter-rate subtraction across
    scrapes is garbage — use gauges, or pin to one instance.
- **Grafana ALERT rules MUST NOT use `$cluster`** (2026-08-01). It's a
  dashboard-only variable; in an alert query it stays literal → 0 series → NoData
  → suppressed by `noDataState: OK`, so the alert silently never fires (CR shows
  `ApplySuccessful`; the tell is `alerts[].state: Normal (NoData)` via
  `/api/prometheus/grafana/api/v1/rules`). Keep `cluster` as an OUTPUT label via
  `by (cluster, ...)`. Only `rules-flux.yaml` had this bug.

### Resilience & sizing

- **Node resilience** (2026-07-26): the repo had NO `MachineHealthCheck`, so
  unreachable nodes stranded StatefulSet Pods (`Terminating` forever, at-most-one
  semantics — Prometheus/Mimir/Vault/kamaji-etcd all wedged). All 4 ClusterClasses
  now define `healthCheck` (workers 300s / `unhealthyLessThanOrEqualTo: 40%` /
  `maxInFlight: 1` [workers-only]; kubeadm CPs 600s / `1`). `-v2` templates add
  kubelet `--kube-reserved`/`--system-reserved`/eviction thresholds (defaults let
  Pods commit 100% + eviction too tight to beat the OOM killer). Uneven VM packing
  is historical placement (makise had 0 VMs); do NOT "fix" via `novaComputeConfig`.
- **Crossplane `DeploymentRuntimeConfig` is `pkg.crossplane.io/v1beta1`, not `v1`**
  (only `Provider`/`ClusterProviderConfig` are `v1`). `v1` fails the server
  dry-run and cascades crossplane-zitadel → crossplane-resources →
  grafana-alerting + chihiro to `Ready=False`.
- **mgmt workload sizing policy**: mem request ≈ P95/current, mem limit ≈ 2×
  observed max, **CPU request-only (no limit)** — from 72h Mimir history. Crossplane
  providers get resources via a `DeploymentRuntimeConfig` + `runtimeConfigRef`
  (vault 448Mi/896Mi/40m, openstack 384/768/40m, zitadel 256/640/30m, random
  128/256/20m). KSM under the hyphenated `kube-state-metrics:` key. kgateway
  top-level `resources`. sveltos per-controller (agents/driftDetectionManager not
  tunable in 1.12.7). Not editable here: kube-apiserver/etcd static pods, Kamaji
  tenant CPs.

---

## 9. Summary

Production-grade GitOps repo: declarative infra (YAML/Helm) reconciled by Flux;
multi-cluster (mgmt + openstack baremetal + Sveltos-driven workload); Cilium,
Rook/Ceph, kgateway, cert-manager, OpenStack via Yaook, CAPI/CAPO; NixOS dev
env; pre-commit quality gates; 1-minute Git sync.

**Repository**: <https://github.com/RPCU/argus.git> · **Branch**: main ·
**Clusters**: openstack (baremetal), mgmt (CAPI management).

---

**Last Updated**: August 2026 — **Split the ClusterClasses out of the
`cluster-api-templates` Flux Kustomization** into a new
`cluster-api-clusterclasses` one (`infrastructure/cluster-api-clusterclasses/` +
the second Kustomization object in `clusters/mgmt/cluster-api-templates.yaml`,
`dependsOn: cluster-api-templates`; the Sveltos `capi-management` bundle mirrors
the split). The old single Kustomization had no intra-set apply ordering, so a
`-vN` templateRef rotation let the ClusterClass reconcile against a not-yet-present
template → topology/templateRef error that marked the WHOLE Kustomization NotReady
and dragged the valid templates down, retrying forever. Now `cluster-api-templates`
holds ONLY the versioned templates and runs `wait: true` (statusless CRs → Ready
immediately); `cluster-api-clusterclasses` adopts them (`wait` omitted to avoid the
topology-controller wedge); `clusters` now `dependsOn: cluster-api-clusterclasses`.
Prune-safe handoff: `cluster-api-templates` was set `prune: false` for ONE commit
(so dropping the ClusterClasses from its inventory did NOT delete them; the
new Kustomization adopted them in place via server-side apply, owner-label change
only) and is now restored to `prune: true`. Backstop: the CAPI `validation.clusterclass.cluster.x-k8s.io` webhook
hard-refuses deletion of any in-use ClusterClass (verified live —
`openstack-default`/`openstack-kamaji` can't be pruned while `mgmt`/`production`
reference them). Prior substantive change: Wired the **capi-janitor** into the
Sveltos `capi-management` bundle so a workload cluster promoted to a management
cluster (label `sveltos.argus.rpcu.io/capi-management: enabled`) gets the janitor
too. Added a `capi-janitor.yaml` Flux Kustomization
(`path: ./infrastructure/capi-janitor`, `dependsOn: cluster-api-providers`,
`wait: true`) to the `capi-management-flux-kustomizations` ConfigMap in
`infrastructure/sveltos/clusterprofiles/capi-management.yaml`, mirroring
`clusters/mgmt/capi-janitor.yaml`. Without it, deleting an `OpenStackCluster` on
the promoted mgmt cluster would hit the OCCM-LB-holds-network teardown deadlock.
The base is self-contained (namespace/SA/RBAC/CA-bundle/Deployment) so a plain
Flux takeover suffices (same pattern as `capo-identity`/`cluster-api-templates`).
Prior substantive change: Added the **capi-janitor-openstack** operator on
mgmt (`infrastructure/capi-janitor/` plain manifests: namespace
`capi-janitor-system`, SA, ClusterRole/Binding, single-replica Recreate
Deployment pulling `zot.rpcu.io/public/capi-janitor-openstack-go:latest` built by
`../capo-janitor`; wired via `clusters/mgmt/capi-janitor.yaml` Flux Kustomization
`dependsOn: cluster-api-providers`, registered in `clusters/mgmt/kustomization.yaml`).
It watches CAPO `OpenStackCluster` CRs, adds the `janitor.capi.stackhpc.com`
finalizer, and on deletion purges OCCM/Cinder-CSI leftovers (FIPs, Octavia LBs,
SGs, Cinder volumes+snapshots, appcred) before CAPO tears down the network. The
cluster name it matches tagged resources against comes from the CAPI-managed
`cluster.x-k8s.io/cluster-name` label the topology controller already puts on the
generated OpenStackCluster (verified live on `mgmt`/`production`) — no
ClusterClass/CR change was needed. Prior substantive change: Added a **dragonfly**
Sveltos add-on
(`infrastructure/sveltos/clusterprofiles/dragonfly.yaml`, registered in that
dir's `kustomization.yaml`): a Flux-takeover ClusterProfile gated by
`sveltos.argus.rpcu.io/dragonfly: enabled` that installs the DragonflyDB operator
(Redis-compatible) on opt-in workload clusters via the SAME base mgmt uses
(`./infrastructure/dragonfly`); the Dragonfly INSTANCE stays app-owned (atlas
production's zot registry consumes one as its Redis remoteCache). Added the
matching chihiro toggle (`clusters/mgmt/apps/chihiro/cm.yaml`: `dragonfly`
boolean, default OFF, injects the label) and pre-enabled it on the production
Cluster CR (`clusters/mgmt/clusters/production.yaml`). Prior substantive change:
Made Sveltos add-on ServiceMonitors
**monitoring-gated** so they only deploy where the Prometheus Operator CRDs
exist: split the flux SM out of `infrastructure/fluxcd/operator` into
`infrastructure/fluxcd/monitoring` (mgmt/openstack `flux-operator.yaml` add a
`flux-metrics` Kustomization `dependsOn: monitoring`; the `monitoring` Sveltos
profile pushes it to opt-in workload clusters), and defaulted the cert-manager
base `prometheus.servicemonitor.enabled: false`, re-enabled via HelmRelease
`values` patches on mgmt/openstack + a templated `cert-manager-install` ConfigMap
gated on the `sveltos.argus.rpcu.io/monitoring` Cluster label (see §8
"monitoring-gated ServiceMonitors"). Prior substantive change: cert-manager
expiry alerts switched to percentage-of-lifetime thresholds (<10% critical, <20%
warning) via `certmanager_certificate_not_before_timestamp_seconds`
(`rules-certmanager.yaml`, `cert-manager-dashboard.yaml`). Prior notable work:
`rules-node.yaml` `for` 10m→1h on `NodeCPUHigh`/`NodeMemoryHigh`; cert-manager
metrics enablement; the Grafana-`$cluster` alert bug fix + Crossplane
`DeploymentRuntimeConfig` `v1beta1` fix; mgmt workload resource sizing; KSM
customResourceState for Flux CRDs; FluxCD dashboard/monitoring; fleet-wide yaook
DB BestEffort fix; openstack-exporter + dashboard rewrites; ECDSA-P256 control
planes; Grafana Operator/DaaS migration. See git history for full detail.
