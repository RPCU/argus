# csi-driver-nfs — RWX volumes over NFS (CephFS-backed)

Upstream [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs)
for clusters with **no local Ceph** (the mgmt cluster and opt-in workload
clusters run as OpenStack VMs). Provides **ReadWriteMany (RWX)** volumes from
the openstack cluster's `rpcu-fs` CephFilesystem, exported over NFS by the
Rook `CephNFS` gateway (`infrastructure/rook/configs/cephnfs.yaml`) at the
pinned LB IP `10.0.0.245`.

## Why NFS instead of ceph-csi-cephfs

The Rook cluster runs on **pod networking**: mons advertise ClusterIPs and
the mgr/MDS/OSDs advertise pod IPs in the Ceph cluster maps. An external
ceph-csi client must connect directly to the active mgr (subvolume
provisioning) and to the MDS/OSDs (mount + IO) at those advertised addresses,
which are unreachable from the VMs — LoadBalancer-fronted mons are not
enough (CreateVolume simply hangs; PVCs stay Pending). The NFS gateway runs
in-cluster with full Ceph connectivity; external clients only need TCP/2049
to its LB IP. No Ceph credentials or Vault/ESO plumbing on consumers at all.

## Pieces

- `helmrepo.yaml` / `helmrelease.yaml` — the csi-driver-nfs chart (kube-system,
  same namespace rationale as openstack-cinder-csi: system priority classes).
- `storageclass.yaml` — the `ceph-cephfs` StorageClass (name kept from the
  former ceph-csi-cephfs driver so existing PVC manifests keep working):
  `server: 10.0.0.245`, `share: /rpcu-fs`, one subdirectory per PV.

Identical on every consuming cluster — no per-cluster values, no secrets.
Consumers: `clusters/mgmt/csi-driver-nfs.yaml` (mgmt) and the Sveltos
`csi-driver-nfs` ClusterProfile (opt-in workload clusters, label
`sveltos.argus.rpcu.io/csi-driver-nfs: enabled`).

## One-time export bootstrap (openstack cluster)

The NFS export is stored by the mgr `nfs` module in the `.nfs` RADOS pool
(survives restarts). Create it once:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph nfs export create cephfs rpcu-nfs /rpcu-fs rpcu-fs --path=/
```

If the CephNFS cluster/export is recreated, the export reverts to
`security_label: true` — re-apply with:
`ceph nfs export config apply rpcu-nfs '{"security_label":false,...}'`.

## CRITICAL: consumer nodes MUST disable NFS directory delegations

Linux kernels ≥ 6.11 optimistically send the NFSv4.1 `GET_DIR_DELEGATION`
op when a directory is accessed repeatedly. NFS-Ganesha (ALL released
versions incl. V6.5 — the ceph v19.2.3 image ships V5.9) replies
`NFS4ERR_OP_ILLEGAL` instead of `NFS4ERR_NOTSUPP` (fixed only in ganesha
`next`, unreleased). The client cannot map `OP_ILLEGAL` to an errno and
returns **EREMOTEIO (Remote I/O error)** to userspace, poisoning the dir's
cached state — symptoms: intermittent/flapping `Remote I/O error` on
directory listings (2nd access within the cache window), files "randomly
missing" from Jellyfin/Radarr library scans. Confirmed by packet capture
(status 10044 in reply to op 46).

Because ganesha replies `OP_ILLEGAL` (not `NOTSUPP`), the client does NOT
disable the feature server-wide and keeps hitting it per-directory. Until a
fixed ganesha release ships, every NFS-consuming node needs the `nfsv4`
module parameter `directory_delegations=0`:

```bash
# runtime (lost on reboot — applied to all production workers 2026-07-05):
echo N > /sys/module/nfsv4/parameters/directory_delegations

# permanent (NixOS node image, hephaestus repo):
boot.extraModprobeConfig = "options nfsv4 directory_delegations=0";
```

Takes effect immediately for subsequent lookups (no remount needed).
Verified: 75/75 non-root directory enumerations clean after flipping, vs
persistent flapping failures before. Re-evaluate when the ganesha image
ships the `GET_DIR_DELEGATION → NOTSUPP` fix.
