# Common operations for managing the Azure lab infrastructure

SHELL := /bin/bash
.ONESHELL:
.ENV:

# Colors
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

.PHONY: help
help: ## Show this help message
	@echo "Azure Lab - Available commands"
	@echo ""
	@echo "Validation:"
	@echo "  make validate            Validate environment and prerequisites"
	@echo ""
	@echo "Bootstrap (one-time setup):"
	@echo "  make bootstrap           Run bootstrap script (prerequisites, SP, providers)"
	@echo ""
	@echo "Infrastructure deployment:"
	@echo "  make build               Build the lab infrastructure baseline"
	@echo "  make deploy-tailscale    Deploy the Tailscale VM"
	@echo "  make destroy-tailscale   Destroy the Tailscale VM"
	@echo ""
	@echo "Environment:"
	@echo "  make env                 Show current environment configuration"
	@echo "  make clean               Clean up .env file (backup first)"

.PHONY: bootstrap
bootstrap: ## Run bootstrap script (one-time setup)
	@echo -e "$(BLUE)Running bootstrap script...$(NC)"
	@chmod +x scripts/bootstrap.sh
	@./scripts/bootstrap.sh

.PHONY: build
build: ## Build the lab infrastructure baseline
	@echo -e "$(BLUE)Building lab infrastructure...$(NC)"
	@chmod +x scripts/build-lab.sh
	@./scripts/build-lab.sh

.PHONY: deploy-tailscale
deploy-tailscale: ## Deploy the Tailscale VM
	@echo -e "$(BLUE)Deploying Tailscale VM...$(NC)"
	@chmod +x tailscale-vm/create-tailscale-vm.sh
	@./tailscale-vm/create-tailscale-vm.sh

.PHONY: destroy-tailscale
destroy-tailscale: ## Destroy the Tailscale VM
	@echo -e "$(YELLOW)Destroying Tailscale VM...$(NC)"
	@chmod +x tailscale-vm/destroy-tailscale-vm.sh
	@./tailscale-vm/destroy-tailscale-vm.sh

.PHONY: validate
validate: ## Validate environment and prerequisites
	@echo -e "$(BLUE)Validating environment...$(NC)"
	@echo ""
	@echo "Checking prerequisites..."
	@which az > /dev/null 2>&1 && echo -e "  $(GREEN)✓$(NC) Azure CLI installed" || (echo -e "  $(RED)✗$(NC) Azure CLI not found" && exit 1)
	@which jq > /dev/null 2>&1 && echo -e "  $(GREEN)✓$(NC) jq installed" || echo -e "  $(YELLOW)⚠$(NC) jq not installed (optional)"
	@az account show > /dev/null 2>&1 && echo -e "  $(GREEN)✓$(NC) Azure CLI logged in" || (echo -e "  $(RED)✗$(NC) Not logged in to Azure" && exit 1)
	@echo ""
	@echo "Checking .env file..."
	@if [ -f .env ]; then echo -e "  $(GREEN)✓$(NC) .env file exists"; else echo -e "  $(YELLOW)⚠$(NC) .env file not found (run 'make bootstrap' first)"; fi
	@echo ""
	@echo -e "$(GREEN)Validation complete$(NC)"

.PHONY: env
env: ## Show current environment configuration
	@echo -e "$(BLUE)Environment Configuration$(NC)"
	@echo "-------------------------"
	@if [ -f .env ]; then \
		grep -v "AUTOMATION_CLIENT_SECRET\|TS_AUTHKEY\|TS_API_KEY" .env | sed 's/=.*$$/=********/'; \
		grep "AUTOMATION_CLIENT_SECRET\|TS_AUTHKEY\|TS_API_KEY" .env | sed 's/^/  /'; \
	else \
		echo "  .env file not found"; \
	fi

.PHONY: clean
clean: ## Clean up .env file (backup first)
	@echo -e "$(YELLOW)Backing up .env file...$(NC)"
	@if [ -f .env ]; then \
		cp .env .env.backup.$$(date +%Y%m%d%H%M%S); \
		rm .env; \
		echo -e "  $(GREEN)✓$(NC) .env backed up and removed"; \
	else \
		echo -e "  $(YELLOW)⚠$(NC) .env file not found"; \
	fi