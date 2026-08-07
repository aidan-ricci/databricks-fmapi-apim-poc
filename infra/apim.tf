# ---------------------------------------------------------------------------
# APIM VNet integration. Mode is set by apim_virtual_network_type:
#
#   External (default) - public gateway IP; internet callers reach APIM, which
#     forwards to the Function over its private endpoint. This is the inbound
#     test: internet -> APIM -> FMAPI -> response.
#
#   Internal - private VIP only; used for the outbound/egress variant.
#
# Either way the gateway lives in snet-apim and forwards to backends over the
# VNet. Provisioning takes 30-45 min for Developer SKU; destroy is similar.
# ---------------------------------------------------------------------------

resource "azurerm_api_management" "this" {
  name                = "${var.prefix}-apim"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku

  virtual_network_type = var.apim_virtual_network_type

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags

  # NSG rules must exist before APIM deploys into the subnet, or the deployment
  # fails or lands unhealthy. The public-ingress rule is count-gated, so depend
  # on the whole resource rather than [0] to stay valid when it is absent.
  depends_on = [
    azurerm_subnet_network_security_group_association.apim,
    azurerm_network_security_rule.apim_in_management,
    azurerm_network_security_rule.apim_in_lb,
    azurerm_network_security_rule.apim_in_public,
    azurerm_network_security_rule.apim_out_storage,
    azurerm_network_security_rule.apim_out_sql,
    azurerm_network_security_rule.apim_out_keyvault,
    azurerm_network_security_rule.apim_out_monitor,
    azurerm_subnet_nat_gateway_association.apim,
  ]
}

# ---------------------------------------------------------------------------
# Private DNS for the gateway hostname - ONLY in Internal mode.
#
# In Internal mode APIM does not create this for you, and its absence is the most
# common reason "APIM is up but nothing can call it". In External mode the
# opposite is true: <name>.azure-api.net resolves publicly through Azure, and a
# private zone of the same name would shadow that resolution inside the VNet and
# break it. So this whole block is gated on Internal mode.
# ---------------------------------------------------------------------------

locals {
  apim_internal = var.apim_virtual_network_type == "Internal"
}

resource "azurerm_private_dns_zone" "apim" {
  count               = local.apim_internal ? 1 : 0
  name                = "azure-api.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  count                 = local.apim_internal ? 1 : 0
  name                  = "${var.prefix}-apim-dns-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.apim[0].name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_a_record" "apim_gateway" {
  count               = local.apim_internal ? 1 : 0
  name                = azurerm_api_management.this.name
  zone_name           = azurerm_private_dns_zone.apim[0].name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = azurerm_api_management.this.private_ip_addresses
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "apim_management" {
  count               = local.apim_internal ? 1 : 0
  name                = "${azurerm_api_management.this.name}.management"
  zone_name           = azurerm_private_dns_zone.apim[0].name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = azurerm_api_management.this.private_ip_addresses
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "apim_portal" {
  count               = local.apim_internal ? 1 : 0
  name                = "${azurerm_api_management.this.name}.portal"
  zone_name           = azurerm_private_dns_zone.apim[0].name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = azurerm_api_management.this.private_ip_addresses
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# A sample API proving the egress path: Databricks -> APIM -> internet.
# Swap the backend for whatever you actually want to front.
# ---------------------------------------------------------------------------

resource "azurerm_api_management_api" "egress_test" {
  name                = "egress-test"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  revision            = "1"
  display_name        = "Egress Test"
  path                = "egress"
  protocols           = ["https"]

  service_url = "https://api.github.com"

  # Require a key like the FMAPI product does. This was previously false, which
  # left an unauthenticated internet-egress path through the gateway: any
  # workload in the VNet could call out through APIM with no credential.
  #
  # Exposure was bounded - only the declared GET /zen operation resolves, so it
  # could not be used as a general api.github.com proxy - but "bounded" is not a
  # reason to ship an open endpoint to a client. Testing it now just means
  # passing the same Ocp-Apim-Subscription-Key used everywhere else.
  subscription_required = true
}

resource "azurerm_api_management_api_operation" "egress_get" {
  operation_id        = "get-zen"
  api_name            = azurerm_api_management_api.egress_test.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "GET /zen"
  method              = "GET"
  url_template        = "/zen"
  description         = "Cheap upstream call that confirms APIM reached the internet."
}
