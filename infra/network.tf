resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Databricks host/container subnets. Both must be delegated to
# Microsoft.Databricks/workspaces and both must carry an NSG, or workspace
# creation fails.
# ---------------------------------------------------------------------------

resource "azurerm_subnet" "dbx_host" {
  name                 = "snet-dbx-host"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 1)] # 10.180.1.0/24

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

resource "azurerm_subnet" "dbx_container" {
  name                 = "snet-dbx-container"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 2)] # 10.180.2.0/24

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

# Private endpoints live here. Must NOT be delegated.
#
# private_endpoint_network_policies controls whether NSGs and UDRs are EVALUATED
# AT ALL for private endpoint NICs in this subnet. The previous value here was
# "Disabled", with a comment claiming that was required "so the PE NIC can be
# placed" - that was wrong. Placement does not need it, and Disabled has a nasty
# property: an NSG attached to this subnet is silently ignored, with no error
# and no diagnostic. A future engineer adding rules would believe they were
# enforced when nothing was.
#
# NetworkSecurityGroupEnabled makes the NSG below actually apply, which gives
# east-west segmentation in front of every private endpoint (workspace, Function,
# Key Vault, blob, file) instead of letting anything anywhere in the VNet reach
# all of them.
resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [cidrsubnet(var.vnet_cidr, 8, 3)] # 10.180.3.0/24
  private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
}

# APIM (stv2) requires a dedicated subnet, /27 minimum. Not delegated for
# Developer/Premium VNet injection.
resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 4)] # 10.180.4.0/24

  service_endpoints = [
    "Microsoft.Storage",
    "Microsoft.Sql",
    "Microsoft.KeyVault",
    "Microsoft.EventHub",
  ]
}

# Jumpbox subnet. Private Link means the workspace URL only resolves inside the
# VNet, so you need something in-VNet to test from.
resource "azurerm_subnet" "jumpbox" {
  name                 = "snet-jumpbox"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 5)] # 10.180.5.0/24
}

# ---------------------------------------------------------------------------
# NSGs
# ---------------------------------------------------------------------------

# Private endpoint subnet NSG.
#
# Without this, every private endpoint (workspace, Function, Key Vault, blob,
# file) is reachable from anywhere in the VNet. Credentials still apply - unkeyed
# calls return 401 - but there is no network-layer segmentation, so a single
# compromised workload can reach all five control planes.
#
# The rules below are an allowlist of the paths this architecture actually uses,
# established by testing the full chain end to end:
#
#   APIM     -> Function PE      APIM's backend URL is https://<fn>/api
#   Function -> workspace PE     OAuth token mint + FMAPI invocation
#   Function -> Key Vault PE     reads the SP secret via managed identity
#   Function -> blob/file PE     runtime content share
#   Databricks compute -> ws PE  secure cluster connectivity control path
#   Jumpbox  -> all              every verification step runs from here
#
# Deliberately NOT permitted: webauth compute subnets (browser SSO terminates at
# its own PE, it does not originate calls) and any inbound from outside the VNet.
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "${var.prefix}-pe-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# HTTPS from the subnets that have a real reason to talk to a private endpoint.
# One rule with a source list rather than several rules, so the intent stays
# readable in the portal's effective-rules view.
resource "azurerm_network_security_rule" "pe_in_https" {
  name                   = "Allow-HTTPS-From-Workload-Subnets"
  priority               = 100
  direction              = "Inbound"
  access                 = "Allow"
  protocol               = "Tcp"
  source_port_range      = "*"
  destination_port_range = "443"
  source_address_prefixes = [
    cidrsubnet(var.vnet_cidr, 8, 1), # snet-dbx-host
    cidrsubnet(var.vnet_cidr, 8, 2), # snet-dbx-container
    cidrsubnet(var.vnet_cidr, 8, 4), # snet-apim
    cidrsubnet(var.vnet_cidr, 8, 5), # snet-jumpbox
    cidrsubnet(var.vnet_cidr, 8, 8), # snet-function
  ]
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

# The storage file PE serves the Function's content share over SMB, not HTTPS.
# Restricted to snet-function: nothing else mounts it.
resource "azurerm_network_security_rule" "pe_in_smb" {
  name                        = "Allow-SMB-From-Function"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = cidrsubnet(var.vnet_cidr, 8, 8) # snet-function
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_range      = "445"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

# Explicit deny for everything else in the VNet, above the default
# AllowVnetInBound (65000). Without this the platform default would still permit
# any-to-any inside the VNet and the allowlist above would be decorative.
#
# Priority 4096 is the last usable slot, so any future allow rule can be added
# below it without having to renumber this one.
resource "azurerm_network_security_rule" "pe_in_deny_rest" {
  name                        = "Deny-All-Other-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "*"
  destination_port_range      = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_group" "dbx" {
  name                = "${var.prefix}-dbx-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# Databricks injects its own required rules into this NSG. Do not hand-add
# rules here unless you know why; the platform manages them.

resource "azurerm_subnet_network_security_group_association" "dbx_host" {
  subnet_id                 = azurerm_subnet.dbx_host.id
  network_security_group_id = azurerm_network_security_group.dbx.id
}

resource "azurerm_subnet_network_security_group_association" "dbx_container" {
  subnet_id                 = azurerm_subnet.dbx_container.id
  network_security_group_id = azurerm_network_security_group.dbx.id
}

resource "azurerm_network_security_group" "apim" {
  name                = "${var.prefix}-apim-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# --- APIM required inbound ---

# Control plane -> direct management endpoint. Without this the service goes
# unhealthy and the portal cannot manage it.
resource "azurerm_network_security_rule" "apim_in_management" {
  name                        = "Allow-ApiManagement-3443"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "ApiManagement"
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_range      = "3443"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

# Azure infrastructure load balancer health probes.
resource "azurerm_network_security_rule" "apim_in_lb" {
  name                        = "Allow-AzureLoadBalancer-6390"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "AzureLoadBalancer"
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_range      = "6390"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

# Gateway traffic from inside the VNet (this is how Databricks clusters reach APIM).
resource "azurerm_network_security_rule" "apim_in_gateway_vnet" {
  name                        = "Allow-VNet-Gateway-443"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_ranges     = ["80", "443"]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

# Optional narrow admin ingress. Guarded by a variable validation that rejects
# 0.0.0.0/0 - validation rejects internet-wide CIDRs.
resource "azurerm_network_security_rule" "apim_in_admin" {
  count = length(var.allowed_admin_cidrs) > 0 ? 1 : 0

  name                        = "Allow-Admin-CIDRs-443"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefixes     = var.allowed_admin_cidrs
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_range      = "443"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

# Public gateway ingress for the inbound test: internet caller -> APIM. Scoped to
# apim_ingress_cidrs, set at deploy time (your public IP as a /32). Its variable
# validation rejects 0.0.0.0/0, so this can never silently become internet-wide;
# widening it to the whole internet is a deliberate, self-owned decision.
#
# Only meaningful in External mode - in Internal mode there is no public gateway
# IP for this to apply to - but it is harmless if left in either way.
resource "azurerm_network_security_rule" "apim_in_public" {
  count = length(var.apim_ingress_cidrs) > 0 ? 1 : 0

  name                        = "Allow-Public-Ingress-443"
  priority                    = 125
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefixes     = var.apim_ingress_cidrs
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_range      = "443"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

# --- APIM required outbound dependencies ---

resource "azurerm_network_security_rule" "apim_out_storage" {
  name                        = "Allow-Out-Storage-443"
  priority                    = 200
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  destination_address_prefix  = "Storage"
  destination_port_range      = "443"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

resource "azurerm_network_security_rule" "apim_out_sql" {
  name                        = "Allow-Out-SQL-1433"
  priority                    = 210
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  destination_address_prefix  = "Sql"
  destination_port_range      = "1433"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

resource "azurerm_network_security_rule" "apim_out_keyvault" {
  name                        = "Allow-Out-KeyVault-443"
  priority                    = 220
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  destination_address_prefix  = "AzureKeyVault"
  destination_port_range      = "443"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

resource "azurerm_network_security_rule" "apim_out_monitor" {
  name                        = "Allow-Out-AzureMonitor"
  priority                    = 230
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  destination_address_prefix  = "AzureMonitor"
  destination_port_ranges     = ["443", "1886"]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

# This is the "APIM connects to the internet" hop - APIM egressing to your
# upstream backends via the NAT Gateway.
resource "azurerm_network_security_rule" "apim_out_internet" {
  name                        = "Allow-Out-Internet-443"
  priority                    = 240
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  destination_address_prefix  = "Internet"
  destination_port_ranges     = ["80", "443"]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.apim.name
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

# ---------------------------------------------------------------------------
# NAT Gateway - deterministic outbound egress for Databricks (SCC clusters have
# no public IP) and for APIM's upstream calls.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "nat" {
  name                = "${var.prefix}-nat-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "${var.prefix}-natgw"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "dbx_host" {
  subnet_id      = azurerm_subnet.dbx_host.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_subnet_nat_gateway_association" "dbx_container" {
  subnet_id      = azurerm_subnet.dbx_container.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_subnet_nat_gateway_association" "apim" {
  subnet_id      = azurerm_subnet.apim.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}
