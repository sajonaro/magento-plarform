.PHONY: up down restart logs status clean help init-dirs kubeconfig

# Default target
.DEFAULT_GOAL := help

# Colors for output
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m # No Color

## up: Start all services (k3s + localstack)
up: init-dirs
	@echo "$(GREEN)Starting Magento platform services...$(NC)"
	docker-compose up -d
	@echo "$(GREEN)Services are starting up...$(NC)"
	@echo "$(YELLOW)Waiting for k3s to be ready...$(NC)"
	@sleep 15
	@echo "$(GREEN)Generating kubeconfig...$(NC)"
	@$(MAKE) kubeconfig
	@echo "$(GREEN)✓ All services are up!$(NC)"
	@echo ""
	@$(MAKE) status

## down: Stop and remove all services
down:
	@echo "$(RED)Stopping Magento platform services...$(NC)"
	docker-compose down
	@echo "$(RED)✓ All services stopped$(NC)"

## restart: Restart all services
restart: down up

## logs: Tail logs from all services
logs:
	docker-compose logs -f

## logs-k3s: Tail logs from k3s only
logs-k3s:
	docker-compose logs -f k3s

## logs-localstack: Tail logs from localstack only
logs-localstack:
	docker-compose logs -f localstack

## status: Show status of all services
status:
	@echo "$(GREEN)=== Service Status ===$(NC)"
	@docker-compose ps
	@echo ""
	@echo "$(GREEN)=== Kubernetes Cluster Info ===$(NC)"
	@if [ -f ./kubeconfig/kubeconfig.yaml ]; then \
		export KUBECONFIG=./kubeconfig/kubeconfig.yaml && \
		kubectl cluster-info 2>/dev/null || echo "$(YELLOW)k3s is still starting...$(NC)"; \
	else \
		echo "$(YELLOW)Kubeconfig not yet generated$(NC)"; \
	fi
	@echo ""
	@echo "$(GREEN)=== Access Information ===$(NC)"
	@echo "Kubernetes API: https://localhost:6443"
	@echo "LocalStack:     http://localhost:4566"
	@echo "Kubeconfig:     ./kubeconfig/kubeconfig.yaml"
	@echo ""
	@echo "$(YELLOW)To use kubectl:$(NC)"
	@echo "export KUBECONFIG=\$$(pwd)/kubeconfig/kubeconfig.yaml"

## clean: Remove all containers, volumes, and generated files
clean: down
	@echo "$(RED)Cleaning up volumes and generated files...$(NC)"
	docker-compose down -v
	rm -rf ./kubeconfig/*.yaml
	rm -rf ./localstack-data
	@echo "$(RED)✓ Cleanup complete$(NC)"

## init-dirs: Create necessary directories
init-dirs:
	@mkdir -p kubeconfig
	@mkdir -p localstack-data
	@mkdir -p k3s-manifests
	@mkdir -p init-scripts

## kubeconfig: Generate and configure kubeconfig for external use
kubeconfig:
	@if [ -f ./kubeconfig/kubeconfig.yaml ]; then \
		echo "$(GREEN)Configuring kubeconfig for external access...$(NC)"; \
		sed -i.bak 's|server:.*|server: https://localhost:6443|g' ./kubeconfig/kubeconfig.yaml; \
		rm -f ./kubeconfig/kubeconfig.yaml.bak; \
		echo "$(GREEN)✓ Kubeconfig ready at: ./kubeconfig/kubeconfig.yaml$(NC)"; \
		echo "$(YELLOW)Run: export KUBECONFIG=\$$(pwd)/kubeconfig/kubeconfig.yaml$(NC)"; \
	else \
		echo "$(RED)Kubeconfig not found. Wait for k3s to start.$(NC)"; \
	fi

## test-k8s: Test Kubernetes cluster connectivity
test-k8s:
	@export KUBECONFIG=./kubeconfig/kubeconfig.yaml && \
	echo "$(GREEN)Testing Kubernetes cluster...$(NC)" && \
	kubectl get nodes && \
	kubectl get namespaces && \
	echo "$(GREEN)✓ Cluster is operational$(NC)"

## test-localstack: Test LocalStack connectivity
test-localstack:
	@echo "$(GREEN)Testing LocalStack services...$(NC)"
	@aws --endpoint-url=http://localhost:4566 s3 ls || echo "$(RED)S3 not ready$(NC)"
	@aws --endpoint-url=http://localhost:4566 sqs list-queues || echo "$(RED)SQS not ready$(NC)"
	@aws --endpoint-url=http://localhost:4566 secretsmanager list-secrets || echo "$(RED)Secrets Manager not ready$(NC)"
	@echo "$(GREEN)✓ LocalStack tests complete$(NC)"

## shell-k3s: Open shell in k3s container
shell-k3s:
	docker-compose exec k3s sh

## shell-localstack: Open shell in localstack container
shell-localstack:
	docker-compose exec localstack sh

## kubectl: Run kubectl commands with auto-configured kubeconfig (e.g., make kubectl get nodes)
kubectl:
	@if [ -f ./kubeconfig/kubeconfig.yaml ]; then \
		export KUBECONFIG=./kubeconfig/kubeconfig.yaml && kubectl $(filter-out $@,$(MAKECMDGOALS)); \
	else \
		echo "$(RED)Kubeconfig not found. Run 'make up' first.$(NC)"; \
		exit 1; \
	fi

# Catch-all target to allow arguments after kubectl
%:
	@:

## help: Show this help message
help:
	@echo "$(GREEN)Magento Platform - Docker Compose Management$(NC)"
	@echo ""
	@echo "$(YELLOW)Usage:$(NC)"
	@echo "  make [target]"
	@echo ""
	@echo "$(YELLOW)Available targets:$(NC)"
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' | sed -e 's/^/ /'
	@echo ""
	@echo "$(YELLOW)Quick Start:$(NC)"
	@echo "  1. make up              # Start all services"
	@echo "  2. make status          # Check service status"
	@echo "  3. make kubectl get nodes  # Use kubectl directly"
	@echo "  4. make test-k8s        # Test Kubernetes"
	@echo "  5. make test-localstack # Test LocalStack"
	@echo "  6. make down            # Stop all services"
