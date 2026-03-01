terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~>1.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~>0.9"
    }
  }
}

provider "azurerm" {
  features {}
}

########################################
# Variables (required)
########################################
variable "workspace_name" {
  description = "Name of the Azure Databricks workspace"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group where the workspace will be created"
  type        = string
}

variable "location" {
  description = "Azure region for the workspace (e.g. Australia East)"
  type        = string
}

########################################
# Variables (optional)
########################################
variable "sku" {
  description = "Databricks workspace SKU (premium or trial)"
  type        = string
  default     = "premium"
}

# Declared to avoid errors if present in terraform.tfvars in this folder
variable "databricks_workspace_url" {
  description = "Unused here; declared to avoid undeclared variable errors"
  type        = string
  default     = null
}

variable "databricks_workspace_id" {
  description = "Unused here; declared to avoid undeclared variable errors"
  type        = string
  default     = null
}

variable "storage_account_name" {
  description = "Unused here; declared to avoid undeclared variable errors"
  type        = string
  default     = null
}

variable "catalog_name" {
  description = "Unused here; declared to avoid undeclared variable errors"
  type        = string
  default     = null
}

variable "container_name" {
  description = "Unused here; declared to avoid undeclared variable errors"
  type        = string
  default     = null
}

########################################
# Metastore + storage variables
########################################
variable "databricks_account_id" {
  description = "Databricks Account ID (required to manage Unity Catalog metastore)"
  type        = string
}

variable "azure_tenant_id" {
  description = "Azure Tenant ID (required to manage Unity Catalog metastore)"
  type        = string
}

variable "metastore_name" {
  description = "Name of the Unity Catalog metastore to create"
  type        = string
  default     = "metastore-australia-east"
}

variable "metastore_storage_account_name" {
  description = "Optional name for storage account backing the metastore (must be globally unique). If null, a name is generated."
  type        = string
  default     = null
}

variable "metastore_container_name" {
  description = "Container name for the metastore's default storage"
  type        = string
  default     = "metastore"
}

########################################
# Locals
########################################
locals {
  # Databricks expects region slugs like 'australiaeast'
  databricks_region = replace(lower(var.location), " ", "")
}

########################################
# Resources
########################################
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_databricks_workspace" "this" {
  name                = var.workspace_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.sku
}

########################################
# Storage for Unity Catalog Metastore
########################################
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  metastore_sa_name = var.metastore_storage_account_name != null ? var.metastore_storage_account_name : "dbmeta${random_string.suffix.result}"
}

resource "azurerm_storage_account" "metastore" {
  name                     = local.metastore_sa_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true
}

resource "azurerm_storage_container" "metastore" {
  name                  = var.metastore_container_name
  storage_account_name  = azurerm_storage_account.metastore.name
  container_access_type = "private"
}

########################################
# Access Connector for Unity Catalog
########################################
resource "azurerm_databricks_access_connector" "this" {
  name                = "adb-access-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "connector_storage_blob_data_contributor" {
  scope                = azurerm_storage_account.metastore.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
}
resource "azurerm_role_assignment" "connector_storage_eventgrid_event_subscription_contributor" {
  scope                = azurerm_storage_account.metastore.id
  role_definition_name = "EventGrid EventSubscription Contributor"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
}
resource "azurerm_role_assignment" "connector_storage_account_contributor" {
  scope                = azurerm_storage_account.metastore.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
}
resource "azurerm_role_assignment" "connector_storage_queue_data_contributor" {
  scope                = azurerm_storage_account.metastore.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
}

# Allow some time for role assignment propagation
resource "time_sleep" "wait_for_rbac" {
  depends_on      = [azurerm_role_assignment.connector_storage_blob_data_contributor]
  create_duration = "60s"
}

########################################
# Databricks account-level provider (for metastore)
########################################
provider "databricks" {
  alias      = "mws"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type           = "azure-cli"
  azure_tenant_id     = var.azure_tenant_id
}

# Databricks workspace-level provider (for storage credential/external location/namespace)
provider "databricks" {
  alias     = "ws"
  host      = var.databricks_workspace_url
  auth_type           = "azure-cli"
  azure_tenant_id     = var.azure_tenant_id
}

# Look up the workspace to get its Databricks workspace_id for assignment
data "azurerm_databricks_workspace" "this" {
  name                = azurerm_databricks_workspace.this.name
  resource_group_name = azurerm_resource_group.this.name
}

########################################
# Unity Catalog Metastore and assignment
########################################
resource "databricks_storage_credential" "metastore_uc" {
  provider = databricks.ws
  name     = "uc-metastore-cred-${random_string.suffix.result}"

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.this.id
  }

  depends_on = [
    time_sleep.wait_for_rbac,
    databricks_metastore_assignment.this
  ]
}

// Removed external location for container root to avoid overlap with
// auto-created 'metastore_root_location' (created during metastore setup).


resource "databricks_metastore_data_access" "default" {
  provider    = databricks.mws
  metastore_id = databricks_metastore.this.id
  name         = "default"
  is_default   = true

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.this.id
  }

  depends_on = [time_sleep.wait_for_rbac]
}

resource "databricks_metastore" "this" {
  provider     = databricks.mws
  name         = var.metastore_name
  region       = local.databricks_region
  force_destroy = true
  storage_root = "abfss://${azurerm_storage_container.metastore.name}@${azurerm_storage_account.metastore.name}.dfs.core.windows.net/metastore/"
}

resource "databricks_default_namespace_setting" "this" {
  provider = databricks.ws
  namespace {
    value = "main"
  }
}

resource "databricks_metastore_assignment" "this" {
  provider     = databricks.mws
  metastore_id = databricks_metastore.this.id
  workspace_id = data.azurerm_databricks_workspace.this.workspace_id
}

########################################
# Outputs
########################################
output "databricks_workspace_resource_id" {
  description = "Azure resource ID of the Databricks workspace"
  value       = azurerm_databricks_workspace.this.id
}

output "databricks_workspace_url" {
  description = "Workspace URL (login host)"
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "metastore_id" {
  description = "ID of the created Unity Catalog metastore"
  value       = databricks_metastore.this.id
}

output "metastore_storage_root" {
  description = "ABFSS URL used as storage root for the metastore"
  value       = databricks_metastore.this.storage_root
}


