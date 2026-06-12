# cluster-api-templates

Reusable **Cluster API ClusterClass** (`openstack-default`) and its base
templates for spinning up OpenStack-backed Kubernetes clusters with CAPO.

The design goal: **creating a new cluster should be a small, copy-paste-edit
`Cluster` CR that sets a handful of variables** — never a fork of these
templates. Everything cluster-specific is a ClusterClass _variable_ injected
into the (immutable) base templates by _patches_.

## File layout

```
cluster-api-templates/
├── kustomization.yaml          # ties everything together
├── namespace.yaml              # mgmt namespace
├── clusterclass.yaml           # ClusterClass "openstack-default": variables + patches
├── README.md                   # this file
└── templates/
    ├── controlplane.yaml       # KubeadmControlPlaneTemplate   openstack-default-control-plane-v1
    ├── bootstrap.yaml          # KubeadmConfigTemplate         openstack-default-worker-v1
    ├── infracluster.yaml       # OpenStackClusterTemplate      openstack-default-cluster-v1
    └── machines.yaml           # OpenStackMachineTemplate x2   openstack-default-{control-plane,worker}-v1
```

The OpenStack credentials secret (`mgmt-cloud-config`) that the hardcoded
`identityRef` consumes is **not** created here. It is synced by a separate Flux
Kustomization, `infrastructure/capo-identity/` (SecretStore + ExternalSecret),
so a credential-plumbing failure cannot abort the apply that creates the
ClusterClass templates. See that directory and the section below.

The live `Cluster` CR that consumes this class lives separately at
`clusters/mgmt/clusters/mgmt.yaml` (it is environment state, not a reusable
template).

## Variables (the customisation surface)

Set these in a `Cluster` `spec.topology.variables`:

| Variable                       | Required | Default           | Purpose                                                         |
| ------------------------------ | -------- | ----------------- | --------------------------------------------------------------- |
| `identityRef`                  | yes      | —                 | Secret (`name` + `cloudName`) holding the OpenStack clouds.yaml |
| `externalNetworkId`            | yes      | —                 | ID of the external / floating-IP network                        |
| `imageName`                    | yes      | —                 | Glance image name used for all machines                         |
| `managedSubnetCIDR`            | no       | `192.168.1.0/24`  | CIDR for the managed node subnet                                |
| `managedSubnetAllocationPools` | no       | `.11`–`.254`      | DHCP allocation ranges (leaves low IPs free for manual ports)   |
| `controlPlaneFlavor`           | no       | `large`           | OpenStack flavor for control-plane machines                     |
| `workerFlavor`                 | no       | `xlarge`          | OpenStack flavor for worker machines                            |
| `sshKeyName`                   | no       | `""` (off)        | Existing OpenStack keypair to inject (patch disabled if empty)  |
| `apiServerFloatingIP`          | no       | auto-allocated    | Pin a specific floating IP to the API server LB                 |
| `oidc`                         | no       | `{enabled:false}` | kube-apiserver OIDC via the shared Zitadel "kubernetes" client  |

Topology-level knobs that are _not_ class variables (set them directly under
`spec.topology`): Kubernetes `version`, control-plane `replicas`, and each
`machineDeployments[].replicas`.

### kube-apiserver OIDC (`oidc`)

The `oidc` object variable wires the control-plane apiserver to the **shared
Zitadel "kubernetes" OIDC client** (`clusters/openstack/crossplane/zitadel/oidc-apps.yaml`).
That Zitadel `Oidc` app is a **public / native client using PKCE with NO client
secret**: the kube-apiserver only validates ID tokens against the issuer +
clientID (it never does a client-credential exchange), and `kubectl oidc-login`
(kubelogin) performs the auth-code + PKCE flow from the user's machine. Because
there is no secret, the app has no `writeConnectionSecretToRef` and nothing
needs to be plumbed into the mgmt cluster.

When `oidc.enabled: true`, an `enabledIf` patch appends these apiserver
`extraArgs`: `--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim`,
`--oidc-username-prefix`, `--oidc-groups-claim`, `--oidc-groups-prefix`.

| Field            | Default                                 | Purpose                                   |
| ---------------- | --------------------------------------- | ----------------------------------------- |
| `enabled`        | `false`                                 | Inject the `--oidc-*` flags               |
| `issuerURL`      | `https://rpcu-gabeck.eu1.zitadel.cloud` | OIDC issuer (the Zitadel instance)        |
| `clientID`       | `""`                                    | Client ID of the Zitadel "kubernetes" app |
| `usernameClaim`  | `sub`                                   | ID-token claim → Kubernetes username      |
| `usernamePrefix` | `""`                                    | Username prefix (empty — see groups note) |
| `groupsClaim`    | `groups`                                | ID-token claim → Kubernetes groups        |
| `groupsPrefix`   | `""`                                    | Group prefix (empty — bare group names)   |

**clientID must be copied by hand**: Zitadel generates the Client ID when it
creates the `Oidc` app, so it cannot be known declaratively up front. Read it
off the app (or its status/the Zitadel console) and paste it into the cluster's
`oidc.clientID`, then flip `enabled: true`. Do **not** enable with an empty
`clientID` — the apiserver would start with a broken `--oidc-client-id` flag.
Enabling/disabling rolls the control-plane machines (apiserver flag change).

### Group mapping & RBAC

The `kubernetes` Zitadel project defines `kube-user` / `kube-admin` roles
(`clusters/openstack/crossplane/zitadel/roles.yaml`). The shared Zitadel
**`groupsClaim` Action** (`clusters/openstack/crossplane/zitadel/actions.yaml`)
collects each user's granted project role keys and writes them into the token's
`groups` claim as **bare names** (e.g. `kube-admin`, `kube-user` — no prefix).

Because the groups arrive bare, the ClusterClass sets an **empty `groupsPrefix`**
so the apiserver presents the Kubernetes group exactly as `kube-admin` /
`kube-user`. The RBAC bindings that grant those groups access live at
**`clusters/mgmt/apps/kubernetes-rbac/`** (applied by the `kubernetes-rbac` Flux
Kustomization):

- `kube-admin` → `cluster-admin` ClusterRole
- `kube-user` → `view` ClusterRole

This mirrors the bealv reference setup (`gitops/apps/kubernetes/crb.yaml` binds
the bare `kube-admin` group to `cluster-admin`). If you set a non-empty
`groupsPrefix`, you must rename the binding subjects to `<prefix>kube-admin`
accordingly.

### OpenStack credentials (`identityRef`)

CAPO validates `identityRef` as **required** at admission time, so it must be
present in the base template — it cannot be added purely by a patch. The base
template carries a hardcoded default (`mgmt-cloud-config`, cloud `openstack`).

The ClusterClass `identityRef` variable/patch **overrides** this default when
the topology controller synthesizes the concrete `OpenStackCluster` per-cluster.
So different clusters can still target different OpenStack projects: set
`identityRef` in your `Cluster` CR to point at a different `clouds.yaml`
secret.

The `mgmt` cluster ships with `infrastructure/capo-identity/` (its own Flux
Kustomization), which syncs the manually-placed `capo-variables` secret from
`capo-system` into `mgmt-cloud-config` in the `mgmt` namespace. The default
`Cluster` CR at `clusters/mgmt/clusters/mgmt.yaml` references this secret.
To create clusters in a different OpenStack project, place a separate
`clouds.yaml` secret in `mgmt` (manually or via another ESO sync) and point
your `Cluster`'s `identityRef` at it.

## Creating a new cluster

1. Write a `Cluster` CR referencing `classRef.name: openstack-default`.
2. Set the required variables (`identityRef`, `externalNetworkId`, `imageName`)
   plus any optional overrides.
3. Ensure the referenced identity secret exists in the cluster's namespace.

A minimal example (see `clusters/mgmt/clusters/mgmt.yaml` for a real one):

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: my-cluster
  namespace: mgmt
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    serviceDomain: cluster.local
  topology:
    classRef:
      name: openstack-default
    version: v1.35.4
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 3
    variables:
      - name: identityRef
        value: { name: my-cloud-config, cloudName: openstack }
      - name: externalNetworkId
        value: <external-network-uuid>
      - name: imageName
        value: hephaestus-kaas-25.11-v1.35.4
```

## ⚠️ Immutability & the `-vN` rotation workflow

CAPI treats the `spec.template.spec` of these template kinds as **immutable**
once a `ClusterClass` references them:

- `KubeadmControlPlaneTemplate`
- `KubeadmConfigTemplate`
- `OpenStackClusterTemplate`
- `OpenStackMachineTemplate`

You **cannot** edit a `-v1` in place to change machine flavors-by-hand, kubelet
args, security groups, etc. on a live cluster — the topology controller will
reject or fail to roll the change.

If the field is already driven by a **variable/patch** (flavor, image, subnet,
SSH key, floating IP, …) just change the value in the `Cluster` CR — no rotation
needed. For anything **not** covered by a patch, rotate the template:

1. Copy the template block to a new resource with a bumped suffix, e.g.
   `openstack-default-control-plane-v2`, and make your edit there. Keep `-v1`
   until the migration is done.
2. Add the new file to `kustomization.yaml`.
3. Point the matching `templateRef` in `clusterclass.yaml` at `-v2`.
4. Flux applies it; the topology controller performs a rolling replacement of
   the affected machines (control-plane or the worker `MachineDeployment`).
5. Once everything has rolled and is healthy, delete the now-unreferenced
   `-v1` resource and its entry in `kustomization.yaml`.

This keeps the change explicit, auditable, and safely rolled out via GitOps.

## Notes

- The `managedSecurityGroups` block in `infracluster.yaml` opens the Cilium
  data-plane (VXLAN 8472, health 4240, Hubble 4244, ICMP) on top of
  `allowAllInClusterTraffic: true`. See the root `AGENTS.md` ("CAPO managed
  security groups must open the Cilium overlay") for why this is mandatory.
- `infracluster.yaml` now also carries `openstack-default-cluster-v2`, which is
  identical to `-v1` plus an ingress rule opening the Kubernetes **NodePort
  range (TCP 30000–32767, from `0.0.0.0/0`)**. This is REQUIRED for external
  `type: LoadBalancer` Services on clusters that use the OpenStack CCM + Octavia
  (e.g. mgmt): the Octavia/OVN VIP forwards traffic to `<node IP>:<nodePort>`,
  and CAPO's default managed SGs do not open that range — so without it the LB
  floating IP times out at the TCP layer even though the VIP, floating IP and
  DNS are all correct. The ClusterClass `infrastructure.templateRef` points at
  `-v2`; `-v1` is retained only until the rotation is confirmed, then deleted
  (this is exactly the `-vN` workflow above — an `OpenStackClusterTemplate`
  rotation reconciles the SGs onto the live `OpenStackCluster` without rolling
  machines).
- Machine `flavor`/`image` in `machines.yaml` are deliberate `dummy`
  placeholders — they are always overwritten by patches.
