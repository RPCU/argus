# Vault (mgmt cluster)

HashiCorp Vault deployed in **HA mode with integrated Raft storage** (3-node
quorum, no external Consul) on the mgmt cluster.

- Namespace: `vault`
- Replicas: 3 (StatefulSet). The chart's server podAntiAffinity is
  `requiredDuringSchedulingIgnoredDuringExecution` on hostname, so the 3 pods
  **require 3 distinct schedulable nodes** — fewer nodes leave the extras
  `Pending`. Drop `server.ha.replicas` (e.g. to 1) if mgmt is smaller.
- Storage: one 10Gi Cinder PVC per replica (`cinder-delete` StorageClass),
  backing Raft.
- TLS: disabled in-cluster (`global.tlsDisable: true`); external TLS is
  terminated at the shared kgateway `https` Gateway via the `httproute.yaml`
  at `vault.mgmt.rpcu.lan` (root-mgmt CA wildcard cert `rpcu-lan-wildcard-tls`).
  The HTTPRoute targets the chart's leader-aware `vault` service.
- The chart's bundled Ingress is disabled — this cluster routes ingress through
  the Gateway API (kgateway), not an Ingress controller.
- Readiness probe enabled (Service only routes to unsealed pods); liveness
  probe disabled (a sealed pod must not be killed during bootstrap/unseal).

## Bootstrap an HA Raft cluster for the first time

All pods start **sealed**. Initialise on the first pod, then unseal it, then
join + unseal the rest.

1. Initialise + unseal the first node (`vault-0`):

   ```
   kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=3 -key-threshold=2
   # record the unseal keys + root token, then unseal (run 2 of the 3 keys):
   kubectl -n vault exec -it vault-0 -- vault operator unseal <key1>
   kubectl -n vault exec -it vault-0 -- vault operator unseal <key2>
   ```

2. Join + unseal the remaining nodes (`vault-1`, `vault-2`):

   ```
   kubectl -n vault exec -it vault-1 -- \
     vault operator raft join http://vault-0.vault-internal:8200
   kubectl -n vault exec -it vault-1 -- vault operator unseal <key1>
   kubectl -n vault exec -it vault-1 -- vault operator unseal <key2>
   # repeat for vault-2
   ```

3. Verify the Raft peer set (from an unsealed pod, logged in with the root token):

   ```
   kubectl -n vault exec -it vault-0 -- vault operator raft list-peers
   ```

Every pod starts sealed again after any restart and must be re-unsealed
(manually with the recorded keys, or via an auto-unseal mechanism).

## Crossplane bootstrap (one-time manual)

After Vault is initialised and unsealed, run these once:

```bash
export VAULT_POD="kubectl -n vault exec -it vault-0 --"

# Enable KV v2 at secrets/
$VAULT_POD vault secrets enable -path=secrets kv-v2

# Enable Kubernetes auth (for ESO)
$VAULT_POD vault auth enable kubernetes
$VAULT_POD vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# Create policy for Crossplane
$VAULT_POD vault policy write crossplane - <<'EOF'
path "secrets/data/mgmt/crossplane" {
  capabilities = ["read"]
}
path "secrets/data/mgmt/crossplane/*" {
  capabilities = ["read", "list"]
}
path "secrets/metadata/mgmt/crossplane/*" {
  capabilities = ["list"]
}
path "auth/approle/login" {
  capabilities = ["create", "update"]
}
path "pki-int/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "pki/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

# Create AppRole for Crossplane
$VAULT_POD vault write auth/approle/role/crossplane \
  token_policies=crossplane \
  token_ttl=1h

# Get credentials and seed them
ROLE_ID=$($VAULT_POD vault read -field=role_id auth/approle/role/crossplane/role-id)
SECRET_ID=$($VAULT_POD vault write -f -field=secret_id auth/approle/role/crossplane/secret-id)

$VAULT_POD vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=vault-auth \
  bound_service_account_namespaces=external-secrets \
  policies=crossplane \
  ttl=1h

$VAULT_POD vault kv put secrets/mgmt/crossplane \
  role-id="$ROLE_ID" \
  secret-id="$SECRET_ID"
```

Once done, the Crossplane resources in `clusters/mgmt/crossplane/vault/` take over:

- `vault-backend` ClusterSecretStore (ESO reads from Vault via K8s auth)
- `vault-creds` ExternalSecret (renders AppRole credentials for Crossplane)
- `default` ProviderConfig (Crossplane Vault provider authenticates)
- `cert-manager` AppRole (Crossplane creates per-cluster cert auth)
