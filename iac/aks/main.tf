terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "radius-e2e"
}

variable "github_repository" {
  description = "GitHub repository in 'owner/name' form, used for OIDC federation."
  type        = string
}

variable "node_count" {
  description = "Number of AKS worker nodes."
  type        = number
  default     = 1
}

variable "node_vm_size" {
  description = "AKS node VM size."
  type        = string
  default     = "Standard_B4ms"
}

data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-rg"
  location = var.location
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "${var.prefix}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.prefix

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_vm_size
  }

  identity {
    type = "SystemAssigned"
  }
}

# AAD application + service principal + federated credential for GHA OIDC.
# Lets the GitHub Actions workflow run `az login` with no client secret.

resource "azuread_application" "gha" {
  display_name = "${var.prefix}-gha"
}

resource "azuread_service_principal" "gha" {
  client_id = azuread_application.gha.client_id
}

resource "azuread_application_federated_identity_credential" "gha_main" {
  application_id = azuread_application.gha.id
  display_name   = "gha-main"
  description    = "GitHub Actions on main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repository}:ref:refs/heads/main"
}

# Allow workflow_dispatch from any branch by also federating a wildcard
# environment. (Azure federation doesn't support wildcard branches, so
# we use the environment subject claim.)
resource "azuread_application_federated_identity_credential" "gha_dispatch" {
  application_id = azuread_application.gha.id
  display_name   = "gha-dispatch"
  description    = "GitHub Actions workflow_dispatch"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repository}:environment:aks-e2e"
}

# Contributor on the resource group is enough to manage the AKS cluster
# (and create supporting resources during the workflow if needed).
resource "azurerm_role_assignment" "gha_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azuread_service_principal.gha.object_id
}

resource "azurerm_role_assignment" "gha_aks_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_service_principal.gha.object_id
}

output "AKS_RESOURCE_GROUP" {
  value = azurerm_resource_group.this.name
}

output "AKS_CLUSTER_NAME" {
  value = azurerm_kubernetes_cluster.this.name
}

output "AZURE_CLIENT_ID" {
  value = azuread_application.gha.client_id
}

output "AZURE_TENANT_ID" {
  value = data.azurerm_client_config.current.tenant_id
}

output "AZURE_SUBSCRIPTION_ID" {
  value = data.azurerm_subscription.current.subscription_id
}
