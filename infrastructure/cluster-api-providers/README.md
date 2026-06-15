# Cluster API providers — manual CAPO credentials

The OpenStack infrastructure provider (CAPO) reads its provider-level
credentials from a secret named `capo-variables` in the `capo-system`
namespace, referenced by `infrastructure-openstack.yaml`
(`spec.configSecret`). The secret must contain a `clouds.yaml` key.

On the **mgmt cluster** the `keystone-admin` secret does not exist (it lives in
the `yaook` namespace on the OpenStack cluster), so `capo-variables` is created
**manually** rather than synced by External Secrets.

> Barbican is installed on the OpenStack cluster (operator + `BarbicanDeployment`
>
> - gateway route at `barbican.rpcu.vpn`) and can be used as the long-term
>   source of truth for these credentials. Today the ESO Barbican provider is
>   read-only and not present in the deployed ESO release, so the secret below is
>   placed by hand.

## Create the secret

Fill in the admin credentials (matching the OpenStack cluster's
`keystone-admin` secret) and apply to the mgmt cluster:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: capo-variables
  namespace: capo-system
type: Opaque
stringData:
  clouds.yaml: |
    clouds:
      openstack:
        auth:
          auth_url: https://keystone.rpcu.vpn/v3
          username: "<OS_USERNAME>"
          password: "<OS_PASSWORD>"
          project_name: "<OS_PROJECT_NAME>"
          user_domain_name: "<OS_USER_DOMAIN_NAME>"
        region_name: hetzner
        verify: false
        interface: public
        identity_api_version: 3
EOF
```

The values can be read from the OpenStack cluster:

```bash
kubectl --context openstack -n yaook get secret keystone-admin \
  -o jsonpath='{.data.OS_USERNAME}' | base64 -d
# repeat for OS_PASSWORD, OS_PROJECT_NAME, OS_PROJECT_DOMAIN_NAME, OS_USER_DOMAIN_NAME
```

## Notes

- `auth_url` uses the **gateway endpoint** (`keystone.rpcu.vpn`) because the
  mgmt cluster cannot resolve in-cluster DNS names from the OpenStack cluster
  (`keystone.yaook.svc`). `interface: public` and `verify: false` are set
  accordingly.
- CAPO, the CCM, and the Cinder CSI all share this same `capo-variables`
  secret. The provider-openstack on mgmt reads it via ESO and renders
  `crossplane-provider-openstack` in `crossplane-system`.
- Because the secret is managed manually, `prune: true` on the
  `cluster-api-providers` Flux Kustomization will not touch it (it is not part
  of the Git-tracked manifests).
- Per-cluster OpenStack credentials are still supplied separately by each
  `Cluster` via its `OpenStackCluster` `identityRef` secret.
