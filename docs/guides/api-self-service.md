# 🔌 Self-Service API Guide

## 📋 Overview

The MongoDB DBaaS Platform exposes a REST API that wraps Crossplane MongoDBInstanceClaim resources. Teams that prefer HTTP over kubectl can use this API to provision, monitor, and delete MongoDB instances.

## 🏗️ Architecture

```
HTTP Client (curl / UI / SDK)
  |
  v
API Gateway (Go, :8081)
  |
  v
Kubernetes API (dynamic client)
  |
  v
Crossplane MongoDBInstanceClaim
  |
  v
Crossplane Composition -> PSMDB CR + Namespace + NetworkPolicy + ResourceQuota
```

## 📖 API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v1alpha1/instances` | List all instances |
| `POST` | `/api/v1alpha1/instances` | Create a new instance |
| `GET` | `/api/v1alpha1/instances/{name}` | Get instance details |
| `DELETE` | `/api/v1alpha1/instances/{name}` | Delete an instance |
| `GET` | `/healthz` | Health check |

## 🚀 Quick Start

### View API documentation (Swagger UI)

```bash
make deploy-api-docs
kubectl port-forward svc/swagger-ui 8081:8081 -n api-docs
# Open http://localhost:8081
```

### Create an instance

```bash
curl -X POST http://localhost:8081/api/v1alpha1/instances \
  -H "Content-Type: application/json" \
  -d '{
    "teamName": "team-alpha",
    "environment": "production",
    "size": "M",
    "version": "7.0",
    "backupEnabled": true,
    "monitoringEnabled": true
  }'
```

### List instances

```bash
curl http://localhost:8081/api/v1alpha1/instances

# Filter by team
curl "http://localhost:8081/api/v1alpha1/instances?teamName=team-alpha"
```

### Get instance status

```bash
curl http://localhost:8081/api/v1alpha1/instances/team-alpha-production
```

### Delete instance

```bash
curl -X DELETE http://localhost:8081/api/v1alpha1/instances/team-alpha-production
```

## 📐 T-Shirt Sizes

| Size | CPU | Memory | Storage |
|------|-----|--------|---------|
| S | 500m | 1Gi | 10Gi |
| M | 1 | 2Gi | 20Gi |
| L | 2 | 4Gi | 50Gi |

## 🔒 Security Notes

This is a **prototype** gateway. Production deployments should add:

- Authentication (JWT, OAuth2, API keys)
- Rate limiting
- Input sanitization and validation
- RBAC mapping (team -> namespace)
- Audit logging
