# Argus Project Guide for AI Agents

## ⚠️ CRITICAL INSTRUCTIONS FOR AI AGENTS

### 1. Commit Policy

**Do NOT commit changes unless explicitly asked by the user.**

- Always preview changes and request confirmation before committing
- Show `git diff` output to the user
- List all files that will be committed
- Draft commit message for user approval

### 2. Documentation Policy

**ALWAYS UPDATE THIS FILE (agents.md) IF YOU MAKE ANY CHANGES TO THE PROJECT**

Whenever you modify the codebase:

- Add/update relevant sections in this agents.md file
- Document new components, versions, or configurations
- Update directory structure if files are added/removed
- Update technology versions if Helm/tool versions change
- Update the "Last Updated" date at the end of this file
- Include changes in the same request when asking for commit permission

**Example workflow**:

1. Make changes to infrastructure/rook/configs/cephcluster.yaml
2. Update the "rook/configs/" section in Section 1 of agents.md
3. Ask user: "I've updated X and documented it in agents.md. Ready to commit?"

---

**IMPORTANT**: Do NOT commit changes unless explicitly asked by the user. Always preview changes and request confirmation before committing.

## Project Overview

**Argus** is RPCU's GitOps repository for Kubernetes cluster configuration, built with Flux CD. The project implements declarative, automated infrastructure management for cloud environments, ensuring consistent deployments and continuous reconciliation.

### Key Features

- **Everything is Infrastructure as Code.** Almost the entire stack is described
  declaratively in this repository and reconciled by Flux CD — the Kubernetes
  clusters (mgmt + openstack), the CNI (Cilium), storage (Rook/Ceph), the full
  OpenStack control plane (Yaook operators + service CRs), networking
  (Neutron/OVN), certificates (cert-manager/trust-manager), the API gateway
  (Gateway API/kgateway), DNS (ExternalDNS/Designate), cluster lifecycle
  (Cluster API/CAPO), and even the OpenStack tenant resources (networks, routers,
  subnets via Crossplane). There is effectively no click-ops: a change is a Git
  commit, and Flux continuously converges the live state to match `main`.

- **Adding a compute node is trivial.** To grow OpenStack capacity you do **not**
  edit this repo — you simply **join a new node to the openstack Kubernetes
  cluster and apply the right Kubernetes node labels**. The Yaook operators do
  the rest: they watch node labels and, when a node carries the labels their
  `nodeSelectors` match, they automatically schedule the corresponding OpenStack
  agents onto it (e.g. `nova-compute` from `nova.yaml`, the OVN `ovn-controller`
  from `neutron.yaml`), register it as a hypervisor in Nova, and wire it into the
  OVN data plane. The relevant operator CRs select nodes via
  `compute.configTemplates[].nodeSelectors[].matchLabels`
  (`infrastructure/yaook/nova.yaml:24`) and
  `setup.ovn.controller.configTemplates[].nodeSelectors[].matchLabels`
  (`infrastructure/yaook/neutron.yaml:94`). With the current `matchLabels: {}`
  (match-all) these target every node; to gate compute/OVN onto specific nodes,
  set explicit labels here and apply the matching labels (plus the Yaook
  management labels, e.g. `node.yaook.cloud/...`) to the new node. No
  re-provisioning of the control plane is required — capacity scales by labeling
  nodes.

---

## 1. Directory Structure

### Root Level

- `clusters/` - Cluster-specific Kubernetes configurations
- `infrastructure/` - Reusable infrastructure components
- `nix/` - Custom Nix packages and dependency management
- `npins/` - Pinned external dependencies (managed by npins tool)
- `devenv.nix` - Development environment setup
- `devenv.yaml` - DevEnv configuration
- `devenv.lock` - Locked dependency versions
- `.envrc` - Direnv shell environment loader
- `.gitignore` - Git ignore patterns
- `README.md` - Project overview
- `renovate.json5` - Renovate dependency-update configuration (see "Dependency Updates (Renovate)" in Section 5)

### nix/ - Custom Nix Packages & Sources

- `default.nix` - Imports and exposes all custom packages
- `sveltosctl.nix` - Sveltos CLI tool package definition (v1.9.0)

### npins/ - Pinned Dependencies

- `default.nix` - npins infrastructure (do not edit manually)
- `sources.json` - npins sources pinned versions
  - Defines GitHub source locations and hashes
  - Update with `npins update` command

### clusters/ - Cluster-Specific Configurations

**Primary cluster**: `clusters/openstack/`

Key files:

- `kustomization.yaml` - Master orchestration file
- `cilium.yaml` - Cilium networking with cluster-specific patches
- `cert-manager.yaml` - Certificate management
- `cert-manager-issuer.yaml` - Cert-Manager issuers
- `trust-manager.yaml` - trust-manager (setup + configs with dependsOn)
- `gateway-api.yaml` - Gateway API CRDs installation
- `kgateway-crds.yaml` - kgateway CRDs installation
- `kgateway.yaml` - kgateway controller and Gateway installation
- `rook.yaml` - Rook storage orchestrator (three Flux Kustomizations:
  `rook-setup` → `rook-ceph-csi` [./infrastructure/rook/csi-drivers, dependsOn
  rook-setup] → `rook-configs` [dependsOn rook-setup + rook-ceph-csi])
- `yaook-operator.yaml` - Yaook OpenStack operators
- `crossplane.yaml` - Crossplane Flux Kustomizations: `crossplane` (Helm),
  `crossplane-openstack` (provider base), `crossplane-zitadel` (provider base),
  `crossplane-compositions` (XRD/Composition/Function base), and
  `crossplane-resources` (the openstack overlay `./clusters/openstack/crossplane`).
- `crossplane/` - **openstack overlay** (concrete instances). `openstack/`:
  OpenStack managed/composite resources (networks, routers, flavors, groups,
  projects, security groups, DNS zone) + the `ClusterProviderConfig` (ns yaook).
  `zitadel/`: the SINGLE-owner shared Zitadel platform (org `rpcu`, projects,
  roles, actions), the Zitadel `ProviderConfig`, and the
  `openstack`/`netbird`/`kubernetes` OIDC apps (ns zitadel). The `kubernetes`
  app is a public/native PKCE client with **no client secret** (and thus no
  `writeConnectionSecretToRef`) used by the CAPI clusters' kube-apiserver OIDC —
  the ClusterClass `oidc` variable injects its issuer/clientID as apiserver
  flags. The mgmt cluster must NOT also manage the Zitadel platform — both
  clusters share one Zitadel instance.
- `external-secrets.yaml` - External Secrets Operator
- `flux-operator.yaml` - Flux operator deployment
- `fluxcd/` - Flux CD configuration
  - `flux-instance-patch.yaml` - Flux instance patches
  - `kustomization.yaml` - Flux component references

**Management cluster**: `clusters/mgmt/`

Cluster API (CAPI) management cluster. Bootstrapped manually with kind +
`clusterctl` today; intended to self-manage after `clusterctl move` so the
mgmt cluster runs the CAPI providers that manage itself.

Key files:

- `kustomization.yaml` - Master orchestration file
- `cilium.yaml` - Cilium networking (shared infrastructure/cilium with mgmt-specific patches: k8sServiceHost 172.16.255.212:6443; uses the base `socketLB.hostNamespaceOnly: false` default — see note below). **Cilium's LoadBalancer implementation is disabled on mgmt**: the patch sets `l2announcements.enabled: false` and `$patch: delete`s the base `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy`. `Service` type `LoadBalancer` is instead handled by the OpenStack CCM via Octavia (see `openstack-ccm.yaml`).
- `cert-manager.yaml` - Certificate management (prerequisite for CAPI operator)
- `gateway-api.yaml` - Gateway API CRDs installation (shared `infrastructure/gateway-api`, identical to openstack)
- `kgateway-crds.yaml` - kgateway CRDs installation (shared `infrastructure/kgateway/crds`, dependsOn gateway-api)
- `kgateway.yaml` - kgateway controller + Gateway (shared `infrastructure/kgateway`, dependsOn gateway-api + kgateway-crds + cert-manager-issuer). **Patched for mgmt**: a JSON 6902 patch removes the base's Cilium `lbipam.cilium.io/ips` annotation from the `gwp-static-ip` GatewayParameters (Cilium LB is disabled on mgmt — Octavia/OCCM auto-assigns the LoadBalancer floating IP); strategic-merge patches rewrite both Gateway listener hostnames from `*.rpcu.vpn` to `*.mgmt.rpcu.lan`, repoint the `cert-manager.io/cluster-issuer` annotation to `root-mgmt`, and change `certificateRefs` to `rpcu-lan-wildcard-tls` (the mgmt-local cert from `cert-manager-issuer`).
- `cert-manager-issuer.yaml` - mgmt-local cert-manager issuer chain (dependsOn cert-manager + kgateway-crds). Path `./clusters/mgmt/cert-manager-issuer`. Unlike openstack (which uses `root-rpcu`/`*.rpcu.vpn`), mgmt has its **own independent root CA** `root-mgmt` and a `*.mgmt.rpcu.lan` wildcard. `cert-manager-issuer/internal-issuer.yaml` = `selfsigned` ClusterIssuer → `root-mgmt` CA Certificate (ns cert-manager, isCA, RSA-4096, 87600h) → `root-mgmt` CA ClusterIssuer; `cert-manager-issuer/wildcard-cert.yaml` = leaf Certificate/secret `rpcu-lan-wildcard-tls` (ns kgateway-system, `*.mgmt.rpcu.lan`). The `root-mgmt` CA is unconstrained (can sign any `.rpcu.lan` name); only `*.mgmt.rpcu.lan` is issued on this cluster.
- `external-secrets.yaml` - External Secrets Operator (sources CAPO credentials)
- `cluster-api-operator.yaml` - Cluster API Operator (dependsOn cert-manager)
- `cluster-api-providers.yaml` - CAPI provider CRs (dependsOn cluster-api-operator + external-secrets)
- `openstack-ccm-identity.yaml` - SecretStore + ExternalSecret rendering the OCCM `cloud-config` secret from `capo-variables` clouds.yaml (dependsOn external-secrets + cluster-api-providers, `wait: false`)
- `openstack-ccm.yaml` - OpenStack Cloud Controller Manager HelmRelease, provides `Service` type `LoadBalancer` via Octavia + Node initialisation (dependsOn openstack-ccm-identity)
- `external-snapshotter-crds.yaml` - external-snapshotter VolumeSnapshot CRDs (shared `infrastructure/external-snapshotter/crds`, v8.6.0)
- `external-snapshotter.yaml` - snapshot-controller Deployment + RBAC (shared `infrastructure/external-snapshotter/controller`, dependsOn external-snapshotter-crds)
- `openstack-cinder-csi.yaml` - Cinder CSI Driver (DaemonSet + Deployment), provides `StorageClass` for Cinder PVCs (dependsOn openstack-ccm-identity + external-snapshotter-crds — its csi-snapshotter sidecar needs the VolumeSnapshot CRDs)
- `ceph-csi-cephfs.yaml` - External CephFS CSI driver, provides a **ReadWriteMany (RWX)** `StorageClass` (`ceph-cephfs`) backed by the openstack cluster's `rpcu-fs` CephFilesystem (dependsOn external-secrets + crossplane-resources for the `vault-backend` store; `wait: false` — the `csi-cephfs-secret` ExternalSecret needs the mgmt Vault path `secrets-mgmt/ceph-csi` populated out of band). Path is the mgmt overlay `./clusters/mgmt/ceph-csi-cephfs` (bases `infrastructure/ceph-csi-cephfs` + adds the `ceph-csi-cephfs-cluster-values` ConfigMap with the remote Ceph FSID + mon endpoints, appended as a second `valuesFrom`).
- `ceph-csi-cephfs/` - mgmt overlay for the external CephFS CSI driver. `cluster-values.yaml` = the `ceph-csi-cephfs-cluster-values` ConfigMap (remote Ceph FSID + mons, placeholders to fill in); `kustomization.yaml` bases `../../../infrastructure/ceph-csi-cephfs`.
- `external-dns.yaml` - InternalDNS with Designate provider, syncs Service/Gateway DNS records into the rpcu.lan zone (dependsOn external-secrets; `wait: false` — ESO-rendered openstack-credentials secret requires the manual capo-variables secret first)
- `crossplane.yaml` - Crossplane Helm install (shared `infrastructure/crossplane`, dependsOn nothing)
- `crossplane-providers.yaml` - provider-random base (shared `infrastructure/crossplane-providers`, dependsOn crossplane). Currently unused / failing to install — candidate for removal.
- `crossplane-zitadel.yaml` - provider-zitadel base (shared `infrastructure/crossplane-zitadel`, dependsOn crossplane). Provider only.
- `crossplane-resources.yaml` - **mgmt overlay** `./clusters/mgmt/crossplane/zitadel` (dependsOn crossplane-zitadel, `prune: false`). mgmt's own Zitadel `ProviderConfig` (`default`, points at the manually-created `crossplane-provider-zitadel` secret in ns zitadel) + the **chihiro** `Oidc` app. The chihiro Oidc references the shared org/project by **literal external ID** (org rpcu `369994019545117645`, project administration `370001231734928333`) because those Project/Org MRs are owned by the openstack cluster and don't exist here. It writes its connection secret as `chihiro-oidc-conn` (keys `attribute.client_id` / `attribute.client_secret`) into chihiro-system.
- `chihiro.yaml` - chihiro app (path `./clusters/mgmt/apps/chihiro`, dependsOn cert-manager-issuer + kgateway + dragonfly-operator + external-secrets + crossplane-resources). The added `apps/chihiro/oidc.yaml` is an ESO `SecretStore` + `ExternalSecret` that remaps `chihiro-oidc-conn`'s `attribute.client_id`/`attribute.client_secret` into the `chihiro-oidc` secret (keys `clientId`/`clientSecret`) consumed by `deploy.yaml`. The `apps/chihiro/cm.yaml` `cluster.template` writes a `sveltos.argus.rpcu.io/capo-version` **annotation** on the generated `Cluster` CR from a `capoVersion` form parameter (editable `select`, `kube-admin`-only, default sentinel `"default"`, path `metadata.annotations.'sveltos.argus.rpcu.io/capo-version'`, options `default`/`v0.14.4`), and adds opt-in labels for add-ons (`external-dns`, `gateway-api`, etc.) via form toggles (`externalDns`, `gatewayApi`, etc.) that map to corresponding Sveltos `ClusterProfile` opt-in labels on the `Cluster` CR. The Sveltos `capi-management` ClusterProfile reads this annotation and only patches the CAPO `InfrastructureProvider` version when it is a real version (the `"default"` sentinel and empty are treated as no-override → repo-pinned version). A `select` (not free-text) is used because chihiro hard-errors on an empty `{{ chihiro.* }}` create-form placeholder, so the field must always carry a non-empty value (`default`).
- `dragonfly-operator.yaml` - Dragonfly (Redis-compatible) operator for chihiro's session store
- `vault.yaml` - HashiCorp Vault (path `./infrastructure/vault`, dependsOn kgateway + openstack-cinder-csi). **HA Vault (3-node integrated Raft storage, no external Consul)** on the mgmt cluster. Adapted from the bealv `flux-mgmt` repo: the chart's bundled Ingress is disabled in favour of a Gateway API `HTTPRoute` at `vault.mgmt.rpcu.lan` (TLS terminated at the shared kgateway `https` Gateway with the `rpcu-lan-wildcard-tls` cert / root-mgmt CA — no per-app cert-manager issuer like the source's `bealv-mgmt`/`vault.bealv-mgmt.lan`), and each replica's `dataStorage` PVC explicitly requests the `cinder-delete` StorageClass (mgmt has no default StorageClass). The 3 replicas require 3 distinct schedulable nodes (chart `required` podAntiAffinity).
- `kubernetes-rbac.yaml` - Flux Kustomization (path `./clusters/mgmt/apps/kubernetes-rbac`, no dependsOn) applying the OIDC group → RBAC bindings on the workload cluster: `apps/kubernetes-rbac/crb.yaml` binds the **bare** `kube-admin` Group → `cluster-admin` and `kube-user` Group → `view`. The bare group names match the shared Zitadel `groupsClaim` Action output and the ClusterClass's empty `groupsPrefix`. Mirrors the bealv reference (`gitops/apps/kubernetes/crb.yaml`). Harmless before OIDC is enabled (the groups simply never appear in any token).
- `sveltos.yaml` - Flux Kustomization (path `./infrastructure/sveltos`, `prune: true`) deploying the shared `infrastructure/sveltos` base (Sveltos core + OIDC RBAC).
- `monitoring.yaml` - kube-prometheus-stack for mgmt (path `./infrastructure/monitoring`, wait: true). Same base as workload clusters, patched with local Mimir remote_write URL (`http://mimir-gateway.monitoring.svc:80/api/v1/push`) and `externalLabels.cluster: mgmt`.
- `mimir.yaml` - Grafana Mimir TSDB (path `./infrastructure/mimir`, dependsOn monitoring). Single-replica monolithic mode with filesystem storage (50Gi PVC).
- `grafana-operator.yaml` - Grafana Operator v5 deployment (path `./infrastructure/grafana-operator`, dependsOn monitoring) enabling cross-namespace DaaS.
- `grafana.yaml` - Grafana CR & DaaS instance (path `./infrastructure/grafana`, dependsOn monitoring + mimir + grafana-operator). Accessible at `https://grafana.mgmt.rpcu.lan`.
- `grafana-alerting.yaml` - Grafana unified alerting (path `./infrastructure/grafana/alerting`, dependsOn grafana + external-secrets + crossplane-resources, **`wait: false`**). Split from `grafana` for blast-radius isolation (same rationale as capo-identity / openstack-ccm-identity): its Discord-webhook `ExternalSecret` cannot be Ready until the Vault path `secrets-mgmt/grafana` is seeded AND the ESO Vault policy is widened — both manual steps — and `grafana` runs `wait: true`, so folding them together would let that manual gap stall the dashboards.
- `flux-operator.yaml` - Flux operator deployment
- `fluxcd/` - Flux CD configuration
  - `flux-instance-patch.yaml` - Flux instance patch (sync path ./clusters/mgmt, domain mgmt.local)
  - `kustomization.yaml` - Flux component references

> **mgmt Crossplane / chihiro OIDC.** The mgmt cluster runs its own Crossplane
> (Helm + zitadel provider) and creates the chihiro OIDC client on the shared
> Zitadel instance. The `crossplane-provider-zitadel` admin-credentials secret
> (ns zitadel) is created **manually** on mgmt (same as on openstack). The
> chihiro `Oidc` writes `chihiro-oidc-conn`; an ESO `ExternalSecret` remaps it to
> the `chihiro-oidc` secret with the `clientId`/`clientSecret` keys chihiro
> expects. The mgmt cluster must NOT manage the shared Zitadel platform
> (org/projects/roles/actions) — that is owned exclusively by the openstack
> overlay, since both clusters share one Zitadel instance.

**Workload clusters**: no dedicated `clusters/` directory.

CAPI-provisioned workload clusters are fully **Sveltos-driven** — there is no
`clusters/workload/` directory. The Sveltos `flux` ClusterProfile bootstraps the
Flux Operator + a FluxInstance whose `sync` block points **directly at
`./infrastructure/fluxcd/operator`**, so Flux self-reconciles its own operator
install from the centralized repo (the operator's own `kustomization.yaml` is the
sync root — no per-workload-cluster overlay dir is needed).

Everything else a workload cluster gets is pushed **per-cluster by Sveltos
ClusterProfiles**, gated by labels (see the `infrastructure/sveltos` section):

- The Flux Operator + FluxInstance (`flux` ClusterProfile, `type: workload`).
- Cilium — both the bootstrap Helm install (`cilium` ClusterProfile) and the
  Flux-managed takeover (`cilium-values` ClusterProfile, which also pushes the
  Flux `cilium` Kustomization CR) — gated by `sveltos.argus.rpcu.io/cilium: enabled`.
- OIDC user RBAC (`oidc-rbac` ClusterProfile, gated by
  `sveltos.argus.rpcu.io/oidc-rbac: enabled`).

This avoids a shared Git sync path that would force an addon onto every
Flux-bootstrapped cluster: opt-in addons live in their own labelled
ClusterProfiles, not in a wholesale-reconciled directory.

### infrastructure/ - Reusable Components

**cert-manager/** - SSL/TLS Certificate Management (v1.19.2)

- `helmrelease.yaml` - Helm deployment
- `helmrepo.yaml` - Helm repository
- `namespace.yaml` - Kubernetes namespace
- `values.yaml` - Custom Helm values (prometheus.enabled: true for metrics)
- `kustomization.yaml` - Kustomization manifest

**trust-manager/** - Certificate Trust Bundle Distribution (v0.18.0)

_trust-manager/setup/_ - Initial installation

- `helmrelease.yaml` - trust-manager Helm chart (v0.18.0)
- `helmrepo.yaml` - Helm repository (charts.jetstack.io)
- `kustomization.yaml` - Kustomization manifest

_trust-manager/configs/_ - Trust bundle configuration

- `bundle.yaml` - Bundle resource distributing RPCU root CA
- `kustomization.yaml` - Kustomization manifest

**cilium/** - eBPF-Based Networking (v1.18.6)

- `helmrelease.yaml` - Helm deployment
- `helmrepo.yaml` - Repository reference
- `ciliumloadbalancerippool.yaml` - Load balancer IPs: 10.0.0.240-10.0.0.253
- `ciliuml2announcementpolicy.yaml` - Layer 2 announcement policy
- `values.yaml` - Custom values
- `kustomization.yaml` - Kustomization manifest

**gateway-api/** - Kubernetes Gateway API CRDs (v1.4.1)

- `kustomization.yaml` - Kustomization to deploy upstream experimental CRDs

**kgateway/** - Kubernetes API Gateway (v2.2.2)

- `crds/` - kgateway CRDs deployment
  - `namespace.yaml` - Kubernetes namespace (`kgateway-system`)
  - `helmrepo.yaml` - Helm repository (`oci://cr.kgateway.dev/kgateway-dev/charts`)
  - `helmrelease-crds.yaml` - kgateway CRDs Helm chart
  - `kustomization.yaml` - Kustomization manifest
- `helmrelease.yaml` - kgateway controller Helm chart
- `gateway.yaml` - `Gateway` resource definition (openstack cluster)
- `httplistenerpolicy.yaml` - `HTTPListenerPolicy` for WebSocket upgrades and access logs
- `kustomization.yaml` - Kustomization manifest

**monitoring/** - kube-prometheus-stack Base (v87.17.0)

- `namespace.yaml` - Namespace `monitoring`
- `helmrepo.yaml` - HelmRepository `prometheus-community`
- `helmrelease.yaml` - Shared `kube-prometheus-stack` HelmRelease (Grafana disabled, 6h local retention, 3GB retention limit, 5Gi PVC, node-exporter, kube-state-metrics). Per-cluster `remoteWrite` and `externalLabels` are injected via Flux Kustomization patches.
  **Cardinality control lives here** and is split per kubelet ENDPOINT — the
  kubelet ServiceMonitor scrapes three (`/metrics`, `/metrics/cadvisor`,
  `/metrics/probes`) and the chart exposes a SEPARATE relabeling list for each
  (`metricRelabelings`, `cAdvisorMetricRelabelings`, `probesMetricRelabelings`).
  A rule placed in the wrong list silently never fires — see "kubelet
  metricRelabelings are per-endpoint" in Section 8. Also drops the high-cardinality
  apiserver/etcd histogram families and disables the rule groups that depend on
  them (`kubeApiserver{Burnrate,Histogram,Slos}`, `k8sContainerMemory{Cache,Swap}`).
- `kustomization.yaml` - Kustomization manifest

**openstack-exporter/** - prometheus-openstack-exporter (image v1.6.0, openstack cluster)

Exports the `openstack_*` metric family by querying the OpenStack APIs with the
yaook admin credentials — the ONLY source of nova VM state, per-service health,
quotas, and cinder/neutron/octavia/glance/designate resource counts in the whole
repo. Before it existed the openstack cluster had zero `openstack_*` metrics
(only the yaook infra exporters `rabbitmq_*`/`mysql_*`), so VM state was
invisible to monitoring and the OpenStack Control Plane dashboard's VM panels /
the VM-error alerts had nothing to query. Deployed on the **openstack cluster**
only.

Deployed as **plain manifests** (not a Flux HelmRelease) because the upstream
`openstack-exporter/helm-charts` chart is not published to any Helm repo (only
packaged locally in-repo), so it can't back a HelmRelease — same direct-manifest
approach this repo uses for ORC and gateway-api.

- `secretstore.yaml` - ServiceAccount `openstack-exporter-reader` (ns monitoring)
  - Role/RoleBinding in `yaook` scoped to ONLY the `keystone-admin` secret + ESO
    `SecretStore yaook-keystone-admin` (Kubernetes provider, `remoteNamespace:
yaook`). Cross-namespace read of the yaook admin creds, same pattern as
    capo-identity / openstack-ccm-identity. `caProvider.namespace` is unset (ESO
    admission rejects it on a namespaced SecretStore).
- `externalsecret.yaml` - ESO `ExternalSecret` rendering the os-client-config
  `clouds.yaml` (secret `openstack-exporter-cloud-config`) from `keystone-admin`.
  `auth_url` is the INTERNAL keystone `https://keystone.yaook.svc:5000/v3`
  (verified reachable, HTTP 200), `verify: false` (keystone presents the RPCU
  bundle CA the exporter image doesn't trust; cluster-internal endpoint — same
  `insecure` choice the crossplane-provider-openstack ExternalSecret makes),
  `region_name: hetzner`, `identity_interface: internal`, admin user
  `yaook-sys-maint` / project `admin`.
- `deployment.yaml` - Deployment (1 replica, ns monitoring, image
  `ghcr.io/openstack-exporter/openstack-exporter:1.6.0`, `--endpoint-type
internal`) + Service (9180) + ServiceMonitor (60s). The image is
  **distroless** (no shell — scrape it via its pod IP, not `kubectl exec sh`).
  The ServiceMonitor carries `release: kube-prometheus-stack` AND no yaook
  component label, so it is scraped by BOTH the label-based default selector and
  the openstack cluster's allow-by-default `NotIn` selector.
- `kustomization.yaml` - Kustomization manifest.

> **What it does NOT expose.** Verified live: the hypervisor-capacity nova
> metrics (`openstack_nova_running_vms` / `vcpus_used` / `memory_used_bytes`) are
> ABSENT on this cloud — its placement/nova setup does not serve the
> os-hypervisors detail the exporter reads. VM counts therefore come from
> `openstack_nova_total_vms` (cluster, verified = 11) and
> `openstack_nova_limits_instances_used` (per tenant). Per-VM state comes from
> `openstack_nova_server_status` (value 4 = ERROR, 0 = ACTIVE, 11 = SHUTOFF —
> see the exporter's `knownServerStatuses`). Deployed by
> `clusters/openstack/openstack-exporter.yaml` (dependsOn external-secrets +
> monitoring, `wait: false`).

**mimir/** - Grafana Mimir TSDB (v5.6.0)

- `helmrepo.yaml` - HelmRepository `grafana`
- `helmrelease.yaml` - `mimir-distributed` HelmRelease in monolithic mode with filesystem storage (5Gi PVC) and 72h retention policy (`compactor_blocks_retention_period: 72h`).
- `httproute.yaml` - HTTPRoute `mimir.mgmt.rpcu.lan` on mgmt internal Gateway for cross-cluster `remote_write`.
- `kustomization.yaml` - Kustomization manifest

**grafana-operator/** - Grafana Operator v5 (v5.16.0)

- `helmrepo.yaml` - OCI HelmRepository `grafana-operator` (`oci://ghcr.io/grafana/helm-charts`).
- `helmrelease.yaml` - `grafana-operator` HelmRelease watching all namespaces for DaaS.
- `kustomization.yaml` - Kustomization manifest

**grafana/** - Grafana Central Monitoring UI & DaaS Instance (Grafana Operator CRDs v1beta1)

- `grafana.yaml` - `Grafana` CR (v1beta1) with 5Gi PVC, `dashboards: grafana-central` label, and Zitadel OIDC integration (`grafana-oidc-conn`).
- `mimir-datasource.yaml` - `GrafanaDatasource` CR for central Mimir (`http://mimir-gateway.monitoring.svc:80/prometheus`).
- `dashboards/cluster-overview-dashboard.yaml` - `GrafanaDashboard` CR for CPU/RAM cluster & node metrics with a dropdown cluster selector.
- `dashboards/pvc-storage-dashboard.yaml` - `GrafanaDashboard` CR for PVC storage & volume usage with dropdown cluster and namespace filters.
- `dashboards/node-filesystem-dashboard.yaml` - `GrafanaDashboard` CR for node filesystem usage.
- `dashboards/ceph-storage-dashboard.yaml` - `GrafanaDashboard` CR for Ceph/Rook storage. **Fully rewritten** against real `ceph_*` metric names (the old dashboard queried `ceph_*` families that did exist but had never been scraped because `spec.monitoring.enabled` was unset). 20 panels: health status, OSD up/total, mon quorum, RAW utilisation%, unclean PGs, health checks table, capacity, pool stored bytes, pool fill%, objects/latency table, OSD apply latency, client throughput/IOPS per pool, PG states. Dashboard title changed from "Ceph Storage Health" to "Ceph / OpenStack Storage". Every panel verified against live Mimir before commit.
- `dashboards/openstack-control-plane-dashboard.yaml` - `GrafanaDashboard` CR
  for the **openstack cluster ONLY**. Deliberately SINGLE-CLUSTER: every query
  is pinned to `cluster="openstack"` and there is no `$cluster` variable (the
  only template variable is `$node`, over the three hypervisors). Sections:
  Health Summary → Message Bus (RabbitMQ) → Service Databases (Galera) →
  Network Data Plane (OVS) → Baremetal Kubernetes.
  **Every metric it queries was verified to exist by scraping the exporter
  before the panel was written** — the previous version of this dashboard was a
  generic multi-cluster Kubernetes dashboard whose latency panels were
  permanently blank because they queried `apiserver_request_duration_seconds_bucket`,
  which the monitoring base drops. Deliberately has NO `openstack_*` panels
  (nova hypervisors, VM counts, quotas): those need
  prometheus-openstack-exporter, which is not deployed, and inventing panels for
  absent metrics is exactly the failure being fixed. OVS coverage is limited to
  `socket_up` + `flow_limit` because that is genuinely all the yaook
  ovn-monitoring DaemonSet exports.
- `dashboards/palworld-dashboard.yaml` -
- `dashboards/palworld-dashboard.yaml`
- `dashboards/palworld-dashboard.yaml` - `GrafanaDashboard` CR (uid `palworld-server`, folder `Gaming`) for the Palworld dedicated server. **Hand-built** (no longer the grafana.com 20421 import) against the metric set of [Banh-Canh/palworld-exporter-go](https://github.com/Banh-Canh/palworld-exporter-go), the `exporter` sidecar in the **atlas** repo (`clusters/production/palworld/deploy.yaml`) — that exporter's `ServiceMonitor` lives in atlas (labeled `release: kube-prometheus-stack`), gets scraped by the Sveltos-pushed Prometheus on the production cluster, and is `remote_write`n to central Mimir here. No app in argus produces these metrics; the dashboard is here only because Grafana is mgmt-only. 37 panels in 6 rows: **Server Health** (`palworld_up`/fps/frame_time/slot usage/uptime/version/Level.sav size), **Performance** (FPS + frame time trends, concurrency vs slots, per-player session lanes), **Container & Storage** (cAdvisor CPU/memory per container + `palworld-data` PVC gauge + 24h restart count — these come from kube-prometheus-stack, NOT the exporter), **Players** (join-by-name table of level/ping/buildings/pals/coords, level bar gauges, ping trend), **Pals & World** (owned/wild pal counts, guilds, unit-type donut, per-player party-vs-base pals, strongest characters), **Saves & Settings** (Level.sav growth + derivative, save-file ages/sizes, `palworld_setting` rates table). Single `$cluster` template variable (`label_values(palworld_up, cluster)`), every query filtered on it. The Pals & World row is empty unless `ENABLE_GAMEDATA_API: "true"` is set on the server (atlas `clusters/production/palworld/cm.yaml`), and the Saves panels need an exporter build newer than `v0.0.1`, whose save collector could not find a nested `Level.sav`. Every PromQL expression was validated against the production Prometheus before being committed.
- `dashboards/fluxcd-dashboard.yaml` - `GrafanaDashboard` CR for Flux CD GitOps status. **Uses kube-state-metrics customResourceState** (`gotk_resource_info`) for Ready/Suspended status tables, plus native controller metrics (`gotk_reconcile_duration_seconds_*`) for timing. Requires KSM `customResourceState.enabled: true` in the kube-prometheus-stack HelmRelease (see "kube-state-metrics customResourceState" in Section 8). 17 panels in 4 rows: **Overview** (Reconcilers count, Failing Reconcilers, Sources count, Failing Sources, Suspended, Clusters), **Reconcile Performance** (reconciler/source avg duration bar gauges), **Status** (Reconciler Readiness table with Ready/Not Ready color coding via `gotk_resource_info{customresource_kind=~"Kustomization|HelmRelease"}`, Source Readiness table, Suspended Objects table), **Timing** (reconcile duration per-resource timeseries for reconcilers and sources). Single `$cluster` template variable.
- `dashboards/cert-manager-dashboard.yaml` - `GrafanaDashboard` CR for cert-manager certificate status and expiry. Uses `certmanager_certificate_expiration_timestamp_seconds` (NotAfter timestamp) and `certmanager_certificate_ready_status{condition="True"}` (1/0 ready status). Requires cert-manager Prometheus metrics enabled (`infrastructure/cert-manager/values.yaml` `prometheus.enabled: true`). 5 rows: **Overview** (Total Certificates, Ready, Not Ready, Expiring <7d, Expiring <30d, Expiring >30d stat panels), **Certificate Details** (table of all certs with namespace, name, issuer kind/name, cluster, Ready status with green/red color-background, Days Left with gauge coloring 7/30/60d thresholds, Expiry Date as relative time), **Expiry by Issuer** (time series of days-until-expiry per certificate for visual planning), **Not Ready Certificates** (table of only certs with Ready=False, red color-background). Two template variables: `$cluster` (multi, includeAll) and `$namespace` (multi, includeAll). Every query filtered on both.
- `httproute.yaml` - HTTPRoute `grafana.mgmt.rpcu.lan` pointing to `grafana-service:3000` on mgmt internal Gateway.
- `kustomization.yaml` - Kustomization manifest

**grafana/alerting/** - Grafana Unified Alerting → Discord (own Flux Kustomization)

Grafana-**managed** alert rules (evaluated by Grafana against the Mimir
datasource), NOT Prometheus `PrometheusRule` CRs. That choice is forced by the
architecture: the Mimir `ruler` is disabled (`infrastructure/mimir/helmrelease.yaml`)
and every cluster's kube-prometheus-stack Alertmanager has **no receivers
configured** (chart default `null` route), so Grafana unified alerting is the
only path in this repo that actually delivers a notification. Because the
queries run against central Mimir, ONE rule set covers **every** cluster that
`remote_write`s into it (currently `mgmt`, `openstack`, `production`) — the
`cluster` external label comes back as an alert label automatically, so there is
nothing per-cluster to deploy.

- `discord-secret.yaml` - ESO `ExternalSecret` `grafana-discord-webhook` (ns
  monitoring) reading `secrets-mgmt/grafana` property `discord-webhook-url` via
  the `vault-backend` `ClusterSecretStore`
  (`clusters/mgmt/crossplane/vault/vault-store.yaml`). `remoteRef.key` is
  relative to the mount — ESO inserts the KV-v2 `/data/` segment itself.
- `folder.yaml` - `GrafanaFolder` `Alerts`. Required: unlike `GrafanaDashboard`
  (whose plain `folder:` string auto-creates), a `GrafanaAlertRuleGroup` needs a
  real folder referenced by `folderRef`/`folderUID`.
- `contactpoint-discord.yaml` - `GrafanaContactPoint` `discord`. Uses the
  multi-receiver `receivers[]` form (needs operator >= v5.21.0; mgmt runs
  **v5.24.0**). The webhook URL is injected at reconcile time via
  `valuesFrom` → `targetPath: url` from the secret above, so it is never in Git.
- `notification-policy.yaml` - `GrafanaNotificationPolicy`, root receiver
  `discord`, grouped by `grafana_folder`/`alertname`/`cluster` so one message
  covers all affected nodes of one rule on one cluster. A child route re-notifies
  `severity: critical` hourly instead of the 4h default. **A Grafana instance has
  exactly ONE notification policy tree** (global object) — a second CR targeting
  the same instance would fight this one.
- `rules-node.yaml` - `GrafanaAlertRuleGroup` `node-resources` (interval 1m):
  `NodeCPUHigh` (>85%, 1h), `NodeMemoryHigh` (>90% of MemAvailable, 1h),
  `NodeDiskSpaceLow` (>85%, 15m), `NodeNotReady` (critical, 10m).
- `rules-storage.yaml` - `GrafanaAlertRuleGroup` `persistent-volumes`
  (interval 5m): `PersistentVolumeSpaceLow` (>85%, 15m) off
  `kubelet_volume_stats_*`. Split from the node group because a rule group has a
  single evaluation `interval` and volume stats move slowly.
- `rules-pods.yaml` - `GrafanaAlertRuleGroup` `pods-health`
  (interval 1m): `PodCrashLoopBackOff` (critical, 5m, waiting_reason
  `CrashLoopBackOff`), `PodRestartingFrequently` (critical, 10m, >3 restarts in
  15m), `PodContainerNotReady` (warning, 15m, not-ready excluding Jobs and
  containers in Waiting state to avoid false positives from init containers and
  rolling-update transitions).
- `rules-openstack.yaml` - `GrafanaAlertRuleGroup` `openstack-resources`
  (interval 5m): `NovaVMInError` (critical, 5m, server_status==4),
  `OpenStackServiceDown` (warning, 5m, any of 8 services reporting <1 up),
  `NovaComputeAgentDown` (critical, 5m, agent_state{nova-compute} lt 1),
  `OctaviaLoadBalancerNotOnline` (warning, 10m, LB status > 0 while ACTIVE).
  All rules are single-cluster `cluster="openstack"` — these metrics only exist
  where the openstack-exporter is deployed.
- `rules-flux.yaml` - `GrafanaAlertRuleGroup` `flux-reconciliations`
  (interval 1m): `FluxReconciliationErrors` (critical, 5m, any kind
  result="error" rate > 0), `FluxReconciliationTimeouts` (warning, 10m,
  timeout rate > 0), `FluxControllerHighErrorRate` (critical, 10m,
  error rate > 50% of total), `FluxResourceStale` (warning, 1h, zero
  reconciliations in 1h), `FluxResourceNotReady` (critical, 10m,
  `gotk_resource_info{ready="False"}` — direct KSM signal). All rules
  linked to the `fluxcd-status` dashboard. Covers every cluster that
  remote_writes into Mimir.
- `rules-certmanager.yaml` - `GrafanaAlertRuleGroup` `certmanager-certificates`
  (interval 5m): `CertManagerCertificateExpiringCritical` (critical, 5m,
  certificate expires within 7 days), `CertManagerCertificateExpiringWarning`
  (warning, 5m, certificate expires within 30 days),
  `CertManagerCertificateNotReady` (warning, 15m, certificate Ready=False for
  > 15m). Uses `certmanager_certificate_expiration_timestamp_seconds` (NotAfter
  > timestamp) and `certmanager_certificate_ready_status{condition="True"}`.
  > Requires cert-manager Prometheus metrics enabled AND the ServiceMonitor
  > sub-toggle (`infrastructure/cert-manager/values.yaml`:
  > `prometheus.enabled: true` + `prometheus.servicemonitor.enabled: true`).
  > `prometheus.enabled: true` ALONE only adds `prometheus.io/*` scrape
  > annotations to the Deployments — it does NOT create a ServiceMonitor, and
  > kube-prometheus-stack does not honour those annotations, so nothing is
  > scraped. The ServiceMonitor also carries
  > `labels: {release: kube-prometheus-stack}` because the mgmt Prometheus
  > `serviceMonitorSelector` is `matchLabels: {release: kube-prometheus-stack}`
  > (NOT the openstack cluster's allow-all `NotIn` selector) — without the label
  > it is silently never scraped on mgmt.
- `kustomization.yaml` - Kustomization manifest (namespace monitoring).

Non-obvious things that were verified live and must not be "simplified":

- **Rule shape is three stages**: `A` instant PromQL → `B` reduce(last) →
  `C` threshold, with `condition: C`. Every metric used survives the monitoring
  base's aggressive `metricRelabelings` (`node_*`, `kube_*`,
  `kubelet_volume_stats_*` are all intact) and every expression was executed
  against live Mimir before commit.
- **`NodeDiskSpaceLow` MUST keep the `and on (cluster, instance, mountpoint)
(node_filesystem_readonly == 0)` join.** These are NixOS hosts where
  `/nix/store` is a read-only bind mount that is permanently ~100% full;
  without the join the rule fires forever on every node. Confirmed live:
  `/nix/store` reports `readonly=1`, real writable mounts peak at ~61%.
- **`NodeNotReady` must NOT use `== 0`.** That filters the series away entirely
  when all nodes are healthy, which Grafana reads as **NoData**, not "OK". It
  queries the raw `kube_node_status_condition{condition="Ready",status="true"}`
  and lets the threshold stage compare `lt 1`, so the rule always has data.
- **`noDataState: OK` is deliberate.** If Mimir or `remote_write` breaks, `NoData`
  would make every rule fire at once and bury the real signal.
- **Panel linking uses ANNOTATIONS, not the CRD fields.** The
  `rules[].dashboardUid` / `rules[].panelId` fields are **deprecated and ignored
  by the operator** — the CRD description says so explicitly. Use
  `annotations.__dashboardUid__` + `annotations.__panelId__`; **both** are
  required (one alone is ignored) and `__panelId__` must be a **quoted string**
  because the annotations map is typed `map[string]string`. Linked rules draw
  alert-state markers on the panel and put a deep-link to it in every Discord
  message. Current links: CPU → `cluster-cpu-ram-overview` panel 7, memory →
  same dashboard panel 8, disk → `node-filesystem-overview` panel 5, PVC →
  `cluster-pvc-storage-overview` panel 10 (a bargauge, so it gets the deep-link
  but not the on-panel markers — those only render on time series panels).
  `NodeNotReady` is intentionally unlinked: no dashboard here visualises node
  readiness, and pointing at an unrelated panel would misdirect responders.

**Manual prerequisite** (documented in `infrastructure/vault/README.md` →
"Grafana alerting bootstrap"): the ESO Kubernetes-auth role `external-secrets`
is bound **only** to the `crossplane` Vault policy, which grants read on
`secrets-mgmt/data/crossplane*` and nothing else. A separate `grafana` policy
must be created and attached **alongside** `crossplane` (the role write
overwrites, so both must be listed), and the webhook seeded at
`secrets-mgmt/grafana`. Until then the rules still evaluate but notifications
do not deliver.

**rook/** - Distributed Storage (Ceph v19.2.3)

_rook/setup/_ - Initial installation

- `helmrelease.yaml` - Rook Helm chart (v1.20.1). Since Rook v1.20 the
  operator NO LONGER deploys the CSI drivers itself — the `rook-ceph` chart
  bundles the **ceph-csi-operator** as a subchart (default
  `csi.installCsiOperator: true`), and the drivers are admin-managed via the
  separate `ceph-csi-drivers` chart (see _rook/csi-drivers/_ below). Values
  are just `crds.enabled: true`; no CSI values belong here anymore.
- `helmrepo.yaml` - Repository reference
- `kustomization.yaml` - Kustomization manifest

_rook/csi-drivers/_ - Ceph-CSI drivers chart (NEW requirement in Rook v1.20)

- `helmrelease.yaml` - `ceph-csi-drivers` chart v1.0.3 (targetNamespace
  rook-ceph). Values are an exact copy of Rook's recommended
  `deploy/charts/rook-ceph/../ceph-csi-drivers/values.yaml` for release-1.20:
  `imageSet.name: rook-csi-operator-image-set-configmap` (the ConfigMap Rook
  generates), system priority classes, and Driver CRs
  `rook-ceph.rbd.csi.ceph.com` + `rook-ceph.cephfs.csi.ceph.com` (names MUST
  keep the rook operator namespace prefix to match the existing StorageClass
  provisioners). `nfs`/`nvmeof` drivers disabled (external RWX is served via
  the CephNFS/Ganesha gateway + `csi-driver-nfs`, not ceph-csi NFS). The
  pre-existing Driver/OperatorConfig CRs (auto-created by Rook v1.18/v1.19)
  were adopted by Helm on install — do NOT also set CSI values in the
  rook-ceph operator chart, that would duplicate ownership.
- `helmrepo.yaml` - HelmRepository `ceph-csi-operator`
  (`https://ceph.github.io/ceph-csi-operator`)
- `kustomization.yaml` - Kustomization manifest

_rook/configs/_ - Ceph cluster configuration

- `cephcluster.yaml` - Ceph cluster with 3 monitors (lucy, makise, quinn).
  **Sets `monitoring.enabled: true`** so the Rook operator creates the
  `rook-ceph-mgr` ServiceMonitor (target `rook-ceph-mgr:9283`, the Ceph mgr
  `prometheus` module → the standard `ceph_*` family). WITHOUT this the mgr
  endpoint existed but nothing scraped it (no ServiceMonitor,
  `spec.monitoring` empty), so Mimir held ZERO ceph metrics and the entire Ceph
  Storage Health dashboard was permanently blank. The openstack
  kube-prometheus-stack picks the generated ServiceMonitor up automatically via
  its allow-by-default `NotIn` serviceMonitorSelector (it carries no
  `state.yaook.cloud/component` label). No PrometheusRule is generated — alerting
  is centralized in Grafana unified alerting against Mimir.
  Sets `priorityClassNames` (mon/osd `system-node-critical`, mgr
  `system-cluster-critical`) and `resources` for mon/mgr/osd (osd: **500m** CPU /
  5Gi request, 8Gi limit; Rook auto-tunes `osd_memory_target` from the
  request). Previously all daemons ran BestEffort — first eviction/OOM
  victims on the hyperconverged nodes (they share the hosts with
  nova-compute VMs). No CPU limits on purpose (throttling hurts tail latency).
  **OSD cpu request is 500m, not the raw core count**: eviction protection
  comes from the `system-node-critical` priorityClass (NOT the request), and
  measured OSD usage peaks at ~350m. The former `cpu: "2"` was a ~6x
  over-reservation that, on the smallest hyperconverged node (**quinn has 8
  cores vs 12 on lucy/makise** — otherwise identical role/labels: all three are
  control-plane + hypervisor), left <300m allocatable and **wedged the per-node
  OVN dataplane rollout**: `neutron-ovs-vswitchd-*` / `neutron-ovn-controller-*`
  each request 300m and are hard node-pinned (nodeAffinity `metadata.name`), so
  they could not schedule anywhere else and sat `Pending` on quinn
  (`FailedScheduling ... Insufficient cpu`). With no CPU limit the OSD still
  bursts freely past 500m during recovery; the request only governs scheduling
  admission + `cpu.weight` under contention. See "Ceph OSD CPU over-reservation
  wedges the OVN rollout on the small node" in Section 8.
- `cephblockpool.yaml` - RBD block pool (replica 2, nvme, `pg_autoscale_mode`
  on + `target_size_ratio: 0.8`). See the "PG autoscaler / overlapping CRUSH
  roots" note in Section 8 — ALL pools must use nvme-classed CRUSH rules.
- `cephfilesystem.yaml` - CephFS filesystem `rpcu-fs` (replica-2 metadata +
  `data0` data pools on nvme, `activeCount: 1` MDS with standby-replay,
  `preserveFilesystemOnDelete: true`). Provides the shared POSIX filesystem
  needed for **ReadWriteMany (RWX)** volumes (RBD/`general` is RWO-only).
  The MDS has `system-cluster-critical` priority, resources (2Gi request /
  4Gi limit — Rook auto-sets `mds_cache_memory_limit` to ~50% of the limit),
  and **required podAntiAffinity** on `kubernetes.io/hostname`: without it
  both MDS pods (active + standby-replay) were observed co-scheduled on the
  same node, so one node failure would have taken CephFS down entirely.
- `cephobjectstore.yaml` - S3-compatible object storage. Both pools set
  `deviceClass: nvme` so their CRUSH rules are nvme-classed — see the
  "PG autoscaler / overlapping CRUSH roots" note in Section 8.
- `cephobjectstoreuser.yaml` - Object store credentials
- `storageclassrdb.yaml` - RBD storage class (`general`, cluster default, RWO)
- `storageclasscephfs.yaml` - CephFS storage class (`cephfs`,
  `rook-ceph.cephfs.csi.ceph.com` provisioner, fsName `rpcu-fs`, RWX-capable,
  NOT default). In-cluster (openstack) RWX only — external clusters use
  `infrastructure/csi-driver-nfs` via the CephNFS gateway.
- `cephnfs.yaml` - `CephNFS` gateway `rpcu-nfs` (1 active NFS-Ganesha server)
  exporting the `rpcu-fs` CephFilesystem to EXTERNAL clusters, + a
  `LoadBalancer` Service pinned at `10.0.0.245` (Cilium L2 pool) on TCP/2049.
  The IP is pinned via the `lbipam.cilium.io/ips` annotation (repo convention,
  same as `infrastructure/kgateway/gateway.yaml`) — NOT the deprecated
  `spec.loadBalancerIP` field. This exists because the Rook cluster is
  POD-networked: mons advertise ClusterIPs and mgr/MDS/OSDs advertise pod IPs
  in the Ceph maps, so an external ceph-csi client can NEVER reach them
  (CreateVolume hangs → PVCs Pending forever) — LB-fronted mons are not
  sufficient. (The out-of-band `rook-ceph-mon-{a,d,f}-external` LB Services at
  `10.0.0.242-244` from that failed attempt were deleted from the live
  cluster; `.242-.244` are free again.) The NFS gateway runs in-cluster;
  consumers only need TCP/2049. The export is created/enforced by the
  `rpcu-nfs-export-ensure` CronJob (see `nfs-export-ensure.yaml` below) —
  no longer a manual one-off. The `server` block now sets
  `priorityClassName: system-cluster-critical` + `resources` (500m/1Gi req,
  2Gi mem limit, no CPU limit) and a **relaxed `livenessProbe`**
  (`failureThreshold: 24`, `periodSeconds: 15` ≈ 6 min) — the gateway was
  previously BestEffort with the default ~100s liveness, so the 2026-07-06
  node event exit-137-killed it repeatedly, each kill costing a 90s NFS grace
  period + client session churn. **security_label remount trap** (2026-07-07
  second incident): ganesha only reloads an export change on restart, and NFS
  clients cache the server's supported-attributes bitmap in the mount
  superblock at mount time — a client that mounted while `security_label` was
  still advertised keeps requesting it (EREMOTEIO for non-root statx()) until
  REMOUNTED. After any `security_label` change: restart the ganesha pod AND
  force a remount on every consuming cluster (scale ALL pods sharing the
  affected PVCs on a node to 0 so kubelet unstages the volume, then back up).
- `nfs-export-ensure.yaml` - `rpcu-nfs-export-ensure` CronJob (rook-ceph,
  hourly at :17, `concurrencyPolicy: Forbid`). Declaratively enforces the
  `rpcu-nfs` CephFS export (exports are mgr `nfs` module state in the `.nfs`
  RADOS pool — NOT declarable on the CephNFS CR): creates it if missing (e.g.
  after the CephNFS cluster or `.nfs` pool is recreated) and re-applies
  `security_label: false` if it drifts (the default on a fresh export is
  `true`, which breaks non-root statx() on Linux 6.x+ → Jellyfin/Radarr
  library scans fail with Remote I/O error). No-op when the export already
  matches (checks `ceph nfs export info` before applying), so steady state
  causes no ganesha reloads. Auth plumbing (SA `rook-ceph-default`, mon
  endpoints, admin keyring) mirrors `toolbox-deployment.yaml`. NOTE: when the
  job has to FIX drift it logs a reminder — the remount trap above still
  applies (the job fixes the server; stale client mounts must be remounted).
- `openstack-clients.yaml` - CephClients: `glance` + `cinder` (rbd caps).
  (The former external `cephfs` CephClient was removed together with the
  ceph-csi-cephfs external driver — NFS consumers need no cephx key.)
- `rook-ceph-config.yaml` - Ceph daemon configuration overrides (Rook
  `rook-ceph-config` ConfigMap). Sets `mon_max_pg_per_osd = 400` (up from the
  default 250) — the July 2026 PG splits brought the 3-OSD cluster to 251
  PGs/OSD, which hit the default limit and triggered a persistent
  `TOO_MANY_PGS` health warning.
- `toolbox-deployment.yaml` - Ceph admin toolbox
- `gateway/` - Gateway API resources for Rook services
  - `httproute-ceph.yaml` - HTTPRoute for Ceph dashboard (TLS termination at Gateway)
  - `kustomization.yaml` - Kustomization manifest
- `kustomization.yaml` - Kustomization manifest

**csi-driver-nfs/** - RWX volumes over NFS, CephFS-backed (chart v4.13.4)

Upstream [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs)
for clusters with **no local Ceph** (the mgmt cluster and opt-in workload
clusters run as OpenStack VMs). Provides **ReadWriteMany (RWX)** volumes from
the openstack cluster's `rpcu-fs` CephFilesystem, exported over NFS by the
Rook `CephNFS` gateway (`infrastructure/rook/configs/cephnfs.yaml`) at the
pinned LB IP `10.0.0.245`. REPLACES the former `ceph-csi-cephfs` external
driver, which could never work: the Rook cluster is pod-networked, so the
mgr/MDS/OSDs advertise pod/ClusterIPs unreachable from the VMs (CreateVolume
hung until the CSI deadline; PVCs stayed Pending). NFS consumers need only
TCP/2049 to the LB IP — no Ceph credentials, no Vault/ESO plumbing.

- `helmrepo.yaml` - HelmRepository (`https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts`)
- `helmrelease.yaml` - `csi-driver-nfs` chart v4.13.4 (kube-system — system
  priority classes, same rationale as openstack-cinder-csi). Inline values
  (no per-cluster overrides needed).
- `storageclass.yaml` - RWX StorageClass **`ceph-cephfs`** (name kept from the
  former ceph-csi-cephfs driver so existing PVC manifests keep working):
  `provisioner: nfs.csi.k8s.io`, `server: 10.0.0.245`, `share: /rpcu-fs`, one
  subdirectory per PV, `nfsvers=4.1`. Keep `server` in sync with the CephNFS
  LB Service IP.
- `README.md` - Rationale (pod-networked Rook ⇒ NFS), pieces, one-time export
  bootstrap command.
- `kustomization.yaml` - Kustomization manifest.

> Identical on every consuming cluster — no per-cluster values, no secrets.
> Consumers: `clusters/mgmt/csi-driver-nfs.yaml` (mgmt) and the Sveltos
> `csi-driver-nfs` ClusterProfile (opt-in workload clusters, label
> `sveltos.argus.rpcu.io/csi-driver-nfs: enabled`). The NFS export is created
> once via the toolbox (persisted in the `.nfs` RADOS pool).
>
> **CRITICAL: `security_label: false` on the NFS export.** On Linux 6.x+
> kernels, `statx()` requests an NFSv4 GETATTR bitmap that includes
> `security_label` — a feature Ganesha/CephFS cannot serve for non-root users.
> This causes EREMOTEIO (Remote I/O error) on `statx()` calls, breaking any
> .NET/Node.js app that uses `Directory.Exists()` (Radarr, Jellyfin, etc.).
> The fix is a one-time export reconfiguration:
> `ceph nfs export config apply rpcu-nfs '{"security_label":false,...}'`.
> See `infrastructure/rook/configs/cephnfs.yaml` for the full command. If you
> recreate NFS PVCs, the fresh mounts will pick up this setting automatically.

**crossplane/** - Universal Control Plane (v2.2.0)

- `helmrelease.yaml` - Helm deployment
- `helmrepo.yaml` - Helm repository (charts.crossplane.io/stable)
- `namespace.yaml` - Kubernetes namespace (crossplane-system)
- `values.yaml` - Custom Helm values (beta features enabled: usages, realtime-compositions)
- `kustomization.yaml` - Kustomization manifest

> **Crossplane layout (shared bases vs per-cluster overlays).** The
> `infrastructure/crossplane*` dirs hold only **cluster-agnostic** pieces (the
> Crossplane Helm install, the provider packages, and the reusable composition
> machinery). All **concrete instances** (OpenStack managed/composite resources,
> the Zitadel platform, and the per-app OIDC clients) live in per-cluster
> overlays under `clusters/<cluster>/crossplane/`. This split exists because
> there is a **single shared Zitadel instance**: the Zitadel org/projects/roles/
> actions must be owned by exactly one cluster (the openstack cluster) — if both
> clusters applied them they would fight over the same external objects.

**crossplane-providers/** - Crossplane provider packages (mgmt)

- `provider-random.yaml` - provider-random (currently unused; install fails on mgmt — candidate for removal)
- `kustomization.yaml` - Kustomization manifest

**crossplane-openstack/** - Shared OpenStack provider base

- `provider.yaml` - provider-openstack package (cluster-scoped)
- `kustomization.yaml` - Kustomization manifest (namespace: crossplane-system, no-op for the cluster-scoped Provider)

**crossplane-zitadel/** - Shared Zitadel provider base (provider only)

- `provider.yaml` - provider-zitadel package (banhcanh/provider-zitadel)
- `kustomization.yaml` - Kustomization manifest. ONLY the provider lives here — the cluster-agnostic piece both clusters install. The ProviderConfig, Zitadel platform and OIDC apps are per-cluster overlays (see below).

**crossplane-compositions/** - Crossplane XRDs & Compositions (OpenStack)

- `xrd-externalnetwork.yaml` - CompositeResourceDefinition `externalnetworks.networking.rpcu.io` (v1alpha1, Namespaced)
- `composition-router.yaml` - Composition `external-network` (NetworkV2 + SubnetV2 + RouterV2)
- `function-patch-and-transform.yaml` - Crossplane patch-and-transform Function
- `kustomization.yaml` - Kustomization manifest. Left as its own Flux Kustomization (not folded into the overlay) to avoid pruning the in-use XRD, which would cascade-delete the ExternalNetwork composite and its real OpenStack network/router.

> The OpenStack concrete resources and the Zitadel platform/OIDC apps formerly in
> `infrastructure/crossplane-resources/` were moved to the openstack overlay
> `clusters/openstack/crossplane/` (`openstack/` + `zitadel/`). The mgmt cluster's
> chihiro OIDC client lives in `clusters/mgmt/crossplane/zitadel/`. See the
> per-cluster sections.

**external-secrets/** - External Secrets Operator (v2.3.0)

- `helmrelease.yaml` - Helm deployment
- `helmrepo.yaml` - Helm repository (charts.external-secrets.io)
- `namespace.yaml` - Kubernetes namespace (external-secrets)
- `values.yaml` - Custom Helm values
- `kustomization.yaml` - Kustomization manifest

**golinky/** - Link Shortener (v0.3.1)

- `kustomization.yaml` - Kustomization manifest (namespace: golinky, upstream bundle from `didactiklabs/golinky` v0.3.1)
- `golinky-service-patch.yaml` - Strategic merge patch: `type: LoadBalancer` with `lbipam.cilium.io/ips: "10.0.0.241"` for Cilium L2 IP pinning

**openstack-ccm/** - OpenStack Cloud Controller Manager (chart v2.35.0, app v1.35.0)

Provides `Service` type `LoadBalancer` via OpenStack Octavia and initialises
Nodes (removes the `node.cloudprovider.kubernetes.io/uninitialized` taint that
the kubelet carries when CAPO sets `--cloud-provider=external`). Deployed onto
the self-managing mgmt cluster (which runs as CAPO-provisioned OpenStack VMs).
This **replaces Cilium's L2-announcement LoadBalancer implementation** on mgmt.

- `helmrepo.yaml` - Helm repository (`https://kubernetes.github.io/cloud-provider-openstack`)
- `helmrelease.yaml` - OCCM Helm chart (v2.35.0, namespace kube-system)
- `namespace.yaml` - kube-system (declared for ordering)
- `values.yaml` - Custom values: image pinned to `v1.35.0`; `enabledControllers`
  = cloud-node, cloud-node-lifecycle, service (the `route` controller is
  intentionally NOT enabled — Cilium owns pod networking); `secret.create: false`
  (consumes the ESO-rendered `cloud-config` secret); flexvolume/PKI `extraVolumes`
  dropped (LB-only controller).
- `kustomization.yaml` - Kustomization manifest (configMapGenerator `openstack-ccm-values`)

**openstack-ccm-identity/** - OCCM cloud-config sync

ESO plumbing that renders the OCCM `cloud-config` secret (`kube-system`) from the
manually-placed `capo-variables` clouds.yaml (`capo-system`) — the same single
credential source CAPO's `identityRef` uses. Split out so an ESO failure cannot
abort the CCM HelmRelease apply (same blast-radius rationale as `capo-identity`).

- `secretstore.yaml` - ServiceAccount `openstack-ccm-reader` (kube-system) +
  Role/RoleBinding `openstack-ccm-capo-variables-reader` (capo-system, scoped to
  the `capo-variables` secret) + ESO `SecretStore capo-system-secrets`
  (kube-system, Kubernetes provider, `remoteNamespace: capo-system`).
- `externalsecret.yaml` - ESO `ExternalSecret` rendering `kube-system/cloud-config`
  with two keys: `clouds.yaml` (verbatim from `capo-variables`) and `cloud.conf`
  (`[Global] use-clouds=true` delegating auth to clouds.yaml; `[LoadBalancer]`
  Octavia config with `floating-network-id` = the Cluster's `externalNetworkId`;
  `lb-provider=ovn` — the mgmt cluster's OpenStack uses the OVN backend, NOT
  Amphora; `lb-method=SOURCE_IP_PORT` — OVN does not support ROUND_ROBIN or
  SOURCE_IP; `create-monitor=true` with explicit `monitor-delay=10s`,
  `monitor-timeout=10s`, `monitor-max-retries=3` — the OVN defaults are too
  aggressive (~5s timeout) and cause intermittent TLS handshake timeouts on
  Kamaji tenant API server pods under CPU load; see "OCCM health monitor
  timeouts" in Section 8).
- `README.md` - Rationale, contents, Flux wiring, caveats.
- `kustomization.yaml` - Kustomization manifest.

> Deployed by `clusters/mgmt/openstack-ccm-identity.yaml` with
> `dependsOn: external-secrets` + `cluster-api-providers` and `wait: false` (the
> ExternalSecret cannot be Ready until the manual `capo-variables` secret exists;
> the CCM Pods wait/CrashLoop until it appears).

**openstack-cinder-csi/** - OpenStack Cinder CSI Driver (chart v2.35.0, app v1.35.0)

Dynamic Cinder volume provisioning via the `cinder.csi.openstack.org` CSI
driver. Provides `StorageClass` resources (`cinder-delete`, `cinder-rwx`) so
PVCs can request OpenStack Cinder block storage. Runs as a DaemonSet (node
plugin) + Deployment (controller plugin) on the mgmt cluster.

Shares the `cloud-config` secret rendered by `openstack-ccm-identity` (same
OpenStack credentials, same `use-clouds=true` INI, same `/etc/config/cloud.conf`
mount path). No additional credential plumbing required.

- `helmrepo.yaml` - Helm repository (`https://kubernetes.github.io/cloud-provider-openstack`, name `cloud-provider-openstack-cinder` to avoid conflicting with the OCCM's repo in kube-system)
- `helmrelease.yaml` - Cinder CSI Helm chart (v2.35.0, namespace kube-system)
- `values.yaml` - Custom values: cinder-csi-plugin image pinned to `v1.35.0`;
  `secret.enabled: true`, `secret.create: false`, `secret.name: cloud-config`
  (shares the ESO-rendered secret); `clusterID: "mgmt"`.
- `kustomization.yaml` - Kustomization manifest (configMapGenerator `openstack-cinder-csi-values`)

**external-snapshotter/** - CSI Volume Snapshot support (v8.6.0)

Cluster-wide CSI snapshot machinery required by the Cinder CSI driver's
`csi-snapshotter` sidecar. Without the `VolumeSnapshot*` CRDs and the
snapshot-controller, the Cinder CSI controller plugin's snapshotter sidecar
cannot register and snapshot APIs are unavailable. Both pieces are plain
kustomize **remote bases** pinned to the upstream `v8.6.0` tag (same
fetch-by-URL pattern as `gateway-api` and `orc`). Deployed on the mgmt cluster.

- `crds/kustomization.yaml` - Remote base
  `github.com/kubernetes-csi/external-snapshotter//client/config/crd?ref=v8.6.0`
  → the 6 `snapshot.storage.k8s.io` + `groupsnapshot.storage.k8s.io` CRDs
  (VolumeSnapshot, VolumeSnapshotContent, VolumeSnapshotClass, and the
  VolumeGroupSnapshot trio, now GA/v1).
- `controller/kustomization.yaml` - Remote base
  `github.com/kubernetes-csi/external-snapshotter//deploy/kubernetes/snapshot-controller?ref=v8.6.0`
  → the `snapshot-controller` Deployment (2 replicas, ns kube-system) + its
  ServiceAccount/Role/RoleBinding/ClusterRole/ClusterRoleBinding. Upstream
  default namespace `kube-system` (same as the Cinder CSI on mgmt).

> Split into `crds/` and `controller/` so the CRDs reconcile first (the
> controller won't report Ready until they exist, and the Cinder CSI
> snapshotter sidecar needs them registered). On mgmt: `external-snapshotter`
> (controller) dependsOn `external-snapshotter-crds`; `openstack-cinder-csi`
> also dependsOn `external-snapshotter-crds`.

**external-dns/** - DNS record synchronization via OpenStack Designate (Helm chart v1.21.1, app v0.21.0)

Syncs Kubernetes `Service` and `Gateway HTTPRoute` resources into the OpenStack
Designate DNS zone (`rpcu.lan.`). Deployed on the mgmt cluster only (the
openstack cluster doesn't use ExternalDNS — its services are already in
Designate via yaook operators).

The in-tree Designate provider was removed from external-dns (PR #5126). This
setup uses the inovex webhook provider
(`github.com/inovex/external-dns-openstack-webhook`) as a sidecar container.
The webhook authenticates with OpenStack via a `clouds.yaml` file (NOT OS\_\*
env vars, which it does not support for auth).

Credentials follow the established ESO pattern: `capo-variables` (capo-system)
`clouds.yaml` is synced into the `internal-dns` namespace as `openstack-credentials`.
IMPORTANT: the `auth_url` in `capo-variables` must point at the gateway endpoint
(`https://keystone.rpcu.vpn`) — the in-cluster Keystone is unreachable from mgmt.

- `secret-credentials.yaml` - Namespace `internal-dns` + ServiceAccount `internal-dns`
  (created before the Helm chart so ESO's SecretStore can reference it) +
  Role/RoleBinding in `capo-system` granting the SA read access to `capo-variables` +
  ESO `SecretStore` `capo-system-secrets` (Kubernetes provider, remoteNamespace
  capo-system) + `ExternalSecret` `openstack-credentials` copying the raw
  `clouds.yaml` from `capo-variables`.
- `helmrepo.yaml` - HelmRepository (`https://kubernetes-sigs.github.io/external-dns/`)
- `values.yaml` - Base Helm values, consumed by the HelmRelease via `valuesFrom`
  (the generated `internal-dns-values` ConfigMap) instead of an inline `values:`
  block. `provider.name: webhook` with inovex `external-dns-openstack-webhook:2.2.0`
  sidecar; `sources: [ingress, gateway-httproute]`, `policy: upsert-only`,
  `registry: noop` (mgmt: wildcard TXT names `a-*.mgmt.rpcu.lan.` are invalid in
  Designate); `serviceAccount.create: false` (uses the pre-created SA); `env`:
  `OS_CLOUD=openstack`; `extraVolumes` mounts the `openstack-credentials` secret
  at `/etc/openstack` for both the main container and the webhook sidecar. These
  are the MGMT defaults — workload clusters override the domain scoping / registry
  via a SECOND `valuesFrom` ConfigMap appended by the Sveltos `external-dns`
  ClusterProfile (later valuesFrom wins).
- `helmrelease.yaml` - HelmRelease `internal-dns` (chart v1.21.1). Reads values
  via `valuesFrom` (`internal-dns-values` ConfigMap) so workload clusters can
  append a per-cluster override ConfigMap.
- `secret-credentials.yaml` - Namespace `internal-dns` + ServiceAccount `internal-dns`
  (created before the Helm chart so ESO's SecretStore can reference it) +
  Role/RoleBinding in `capo-system` granting the SA read access to `capo-variables` +
  ESO `SecretStore` `capo-system-secrets` (Kubernetes provider, remoteNamespace
  capo-system) + `ExternalSecret` `openstack-credentials` copying the raw
  `clouds.yaml` from `capo-variables`. **mgmt-only** — workload clusters have no
  `capo-system`/`capo-variables`, so this is NOT part of the `workload/` overlay.
- `kustomization.yaml` - Kustomization manifest (no global namespace override —
  Role/RoleBinding live in `capo-system`, everything else in `internal-dns`).
  `configMapGenerator` produces the `internal-dns-values` ConfigMap from
  `values.yaml` (`disableNameSuffixHash: true`).

> **No separate workload overlay.** Workload clusters reuse this SAME base
> (`./infrastructure/external-dns`) — the Sveltos `external-dns` ClusterProfile
> pushes a Flux Kustomization pointing at it and uses `patches` with
> `$patch: delete` to strip the four mgmt-only resources from
> `secret-credentials.yaml` (the ESO `SecretStore`/`ExternalSecret` reading
> `capo-variables`, and the `capo-system` Role/RoleBinding), keeping the
> Namespace + ServiceAccount. The per-cluster `openstack-credentials` Secret and
> the `internal-dns-workload-values` override ConfigMap (subdomain scoping +
> per-cluster TXT registry) are pushed by the ClusterProfile. This avoids
> duplicating the helmrepo/helmrelease/values into a `workload/` directory.

**sveltos/** - Sveltos multi-cluster add-on manager (core chart v1.10.0, dashboard chart v1.10.1)

Basic Sveltos install for the **mgmt cluster** (Sveltos manages add-ons across
the CAPI-provisioned workload clusters from here). Structured one-concern-per-file
so it's easy to extend (ClusterProfiles, extra RBAC, etc. can be added as new
files). Deployed only on mgmt for now.

- `namespace.yaml` - Namespace `projectsveltos`
- `helmrepo.yaml` - HelmRepository (`https://projectsveltos.github.io/helm-charts`)
- `helmrelease.yaml` - Sveltos core controllers (chart `projectsveltos` v1.10.0).
  Values are provided by a `sveltos-core-values` ConfigMap (referenced via
  `valuesFrom`), which must exist before Flux reconciles the HelmRelease.
  For the mgmt cluster, the values ConfigMap is created by the
  `clusters/mgmt/sveltos.yaml` kustomization; for new management clusters
  bootstrapped via the `capi-management` ClusterProfile, Sveltos pushes a
  templated version with `kubernetesClusterDomain: <cluster-name>.local` and
  `agent.managementCluster: true`.
- `clusterprofiles/kustomization.yaml` - Labels all resources under
  `clusterprofiles/` with `argus.rpcu.io/sveltos-clusterprofile=true` (via
  `labels: [{pairs: {...}, includeSelectors: false}]`). This label is the
  mechanism that lets the `capi-management` ClusterProfile reuse the same
  parent `./infrastructure/sveltos` base for new management clusters: the
  pushed Flux `Kustomization` strips everything under `clusterprofiles/` with a
  single `$patch: delete` targeting this labelSelector, yielding a core-only
  install. No separate `./core` subdirectory is needed.
- `clusterprofiles/oidc-rbac.yaml` - **OIDC user RBAC pushed to the CHILD (CAPI
  workload) clusters** (the focus of this install). A Sveltos `ClusterProfile`
  (`syncMode: ContinuousWithDriftDetection`) + a **templated** `policyRefs`
  `ConfigMap` (`projectsveltos.io/template: "true"`). The bare Zitadel group
  `kube-admin` is statically bound to `cluster-admin`; **additionally, one
  `cluster-admin` `ClusterRoleBinding` is generated per group name listed in the
  workload `Cluster`'s `chihiro.io/groups` annotation** (comma-separated; each
  name is `trim`med, empty entries skipped, binding named `oidc-group-<name>`).
  The annotation is read via a `templateResourceRefs` entry that registers the
  workload CAPI `Cluster` (`cluster.x-k8s.io/v1beta2`, identifier
  `WorkloadCluster`) and `index ((getResource "WorkloadCluster").metadata.annotations | default dict) "chihiro.io/groups"` —
  `.Cluster.metadata.*` only reliably exposes name/namespace/kind in Sveltos
  templates, so arbitrary annotations must be read off an explicitly-registered
  resource (same pattern as the `capi-management` CAPO-version override).
  Registering the Cluster via `templateResourceRefs` also makes Sveltos
  re-template (and re-push the bindings) when the annotation is edited on an
  existing cluster. **Opt-in**: the `clusterSelector` is `matchLabels:
sveltos.argus.rpcu.io/oidc-rbac: enabled` — a cluster only receives the bindings
  if its CAPI `Cluster` CR (or `SveltosCluster`) carries that label, so
  cluster-admin RBAC is never blanket-deployed (the mgmt cluster, even if it had
  the label, keeps its own local bindings in
  `clusters/mgmt/apps/kubernetes-rbac/`). The bare group names match the shared
  Zitadel `groupsClaim` Action output and the ClusterClass empty
  `--oidc-groups-prefix`. The addon-controller RBAC
  (`infrastructure/sveltos/rbac.yaml`) already grants `cluster.x-k8s.io/clusters`
  `get/list/watch` for the `WorkloadCluster` ref. `clusterprofiles/kustomization.yaml`
  lists it (add future ClusterProfiles here).
- `clusterprofiles/cilium.yaml` - **CNI bootstrap for workload clusters**.
  A Sveltos `ClusterProfile` (`syncMode: ContinuousWithDriftDetection`) that
  deploys Cilium v1.18.6 via `helmCharts` (same chart as
  `infrastructure/cilium/helmrelease.yaml`). The cluster-specific values
  (`k8sServiceHost`/`k8sServicePort`, the IPAM `clusterPoolIPv4PodCIDRList`, and
  `clusterDomain`) are expressed **inline** as a templated `helmCharts[].values`
  block, which Sveltos instantiates from the matching `Cluster` resource in the
  management cluster (`.Cluster.spec.controlPlaneEndpoint.host/port`,
  `.Cluster.spec.clusterNetwork.pods.cidrBlocks[0]`, `.Cluster.metadata.name`).
  These values are REQUIRED — a kube-proxy-free workload cluster has no
  CNI/DNS yet, so Cilium must be told the apiserver host/port directly or the
  bootstrap chart fails to come up. **Opt-in**: `clusterSelector:
matchLabels: {type: workload, sveltos.argus.rpcu.io/cilium: enabled}`. This is a
  bootstrap only — once Cilium is running and pods can schedule, the
  `cilium-values` ClusterProfile pushes the Flux `cilium` Kustomization CR which
  takes over reconciling Cilium from `infrastructure/cilium`. No version sync
  needed: Flux overwrites with the repo version.
- `clusterprofiles/cilium-values.yaml` - **Flux takeover path for Cilium on
  OPT-IN workload clusters** (the per-cluster modularity gate). A Sveltos
  `ClusterProfile` (`syncMode: ContinuousWithDriftDetection`, `clusterSelector:
matchLabels: {type: workload, sveltos.argus.rpcu.io/cilium: enabled}`) that pushes
  **two** `policyRefs` ConfigMaps to each matching cluster: (1) a templated
  `cilium-workload-values` ConfigMap with per-cluster values pulled from the
  SveltosCluster resource (pod CIDR `spec.clusterNetwork.pods.cidrBlocks[0]`, API
  server endpoint `spec.controlPlaneEndpoint.host/port`, domain
  `<cluster-name>.local`); and (2) a `cilium-flux-kustomization` ConfigMap holding
  the Flux `cilium` Kustomization CR (path `infrastructure/cilium`, patched to
  source the values ConfigMap). This is **deliberately NOT in a shared Flux sync
  path** — keeping the Flux Kustomization CR in this opt-in ClusterProfile means
  Flux-managed Cilium only lands on clusters carrying the cilium label, instead of
  every Flux-bootstrapped cluster. (The bootstrap `cilium` ClusterProfile above
  does NOT consume the values ConfigMap — it carries its own inline templated
  values; this profile is the post-bootstrap Flux takeover.) **The Flux `cilium`
  Kustomization CR also DISABLES Cilium's L2-announcement LoadBalancer on workload
  clusters** (same as `clusters/mgmt/cilium.yaml` does on mgmt): the HelmRelease
  patch sets `l2announcements.enabled: false` and two `$patch: delete` patches
  remove the base `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy` CRs.
  Without this, every workload cluster inherits the base pool `10.0.0.240-253` and
  Cilium's L2 announcer RACES the OpenStack CCM for `type: LoadBalancer` Services —
  a Service then gets a `10.0.0.x` Cilium IP instead of an OpenStack floating IP
  (`172.16.255.x`). LoadBalancer on workload clusters is owned by the OpenStack CCM
  via Octavia (the opt-in `openstack-ccm` ClusterProfile), not Cilium.
- `clusterprofiles/flux.yaml` - **Flux bootstrap for workload clusters**, split
  into TWO `ClusterProfile`s (both `clusterSelector: matchLabels: type: workload`)
  because a ClusterProfile has a single `syncMode` and the two pieces want
  different semantics:
  - `flux` (**`syncMode: OneTime`**, **`dependsOn: [cilium]`**) — deploys the
    Flux Operator v0.40.0 via `helmCharts` (OCI chart
    `oci://ghcr.io/controlplaneio-fluxcd/charts`, chart `flux-operator`;
    `installCRDs: true` installs the `FluxInstance` CRD, default
    `rbac.create: true` grants the operator cluster-admin to deploy the Flux
    controllers). A one-time bootstrap; the operator thereafter self-updates via
    the FluxInstance's sync to `./infrastructure/fluxcd/operator`. **`dependsOn:
cilium`** so the CNI is fully installed before Flux — Flux's pods (and the
    controllers it deploys) can't schedule without a CNI. This makes the whole
    workload-cluster spine linear: **`cilium` → `flux` → `flux-instance` → (all
    other add-ons, which `dependsOn: flux-instance`)**. A cluster that opts OUT
    of the Sveltos-managed Cilium (`sveltos.argus.rpcu.io/cilium != enabled`,
    e.g. bring-your-own-CNI) is not matched by the `cilium` profile, so Sveltos
    treats the dependency as satisfied and Flux still deploys.
  - `flux-instance` (**`syncMode: ContinuousWithDriftDetection`**, `dependsOn:
[flux]`) — pushes the `flux-sources` ConfigMap (`projectsveltos.io/template:
"true"`) containing the `FluxInstance` CR, kept continuously reconciled so its
    desired state is enforced and drift corrected. `dependsOn: flux` because the
    `FluxInstance` CRD ships with the operator, so the operator must land first.

  The FluxInstance mirrors `infrastructure/fluxcd/instances/flux.yaml` (all four
  components incl. `notification-controller`, the `--concurrent=2` throttle patch, and the **tmpfs
  ephemeral-storage patches** — RAM-backed `emptyDir` `medium: Memory` for
  source-controller `data`/`tmp` and kustomize/helm-controller `temp`, with
  raised memory limits for headroom) with
  `cluster.domain` patched per-cluster to `{{ .Cluster.metadata.name }}.local` and
  a **real `sync` block** pointing at `https://github.com/RPCU/argus.git`
  `refs/heads/main` path **`./infrastructure/fluxcd/operator`** — so **Flux
  self-reconciles its own operator install** directly from the centralized repo
  (the operator's own `kustomization.yaml` is the sync root — no
  `clusters/workload/` directory is needed). Opt-in addons (e.g. Cilium) are NOT
  in this sync path — they are pushed by their own labelled ClusterProfiles, so
  the shared Git path can never force an addon onto every workload cluster.

- `clusterprofiles/capi-management.yaml` - **CAPI/CAPO management cluster
  bootstrap for OPT-IN workload clusters**. A Sveltos `ClusterProfile`
  (`syncMode: ContinuousWithDriftDetection`, `dependsOn: flux-instance`) that
  deploys the full Cluster API + CAPO stack AND Sveltos (with all
  ClusterProfiles) onto a workload cluster so it can become a new management
  cluster. Components are delivered as **Flux Kustomization CRs**
  (GitOps-managed, drift-corrected) — Sveltos pushes the CRs; Flux on the
  target cluster reconciles them from the central repo.

  **What is deployed** (in dependency order via Flux `dependsOn`):
  1. Sveltos core (Flux Kustomization → `infrastructure/sveltos`) — multi-cluster add-on manager, ClusterProfiles stripped via labelSelector `$patch:delete`
  2. Sveltos ClusterProfiles + backing ConfigMaps — pushed as raw manifests
  3. cert-manager (v1.19.2) — TLS certificate management
  4. external-secrets (v2.3.0) — credential syncing
  5. cluster-api-operator (v0.27.0) — declarative CAPI provider lifecycle
  6. ORC (v2.5.0) — OpenStack Resource Controller (CAPO image resolution)
  7. cluster-api-providers — CAPI core + kubeadm bootstrap/control-plane + kamaji control-plane + CAPO
  8. capo-identity — ESO: `capo-variables` (capo-system) → `mgmt-cloud-config`
  9. cluster-api-templates — ClusterClass `openstack-default` + versioned templates
  10. kamaji (Flux Kustomization → `infrastructure/kamaji`) — Kamaji hosted
      control-plane manager + bundled etcd datastore, so the new mgmt cluster can
      provision `openstack-kamaji`-class workload clusters (their apiservers run
      as pods here). Pushed with `wait: false` (its etcd PVCs request the
      `csi-cinder-sc-delete` StorageClass from the separate
      `openstack-integration` profile) and `dependsOn: cluster-api-providers`
      (where the kamaji `ControlPlaneProvider` CR lives). A templated
      `kamaji-workload-values` ConfigMap (`capi-management-kamaji-values`)
      overrides the base's hardcoded `kamaji-etcd.clusterDomain` (`mgmt.local`)
      with `<cluster-name>.local` and is added to the kamaji HelmRelease
      `valuesFrom` via a patch.

  **Sveltos deployment**: Sveltos is deployed via a Flux Kustomization CR
  (not inline `helmCharts`) pointing at `./infrastructure/sveltos` in Git
  (the SAME base the mgmt cluster uses). All clusterprofiles/ resources carry
  a `argus.rpcu.io/sveltos-clusterprofile=true` label; the pushed
  Kustomization uses a single `$patch: delete` targeting that label to strip
  them, yielding a core-only install. A templated `sveltos-core-values`
  ConfigMap provides per-cluster values (`kubernetesClusterDomain:
<cluster-name>.local`, `managementCluster: true`) via a values swap patch.
  The new cluster's own ClusterProfiles are re-pushed as raw manifests by the
  `capi-management-sveltos-profiles` ConfigMap. This is consistent with how
  other profiles (openstack-ccm, cinder-csi, external-snapshotter) push Flux
  Kustomization CRs for GitOps-managed deployment.

  **Credential transfer**: the `capo-variables` secret (OpenStack admin
  `clouds.yaml` in `capo-system`) is read from the **current** management
  cluster via `templateResourceRefs` and pushed to the target cluster. This is
  the same credential source CAPO, the CCM, and the Cinder CSI share. On the
  new management cluster, it must exist in `capo-system` before CAPO can
  provision infrastructure.

  **Opt-in**: `clusterSelector: matchLabels: {type: workload,
sveltos.argus.rpcu.io/capi-management: enabled}`. A cluster only receives the
  CAPI/CAPO stack if it carries this label. Prerequisites: Cilium (CNI) and
  Flux (GitOps) must already be running on the target cluster (delivered by the
  `cilium` and `flux`/`flux-instance` ClusterProfiles).

  **Per-cluster CAPO version override**: the CAPO provider version is normally
  the repo-pinned default in
  `infrastructure/cluster-api-providers/infrastructure-openstack.yaml`. To pin a
  specific CAPO version on an individual target cluster, set the annotation
  `sveltos.argus.rpcu.io/capo-version` (e.g. `v0.14.4`) on that cluster's CAPI
  `Cluster` CR. The `capi-management-flux-kustomizations` ConfigMap is
  Sveltos-templated (`projectsveltos.io/template: "true"`): when the annotation
  is present it emits a `patches` block on the pushed `cluster-api-providers`
  Flux Kustomization that repoints the CAPO `InfrastructureProvider`
  `.spec.version`; when the annotation is absent, empty, or the literal sentinel
  `"default"` no patch is emitted and the default applies unchanged. This is a
  Cluster-CR **annotation** (an arbitrary version string), not an opt-in
  **label** — labels gate which add-ons a cluster receives; the version value is
  carried as an annotation. chihiro surfaces this as the `capoVersion` form
  field (`clusters/mgmt/apps/chihiro/cm.yaml`), an editable `select` whose
  `"default"` option is the no-override sentinel (chihiro always writes the
  annotation, so the sentinel — not an empty/absent annotation — is the normal
  "leave it" value here). The annotation is read via a `templateResourceRefs`
  entry that registers the workload CAPI `Cluster` (identifier `WorkloadCluster`,
  `cluster.x-k8s.io/v1beta2`) and `getResource "WorkloadCluster"` —
  `.Cluster.metadata.*` only reliably exposes name/namespace/kind in Sveltos
  templates, so arbitrary annotations must be read off an explicitly-registered
  resource. Registering the Cluster via `templateResourceRefs` also makes
  Sveltos re-template (and re-push the Flux Kustomization) when the annotation is
  edited on an existing cluster.

  **RBAC**: the addon-controller needs read access to (a) the `capo-variables`
  secret in `capo-system` (granted by the `capi-management-capo-rbac` ConfigMap
  deployed alongside the profile), and (b) the CAPI `clusters`
  (`cluster.x-k8s.io`) on the management cluster for the `WorkloadCluster`
  templateResourceRef — granted by `infrastructure/sveltos/rbac.yaml`
  (`addon-controller-argus-template-reader`).

- `clusterprofiles/vault-auth.yaml` - **Per-child-cluster Vault auth backend +
  ESO ClusterSecretStore** (adapted/improved from the bealv flux-mgmt
  `gitops/apps/sveltos/clusterprofiles/external-secret.yaml`). Lets an OPT-IN
  workload cluster consume secrets from the SHARED mgmt Vault
  (`infrastructure/vault`, reachable at `https://vault.mgmt.rpcu.lan`) via
  External Secrets Operator **without static Vault tokens** — each cluster
  authenticates with its OWN Kubernetes ServiceAccount tokens, validated by a
  per-cluster Vault Kubernetes auth backend. Two halves wired by an
  `EventSource`/`EventTrigger` (the trigger fires once the workload cluster's ESO
  Deployment is up): **(A) on mgmt** Sveltos instantiates Crossplane `provider-vault`
  MRs against the mgmt Vault — a KV-v2 read `Policy` `secrets-<cluster>`, a
  kubernetes-auth `Backend` mounted at `clusters/<cluster>`, an `AuthBackendConfig`
  (the workload cluster's API host + CA, read from the CAPI `<cluster>-ca` secret
  via `templateResourceRefs`), and an `AuthBackendRole` `external-secrets` bound
  to the ESO `vault-auth` SA; **(B) on the workload cluster** it pushes a Flux
  `Kustomization` CR installing the argus ESO base
  (`infrastructure/external-secrets`), a `vault-auth` ServiceAccount + bound token
  - `system:auth-delegator` ClusterRoleBinding (so Vault's cross-cluster
    TokenReview succeeds), the `root-mgmt` CA bundle (pushed as
    `root-mgmt-ca-bundle` so ESO trusts the Gateway-terminated Vault TLS), and a
    `vault-backend` `ClusterSecretStore` pointed at the mgmt Vault over the
    `clusters/<cluster>` auth mount. **Opt-in**: `clusterSelector: matchLabels:
{type: workload, sveltos.argus.rpcu.io/vault-auth: enabled}`; `dependsOn:
flux-instance` (it pushes a Flux Kustomization CR). **Improvements over the
    source**: uses the argus `flux-system` GitRepository + ESO base, the
    kgateway-fronted `https://vault.mgmt.rpcu.lan` URL with the `root-mgmt` CA
    bundle (vs the bealv ingress host / no CA), argus opt-in label gating. (The
    flux-mgmt cert-manager-via-Vault-PKI path — `cert-vault.yaml` — is NOT part
    of THIS add-on; it is re-implemented, improved and subdomain-isolated, as the
    separate `cert-manager` ClusterProfile below.) **Prereqs on
    mgmt** (already present): Crossplane + `provider-vault`
    (`infrastructure/crossplane-vault`) with a working `default` ProviderConfig
    (`clusters/mgmt/crossplane/vault`); the mgmt Vault must have a KV-v2 mount for
    the `secrets-<cluster>` paths (the actual secret data is provisioned out of
    band — this add-on only wires AUTH). The addon-controller RBAC
    (`rbac.yaml`) was widened to `get/list/watch` secrets so its templates can
    read the per-cluster `<cluster>-ca` and `root-mgmt` CA secrets.

- `clusterprofiles/cert-manager.yaml` - **Per-child-cluster cert-manager +
  Vault-PKI ClusterIssuer with SUBDOMAIN ISOLATION** (the re-implemented,
  improved-and-secured version of the bealv flux-mgmt `cert-vault.yaml` that the
  `vault-auth` add-on deliberately left out). Gives each OPT-IN workload cluster
  a `vault-issuer` cert-manager `ClusterIssuer` that mints certs from the SHARED
  mgmt Vault PKI **intermediate** CA (`pki-int`, chained under the cert-manager
  `root-mgmt` root — see `clusters/mgmt/crossplane/vault/pki-int.yaml`), while
  GUARANTEEING a cluster can only issue certs for its OWN subdomain
  `<cluster>.rpcu.lan` and can never usurp another cluster's subdomain.
  **The enforcement boundary is the Vault PKI Role itself**: per cluster Sveltos
  creates (via Crossplane `provider-vault`) a `SecretBackendRole` `cm-<cluster>`
  on `pki-int` with `allowedDomains: ["<cluster>.rpcu.lan"]`,
  `allowSubdomains/allowBareDomains/allowWildcardCertificates: true`, and
  `allowGlobDomains/allowAnyName/allowLocalhost/allowIpSans: false` — Vault
  refuses to sign any CN/SAN outside that domain, so even a fully-compromised
  workload cluster cannot mint `foo.other.rpcu.lan`. This is strictly more secure
  than flux-mgmt's single shared PKI role/AppRole. Topology mirrors `vault-auth`
  (an `EventSource`/`EventTrigger` firing once the workload cluster's
  `cert-manager` controller Deployment is up): **(A) on mgmt** Sveltos
  instantiates Crossplane MRs against the mgmt Vault — the isolated
  `SecretBackendRole cm-<cluster>` (`pki.vault.upbound.io`), a `Policy`
  `pki-cm-<cluster>` granting ONLY `pki-int/issue/cm-<cluster>` +
  `pki-int/sign/cm-<cluster>`, a **separate** kubernetes-auth `Backend` mounted
  at `pki-clusters/<cluster>` (distinct from vault-auth's `clusters/<cluster>` so
  the two add-ons don't collide), an `AuthBackendConfig` (workload cluster API
  host + CA from the CAPI `<cluster>-ca` secret via `templateResourceRefs`), and
  an `AuthBackendRole cert-manager` bound to the workload cluster's cert-manager
  `vault-auth` SA; **(B) on the workload cluster** it pushes a Flux
  `Kustomization` CR installing the argus cert-manager base
  (`infrastructure/cert-manager`), a `vault-auth` ServiceAccount (+ bound token +
  `system:auth-delegator` for cross-cluster TokenReview + a
  `serviceaccounts/token` Role/RoleBinding so cert-manager can TokenRequest the
  SA), the `root-mgmt` CA inlined into the issuer's `caBundle` (so it trusts the
  chain leaf→`pki-int`→`root-mgmt` presented over the kgateway-terminated
  `https://vault.mgmt.rpcu.lan`), and the `vault-issuer` `ClusterIssuer`
  authenticating via the `pki-clusters/<cluster>` Kubernetes auth mount. No
  static Vault tokens / AppRole secret-IDs are distributed (flux-mgmt shipped an
  AppRole secret-id). **Opt-in**: `clusterSelector: matchLabels: {type: workload,
sveltos.argus.rpcu.io/cert-manager: enabled}`; `dependsOn: flux-instance` (it
  pushes a Flux Kustomization CR). **Prereqs on mgmt**: Crossplane +
  `provider-vault` with a working `default` ProviderConfig; the `pki-int`
  intermediate CA must be bootstrapped AND signed by `root-mgmt`
  (`clusters/mgmt/crossplane/vault/pki-int.yaml` + the `infrastructure/vault`
  README manual step) — until then the per-cluster Roles exist but issuance
  fails. The addon-controller RBAC (`rbac.yaml`) was widened with
  `pki.vault.upbound.io/secretbackendroles` (the auth/vault/kubernetes MR groups
  were already granted for vault-auth). Listed in `clusterprofiles/kustomization.yaml`.

- `clusterprofiles/external-dns.yaml` - **Per-child-cluster InternalDNS with
  SUBDOMAIN ISOLATION**. Gives each OPT-IN workload cluster its own InternalDNS
  that syncs `Ingress` / `Gateway HTTPRoute` records into the SHARED OpenStack
  Designate zone (`rpcu.lan`) under its OWN subdomain `<cluster>.rpcu.lan`,
  delivered as a Flux takeover (NO Sveltos helmChart bootstrap — same rationale
  as `openstack-ccm`/`openstack-cinder-csi`: not bootstrap-critical, and a
  helmChart would fight Flux over the same release; Flux is the SOLE owner).
  Three things are pushed: **(1)** the `openstack-credentials` Secret
  (internal-dns ns) — the SHARED admin-project DNS Application Credential
  `clouds.yaml`, rendered by Sveltos from the mgmt
  `crossplane-system/cloud-controller-app-cred-dns` Secret (the connection
  secret of the admin-project app-cred with `dns_manager` role only, created
  by Crossplane in `clusters/mgmt/crossplane/openstack/cloud-controller-dns.yaml`);
  ALL workload clusters share the same app-cred; subdomain isolation is enforced
  by Designate policy (`dns_manager` can only manage recordsets, not zones) and
  the per-cluster `domainFilters` below. The inovex Designate webhook reads it
  at `/etc/openstack/clouds.yaml`. **(2)** the templated
  `internal-dns-workload-values` ConfigMap (internal-dns ns) — overrides the mgmt
  base values with a per-cluster `domainFilters: [<cluster>.rpcu.lan]`, and
  RE-ENABLES the TXT ownership registry (`registry: txt`,
  `txtOwnerId: <cluster>`, `txtPrefix: edns-`) which the mgmt base disables
  (`registry: noop`) — so each cluster only manages its own records and clusters
  never collide in the flat zone. **(3)** the Flux Kustomization CR wrapping
  the SAME base `infrastructure/external-dns` as mgmt (no separate workload
  overlay), patched to append that ConfigMap as a SECOND `valuesFrom` (Helm
  merges valuesFrom in order — later wins) AND to `$patch: delete` the four
  mgmt-only resources from `secret-credentials.yaml` (the ESO
  `SecretStore`/`ExternalSecret` reading `capo-variables` + the `capo-system`
  Role/RoleBinding), which can't reconcile on a workload cluster; the Namespace
  - ServiceAccount are kept. **Opt-in**: `clusterSelector: matchLabels:
{type: workload, sveltos.argus.rpcu.io/external-dns: enabled}`; `dependsOn:
flux-instance` (it pushes a Flux Kustomization CR + HelmRelease reconciled by
    the kustomize/helm controllers, which only exist once Flux is installed). RBAC
    for the `cloud-controller-app-cred-dns` read is already granted by
    `addon-controller-argus-template-reader` (`rbac.yaml`) for the
    `openstack-ccm` profile. Listed in `clusterprofiles/kustomization.yaml`.
    **Prereqs on mgmt**: the `cloud-controller-dns` Crossplane MR
    (`clusters/mgmt/crossplane/openstack/cloud-controller-dns.yaml`) creates the
    admin-project app-cred with `dns_manager` role; the `dns_manager` Keystone
    role + `yaook-sys-maint` assignment in the admin project are colocated in
    the same file. **DNS permission**: workload clusters use a SHARED
    admin-project DNS app-cred with only the `dns_manager` role — all clusters
    share the same app-cred; subdomain isolation is enforced by per-cluster
    `domainFilters` and the Designate `policy:` block
    (`infrastructure/yaook/designate.yaml`) which OR-s `role:dns_manager` into
    the recordset CRUD + zone-read targets.

- `clusterprofiles/ceph-csi-cephfs.yaml` - **Per-child-cluster CephFS CSI driver
  (RWX)**. Gives each OPT-IN workload cluster the upstream Ceph CSI CephFS
  driver, providing **ReadWriteMany (RWX)** volumes backed by the EXISTING
  Rook/Ceph cluster on the bare-metal openstack cluster (`rpcu-fs`
  CephFilesystem). Delivered as a Flux takeover (same pattern as
  openstack-ccm/openstack-cinder-csi/external-dns). Two things are pushed: the
  `ceph-csi-cephfs-cluster-values` ConfigMap (ceph-csi-cephfs ns) containing the
  remote Ceph FSID + monitor endpoints (identical across all workload clusters —
  one openstack Ceph cluster), and the Flux Kustomization CR wrapping
  `./infrastructure/ceph-csi-cephfs` patched to append that ConfigMap as a second
  `valuesFrom`. The ExternalSecret for `csi-cephfs-secret` (adminID/adminKey) is
  in the base and reads from the workload cluster's Vault mount
  (`secrets-<cluster>/ceph-csi`) via the `vault-backend` ClusterSecretStore.
  **Opt-in**: `clusterSelector: matchLabels: {type: workload,
sveltos.argus.rpcu.io/ceph-csi-cephfs: enabled}`; `dependsOn: [flux-instance,
vault-auth]` (pushes a Flux Kustomization CR + needs the vault-backend store
  - per-cluster Vault mount). The CephFS client key must be seeded in Vault per
    cluster out of band (see `infrastructure/ceph-csi-cephfs/README.md`). Listed
    in `clusterprofiles/kustomization.yaml`.

- `clusterprofiles/gateway-api-crds.yaml` - **Gateway API CRDs on ALL workload
  clusters**. Installs the upstream Gateway API experimental CRDs
  (`./infrastructure/gateway-api`) on every cluster with label `type: workload`
  (no opt-in required). Provides the CRDs that cert-manager's gateway-shim
  controller needs to reconcile Certificate resources for Gateway HTTPRoutes.
  Does NOT install kgateway or any Gateway resources — those remain opt-in via
  the `gateway-api` ClusterProfile. Depends on `flux-instance`. Listed in
  `clusterprofiles/kustomization.yaml`.

- `clusterprofiles/gateway-api.yaml` - **Per-child-cluster kgateway
  add-on**. Gives each OPT-IN workload cluster the kgateway CRDs, controller,
  and a workload-cluster Gateway for TLS-terminated HTTP/HTTPS ingress. The
  Gateway API CRDs are NOT deployed here — they are installed on ALL workload
  clusters by the `gateway-api-crds` ClusterProfile. Delivered as a Flux takeover
  (same pattern as openstack-ccm/openstack-cinder-csi/external-dns). Two Flux
  Kustomization CRs are pushed: **(1)** `kgateway-crds` — kgateway CRDs
  (`./infrastructure/kgateway/crds`, dependsOn gateway-api); **(2)** `kgateway` —
  kgateway controller (`./infrastructure/kgateway`, dependsOn kgateway-crds),
  patched to replace the base's resources list with only `helmrelease.yaml` (strips
  the openstack-specific `gateway.yaml` and `httplistenerpolicy.yaml` from the
  kustomize build). Additionally, a templated ConfigMap pushes the **Gateway**
  (hostname `*.cluster.rpcu.lan`, annotated `cert-manager.io/cluster-issuer:
vault-issuer`), **GatewayParameters** (LoadBalancer via OpenStack CCM, no Cilium
  lbipam annotation), **HTTPRoute** (HTTPS redirect), a manually-created
  **Certificate** (`wildcard-tls` in kgateway-system, SAN `*.cluster.rpcu.lan`,
  signed by `vault-issuer`), and **HTTPListenerPolicy** (WebSocket upgrades +
  access logs) directly to the workload cluster. Sveltos resolves
  `{{ .Cluster.metadata.name }}` in the hostname/Certificate SAN before pushing.
  The Certificate is signed by the per-cluster Vault PKI intermediate
  (`pki-int/sign/cm-<cluster>`); the per-cluster PKI role allows wildcard
  certificates and subdomains of `<cluster>.rpcu.lan`, so `*.<cluster>.rpcu.lan` is
  accepted. HTTPRoutes attached to this Gateway are synced to Designate by the
  external-dns add-on (`domainFilters` scoped to `<cluster>.rpcu.lan`). **Opt-in**:
  `clusterSelector: matchLabels: {type: workload,
sveltos.argus.rpcu.io/gateway-api: enabled}`. Split into TWO ClusterProfiles:
  `gateway-api` (`dependsOn: gateway-api-crds`) pushes only the Flux Kustomization CRs
  (kgateway CRDs + controller); `gateway-api-resources` (`dependsOn: gateway-api`) pushes
  the Gateway/GatewayParameters/Certificate/HTTPRoute/HTTPListenerPolicy CRs. The
  split orders the CRs AFTER the CRDs — deploying them together fails with
  `no matches for kind "GatewayParameters"` because the kgateway CRDs (installed
  by the Flux Kustomization's HelmRelease) aren't registered yet. With
  `ContinuousWithDriftDetection`, Sveltos retries until the CRDs land. Listed
  in `clusterprofiles/kustomization.yaml`.

- `kustomization.yaml` - Kustomization manifest (namespace, helmrepo, core
  helmrelease, rbac, clusterprofiles/). All clusterprofiles/ resources carry
  the `argus.rpcu.io/sveltos-clusterprofile=true` label; the `capi-management`
  ClusterProfile reuses this same base with a single `$patch: delete` targeting
  that label to strip clusterprofiles for new management clusters.

> Deployed by `clusters/mgmt/sveltos.yaml` (no `dependsOn` required; basic
> Sveltos core install). The `oidc-rbac` ClusterProfile only takes effect on a
> child cluster once that cluster is Sveltos-registered, **carries the opt-in
> label `sveltos.argus.rpcu.io/oidc-rbac: enabled`**, AND its kube-apiserver
> OIDC is enabled (the `oidc` ClusterClass variable); it is harmless before then
> (the groups simply never appear in any token). Both `kube-admin` and
> `kube-user` map to `cluster-admin` on the labelled child clusters.

**cluster-api-operator/** - Cluster API Operator (v0.27.0)

Declarative lifecycle manager for Cluster API providers (GitOps-friendly,
compatible with `clusterctl move`). Requires cert-manager.

- `namespace.yaml` - Kubernetes namespace (capi-operator-system)
- `helmrepo.yaml` - Helm repository (kubernetes-sigs.github.io/cluster-api-operator)
- `helmrelease.yaml` - Cluster API Operator Helm chart (v0.27.0)
- `values.yaml` - Custom values (chart-managed cert-manager disabled; providers managed separately)
- `kustomization.yaml` - Kustomization manifest

**cluster-api-providers/** - Cluster API Providers (declarative CRs)

Provider CRs reconciled by the Cluster API Operator. Versions pinned to match
the manually bootstrapped kind management cluster. The `clusterctl.cluster.x-k8s.io/v1alpha3`
Provider inventory CRs are intentionally EXCLUDED — the CRD is not installed
by the Cluster API Operator; applying them on a fresh cluster fails. They
live in a separate `cluster-api-providers-clusterctl/` kustomization.

- `namespaces.yaml` - Namespaces (capi-system, capi-kubeadm-bootstrap-system, capi-kubeadm-control-plane-system, capo-system)
- `core.yaml` - CoreProvider cluster-api (v1.13.2) — operator.cluster.x-k8s.io/v1alpha2
- `bootstrap-kubeadm.yaml` - BootstrapProvider kubeadm (v1.13.2) — operator.cluster.x-k8s.io/v1alpha2
- `control-plane-kubeadm.yaml` - ControlPlaneProvider kubeadm (v1.13.2) — operator.cluster.x-k8s.io/v1alpha2
- `infrastructure-openstack.yaml` - InfrastructureProvider openstack / CAPO (v0.14.4), configSecret capo-variables — operator.cluster.x-k8s.io/v1alpha2
- `control-plane-kamaji.yaml` - ControlPlaneProvider kamaji (v0.20.0) — operator.cluster.x-k8s.io/v1alpha2
- `README.md` - How to create the `capo-variables` (clouds.yaml) secret manually on the mgmt cluster
- `kustomization.yaml` - Kustomization manifest (multi-namespace, no top-level namespace)

> The CAPO `capo-variables` secret is now created **manually** on the mgmt
> cluster (see `cluster-api-providers/README.md`). The previous External
> Secrets approach (`secretstore.yaml`, `secretstore-rbac.yaml`,
> `externalsecret-capo.yaml`) was removed because the mgmt cluster has no local
> `yaook` namespace to read `keystone-admin` from.
>
> ORC (openstack-resource-controller) is a **hard dependency of CAPO v0.14.x**
> (OpenStackMachine images resolve through ORC `Image` resources), but it is
> **not** a Cluster API provider and is **not** managed in this kustomization.
> On the mgmt cluster it is installed as a plain Flux Kustomization
> (`clusters/mgmt/orc.yaml` → `infrastructure/orc/`) using ORC's upstream
> `install.yaml` pinned at v2.5.0. Do **not** add it as an
> `InfrastructureProvider` CR — the Cluster API Operator has no fetch source
> for it and would fight the standalone install.

**orc/** - OpenStack Resource Controller (v2.5.0)

Standalone ORC deployment, fetched from upstream via URL. CAPO v0.14.x depends on
ORC for image resolution (OpenStackMachine images are resolved through ORC
`Image` resources). ORC is NOT a Cluster API provider — it does not implement
the CAPI infrastructure contract and is not managed by the Cluster API Operator.

- `kustomization.yaml` - Kustomization manifest pointing at the pinned upstream release URL (v2.5.0)

**cluster-api-templates/** - Cluster API ClusterClass & Templates

Generic, reusable OpenStack ClusterClass. Restructured so the base templates are
split per-component and carry a `-v1` version suffix; everything cluster-specific
is a ClusterClass variable injected via patches, so creating a new cluster is a
small `Cluster` CR (no template forking). See `README.md` for the variable table
and the `-vN` immutability/rotation workflow.

- `clusterclass.yaml` - ClusterClass `openstack-default` (renamed from `openstack-mgmt`) with variables: identityRef, externalNetworkId, managedSubnetCIDR, managedSubnetAllocationPools, imageName, controlPlaneFlavor, workerFlavor, sshKeyName, apiServerFloatingIP, **oidc**. Template refs use the versioned `openstack-default-*-v1` names, except `infrastructure.templateRef` which now points at `openstack-default-cluster-v3` (no redundant Cilium rules). The **`oidc`** object variable (`enabled`/`issuerURL`/`clientID`/`usernameClaim`/`usernamePrefix`/`groupsClaim`/`groupsPrefix`) is an `enabledIf` patch that appends the `--oidc-*` kube-apiserver `extraArgs` (issuer-url, client-id, username-claim, username-prefix, groups-claim, groups-prefix) onto the control-plane `KubeadmControlPlaneTemplate`. It targets the shared Zitadel **`kubernetes`** OIDC client (a public/native PKCE app with **no client secret** — see `clusters/openstack/crossplane/zitadel/oidc-apps.yaml`); the apiserver only validates ID tokens so no secret is plumbed to mgmt. The Zitadel-generated `clientID` must be copied by hand into the `Cluster` CR's `oidc.clientID` and `enabled` flipped to true (don't enable with an empty clientID; enabling rolls the control-plane machines). **Group mapping**: the shared Zitadel `groupsClaim` Action (`clusters/openstack/crossplane/zitadel/actions.yaml`) injects each user's granted project role keys into the token's `groups` claim as **bare names** (`kube-admin`/`kube-user`, no prefix), so the ClusterClass defaults `usernamePrefix`/`groupsPrefix` to **empty**. The RBAC bindings for those bare groups live at `clusters/mgmt/apps/kubernetes-rbac/` (`kube-admin` → `cluster-admin`, `kube-user` → `view`), mirroring the bealv reference (`gitops/apps/kubernetes/crb.yaml`). A non-empty `groupsPrefix` would require renaming the binding subjects to `<prefix>kube-admin`.
- `clusterclass-v1.yaml` - ClusterClass `openstack-default-v1` — legacy class for clusters originally created from `openstack-default-cluster-v2` (which includes the remoteManagedGroups Cilium rules). CAPO's admission webhook makes `OpenStackCluster.spec` immutable after creation, so changing the `infrastructure.templateRef` on a live cluster creates an unreconcilable topology diff (the CAPI topology controller tries to remove the rules, CAPO blocks the spec modification). This class preserves the `-v2` templateRef for existing clusters (e.g. `mgmt`). New clusters should use `openstack-default` (which points at `-v3` and avoids the `409 SecurityGroupRuleExists`). Identical to `openstack-default` in variables/patches; only the `infrastructure.templateRef` differs.
- `templates/controlplane.yaml` - KubeadmControlPlaneTemplate `openstack-default-control-plane-v1`
- `templates/controlplane-v2.yaml` - KubeadmControlPlaneTemplate `openstack-default-control-plane-v2`. Adds kubelet `--kube-reserved`/`--system-reserved`/`--eviction-hard`/`--eviction-soft`/image-GC flags on both init and join, plus kube-controller-manager `node-monitor-grace-period=40s`/`node-monitor-period=5s`. See the "Node resilience" note in Section 8. Superseded as the ClusterClass `controlPlane.templateRef` by `-v3`.
- `templates/controlplane-v3.yaml` - KubeadmControlPlaneTemplate `openstack-default-control-plane-v3`. Identical to `-v2` plus `clusterConfiguration.encryptionAlgorithm: ECDSA-P256` — kubeadm generates ECDSA P-256 control-plane keys/certs instead of the RSA-2048 default. At low request volume the dominant kube-apiserver CPU cost is the per-connection TLS handshake (asymmetric crypto); an ECDSA-P256 handshake is ~5-10x cheaper server-side than RSA-2048. **Only takes effect on certs generated at `kubeadm init`/cert renewal** — i.e. when control-plane machines roll (which the `-v3` templateRef bump triggers); a running control plane keeps its RSA certs until replaced. The Kamaji ClusterClass is deliberately NOT changed (KamajiControlPlaneTemplate manages its tenant cert keys itself, no kubeadm `encryptionAlgorithm` knob, and Kamaji tenant apiservers are not CPU-stressed). See the "kube-apiserver CPU is TLS-handshake bound" note in Section 8.
- `templates/controlplane-v4.yaml` - KubeadmControlPlaneTemplate `openstack-default-control-plane-v4` (broken — superseded). Added `--watch-cache-sizes` targeting CRDs, which crashed the apiserver (flag only affects built-in resources). Superseded by `-v5`.
- `templates/controlplane-v5.yaml` - KubeadmControlPlaneTemplate `openstack-default-control-plane-v5` — **CURRENT**. Identical to `-v3` minus the broken `--watch-cache-sizes` flag from `-v4`.
- `templates/controlplane-v6.yaml` - KubeadmControlPlaneTemplate `openstack-default-control-plane-v6` — **prepared but NOT referenced** by the ClusterClass. Adds apiserver memory-tuning flags on top of `-v5`: `--event-ttl=30m`, `--max-requests-inflight=200`, `--max-mutating-requests-inflight=100`, `--profiling=false`. Bump the ClusterClass to activate (triggers a control-plane roll).
- `templates/bootstrap.yaml` - KubeadmConfigTemplate `openstack-default-worker-v1`
- `templates/bootstrap-v2.yaml` - KubeadmConfigTemplate `openstack-default-worker-v2` (referenced by `openstack-default` and `openstack-kamaji`). Same kubelet reservation/eviction flags as the control-plane `-v2`.
- `templates/infracluster.yaml` - OpenStackClusterTemplate `openstack-default-cluster-v1`, `-v2` **and** `-v3` (ClusterClass points `infrastructure.templateRef` at `-v3`). The `managedSecurityGroups` sets `allowAllInClusterTraffic: true` (opens ALL node-to-node traffic on every port/protocol, which already covers the Cilium overlay) plus **only** rules scoped to `0.0.0.0/0`: SSH ingress, DNS egress, and (since `-v2`) the Kubernetes NodePort range (TCP 30000–32767) — REQUIRED for external `type: LoadBalancer` Services via the OpenStack CCM + Octavia (the Octavia/OVN VIP DNATs to `<node IP>:<nodePort>`; without this rule the managed SG drops it and the LB floating IP times out at the TCP layer despite correct VIP/floating-IP/DNS). **`-v3` REMOVES the explicit `remoteManagedGroups: [controlplane, worker]` Cilium data-plane rules (VXLAN UDP 8472 / health TCP 4240 / Hubble TCP 4244 / ICMP)** that `-v1`/`-v2` carried: because `allowAllInClusterTraffic` already opens all traffic between the managed groups, each of those rules normalizes to a Neutron rule tuple CAPO also creates, so on a fresh cluster the second POST returns `409 SecurityGroupRuleExists` and aborts the whole SG reconcile (wedged new cluster `testb`). They were labelled "redundant but harmless" — they are redundant AND harmful (a duplicate rule is a hard 409, not a no-op). `-v1`/`-v2` are retained only until the rotation to `-v3` is confirmed, then deleted (per the README `-vN` workflow — an `OpenStackClusterTemplate` rotation reconciles the SGs onto the live `OpenStackCluster` without rolling machines). `identityRef` is hardcoded to `mgmt-cloud-config` (CAPO requires it at admission time); the ClusterClass `identityRef` variable/patch overrides this default per-cluster when the topology controller synthesizes the concrete `OpenStackCluster`.
- `templates/machines.yaml` - OpenStackMachineTemplate `openstack-default-control-plane-v1` and `openstack-default-worker-v1` (flavor/image are `dummy` placeholders overwritten by patches)
- `namespace.yaml` - Namespace `mgmt`
- `README.md` - Structure, variable table, credentials/ESO note, new-cluster recipe, immutability/`-vN` rotation workflow, and **"Multiple worker pools with different flavors"** (per-pool `workerFlavor` overrides)

> **Multiple worker pools / per-pool flavors.** Both ClusterClasses
> (`openstack-default` and `openstack-kamaji`) expose a single `default-worker`
> machine-deployment class, and the `workerFlavor` patch targets that class (not
> a specific pool). A `Cluster` CR can therefore instantiate `default-worker`
> any number of times under `spec.topology.workers.machineDeployments[]` and set
> a different flavor per pool via `machineDeployments[].variables.overrides`
> (`name: workerFlavor`, `value: <flavor>`). A pool that omits the override
> inherits the top-level `workerFlavor` (default `xlarge`). No extra worker
> classes or template rotation are needed — this is the idiomatic CAPI
> per-MachineDeployment variable-override mechanism. Other worker-class variables
> (`imageName`, `sshKeyName`) can be overridden the same way; `controlPlaneFlavor`
> and cluster-wide values (e.g. `externalNetworkId`) cannot be per-pool. See the
> README section for a full example. The same comment is inlined above the
> `workerFlavor` patch in both `clusterclass.yaml` and `clusterclass-kamaji.yaml`.

- `kustomization.yaml` - Kustomization manifest (references namespace, clusterclass, clusterclass-v1, clusterclass-kamaji, clusterclass-kamaji-v1, and all four `templates/*` files). The actual `Cluster` CR lives at `clusters/mgmt/clusters/mgmt.yaml` and now references `classRef.name: openstack-default-v1` (and no longer sets an `identityRef` variable).

> The OpenStack credentials secret (`mgmt-cloud-config`) consumed by the hardcoded
> `identityRef` is **not** created here — it lives in `infrastructure/capo-identity/`
> (its own Flux Kustomization), so a credential-plumbing failure cannot abort the
> apply that creates the ClusterClass templates. `cluster-api-templates` now
> `dependsOn: cluster-api-providers` only (the `external-secrets` dependency moved
> to `capo-identity`). It was previously fixed from a self-dependency.

**capo-identity/** - OpenStack credentials sync for the mgmt CAPI cluster

ESO plumbing that projects the manually-placed `capo-variables` (capo-system)
`clouds.yaml` into the `mgmt` namespace as `mgmt-cloud-config`, the secret the
`openstack-default` ClusterClass references via its hardcoded `identityRef`.
Split out of `cluster-api-templates` so an ESO failure (admission, missing
`capo-variables`, backend not ready) can't break the ClusterClass apply.

- `namespace.yaml` - Namespace `mgmt`
- `secretstore.yaml` - ServiceAccount `capo-identity-reader` (mgmt) + Role/RoleBinding `capo-variables-reader` (capo-system, scoped to the `capo-variables` secret) + ESO `SecretStore` `capo-system-secrets` (mgmt, Kubernetes provider, `remoteNamespace: capo-system`). Note: `caProvider.namespace` must be empty on a namespaced SecretStore (admission rejects it) — `kube-root-ca.crt` is read from the store's own namespace.
- `externalsecret.yaml` - ESO `ExternalSecret` syncing `capo-variables` `clouds.yaml` (capo-system) → secret `mgmt-cloud-config` (mgmt).
- `README.md` - Rationale (blast-radius isolation), contents, Flux wiring, caveats.
- `kustomization.yaml` - Kustomization manifest.

> Deployed by `clusters/mgmt/capo-identity.yaml` with `dependsOn: external-secrets`
>
> - `cluster-api-providers` and `wait: false` (the ExternalSecret cannot be Ready
>   until the manual `capo-variables` secret exists; we don't block on it).

> The Flux Kustomization `clusters/mgmt/cluster-api-templates.yaml` previously had a
> self-dependency (`dependsOn: cluster-api-templates`); this was fixed to
> `dependsOn: cluster-api-providers` so the ClusterClass/templates only reconcile
> after the CAPO/kubeadm provider CRDs exist.

> `clusters/mgmt/cluster-api-templates.yaml` intentionally does **NOT** set
> `wait: true` (it defaults to `false`). With `wait: true`, Flux health-gates
> every object in the Kustomization via kstatus — including the `ClusterClass`.
> The `ClusterClass` and its `OpenStackClusterTemplate`s live in the **same**
> Kustomization with no apply-ordering guarantee, so during a `-vN` template
> rotation (repointing `infrastructure.templateRef` to a new template) the health
> wait can trip while the `ClusterClass` momentarily reports `InProgress` — and if
> the new template object isn't reconciled yet, the topology controller wedges
> (`TopologyReconciled=False`, `ClusterClass.status.observedGeneration` stuck one
> behind) and the Kustomization never recovers. Without `wait`, Flux applies the
> template and the ClusterClass together and returns; CAPI converges the topology
> asynchronously. (If a future change needs strict ordering, the durable fix is to
> split the templates and the ClusterClass into two Kustomizations with
> `dependsOn`, like `kgateway-crds` → `kgateway`.)

**yaook-operator/** - Yaook OpenStack Operators (v2.4.0)

- `namespace.yaml` - Kubernetes namespace (yaook)
- `helmrepo.yaml` - Repository reference (charts.yaook.cloud)
- `helmrelease-crds.yaml` - Yaook CRDs Helm chart
- `helmrelease-infra-operator.yaml` - Infrastructure operator
- `helmrelease-keystone-operator.yaml` - Keystone operator
- `helmrelease-keystone-resources-operator.yaml` - Keystone resources operator
- `helmrelease-glance-operator.yaml` - Glance operator
- `helmrelease-nova-operator.yaml` - Nova operator
- `helmrelease-nova-compute-operator.yaml` - Nova compute operator
- `helmrelease-neutron-operator.yaml` - Neutron operator
- `helmrelease-neutron-ovn-operator.yaml` - Neutron OVN operator
- `helmrelease-horizon-operator.yaml` - Horizon operator
- `helmrelease-octavia-operator.yaml` - Octavia operator
- `helmrelease-designate-operator.yaml` - Designate operator
- `helmrelease-cds-operator.yaml` - CDS operator
- `helmrelease-barbican-operator.yaml` - Barbican operator (v2.2.0, key manager)
- `secretstore.yaml` - SecretStore for Kubernetes secrets provider
- `secretstore-rbac.yaml` - ServiceAccount for SecretStore
- `secretstore-cluster-rbac.yaml` - ClusterRole permissions for SecretStore to read across namespaces
- `secretstore-rook.yaml` - SecretStore for reading secrets from rook-ceph namespace
- `externalsecret-crossplane-openstack.yaml` - ExternalSecret transforming keystone-admin to Crossplane format
- `externalsecret-rook-ceph.yaml` - ExternalSecrets syncing cinder and glance credentials from rook-ceph
- `gateway/` - Gateway API resources for Yaook services
  - `httproute-*.yaml` - HTTPRoutes + BackendTLSPolicies for all OpenStack services (TLS termination at gateway, re-encryption to backends using RPCU bundle CA)
  - `kustomization.yaml` - Kustomization manifest
- `kustomization.yaml` - Kustomization manifest

**yaook/** - Yaook OpenStack Service Deployments (CRs)

Actual OpenStack service deployment CRs (`*Deployment` of `yaook.cloud/v1`),
reconciled by the operators above. Deployed by the `yaook` Flux Kustomization
(dependsOn yaook-operator + external-secrets).

- `keystone.yaml` - KeystoneDeployment (identity).
  Database (`database`): `resources` on `mariadb-galera` (200m CPU / 512Mi req /
  2Gi limit) and every proxy sidecar (`haproxy`, `service-reload`,
  `create-ca-bundle`). Same BestEffort-starvation fix as all other databases —
  see "All yaook database pods must not be BestEffort" in Section 8.
- `glance.yaml` - GlanceDeployment (images). `show_image_direct_url: true`
  exposes the RBD location of images so cinder/nova create volumes as instant
  Ceph copy-on-write clones instead of streaming a full copy through the
  glance API (images must be **raw** format for COW cloning; safe because
  glance/cinder share one Ceph cluster).
  Database (`database`): `resources` on `mariadb-galera` and every proxy
  sidecar — same fix as all other databases.
- `neutron.yaml` - NeutronDeployment (networking). The `setup.ovn` block sets
  **`resources` on every OVN component** (`northboundOVSDB.ovsdb`/`ssl-terminator`,
  `southboundOVSDB.ovsdb`/`ssl-terminator`, `southboundOVSDB.ovnRelay.ovn-relay`/
  `ssl-terminator`, `northd.northd`, and the per-node `controller.*` agents).
  They previously had `resources: {}` → QoS **BestEffort** → cgroup v2
  `cpu.weight` of 1, so they lost every scheduling contest against the Ceph OSDs
  (2 CPU / 5Gi requests) and the tenant qemu processes on these hyperconverged
  nodes. See "OVN control plane must not be BestEffort" in Section 8 for the
  2026-07-26 outage this caused. **No CPU limits** anywhere (throttling a
  single-threaded raft/dataplane process destroys tail latency — same rationale
  as the Ceph daemons), and **no memory limit on `ovs-vswitchd`** (an OOM-kill
  there severs the whole node's dataplane). NOTE the CRD exposes **no
  `priorityClassName`/scheduling knob** for these components, so unlike the Ceph
  mons/mgr/osd they cannot be marked `system-cluster-critical` declaratively —
  that half of the fix needs an upstream yaook change.
- `nova.yaml` - NovaDeployment (compute). libvirt I/O tuning for RBD-backed
  disks: `disk_cachemodes: [network=writeback]` (librbd writeback cache —
  flushed on guest fsync, large guest write-latency win) and
  `hw_disk_discard: unmap` (guest TRIM reclaims space in the Ceph pool).
  **`disk_cachemodes` MUST be a LIST** (`[network=writeback]`), not a bare
  string. The yaook operator 2.4.0 CUE schema
  (`nova_template/openstack_default_nova.cue`: `"disk_cachemodes"?: [...string]`)
  rejects a scalar string with `conflicting values "network=writeback" and
[...string]` → the generated `NovaComputeNode` goes `ConfigurationInvalid`.
  A scalar here is worse than a plain config error: because it makes the
  rendered compute config "not up-to-date", the nova-operator flags every node
  `RequiresRecreation=True` and starts a **rolling recreate** (maxUnavailable=1)
  that DELETEs each `NovaComputeNode` and evicts (live-migrates) its VMs before
  recreating it. If live-migration cannot converge on this cluster, each node
  wedges mid-eviction (`state: Evicting`, `phase: WaitingForDependency`) with
  its compute service left `disabled` — cascading across lucy/makise/quinn one
  at a time. (Pre-2.4.0 the scalar was tolerated; the upgrade tightened it.)
  `live_migration_permit_auto_converge: true` enables libvirt auto-converge:
  when the VM's dirty page rate exceeds network bandwidth during live migration,
  libvirt automatically throttles vCPU to force convergence. Without this, busy
  VMs with high memory write rates (e.g. production workers) can oscillate
  forever in the pre-copy convergence loop and never complete migration.
  `resume_guests_state_on_host_boot: true` makes nova-compute restart, on
  service init, every instance whose Nova DB `vm_state` is ACTIVE but whose
  libvirt domain is not running — i.e. VMs come back automatically after a
  hypervisor reboot. Without it a node reboot leaves its VMs SHUTOFF until
  someone manually `openstack server start`s them, which for the
  CAPO-provisioned mgmt/workload clusters means those Kubernetes nodes never
  return. Only instances Nova believes should be ACTIVE are resumed — a VM
  stopped through the Nova API has `vm_state=stopped` and stays down — so it
  does not fight deliberate shutdowns. It triggers on nova-compute service
  init, not strictly on host boot, so it also applies when the pod restarts.
  Database (`database`): `resources` on all four Galera instances (`api`,
  `cell0`, `cell1`, `placement`) and every proxy sidecar — same
  BestEffort-starvation fix as all other databases. Nova has four separate
  databases (one per cell + api + placement); each must carry resources.
- `cinder.yaml` - CinderDeployment (block storage, rook-ceph RBD backend).
  Database (`database`): `resources` on `mariadb-galera` (200m CPU / 512Mi req /
  2Gi limit) and every proxy sidecar (`haproxy`, `service-reload`,
  `create-ca-bundle`). Same BestEffort-starvation fix as all other databases —
  see "All yaook database pods must not be BestEffort" in Section 8.
- `horizon.yaml` - HorizonDeployment (dashboard)
- `octavia.yaml` - OctaviaDeployment (load balancing).
  Database (`database`): `resources` on `mariadb-galera` and every proxy
  sidecar — same fix as cinder/keystone/etc.
- `designate.yaml` - DesignateDeployment (DNS). The `policy:` map, besides
  `admin: role:admin`, OR-s a narrow custom `role:dns_manager` into the recordset
  CRUD + zone/recordset READ targets (`get_zones`/`find_zones`/`get_zone`/
  `get_recordsets`/`find_recordsets`/`get_recordset`/`create_recordset`/
  `update_recordset`/`delete_recordset`), regardless of zone ownership (write
  rules keep the `('PRIMARY':%(zone_type)s)` guard). This lets workload-cluster
  ExternalDNS manage recordsets in the SHARED admin-owned `rpcu.lan` zone using a
  shared admin-project `cloud-controller-dns` app-cred that carries `dns_manager`
  — WITHOUT granting admin to tenant credentials. Zone create/update/delete are
  NOT granted to `dns_manager` (ExternalDNS manages recordsets only; the zone is
  pre-created by admin). The `dns_manager` role + admin-project assignment live
  in `clusters/mgmt/crossplane/openstack/cloud-controller-dns.yaml`; Designate
  policy OR-in: `infrastructure/yaook/designate.yaml` `policy:` block.
  The `powerdns.database` block sets **`resources`** on the Galera pod
  (`mariadb-galera` + backup/exporter sidecars) and on
  `powerdns.database.proxy` (`haproxy`, `service-reload`, `create-ca-bundle`).
  They were all `resources: {}` → QoS **BestEffort**, so on a 91%-CPU node the
  DB was starved until its `ssl-terminator` failed readiness, restarting the pod
  18 times in 47h; PowerDNS then answered **SERVFAIL** for every query and
  `rpcu.lan` resolution died cluster-wide. Same class of bug as the OVN one —
  see "PowerDNS/Galera must not be BestEffort" in Section 8. NOTE the CRD
  exposes no `resources` for the PowerDNS **server** pod itself, nor for the
  Galera pod's `ssl-terminator` sidecar (the container that actually failed), so
  those stay BestEffort pending an upstream yaook change.
- `barbican.yaml` - BarbicanDeployment (key manager, simple_crypto plugin, KEK auto-generated)
- `ca-cert.yaml` - CA certificate resources
- `disruptionbudget.yaml` - `YaookDisruptionBudget` `nova-compute` (match-all
  `nodeSelectors`, `maxUnavailable: 1`, **`disruptiveMaintenance: true`**,
  **`preventDeletion: false`**). The compute rollout's disruption policy: any
  edit to `novaComputeConfig` makes the nova operator delete each
  `NovaComputeNode` in turn (one at a time — `maxUnavailable: 1`) to apply the
  new config, which drains the node by migrating its VMs off.
  `disruptiveMaintenance: true` means ACTIVE instances are **COLD** migrated
  (not live); `preventDeletion: false` means the operator **auto-evicts** on a
  config change rather than merely flagging the node. Cold migration copies the
  local qcow2 root disk over the `nova` ssh account, which has an image bug
  (missing `IdentityFile`) worked around by `nova-compute-ssh-fix.yaml` below —
  apply that (and verify `remote_filesystem_transport = rsync`) BEFORE relying
  on an eviction, or the drain wedges (see "Nova cold-migration / node eviction
  fails" in Section 8). `spareNodes` is unset (no spare host aggregate exists).
  NOTE: this supersedes the out-of-band `compute-cold-migrate` budget that used
  to carry these same settings (deleted from the live cluster — a node may match
  at most one budget or the operator raises `ConfigurationInvalid`).
- `nova-compute-ssh-fix.yaml` - **Tactical workaround** for the nova
  cold-migration ssh bug (ServiceAccount + Role/RoleBinding + CronJob, ns
  yaook). The yaook `nova-compute-*-ubuntu` image ships an `/etc/ssh/ssh_config`
  with no `IdentityFile` and gives the `nova` user passwd home `/var/empty`, so
  ssh can't find the key `keygen` writes to `/home/nova/.ssh/id_ed25519` →
  cold-migration rsync fails `Permission denied (publickey)` and every eviction
  wedges (Section 8, bug #2). The nova-compute pods are operator-generated
  StatefulSets and the NovaDeployment CRD's `compute` block exposes only
  `configTemplates`/`resources` (no ssh_config/IdentityFile/extraVolumes/
  lifecycle knob — verified against operator 4.1.208), so there is NO
  declarative CR fix; the durable fix is upstream (fix the image). Until then
  this CronJob (every 5 min, `kubectl exec` via a scoped `pods`+`pods/exec`
  Role) idempotently appends the `IdentityFile` line to every nova-compute pod's
  ssh_config, replacing the manual `sed` loop from the runbook. Two non-obvious
  gotchas baked in: it selects the pods by
  `state.yaook.cloud/component=compute,parent-plural=novacomputenodes` (the
  component label value is `compute`, NOT `nova-compute`), and it uses the
  Alpine-based `docker.io/alpine/k8s` image — NOT `registry.k8s.io/kubectl` or
  `rancher/kubectl`, both of which are DISTROLESS (no `/bin/sh`, so the shell
  loop fails `StartError: exec /bin/sh: no such file or directory`). It is **racy**
  (a pod recreated then immediately targeted can migrate before the next tick) —
  for an in-flight eviction, trigger it now:
  `kubectl create job -n yaook --from=cronjob/nova-compute-ssh-fix nova-ssh-fix-now`.
- `secretstore*.yaml` / `externalsecret-*.yaml` - SecretStores + ExternalSecrets (crossplane creds, OIDC, rook-ceph client keys)
- `gateway/` - HTTPRoutes + BackendTLSPolicies per service (includes `httproute-barbican.yaml` → `barbican.rpcu.vpn`, backend `barbican-api:9311`)
- `kustomization.yaml` - Kustomization manifest (namespace: yaook)

**vault/** - HashiCorp Vault (chart v0.30.0)

**HA Vault (3-node integrated Raft storage, no external Consul)** on the **mgmt
cluster**, adapted from the bealv `flux-mgmt` repo (`gitops/apps/vault`). The
source was a single-pod standalone/file-storage install targeting an Ingress
controller (`vault.bealv-mgmt.lan`, cert-manager issuer `bealv-mgmt`); this repo
uses HA Raft and the Gateway API (kgateway) instead, so `server.standalone` is
disabled, `server.ha`/`server.ha.raft` are enabled, the chart's bundled Ingress
is disabled, and external access is provided by a Gateway API `HTTPRoute`.

- `namespace.yaml` - Namespace `vault`
- `helmrepo.yaml` - HelmRepository `hashicorp` (`https://helm.releases.hashicorp.com`)
- `helmrelease.yaml` - Vault Helm chart v0.30.0 (namespace vault).
  `server.standalone.enabled: false`; `server.ha.enabled: true`,
  `server.ha.replicas: 3`, `server.ha.raft.enabled: true` + `setNodeId: true`
  (integrated Raft storage stanza `storage "raft"` at `/vault/data`,
  `service_registration "kubernetes"`). `global.tlsDisable: true` (TLS
  terminated at the Gateway). **readinessProbe ENABLED** (the Service only routes
  to unsealed/active pods); **livenessProbe DISABLED** (a sealed pod — normal
  after any restart before unseal — must not be killed or it crash-loops during
  bootstrap). `server.ingress.enabled: false` (Gateway API is used instead). Each
  replica's `dataStorage` PVC (10Gi, RWO) explicitly requests the `cinder-delete`
  StorageClass — mgmt has no default StorageClass. Injector/CSI disabled. The
  chart's server podAntiAffinity is `required...` on hostname, so the 3 replicas
  need 3 distinct schedulable nodes.
- `httproute.yaml` - Gateway API `HTTPRoute` `vault` at `vault.mgmt.rpcu.lan`,
  parentRef the shared kgateway `https` Gateway (TLS terminated with the
  `rpcu-lan-wildcard-tls` cert / root-mgmt CA), backend the leader-aware `vault`
  service port 8200.
- `README.md` - HA Raft bootstrap (init/unseal `vault-0`, `raft join` + unseal
  `vault-1`/`vault-2`, `raft list-peers`).
- `kustomization.yaml` - Kustomization manifest.

> Deployed by `clusters/mgmt/vault.yaml` with `dependsOn: kgateway` (the
> HTTPRoute's parent Gateway, which consumes the wildcard cert from
> cert-manager-issuer) + `openstack-cinder-csi` (provides the `cinder-delete`
> StorageClass the PVCs request). Every Vault pod starts **sealed** on every
> (re)start and must be unsealed manually (or via an auto-unseal mechanism) — see
> README.

**fluxcd/** - GitOps Operator

_fluxcd/operator/_ - Operator installation

- `kustomization.yaml` - Flux operator (v0.40.0 from GitHub releases)
- `monitoring.yaml` - Headless `Service` (`flux-metrics`, ns `flux-system`) selecting all pods labeled `app.kubernetes.io/part-of: flux` (the standard Flux label), exposing container port 8080 (`metrics`). `ServiceMonitor` (`flux-controllers`, ns `monitoring`) scraping the service every 60s. Without this, zero Flux controller metrics reach Mimir and the FluxCD dashboard/alerts are empty.

_fluxcd/instances/_ - Instance configuration

- `flux.yaml` - FluxInstance CRD (Flux 2.x, kustomize/helm controllers patched to `--concurrent=2` to bound etcd load). **All controllers' ephemeral storage is backed by tmpfs** (RAM-backed `emptyDir` with `medium: Memory`) instead of the node disk to avoid heavy disk I/O from Git clones, artifact unpacking, and kustomize/helm build scratch. Per-controller patches (volume names differ upstream): source-controller `data`(/data, sizeLimit 1Gi) + `tmp`(/tmp, 256Mi); kustomize/helm-controller `temp`(/tmp, 512Mi). Because a Memory `emptyDir` counts against the container memory cgroup limit, the memory limits are raised for headroom (source-controller 2Gi, kustomize/helm-controller 1536Mi) — a full tmpfs would otherwise OOM-kill the pod; each `sizeLimit` also caps tmpfs growth so a runaway artifact can't exhaust node RAM.
- `kustomization.yaml` - Manifest collection

---

## 2. Technologies & Dependencies

### GitOps & Orchestration

- **Flux CD** - v2.x (ghcr.io/fluxcd)
- **Flux Operator** - v0.40.0
- **Kustomize** - Kubernetes manifest customization
- **Helm** - Package management

### Networking

- **Cilium** - v1.18.6 (eBPF-based networking)
- **Gateway API** - v1alpha3 (experimental channel)
- **kgateway** - v2.2.2 (Kubernetes API Gateway)
- **L2 Announcements** - VLAN interface eno1.4000

### Storage

- **Rook/Ceph** - v19.2.3
- **Block Storage** - RBD
- **Object Storage** - S3-compatible
- **external-snapshotter** - v8.6.0 (CSI VolumeSnapshot CRDs + snapshot-controller, mgmt cluster)

### OpenStack Operators

- **Yaook Operators** - v2.2.0 (charts.yaook.cloud)
- **Operators**: infra, keystone, keystone-resources, glance, nova, nova-compute, neutron, neutron-ovn, horizon, octavia, designate, cds, barbican

### Certificate Management

- **Cert-Manager** - v1.19.2
- **Internal CA Issuer**

### DNS

- **ExternalDNS** - v0.21.0 (Helm chart v1.21.1, Designate provider, mgmt cluster)
- **dns_manager** - Narrow custom Keystone role (recordset CRUD + zone/recordset read; no zone write/delete). Used by workload-cluster ExternalDNS app-creds to manage recordsets in the shared admin-owned `rpcu.lan` zone. Role definition: `clusters/mgmt/crossplane/openstack/cloud-controller-dns.yaml` (alongside the admin-project app-cred). Designate policy OR-in: `infrastructure/yaook/designate.yaml` `policy:` block.

### Infrastructure Abstraction

- **Crossplane** - v2.2.0 (universal control plane)

### Cluster Lifecycle (Cluster API)

- **Cluster API Operator** - v0.27.0 (declarative provider lifecycle)
- **CAPI Core** - v1.13.2 (cluster-api)
- **Kubeadm Bootstrap Provider** - v1.13.2
- **Kubeadm Control Plane Provider** - v1.13.2
- **OpenStack Infrastructure Provider (CAPO)** - v0.14.4
- **OpenStack Resource Controller (ORC)** - v2.5.0 (image resolution dependency for CAPO v0.14.x)
- **clusterctl** - v1.12.x (used for initial bootstrap; `clusterctl move` planned for self-management)

### Cloud Provider Integration

- **OpenStack Cloud Controller Manager (OCCM)** - chart v2.35.0 / app v1.35.0
  (`Service` type `LoadBalancer` via Octavia + Node initialisation on the mgmt
  cluster; replaces Cilium's L2-announcement LoadBalancer)

### Development Tools

- **Nix/NixOS** - Flakes for reproducible builds
- **Direnv** - Shell environment management
- **DevEnv** - Development environment setup
- **Pre-commit Hooks** - Code quality enforcement
  - shellcheck (shell scripts)
  - nixfmt-rfc-style (Nix code)
  - prettier (YAML/JSON)

### Available Commands in devenv

- `jq` - JSON processor
- `yq` - YAML processor
- `runme` - Executable documentation
- `code-server` - VS Code in browser
- `go-task` - Task runner
- `fluxcd` - Flux CLI
- `kustomize` - Kustomize CLI
- `kubernetes-helm` - Helm CLI
- `kube-capacity` - Kubernetes resource analyzer
- `openstackclient` - OpenStack CLI
- `sveltosctl` - Sveltos multi-cluster management CLI (v1.9.0)

---

## 3. Key Configuration Details

### Git Repository

- **Remote**: <git@github.com>:RPCU/argus.git
- **Main Branch**: main
- **Sync Interval**: 1 minute
- **Development Branches**: dev, dev-vic, ciliumlb
- **Commit Signing**: GPG required
- **Authentication**: SSH key-based

### Flux Sync Configuration

**Source**: infrastructure/fluxcd/instances/flux.yaml

- **Distribution**: Flux 2.x
- **Components**: source, kustomize, helm, notification controllers
- **Git Repository**: <https://github.com/RPCU/argus.git>
- **Branch**: main
- **Path**: ./clusters/PLACEHOLDER (cluster-specific override)
- **Concurrency**: 2 operations per controller (kustomize/helm) to bound apiserver/etcd load
- **Ephemeral storage**: all controllers use tmpfs (RAM-backed `emptyDir` `medium: Memory`) instead of node disk, to avoid heavy disk I/O (source-controller `data`/`tmp`; kustomize/helm-controller `temp`), with per-volume `sizeLimit`s and raised memory limits for headroom
- **Interval**: 1 minute

### Cluster Network Configuration (clusters/openstack/)

- **Kubernetes API**: 10.0.0.5:6443
- **Device Routing**: eno1.4000 (VLAN)
- **Cilium `--devices`**: `eno1.4000,br-ex,br-int` — the OVN bridges `br-int`/`br-ex` must be included for OpenStack VM communication (see "Cilium `--devices` must include the OVN bridges" in Section 8)
- **L2 Announcement Interface**: eno1.4000
- **Load Balancer IPs**: 10.0.0.240-10.0.0.253 (now used by kgateway)

### Ceph Cluster

- **Cluster**: rook-ceph
- **Monitors**: 3 (lucy, makise, quinn)
- **Storage**: NVMe SSDs
- **Version**: Ceph v19.2.3
- **Dashboard**: Enabled
- **Pools**: RBD (block), Object Store (S3)

### Code Quality & Formatting Configuration

**`.yamllint`** - YAML linting rules

- Extends default yamllint rules
- Disables `document-start` rule (not auto-fixed by prettier)
- Line length rule disabled for flexibility
- Indentation set to 2 spaces

**`.prettierrc.yaml`** - Prettier formatting configuration

- `proseWrap: preserve` - Keeps prose as-is
- `tabWidth: 2` - 2-space indentation
- `useTabs: false` - Use spaces instead of tabs
- Applies to YAML/JSON files via devenv treefmt

**Note**: `treefmt` with `prettier` handles structure formatting but NOT:

- Inline comment spacing (requires manual fixing)
- YAML document start markers (handled via `.yamllint` rules)

### Helm Chart Versions

| Component            | Version | Repository                                     | Sync Interval |
| -------------------- | ------- | ---------------------------------------------- | ------------- |
| cert-manager         | v1.19.2 | jetstack/cert-manager                          | 5m            |
| cilium               | v1.18.6 | cilium/cilium                                  | 5m            |
| kgateway             | v2.2.2  | oci://cr.kgateway.dev/kgateway-dev/charts      | 5m            |
| rook                 | v1.20.1 | rook-release/rook-ceph                         | 5m            |
| ceph-csi-drivers     | 1.0.3   | ceph.github.io/ceph-csi-operator               | 5m            |
| crossplane           | 2.2.0   | charts.crossplane.io/stable                    | 5m            |
| external-secrets     | 2.3.0   | charts.external-secrets.io                     | 5m            |
| yaook-crds           | 2.2.0   | yaook.cloud/crds                               | 5m            |
| yaook-ops            | 2.2.0   | yaook.cloud/operators                          | 5m            |
| capi-operator        | 0.27.0  | kubernetes-sigs.github.io/cluster-api-operator | 5m            |
| openstack-ccm        | 2.35.0  | kubernetes.github.io/cloud-provider-openstack  | 5m            |
| openstack-cinder-csi | 2.35.0  | kubernetes.github.io/cloud-provider-openstack  | 5m            |
| ceph-csi-cephfs      | 3.15.0  | ceph.github.io/csi-charts                      | 5m            |
| external-dns         | 1.21.1  | kubernetes-sigs.github.io/external-dns/        | 5m            |
| openstack-exporter   | 1.6.0   | ghcr.io/openstack-exporter/openstack-exporter  | 60s (SM)      |

---

## 4. Deployment & Sync Process

### Kustomization Dependencies (from clusters/openstack/)

1. **flux-operator** (no dependencies)
   - Deploys Flux operator v0.40.0

2. **fluxcd** (depends on flux-operator)
   - Instantiates Flux CD components
   - Configures Git sync from RPCU/argus:main

3. **Core Components** (after Flux):
   - cert-manager
   - cert-manager-issuer
   - trust-manager (setup → configs with dependsOn)
   - gateway-api (CRDs)
   - kgateway-crds (depends on gateway-api)
   - kgateway (depends on kgateway-crds)
   - cilium (with VLAN patches)
   - crossplane (Helm → crossplane-openstack → crossplane-compositions → crossplane-resources [./clusters/openstack/crossplane, prune:false])
   - external-secrets
   - rook (setup → csi-drivers → configs with health checks)
   - yaook-operator (CRDs first, then operators via dependsOn)

### Kustomization Dependencies (from clusters/mgmt/)

CAPI management cluster (self-management target via `clusterctl move`):

1. **flux-operator** (no dependencies) → Flux operator
2. **fluxcd** → Flux CD instance (sync ./clusters/mgmt)
3. **cilium** (no dependencies) → eBPF-based networking (CNI / kube-proxy replacement). **Cilium's LoadBalancer is disabled on mgmt**: L2 announcements and LB IP pool are `$patch: delete`d; `Service` type `LoadBalancer` is provided by the OpenStack CCM via Octavia instead.
4. **cert-manager** (no dependencies) → prerequisite for CAPI operator
   - **gateway-api** (no dependencies) → Gateway API v1.4.1 experimental CRDs
   - **kgateway-crds** (dependsOn gateway-api) → kgateway CRDs HelmRelease
   - **kgateway** (dependsOn gateway-api + kgateway-crds + cert-manager-issuer) → kgateway controller + `https` Gateway. Patched for mgmt: Cilium `lbipam.cilium.io/ips` annotation removed (Octavia/OCCM auto-assigns the LB floating IP); listener hostnames rewritten to `*.mgmt.rpcu.lan`; cluster-issuer repointed to `root-mgmt` and `certificateRefs` to `rpcu-lan-wildcard-tls`.
   - **cert-manager-issuer** (dependsOn cert-manager + kgateway-crds) → mgmt-local `selfsigned` → `root-mgmt` CA chain + `rpcu-lan-wildcard-tls` leaf cert (`*.mgmt.rpcu.lan`, ns kgateway-system). Independent of openstack's `root-rpcu`.
5. **external-secrets** (no dependencies) → sources CAPO credentials
6. **cluster-api-operator** (dependsOn cert-manager)
7. **orc** (no dependencies) → ORC v2.5.0, image resolution for CAPO
8. **cluster-api-providers** (dependsOn cluster-api-operator + external-secrets + orc)
   - CoreProvider installed first; operator requeues the others until it exists
   - kubeadm bootstrap + control-plane providers
   - openstack (CAPO) infrastructure provider with capo-variables configSecret
   - ORC (openstack-resource-controller) is a CAPO image-resolution dependency but
     is installed out-of-band (kubectl apply of upstream kustomize), NOT as a
     provider CR — see cluster-api-providers note
9. **cluster-api-templates** (dependsOn cluster-api-providers) → ClusterClass
   `openstack-default` + `openstack-default-v1` + `openstack-kamaji` + `openstack-kamaji-v1` + versioned templates
10. **capo-identity** (dependsOn external-secrets + cluster-api-providers,
    `wait: false`) → SecretStore + ExternalSecret syncing capo-variables
    clouds.yaml (capo-system) → mgmt/mgmt-cloud-config for CAPO's identityRef.
    Split from cluster-api-templates so an ESO failure can't abort the
    ClusterClass apply.
11. **openstack-ccm-identity** (dependsOn external-secrets + cluster-api-providers,
    `wait: false`) → SecretStore + ExternalSecret rendering the OCCM
    `cloud-config` secret (kube-system/cloud-config) from capo-variables
    clouds.yaml (capo-system). Same ESO + credential plumbing as capo-identity,
    targeting kube-system for the CCM.
12. **openstack-ccm** (dependsOn openstack-ccm-identity) → OpenStack Cloud
    Controller Manager HelmRelease. Provides `Service` type `LoadBalancer` via
    Octavia and initialises Nodes (removes the CAPO cloud-provider taint).
    Replaces Cilium's L2-announcement LoadBalancer on the mgmt cluster.
13. **external-snapshotter-crds** (no dependencies) → VolumeSnapshot /
    VolumeGroupSnapshot CRDs (external-snapshotter v8.6.0, remote base).
14. **external-snapshotter** (dependsOn external-snapshotter-crds) →
    snapshot-controller Deployment + RBAC (kube-system).
15. **openstack-cinder-csi** (dependsOn openstack-ccm-identity +
    external-snapshotter-crds) → Cinder CSI Driver (DaemonSet + Deployment).
    Provides `StorageClass` for Cinder PVCs. Shares the cloud-config secret from
    openstack-ccm-identity; its csi-snapshotter sidecar needs the VolumeSnapshot
    CRDs.
16. **internal-dns** (dependsOn external-secrets, `wait: false`) → InternalDNS
    with inovex Designate webhook provider. Syncs Service/Gateway HTTPRoute DNS
    records into the `rpcu.lan.` zone via `https://designate.rpcu.vpn`.
    Credentials follow the ESO pattern (capo-variables clouds.yaml →
    openstack-credentials in internal-dns namespace); `OS_CLOUD` env var selects
    the cloud entry. IMPORTANT: `auth_url` in `capo-variables` must be the
    gateway endpoint (`https://keystone.rpcu.vpn`), not the in-cluster Keystone.
17. **crossplane** (no dependencies) → Crossplane Helm install
18. **crossplane-zitadel** (dependsOn crossplane) → provider-zitadel package
    (provider only — no ProviderConfig or platform resources here)
19. **crossplane-resources** (dependsOn crossplane-zitadel, `prune: false`) →
    mgmt's own Zitadel `ProviderConfig` + the **chihiro** `Oidc` app (writes
    `chihiro-oidc-conn` secret). References the shared org/project by literal
    external ID — the openstack cluster owns the Zitadel platform.
20. **chihiro** (dependsOn cert-manager-issuer + kgateway + dragonfly-operator +
    external-secrets + crossplane-resources) → chihiro app. The `apps/chihiro/oidc.yaml`
    ESO ExternalSecret remaps `chihiro-oidc-conn`'s `attribute.client_id` /
    `attribute.client_secret` into the `chihiro-oidc` secret with the
    `clientId`/`clientSecret` keys `deploy.yaml` expects.
21. **dragonfly-operator** (no dependencies) → Dragonfly (Redis-compatible) operator
22. **kubernetes-rbac** (no dependencies) → OIDC group → RBAC bindings on the
    workload cluster (bare `kube-admin` → `cluster-admin`, `kube-user` → `view`).
    Matches the Zitadel `groupsClaim` Action's bare group names and the
    ClusterClass empty `groupsPrefix`; harmless before OIDC is enabled.
23. **sveltos** (`prune: true`) → basic Sveltos install
    (`infrastructure/sveltos`): core controllers + ClusterProfiles pushed to opt-in
    child clusters:
    - `oidc-rbac` (label `sveltos.argus.rpcu.io/oidc-rbac: enabled`) — binds
      `kube-admin`/`kube-user` to `cluster-admin`
    - `cilium` (`syncMode: ContinuousWithDriftDetection`) — deploys Cilium
      v1.18.6 via inline `helmCharts` (label `sveltos.argus.rpcu.io/cilium: enabled`)
    - `flux` (`syncMode: OneTime`) + `flux-instance`
      (`syncMode: ContinuousWithDriftDetection`, `dependsOn: flux`) — deploys
      Flux Operator v0.40.0 + FluxInstance (self-reconciles from
      `./infrastructure/fluxcd/operator`)
    - `external-snapshotter`, `openstack-ccm`, `openstack-cinder-csi` —
      `syncMode: ContinuousWithDriftDetection`, `dependsOn: flux-instance`
      (label `sveltos.argus.rpcu.io/openstack-integration: enabled`)
    - `capi-management` (`syncMode: ContinuousWithDriftDetection`,
      `dependsOn: flux-instance`) — deploys the full CAPI/CAPO stack (cert-manager,
      external-secrets, cluster-api-operator, ORC, CAPI providers, capo-identity,
      ClusterClass templates) as Flux Kustomization CRs, plus transfers the
      `capo-variables` secret from the mgmt cluster via `templateResourceRefs`
      (label `sveltos.argus.rpcu.io/capi-management: enabled`). The CAPO
      provider version can be overridden per cluster via the CAPI Cluster
      annotation `sveltos.argus.rpcu.io/capo-version` (templated patch on the
      `cluster-api-providers` Flux Kustomization; unset = repo-pinned default)
    - `vault-auth` (`syncMode: ContinuousWithDriftDetection`,
      `dependsOn: flux-instance`) — provisions a per-cluster Vault Kubernetes
      auth backend on the shared mgmt Vault (Crossplane `provider-vault` MRs:
      `Policy`/`Backend`/`AuthBackendConfig`/`AuthBackendRole`) and pushes ESO +
      a `vault-backend` `ClusterSecretStore` + the `root-mgmt` CA bundle to the
      workload cluster, so it can read secrets from `https://vault.mgmt.rpcu.lan`
      without static tokens (label `sveltos.argus.rpcu.io/vault-auth: enabled`)
    - `cert-manager` (`syncMode: ContinuousWithDriftDetection`,
      `dependsOn: flux-instance`) — per-cluster cert-manager + a `vault-issuer`
      `ClusterIssuer` backed by the shared mgmt Vault PKI **intermediate**
      (`pki-int`, chained under `root-mgmt`). Per cluster it provisions
      (Crossplane `provider-vault` MRs) a `SecretBackendRole cm-<cluster>` on
      `pki-int` with `allowedDomains: ["<cluster>.rpcu.lan"]` (SUBDOMAIN
      ISOLATION — Vault refuses to sign outside the cluster's own subdomain), a
      `Policy pki-cm-<cluster>` (issue/sign that role only), and a per-cluster
      kubernetes-auth `Backend` at `pki-clusters/<cluster>`; on the workload
      cluster it installs cert-manager + the `vault-issuer` ClusterIssuer + the
      `root-mgmt` CA bundle. Improves on flux-mgmt's shared PKI role/AppRole
      (label `sveltos.argus.rpcu.io/cert-manager: enabled`)
    - `gateway-api` (`syncMode: ContinuousWithDriftDetection`,
      `dependsOn: cert-manager`) — deploys Gateway API CRDs, kgateway CRDs +
      controller, and a workload-cluster Gateway (hostname `*.cluster.rpcu.lan`,
      `vault-issuer` for TLS). Includes a manually-created wildcard Certificate
      (`wildcard-tls`) signed by the per-cluster Vault PKI intermediate. HTTPRoutes
      attached to the Gateway are synced to Designate by the external-dns add-on
      (label `sveltos.argus.rpcu.io/gateway-api: enabled`)
    - `ceph-csi-cephfs` (`syncMode: ContinuousWithDriftDetection`,
      `dependsOn: [flux-instance, vault-auth]`) — external CephFS CSI driver
      providing **ReadWriteMany (RWX)** volumes backed by the openstack cluster's
      `rpcu-fs` CephFilesystem. Pushes the `ceph-csi-cephfs-cluster-values`
      ConfigMap (remote Ceph FSID + mons, identical across all workload clusters)
      and a Flux Kustomization CR wrapping `./infrastructure/ceph-csi-cephfs`
      (the ExternalSecret reads `secrets-<cluster>/ceph-csi` from Vault via the
      `vault-backend` ClusterSecretStore provisioned by vault-auth). The CephFS
      client key (`adminID`/`adminKey`) must be seeded in Vault per cluster out of
      band (see `infrastructure/ceph-csi-cephfs/README.md`).
      (label `sveltos.argus.rpcu.io/ceph-csi-cephfs: enabled`)

    `wait: false` — the dashboard's placeholder OIDC `clientId` must be set
    before it can come up healthy.

24. **vault** (dependsOn kgateway + openstack-cinder-csi) → HashiCorp Vault
    (`infrastructure/vault`). **HA Vault (3-node integrated Raft storage, no
    external Consul)** reachable at `vault.mgmt.rpcu.lan` via a Gateway API
    `HTTPRoute` on the shared kgateway `https` Gateway (TLS terminated with the
    `rpcu-lan-wildcard-tls` cert / root-mgmt CA). The chart Ingress is disabled;
    each replica's `dataStorage` PVC requests the `cinder-delete` StorageClass.
    The 3 replicas need 3 distinct schedulable nodes (chart `required`
    podAntiAffinity). Every Vault pod starts **sealed** and must be unsealed
    manually after every (re)start. The mgmt Vault also hosts a PKI
    **intermediate** CA (`pki-int` mount, chained under the cert-manager
    `root-mgmt` root) provisioned by `clusters/mgmt/crossplane/vault/pki-int.yaml`
    (Crossplane `Mount` + `SecretBackendIntermediateCertRequest` +
    `SecretBackendConfigUrls`); the intermediate CSR must be signed by `root-mgmt`
    once by hand (`infrastructure/vault/README.md` → "Vault PKI intermediate
    bootstrap") before `vault write pki-int/intermediate/set-signed`. This
    intermediate is the shared signer for the Sveltos `cert-manager` add-on's
    per-cluster, subdomain-isolated PKI Roles.

### Health Checks

**Rook Configs Kustomization** (rook.yaml):

```yaml
healthChecks:
  - apiVersion: ceph.rook.io/v1
    kind: CephCluster
    name: rook-ceph
    namespace: rook-ceph
```

- Waits for CephCluster to be ready
- 5-minute timeout per deployment

### Pre-commit Testing

**devenv.enterTest**:

```bash
echo "Running tests"
hello | grep "Welcome"
```

Validates devenv configuration and hello script.

---

## 5. Making Changes

### Common Tasks

**Update Helm Chart Version**:

1. Edit infrastructure/[component]/helmrelease.yaml
2. Change `spec.chart.version` field
3. Test locally with `fluxcd reconcile helmrelease [name] -n [namespace] --with-source`

**Add New Certificate Issuer**:

1. Create file in clusters/openstack/cert-manager-issuer/[name].yaml
2. Reference in clusters/openstack/cert-manager-issuer/kustomization.yaml
3. Apply via Flux

**Modify Cilium Network Policy**:

1. Edit clusters/openstack/cilium.yaml patches
2. Update VLAN interface or IP pool as needed
3. Verify with `cilium policy get` in toolbox pod

**Configure Ceph Storage**:

1. Edit infrastructure/rook/configs/[resource].yaml
2. Ensure health checks pass
3. Verify with Ceph dashboard or toolbox

### Development Workflow

1. Create feature branch: `git checkout -b feature/your-feature`
2. Make YAML changes
3. Run pre-commit: `pre-commit run --all-files` (via devenv)
4. Test with `fluxcd` CLI if available
5. Commit with message: `git commit -m "feat: description"`
6. Push: `git push origin feature/your-or-your-team's-feature`
7. Create PR on GitHub

### Dependency Updates (Renovate)

`renovate.json5` (repo root) drives dependency-update PRs. Renovate runs
**self-hosted in GitHub Actions** (`.github/workflows/renovate.yaml`, the
`renovatebot/github-action`) rather than via the Mend-hosted App. **No
auto-merge** — every PR requires manual review/merge (production GitOps). PRs
are batched Monday early morning (`Europe/Paris`) via the `schedule` in
`renovate.json5`. A Dependency Dashboard issue tracks everything.

**Runner + auth (self-hosted).** The workflow (`.github/workflows/renovate.yaml`)
runs hourly (`cron: 0 * * * *`) plus `workflow_dispatch` (with `dryRun` /
`logLevel` inputs); Renovate's own `schedule` gates when branches/PRs are
actually created, so the hourly runs are cheap no-ops outside the window. It
mints a short-lived installation token from the org's **`rpcu-bot` GitHub App**
(app_id `3164565`) via `actions/create-github-app-token@v1` (same pattern as
bealv's updatecli workflow), then passes it to the Renovate action. It reuses
the existing **org-level** secrets already granted to `argus` (no repo-level
secrets needed):

- `APP_ID` — the `rpcu-bot` App's numeric App ID.
- `PRIVATE_KEY` — the `rpcu-bot` App's private key (PEM).

Both are org secrets on `RPCU` (visible to argus via
`gh api /repos/RPCU/argus/actions/organization-secrets`), created out of band
from `https://github.com/organizations/RPCU/settings/apps/rpcu-bot`.

The `rpcu-bot` App must have **Workflows: Read and write** permission — the
`helpers:pinGitHubActionDigests` preset makes Renovate open PRs that edit
`.github/workflows/*`, which requires the `workflows` scope on the token (the
App's other needed scopes — Contents, Pull requests, Issues, Actions — are
already granted). The Mend-hosted `renovate` App (app_id `2740`) is installed
org-wide (`repository_selection: all`); to avoid it double-running against
argus alongside the self-hosted job, exclude argus from that App's access
(org → Installations → `renovate` → Only select repositories) or uninstall it.

**What it tracks, and how:**

- **Flux HelmReleases / HelmRepositories** (HTTP + OCI) — built-in `flux`
  manager (cert-manager, cilium, kgateway, rook, crossplane, external-secrets,
  yaook operators, capi-operator, openstack-ccm, openstack-cinder-csi,
  external-dns, sveltos, flux-operator, etc.).
- **Helm `values.yaml` images** with a `repository:`+`tag:` pair — built-in
  `helm-values` manager (openstack-ccm, openstack-cinder-csi).
- **Custom (regex) managers** in `renovate.json5` for the pins no built-in
  manager understands:
  1. Kustomize remote bases via GitHub **release-download URLs**
     (`.../releases/download/vX/...`) and `raw.githubusercontent.com/.../vX/...`
     → `github-releases` (orc, gateway-api, dragonfly).
  2. Kustomize remote bases via **`?ref=vX`** → `github-releases`
     (external-snapshotter crds + controller).
  3. **Crossplane** provider/function packages (`package: xpkg.../...:vX`) →
     `docker` (provider-openstack, provider-zitadel, provider-random,
     function-patch-and-transform).
  4. **Cluster API provider** `version:` fields — driven by inline
     `# renovate: datasource=github-releases depName=<org/repo>` markers in
     `infrastructure/cluster-api-providers/*.yaml` (core/bootstrap/control-plane
     → `kubernetes-sigs/cluster-api`; CAPO →
     `kubernetes-sigs/cluster-api-provider-openstack`; kamaji →
     `clastix/cluster-api-control-plane-provider-kamaji`). The
     `clusterctl-providers.yaml` inventory carries the same markers so the
     inventory stays in lockstep with the operator CRs.
  5. **Sveltos ClusterProfile inline `helmCharts`** (`chartVersion:`) — inline
     markers in `infrastructure/sveltos/clusterprofiles/*.yaml` (cilium →
     `datasource=helm`; flux-operator OCI → `datasource=docker`).
  6. **Helm-values `tag:` without a sibling `repository:`** — inline marker in
     `infrastructure/kamaji/values.yaml` (`docker.io/clastix/kamaji`).
  7. **Plain `image: registry/repo:tag`** in raw manifests → `docker` (rook
     ceph image + toolbox + nfs-export CronJob, chihiro). All three
     `quay.io/ceph/ceph` images are pinned to the same full tag (`v19.2.3`,
     not a floating `v19`) and grouped so they bump in lockstep.

**npins is NOT managed by Renovate.** `npins/sources.json` pins carry a
`revision`/`url`/`hash` that a Renovate regex cannot refresh (it could only bump
the `version` string, leaving a stale hash that breaks the Nix build). The
dedicated `.github/workflows/npins-update.yaml` workflow runs `npins update`
across ALL pins every 6h and opens correct PRs with refreshed hashes — it is the
sole owner of npins updates (sveltosctl, nixpkgs, etc.).

**yaook OpenStack releases are NOT managed by Renovate.** The yaook operator
supports multiple OpenStack releases (e.g. `2025.1`, `2026.1`) via the
`targetRelease` field in each Deployment CR. New releases are defined in the
operator's Python source (`RELEASES = [...]` in each component's `__init__.py`
or `cr.py`). Because there is no public registry or datasource for these
version strings, Renovate cannot track them. The dedicated
`.github/workflows/yaook-releases.yaml` workflow runs weekly (Monday 03:00 UTC)
and on-demand: it fetches the yaook operator source from GitLab, extracts the
`RELEASES` lists from all components, compares them to the `targetRelease` in
our CRs (`infrastructure/yaook/*.yaml`), and opens a PR to upgrade if a newer
release is available. All 8 CRs are updated together (keystone, nova, glance,
neutron, cinder, horizon, octavia, designate). Barbican is not currently
deployed. **Before merging:** verify the upgrade path is valid — check the
[yaook upgrade docs](https://yaook.cloud/docs/) for breaking changes.

**Grouping (packageRules):** yaook operators (shared 2.2.0), openstack
cloud-provider (CCM + Cinder CSI + their images), cluster-api providers, cilium
(HelmRelease + Sveltos inline kept in sync), flux-operator (HelmRelease +
Sveltos inline). `major` updates are un-batched and labelled
`major-update`/`needs-careful-review`.

**Intentionally NOT bumped:** the kamaji **chart** is pinned to the rolling
`0.0.0+latest` tag (the chart HelmReleases are `enabled: false` for the `flux`
manager); only its image tag is tracked via the annotated custom manager.

**Adding a new dependency:** if it's a standard HelmRelease/values image it's
picked up automatically. For a new URL-pinned base, Crossplane package, CAPI
provider, Sveltos inline chart, or raw `image:`, either it matches an existing
regex manager or you must add a `# renovate: datasource=... depName=...` marker
on the line above the version (see the existing markers for the exact shape).
Validate after editing: `npx --package renovate -- renovate-config-validator renovate.json5`.

---

## 6. Git Hooks & Code Quality

### Enabled Pre-commit Hooks

- **shellcheck** - Shell script validation
- **nixfmt-rfc-style** - Nix code formatting
- **prettier** - YAML/JSON formatting
- **treefmt** - Multi-format code formatting

### Running Hooks

```bash
pre-commit run --all-files     # Run all hooks
pre-commit run shellcheck      # Run specific hook
```

### Auto-formatting

Prettier, nixfmt, and shfmt are integrated for automatic formatting on commit.

---

## 7. Documentation & Resources

### External Resources

- **Official Docs**: <https://docs.rpcu.io/gitops/>
- **Flux CD**: <https://fluxcd.io/docs/>
- **Cilium**: <https://docs.cilium.io/>
- **Gateway API**: <https://gateway-api.sigs.k8s.io/>
- **kgateway**: <https://kgateway.dev/>
- **Rook**: <https://rook.io/docs/rook/>
- **Cert-Manager**: <https://cert-manager.io/docs/>
- **Crossplane**: <https://docs.crossplane.io/>

### Git Aliases (from .git/config)

```bash
git br            # Branch list
git lg            # Log with graph
git s             # Status
git sw            # Switch branch
# ... and others
```

---

## 8. Important Notes for AI Agents

### Commit Policy

**⚠️ DO NOT COMMIT CHANGES UNLESS EXPLICITLY ASKED**

When making changes:

1. Preview all modifications
2. Ask user for confirmation before committing
3. Show git diff output
4. List all files that will be committed
5. Draft commit message for user approval

### File Safety

- Do NOT modify `.git/config` or Git settings
- Do NOT alter devenv/flake lock files without good reason
- Do NOT delete Kustomization dependencies without updating parents
- Do NOT commit secrets or sensitive data

### Cluster Safety

- Test changes on dev/dev-vic branches first
- Health checks must pass before considering deployment ready
- Verify Flux reconciliation succeeds: `fluxcd reconcile kustomization -n flux-system`
- Never force-delete critical resources (cert-manager, cilium, rook)

#### Cilium `socketLB.hostNamespaceOnly` (per-cluster divergence)

The shared base `infrastructure/cilium/values.yaml` sets
`socketLB.hostNamespaceOnly: false` (the safe default): socket-LB runs inside
pod network namespaces, which ordinary clusters (e.g. mgmt) need for
kube-proxy-free ClusterIP resolution.

The **baremetal openstack cluster overrides this to `true`** in
`clusters/openstack/cilium.yaml`, because its nodes host nested KVM/QEMU
OpenStack VMs — limiting socket-LB to the host namespace prevents the host's
eBPF socket load-balancer from interfering with connections made inside the
guest VMs. If you ever move the base default, re-evaluate both clusters'
patches.

#### Cilium `--devices` must include the OVN bridges `br-int` and `br-ex` (openstack cluster)

The baremetal openstack cluster patches the Cilium agent's device list in
`clusters/openstack/cilium.yaml`:

```yaml
extraArgs:
  - --devices=eno1.4000,br-ex,br-int
  - --direct-routing-device=eno1.4000
```

`br-int` (the OVN **integration bridge**, where every VM tap port lands) and
`br-ex` (the OVN external/provider bridge, uplink `enp3s0`, physnet `public` —
see `infrastructure/yaook/neutron.yaml` `ovn-controller` `configTemplates`) **must
be listed in `--devices`** for OpenStack VM communication to work.

Why: with `kubeProxyReplacement: true` Cilium's eBPF datapath (NodePort /
host-routing / health datapath) only processes traffic on the interfaces named
in `--devices`. Tenant VM traffic enters the host through OVN's bridges, **not**
through `eno1.4000`. If `br-int`/`br-ex` are omitted, Cilium's datapath does not
see that traffic and return/forwarded packets for VM↔node and VM↔Service
(ClusterIP/NodePort/LoadBalancer) flows are dropped — VMs can't reach
in-cluster services and, depending on the path, can't communicate at all.
`--direct-routing-device` stays pinned to `eno1.4000` (the node's real uplink);
only the device-attach list is widened to cover the OVN bridges.

If the OVN bridge names ever change (e.g. a different `bridgeName` in the
NeutronDeployment `bridgeConfig`, or an added tenant/provider bridge), update
this `--devices` list to match.

#### OpenStack CCM replaces Cilium L2-announcement LoadBalancer on mgmt

On the mgmt cluster, `Service` type `LoadBalancer` is provided by the OpenStack
Cloud Controller Manager (`infrastructure/openstack-ccm/`) via Octavia, NOT by
Cilium. The mgmt cilium Flux wrapper (`clusters/mgmt/cilium.yaml`) disables
Cilium's L2-announcement implementation:

- `l2announcements.enabled: false` in the HelmRelease values
- `$patch: delete` removes the base `CiliumLoadBalancerIPPool` and
  `CiliumL2AnnouncementPolicy` CRs

The shared base `infrastructure/cilium/` still contains these resources for the
openstack cluster, which continues to use Cilium LB (its cilium wrapper patches
them with cluster-specific IP pools and interface bindings).

Node subnet for mgmt: `192.168.1.0/24` (managedSubnetCIDR), with allocation
pool starting at `.11` (reserving `.2`–`.10` which were previously the Cilium
LB range; those IPs are now available for the OpenStack DHCP pool).

#### CAPO managed security groups must open the Cilium overlay (mgmt cluster)

CAPO's `managedSecurityGroups` only opens the baseline kube API / etcd /
kubelet / node-port rules. It does **not** open the CNI's overlay traffic (see
CAPO docs, "CNI security group rules"). On the mgmt cluster, Cilium runs in
tunnel/VXLAN mode, so cross-node pod traffic is encapsulated in **UDP 8472**.
Without an explicit rule, Neutron silently drops it: same-node pods work, but
**pod-to-pod and pod-to-Service across nodes fail entirely** (can't even ping
another node's pod), and CoreDNS can't reach the apiserver/endpoints so DNS
never becomes ready (`plugin/ready: Plugins not ready: "kubernetes"`).

Fix lives in `infrastructure/cluster-api-templates/templates/infracluster.yaml`
(and `infrakamaji.yaml`) via `OpenStackClusterTemplate.spec.template.spec.managedSecurityGroups.allowAllInClusterTraffic: true`
— this opens **all** node-to-node traffic on every port/protocol between the
managed `controlplane`/`worker` groups, which fully covers the Cilium overlay
(VXLAN 8472, health 4240, Hubble 4244, ICMP) and every future Cilium feature
without enumerating ports.

> **Do NOT also add explicit `remoteManagedGroups: [controlplane, worker]`
> rules for those ports.** They are redundant with `allowAllInClusterTraffic`
> and, worse, each one normalizes to a Neutron rule tuple CAPO also creates from
> the allow-all — so on a fresh cluster the duplicate POST returns `409
SecurityGroupRuleExists` and aborts the entire SG reconcile, wedging the
> `OpenStackCluster`. `openstack-default-cluster-v3` / `openstack-kamaji-cluster-v5`
> removed those rules for exactly this reason. Keep only rules scoped to
> `0.0.0.0/0` (SSH, DNS egress, NodePort, kubelet 10250) in
> `allNodesSecurityGroupRules`, since those don't collide with the in-cluster
> allow-all. After a template rotation, verify the rules actually landed on the
> managed SGs:
> `openstack security group rule list k8s-cluster-mgmt-mgmt-secgroup-controlplane`.

#### CAPO managed security groups must open the NodePort range for Octavia LoadBalancer (mgmt cluster)

A second, distinct gap in CAPO's default managed SGs: they do **not** open the
Kubernetes Service **NodePort range (30000–32767)** from outside the cluster.
On mgmt, external `type: LoadBalancer` Services are provisioned by the OpenStack
CCM via Octavia (OVN provider). The Octavia VIP DNATs incoming traffic to a
member = `<node IP>:<nodePort>`. Without a NodePort ingress rule the managed SG
silently drops that, so the LoadBalancer **floating IP times out at the TCP
layer** (`curl: (28) Failed to connect ... Connection timed out`) even though
the Octavia VIP, the floating IP, and the DNS record are all correct. This is
the failure that made the kgateway `https` Gateway (the cluster's only
`type: LoadBalancer` service, floating IP `172.16.255.111`) unreachable while
every other endpoint resolved fine.

Fix: `openstack-default-cluster-v2` in
`infrastructure/cluster-api-templates/templates/infracluster.yaml` adds an
ingress rule opening **TCP 30000–32767 from `0.0.0.0/0`** (source can't be
scoped — the OVN VIP may preserve the original client source IP with
`lb-method=SOURCE_IP_PORT`). Because `OpenStackClusterTemplate.spec.template.spec`
is immutable once referenced, this is a NEW `-v2` template with the ClusterClass
`infrastructure.templateRef` repointed to it (the documented `-vN` rotation) —
NOT an in-place edit of `-v1`. The rotation reconciles the SGs onto the live
`OpenStackCluster` without rolling machines; delete `-v1` once confirmed. Verify
with `openstack security group rule list k8s-cluster-mgmt-mgmt-secgroup-worker`
(and `…-controlplane`).

Note: MTU is a separate, secondary concern. Double encapsulation (Cilium VXLAN
over Neutron VXLAN/Geneve) shrinks the usable pod MTU; large packets (DNS/TCP,
big API LISTs, TLS) can black-hole if MTUs are inconsistent. Do NOT apply jumbo
frames piecemeal — an MTU mismatch on any hop is worse than a consistent small
MTU. Confirm overlay connectivity first, then size Cilium `MTU` to the OpenStack
tenant-network MTU if needed.

#### Kamaji control plane must open kubelet port 10250 (workload clusters)

With the `openstack-kamaji` ClusterClass the kube-apiserver runs as **pods in
the mgmt cluster** (KamajiControlPlane), NOT as OpenStack VMs in the workload
cluster's managed security groups. `kubectl logs` / `exec` / `attach` /
`port-forward` and `kubectl top node` all proxy from the apiserver to each
node's **kubelet on TCP 10250**. CAPO's default managed SG only opens 10250 to
the managed `controlplane`/`worker` groups (node-to-node); the Kamaji apiserver
pods have a source IP from the mgmt cluster's network — outside those SGs — so
they are dropped. Symptom: `kubectl logs`/`exec` against a Kamaji-CP cluster
hang / time out (`error dialing backend: ... i/o timeout`) while the API itself
works.

Fix: `openstack-kamaji-cluster-v3` in
`infrastructure/cluster-api-templates/templates/infrakamaji.yaml` adds an
ingress rule opening **TCP 10250 from `0.0.0.0/0`**. Source can't be scoped:
the Kamaji CP egress IP depends on the mgmt cluster's SNAT/floating-IP, and
`remoteManagedGroups` cannot reference a group outside this cluster — so it is
opened from anywhere (the kubelet still enforces authenticated+authorized TLS,
so the port is exposed but not unauthenticated). Because
`OpenStackClusterTemplate.spec.template.spec` is immutable once referenced, this
is a NEW `-v3` template with the Kamaji ClusterClass `infrastructure.templateRef`
repointed to it (the documented `-vN` rotation) — NOT an in-place edit of `-v2`.
The rotation reconciles the SGs onto the live `OpenStackCluster` without rolling
machines; delete `-v2` once confirmed. Verify with
(and `…-controlplane`). This gap is Kamaji-specific — the kubeadm
`openstack-default` class runs the apiserver ON a control-plane VM inside the
managed SGs, so it reaches the kubelet via the node-to-node 10250 rule already.

#### OCCM health monitor timeouts cause intermittent TLS handshake failures (mgmt cluster)

The OCCM `cloud.conf` sets `create-monitor=true` for Octavia health monitors,
but for a long time had **no explicit timeout parameters** (`monitor-delay`,
`monitor-timeout`, `monitor-max-retries`). OVN's default health monitor
timeouts are aggressive (~5s delay, ~5s timeout, ~2 retries). When a
`type: LoadBalancer` backend (e.g. the Kamaji tenant API server pod) takes
longer than ~5s to respond to the TCP health probe — due to TLS handshake CPU
cost, transient load, or GC pause — the OVN health monitor marks the backend
DOWN and Octavia stops routing new connections to it. The client's TCP
connection to the floating IP succeeds (the VIP is always reachable), but
Octavia has no healthy backends → the TLS ServerHello never arrives → the
client sees `net/http: TLS handshake timeout`. This is intermittent because it
only triggers when the backend is under load and the health probe is slow.

Fix: `infrastructure/openstack-ccm-identity/externalsecret.yaml` now includes
explicit monitor parameters:

```ini
monitor-delay=10s
monitor-timeout=10s
monitor-max-retries=3
```

This gives backends 10s to respond (vs the ~5s default), and only marks a
backend DOWN after 3 consecutive failures (vs ~2). The Kamaji tenant API server
pods perform TLS handshakes with asymmetric crypto; under concurrent load the
CPU-bound work can exceed 5s on a shared mgmt node. The 10s window accommodates
this without sacrificing health detection (a truly dead backend is caught within
30s = 3 × 10s). These values apply cluster-wide to ALL `type: LoadBalancer`
Services on mgmt (kgateway, Vault, NFS gateway, etc.) — the longer timeout is
safe because a healthy backend responds in <1s; the timeout only matters when
the backend is degraded.

#### Ceph PG autoscaler silently breaks on overlapping CRUSH roots (openstack cluster)

ALL Ceph pools must use **nvme-classed CRUSH rules**. If even one pool uses a
class-less rule (plain `replicated_rule` on root `default`) while others use
device-class rules (shadow root `default~nvme`), the mgr pg_autoscaler
considers the roots "overlapping" and **silently refuses to manage any
affected pool** — `ceph osd pool autoscale-status` returns EMPTY output and
`pg_num` never grows. This is exactly what happened until July 2026: the main
data pools (`rdb-pool`, `rpcu-fs-data0`, `rpcu-fs-metadata`,
`rpcu-store.rgw.buckets.data`) sat at **`pg_num: 1`** — 115 GiB of RBD data in
a single PG, one OSD holding ~zero data (no parallelism, monolithic recovery).

Fixed live (one-time ops, July 2026):

- `ceph osd crush rule create-replicated replicated_nvme default host nvme`,
  then repointed `.mgr`, `.nfs`, `cinder.volumes` and the 7 replicated RGW
  pools to it (`ceph osd pool set <pool> crush_rule replicated_nvme`).
- Updated the original EC profile `rpcu-store.rgw.buckets.data_ecprofile` in
  place (`--force`) to add `crush-device-class=nvme` — the July manual fix had
  created a parallel `_ecprofile_nvme` profile instead of updating the
  original, leaving the ObjectStore CR's pools on the old profile without the
  device class.
- Split PGs: `rdb-pool` 32 (autoscaler then grew it further via
  `target_size_ratio: 0.8`), `rpcu-fs-data0` 32, `rpcu-fs-metadata` 16,
  `rpcu-store.rgw.buckets.data` 32.

Repo side: `cephblockpool.yaml` sets `pg_autoscale_mode: on` +
`target_size_ratio: 0.8`; `cephobjectstore.yaml` sets `deviceClass: nvme` on
both pools. When adding ANY new pool (including Rook-implicit ones like
`.nfs`), make sure it lands on an nvme-classed rule or the autoscaler breaks
again cluster-wide.

#### Ceph OSD CPU over-reservation wedges the OVN rollout on the small node (openstack cluster)

On the openstack cluster, `quinn` has only 8 cores versus 12 on `lucy`/`makise`
(verified with `kubectl get node <node> -o jsonpath='cpu={.status.capacity.cpu}'`).
All three nodes are `control-plane`, `hypervisor`, and run the full set of
yaook control-plane, Ceph, and kube control-plane workloads.

When the OVN dataplane pods (`neutron-ovs-vswitchd-*` and
`neutron-ovn-controller-*`) were updated to include CPU requests of 300m each
(the fix for "OVN control plane must not be BestEffort"), the rollout wedged
on `quinn`.

Diagnosis: `quinn` had 8000m allocatable CPU, with 7730m already requested by
running pods (96%). This left only 270m unrequested. Since each OVN pod
requested 300m, they couldn't fit by 30m. The OVN pods are hard-pinned to their
respective hypervisor nodes via `nodeAffinity`, so they could not be scheduled
elsewhere.

The dominant CPU request on `quinn` was the Ceph OSD pod, which requested 2 CPU
(2000m) while actual usage consistently remained around 200-350m. This was a 6x
over-reservation. While the OSD's `system-node-critical` priorityClass protects
it from eviction, the excessive CPU request unnecessarily consumed allocatable
capacity, preventing other critical pods from scheduling.

Fix: The CPU request for the Ceph OSD (`infrastructure/rook/configs/cephcluster.yaml`)
was reduced from `2` (2000m) to `500m`. This freed 1500m of allocatable CPU on
each node, including `quinn`, allowing the OVN dataplane pods to schedule
without impacting OSD performance (as they still operate without CPU limits and
with `system-node-critical` priority).

#### Ceph single OSD full from too-few PGs on the dominant pool (openstack cluster)

On **2026-07-10** `osd.2` (quinn) hit `full_ratio` (95.02%) and Ceph flagged
`OSD_FULL` → `POOL_FULL` on **all 14 pools**, blocking writes **cluster-wide**,
even though the cluster was only **~73% full** with 760 GiB free. "Full" in Ceph
is **per-OSD, not per-cluster**: a full OSD blocks writes to every pool with PGs
on it regardless of free space elsewhere. K8s PVC accounting does NOT prevent
this — RBD/CephFS volumes are **thin-provisioned** (a 100Gi PVC consumes only
bytes written), the replica-2 ×2 raw multiplier is invisible to K8s, and there
is no admission gate on live Ceph utilization or per-OSD balance.

Root cause: `rpcu-fs-data0` (the CephFS/NFS media pool) holds **~1 TiB ≈ 70% of
raw capacity** but was left at **`pg_num: 32`** by the July 2026 CRUSH-root fix
above. At ~31 GiB per PG on a 3-OSD replica-2 cluster the 64 PG-copies split
**26/19/19**, so quinn carried ~40% of the bytes vs ~30% each on lucy/makise.
The **upmap balancer could not fix it** — it balances on aggregate **PG count**
(which was even: 257/252/233), NOT per-pool bytes; coarse, oversized PGs give it
nothing to smooth (`ceph balancer status` reported `no optimization needed`).

Fixed live (one-time ops, 2026-07-10):

- Unblock writes: `ceph osd set-full-ratio 0.97` / `set-backfillfull-ratio 0.92`
  / `set-nearfull-ratio 0.85→0.88` (temporary — reverted to 0.95/0.9/0.85 once
  drained). Stopgap only; creates no space.
- Immediate relief: `ceph osd reweight osd.2 0.85` to shed PGs off quinn (reset
  to 1.0 after).
- **Durable fix**: split `rpcu-fs-data0` `pg_num` **32 → 128** (finer PGs the
  balancer CAN distribute evenly) + `ceph config set mgr
mgr/balancer/upmap_max_deviation 1` (default 5 was too loose for 3 OSDs).
- Speed up drain: Ceph v19 uses the **mClock scheduler** by default, which
  **IGNORES `osd_max_backfills`/`osd_recovery_max_active`** — recovery speed is
  the `osd_mclock_profile` (default `balanced`). Set
  `ceph config set osd osd_mclock_profile high_recovery_ops` during the drain,
  reset to `balanced` after (starves client I/O otherwise).

Repo side: `cephfilesystem.yaml` `dataPools[0]` (`data0`) now declares
`pg_autoscale_mode: on` + `target_size_ratio: 0.8` (mirrors `cephblockpool.yaml`)
so the autoscaler keeps enough PGs and never collapses back to 32. Both dominant
pools declaring 0.8 is fine — the autoscaler normalizes the ratios (each →
`EFFECTIVE RATIO 0.5`). **Lesson**: on a small (3-OSD) replica-2 cluster, the
pool holding the bulk of the data needs enough PGs that individual PGs stay
small relative to per-OSD capacity, or one OSD fills from placement skew the
PG-count balancer can't correct. Set `target_size_ratio` on EVERY dominant pool.

#### Ceph mon crash storm = containerd fd limit (hephaestus repo)

On 2026-07-03 all 3 mons crash-looped for ~15 min (36 crashes, `abort()` in
`Processor::accept()`): a reconnect storm after a node outage exhausted the
**soft `nofile` limit of 1024** that containers inherit from containerd (the
NixOS containerd unit didn't raise it; upstream containerd.service ships
`LimitNOFILE=infinity`). Fix lives in the **hephaestus** repo
(`nixosModules/kubernetes/default.nix`):
`systemd.services.containerd.serviceConfig.LimitNOFILE = 1048576` — requires a
`nixos-rebuild switch` + containerd restart on lucy/makise/quinn to take
effect. If mons ever crash-loop with that backtrace again, check
`cat /proc/1/limits` inside a mon container first.

#### ANY `novaComputeConfig` edit triggers a rolling eviction (openstack cluster)

Verified in the yaook operator source (`yaook/statemachine/resources/instancing.py`,
v3.0.0): the nova operator renders one `NovaComputeNode` per node from
`compute.configTemplates[]`. When the rendered spec no longer matches the live
instance, the instance is marked `ResourceSpecState` != `UP_TO_DATE`, the
operator sets the `RequiresRecreation` condition and **DELETES the
`NovaComputeNode` to trigger the update** (`instancing.py:1250-1290`), one node
at a time (gated by `max_unavailable`). Deleting a `NovaComputeNode` runs the
`ComputeStateResource` eviction job (`yaook/op/nova_compute/cr.py:510`), which
drains the node by **cold-migrating every VM off it** — i.e. straight into the
two ssh bugs documented below.

So **any** change under `spec.compute.configTemplates[].novaComputeConfig` —
even a one-line, semantically harmless one — starts a rolling drain of
lucy → makise → quinn. This is the mechanism behind the 2026-07-19 lucy
incident, and why the node-resilience note says not to "fix" VM packing by
editing `novaComputeConfig`.

**This is now guarded by `infrastructure/yaook/disruptionbudget.yaml`.** That
`YaookDisruptionBudget` (`nova-compute`, ns yaook) sets
`preventDeletion: true`, so the operator **labels** the node +
`NovaComputeNode` with
`maintenance.yaook.cloud/maintenance-required-nova-compute=True` and sets
`RequiresRecreation` **instead of deleting** (`instancing.py:1004-1032`,
`flag_instead_of_delete`; enabled for nova because
`NovaComputeNodes.__init__` passes `allow_prevent_deletion=True`,
`yaook/op/nova/resources.py:819-821`). The node keeps running the OLD config
until it is recreated by hand.

Consequences to keep in mind:

- **Flagging defers a change, it does not apply it.** A `novaComputeConfig`
  edit does NOT take effect on a node until that node's `NovaComputeNode` is
  actually deleted and recreated. Expect nodes to sit `RequiresRecreation`
  indefinitely — that is the intended steady state, not a fault.
- **Coverage must be total.** The budget uses `matchLabels: {}` (match-all),
  mirroring `nova.yaml`'s `configTemplates[].nodeSelectors`. Any compute node
  NOT matched by some budget falls into the operator's implicit default group
  (`maxUnavailable: 1`, preventDeletion **disabled**) and is auto-evicted —
  a narrower selector would silently re-open the hole.
- **One budget per node, max.** A node matching two `YaookDisruptionBudget`s
  makes the operator raise `ConfigurationInvalid` (`instancing.py:1408-1415`).
  Do not add a second match-all budget in the `yaook` namespace.

#### Runbook: applying a `novaComputeConfig` change, one node at a time

With the budget in place the rollout is manual and interruptible. Per node
(lucy, then makise, then quinn — never in parallel; `maxUnavailable: 1`):

1. **Confirm the node is flagged**, i.e. the operator has rendered the new
   config and is waiting on you:

   ```sh
   kubectl get novacomputenodes -n yaook \
     -o custom-columns=NAME:.metadata.name,RECREATE:'.status.conditions[?(@.type=="RequiresRecreation")].status'
   ```

2. **Pre-empt the two ssh bugs.** The eviction cold-migrates any **SHUTOFF**
   instance (`SHUTOFF` → `OFFLINE_MIGRATABLE` even with
   `disruptiveMaintenance: false`, `nova_compute/eviction.py:233`), so the
   `IdentityFile` live-patch must be applied to ALL nova-compute pods
   **before** deleting anything — see the ssh runbook below. Also verify the
   source node's live `/etc/nova/nova.conf` has
   `remote_filesystem_transport = rsync` under `[libvirt]`.

3. **Reduce the cold-migration surface**: `openstack server list --all-projects
--host <node> --status SHUTOFF`. Every SHUTOFF instance is a cold migration
   and therefore an ssh-bug exposure. Starting them first (so they are ACTIVE
   and get **live** migrated instead) is usually the cheaper path.

4. **Delete the one `NovaComputeNode`** to trigger its recreate + eviction:

   ```sh
   kubectl delete novacomputenode -n yaook <node>
   ```

5. **Watch the eviction** (`kubectl logs -n yaook -l app=compute-evict --tail=-1`,
   or the node's `nova-compute` container). If instances land in
   `EXPONENTIALBACKOFF`/`ERROR`, stop and follow the unwedge runbook below —
   do NOT proceed to the next node.

6. **Verify** the node comes back `Updated/Success/Enabled`, its compute
   service is `up`, and the flag is gone, before starting the next node.

To roll back mid-rollout, simply stop deleting nodes: the remaining nodes keep
their old config indefinitely, since nothing deletes them automatically.

#### Nova cold-migration / node eviction fails: two ssh bugs (openstack cluster)

A yaook **NovaComputeNode eviction** (rolling recreate, or `deleteNode: true`
node teardown) drains a node by **cold-migrating** every VM off it. Because the
openstack cluster uses **local qcow2 root disks** (`images_type` unset →
`/var/lib/nova/instances`), cold migration copies the disk **node-to-node over
SSH** as the `nova` user (sshd on port 8022, locked down by
`restricted-ssh-commands`). TWO independent bugs each break this and wedge the
eviction (node stuck `Evicting` / `WaitingForDependency`, VMs looping
`EXPONENTIALBACKOFF` → eventually `ERROR`/`UNHANDLEABLE`):

1. **`remote_filesystem_transport` must be `rsync` (fixed in-repo).** Nova
   defaults to `scp`, but OpenSSH 9+ `scp` uses the **SFTP** subsystem, which is
   NOT in the `restricted-ssh-commands` allow-list (only legacy SCP wire protocol
   - rsync are) → every copy is rejected → migration rolls back. Fixed
     permanently via `infrastructure/yaook/nova.yaml`
     `spec.…libvirt.remote_filesystem_transport: rsync`. This IS reconciled by the
     operator into the generated compute config — **but only when the operator
     regenerates that config**, which it will NOT do while the node is mid-eviction
     (chicken-and-egg: the rsync fix that would let the eviction finish can't be
     applied until the eviction finishes). See the unwedge runbook below.

2. **`IdentityFile` missing from `/etc/ssh/ssh_config` (yaook IMAGE bug — NOT
   fixable via CR).** The `nova-compute-*` image's ssh_config has no
   `IdentityFile` line, and the `nova` user's **passwd home is `/var/empty`**
   (which doesn't even exist in the container), so ssh's `~/.ssh/id_ed25519`
   default expands to `/var/empty/.ssh/id_ed25519` (missing) instead of the real
   key at **`/home/nova/.ssh/id_ed25519`**. Result:
   `nova@<ip>: Permission denied (publickey)`. Setting `$HOME` does NOT help — ssh
   uses the **passwd** home (`getpwuid`), not `$HOME`, for `~` expansion. The
   NovaDeployment CRD exposes **no** ssh_config override / lifecycle hook /
   extraVolumes / sidecar, so there is no GitOps fix. **Every freshly-created
   nova-compute pod must be live-patched** (below) until the yaook image ships an
   `IdentityFile` (or sets the nova user's home to `/home/nova`). Report upstream.

**Symptom trail** (in the `compute-evict-<node>-*` pod logs and the node's
`nova-compute` container): `is failing to be moved … will start
ExponentialBackoff` → later `UNHANDLEABLE: … (ERROR)`; in the compute log
`Resize error: not able to execute ssh command … ssh -o BatchMode=yes <ip>
mkdir -p /var/lib/nova/instances/<uuid> … Permission denied (publickey)` (bug 2)
or an scp/SFTP `Connection closed` (bug 1).

**Unwedge runbook** (what was done 2026-07-19 for lucy):

1. **Live-patch `IdentityFile` on ALL 3 nova-compute pods** (bug 2, lost on every
   pod restart — the ssh_config is a writable image-layer file):

   ```sh
   for p in $(kubectl get pods -n yaook -o name | grep nova-compute-.*-0); do
     kubectl exec -n yaook ${p#pod/} -c nova-compute -- sh -c \
       'grep -q "IdentityFile /home/nova/.ssh/id_ed25519" /etc/ssh/ssh_config || \
        sed -i "/Host \*/a\    IdentityFile /home/nova/.ssh/id_ed25519" /etc/ssh/ssh_config'
   done
   ```

   Verify auth: `kubectl exec -n yaook <pod> -c nova-compute -- su -s /bin/sh nova
-c 'ssh -o BatchMode=yes <other-node-ip> mkdir -p
/var/lib/nova/instances/00000000-0000-0000-0000-000000000000'` (a real-UUID
   `mkdir` IS allow-listed; `echo`/bogus paths are correctly rejected).

2. **Fix rsync on the SOURCE node's live config if its config secret is stale**
   (bug 1). The source node drives the transport choice. If its
   `/etc/nova/nova.conf` `[libvirt]` lacks `remote_filesystem_transport = rsync`
   (compare with a healthy node), the config secret
   (`nova-compute-<hash>`, key `novacompute.conf`, owned by the NovaComputeNode,
   **immutable**) is stale and won't regenerate mid-eviction. Recreate it with the
   line added under `[libvirt]` and restart the pod:

   ```sh
   # dump, edit, recreate the immutable secret (mutable), then restart the pod
   kubectl get secret <sec> -n yaook -o jsonpath='{.data.novacompute\.conf}' | base64 -d > /tmp/n.conf
   sed -i '/^hw_disk_discard = unmap$/a remote_filesystem_transport = rsync' /tmp/n.conf
   kubectl delete secret <sec> -n yaook          # immutable → must delete+recreate
   # recreate with the SAME name/labels/ownerReferences (see live yaml) and the new data
   kubectl delete pod nova-compute-<hash>-0 -n yaook   # StatefulSet remounts the tmpfs
   ```

   Re-apply step 1's IdentityFile patch to the fresh pod.

3. **Reset ERROR'd VMs back to `active`** (the failed attempts + the pod restart
   dropping libvirt leave them `vm_state=error`, often with
   `task_state=resize_migrating` or "Connection to the hypervisor is broken").
   Use the admin `os-resetState` action (creds in the `keystone-admin` secret in
   ns `yaook`; run from a `nova-api` pod which can reach the internal keystone —
   the local `~/.config/openstack/clouds.yaml` points at leaf.cloud, NOT this
   cluster). POST `{"os-resetState":{"state":"active"}}` to
   `/servers/<id>/action`.

4. **Restart the eviction pod** (`kubectl delete pod compute-evict-<node>-*`) to
   clear the exponential backoff; the operator recreates it and retries
   immediately. Migrations then proceed (2 parallel; RESIZE→ACTIVE per VM). When
   the node is drained (0 VMs on it) the eviction completes; with
   `deleteNode: true` the operator recreates the NovaComputeNode fresh — its new
   compute config finally includes rsync, so bug 1 is durably fixed on that node
   (bug 2 still needs the step-1 live-patch on the fresh pod).

Once all VMs are off and every node is back `Updated/Success/Enabled`, confirm
`nova-compute` services are `up` (nova `os-services`) and no VMs remain on the
drained host (`servers/detail?all_tenants=1&host=<node>`).

#### OVN control plane must not be BestEffort (openstack cluster)

**2026-07-26.** Every OVN pod — NB ovsdb, SB ovsdb, the SB relay, `ovn-northd`
and the per-node `ovn-controller`/`ovs-vswitchd` — shipped with `resources: {}`,
i.e. QoS **BestEffort**, i.e. cgroup v2 `cpu.weight` of **1** (the minimum). On
these hyperconverged hosts they therefore lose every scheduling contest against
the Ceph OSDs (which DO request 2 CPU / 5Gi) and the tenant qemu processes.

With `lucy` at **load average 69 on 12 cores** (69/37/20 over 1/5/15min) this
collapsed the whole logical network:

1. `ovsdb-server` is single-threaded and latency-critical. Starved, it could not
   answer even a **local unix-socket** appctl — a manual
   `ovs-appctl cluster/status OVN_Northbound` hung for **>120s**.
2. The ovsdb **liveness probe is that exact command**, with a 20s timeout. It
   failed, so kubelet killed the container.
3. The rejoining member had to replay ~3.9k uncommitted raft entries
   (`Log: [285404, 289300]`), costing more CPU, so the probe failed again —
   a probe-induced death spiral. Restart counts reached nb-2=**12**, sb-2=**21**.
4. Quorum was never reached: NB sat at `Role: candidate`, `Term: 676`,
   `Leader: unknown`, peers unheard for **167s**.
5. With no NB leader, `ovn-northd` could never attach — its log looped
   `clustered database server is not cluster leader; trying another server`
   across all three servers — so it failed its own probe and went 0/1.
   **northd is the visible symptom, never the cause: always check NB raft first
   with `ovs-appctl -t /run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound`.**
6. No logical-network change could compile into the dataplane, so Neutron could
   not bind ports and **new VMs failed to boot** (no vif-plugged event).

**Tuning the raft timers is not sufficient and does not substitute for this.**
The earlier `raftElectionTimerMs: 60000` fix applied correctly (status showed
`Election timer: 60000`) yet peers were still unheard for ~3x that window. You
cannot tune your way out of a process that cannot get scheduled.

Fix: `resources` on every component in `infrastructure/yaook/neutron.yaml`
`setup.ovn`. **No CPU limits** (CFS throttling of a single-threaded raft or
dataplane process destroys tail latency — same rationale as the Ceph daemons);
CPU _requests_ cost nothing on an idle node and only bind under contention,
which is exactly when OVN must win. Memory limits are ~100x observed RSS as a
runaway backstop, **except `ovs-vswitchd` which is deliberately left unlimited**
because an OOM-kill there severs the entire node's dataplane.

**Unfixable declaratively:** the `NeutronDeployment` CRD exposes no
`priorityClassName`/scheduling field for these components, so they cannot be
marked `system-cluster-critical` the way the Ceph mons/mgr/osd are. Needs an
upstream yaook change.

**Rollout caveat:** applying the `controller.*` resources restarts
`ovs-vswitchd` on every node, which briefly interrupts the dataplane for all
tenant VMs. The control-plane half (NB/SB/relay/northd) can be applied
independently and is safe to do first.

#### Monitoring: Prometheus OOM was cardinality, not tuning (mgmt cluster)

**2026-07-26.** The mgmt monitoring stack had two INDEPENDENT faults that look
alike from `kubectl get pods` but share no mechanism.

**(a) `mimir-ingester-0` CrashLoopBackOff was DISK, not memory.** The log is
explicit: `open /data/tsdb/anonymous/wal/00000256: no space left on device`.
The live PVC was a stale **2Gi** while the StatefulSet template already carried
5Gi. Fixed by expanding the PVC IN PLACE (`csi-cinder-sc-delete` has
`allowVolumeExpansion: true`), then deleting the pod so the filesystem resize
completes (the PVC sits at `FileSystemResizePending` until a pod restarts).

> **Do NOT "fix" this by raising `ingester.persistentVolume.size`.** A
> StatefulSet's `volumeClaimTemplates` are **immutable** — raising the value does
> not resize anything, it makes the Helm upgrade fail outright with
> `updates to statefulset spec for fields other than 'replicas' ... are
forbidden`, wedging the release. Expand the PVC; leave the chart value alone.

**(b) Prometheus OOM-looping with a 1Gi limit was CARDINALITY.** Measured:
**313,505 active head series**. A head costs ~2-4 KB/series, so 1Gi could only
ever OOM. The distribution is the whole story:

```
series by scrape job          top metrics by series
  255,986  apiserver  (82%)     39,260  etcd_request_duration_seconds_bucket
   31,832  kubelet               30,114  apiserver_watch_list_duration_seconds_bucket
   12,733  kube-state-metrics    28,570  apiserver_request_duration_seconds_bucket
    7,744  node-exporter         26,152  apiserver_watch_cache_read_wait_seconds_bucket
```

The apiserver is 82% of all series because this is a CAPI **management** cluster:
most apiserver metrics are per-(resource x verb x le) and the CRD count is large.
Dropping nine histogram families whole (`_bucket`+`_sum`+`_count`) plus genuinely
inert metrics (`kubernetes_feature_enabled` — a STATIC feature-gate list;
`apiextensions_openapi_v2/v3_regeneration_count`; six `apiserver_{storage,cache}_list_*`
families; kubelet `prober_probe_duration_seconds`) takes it to **~108,600, a 65%
cut**. `apiserver_request_total` is deliberately KEPT — `KubeAPIDown` and
error-rate alerting need it. The `kubeApiserverSlos`/`Burnrate`/`Histogram`
default rule groups are disabled to match, since they are built on the dropped
buckets and would otherwise be permanently empty.

**A memory limit alone is a CLIFF, not a safety net.** Go grows the heap until
the kernel SIGKILLs it, so the pod dies, replays the WAL, and dies again — an OOM
loop. `GOMEMLIMIT` (set to ~80% of the hard limit via
`prometheusSpec.containers[].env`) is a SOFT limit that makes the GC trade CPU
for memory instead of being killed. Also bound `remoteWrite.queueConfig.maxShards`:
unbounded shards are a hidden memory sink when the remote is slow, which turns
"Mimir is unhealthy" into "Prometheus OOMs".

Local retention is 6h on purpose — this Prometheus is a **shipper**, not a store;
Mimir owns retention via `compactor_blocks_retention_period`.

**Renovate silently changed the Mimir architecture.** Chart 6.x defaults BOTH
`kafka.enabled: true` and the templated `ingest_storage.enabled: true`, so the
major bump (`8f5ff7f`) switched Mimir onto the experimental Kafka-backed write
path and added a Kafka StatefulSet (+5Gi PVC) nobody asked for. Disabling it
needs **both** flags: `kafka.enabled: false` stops the StatefulSet, and
`mimir.structuredConfig.ingest_storage.enabled: false` stops Mimir trying to
produce to a broker that no longer exists. Check `helm show values` on major
chart bumps for defaults that change topology.

#### PowerDNS/Galera must not be BestEffort → `rpcu.lan` SERVFAILs cluster-wide (openstack cluster)

**2026-07-26.** The openstack cluster was completely absent from the central
Grafana. Root cause chain, from symptom to origin:

1. Its Prometheus could not remote_write:
   `"dial tcp: lookup mimir.mgmt.rpcu.lan on 10.96.0.10:53: no such host"`.
2. Nothing on the cluster could resolve `*.rpcu.lan` — CoreDNS forwards `.` to
   `/etc/resolv.conf`, which on these hosts is Hetzner's public resolvers
   (185.12.64.1/2). Fixed in **hephaestus**, see below.
3. But even the correct resolver was broken: PowerDNS (authoritative for the
   Designate `rpcu.lan` zone, LB `10.0.0.241`) answered **SERVFAIL** —
   intermittently, which is why `rpcu.lan` "worked, then didn't, then worked".

The SERVFAIL was **not** an ACL or a Cilium LB problem (both were ruled out by
querying the PowerDNS pod IP directly). The log is explicit:

```
Backend error: Unable to launch gmysql connection: Unable to connect to database:
ERROR 2013 (HY000): Lost connection to MySQL server at 'handshake...'
```

`designate-powerdns-powerdns-db-0` was `5/6 Terminating` with **18 restarts** in
47h, its `ssl-terminator` failing readiness (`connect: connection refused` on
:9101). Every container in that stack ran `resources: {}` → QoS **BestEffort** →
cgroup v2 `cpu.weight` of 1, on a node (`lucy`) sitting at **91% CPU**. Measured
usage was tiny (galera 51m CPU / 301Mi, haproxy 160Mi) — the problem was never
capacity, it was **priority**.

This is the SAME failure mode as "OVN control plane must not be BestEffort"
above, and it will keep recurring in other yaook components until they all carry
requests. When a yaook service misbehaves, **check `.status.qosClass` before
anything else**.

Fix: `resources` on `powerdns.database` and `powerdns.database.proxy` in
`infrastructure/yaook/designate.yaml`. No CPU limits (throttling a DB re-creates
the probe-timeout death spiral); memory limits are a ~5-7x runaway backstop.

**Blast radius when applying:** editing the DesignateDeployment restarts the
single-replica (`replicas: 1`) Galera pod, so `rpcu.lan` resolution drops for
the duration. Do it deliberately, not alongside other changes.

**Still unfixable declaratively:** the CRD exposes no `resources` for the
PowerDNS _server_ pod, nor for the Galera pod's `ssl-terminator` — the very
container whose probe failed. Fixing the DB removes the trigger; closing the gap
needs an upstream yaook change.

#### All yaook database pods must not be BestEffort (openstack cluster)

**2026-07-30.** Every yaook OpenStack service has a `database` sub-section in its
Deployment CR that defines a Galera cluster + proxy sidecars (haproxy,
`service-reload`, `create-ca-bundle`). Every one of these pods shipped with
`resources: {}` → QoS **BestEffort** → cgroup v2 `cpu.weight` of **1** — the
minimum. On hyperconverged nodes shared with Ceph OSDs and tenant qemu
processes, the readiness probe (`ssl-terminator` connecting to the Galera port)
would fail under CPU contention → kubelet restarts the pod → intermittent
database connectivity for the OpenStack control plane.

This is the same failure mode as "OVN control plane must not be BestEffort"
(2026-07-26) and "PowerDNS/Galera must not be BestEffort" (same date). The
PowerDNS note diagnosed the problem in detail; this is the fleet-wide fix.

Fix: `resources` on every Galera + proxy sidecar in **all 9 database
sub-sections** across 7 CRs:

| CR        | databases                                        | status             |
| --------- | ------------------------------------------------ | ------------------ |
| keystone  | `database`                                       | fixed              |
| glance    | `database`                                       | fixed              |
| neutron   | `database`                                       | fixed              |
| nova      | `database.api`, `.cell0`, `.cell1`, `.placement` | fixed              |
| cinder    | `database`                                       | fixed              |
| octavia   | `database`                                       | fixed              |
| designate | `database`                                       | fixed              |
| designate | `powerdns.database`                              | fixed (2026-07-26) |

Resource values: `mariadb-galera` 200m CPU / 512Mi req / 2Gi limit;
`haproxy` 50m / 192Mi req / 512Mi limit; `service-reload` and
`create-ca-bundle` 10m / 32Mi req / 64Mi limit. **No CPU limits** anywhere —
throttling a DB re-creates the probe-timeout death spiral (same rationale as
the OVN and Ceph daemons). Memory limits are a ~5-7x runaway backstop.

**Still unfixable declaratively:** the CRD exposes no `resources` for the
Galera pod's `ssl-terminator` sidecar (the container whose readiness probe
fails). Fixing the DB and proxy removes the trigger; closing the gap needs an
upstream yaook change. Also no `priorityClassName` for these pods, so they
cannot be marked `system-cluster-critical`.

#### kubelet metricRelabelings are PER-ENDPOINT — a rule in the wrong list silently never fires

**2026-07-26.** The monitoring base carried a rule dropping
`prober_probe_duration_seconds_*`, and AGENTS.md recorded it as dropped. It was
**still being ingested** — 12,960 series on the openstack cluster, 6.5% of the
entire head.

The kubelet ServiceMonitor scrapes THREE endpoints, and kube-prometheus-stack
exposes a SEPARATE relabeling list for each:

| endpoint            | chart value                 | series (openstack) |
| ------------------- | --------------------------- | ------------------ |
| `/metrics`          | `metricRelabelings`         | 16,238             |
| `/metrics/cadvisor` | `cAdvisorMetricRelabelings` | 82,526             |
| `/metrics/probes`   | `probesMetricRelabelings`   | 16,550             |

The rule sat in `metricRelabelings` (i.e. `/metrics`) while the metric is served
by `/metrics/probes`. Prometheus does not warn about a relabel rule that matches
nothing, so this fails **completely silently**. Verify with:

```promql
count by (metrics_path) ({job="kubelet"})
count by (endpoint,metrics_path) (<the metric you think you dropped>)
```

**Setting any of these lists REPLACES the chart's defaults wholesale.** The
chart ships seven non-trivial cAdvisor rules (including `container_spec.*` and
the per-interface `container_network_.*` drops); omitting them while "adding" a
drop rule INCREASES cardinality. The base now reproduces all seven verbatim
above an `--- additions ---` marker.

cAdvisor cost scales with container count, not with anything anyone queries: it
emitted ~45 families per container to support the **two** the dashboards and
chart alerts actually use (`container_cpu_usage_seconds_total`,
`container_memory_working_set_bytes`). The additions drop per-device blkio/fs,
the six PSI families, cgroup memory internals, process/task accounting and
non-byte network counters — together with the probes fix, ~76,000 series (**-38%**).
When dropping a metric, also disable any default rule group built on it
(`k8sContainerMemory{Cache,Swap}` here) or you leave a permanently empty
recording rule.

#### yaook ServiceMonitors are invisible to kube-prometheus-stack by default (openstack cluster)

**2026-07-26.** The yaook operators generate **92 ServiceMonitors + 1
PodMonitor** in the `yaook` namespace. **Zero** of them were being scraped, so
the cluster produced no OpenStack metrics at all — because the chart's default
`serviceMonitorSelector` is `matchLabels: {release: kube-prometheus-stack}` and
no yaook-generated monitor carries that label.

A LabelSelector ANDs its terms, so "release=X OR yaook-component=Y" is not
expressible. The workaround in `clusters/openstack/monitoring.yaml` is an
**exclusion** expression: `NotIn` matches objects whose value is not listed AND
objects that lack the label entirely, so kube-prometheus-stack's own monitors
(no `state.yaook.cloud/component` label) keep matching while yaook's are
filtered by component. **This is allow-by-default** — anything new is scraped
unless added to the list, so re-check the cardinality budget when adding
operators.

Kept (~32 monitors, ~30k series): `mysql_service_monitor` (Galera),
`amqp_service_monitor` (RabbitMQ — the OpenStack RPC bus), `ovsdb`/`ovn_relay`,
the OVN PodMonitor, and the yaook operators. Excluded (60): the 14 `*_ssl_*`
cert-expiry probes, `haproxy`, `mysql_backup`, `replication_ports`, `memcache`.

Two things that are NOT obstacles, despite appearances:

- **Cross-namespace TLS secrets work.** The yaook monitors scrape HTTPS with
  per-service CA secrets in the `yaook` namespace. prometheus-operator resolves
  a ServiceMonitor's `tlsConfig` secrets from the **ServiceMonitor's own**
  namespace and mounts them as
  `/etc/prometheus/certs/0_yaook_<secret>_tls.crt`. No secret copying needed —
  verified live (`health=up`).
- **Prometheus had headroom** only after the cAdvisor trim above: it was at
  1352 MiB RSS against a **1536Mi limit** (86%), so adding ~30k series without
  first removing ~76k would have OOM-looped it. Note `kubectl top` reported
  2632Mi for this pod — it is **wrong**; trust
  `container_memory_working_set_bytes` / `process_resident_memory_bytes`.

**Two upstream yaook bugs found while doing this**, both meaning the metrics do
not exist no matter how you configure Prometheus:

1. The OVN `PodMonitor` references container ports named `prometheus` and
   `ovs-vswitchd-metrics`, but the pods actually expose `metrics` (8008) and
   `ovs-metrics` (8007) → it selects **no targets**.
2. The `ovsdb`/`ovn_relay` ServiceMonitors point at the **traefik
   ssl-terminator** sidecar, so they yield `traefik_*`/`go_*`/`process_*`, not
   OVN state. The only genuine OVS metrics on the whole cluster are `socket_up`
   and `flow_limit` (port 9999/8008).

There is also **no `openstack_*` semantic data** (nova hypervisors, VM counts,
quotas) anywhere — that needs prometheus-openstack-exporter, which is not
deployed. Do not write dashboard panels against those names.

#### kube-state-metrics customResourceState for Flux CRDs

The official Flux monitoring approach (since Flux v2.1.0 / August 2023) uses
kube-state-metrics with `customResourceState` to generate `gotk_resource_info`
metrics for all Flux CRDs. This provides `ready`/`suspended`/`revision` labels
that enable direct status queries like `gotk_resource_info{ready="False"}` —
the same information the `kubectl get kustomizations` READY column shows.

The kube-prometheus-stack HelmRelease
(`infrastructure/monitoring/helmrelease.yaml`) enables this under
`kubeStateMetrics.customResourceState` with RBAC rules granting KSM
`list`/`watch` on all Flux CRD groups (`kustomize.toolkit.fluxcd.io`,
`helm.toolkit.fluxcd.io`, `source.toolkit.fluxcd.io`,
`notification.toolkit.fluxcd.io`, `image.toolkit.fluxcd.io`). The config
defines resource mappings for Kustomization, HelmRelease, GitRepository,
HelmRepository, HelmChart, OCIRepository, and Bucket — each emitting a
`gotk_resource_info` Info metric with labels including `name`,
`exported_namespace`, `ready`, `suspended`, `revision`, and kind-specific
fields (`source_name`, `chart_name`, `url`, etc.).

**RBAC note**: The Flux CRD rules live under `kube-state-metrics.rbac.extraRules`
(top-level subchart path), NOT under `customResourceState.rbac.extraRules`.
Some kube-state-metrics chart versions silently ignore the nested path, so the
rules never reach the ClusterRole — causing KSM errors like `cannot list resource
"buckets" in API group "source.toolkit.fluxcd.io"`. The top-level `rbac.extraRules`
adds rules to the main kube-state-metrics ClusterRole which is always bound to
the SA.

**Cardinality note**: KSM custom resource state emits one series per Flux CR
per label combination. With ~200 Flux CRs across mgmt + openstack clusters,
this adds ~200-400 series — negligible against the existing ~150k head.

**Dashboard and alerts**: `infrastructure/grafana/dashboards/fluxcd-dashboard.yaml`
uses `gotk_resource_info` for the Status row tables (Reconciler Readiness,
Source Readiness, Suspended Objects) with Ready/Not Ready color coding.
`infrastructure/grafana/alerting/rules-flux.yaml` adds
`FluxResourceNotReady` (critical, `gotk_resource_info{ready="False"}`) as a
direct KSM-based signal, alongside the existing controller-metric-based rules
(errors, timeouts, stale resources).

Reference: [Flux custom Prometheus metrics](https://fluxcd.io/flux/monitoring/custom-metrics/),
[flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example).

#### cert-manager monitoring was invisible until August 2026

The cert-manager Helm chart (v1.21.1) exposes Prometheus metrics on port 9402
by default, but they were never scraped. Without scraped metrics, no
cert-manager alert could fire — a certificate expiring tomorrow would produce
zero signal, and the cert-manager dashboard is permanently blank.

**Two-part fix — `prometheus.enabled: true` alone is NOT enough.** The first
attempt set only `prometheus.enabled: true` in
`infrastructure/cert-manager/values.yaml`; the dashboard/alerts still had no
data. Verified live: the metric `certmanager_certificate_expiration_timestamp_seconds`
returned ZERO series from Mimir, and there was **no ServiceMonitor** in the
`cert-manager` namespace despite the HelmRelease having upgraded successfully.
The chart's `prometheus.enabled: true` ONLY adds `prometheus.io/*` scrape
annotations to the cert-manager Deployments — it does **NOT** create a
ServiceMonitor (the chart comment says so explicitly), and kube-prometheus-stack
does not honour pod scrape annotations. The ServiceMonitor is a **separate
sub-toggle** that defaults to `false`:

```yaml
prometheus:
  enabled: true
  servicemonitor:
    enabled: true # REQUIRED — without this no ServiceMonitor exists
    labels:
      release: kube-prometheus-stack # REQUIRED on mgmt — see below
```

The `labels: {release: kube-prometheus-stack}` is the second half of the fix.
The **mgmt** Prometheus `serviceMonitorSelector` is
`matchLabels: {release: kube-prometheus-stack}` (NOT the openstack cluster's
allow-all `NotIn` selector), so a ServiceMonitor without that label is silently
never scraped on mgmt. `values.yaml` is a shared base, but the label is harmless
on openstack (its `NotIn` selector matches anything lacking a
`state.yaook.cloud/component` label). Because the `cert-manager-values`
ConfigMap uses `disableNameSuffixHash: true`, the helm-controller re-renders on
the ConfigMap content change and creates the ServiceMonitor on the next
reconcile.

Key metrics now available in Mimir:

- `certmanager_certificate_expiration_timestamp_seconds` — NotAfter Unix
  timestamp per certificate (labels: `namespace`, `name`, `issuer_kind`,
  `issuer_name`). Used for expiry alerts.
- `certmanager_certificate_not_before_timestamp_seconds` — NotBefore (issuance)
  Unix timestamp per certificate. Used with the above to compute total
  certificate lifetime for percentage-based expiry alerts.
- `certmanager_certificate_ready_status{condition="True"}` — 1/0 per
  certificate. Used for not-ready alerts.

Three alert rules in `infrastructure/grafana/alerting/rules-certmanager.yaml`:

- `CertManagerCertificateExpiringCritical` (critical, <10% lifetime remaining)
- `CertManagerCertificateExpiringWarning` (warning, <20% lifetime remaining)
- `CertManagerCertificateNotReady` (warning, 15m for Ready=False)

Expiry rules use **percentage-of-lifetime** thresholds, not fixed day counts.
This avoids false alerts on short-lived certs (e.g. 72h certs that would fire a
30d warning immediately). The percentage is computed as
`(remaining / total_lifetime) * 100` where `total_lifetime = not_after - not_before`.
Example: 72h cert fires critical at ~7.2h, warning at ~14.4h; 90d cert fires
critical at ~9d, warning at ~18d.

On mgmt the ServiceMonitor MUST carry `release: kube-prometheus-stack` (the
mgmt `serviceMonitorSelector`); on openstack its allow-by-default `NotIn`
selector matches it regardless (the label is harmless there). Setting the label
in the shared `values.yaml` therefore gets it scraped on every cluster.

#### kube-apiserver CPU is TLS-handshake bound, not request-volume bound

**2026-07-29.** The openstack cluster's three kube-apiservers each burn ~2 cores
(~6 cores total) and 4-6.7 GiB RAM, which looks alarming but is NOT a request
storm. Measured live: `apiserver_current_inflight_requests` was only **2-3**
(mutating + readOnly) and the total request rate ~10 req/s. Object counts are
modest (top is 396 events, 372 CRDs; no resource has a pathological count).

The driver at low request volume is the **per-connection TLS handshake**
(asymmetric crypto), amplified by two things specific to this cluster:

1. **RSA-2048 control-plane keys** (kubeadm default; the live kubeadm-config CM
   shows `encryptionAlgorithm: RSA-2048`). An RSA-2048 handshake is ~5-10x more
   CPU server-side than ECDSA-P256. With 226 pods, 13 yaook operators, Cilium
   per-node agents, Flux, Crossplane and ESO each opening/refreshing mTLS
   connections, handshake CPU dominates.
2. **Baremetal CPU contention** — lucy/quinn sit at 89-97% CPU (shared with Ceph
   OSDs + nova VMs), so the apiserver's work is both slower and accounted at a
   higher cost than on the mgmt VMs, whose apiservers idle at 100-320m.

**Fix: switch control-plane keys RSA-2048 → ECDSA-P256.** The openstack cluster
is baremetal and bootstrapped from the **hephaestus** repo, NOT argus — the knob
lives in `nixosModules/rpcuIaaSCP/confs/kubeadm-bootstrap.nix`
(`encryptionAlgorithm: ECDSA-P256`, which also required migrating that file from
kubeadm `v1beta3` to `v1beta4` — the field does not exist in v1beta3 — and
converting `apiServer.extraArgs` from the v1beta3 map form to the v1beta4 list
form). The CAPI-managed clusters (mgmt + kubeadm workload) get the same via
`openstack-default-control-plane-v3` here. **`encryptionAlgorithm` only affects
certs generated at `kubeadm init`/cert renewal**, so the already-running
clusters keep their RSA certs until a cert rotation (`kubeadm certs renew all` +
restart the control-plane static pods on each baremetal node) or a
machine/control-plane roll (CAPI). Kamaji tenant control planes are unaffected
(Kamaji manages its own cert keys; its tenant apiservers are not CPU-stressed at
47-100m).

**Measurement caveat that cost time here:** `authentication_attempts` and other
cumulative counters are **per-apiserver-process**. `kubectl get --raw /metrics`
is load-balanced across the 3 replicas, so subtracting two scrapes can land on
different processes and produce garbage rates (a spurious "108k auth/s storm" on
mgmt was entirely this artifact — mgmt is healthy). Use **gauges**
(`apiserver_current_inflight_requests`, `go_goroutines`) for instantaneous state,
and only trust counter _rates_ when pinned to a single instance.

#### Node resilience: MachineHealthCheck + kubelet reservations

**2026-07-26.** Two gaps made a single sick node escalate into a cluster-wide
incident (worker `mgmt-md-0-285vl-xqztp-jz5cb` went `Ready=Unknown` with
"Kubelet stopped posting node status" and stayed that way):

1. **There was NO `MachineHealthCheck` anywhere in the repo**, so an unreachable
   node was never remediated. Deployment Pods taint-evict and reschedule, but
   every **StatefulSet** Pod on the node stays stuck `Terminating` FOREVER — a
   StatefulSet cannot create a replacement while the old Pod is
   unreachable-but-not-deleted (at-most-one semantics). Prometheus, the Mimir
   ingester, Vault and kamaji-etcd were all wedged this way, and 48 Pods total
   were stranded. Deleting the Machine is the only action that removes the Node
   object and releases them. All four ClusterClasses now define `healthCheck`
   (workers: remediate after 300s, `unhealthyLessThanOrEqualTo: 40%`,
   `maxInFlight: 1`; kubeadm control planes: 600s and
   `unhealthyLessThanOrEqualTo: 1`). NOTE `maxInFlight` is **workers-only** in
   the ClusterClass schema — the API rejects it under `controlPlane`.
   `healthCheck` is a ClusterClass field, not part of the immutable templates,
   so adding it to the legacy `-v1` classes does **not** roll their Machines.
2. **The kubelet ran with upstream defaults**: no `--kube-reserved` /
   `--system-reserved` (so Allocatable == Capacity and Pods may commit 100% of
   the node), and the default `--eviction-hard=memory.available<100Mi` which is
   far too tight to beat the kernel OOM killer. Observed memory-LIMIT overcommit
   on the 4 vCPU / 8 GiB workers was **209%**. The `-v2` templates set
   reservations and wider eviction thresholds; since
   `--enforce-node-allocatable` defaults to `pods`, this genuinely caps the
   `kubepods` cgroup so Pods OOM inside their own cgroup instead of taking the
   kubelet down with them.

Contributing factor worth watching: the VMs are packed unevenly across
hypervisors — `lucy` was at **load average 41** on 12 cores (6 VMs) and `quinn`
at 32 on 8 cores (5 VMs), while `makise` sat at load 2.5 with **zero** VMs. Nova
does not rebalance existing instances, so this is historical placement, not a
live scheduler bug; new/replaced VMs should land on `makise`. Do **not** "fix"
it by editing `compute.configTemplates[].novaComputeConfig` — that makes the
operator flag every `NovaComputeNode` `RequiresRecreation` and start a rolling
eviction, which is broken on this cluster (see the nova cold-migration note).

#### Tenant MTU: `path_mtu` is 1342 so VMs get 1284 (measured, do NOT raise)

**2026-07-26.** `ml2.path_mtu` is **1342**, giving tenant VMs `1342 − 58` =
**1284**. It was previously 1400 (→ VMs got 1342), which was **58 bytes too big
for the north-south path** and was the true cause of the recurring
`net/http: TLS handshake timeout` on image pulls and the long-standing "flaky
etcd / works after a retry" symptoms.

Neutron derives a geneve network's MTU as
`min(global_physnet_mtu, path_mtu) − 58`, so **`path_mtu` — not
`global_physnet_mtu` — is the knob that sets the tenant VM MTU.**

Measured with DF pings (`ping -M do -s <payload>`, totalIP = payload+28):

| path                                         | largest totalIP that passes |
| -------------------------------------------- | --------------------------- |
| underlay, hypervisor↔hypervisor (eno1.4000) | **1400** OK                 |
| tenant east-west, VM→VM                      | **1342** OK, 1358 drops     |
| tenant north-south, VM→internet (OVN SNAT)   | **1284** OK, 1292 drops     |

East-west at 1342 is correct (1342 + 58 geneve = 1400 = the vSwitch limit,
exactly). So Neutron **advertised 1342 while only 1284 got through**.

> **CORRECTION (2026-07-26, later).** The original diagnosis below — that
> north-south crossed the OVN distributed gateway port and that with
> `ovn_emit_need_to_frag: True` OVN reserved a further tunnel header there — was
> **WRONG**, and so was the "NOT a Cilium problem" conclusion. It is **Cilium**,
> it is **not OVN**, and it hits **east-west identically** (a gateway-port
> reservation could not do that). See "Cilium auto-MTU inherits `br-int`" below.
> Lowering `path_mtu` to 1342 therefore did **not** fix anything — it moved the
> black hole from 1342/1284 down to 1284/1226, preserving the 58-byte deficit
> exactly. Keep `path_mtu: 1342`, but the actual fix is the Cilium `MTU` pin in
> `clusters/openstack/cilium.yaml`.

TCP then depended entirely on PMTUD, which fails silently wherever ICMP
frag-needed is filtered. Measured from a mgmt worker, IPv4, 10 TLS handshakes:

```
registry.k8s.io   ok=10 fail=0    (ICMP honoured; PMTU cache learned 1284)
ghcr.io           ok=10 fail=0    (ICMP honoured; PMTU cache learned 1284)
xpkg.upbound.io   ok=0  fail=10   (ICMP filtered -> HARD BLACK HOLE)
```

The same 10 handshakes from the **hypervisor** host netns (MTU 1500, no geneve)
were `ok=10 fail=0`, proving the internet path is healthy and the loss is purely
the tenant-MTU overshoot. A TLS ServerHello+Certificate is several full-MSS
segments, so it is the first thing to hit the black hole while the tiny SYN/ACK
sail through.

Diagnostic tells, in order of usefulness:

- `ip -4 route show cache` on a VM showing `mtu 1284` on external destinations
  while `ip link` says the NIC is 1342 — the kernel is silently papering over
  the misconfiguration, one stall per new destination IP.
- A DF ping that fails with **no ICMP and no local error** (pure `100% packet
loss`) is a REMOTE silent drop. If it fails with `sendmsg: Message too long`
  that is a LOCAL EMSGSIZE, i.e. just the NIC/route MTU — a different problem.

**This is NOT a vSwitch problem** — hephaestus
`nixosModules/vlanConfiguration.nix` keeps `eno1.4000` at **1400**, which is
correct per Hetzner's vSwitch docs. The underlay genuinely carries 1400: proven
with `ping -M probe` (which BYPASSES the PMTU cache) and with a plain DF ping
after `sysctl -w net.ipv4.route.flush=1`, both passing at totalIP 1400
hypervisor-to-hypervisor. Do not lower it, and do NOT raise it (see jumbo below).

#### Cilium auto-MTU inherits `br-int` and poisons the underlay PMTU (openstack cluster)

**2026-07-26, ROOT CAUSE of the above.** Cilium sets no explicit `MTU`, so it
**auto-detects it as the MINIMUM MTU across its attached `--devices`**. This
cluster attaches `br-int` (`clusters/openstack/cilium.yaml`), and OVN sizes
`br-int` to the **tenant** network MTU. So Cilium adopted the tenant MTU as its
**host** MTU. Observed on lucy:

```
br-int = 1284    cilium_host = 1284    cilium_vxlan = 1284
devices: eno1.4000 (1400), br-ex (1500), br-int (1284)
enable-pmtu-discovery = true ; packetization-layer-pmtud-mode = always
```

With `packetizationLayerPMTUDMode: always` Cilium's BPF **actively emits ICMP
frag-needed at its MTU** — and it does so for ORDINARY HOST traffic on the
underlay, nothing to do with tenants. Captured on `eno1.4000`:

```
10.0.0.2 > 10.0.0.4: ICMP need to frag (mtu 1284)  inner: 10.0.0.4.6443  > 10.0.0.2  (kube-apiserver)
10.0.0.3 > 10.0.0.4: ICMP need to frag (mtu 1284)  inner: 10.0.0.4.10250 > 10.0.0.3  (kubelet)
```

Each hypervisor therefore caches PMTU **1284** for its peers (re-poisons within
**15 s** of a cache flush; `net.ipv4.route.min_pmtu` is the default 552, so
nothing stops it). Geneve then has only `1284 − 58` = **1226** for tenant
payload while Neutron advertises **1284** over DHCP → a 58-byte silent black
hole in **both** directions.

**It is a FEEDBACK LOOP, which is why tuning `path_mtu` can never fix it:**

```
path_mtu -> br-int -> Cilium auto-MTU -> ICMP needs-frag -> underlay PMTU -> geneve -58
```

The advertised tenant MTU is itself what sets the poison, so usable is ALWAYS
`advertised − 58`:

|                  | advertised | usable | deficit |
| ---------------- | ---------- | ------ | ------- |
| before `dfe2403` | 1342       | 1284   | 58      |
| after `dfe2403`  | 1284       | 1226   | **58**  |

**Fix:** pin `MTU: 1400` in the openstack Cilium patch
(`clusters/openstack/cilium.yaml`). Cilium then reports the truth, the underlay
stays 1400, and geneve yields 1342 vs 1284 advertised = **58 bytes of headroom**.
`path_mtu: 1342` becomes correct and should stay. mgmt needs no pin (no `br-int`).

Do **not** "fix" it by removing `br-int` from `--devices` — that breaks
OpenStack VM connectivity (see "Cilium `--devices` must include the OVN bridges"
above). Pinning keeps br-int attached and only stops Cilium inheriting its MTU.

**Symptom signature:** TCP connects fine (`nc -z` succeeds, tiny SYN/ACK) but
TLS never completes (`net/http: TLS handshake timeout`, `curl` shows
`tls=0.000000` even after 30 s) — the multi-segment ServerHello/Certificate is
the first thing to hit the hole. Confirm by comparing a path that stays inside
the tenant network against one that does not: LB VIP east-west was **20/20 OK**
while the same service via its floating IP was **0/20**.

**Rollout:** Neutron fixes a port's MTU at CREATION time. Existing VMs keep 1342
until their ports are recreated (roll the machines via CAPI). Stopgap on a
running VM: `ip link set dev enp3s0 mtu 1284`.

**External clients (VPN/laptop).** The same black hole applies inbound to any
floating IP. A netbird/WireGuard client at `wt0` MTU 1280 still failed because
the tunnel adds ~60 B of encapsulation on top, overshooting the usable ceiling.
Stopgap until the Cilium pin is rolled out:
`sudo ip route replace <floating-ip> dev wt0 mtu 1200`.

---

Historical context (why 1400 rather than jumbo) follows.

Why 1400 and not jumbo (9000): the underlay is not jumbo-clean end to end. On
the hephaestus hosts the Hetzner vSwitch VLAN `eno1.4000` is capped at 1400 and
`br-ex`/`eno1` default to 1500. A previous attempt set `enp3s0` and Neutron to
9000; VMs then emitted oversized frames that black-holed at the first 1500/1400
hop. Symptoms (on the CAPI mgmt cluster running as tenant VMs): flaky etcd
(`addrConn.createTransport failed ... 127.0.0.1:2379 ... operation was
canceled`) and intermittent `TLS handshake timeout` pulling images from
ghcr.io — both "works after a retry," the classic MTU black-hole signature.

The host side of this change lives in the hephaestus repo: `enp3s0` was reverted
from MTU 9000 back to the default 1500 in
`nixosModules/rpcuIaaSCP/osconfig.nix`. Keep the two repos in sync — if you
change the Neutron MTU here, update `enp3s0`/host MTUs there (and vice versa).

Rollout caveat: Neutron sets port MTU at port-creation time. Existing running
VMs (current mgmt nodes) keep their old MTU until their ports are recreated —
rolling-replace the mgmt machines via CAPI to pick up 1362, or set the VM NIC
MTU manually (`ip link set dev <iface> mtu 1362`) as a stopgap to verify the
fix. Cilium auto-detects MTU from the device, so its inner overlay sizes itself
below the corrected VM MTU automatically.

#### Cilium 1.19 `packetizationLayerPMTUDMode: blackhole` silently drops cross-node TCP (all clusters)

Cilium Helm chart **1.19.x** introduced a new default:
`pmtuDiscovery.packetizationLayerPMTUDMode: "blackhole"`. This did not exist
in 1.18.6. With `blackhole` mode, Cilium's BPF program silently drops any
**inner** packet that exceeds the route MTU — no ICMP, no TCP PMTU discovery,
just a timeout.

The mismatch is structural: pod `eth0` MTU = `cilium_vxlan` MTU (auto-detected
from physical NIC = 1342), but the host route to remote pod CIDRs has
MTU = 1342 − 50 (VXLAN overhead) = **1292**. Pod TCP MSS = 1342 − 40 = **1302**,
which is 10 bytes larger than the route MTU. Every cross-node TCP segment

> 1292 bytes gets blackholed.

Impact: TCP SYN/ACK (~60 bytes) always works. TLS handshakes (multi-segment
ServerHello/Certificate ~1200 bytes each) always fail cross-node from regular
pods. Same-node and host-network pods are unaffected (no VXLAN path).

Fix (PR #405): set `pmtuDiscovery.enabled: true` +
`packetizationLayerPMTUDMode: "always"` in `infrastructure/cilium/values.yaml`
and `infrastructure/sveltos/clusterprofiles/cilium.yaml`. `always` makes BPF
send ICMP "fragmentation needed" back to the pod, triggering TCP PMTU
discovery. The pod reduces its MSS to 1252 (fitting the 1292 route MTU).

**When upgrading Cilium charts**: always check `helm show values` for new
defaults under `pmtuDiscovery` — a new `packetizationLayerPMTUDMode` default
can silently break all cross-node TLS without any error in logs.

#### Crossplane DeploymentRuntimeConfig is `pkg.crossplane.io/v1beta1`, not `v1`

The Crossplane provider resource caps live in a `DeploymentRuntimeConfig`
(`infrastructure/crossplane-{vault,openstack,zitadel,providers}`, referenced by
`spec.runtimeConfigRef` on each `Provider`). The `Provider` and
`ClusterProviderConfig` kinds are `pkg.crossplane.io/v1`, but
**`DeploymentRuntimeConfig` is served at `pkg.crossplane.io/v1beta1`** (verify:
`kubectl get deploymentruntimeconfig default -o jsonpath='{.apiVersion}'`).
Using `v1` makes the Flux Kustomization fail its server dry-run with
`no matches for kind "DeploymentRuntimeConfig" in version "pkg.crossplane.io/v1"`,
which cascades: `crossplane-zitadel` → `crossplane-resources` →
`grafana-alerting` + `chihiro` all go `Ready=False` on the dependency. Keep the
`DeploymentRuntimeConfig` docs on `v1beta1`; only the `Provider` doc is `v1`.

#### Grafana ALERT rules must NOT use `$cluster` — it's a dashboard-only variable

**2026-08-01.** Every Flux resource on mgmt was `Ready=False` (crossplane chain
broken) yet **no Discord alert fired**. Root cause: `rules-flux.yaml` was the
only alert file whose PromQL carried a `cluster=~"$cluster"` selector, copied
from the dashboard queries. **Grafana alert rules have NO dashboard template
variables** — `$cluster` is substituted only in dashboard panels; in an alert
query it stays LITERAL, so `cluster=~"$cluster"` matches zero series. Every Flux
rule therefore returned empty → evaluated `NoData` → and with `noDataState: OK`
(the deliberate "don't fire the world if Mimir breaks" choice) the alert was
silently suppressed and never fired. The rule `health` shows `ok` and
`lastEvaluation` is current, which makes it look fine — the tell is the alert
instance stuck at `state: Normal (NoData)`.

Diagnose via the Grafana API (not just the CR status, which shows
`ApplySuccessful`): `GET /api/prometheus/grafana/api/v1/rules` and look at each
rule's `alerts[].state`. `Normal (NoData)` on a rule you expect to be firing =
the query returns empty. Confirm by running the literal expression (with
`$cluster` unexpanded) against Mimir — it returns 0 series.

Fix: removed `cluster=~"$cluster"` from all 5 Flux expressions. The rules keep
`cluster` as an OUTPUT label via `by (cluster, ...)`, so per-cluster context is
preserved in the alert without the (broken) input selector. The other alert
files (`rules-node`, `rules-openstack`, `rules-pods`, `rules-storage`,
`rules-diskio`) never used `$cluster` and were unaffected. A prominent DO-NOT
comment now guards the top of `rules-flux.yaml`.

#### mgmt workload resource sizing: request≈usage, mem limit≈2×, CPU request-only

The mgmt workers ran at 75–82% memory with several top consumers as QoS
**BestEffort** (`resources: {}`). Sizing policy applied (from **72h Mimir
history**, max/P95 of `container_memory_working_set_bytes` and
`rate(container_cpu_usage_seconds_total[5m])`, `cluster="mgmt"`): **memory
request ≈ P95/current, memory limit ≈ 2× observed max, CPU request-only (NO CPU
limit)** — same rationale as the Ceph/OVN/DB daemons above (throttling a
controller's reconcile loop hurts tail latency; a CPU request costs nothing idle
and only binds under contention).

Non-obvious mechanics that matter here:

- **Crossplane providers get resources via a `DeploymentRuntimeConfig`**, NOT a
  field on the `Provider` CR. Each provider base
  (`infrastructure/crossplane-{vault,openstack,zitadel,providers}`) now ships a
  `pkg.crossplane.io/v1` `DeploymentRuntimeConfig` (same name as the provider)
  setting the `package-runtime` container resources, plus `spec.runtimeConfigRef`
  on the `Provider` pointing at it. These are **shared bases** — the change
  applies to BOTH the mgmt and openstack clusters (intended). Values: vault
  448Mi/896Mi/40m, openstack 384Mi/768Mi/40m, zitadel 256Mi/640Mi/30m, random
  128Mi/256Mi/20m (req/lim/cpu-req).
- **kube-state-metrics resources MUST go under the hyphenated `kube-state-metrics:`
  subchart key**, not the parent `kubeStateMetrics.resources` toggle (which is
  NOT applied to the pod — the live pod ran `resources: {}` despite that key
  being set). Fixed in `infrastructure/monitoring/helmrelease.yaml`
  (192Mi/384Mi/25m).
- **kgateway** controller was BestEffort; set the chart's top-level `resources:`
  in `infrastructure/kgateway/helmrelease.yaml` (192Mi/384Mi/20m). Shared base —
  applies to openstack too.
- **sveltos**: per-controller `resources` set in
  `infrastructure/sveltos/helmrelease.yaml` values for the components the chart
  exposes (`addonController.controller` 448Mi/1Gi/80m — it shipped with only a
  512Mi request and no limit; `accessManager`/`eventManager`/`classifierManager`/
  `hcManager`/`shardController`/`scManager` `.manager`). The chart's default
  512Mi mem limit was below several controllers' observed peaks. The
  **sveltos-agents** (`sveltos-agent-*`, ~488Mi) and `driftDetectionManager` do
  NOT expose a `resources` key in chart 1.12.7 and can't be tuned via values.

Left as-is (already tuned in the July monitoring incident): mimir-ingester,
prometheus, grafana, crossplane core, flux controllers, kamaji, external-dns.
NOT editable from this repo: `kube-apiserver`/`etcd` (kubeadm static pods) and
the `production-*` Kamaji tenant control-plane pods (Kamaji-managed) — the two
biggest memory consumers on the control-plane nodes.

### Code Quality

- Always format code before committing (prettier, nixfmt)
- Run `pre-commit run --all-files` in devenv
- Ensure YAML syntax is valid (use yamllint if available)
- Test Kustomize builds: `kustomize build clusters/openstack/`

### Kubeconfigs

The cluster kubeconfigs are stored in `~/.kube/configs/rpcu/`.

### Helpful Commands

```bash
# Flux status
fluxcd get kustomizations -A
fluxcd reconcile kustomization [name] -n flux-system

# Ceph status (in toolbox pod)
ceph status
ceph osd tree
ceph pool ls

# Cilium status
cilium status

# Kubernetes resources
kubectl get helmrelease -A
kubectl get kustomization -n flux-system
kubectl get gateway -A
kubectl get httproute -A
kubectl get backendtlspolicy -A
```

---

## 9. Project Statistics

| Metric                              | Value     |
| ----------------------------------- | --------- |
| Infrastructure YAML files           | (updated) |
| Cluster YAML files                  | (updated) |
| Helm charts managed                 | (updated) |
| Kubernetes namespaces               | (updated) |
| Git branches (local)                | 4         |
| Total project size (excluding .git) | (updated) |

---

## 10. Summary

Argus is a **production-grade Kubernetes GitOps repository** that:

✅ Declares infrastructure as code (YAML/Helm)
✅ Manages via Flux CD for automatic reconciliation
✅ Supports multi-cluster deployments (OpenStack-based)
✅ Provides networking (Cilium), storage (Rook/Ceph), API Gateway (kgateway), TLS (Cert-Manager)
✅ Uses NixOS ecosystem for reproducible development
✅ Enforces code quality through pre-commit hooks
✅ Syncs from GitHub automatically (1-minute intervals)
✅ Handles complex dependencies with health checks

All configuration is declarative, version-controlled, and enables auditable infrastructure changes.

---

**Last Updated**: August 2026 (Cert-manager expiry alerts: switched from fixed day thresholds (7d/30d) to **percentage-of-lifetime** thresholds (<10% critical, <20% warning) using `certmanager_certificate_not_before_timestamp_seconds` to compute total cert duration. This prevents short-lived certs (e.g. 72h) from constantly alerting — a 72h cert now fires critical at ~7.2h and warning at ~14.4h remaining, while a 90d cert fires at ~9d/~18d. Updated `infrastructure/grafana/alerting/rules-certmanager.yaml` (two expiry rules rewritten with `label_join` to compute `(remaining / total_lifetime) * 100`), `infrastructure/grafana/dashboards/cert-manager-dashboard.yaml` (three stat panels switched to percentage-based counts), and AGENTS.md Section 8 cert-manager monitoring notes. — Prior: Raised the `for` duration on the two high-resource node alerts in `infrastructure/grafana/alerting/rules-node.yaml` from `10m` to `1h` — `NodeCPUHigh` (>85%) and `NodeMemoryHigh` (>90% MemAvailable) now require the condition to be sustained for 1h before firing, to cut noise from transient spikes. Resolution is unchanged and already fast: the `node-resources` group evaluates at `interval: 1m`, so an alert clears at the next 1m eval once the condition drops (well within 10min). Descriptions updated to say "1h"; AGENTS.md Section 8 `rules-node.yaml` entry updated. — Prior: Added cert-manager certificate expiry monitoring: enabled `prometheus.enabled: true` in `infrastructure/cert-manager/values.yaml` so the chart's built-in ServiceMonitor (port 9402) is created and scraped by kube-prometheus-stack; created `infrastructure/grafana/alerting/rules-certmanager.yaml` with 3 alert rules — `CertManagerCertificateExpiringCritical` (critical, <7d), `CertManagerCertificateExpiringWarning` (warning, <30d), `CertManagerCertificateNotReady` (warning, Ready=False >15m) — using `certmanager_certificate_expiration_timestamp_seconds` and `certmanager_certificate_ready_status`. Created `infrastructure/grafana/dashboards/cert-manager-dashboard.yaml` with overview stats, certificate details table (Ready status, days left, expiry date), expiry-by-issuer timeseries, and not-ready certificates table. Without this, a certificate expiring tomorrow produced zero signal. Added Section 8 note. — Prior: Fixed silent Flux alerting + Crossplane DeploymentRuntimeConfig apiVersion. TWO chained bugs. (1) The Crossplane provider resource caps added in the prior change used `apiVersion: pkg.crossplane.io/v1` on the `DeploymentRuntimeConfig`, but that kind is served at **`pkg.crossplane.io/v1beta1`** (only `Provider`/`ClusterProviderConfig` are `v1`). The Flux server dry-run failed `no matches for kind "DeploymentRuntimeConfig" in version "pkg.crossplane.io/v1"`, breaking `crossplane-vault`/`-openstack`/`-zitadel`/`-providers`, which cascaded to `crossplane-resources` → `grafana-alerting` + `chihiro`. Fixed the apiVersion to `v1beta1` on all four provider bases (`Provider` stays `v1`); verified with server dry-run. (2) `infrastructure/grafana/alerting/rules-flux.yaml` was the ONLY alert file using `cluster=~"$cluster"` in its PromQL — a dashboard-only template variable that does NOT exist in Grafana alert-rule evaluation, so it stayed literal and matched zero series → all 5 Flux rules evaluated `NoData` → with `noDataState: OK` they were silently suppressed and never fired, so the whole broken crossplane chain produced NO Discord alert. Removed `cluster=~"$cluster"` from all 5 expressions (cluster is still emitted as an output label via `by (cluster, ...)`); added a DO-NOT-readd comment. Diagnosed via the Grafana alerting API (`/api/prometheus/grafana/api/v1/rules` → `alerts[].state: Normal (NoData)`), not the CR status which showed `ApplySuccessful`. The alert fix reaches the cluster only once the crossplane chain recovers (grafana-alerting dependsOn crossplane-resources). Added two Section 8 notes. — Prior: mgmt workload resource sizing. Analyzed all mgmt-cluster workload memory/CPU usage against 72h Mimir history (max/P95 of `container_memory_working_set_bytes` and `rate(container_cpu_usage_seconds_total[5m])`, `cluster="mgmt"`) and set `resources` on the top consumers that were QoS BestEffort / missing requests, per policy: **memory request ≈ P95/current, memory limit ≈ 2× observed max, CPU request-only (no CPU limit)**. Files: added a `pkg.crossplane.io/v1` `DeploymentRuntimeConfig` + `spec.runtimeConfigRef` to each Crossplane provider base — `infrastructure/crossplane-vault/provider-vault.yaml` (448Mi/896Mi/40m), `infrastructure/crossplane-openstack/provider.yaml` (384Mi/768Mi/40m), `infrastructure/crossplane-zitadel/provider.yaml` (256Mi/640Mi/30m), `infrastructure/crossplane-providers/provider-random.yaml` (128Mi/256Mi/20m) — these are SHARED bases so the caps apply to both mgmt and openstack (intended); providers previously ran `package-runtime` with `resources: {}`. `infrastructure/kgateway/helmrelease.yaml` — set the chart's top-level `resources` (192Mi/384Mi/20m), controller was BestEffort (shared base, applies to openstack too). `infrastructure/monitoring/helmrelease.yaml` — added KSM `resources` under the CORRECT hyphenated `kube-state-metrics:` subchart key (192Mi/384Mi/25m); the existing parent `kubeStateMetrics.resources` toggle key is NOT applied to the pod, so the live KSM pod ran `resources: {}`. `infrastructure/sveltos/helmrelease.yaml` — per-controller `resources` for the components the chart exposes (`addonController.controller` 448Mi/1Gi/80m — shipped with only a 512Mi request, no limit, no CPU request; `accessManager`/`eventManager` 320Mi/768Mi/15m; `classifierManager` 288Mi/704Mi/20m; `hcManager` 256Mi/576Mi/15m; `shardController` 224Mi/576Mi/15m; `scManager` 128Mi/256Mi/15m); sveltos-agents + driftDetectionManager expose no `resources` key in chart 1.12.7. Left already-tuned workloads alone (mimir-ingester, prometheus, grafana, crossplane core, flux controllers, kamaji, external-dns). NOT editable from this repo: kube-apiserver/etcd (kubeadm static pods) and the production-_ Kamaji tenant control-plane pods (Kamaji-managed) — the two biggest memory consumers. Added Section 8 note "mgmt workload resource sizing". All edits validated with `kustomize build` + prettier. — Prior: Fixed Disk I/O dashboard and kube-state-metrics RBAC. Dashboard `node-disk-io-dashboard.yaml`: fixed the "Disk I/O Utilization (avg)" gauge query — the old `sum()` / `count without (device)` aggregation was semantically broken (global sum divided by per-node device count, producing wrong averages) and replaced with `avg by (cluster, node) (rate(...))`. Removed `dm-0` from all device exclusion filters (`device!~"loop._|dm-0"`→`device!~"loop._"`) across the dashboard and `rules-diskio.yaml`alert rules — on NixOS hosts dm-0 is the LVM root volume whose I/O is the dominant signal, not noise to exclude. Monitoring`helmrelease.yaml`: moved Flux CRD RBAC rules from `kube-state-metrics.customResourceState.rbac.extraRules`to`kube-state-metrics.rbac.extraRules`(top-level subchart path) — some kube-state-metrics chart versions silently ignore the nested path, so the rules never reached the ClusterRole, causing KSM errors like`cannot list resource "buckets" in API group "source.toolkit.fluxcd.io"`. The `customResourceState.rbac`block was removed; the rules are now in the main ClusterRole which is always bound to the SA. — Prior: Added kube-state-metrics customResourceState for Flux CRDs: enabled`customResourceState.enabled: true`in`infrastructure/monitoring/helmrelease.yaml`under`kubeStateMetrics`, adding RBAC rules for KSM to watch all Flux CRDs (kustomizations, helmreleases, gitrepositories, helmrepositories, helmcharts, ocirepositories, buckets, alerts, providers, receivers, imagerepositories, imagepolicies, imageupdateautomations) and the custom resource state config generating `gotk*resource_info`metrics with`ready`/`suspended`/`revision`labels. Rewrote`infrastructure/grafana/dashboards/fluxcd-dashboard.yaml`from the controller-metrics-only version to use`gotk_resource_info`for status tables (Reconciler Readiness, Source Readiness, Suspended Objects) with Ready/Not Ready color coding, plus the native`gotk_reconcile_duration_seconds*_`for timing. Added`FluxResourceNotReady`alert rule (critical, 10m,`gotk*resource_info{ready="False"}`— direct KSM signal). 17 panels / 4 rows (Overview, Reconcile Performance, Status, Timing) / 5 alert rules. — Prior: Added FluxCD monitoring: headless`Service`+`ServiceMonitor`in`infrastructure/fluxcd/operator/monitoring.yaml`scraping all Flux controller pods (port 8080, label`app.kubernetes.io/part-of: flux`). Zero Flux metrics existed before — controllers expose `:8080/metrics`by default but nothing scraped them. — Prior: BestEffort starvation fix fleet-wide: added`resources`on all 9 database sub-sections across 7 yaook Deployment CRs (keystone, glance, neutron, nova×4, cinder, octavia, designate main — designate powerdns.database was already fixed 2026-07-26). Every yaook database pod shipped with`resources: {}`→ QoS BestEffort → cpu.weight=1 → readiness probe fails under CPU contention → kubelet restarts → intermittent OpenStack control-plane connectivity. Same failure mode as OVN (2026-07-26) and PowerDNS (same date). Resource values: mariadb-galera 200m/512Mi req / 2Gi limit; haproxy 50m/192Mi / 512Mi; service-reload + create-ca-bundle 10m/32Mi / 64Mi. No CPU limits (throttling re-creates the death spiral). Added Section 8 note "All yaook database pods must not be BestEffort". — Prior: Added`infrastructure/openstack-exporter/`— plain manifests deploying`ghcr.io/openstack-exporter/openstack-exporter:1.6.0`(distroless, no shell) on the openstack cluster: ESO`SecretStore`reads`keystone-admin`from ns`yaook`via cross-namespace SA RBAC, renders`clouds.yaml`with`auth_url: https://keystone.yaook.svc:5000/v3` (internal,
`verify: false`), Deployment with `--endpoint-type internal` and a
ServiceMonitor (interval 60s, no yaook component label → scraped by
kube-prometheus-stack's allow-by-default `NotIn` selector). The image is
**distroless** (no shell — scrape it via its pod IP, not `kubectl exec sh`). Deployed by `clusters/openstack/openstack-exporter.yaml` (dependsOn external-secrets + monitoring, `wait: false` — requires the manually-created `keystone-admin` secret first). Fully rewritten `infrastructure/grafana/dashboards/openstack-control-plane-dashboard.yaml` against live exporter metrics: 24 panels in 6 rows — Service Health (services-up stat, total VMs, VMs-not-active, VMs-in-error, nova-compute-up, RPC backlog, API availability timeseries), Virtual Machines Nova (VM status table w/ color-coded status, instances-per-tenant bar gauge, VMs-by-status stacked chart, nova agent state), Message Bus RabbitMQ (ready msgs, unacked, memory vs watermark), Service Databases Galera (db status table, connection pool%, aborted connections), Resources Network/Storage (resource inventory timeseries, Octavia LB status table). Every metric verified live (62 `openstack**`families confirmed). Deliberately has NO OVN/SDN panels (yaook ovn-monitoring PodMonitor selects wrong container ports → zero series). Also added`infrastructure/grafana/alerting/rules-openstack.yaml`(4 rules:`NovaVMInError` critical 5m server*status==4, `OpenStackServiceDown` warning 5m sum(8 services up) < 8, `NovaComputeAgentDown` critical 5m agent_state{nova-compute} lt 1, `OctaviaLoadBalancerNotOnline` warning 10m LB status > 0 while ACTIVE) and `infrastructure/grafana/alerting/rules-pods.yaml` (3 rules: `PodCrashLoopBackOff` critical 5m waiting_reason CrashLoopBackOff, `PodRestartingFrequently` critical 10m restarts>3 in 15m, `PodContainerNotReady` warning 15m not-ready excluding Jobs). Also enabled `spec.monitoring.enabled: true` on `infrastructure/rook/configs/cephcluster.yaml` — without this, the Rook operator never created the `rook-ceph-mgr` ServiceMonitor (port 9283, the Ceph mgr `prometheus` module), so Mimir held zero `ceph*\_`metrics and the Ceph dashboard was permanently blank. Fully rewrote`infrastructure/grafana/dashboards/ceph-storage-dashboard.yaml`against the now-live`ceph\__` family: 20 panels using real metric names (`ceph*cluster_status_code`, `ceph_osd_up`, `ceph_osd_in`, `ceph_pg*_`, `ceph*osd_utilization`, `ceph_pool_metadata`, `ceph_osd_metadata`), with `rook-ceph-mgr:9283`scraped automatically by the openstack kube-prometheus-stack's allow-by-default`NotIn`ServiceMonitor selector. — Prior: kube-apiserver CPU reduction: added`infrastructure/cluster-api-templates/templates/controlplane-v3.yaml` (ECDSA-P256). See "kube-apiserver CPU is TLS-handshake bound" in Section 8.) (`openstack-default-control-plane-v3`) — identical to `-v2`plus`clusterConfiguration.encryptionAlgorithm: ECDSA-P256`, and repointed the `openstack-default`ClusterClass`controlPlane.templateRef`at it (registered in`kustomization.yaml`). ROOT CAUSE: the openstack cluster's 3 apiservers burn ~2 cores each (~6 total) despite only 2-3 inflight requests and ~10 req/s — the cost is the per-connection TLS handshake (RSA-2048 asymmetric crypto), amplified by baremetal CPU contention (lucy/quinn at 89-97%, shared with Ceph+VMs). ECDSA-P256 handshakes are ~5-10x cheaper server-side. The openstack cluster is baremetal (bootstrapped from **hephaestus**, not argus), so its fix lives in hephaestus `nixosModules/rpcuIaaSCP/confs/kubeadm-bootstrap.nix`(added`encryptionAlgorithm: ECDSA-P256`, migrated that file kubeadm v1beta3→v1beta4 since the field is v1beta4-only, converted `apiServer.extraArgs`map→list, and fixed two pre-existing YAML indentation bugs in the certSANs join and the InitConfiguration`nodeRegistration`block; join template also bumped to v1beta4). Kamaji ClusterClass deliberately unchanged (manages its own tenant cert keys, tenant apiservers not CPU-stressed). Only takes effect on certs generated at kubeadm init/cert renewal — running control planes keep RSA certs until rolled/rotated. Also corrected a measurement red herring: a spurious "108k auth/s storm" on mgmt was an artifact of subtracting per-process cumulative counters across LB-routed apiserver replicas — mgmt is healthy. See "kube-apiserver CPU is TLS-handshake bound" in Section 8. — Prior: Rewrote`infrastructure/grafana/dashboards/palworld-dashboard.yaml` from scratch — the grafana.com 20421 import only covered the handful of metrics the OLD Python exporter emitted (`palworld_up`, `palworld_player_count`, `palworld_server_info`, save-file sizes) and its remaining panels were permanently blank. The atlas repo swapped the exporter sidecar to `docker.io/banhcanh/palworld-exporter`([Banh-Canh/palworld-exporter-go](https://github.com/Banh-Canh/palworld-exporter-go)), which exports the full REST-API metric set, so the dashboard is now hand-built against it: 37 panels / 6 rows (Server Health, Performance, Container & Storage, Players, Pals & World, Saves & Settings), a`$cluster` template variable applied to every query, and kube-prometheus-stack panels (cAdvisor CPU/memory per container, `palworld-data` PVC gauge, 24h restart count) alongside the game metrics. Kept uid `palworld-server`, title "Palworld", folder `Gaming`. Every PromQL expression was executed against the production Prometheus before commit (0 invalid); the panels that return nothing today do so only because they need the new exporter deployed, players online, or `ENABLE_GAMEDATA_API`. Two known gates documented in the file header: the Pals & World row needs `ENABLE_GAMEDATA_API: "true"` on the server (set in atlas `cm.yaml`), and the Saves panels are blank on exporter image `v0.0.1`, whose save reader does a flat `os.ReadDir` of `SAVE_DIRECTORY` and never finds the nested `Level.sav` (fixed upstream in palworld-exporter-go after that tag; needs a new image release + an atlas `image:` bump). — Prior: Added `infrastructure/grafana/dashboards/palworld-dashboard.yaml` — a `GrafanaDashboard` CR (folder `Gaming`, `instanceSelector` `dashboards: grafana-central`) for the Palworld dedicated server, imported from grafana.com dashboard 20421 with all datasource UIDs rewritten from `${DS_PROMETHEUS}`to`Mimir`and the`**inputs`/`**requires`/`\_\_elements`export wrappers stripped. Registered it in`infrastructure/grafana/kustomization.yaml`. It visualizes the `palworld*\_`metrics produced by the`palworld-exporter` sidecar defined in the **atlas** repo (`clusters/production/palworld/`); that exporter's `ServiceMonitor`(labeled`release: kube-prometheus-stack`) is scraped by the Sveltos-pushed Prometheus on the production cluster and `remote_write`n to central Mimir here — the dashboard lives in argus only because Grafana is mgmt-only. — Prior: Grafana Operator & DaaS transition: added Grafana Operator v5 (`infrastructure/grafana-operator`, `clusters/mgmt/grafana-operator.yaml`) watching all namespaces, migrated Grafana instance to `Grafana`CR (v1beta1) in`infrastructure/grafana/grafana.yaml`preserving Zitadel OIDC & 2Gi PVC, added`GrafanaDatasource`for Mimir, updated HTTPRoute to`grafana-service:3000`, and enabled `allowCrossNamespaceImport: true` for cross-namespace DaaS.)

**Previously**: July 26, 2026 (Monitoring: made the mgmt stack minimalist and stable. TWO independent faults — `mimir-ingester-0` CrashLoopBackOff was DISK (stale 2Gi PVC vs a 5Gi StatefulSet template; expanded in place, since raising the chart value would instead wedge the Helm upgrade on the immutable `volumeClaimTemplates`), while Prometheus OOM-looping under a 1Gi limit was CARDINALITY: **313,505 active head series**, of which the apiserver job alone was 82%. Dropped nine apiserver/etcd histogram families whole plus inert metrics (`kubernetes_feature_enabled`, openapi regeneration counters, `apiserver_{storage,cache}_list_*`, kubelet `prober_probe_duration_seconds`) for a **65% cut to ~108,600 series**, keeping `apiserver_request_total` for `KubeAPIDown`; disabled the kube-apiserver SLO rule groups that depended on the dropped buckets. Added `GOMEMLIMIT` (a hard limit alone is a cliff → OOM loop; GOMEMLIMIT makes the GC trade CPU for memory), bounded `remoteWrite` shards, 60s scrape, 6h local retention (Mimir owns retention). Also disabled the Kafka/ingest-storage architecture that the Mimir v6 Renovate bump silently enabled, and added the missing `monitoring` Sveltos toggle to the chihiro ConfigMap. See "Monitoring: Prometheus OOM was cardinality, not tuning" in Section 8.)

**Previously**: July 26, 2026 (MTU: pinned `MTU: 1400` in `clusters/openstack/cilium.yaml`. ROOT CAUSE of the long-running `net/http: TLS handshake timeout` black hole: Cilium sets no explicit MTU, so it auto-detects the MINIMUM across its `--devices` — and this cluster attaches `br-int`, which OVN sizes to the TENANT MTU (1284). Cilium thus adopted the tenant MTU as its HOST MTU and, with `packetizationLayerPMTUDMode: always`, its BPF emitted ICMP frag-needed `mtu 1284` for ordinary host underlay traffic (captured: apiserver/6443 and kubelet/10250 between hypervisors), poisoning each hypervisor's PMTU cache for its peers. Geneve was then left `1284 − 58` = 1226 while Neutron advertised 1284 → a 58-byte silent black hole east-west AND north-south. This is a FEEDBACK LOOP (`path_mtu → br-int → Cilium MTU → ICMP → underlay PMTU`), so `dfe2403`'s `path_mtu` 1400→1342 could not fix it — it only moved the hole from 1342/1284 to 1284/1226. The underlay genuinely carries 1400 (proven with `ping -M probe` and a post-flush DF ping), so jumbo would not have helped either. Corrected the previous WRONG diagnosis that blamed the OVN distributed gateway port and explicitly ruled out Cilium. See "Cilium auto-MTU inherits `br-int`" in Section 8.)

**Previously**: July 26, 2026 (OVN: set `resources` on every component in `infrastructure/yaook/neutron.yaml` `setup.ovn` — NB/SB ovsdb + their ssl-terminators, the SB relay, `northd`, and the per-node `controller.*` agents were ALL QoS BestEffort (`resources: {}`), so on a node at load 69/12-cores they were starved until `ovsdb-server` could not answer a local appctl within the 20s liveness timeout; kubelet then killed them in a loop, NB raft lost quorum (term 676, no leader), `ovn-northd` could never find a leader and flapped 0/1, and Neutron could not bind ports so new VMs failed to boot. No CPU limits anywhere, and no memory limit on `ovs-vswitchd`. The CRD exposes no `priorityClassName`, so the `system-cluster-critical` half of the fix needs an upstream yaook change. See "OVN control plane must not be BestEffort" in Section 8.)

**Previously**: July 26, 2026 (Nova: `resume_guests_state_on_host_boot: true` in `infrastructure/yaook/nova.yaml` so instances Nova believes are ACTIVE are restarted automatically after a hypervisor reboot — previously a node reboot left every CAPO-provisioned VM SHUTOFF until manually started. Added `infrastructure/yaook/disruptionbudget.yaml`, the repo's first `YaookDisruptionBudget` (`preventDeletion: true`, match-all), so that edit — and any future `novaComputeConfig` edit — only FLAGS each `NovaComputeNode` `RequiresRecreation` instead of rolling-deleting it into a cold-migration drain that is broken on this cluster. Documented the mechanism from the operator source plus a per-node manual rollout runbook.)

**Previously**: July 26, 2026 (Networking + node resilience: fixed the tenant MTU black hole — `ml2.path_mtu` 1400 → 1342 in `infrastructure/yaook/neutron.yaml` so tenant VMs get 1284 instead of an unusable 1342, measured with DF sweeps (underlay 1400 OK, east-west 1342 OK, north-south capped at 1284 by the OVN gateway); added the repo's first `MachineHealthCheck`s to all four ClusterClasses so unreachable nodes are remediated instead of stranding StatefulSet Pods; added `openstack-default-control-plane-v2` / `openstack-default-worker-v2` templates with kubelet `--kube-reserved`/`--system-reserved`/eviction thresholds.)
**Repository**: <https://github.com/RPCU/argus.git>
**Main Branch**: main
**Clusters**: OpenStack, mgmt (Cluster API management)
