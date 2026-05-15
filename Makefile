SHELL := /bin/bash

DEMO_DIR := demo
RTC_DIR := resource-types-contrib

# All resource type folders from the submodule (including containerImages)
RTC_TYPES := Compute/containerImages Compute/containers Compute/persistentVolumes Compute/routes Security/secrets

.PHONY: help build register-types register-recipes setup clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[34;1m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build Bicep extensions and place them in demo/
	@echo "==> Building Bicep extensions..."
	@for folder in $(RTC_TYPES); do \
		yaml=$$(find "$(RTC_DIR)/$$folder" -maxdepth 1 -name "*.yaml" | head -1); \
		name=$$(basename "$$yaml" .yaml); \
		echo "    $$name"; \
		rad bicep publish-extension -f "$$yaml" --target "$(DEMO_DIR)/$${name}-extension.tgz" --force 2>&1 | grep -v WARNING || true; \
	done
	@echo "✅ Extensions built in $(DEMO_DIR)/"
	@ls -1 $(DEMO_DIR)/*.tgz

register-types: ## Register all resource types with Radius
	@echo "==> Registering resource types..."
	@for folder in $(RTC_TYPES); do \
		yaml=$$(find "$(RTC_DIR)/$$folder" -maxdepth 1 -name "*.yaml" | head -1); \
		echo "    $$yaml"; \
		rad resource-type create -f "$$yaml" || \
			(echo "    Retrying after 5s..." && sleep 5 && rad resource-type create -f "$$yaml"); \
	done
	@echo "✅ Resource types registered"

register-recipes: ## Register Terraform recipes with the default environment
	@echo "==> Registering Terraform recipes..."
	rad recipe register default \
		--resource-type Radius.Compute/containerImages \
		--template-kind terraform \
		--template-path "git::https://github.com/YOUR_ORG/radius-containerimagetype-demo.git//resource-types-contrib/Compute/containerImages/recipes/kubernetes/terraform" \
		--parameters registry="ghcr.io/YOUR_ORG" \
		--parameters registrySecretName="ghcr-creds"
	rad recipe register default \
		--resource-type Radius.Compute/containers \
		--template-kind terraform \
		--template-path "git::https://github.com/radius-project/resource-types-contrib.git//Compute/containers/recipes/kubernetes/terraform"
	rad recipe register default \
		--resource-type Radius.Security/secrets \
		--template-kind terraform \
		--template-path "git::https://github.com/radius-project/resource-types-contrib.git//Security/secrets/recipes/kubernetes/terraform"
	@echo "✅ Recipes registered"

setup: register-types build register-recipes ## Run all setup steps (register types, build extensions, register recipes)
	@echo "✅ Setup complete. Run 'cd demo && rad deploy app.bicep' to deploy."

clean: ## Remove generated extension files
	@rm -f $(DEMO_DIR)/*.tgz
	@echo "✅ Cleaned generated files"
