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
- `ceph-adapter-rook.yaml` - OpenStack/Ceph integration
- `rook.yaml` - Rook storage orchestrator
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
- `external-dns.yaml` - InternalDNS with Designate provider, syncs Service/Gateway DNS records into the rpcu.lan zone (dependsOn external-secrets; `wait: false` — ESO-rendered openstack-credentials secret requires the manual capo-variables secret first)
- `crossplane.yaml` - Crossplane Helm install (shared `infrastructure/crossplane`, dependsOn nothing)
- `crossplane-providers.yaml` - provider-random base (shared `infrastructure/crossplane-providers`, dependsOn crossplane). Currently unused / failing to install — candidate for removal.
- `crossplane-zitadel.yaml` - provider-zitadel base (shared `infrastructure/crossplane-zitadel`, dependsOn crossplane). Provider only.
- `crossplane-resources.yaml` - **mgmt overlay** `./clusters/mgmt/crossplane/zitadel` (dependsOn crossplane-zitadel, `prune: false`). mgmt's own Zitadel `ProviderConfig` (`default`, points at the manually-created `crossplane-provider-zitadel` secret in ns zitadel) + the **chihiro** `Oidc` app. The chihiro Oidc references the shared org/project by **literal external ID** (org rpcu `369994019545117645`, project administration `370001231734928333`) because those Project/Org MRs are owned by the openstack cluster and don't exist here. It writes its connection secret as `chihiro-oidc-conn` (keys `attribute.client_id` / `attribute.client_secret`) into chihiro-system.
- `chihiro.yaml` - chihiro app (path `./clusters/mgmt/apps/chihiro`, dependsOn cert-manager-issuer + kgateway + dragonfly-operator + external-secrets + crossplane-resources). The added `apps/chihiro/oidc.yaml` is an ESO `SecretStore` + `ExternalSecret` that remaps `chihiro-oidc-conn`'s `attribute.client_id`/`attribute.client_secret` into the `chihiro-oidc` secret (keys `clientId`/`clientSecret`) consumed by `deploy.yaml`. The `apps/chihiro/cm.yaml` `cluster.template` writes a `sveltos.argus.rpcu.io/capo-version` **annotation** on the generated `Cluster` CR from a `capoVersion` form parameter (editable `select`, `kube-admin`-only, default sentinel `"default"`, path `metadata.annotations.'sveltos.argus.rpcu.io/capo-version'`, options `default`/`v0.14.4`). The Sveltos `capi-management` ClusterProfile reads this annotation and only patches the CAPO `InfrastructureProvider` version when it is a real version (the `"default"` sentinel and empty are treated as no-override → repo-pinned version). A `select` (not free-text) is used because chihiro hard-errors on an empty `{{ chihiro.* }}` create-form placeholder, so the field must always carry a non-empty value (`default`).
- `dragonfly-operator.yaml` - Dragonfly (Redis-compatible) operator for chihiro's session store
- `vault.yaml` - HashiCorp Vault (path `./infrastructure/vault`, dependsOn kgateway + openstack-cinder-csi). **HA Vault (3-node integrated Raft storage, no external Consul)** on the mgmt cluster. Adapted from the bealv `flux-mgmt` repo: the chart's bundled Ingress is disabled in favour of a Gateway API `HTTPRoute` at `vault.mgmt.rpcu.lan` (TLS terminated at the shared kgateway `https` Gateway with the `rpcu-lan-wildcard-tls` cert / root-mgmt CA — no per-app cert-manager issuer like the source's `bealv-mgmt`/`vault.bealv-mgmt.lan`), and each replica's `dataStorage` PVC explicitly requests the `cinder-delete` StorageClass (mgmt has no default StorageClass). The 3 replicas require 3 distinct schedulable nodes (chart `required` podAntiAffinity).
- `kubernetes-rbac.yaml` - Flux Kustomization (path `./clusters/mgmt/apps/kubernetes-rbac`, no dependsOn) applying the OIDC group → RBAC bindings on the workload cluster: `apps/kubernetes-rbac/crb.yaml` binds the **bare** `kube-admin` Group → `cluster-admin` and `kube-user` Group → `view`. The bare group names match the shared Zitadel `groupsClaim` Action output and the ClusterClass's empty `groupsPrefix`. Mirrors the bealv reference (`gitops/apps/kubernetes/crb.yaml`). Harmless before OIDC is enabled (the groups simply never appear in any token).
- `sveltos.yaml` - Flux Kustomization (path `./infrastructure/sveltos`, `prune: true`) deploying the shared `infrastructure/sveltos` base (Sveltos core + OIDC RBAC).
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
- `values.yaml` - Custom Helm values
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
- `gateway.yaml` - `Gateway` resource definition
- `httplistenerpolicy.yaml` - `HTTPListenerPolicy` for WebSocket upgrades and access logs
- `kustomization.yaml` - Kustomization manifest

**rook/** - Distributed Storage (Ceph v19.2.3)

_rook/setup/_ - Initial installation

- `helmrelease.yaml` - Rook Helm chart (v1.19.0)
- `helmrepo.yaml` - Repository reference
- `kustomization.yaml` - Kustomization manifest

_rook/configs/_ - Ceph cluster configuration

- `cephcluster.yaml` - Ceph cluster with 3 monitors (lucy, makise, quinn)
- `cephblockpool.yaml` - RBD block pool
- `cephobjectstore.yaml` - S3-compatible object storage
- `cephobjectstoreuser.yaml` - Object store credentials
- `storageclassrdb.yaml` - RBD storage class
- `openstack-clients.yaml` - OpenStack client pods
- `toolbox-deployment.yaml` - Ceph admin toolbox
- `yaook-secret-reader-rbac.yaml` - RBAC allowing yaook to read secrets
- `gateway/` - Gateway API resources for Rook services
  - `httproute-ceph.yaml` - HTTPRoute for Ceph dashboard (TLS termination at Gateway)
  - `kustomization.yaml` - Kustomization manifest
- `kustomization.yaml` - Kustomization manifest

**ceph-adapter-rook/** - OpenStack Integration

- `helmrelease.yaml` - Helm chart
- `helmrepo.yaml` - Repository reference
- `kustomization.yaml` - Kustomization manifest

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
  SOURCE_IP).
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
- `core/` - **Reusable Sveltos core install** (Flux Kustomization source). A
  self-contained subset of the parent `sveltos/` directory containing only the
  pieces needed to run Sveltos on a single cluster: `namespace.yaml`,
  `helmrepo.yaml`, `helmrelease.yaml` (values via `valuesFrom` referencing a
  `sveltos-core-values` ConfigMap), and `rbac.yaml` (base addon-controller
  RBAC only — no capi-management-specific RBAC). The HelmRelease does NOT
  carry hardcoded values — per-cluster configuration (domain,
  managementCluster flag) is injected by a Sveltos-templated
  `sveltos-core-values` ConfigMap pushed alongside the Flux Kustomization CR.
  Used by the `capi-management` ClusterProfile to deploy Sveltos onto new
  management clusters via a Flux `Kustomization` CR pointing at
  `./infrastructure/sveltos/core` in Git. The main `sveltos/kustomization.yaml`
  still references the parent directory files directly (not `core/`) — `core/` is
  a Flux sync source, not a nested kustomize reference.
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
  components incl. `notification-controller`, the `--concurrent=4` +
  `--kube-api-qps=50`/`--kube-api-burst=100` throttle patch, and the **tmpfs
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
  1. Sveltos core (Flux Kustomization → `infrastructure/sveltos/core`) — multi-cluster add-on manager
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
  (not inline `helmCharts`) pointing at `./infrastructure/sveltos/core` in Git.
  A templated `sveltos-core-values` ConfigMap provides per-cluster values
  (`kubernetesClusterDomain: <cluster-name>.local`, `managementCluster: true`).
  This is consistent with how other profiles (openstack-ccm, cinder-csi,
  external-snapshotter) push Flux Kustomization CRs for GitOps-managed
  deployment.

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

- `kustomization.yaml` - Kustomization manifest (namespace, helmrepo, core
  helmrelease, rbac, clusterprofiles/). The main `sveltos/kustomization.yaml`
  references the parent directory files directly; the `core/` subdirectory is
  a separate Flux sync source used by the `capi-management` ClusterProfile.

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
- `templates/bootstrap.yaml` - KubeadmConfigTemplate `openstack-default-worker-v1`
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

**yaook-operator/** - Yaook OpenStack Operators (v2.2.0)

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

- `keystone.yaml` - KeystoneDeployment (identity)
- `glance.yaml` - GlanceDeployment (images)
- `neutron.yaml` - NeutronDeployment (networking)
- `nova.yaml` - NovaDeployment (compute)
- `cinder.yaml` - CinderDeployment (block storage, rook-ceph RBD backend)
- `horizon.yaml` - HorizonDeployment (dashboard)
- `octavia.yaml` - OctaviaDeployment (load balancing)
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
- `barbican.yaml` - BarbicanDeployment (key manager, simple_crypto plugin, KEK auto-generated)
- `ca-cert.yaml` - CA certificate resources
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

_fluxcd/instances/_ - Instance configuration

- `flux.yaml` - FluxInstance CRD (Flux 2.x, kustomize/helm controllers patched to `--concurrent=4` + `--kube-api-qps=50`/`--kube-api-burst=100` to bound etcd load). **All controllers' ephemeral storage is backed by tmpfs** (RAM-backed `emptyDir` with `medium: Memory`) instead of the node disk to avoid heavy disk I/O from Git clones, artifact unpacking, and kustomize/helm build scratch. Per-controller patches (volume names differ upstream): source-controller `data`(/data, sizeLimit 1Gi) + `tmp`(/tmp, 256Mi); kustomize/helm-controller `temp`(/tmp, 512Mi). Because a Memory `emptyDir` counts against the container memory cgroup limit, the memory limits are raised for headroom (source-controller 2Gi, kustomize/helm-controller 1536Mi) — a full tmpfs would otherwise OOM-kill the pod; each `sizeLimit` also caps tmpfs growth so a runaway artifact can't exhaust node RAM.
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
- **Concurrency**: 4 operations per controller (kustomize/helm), throttled with `--kube-api-qps=50`/`--kube-api-burst=100` to bound apiserver/etcd load
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
| rook                 | v1.19.0 | rook-release/rook-ceph                         | 5m            |
| crossplane           | 2.2.0   | charts.crossplane.io/stable                    | 5m            |
| external-secrets     | 2.3.0   | charts.external-secrets.io                     | 5m            |
| yaook-crds           | 2.2.0   | yaook.cloud/crds                               | 5m            |
| yaook-ops            | 2.2.0   | yaook.cloud/operators                          | 5m            |
| capi-operator        | 0.27.0  | kubernetes-sigs.github.io/cluster-api-operator | 5m            |
| openstack-ccm        | 2.35.0  | kubernetes.github.io/cloud-provider-openstack  | 5m            |
| openstack-cinder-csi | 2.35.0  | kubernetes.github.io/cloud-provider-openstack  | 5m            |
| external-dns         | 1.21.1  | kubernetes-sigs.github.io/external-dns/        | 5m            |

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
   - ceph-adapter-rook
   - rook (setup → configs with health checks)
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

`renovate.json5` (repo root) configures the **Mend Renovate GitHub App** to open
PRs for outdated dependencies. **No auto-merge** — every PR requires manual
review/merge (production GitOps). PRs are batched Monday early morning
(`Europe/Paris`). A Dependency Dashboard issue tracks everything.

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
     ceph image + toolbox, chihiro).
  8. **npins** GitRelease pin in `npins/sources.json` → `github-releases`
     (sveltosctl). Note: bumping the JSON pin alone is not sufficient — the
     `hash`/`revision` must be refreshed with `npins update`; treat such PRs as a
     signal to run `npins update` locally.

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

#### Tenant network MTU is pinned to 1400 (no jumbo frames)

`infrastructure/yaook/neutron.yaml` pins the tenant/provider network MTU to
**1400** (`DEFAULT.global_physnet_mtu: 1400`, `ml2.path_mtu: 1400`,
`ml2.physical_network_mtus: enp3s0:1400`). Combined with `advertise_mtu: True`,
Neutron advertises the derived overlay MTU (OVN geneve = 38B overhead →
~**1362**) to tenant VMs over DHCP.

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

**Last Updated**: July 2026 (Renamed the ExternalDNS add-on to InternalDNS: namespace `external-dns` → `internal-dns`, HelmRelease `external-dns` → `internal-dns`, ServiceAccount `external-dns` → `internal-dns`, ConfigMap generator `external-dns-values` → `internal-dns-values`, RoleBinding `external-dns-capo-variables-reader` → `internal-dns-capo-variables-reader`. The upstream HelmRepository name stays `external-dns` (chart repo). Updated across infrastructure/external-dns/ base, infrastructure/sveltos/clusterprofiles/external-dns.yaml, clusters/mgmt/external-dns.yaml Flux Kustomization name, and AGENTS.md.)
**Repository**: <https://github.com/RPCU/argus.git>
**Main Branch**: main
**Clusters**: OpenStack, mgmt (Cluster API management)
