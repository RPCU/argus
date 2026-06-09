# openstack-ccm-identity

Renders the OpenStack Cloud Controller Manager (OCCM) `cloud-config` secret in
`kube-system` from the OpenStack `clouds.yaml`, so the CCM
(`infrastructure/openstack-ccm`) can authenticate to OpenStack and drive Octavia
for `Service` type `LoadBalancer`.

## What it produces

A secret `kube-system/cloud-config` with two keys, both projected by the chart
into `/etc/config` (the CCM reads `/etc/config/cloud.conf`):

- `clouds.yaml` — copied verbatim from `capo-variables` (the OpenStack auth
  credentials: `auth_url`, `username`, `password`, project + domains).
- `cloud.conf` — the INI config the CCM binary reads:
  - `[Global] use-clouds=true` delegates authentication to `clouds.yaml`
    (`clouds-file=/etc/config/clouds.yaml`, `cloud=openstack`), so there is a
    single credential source of truth — exactly like CAPO's `identityRef`.
  - `[LoadBalancer]` configures Octavia: `floating-network-id` is the OpenStack
    external network used to allocate floating IPs for Service VIPs. It matches
    the Cluster's `externalNetworkId` (`clusters/mgmt/clusters/mgmt.yaml`).

## Why this is a separate Flux Kustomization

Same rationale as `infrastructure/capo-identity`: the ExternalSecret only
becomes Ready once the **manually-placed** `capo-variables` secret exists in
`capo-system` (see `infrastructure/cluster-api-providers/README.md`). Keeping
the credential plumbing separate from the CCM HelmRelease isolates that blast
radius — an ESO admission/backend failure cannot abort the CCM apply.

## Contents

- `secretstore.yaml` — `ServiceAccount openstack-ccm-reader` (kube-system) +
  `Role`/`RoleBinding openstack-ccm-capo-variables-reader` (capo-system, scoped
  to the `capo-variables` secret) + ESO `SecretStore capo-system-secrets`
  (kube-system, Kubernetes provider, `remoteNamespace: capo-system`).
- `externalsecret.yaml` — ESO `ExternalSecret` rendering
  `kube-system/cloud-config` (`cloud.conf` + `clouds.yaml`).

## Flux wiring

Deployed by `clusters/mgmt/openstack-ccm-identity.yaml`:

- `dependsOn: external-secrets` (ESO CRDs/operator) and `cluster-api-providers`
  (creates the `capo-system` namespace where the RBAC lives and `capo-variables`
  is placed).
- `wait: false` on purpose — the ExternalSecret cannot be Ready until the manual
  `capo-variables` secret exists, and we do not want to block on that manual
  step (nor block the CCM apply). The CCM Pods wait/CrashLoop until the secret
  appears, which is expected.

## Caveats

- `caProvider.namespace` must **not** be set on a namespaced `SecretStore`
  (admission rejects it); the CA ConfigMap `kube-root-ca.crt` is read from the
  SecretStore's own namespace.
- If you change the external network, update `floating-network-id` in
  `externalsecret.yaml` (keep it in sync with the Cluster's `externalNetworkId`).
- `tls-insecure=true` matches the `verify: false` in the in-cluster Keystone
  `clouds.yaml`. If you switch to a trusted CA, drop it and add `ca-file`.
