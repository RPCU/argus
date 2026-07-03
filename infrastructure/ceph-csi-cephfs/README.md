# ceph-csi-cephfs — external CephFS CSI driver (RWX)

Standalone upstream [Ceph CSI](https://github.com/ceph/ceph-csi) CephFS driver
for clusters that have **no local Ceph** (the mgmt cluster and opt-in workload
clusters run as OpenStack VMs). It connects back to the **existing Rook/Ceph
cluster on the bare-metal `openstack` cluster** to provide **ReadWriteMany
(RWX)** volumes via the `rpcu-fs` CephFilesystem.

The in-cluster `general` (RBD) StorageClass is ReadWriteOnce only — a raw block
device can be mounted read-write by a single node at a time. RWX needs a shared
filesystem, which is CephFS (`infrastructure/rook/configs/cephfilesystem.yaml`).

## Pieces

- `namespace.yaml` — `ceph-csi-cephfs` namespace.
- `helmrepo.yaml` — the Ceph CSI charts repo (`https://ceph.github.io/csi-charts`).
- `helmrelease.yaml` — the `ceph-csi-cephfs` chart (v3.15.0). Reads base
  `values.yaml` via `valuesFrom`; the consumer appends a SECOND `valuesFrom`
  with the per-cluster `csiConfig` (mon list) + `clusterID`.
- `values.yaml` — base values. `csiConfig` is intentionally empty and the
  StorageClass `clusterID` blank — overridden per cluster.
- `externalsecret.yaml` — renders the `csi-cephfs-secret` (Ceph user
  `adminID`/`adminKey`) from the mgmt Vault via the `vault-backend`
  ClusterSecretStore.

## Per-cluster override (csiConfig + clusterID)

The base leaves the Ceph connection blank. The consumer supplies a values
override with the remote Ceph cluster's FSID (`clusterID`) and monitor
endpoints, e.g.:

```yaml
csiConfig:
  - clusterID: "<ceph-fsid>"
    monitors:
      - "10.0.0.x:6789"
      - "10.0.0.y:6789"
      - "10.0.0.z:6789"
storageClass:
  clusterID: "<ceph-fsid>"
```

- **mgmt**: `clusters/mgmt/ceph-csi-cephfs.yaml` (a Flux Kustomization) appends
  a `ceph-csi-cephfs-cluster-values` ConfigMap patch.
- **workload clusters**: the Sveltos `ceph-csi-cephfs` ClusterProfile
  (`infrastructure/sveltos/clusterprofiles/ceph-csi-cephfs.yaml`) pushes the same
  override as a ConfigMap.

Get the FSID + mon endpoints from the openstack cluster:

```bash
# FSID (clusterID)
kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.fsid}'
# Monitor endpoints
kubectl -n rook-ceph get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}'
```

The mon endpoints must be reachable from the consuming cluster (the openstack
Ceph mons on `10.0.0.0/24`). If they are not routable, expose them (e.g. a
`LoadBalancer` per mon) before enabling this add-on off-cluster.

## Credential bootstrap (Vault)

The `csi-cephfs-secret` is rendered by ESO from the mgmt Vault KV path
`secrets-<cluster>/ceph-csi`. Populate it once, out of band, from the CephFS
CephClient key Rook created on the openstack cluster:

```bash
# On the openstack cluster — the cephx key for the `cephfs` CephClient
kubectl -n rook-ceph get secret rook-ceph-client-cephfs \
  -o jsonpath='{.data.cephfs}' | base64 -d

# Store it in the mgmt Vault (adjust the mount per consuming cluster:
# secrets-mgmt for mgmt, secrets-<cluster> for a workload cluster)
vault kv put secrets-mgmt/ceph-csi userID=cephfs userKey=<cephx-key>
```

`ceph-csi` wants the bare Ceph user name (`cephfs`), NOT the `client.cephfs`
form. `userKey` is the raw cephx key.
