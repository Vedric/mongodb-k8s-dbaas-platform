#!/usr/bin/env bash
set -euo pipefail

# seed-data.sh - Load sample data into MongoDB for demos and testing
#
# Usage:
#   ./scripts/seed-data.sh [OPTIONS]
#
# Options:
#   --help        Show this help message
#   --dry-run     Print commands without executing

NAMESPACE="${NAMESPACE:-mongodb}"
CLUSTER_NAME="${CLUSTER_NAME:-mongodb-rs}"
RS_NAME="${RS_NAME:-rs0}"
DRY_RUN=false

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

run() {
  if [ "${DRY_RUN}" = true ]; then
    log "[DRY-RUN] $*"
  else
    "$@"
  fi
}

usage() {
  grep '^#' "${BASH_SOURCE[0]}" | grep -v '!/usr/bin' | sed 's/^# \?//'
  exit 0
}

run_mongosh() {
  local pod="${CLUSTER_NAME}-${RS_NAME}-0"
  kubectl exec "${pod}" -n "${NAMESPACE}" -c mongod -- \
    mongosh --quiet --eval "$1" 2>/dev/null
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) log "ERROR: Unknown option: $1"; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# Seed data
# ──────────────────────────────────────────────

seed_products() {
  log "Seeding products collection..."
  run run_mongosh "
    const db = db.getSiblingDB('demo');
    db.products.drop();
    db.products.insertMany([
      { name: 'MongoDB Enterprise Server', category: 'database', price: 0, license: 'SSPL', rating: 4.8 },
      { name: 'Percona Server for MongoDB', category: 'database', price: 0, license: 'Apache-2.0', rating: 4.6 },
      { name: 'Redis Stack', category: 'cache', price: 0, license: 'RSALv2', rating: 4.7 },
      { name: 'PostgreSQL', category: 'database', price: 0, license: 'PostgreSQL', rating: 4.9 },
      { name: 'Elasticsearch', category: 'search', price: 0, license: 'Elastic', rating: 4.5 },
      { name: 'Apache Kafka', category: 'streaming', price: 0, license: 'Apache-2.0', rating: 4.7 },
      { name: 'MinIO', category: 'storage', price: 0, license: 'AGPL-3.0', rating: 4.4 },
      { name: 'HashiCorp Vault', category: 'security', price: 0, license: 'BSL', rating: 4.6 },
      { name: 'Grafana', category: 'observability', price: 0, license: 'AGPL-3.0', rating: 4.8 },
      { name: 'Prometheus', category: 'monitoring', price: 0, license: 'Apache-2.0', rating: 4.7 }
    ], { writeConcern: { w: 'majority' } });
    print('Inserted ' + db.products.countDocuments() + ' products');
  "
}

seed_users() {
  log "Seeding users collection..."
  run run_mongosh "
    const db = db.getSiblingDB('demo');
    db.users.drop();
    const teams = ['alpha', 'beta', 'gamma', 'delta', 'epsilon'];
    const roles = ['developer', 'sre', 'data-engineer', 'architect', 'manager'];
    const docs = [];
    for (let i = 0; i < 50; i++) {
      docs.push({
        username: 'user-' + String(i).padStart(3, '0'),
        email: 'user' + i + '@platform.local',
        team: teams[i % teams.length],
        role: roles[i % roles.length],
        active: i % 10 !== 0,
        created: new Date(2025, 0, 1 + i)
      });
    }
    db.users.insertMany(docs, { writeConcern: { w: 'majority' } });
    print('Inserted ' + db.users.countDocuments() + ' users');
  "
}

seed_events() {
  log "Seeding events collection (time-series style)..."
  run run_mongosh "
    const db = db.getSiblingDB('demo');
    db.events.drop();
    const types = ['login', 'logout', 'query', 'backup', 'alert', 'deploy'];
    const docs = [];
    for (let i = 0; i < 200; i++) {
      docs.push({
        type: types[i % types.length],
        source: 'service-' + (i % 5),
        severity: i % 20 === 0 ? 'critical' : i % 5 === 0 ? 'warning' : 'info',
        message: 'Event ' + i + ' from service-' + (i % 5),
        timestamp: new Date(Date.now() - (200 - i) * 60000),
        metadata: { region: 'eu-west-1', cluster: 'mongodb-rs' }
      });
    }
    db.events.insertMany(docs, { writeConcern: { w: 'majority' } });
    print('Inserted ' + db.events.countDocuments() + ' events');
  "
}

create_indexes() {
  log "Creating indexes..."
  run run_mongosh "
    const db = db.getSiblingDB('demo');
    db.products.createIndex({ category: 1 });
    db.products.createIndex({ rating: -1 });
    db.users.createIndex({ team: 1, role: 1 });
    db.users.createIndex({ email: 1 }, { unique: true });
    db.events.createIndex({ timestamp: -1 });
    db.events.createIndex({ type: 1, severity: 1 });
    print('Indexes created successfully');
  "
}

print_summary() {
  log "Seed data summary:"
  run run_mongosh "
    const db = db.getSiblingDB('demo');
    db.getCollectionNames().forEach(c => {
      const count = db[c].countDocuments();
      const indexes = db[c].getIndexes().length;
      print('  ' + c + ': ' + count + ' documents, ' + indexes + ' indexes');
    });
  "
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  log "Seeding MongoDB with sample data..."

  seed_products
  seed_users
  seed_events
  create_indexes
  print_summary

  log "Seed data loaded successfully."
}

main
