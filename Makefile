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

LOCATION := centralus
RG_NETWORK := rg-lab-network
RG_MONITORING := rg-lab-monitoring
RG_SECURITY := rg-lab-security

# Pull ADMIN_EMAIL, ADMIN_OBJECT_ID, AUTOMATION_OBJECT_ID, HOME_IP from .env if present
-include .env
export

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
	@echo "  make build               Full baseline (all Bicep layers in order)"
	@echo "  make deploy-subscription Deploy bicep/subscription.bicep (RGs)"
	@echo "  make deploy-network      Deploy bicep/network.bicep (VNet + subnets)"
	@echo "  make deploy-monitoring   Deploy bicep/monitoring.bicep (action group)"
	@echo "  make deploy-policy       Deploy bicep/policy.bicep (defs + assignments)"
	@echo "  make deploy-security     Deploy bicep/security.bicep (KV + RBAC + ACL)"
	@echo "  make whatif-subscription Preview subscription.bicep changes"
	@echo "  make whatif-network      Preview network.bicep changes"
	@echo "  make whatif-monitoring   Preview monitoring.bicep changes"
	@echo "  make whatif-policy       Preview policy.bicep changes"
	@echo "  make whatif-security     Preview security.bicep changes"
	@echo "  make deploy-tailscale          Deploy the Tailscale subnet router VM"
	@echo "  make whatif-tailscale          Preview tailscale.bicep changes"
	@echo "  make destroy-tailscale         Destroy the Tailscale subnet router VM"
	@echo ""
	@echo "Environment:"
	@echo "  make env                 Show current environment configuration"
	@echo "  make clean               Clean up .env file (backup first)"

.PHONY: bootstrap
bootstrap: ## Run bootstrap script (one-time setup)
	@echo -e "$(BLUE)Running bootstrap script...$(NC)"
	@chmod +x scripts/bootstrap.sh
	@./scripts/bootstrap.sh

.PHONY: deploy-subscription
deploy-subscription: ## Deploy subscription-scope Bicep (resource groups)
	@echo -e "$(BLUE)Deploying bicep/subscription.bicep...$(NC)"
	@az deployment sub create \
		--location $(LOCATION) \
		--name subscription-baseline \
		--template-file bicep/subscription.bicep \
		--output none
	@echo -e "  $(GREEN)✓$(NC) subscription baseline deployed"

.PHONY: deploy-network
deploy-network: ## Deploy network Bicep (VNet + subnets)
	@echo -e "$(BLUE)Deploying bicep/network.bicep...$(NC)"
	@az deployment group create \
		--resource-group $(RG_NETWORK) \
		--name network-baseline \
		--template-file bicep/network.bicep \
		--output none
	@echo -e "  $(GREEN)✓$(NC) network baseline deployed"

.PHONY: whatif-subscription
whatif-subscription: ## Preview subscription.bicep changes
	@az deployment sub what-if \
		--location $(LOCATION) \
		--template-file bicep/subscription.bicep

.PHONY: whatif-network
whatif-network: ## Preview network.bicep changes
	@az deployment group what-if \
		--resource-group $(RG_NETWORK) \
		--template-file bicep/network.bicep

.PHONY: deploy-monitoring
deploy-monitoring: ## Deploy monitoring Bicep (action group)
	@echo -e "$(BLUE)Deploying bicep/monitoring.bicep...$(NC)"
	@if [ -z "$$ADMIN_EMAIL" ]; then echo -e "  $(RED)✗$(NC) ADMIN_EMAIL not set (run 'make bootstrap' or set in .env)" && exit 1; fi
	@az deployment group create \
		--resource-group $(RG_MONITORING) \
		--name monitoring-baseline \
		--template-file bicep/monitoring.bicep \
		--parameters adminEmail=$$ADMIN_EMAIL \
		--output none
	@echo -e "  $(GREEN)✓$(NC) monitoring baseline deployed"

.PHONY: whatif-monitoring
whatif-monitoring: ## Preview monitoring.bicep changes
	@if [ -z "$$ADMIN_EMAIL" ]; then echo -e "  $(RED)✗$(NC) ADMIN_EMAIL not set" && exit 1; fi
	@az deployment group what-if \
		--resource-group $(RG_MONITORING) \
		--template-file bicep/monitoring.bicep \
		--parameters adminEmail=$$ADMIN_EMAIL

.PHONY: deploy-policy
deploy-policy: ## Deploy policy Bicep (definitions + assignments)
	@echo -e "$(BLUE)Deploying bicep/policy.bicep...$(NC)"
	@az deployment sub create \
		--location $(LOCATION) \
		--name policy-baseline \
		--template-file bicep/policy.bicep \
		--output none
	@echo -e "  $(GREEN)✓$(NC) policy baseline deployed"

.PHONY: whatif-policy
whatif-policy: ## Preview policy.bicep changes
	@az deployment sub what-if \
		--location $(LOCATION) \
		--template-file bicep/policy.bicep

.PHONY: deploy-security
deploy-security: ## Deploy security Bicep (Key Vault + RBAC + network ACL)
	@echo -e "$(BLUE)Deploying bicep/security.bicep...$(NC)"
	@if [ -z "$$ADMIN_OBJECT_ID" ]; then echo -e "  $(RED)✗$(NC) ADMIN_OBJECT_ID not set (run 'make bootstrap' or set in .env)" && exit 1; fi
	@if [ -z "$$AUTOMATION_OBJECT_ID" ]; then echo -e "  $(RED)✗$(NC) AUTOMATION_OBJECT_ID not set" && exit 1; fi
	@HOME_IP=$${HOME_IP:-$$(curl -sf https://api.ipify.org)}; \
	if [ -z "$$HOME_IP" ]; then echo -e "  $(RED)✗$(NC) Could not detect public IP — set HOME_IP in .env" && exit 1; fi; \
	echo -e "  $(BLUE)▶$(NC) Home IP: $$HOME_IP"; \
	az deployment group create \
		--resource-group $(RG_SECURITY) \
		--name security-baseline \
		--template-file bicep/security.bicep \
		--parameters homeIp=$$HOME_IP adminObjectId=$$ADMIN_OBJECT_ID automationObjectId=$$AUTOMATION_OBJECT_ID \
		--output none
	@echo -e "  $(GREEN)✓$(NC) security baseline deployed"

.PHONY: whatif-security
whatif-security: ## Preview security.bicep changes
	@if [ -z "$$ADMIN_OBJECT_ID" ] || [ -z "$$AUTOMATION_OBJECT_ID" ]; then echo -e "  $(RED)✗$(NC) ADMIN_OBJECT_ID or AUTOMATION_OBJECT_ID not set" && exit 1; fi
	@HOME_IP=$${HOME_IP:-$$(curl -sf https://api.ipify.org)}; \
	az deployment group what-if \
		--resource-group $(RG_SECURITY) \
		--template-file bicep/security.bicep \
		--parameters homeIp=$$HOME_IP adminObjectId=$$ADMIN_OBJECT_ID automationObjectId=$$AUTOMATION_OBJECT_ID

.PHONY: build
build: deploy-subscription deploy-policy deploy-network deploy-monitoring deploy-security ## Full baseline (all Bicep layers)
	@echo -e "$(GREEN)✓$(NC) Lab baseline deployed"

.PHONY: deploy-tailscale
deploy-tailscale: ## Deploy the Tailscale subnet router VM (Bicep + tailnet route approval)
	@echo -e "$(BLUE)Deploying Tailscale subnet router VM...$(NC)"
	@chmod +x tailscale/create-tailscale.sh
	@./tailscale/create-tailscale.sh

.PHONY: whatif-tailscale
whatif-tailscale: ## Preview tailscale.bicep changes
	@if [ -z "$$ADMIN_SSH_PUBKEY" ]; then echo -e "  $(RED)✗$(NC) ADMIN_SSH_PUBKEY not set" && exit 1; fi
	@az deployment group what-if \
		--resource-group $(RG_NETWORK) \
		--template-file bicep/tailscale.bicep \
		--parameters adminSshPubkey="$$ADMIN_SSH_PUBKEY" tsAuthKey="dummy-for-whatif"

.PHONY: destroy-tailscale
destroy-tailscale: ## Destroy the Tailscale subnet router VM (and clean up tailnet device)
	@echo -e "$(YELLOW)Destroying Tailscale subnet router VM...$(NC)"
	@chmod +x tailscale/destroy-tailscale.sh
	@./tailscale/destroy-tailscale.sh

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