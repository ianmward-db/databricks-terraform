# Azure Databricks Catalog with ADLS Storage - Terraform Configuration

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~>2.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~>1.0"
    }
  }
}

# Configure the Azure Provider
provider "azurerm" {
  features {}
}

# Configure the Azure AD Provider
provider "azuread" {}

# Configure the Databricks Provider
provider "databricks" {
  host = var.databricks_workspace_url
}

# Variables
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-databricks-unity-catalog"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "East US"
}

variable "storage_account_name" {
  description = "Name of the storage account (must be globally unique)"
  type        = string
  # Generate a unique name if not provided
  default = null
}

variable "container_name" {
  description = "Name of the ADLS container"
  type        = string
  default     = "unity-catalog-data"
}

variable "catalog_name" {
  description = "Name of the Databricks catalog"
  type        = string
  default     = "my_catalog"
}

variable "databricks_workspace_url" {
  description = "URL of the Databricks workspace"
  type        = string
}

variable "databricks_workspace_id" {
  description = "Resource ID of the Databricks workspace"
  type        = string
}

# Generate random suffix for unique naming
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Local values
locals {
  storage_account_name = var.storage_account_name != null ? var.storage_account_name : "adls${random_string.suffix.result}"
  tags = {
    Environment = "unity-catalog"
    Purpose     = "databricks-storage"
    ManagedBy   = "terraform"
  }
}

# Data source for current client configuration
data "azurerm_client_config" "current" {}

# Data source for Databricks workspace
data "azurerm_databricks_workspace" "this" {
  name                = split("/", var.databricks_workspace_id)[8]
  resource_group_name = split("/", var.databricks_workspace_id)[4]
}

# Resource Group (if it doesn't exist)
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# Storage Account with ADLS Gen2
resource "azurerm_storage_account" "adls" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled          = true  # Enable hierarchical namespace for ADLS Gen2

  tags = local.tags
}

# Storage Container
resource "azurerm_storage_container" "unity_catalog" {
  name                  = var.container_name
  storage_account_name  = azurerm_storage_account.adls.name
  container_access_type = "private"
}

# Azure AD Application for Service Principal
resource "azuread_application" "databricks_sp" {
  display_name = "databricks-unity-catalog-${random_string.suffix.result}"
  owners       = [data.azurerm_client_config.current.object_id]
}

# Service Principal
resource "azuread_service_principal" "databricks_sp" {
  client_id                    = azuread_application.databricks_sp.client_id
  app_role_assignment_required = false
  owners                       = [data.azurerm_client_config.current.object_id]
}

# Service Principal Password
resource "azuread_service_principal_password" "databricks_sp" {
  service_principal_id = azuread_service_principal.databricks_sp.object_id
  display_name         = "databricks-unity-catalog-secret"
}

# Role Assignment: Storage Blob Data Contributor
resource "azurerm_role_assignment" "storage_blob_data_contributor" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.databricks_sp.object_id
}

# Wait for role assignment to propagate
resource "time_sleep" "wait_for_permissions" {
  depends_on      = [azurerm_role_assignment.storage_blob_data_contributor]
  create_duration = "60s"
}

# Databricks Storage Credential
resource "databricks_storage_credential" "unity_catalog" {
  depends_on = [time_sleep.wait_for_permissions]
  
  name = "unity-catalog-credential-${random_string.suffix.result}"
  
  azure_service_principal {
    directory_id   = data.azurerm_client_config.current.tenant_id
    application_id = azuread_application.databricks_sp.client_id
    client_secret  = azuread_service_principal_password.databricks_sp.value
  }
  
  comment = "Storage credential for Unity Catalog"
}

# Databricks External Location
resource "databricks_external_location" "unity_catalog" {
  depends_on = [databricks_storage_credential.unity_catalog]
  
  name = "unity-catalog-location-${random_string.suffix.result}"
  url  = "abfss://${azurerm_storage_container.unity_catalog.name}@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  
  credential_name = databricks_storage_credential.unity_catalog.id
  comment         = "External location for Unity Catalog"
}

# Databricks Catalog
resource "databricks_catalog" "unity_catalog" {
  depends_on = [databricks_external_location.unity_catalog]
  
  name           = var.catalog_name
  comment        = "Unity Catalog created via Terraform"
  storage_root   = databricks_external_location.unity_catalog.url
  
  properties = {
    purpose = "unity-catalog-demo"
  }
}

# Grant permissions on the catalog (optional - adjust as needed)
resource "databricks_grants" "catalog_grants" {
  catalog = databricks_catalog.unity_catalog.name
  
  grant {
    principal  = "account users"  # Adjust this based on your needs
    privileges = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA"]
  }
}

# Create a test schema in the catalog
resource "databricks_schema" "test_schema" {
  depends_on   = [databricks_catalog.unity_catalog]
  catalog_name = databricks_catalog.unity_catalog.name
  name         = "test_schema"
  comment      = "Test schema created via Terraform"
  
  properties = {
    kind = "various"
  }
}

# Outputs
output "storage_account_name" {
  description = "Name of the created storage account"
  value       = azurerm_storage_account.adls.name
}

output "storage_account_primary_dfs_endpoint" {
  description = "Primary DFS endpoint of the storage account"
  value       = azurerm_storage_account.adls.primary_dfs_endpoint
}

output "container_name" {
  description = "Name of the storage container"
  value       = azurerm_storage_container.unity_catalog.name
}

output "service_principal_application_id" {
  description = "Application ID of the service principal"
  value       = azuread_application.databricks_sp.client_id
}

output "databricks_catalog_name" {
  description = "Name of the created Databricks catalog"
  value       = databricks_catalog.unity_catalog.name
}

output "databricks_external_location_url" {
  description = "URL of the external location"
  value       = databricks_external_location.unity_catalog.url
}

output "databricks_storage_credential_name" {
  description = "Name of the storage credential"
  value       = databricks_storage_credential.unity_catalog.name
}

output "starter_warehouse_id" {
  description = "ID of the existing Starter Warehouse"
  value       = data.databricks_sql_warehouse.starter_warehouse.id
}

# Compute policy to ensure Unity Catalog compatibility
resource "databricks_cluster_policy" "unity_catalog_policy" {
  name = "Unity Catalog Serverless Compatible Policy"
  
  definition = jsonencode({
    "spark_version": {
      "type": "regex",
      "pattern": "^(1[4-9]\\.[0-9]+\\.x-scala2\\.12|[2-9][0-9]\\.[0-9]+\\.x-scala2\\.12)$",
      "defaultValue": "auto:latest-lts"
    },
    "data_security_mode": {
      "type": "fixed",
      "value": "SINGLE_USER"
    },
    "runtime_engine": {
      "type": "fixed", 
      "value": "PHOTON"
    }
  })
}

# Optional: Create sample table for testing
resource "databricks_sql_table" "sample_table" {
  depends_on   = [databricks_schema.test_schema]
  catalog_name = databricks_catalog.unity_catalog.name
  schema_name  = databricks_schema.test_schema.name
  name         = "sample_table"
  table_type   = "MANAGED"
  
  column {
    name     = "id"
    type     = "bigint"
    nullable = false
    comment  = "Unique identifier"
  }
  
  column {
    name     = "name"
    type     = "string"
    nullable = true
    comment  = "Name field"
  }
  
  column {
    name     = "created_at"
    type     = "timestamp"
    nullable = true
    comment  = "Creation timestamp"
  }
  
  comment = "Sample table created via Terraform"
}

# Data source to reference existing SQL warehouse
data "databricks_sql_warehouse" "starter_warehouse" {
  name = "Starter Warehouse"
}

# Test serverless compatibility with a simple SQL query
resource "databricks_query" "test_query" {
  depends_on = [databricks_sql_table.sample_table]
  
  warehouse_id = data.databricks_sql_warehouse.starter_warehouse.id
  display_name = "Test Unity Catalog Access"
  query_text = "SELECT 'Unity Catalog is accessible from serverless compute!' as status, current_timestamp() as test_time"
  
  tags = ["unity-catalog", "serverless-test"]
}
