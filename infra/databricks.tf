# ---------------------------------------------------------------------------
# VNet-injected classic workspace with secure cluster connectivity.
#
# Premium SKU is required for Private Link. Serverless Azure workspaces cannot
# do VNet injection or Private Link at all, which is why this is classic.
# ---------------------------------------------------------------------------

resource "azurerm_databricks_workspace" "this" {
  name                = "${var.prefix}-ws"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "premium"

  managed_resource_group_name = "${var.prefix}-ws-managed-rg"

  # Front-end Private Link: workspace reachable only through the private endpoint.
  public_network_access_enabled         = false
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    virtual_network_id                                   = azurerm_virtual_network.this.id
    public_subnet_name                                   = azurerm_subnet.dbx_host.name
    private_subnet_name                                  = azurerm_subnet.dbx_container.name
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.dbx_host.id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.dbx_container.id

    # Secure cluster connectivity - no public IPs on cluster VMs. Egress goes
    # out via the NAT Gateway.
    no_public_ip = true
  }

  tags = local.tags

  depends_on = [
    azurerm_subnet_network_security_group_association.dbx_host,
    azurerm_subnet_network_security_group_association.dbx_container,
  ]
}

# ---------------------------------------------------------------------------
# Private DNS for the front-end. Without this the workspace hostname still
# resolves to a public IP and Private Link appears to "not work".
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "databricks" {
  name                = "privatelink.azuredatabricks.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "databricks" {
  name                  = "${var.prefix}-dbx-dns-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.databricks.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

# ---------------------------------------------------------------------------
# Private endpoints
# ---------------------------------------------------------------------------

# Front-end UI/API. This is the one that makes the workspace reachable privately.
resource "azurerm_private_endpoint" "dbx_ui_api" {
  name                = "${var.prefix}-pe-ui-api"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-psc-ui-api"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dbx-ui-api"
    private_dns_zone_ids = [azurerm_private_dns_zone.databricks.id]
  }
}

# ---------------------------------------------------------------------------
# Browser authentication (SSO redirect over Private Link).
#
# Microsoft's documented pattern requires a DEDICATED "web auth" workspace for
# this - the browser_authentication endpoint must NOT share a workspace with a
# databricks_ui_api endpoint. The web-auth workspace runs no workloads; it
# exists only to host this endpoint.
#
# The limit is one per region per PRIVATE DNS ZONE, not per tenant or per
# subscription. Because this stack creates its own
# privatelink.azuredatabricks.net zone linked only to its own VNet, it does not
# collide with other engineers' endpoints. Verified: this subscription already
# has 7 browser_authentication endpoints, including 3 in westeurope and one in
# eastus2 (rg-cbtsthub), each in its own VNet and zone.
#
# The failure mode to avoid is two of these sharing ONE zone: the pl-auth
# A record would conflict and SSO would break for both.
#
# Without this endpoint, Private Link still works for API/CLI/PAT access; only
# browser SSO login to the private workspace URL breaks.
# ---------------------------------------------------------------------------

resource "azurerm_subnet" "webauth_host" {
  count = var.create_browser_auth_endpoint ? 1 : 0

  name                 = "snet-webauth-host"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 6)] # 10.180.6.0/24

  delegation {
    name = "databricks-host"

    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet" "webauth_container" {
  count = var.create_browser_auth_endpoint ? 1 : 0

  name                 = "snet-webauth-container"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 7)] # 10.180.7.0/24

  delegation {
    name = "databricks-container"

    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_network_security_group" "webauth" {
  count = var.create_browser_auth_endpoint ? 1 : 0

  name                = "${var.prefix}-webauth-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "webauth_host" {
  count = var.create_browser_auth_endpoint ? 1 : 0

  subnet_id                 = azurerm_subnet.webauth_host[0].id
  network_security_group_id = azurerm_network_security_group.webauth[0].id
}

resource "azurerm_subnet_network_security_group_association" "webauth_container" {
  count = var.create_browser_auth_endpoint ? 1 : 0

  subnet_id                 = azurerm_subnet.webauth_container[0].id
  network_security_group_id = azurerm_network_security_group.webauth[0].id
}

# Follows Microsoft's DO-NOT-DELETE convention so nobody in the shared sandbox
# removes it, but prefixed: an unprefixed WEB-AUTH-DO-NOT-DELETE-eastus2 would
# collide with another engineer doing the same thing (rg-cbtsthub already has
# WEBAUTH_DO_NOT_DELETE_EASTUS2).
resource "azurerm_databricks_workspace" "webauth" {
  count = var.create_browser_auth_endpoint ? 1 : 0

  name                = "${var.prefix}-WEBAUTH-DO-NOT-DELETE-${var.location}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "premium"

  managed_resource_group_name = "${var.prefix}-webauth-managed-rg"

  public_network_access_enabled         = false
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    virtual_network_id                                   = azurerm_virtual_network.this.id
    public_subnet_name                                   = azurerm_subnet.webauth_host[0].name
    private_subnet_name                                  = azurerm_subnet.webauth_container[0].name
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.webauth_host[0].id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.webauth_container[0].id
    no_public_ip                                         = true
  }

  tags = merge(local.tags, {
    Purpose = "Web auth workspace for browser_authentication PE. Runs no workloads. Do not delete."
  })

  depends_on = [
    azurerm_subnet_network_security_group_association.webauth_host,
    azurerm_subnet_network_security_group_association.webauth_container,
  ]
}

resource "azurerm_private_endpoint" "dbx_browser_auth" {
  count = var.create_browser_auth_endpoint ? 1 : 0

  name                = "${var.prefix}-pe-browser-auth"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-psc-browser-auth"
    private_connection_resource_id = azurerm_databricks_workspace.webauth[0].id
    subresource_names              = ["browser_authentication"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dbx-browser-auth"
    private_dns_zone_ids = [azurerm_private_dns_zone.databricks.id]
  }
}
