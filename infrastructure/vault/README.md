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

# Enable a per-cluster KV v2 mount for the mgmt cluster (secrets-mgmt).
# Per-cluster mount convention: each cluster reads from its own secrets-<cluster>
# mount. The Sveltos vault-auth add-on
# (infrastructure/sveltos/clusterprofiles/vault-auth.yaml) provisions the
# equivalent secrets-<cluster> mounts/policies/auth-backends for workload
# clusters; this is the manual equivalent for mgmt itself.
$VAULT_POD vault secrets enable -path=secrets-mgmt kv-v2

# Enable Kubernetes auth (for ESO)
$VAULT_POD vault auth enable kubernetes
$VAULT_POD vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# Create policy for Crossplane (reads its AppRole creds from secrets-mgmt/crossplane)
$VAULT_POD vault policy write crossplane - <<'EOF'
path "secrets-mgmt/data/crossplane" {
  capabilities = ["read"]
}
path "secrets-mgmt/data/crossplane/*" {
  capabilities = ["read", "list"]
}
path "secrets-mgmt/metadata/crossplane/*" {
  capabilities = ["list"]
}
path "auth/approle/login" {
  capabilities = ["create", "update"]
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

$VAULT_POD vault kv put secrets-mgmt/crossplane \
  role-id="$ROLE_ID" \
  secret-id="$SECRET_ID"
```

Once done, the Crossplane resources in `clusters/mgmt/crossplane/vault/` take over:

- `vault-backend` ClusterSecretStore (ESO reads from Vault via K8s auth)
- `vault-creds` ExternalSecret (renders AppRole credentials for Crossplane)
- `default` ProviderConfig (Crossplane Vault provider authenticates)
- `cert-manager` AppRole (Crossplane creates per-cluster cert auth)

## Vault PKI intermediate bootstrap (one-time manual)

`clusters/mgmt/crossplane/vault/pki-int.yaml` chains a Vault PKI **intermediate
CA** (`pki-int` mount) under the cert-manager **`root-mgmt`** self-signed root.
This intermediate is the shared signer for the per-cluster cert-manager add-on
(`infrastructure/sveltos/clusterprofiles/cert-manager.yaml`): each opt-in
workload cluster gets a Vault PKI _Role_ on this mount whose `allowedDomains` is
locked to `<cluster>.rpcu.lan`, so Vault enforces subdomain isolation between
clusters even though they share one intermediate.

Crossplane creates the `pki-int` mount and asks Vault to generate the
intermediate key + CSR internally (`SecretBackendIntermediateCertRequest`, key
`pki-int`; the private key never leaves Vault). The CSR is written to
`crossplane-system/pki-int-csr` (key `csr`). Signing that CSR with `root-mgmt`
is the one step cert-manager cannot do declaratively (it signs
`CertificateRequest`s that reference an Issuer, not an arbitrary CSR), so do it
once by hand:

1. Extract the Vault-generated CSR:

   ```bash
   kubectl -n crossplane-system get secret pki-int-csr \
     -o jsonpath='{.data.csr}' | base64 -d > /tmp/pki-int.csr
   ```

2. Sign it with the `root-mgmt` CA (private key + cert live in the
   `cert-manager/root-mgmt` secret). Extract them and sign the CSR with openssl
   (CA:TRUE intermediate, pathlen 0, 5-year validity):

   ```bash
   kubectl -n cert-manager get secret root-mgmt \
     -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/root-mgmt.crt
   kubectl -n cert-manager get secret root-mgmt \
     -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/root-mgmt.key

   cat > /tmp/int-ext.cnf <<'EOF'
   basicConstraints = critical, CA:TRUE, pathlen:0
   keyUsage = critical, digitalSignature, cRLSign, keyCertSign
   EOF

   openssl x509 -req -in /tmp/pki-int.csr \
     -CA /tmp/root-mgmt.crt -CAkey /tmp/root-mgmt.key -CAcreateserial \
     -days 1825 -sha256 -extfile /tmp/int-ext.cnf \
     -out /tmp/pki-int.crt
   ```

3. Build the PEM bundle (intermediate first, then the root) and set it back into
   Vault. Either paste it into the `SecretBackendConfigCa` `pemBundle` in
   `pki-int.yaml` and flip `crossplane.io/paused` to `"false"`, or apply it
   directly:

   ```bash
   cat /tmp/pki-int.crt /tmp/root-mgmt.crt > /tmp/pki-int-bundle.pem
   kubectl -n vault exec -i vault-0 -- \
     vault write pki-int/intermediate/set-signed \
     certificate=- < /tmp/pki-int-bundle.pem
   ```

After the signed intermediate is set, the `pki-int` mount can issue certs and
the Sveltos `cert-manager` ClusterProfile's per-cluster PKI Roles become
functional. Clean up `/tmp/root-mgmt.*` afterwards — it is the root CA private
key.
