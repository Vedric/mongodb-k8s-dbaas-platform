# TLS Configuration for MongoDB

## Overview

All MongoDB communications are encrypted using TLS 1.2+ certificates managed by [cert-manager](https://cert-manager.io/). This covers:

- **Intra-cluster**: Member-to-member replication traffic within replica sets
- **Client connections**: Application-to-MongoDB connections via mongos or direct to replica set
- **Sharded cluster**: All traffic between mongos, config servers, and shard replica sets

## Certificate Architecture

```
ClusterIssuer (self-signed)
    |
    v
CA Certificate (mongodb-ca, 10y validity)
    |
    v
Issuer (mongodb-tls-issuer, per namespace)
    |
    +-- Certificate: mongodb-rs-tls (replica set)
    +-- Certificate: mongodb-sharded-tls (sharded cluster)
```

### Certificate Details

| Certificate | Namespace | Validity | Renewal | Secret |
|-------------|-----------|----------|---------|--------|
| `mongodb-ca` | cert-manager | 10 years | 1 year before expiry | `mongodb-ca-secret` |
| `mongodb-rs-tls` | mongodb | 1 year | 30 days before expiry | `mongodb-rs-tls-secret` |
| `mongodb-sharded-tls` | mongodb-sharded | 1 year | 30 days before expiry | `mongodb-sharded-tls-secret` |

### Key Specifications

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| CA algorithm | ECDSA P-256 | Smaller key size, faster TLS handshake |
| Server/client algorithm | RSA 2048 | Broad compatibility with MongoDB drivers |
| Key encoding | PKCS8 | Required by Percona Operator |
| Usages | server auth, client auth | Mutual TLS between members |

## Integration with Percona Operator

The Percona Operator references TLS secrets in the PerconaServerMongoDB CR:

```yaml
spec:
  secrets:
    ssl: mongodb-rs-tls-secret        # Server certificate
    sslInternal: mongodb-rs-tls-secret # Internal member certificate
```

> **Note**: The `ssl` and `sslInternal` secrets must contain `tls.crt`, `tls.key`, and `ca.crt` keys. cert-manager populates these automatically.

## Production Considerations

1. **Replace the self-signed CA** with an organization-managed CA or Vault PKI backend for production deployments
2. **Monitor certificate expiry** using the Prometheus cert-manager exporter (`cert_manager_certificate_expiration_timestamp_seconds`)
3. **Test certificate rotation** before deploying to production - cert-manager handles renewal automatically, but the Percona Operator must be configured to detect and reload certificates
4. **Client certificates**: For applications requiring mTLS, issue additional certificates from the same CA using cert-manager

## Deployment Order

1. Install cert-manager (prerequisite)
2. Apply `issuer.yaml` (ClusterIssuer + CA Certificate + Namespace Issuer)
3. Apply `certificate.yaml` (server/client certificates)
4. Update Percona CR to reference TLS secrets
5. Verify with: `kubectl get certificates -A`
