.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────
KIND_CLUSTER_NAME ?= mongodb-dbaas
KUBECONFIG ?= $(HOME)/.kube/config
OPERATOR_NAMESPACE ?= mongodb-operator
HELM_REPO_NAME ?= percona
HELM_REPO_URL ?= https://percona.github.io/percona-helm-charts/

# ──────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────
.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

# ──────────────────────────────────────────────
# Linting
# ──────────────────────────────────────────────
.PHONY: lint
lint: lint-yaml lint-shell lint-helm ## Run all linters

.PHONY: lint-yaml
lint-yaml: ## Run yamllint on all YAML files
	@echo "Running yamllint..."
	@yamllint -c .yamllint.yaml .

.PHONY: lint-shell
lint-shell: ## Run shellcheck on all shell scripts
	@echo "Running shellcheck..."
	@find . -name '*.sh' -type f -exec shellcheck --severity=warning {} +

.PHONY: lint-helm
lint-helm: ## Run helm lint on all charts (if any)
	@echo "Running helm lint..."
	@charts=$$(find . -name 'Chart.yaml' -exec dirname {} \;); \
	if [ -n "$$charts" ]; then \
		echo "$$charts" | while read -r chart; do helm lint "$$chart"; done; \
	else \
		echo "No Helm charts found, skipping."; \
	fi

# ──────────────────────────────────────────────
# Platform lifecycle
# ──────────────────────────────────────────────
.PHONY: bootstrap
bootstrap: ## Create kind cluster and deploy full platform
	@./scripts/bootstrap.sh

.PHONY: teardown
teardown: ## Destroy kind cluster and clean up
	@./scripts/teardown.sh

# ──────────────────────────────────────────────
# Deployment targets (placeholders for Phase 2+)
# ──────────────────────────────────────────────
.PHONY: deploy-operator
deploy-operator: ## Install Percona Operator for MongoDB
	@echo "Deploying Percona Operator for MongoDB..."
	@kubectl apply -k operator/
	@helm repo add $(HELM_REPO_NAME) $(HELM_REPO_URL) 2>/dev/null || true
	@helm repo update $(HELM_REPO_NAME)
	@helm upgrade --install psmdb-operator-crds $(HELM_REPO_NAME)/psmdb-operator-crds \
		--namespace $(OPERATOR_NAMESPACE)
	@helm upgrade --install psmdb-operator $(HELM_REPO_NAME)/psmdb-operator \
		--namespace $(OPERATOR_NAMESPACE) \
		-f operator/percona-server-mongodb-operator/values.yaml \
		--wait --timeout 120s
	@echo "Percona Operator deployed successfully."

.PHONY: deploy-replicaset
deploy-replicaset: ## Deploy 3-node replica set
	@echo "Deploying 3-node MongoDB replica set..."
	@kubectl create namespace mongodb --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -k clusters/replicaset/
	@echo "Waiting for replica set to become ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=mongod \
		-n mongodb --timeout=300s 2>/dev/null || \
		echo "Timeout waiting for pods (may still be initializing)."
	@echo "Replica set deployment initiated."

.PHONY: deploy-sharded
deploy-sharded: ## Deploy sharded cluster
	@echo "Deploying sharded MongoDB cluster..."
	@kubectl create namespace mongodb-sharded --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -k clusters/sharded/
	@echo "Waiting for sharded cluster to become ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=mongos \
		-n mongodb-sharded --timeout=300s 2>/dev/null || \
		echo "Timeout waiting for mongos pods (may still be initializing)."
	@echo "Sharded cluster deployment initiated."

.PHONY: deploy-self-service
deploy-self-service: ## Install Crossplane + XRDs + Compositions
	@echo "Deploying Crossplane self-service layer..."
	@kubectl apply -f self-service/crossplane/xrd.yaml
	@echo "Waiting for XRD to be established..."
	@sleep 5
	@kubectl apply -f self-service/crossplane/composition.yaml
	@echo "Self-service layer deployed (XRD + Composition)."
	@echo "Submit claims from self-service/crossplane/examples/ to provision instances."

.PHONY: deploy-observability
deploy-observability: ## Deploy Prometheus + Grafana + Loki + Fluent Bit
	@echo "Deploying observability stack..."
	@kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -
	@echo "Installing kube-prometheus-stack via Helm..."
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	@helm repo update prometheus-community
	@helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace monitoring \
		-f observability/kube-prometheus-stack/values.yaml \
		--wait --timeout 300s
	@echo "kube-prometheus-stack installed."
	@echo "Deploying Grafana dashboard ConfigMaps..."
	@kubectl apply -k observability/grafana/configmaps/
	@echo "Deploying MongoDB exporter configuration..."
	@kubectl apply -f observability/prometheus/mongodb-exporter.yaml
	@kubectl apply -f observability/prometheus/servicemonitor.yaml
	@kubectl apply -f observability/prometheus/prometheus-rules.yaml
	@kubectl apply -f observability/alerting/critical-alerts.yaml
	@echo "Deploying logging stack..."
	@kubectl apply -f observability/logging/fluent-bit-config.yaml
	@kubectl apply -f observability/logging/fluent-bit-daemonset.yaml
	@kubectl apply -f observability/logging/loki-datasource.yaml
	@echo "Observability stack deployed."
	@echo "Access Grafana: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
	@echo "Credentials: admin / admin"

.PHONY: deploy-cdc
deploy-cdc: ## Deploy Kafka (Strimzi) + Debezium connector
	@echo "Deploying CDC pipeline..."
	@kubectl apply -f cdc/kafka/strimzi-operator.yaml
	@echo "Install Strimzi operator via Helm (see cdc/kafka/strimzi-operator.yaml)"
	@kubectl apply -f cdc/kafka/kafka-cluster.yaml
	@echo "Waiting for Kafka cluster to become ready..."
	@kubectl wait kafka/mongodb-cdc -n kafka --for=condition=Ready \
		--timeout=300s 2>/dev/null || \
		echo "Timeout waiting for Kafka cluster (may still be initializing)."
	@kubectl apply -f cdc/kafka/kafka-topic.yaml
	@kubectl apply -f cdc/debezium/mongodb-connector.yaml
	@echo "CDC pipeline deployed (Kafka + Debezium + topics)."

.PHONY: deploy-backup
deploy-backup: ## Configure PBM + MinIO + schedules
	@echo "Deploying backup infrastructure..."
	@kubectl create namespace mongodb-backup --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f backup/minio/deployment.yaml
	@kubectl apply -f backup/minio/service.yaml
	@kubectl apply -f backup/pbm-config.yaml
	@kubectl apply -f backup/schedule-daily-snapshot.yaml
	@kubectl apply -f backup/schedule-oplog-continuous.yaml
	@echo "Waiting for MinIO to become ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=minio \
		-n mongodb-backup --timeout=120s 2>/dev/null || \
		echo "Timeout waiting for MinIO pod."
	@echo "Backup infrastructure deployed."

# ──────────────────────────────────────────────
# Data & utilities
# ──────────────────────────────────────────────
.PHONY: seed-data
seed-data: ## Load sample data into MongoDB
	@./scripts/seed-data.sh

.PHONY: port-forward
port-forward: ## Port-forward Grafana, Mongo, Kafka UIs
	@./scripts/port-forward.sh

# ──────────────────────────────────────────────
# Testing
# ──────────────────────────────────────────────
.PHONY: test
test: ## Run full bats test suite
	@echo "Running bats tests..."
	@bats tests/bats/

.PHONY: test-chaos
test-chaos: ## Run chaos engineering scenarios
	@echo "Running chaos tests..."
	@for script in tests/chaos/*.sh; do bash "$$script"; done

.PHONY: demo-chaos
demo-chaos: ## Run chaos demo (kill primary + failover + recovery)
	@./scripts/demo-chaos.sh

.PHONY: test-backup
test-backup: ## Run backup/restore validation cycle
	@echo "Running backup validation..."
	@bash tests/ci/backup-restore-ephemeral.sh

# ──────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────
.PHONY: clean
clean: ## Remove generated files
	@echo "Cleaning generated files..."
	@rm -rf tmp/ minio-data/
	@find . -name '*.tmp' -delete
	@find . -name '*.bak' -delete
	@echo "Clean complete."
