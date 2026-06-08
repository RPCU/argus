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
- `crossplane.yaml` - Crossplane universal control plane
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
- `cilium.yaml` - Cilium networking (shared infrastructure/cilium with mgmt-specific patches: k8sServiceHost 172.16.255.212:6443, L2 interface enp3s0, LB IP pool 192.168.1.2-192.168.1.10; uses the base `socketLB.hostNamespaceOnly: false` default — see note below)
- `cert-manager.yaml` - Certificate management (prerequisite for CAPI operator)
- `external-secrets.yaml` - External Secrets Operator (sources CAPO credentials)
- `cluster-api-operator.yaml` - Cluster API Operator (dependsOn cert-manager)
- `cluster-api-providers.yaml` - CAPI provider CRs (dependsOn cluster-api-operator + external-secrets)
- `flux-operator.yaml` - Flux operator deployment
- `fluxcd/` - Flux CD configuration
  - `flux-instance-patch.yaml` - Flux instance patch (sync path ./clusters/mgmt, domain mgmt.local)
  - `kustomization.yaml` - Flux component references

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

**crossplane-compositions/** - Crossplane XRDs & Compositions

- `xrd-router.yaml` - CompositeResourceDefinition for XRouter (networking.rpcu.io/v1alpha1)
- `composition-router.yaml` - Composition wiring NetworkV2 ID into RouterV2 externalNetworkId
- `kustomization.yaml` - Kustomization manifest (no namespace, cluster-scoped resources)

**crossplane-resources/** - Crossplane Managed Resources & Composite Resources

- `network-mgmt.yaml` - Management network (NetworkV2 + SubnetV2, CIDR 192.168.0.0/24)
- `network-ext.yaml` - External network subnet (SubnetV2, CIDR 172.16.0.0/16)
- `routers.yaml` - XRouter composite resource (router-ext with ext network gateway)
- `kustomization.yaml` - Kustomization manifest (namespace: crossplane-system)

**external-secrets/** - External Secrets Operator (v2.3.0)

- `helmrelease.yaml` - Helm deployment
- `helmrepo.yaml` - Helm repository (charts.external-secrets.io)
- `namespace.yaml` - Kubernetes namespace (external-secrets)
- `values.yaml` - Custom Helm values
- `kustomization.yaml` - Kustomization manifest

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
the manually bootstrapped kind management cluster.

- `namespaces.yaml` - Namespaces (capi-system, capi-kubeadm-bootstrap-system, capi-kubeadm-control-plane-system, capo-system)
- `core.yaml` - CoreProvider cluster-api (v1.13.2)
- `bootstrap-kubeadm.yaml` - BootstrapProvider kubeadm (v1.13.2)
- `control-plane-kubeadm.yaml` - ControlPlaneProvider kubeadm (v1.13.2)
- `infrastructure-openstack.yaml` - InfrastructureProvider openstack / CAPO (v0.14.4), configSecret capo-variables
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

- `clusterclass.yaml` - ClusterClass `openstack-mgmt` with variables: identityRef, externalNetworkId, managedSubnetCIDR, managedSubnetAllocationPools, imageName, controlPlaneFlavor, workerFlavor, sshKeyName, apiServerFloatingIP
- `templates.yaml` - KubeadmControlPlaneTemplate, KubeadmConfigTemplate, OpenStackClusterTemplate, OpenStackMachineTemplate. The `OpenStackClusterTemplate.managedSecurityGroups` sets `allowAllInClusterTraffic: true` plus explicit Cilium data-plane rules (VXLAN UDP 8472, health TCP 4240, Hubble TCP 4244, ICMP via `remoteManagedGroups: [controlplane, worker]`) — required because CAPO's default managed SGs only open API/etcd/kubelet/node-port and would otherwise drop Cilium's cross-node overlay (see note in Cluster Safety).
- `namespaces.yaml` - Namespace `mgmt`
- `kustomization.yaml` - Kustomization manifest (the `Cluster` CR `mgmt-cluster.yaml` is commented out here; the actual Cluster lives at `clusters/mgmt/clusters/mgmt.yaml`)

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
- `designate.yaml` - DesignateDeployment (DNS)
- `barbican.yaml` - BarbicanDeployment (key manager, simple_crypto plugin, KEK auto-generated)
- `ca-cert.yaml` - CA certificate resources
- `secretstore*.yaml` / `externalsecret-*.yaml` - SecretStores + ExternalSecrets (crossplane creds, OIDC, rook-ceph client keys)
- `gateway/` - HTTPRoutes + BackendTLSPolicies per service (includes `httproute-barbican.yaml` → `barbican.rpcu.vpn`, backend `barbican-api:9311`)
- `kustomization.yaml` - Kustomization manifest (namespace: yaook)

**fluxcd/** - GitOps Operator

_fluxcd/operator/_ - Operator installation

- `kustomization.yaml` - Flux operator (v0.40.0 from GitHub releases)

_fluxcd/instances/_ - Instance configuration

- `flux.yaml` - FluxInstance CRD (Flux 2.x, 42 concurrent operations)
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

### OpenStack Operators

- **Yaook Operators** - v2.2.0 (charts.yaook.cloud)
- **Operators**: infra, keystone, keystone-resources, glance, nova, nova-compute, neutron, neutron-ovn, horizon, octavia, designate, cds, barbican

### Certificate Management

- **Cert-Manager** - v1.19.2
- **Internal CA Issuer**

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

- **Remote**: git@github.com:RPCU/argus.git
- **Main Branch**: main
- **Sync Interval**: 1 minute
- **Development Branches**: dev, dev-vic, ciliumlb
- **Commit Signing**: GPG required
- **Authentication**: SSH key-based

### Flux Sync Configuration

**Source**: infrastructure/fluxcd/instances/flux.yaml

- **Distribution**: Flux 2.x
- **Components**: source, kustomize, helm, notification controllers
- **Git Repository**: https://github.com/RPCU/argus.git
- **Branch**: main
- **Path**: ./clusters/PLACEHOLDER (cluster-specific override)
- **Concurrency**: 42 operations per controller
- **Interval**: 1 minute

### Cluster Network Configuration (clusters/openstack/)

- **Kubernetes API**: 10.0.0.5:6443
- **Device Routing**: eno1.4000 (VLAN)
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

| Component        | Version | Repository                                     | Sync Interval |
| ---------------- | ------- | ---------------------------------------------- | ------------- |
| cert-manager     | v1.19.2 | jetstack/cert-manager                          | 5m            |
| cilium           | v1.18.6 | cilium/cilium                                  | 5m            |
| kgateway         | v2.2.2  | oci://cr.kgateway.dev/kgateway-dev/charts      | 5m            |
| rook             | v1.19.0 | rook-release/rook-ceph                         | 5m            |
| crossplane       | 2.2.0   | charts.crossplane.io/stable                    | 5m            |
| external-secrets | 2.3.0   | charts.external-secrets.io                     | 5m            |
| yaook-crds       | 2.2.0   | yaook.cloud/crds                               | 5m            |
| yaook-ops        | 2.2.0   | yaook.cloud/operators                          | 5m            |
| capi-operator    | 0.27.0  | kubernetes-sigs.github.io/cluster-api-operator | 5m            |

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
   - crossplane (Helm → crossplane-openstack → crossplane-compositions → crossplane-resources)
   - external-secrets
   - ceph-adapter-rook
   - rook (setup → configs with health checks)
   - yaook-operator (CRDs first, then operators via dependsOn)

### Kustomization Dependencies (from clusters/mgmt/)

CAPI management cluster (self-management target via `clusterctl move`):

1. **flux-operator** (no dependencies) → Flux operator
2. **fluxcd** → Flux CD instance (sync ./clusters/mgmt)
3. **cilium** (no dependencies) → eBPF-based networking (CNI / kube-proxy replacement), L2 announcements on enp3s0, LoadBalancer IP pool 10.0.0.224-10.0.0.239
4. **cert-manager** (no dependencies) → prerequisite for CAPI operator
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

- **Official Docs**: https://docs.rpcu.io/gitops/
- **Flux CD**: https://fluxcd.io/docs/
- **Cilium**: https://docs.cilium.io/
- **Gateway API**: https://gateway-api.sigs.k8s.io/
- **kgateway**: https://kgateway.dev/
- **Rook**: https://rook.io/docs/rook/
- **Cert-Manager**: https://cert-manager.io/docs/
- **Crossplane**: https://docs.crossplane.io/

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

#### CAPO managed security groups must open the Cilium overlay (mgmt cluster)

CAPO's `managedSecurityGroups` only opens the baseline kube API / etcd /
kubelet / node-port rules. It does **not** open the CNI's overlay traffic (see
CAPO docs, "CNI security group rules"). On the mgmt cluster, Cilium runs in
tunnel/VXLAN mode, so cross-node pod traffic is encapsulated in **UDP 8472**.
Without an explicit rule, Neutron silently drops it: same-node pods work, but
**pod-to-pod and pod-to-Service across nodes fail entirely** (can't even ping
another node's pod), and CoreDNS can't reach the apiserver/endpoints so DNS
never becomes ready (`plugin/ready: Plugins not ready: "kubernetes"`).

Fix lives in `infrastructure/cluster-api-templates/templates.yaml`
(`OpenStackClusterTemplate.spec.template.spec.managedSecurityGroups`):
`allowAllInClusterTraffic: true` (covers all node-to-node traffic and future
Cilium features) plus explicit documented rules for VXLAN 8472 / health 4240 /
Hubble 4244 / ICMP scoped via `remoteManagedGroups: [controlplane, worker]`.
If Cilium is switched to Geneve, open UDP 6081 instead of 8472; if Cilium
encryption is enabled, also open WireGuard/ESP. After changing this, verify the
rules actually landed on the managed SGs:
`openstack security group rule list k8s-cluster-mgmt-mgmt-secgroup-controlplane`.

Note: MTU is a separate, secondary concern. Double encapsulation (Cilium VXLAN
over Neutron VXLAN/Geneve) shrinks the usable pod MTU; large packets (DNS/TCP,
big API LISTs, TLS) can black-hole if MTUs are inconsistent. Do NOT apply jumbo
frames piecemeal — an MTU mismatch on any hop is worse than a consistent small
MTU. Confirm overlay connectivity first, then size Cilium `MTU` to the OpenStack
tenant-network MTU if needed.

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

**Last Updated**: June 2026 (added mgmt Cluster resource, cluster-api-templates docs, apiServerFloatingIP + managedSubnetAllocationPools ClusterClass variables)
**Repository**: https://github.com/RPCU/argus.git
**Main Branch**: main
**Clusters**: OpenStack, mgmt (Cluster API management)
