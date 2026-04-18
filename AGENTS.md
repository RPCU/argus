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
- `sveltosctl.nix` - Sveltos CLI tool package definition (v1.4.0)

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
- `gateway-api.yaml` - Gateway API CRDs installation
- `kgateway-crds.yaml` - kgateway CRDs installation
- `kgateway.yaml` - kgateway controller and Gateway installation
- `ceph-adapter-rook.yaml` - OpenStack/Ceph integration
- `rook.yaml` - Rook storage orchestrator
- `yaook-operator.yaml` - Yaook OpenStack operators
- `flux-operator.yaml` - Flux operator deployment
- `fluxcd/` - Flux CD configuration
  - `flux-instance-patch.yaml` - Flux instance patches
  - `kustomization.yaml` - Flux component references

### infrastructure/ - Reusable Components

**cert-manager/** - SSL/TLS Certificate Management (v1.19.2)

- `helmrelease.yaml` - Helm deployment
- `helmrepo.yaml` - Helm repository
- `namespace.yaml` - Kubernetes namespace
- `values.yaml` - Custom Helm values
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
- `gateway/` - Gateway API resources for Rook services
  - `httproute-ceph.yaml` - HTTPRoute for Ceph dashboard (TLS termination at Gateway)
  - `kustomization.yaml` - Kustomization manifest
- `kustomization.yaml` - Kustomization manifest

**ceph-adapter-rook/** - OpenStack Integration

- `helmrelease.yaml` - Helm chart
- `helmrepo.yaml` - Repository reference
- `kustomization.yaml` - Kustomization manifest

**yaook-operator/** - Yaook OpenStack Operators (v2.0.3)

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
- `gateway/` - Gateway API resources for Yaook services
  - `listenerset.yaml` - XListenerSet for Yaook TLS passthrough
  - `tlsroute-*.yaml` - TLSRoutes for various OpenStack services (TLS passthrough)
  - `kustomization.yaml` - Kustomization manifest
- `kustomization.yaml` - Kustomization manifest

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
- **Gateway API** - v1.4.1 (experimental channel)
- **kgateway** - v2.2.2 (Kubernetes API Gateway)
- **L2 Announcements** - VLAN interface eno1.4000

### Storage

- **Rook/Ceph** - v19.2.3
- **Block Storage** - RBD
- **Object Storage** - S3-compatible

### OpenStack Operators

- **Yaook Operators** - v2.0.3 (charts.yaook.cloud)
- **Operators**: infra, keystone, keystone-resources, glance, nova, nova-compute, neutron, neutron-ovn, horizon

### Certificate Management

- **Cert-Manager** - v1.19.2
- **Internal CA Issuer**

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
- `sveltosctl` - Sveltos multi-cluster management CLI (v1.4.0)

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

| Component    | Version | Repository                                | Sync Interval |
| ------------ | ------- | ----------------------------------------- | ------------- |
| cert-manager | v1.19.2 | jetstack/cert-manager                     | 5m            |
| cilium       | v1.18.6 | cilium/cilium                             | 5m            |
| kgateway     | v2.2.2  | oci://cr.kgateway.dev/kgateway-dev/charts | 5m            |
| rook         | v1.19.0 | rook-release/rook-ceph                    | 5m            |
| yaook-crds   | 2.0.3   | yaook.cloud/crds                          | 5m            |
| yaook-ops    | 2.0.3   | yaook.cloud/operators                     | 5m            |

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
   - gateway-api (CRDs)
   - kgateway-crds (depends on gateway-api)
   - kgateway (depends on kgateway-crds)
   - cilium (with VLAN patches)
   - ceph-adapter-rook
   - rook (setup → configs with health checks)
   - yaook-operator (CRDs first, then operators via dependsOn)

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
kubectl get tlsroute -A
kubectl get backendtlspolicy -A
kubectl get xlistenersets -A
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

**Last Updated**: April 2026
**Repository**: https://github.com/RPCU/argus.git
**Main Branch**: main
**Cluster**: OpenStack
