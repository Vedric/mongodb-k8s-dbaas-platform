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
	@echo "TODO: implement in Phase 4"

.PHONY: deploy-observability
deploy-observability: ## Deploy Prometheus + Grafana + Loki + Fluent Bit
	@echo "TODO: implement in Phase 5"

.PHONY: deploy-cdc
deploy-cdc: ## Deploy Kafka (Strimzi) + Debezium connector
	@echo "TODO: implement in Phase 5"

.PHONY: deploy-backup
deploy-backup: ## Configure PBM + MinIO + schedules
	@echo "TODO: implement in Phase 3"

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
