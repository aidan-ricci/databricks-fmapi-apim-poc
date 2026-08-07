# ---------------------------------------------------------------------------
# Phase 3: supporting infra for the FMAPI-calling Function.
#
# Premium (Elastic) plan, not Flex Consumption: Flex has documented platform
# issues combining outbound VNet integration with an inbound private endpoint
# (deploy timeouts, intermittent DNS failures) and routes egress through shared
# gateways. This test exists to prove a private path, so predictability wins.
# Plain Consumption (Y1) cannot do private endpoints at all.
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

# Outbound VNet integration requires a delegated subnet.
resource "azurerm_subnet" "function" {
  name                 = "snet-function"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 8)] # 10.180.8.0/24

  service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]

  delegation {
    name = "webapp"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Function egress leaves via the same NAT Gateway, so upstream allowlisting sees
# one predictable IP.
resource "azurerm_subnet_nat_gateway_association" "function" {
  subnet_id      = azurerm_subnet.function.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---------------------------------------------------------------------------
# Key Vault - holds the Databricks SP OAuth secret.
#
# RBAC authorization rather than access policies: access policies are legacy and
# awkward to express for managed identities.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  name                = "${var.prefix}-kv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true

  # No public access; reachable only through the private endpoint. The
  # "allow Azure services" bypass is intentionally not used.
  public_network_access_enabled = false

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
  }

  purge_protection_enabled   = false # sandbox: allow clean teardown
  soft_delete_retention_days = 7

  tags = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "${var.prefix}-pe-kv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-psc-kv"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}

resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "${var.prefix}-kv-dns-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

# The identity running Terraform needs write access to seed the secret. Without
# this, the SP-secret write below fails with a 403 under RBAC.
resource "azurerm_role_assignment" "tf_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Storage for the Function runtime. Private, no public access.
# ---------------------------------------------------------------------------

resource "random_string" "storage_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_storage_account" "function" {
  name                = substr("${replace(var.prefix, "-", "")}fn${random_string.storage_suffix.result}", 0, 24)
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # Public access stays enabled at the account level ONLY so Terraform can reach
  # the data plane to create the content file share below - with it disabled the
  # share creation fails with AuthorizationFailure from outside the VNet, which
  # is a chicken-and-egg bootstrap problem.
  #
  # network_rules below still denies everything by default: only the operator's
  # own IP and the VNet subnets are permitted, so this is not open to the
  # internet. Verify with checklist item C3-equivalent from an unlisted network.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true # Functions runtime still needs this

  network_rules {
    default_action = "Deny"

    # Operator IP, needed for the share bootstrap. Narrow by construction:
    # reuses the same validated CIDR list as the jumpbox SSH rule.
    ip_rules = [for c in var.jumpbox_ssh_source_cidrs : split("/", c)[0]]

    # Only snet-function: a storage ACL can reference a subnet only if that
    # subnet has the Microsoft.Storage service endpoint. snet-private-endpoints
    # deliberately has none (private endpoints do not need them), and listing it
    # here fails with SubnetsHaveNoServiceEndpointsConfigured.
    virtual_network_subnet_ids = [
      azurerm_subnet.function.id,
    ]

    bypass = ["AzureServices"]
  }

  tags = local.tags
}

# Content share for the Functions runtime. Required by WEBSITE_CONTENTSHARE
# whenever WEBSITE_CONTENTOVERVNET is set.
resource "azurerm_storage_share" "function_content" {
  name               = "${var.prefix}-fn-content"
  storage_account_id = azurerm_storage_account.function.id
  quota              = 5

  # The account's network_rules must permit this caller before the data plane
  # accepts the create.
  depends_on = [azurerm_storage_account.function]
}

resource "azurerm_private_dns_zone" "storage_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_blob" {
  name                  = "${var.prefix}-blob-dns-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_blob.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone" "storage_file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_file" {
  name                  = "${var.prefix}-file-dns-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_file.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

# Both blob and file endpoints are needed - the Functions runtime mounts content
# over the file share.
resource "azurerm_private_endpoint" "storage_blob" {
  name                = "${var.prefix}-pe-blob"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-psc-blob"
    private_connection_resource_id = azurerm_storage_account.function.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_blob.id]
  }
}

resource "azurerm_private_endpoint" "storage_file" {
  name                = "${var.prefix}-pe-file"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-psc-file"
    private_connection_resource_id = azurerm_storage_account.function.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "file"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_file.id]
  }
}

# ---------------------------------------------------------------------------
# Function App (Elastic Premium EP1)
# ---------------------------------------------------------------------------

resource "azurerm_service_plan" "function" {
  name                = "${var.prefix}-asp"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  sku_name            = var.function_plan_sku
  tags                = local.tags
}

resource "azurerm_application_insights" "function" {
  name                = "${var.prefix}-appi"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  application_type    = "web"
  tags                = local.tags
}

resource "azurerm_linux_function_app" "this" {
  name                = "${var.prefix}-fn"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.function.id

  storage_account_name       = azurerm_storage_account.function.name
  storage_account_access_key = azurerm_storage_account.function.primary_access_key

  # Only APIM should reach this, over the private endpoint.
  public_network_access_enabled = false

  # Reject plaintext HTTP. This defaults to FALSE, which is easy to miss: the
  # Function then answers on port 80 as well as 443, and because the function
  # key travels as a `?code=` query parameter, an in-VNet observer picks up a
  # credential that grants full access to /api/chat. Verified on the previous
  # deployment - `curl http://<fn>.azurewebsites.net/api/health?code=<key>`
  # returned 200 over cleartext via the private endpoint.
  #
  # Nothing legitimate needs :80 here. APIM's backend URL is already https://.
  https_only = true

  virtual_network_subnet_id = azurerm_subnet.function.id

  # Client certificates enabled because some org policies deny Function apps
  # created with clientCertEnabled = false.
  #
  # "Optional" satisfies such a policy (the flag is true) while still accepting
  # requests that present no client cert - APIM does not send one, so "Required"
  # would break the whole chain with a TLS handshake failure. The exclusion path
  # additionally exempts /api/* so the mTLS negotiation never applies to the
  # actual function routes.
  client_certificate_enabled         = true
  client_certificate_mode            = "Optional"
  client_certificate_exclusion_paths = "/api"

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.function.connection_string
    application_insights_key               = azurerm_application_insights.function.instrumentation_key

    # Route ALL outbound through the VNet, not just RFC1918. Without this the
    # workspace hostname resolves publicly and Private Link is bypassed.
    vnet_route_all_enabled = true

    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    # Databricks workspace host - resolves privately inside the VNet.
    DATABRICKS_HOST = "https://${azurerm_databricks_workspace.this.workspace_url}"

    # Pay-per-token FMAPI endpoint. eastus2 supports pay-per-token.
    FMAPI_ENDPOINT_NAME = var.fmapi_endpoint_name

    # Secrets stay in Key Vault; the Function resolves them via its managed
    # identity at runtime. Never the literal value here.
    KEY_VAULT_URI                = azurerm_key_vault.this.vault_uri
    DATABRICKS_SP_CLIENT_ID      = var.databricks_sp_client_id
    DATABRICKS_SP_SECRET_KV_NAME = var.databricks_sp_secret_name

    FUNCTIONS_WORKER_RUNTIME = "python"

    # Whether upstream error detail reaches the caller. Full detail always goes
    # to the logs regardless; see the verbose_errors variable.
    VERBOSE_ERRORS = tostring(var.verbose_errors)

    # WEBSITE_CONTENTOVERVNET routes the content share over the VNet (required
    # when storage has no public access). Azure rejects it unless
    # WEBSITE_CONTENTSHARE names an existing file share, so both are set
    # together along with the explicit connection string.
    WEBSITE_CONTENTOVERVNET                  = "1"
    WEBSITE_CONTENTSHARE                     = azurerm_storage_share.function_content.name
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING = azurerm_storage_account.function.primary_connection_string

    SCM_DO_BUILD_DURING_DEPLOYMENT = "1"
  }

  tags = local.tags

  depends_on = [
    azurerm_private_endpoint.storage_blob,
    azurerm_private_endpoint.storage_file,
    azurerm_subnet_nat_gateway_association.function,
  ]

  lifecycle {
    # `func azure functionapp publish --build remote` injects its own build
    # settings (ENABLE_ORYX_BUILD, BUILD_FLAGS, XDG_CACHE_HOME). Terraform does
    # not know about them and would strip them on the next apply, breaking the
    # deployed app. Ignoring the whole map is deliberate: after a publish, app
    # settings are jointly owned by Terraform and the Functions tooling.
    #
    # Consequence: changing DATABRICKS_HOST, FMAPI_ENDPOINT_NAME, or
    # DATABRICKS_SP_CLIENT_ID in tfvars will NO LONGER take effect via apply.
    # Set those with `az functionapp config appsettings set` instead, or
    # temporarily comment this out, apply, then republish.
    ignore_changes = [app_settings]
  }
}

resource "azurerm_private_dns_zone" "function" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "function" {
  name                  = "${var.prefix}-fn-dns-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.function.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

# Inbound PE so APIM can reach the Function privately. Group id is "sites".
resource "azurerm_private_endpoint" "function" {
  name                = "${var.prefix}-pe-fn"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-psc-fn"
    private_connection_resource_id = azurerm_linux_function_app.this.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "fn"
    private_dns_zone_ids = [azurerm_private_dns_zone.function.id]
  }
}

# ---------------------------------------------------------------------------
# RBAC: both managed identities read the SP secret from Key Vault.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "function_kv" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "apim_kv" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

# Function reads its own runtime storage via MI where possible.
resource "azurerm_role_assignment" "function_storage" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_function_app.this.identity[0].principal_id
}
