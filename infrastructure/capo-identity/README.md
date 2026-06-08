# capo-identity

Syncs the OpenStack `clouds.yaml` into the `mgmt` namespace as the secret
`mgmt-cloud-config`, which the `openstack-default` ClusterClass references via
the hardcoded `OpenStackCluster.identityRef` (see
`infrastructure/cluster-api-templates/`).

## Why this is a separate Flux Kustomization

The credential plumbing (SecretStore + ExternalSecret) and the CAPI
ClusterClass/templates have **different readiness dependencies**:

- The ExternalSecret only becomes Ready once the **manually-placed**
  `capo-variables` secret exists in `capo-system`
  (see `infrastructure/cluster-api-providers/README.md`).
- The CAPI templates need nothing but the CAPO/kubeadm CRDs.

Keeping them in one Kustomization caused a real outage: a dry-run admission
failure on the SecretStore aborted the whole apply, so the `ClusterClass` was
created but its referenced templates were not — leaving the topology controller
erroring with "could not find external object for the ClusterClass". Splitting
them isolates that blast radius.

## Contents

- `namespace.yaml` — `mgmt` namespace.
- `secretstore.yaml` — `ServiceAccount capo-identity-reader` (mgmt) +
  `Role`/`RoleBinding capo-variables-reader` (capo-system, scoped to the
  `capo-variables` secret) + ESO `SecretStore capo-system-secrets` (mgmt,
  Kubernetes provider, `remoteNamespace: capo-system`).
- `externalsecret.yaml` — ESO `ExternalSecret` projecting
  `capo-variables.clouds.yaml` (capo-system) → `mgmt/mgmt-cloud-config`.

## Flux wiring

Deployed by `clusters/mgmt/capo-identity.yaml`:

- `dependsOn: external-secrets` (ESO CRDs/operator) and `cluster-api-providers`
  (creates the `capo-system` namespace where the RBAC lives and `capo-variables`
  is placed).
- `wait: false` on purpose — the ExternalSecret cannot be Ready until the manual
  `capo-variables` secret exists, and we do not want to block on that manual
  step. The objects are applied and sync on their own once the source appears.

## Caveats

- `caProvider.namespace` must **not** be set on a namespaced `SecretStore`
  (admission rejects it); the CA ConfigMap `kube-root-ca.crt` is read from the
  SecretStore's own namespace.
- If you change the source key, keep `remoteRef.key: capo-variables` /
  `property: clouds.yaml` in sync with how the secret is placed.
