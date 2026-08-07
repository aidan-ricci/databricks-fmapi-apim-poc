# ---------------------------------------------------------------------------
# Optional jumpbox.
#
# Needed because the workspace, Key Vault, and Function all have public access
# disabled - their hostnames only resolve inside this VNet. Without in-VNet
# access you cannot seed the SP secret, publish the Function code, or run any
# verification step.
#
# B1s at ~$7.59/mo (eastus2 retail) rather than Bastion Basic at ~$139/mo.
# Bastion Developer is free but allows one session at a time with no file
# transfer, which makes publishing code painful.
#
# Disabled by default: set create_jumpbox = true when you are ready to deploy.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "jumpbox" {
  count = var.create_jumpbox ? 1 : 0

  name                = "${var.prefix}-jumpbox-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# SSH inbound from within the VNet (jumpbox-to-jumpbox, and any VNet-injected
# service that needs it).
resource "azurerm_network_security_rule" "jumpbox_ssh" {
  count = var.create_jumpbox ? 1 : 0

  name                        = "Allow-SSH-From-VNet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_range      = "22"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.jumpbox[0].name
}

# NOTE on Bastion Developer SKU and NSGs:
#
# Developer SKU is a SHARED Microsoft-hosted service with no IP configuration in
# your VNet (`ipConfigurations: 0`), so there is no AzureBastionSubnet CIDR to
# allow. There is also NO Bastion service tag - `az network list-service-tags`
# returns none matching "Bastion", and inventing one (e.g.
# AzureBastionInboundRule) fails with SecurityRuleInvalidAddressPrefix.
#
# Microsoft's guidance for Developer SKU is to allow TCP 22 from the
# VirtualNetwork tag, which the rule above already does. If the portal still
# reports "Port 22 is not accessible from source IP(s)", the remaining options
# are to upgrade to Basic/Standard (which deploys into an AzureBastionSubnet you
# can scope to) or to skip SSH entirely.
#
# Skipping SSH is what this project does: `az vm run-command invoke` reaches the
# VM through the Azure VM agent, needs no inbound port at all, and is how
# prove-it.sh runs every in-VNet verification.

resource "azurerm_subnet_network_security_group_association" "jumpbox" {
  count = var.create_jumpbox ? 1 : 0

  subnet_id                 = azurerm_subnet.jumpbox.id
  network_security_group_id = azurerm_network_security_group.jumpbox[0].id
}

# Without this the jumpbox egresses via Azure's default SNAT, not the NAT
# Gateway - so `curl api.ipify.org` from the VM reports an unrelated IP and
# looks like the NAT Gateway is broken when it is not. The subnets that matter
# for the test (apim, dbx_host, dbx_container, function) were always attached.
resource "azurerm_subnet_nat_gateway_association" "jumpbox" {
  count = var.create_jumpbox ? 1 : 0

  subnet_id      = azurerm_subnet.jumpbox.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# Lets `az keyvault secret set` run on the jumpbox via `az login --identity`,
# which is how the SP OAuth secret gets seeded into the private vault.
resource "azurerm_role_assignment" "jumpbox_kv" {
  count = var.create_jumpbox ? 1 : 0

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_virtual_machine.jumpbox[0].identity[0].principal_id
}

# `func azure functionapp publish` must read the site and fetch publishing
# credentials, so the jumpbox MI needs rights on the Function App itself.
# Without this it fails with a misleading `Can't find app with name "..."` -
# which is an authorization failure, not a missing resource.
#
# Scoped to the single Function App rather than the resource group or
# subscription, so the jumpbox cannot touch anything else.
resource "azurerm_role_assignment" "jumpbox_function_contributor" {
  count = var.create_jumpbox ? 1 : 0

  scope                = azurerm_linux_function_app.this.id
  role_definition_name = "Website Contributor"
  principal_id         = azurerm_linux_virtual_machine.jumpbox[0].identity[0].principal_id
}

resource "azurerm_network_interface" "jumpbox" {
  count = var.create_jumpbox ? 1 : 0

  name                = "${var.prefix}-jumpbox-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  # No public IP by design: no public IP means no internet-facing SSH surface at
  # all. Reach the jumpbox via `az network bastion ssh` (Bastion Developer SKU is
  # free) or `az ssh vm`.
  #
  # This is also the only option under some org policies. Azure Policies that deny
  # "NICs with public IPs that lack an attached NSG" evaluate the NIC at creation,
  # and the azurerm provider has no inline NSG argument for a NIC - a separate
  # association resource is applied too late - so a NIC-with-public-IP is denied on
  # the first API call. Private-only sidesteps that entirely.
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jumpbox.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  count = var.create_jumpbox ? 1 : 0

  name                = "${var.prefix}-jumpbox"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.jumpbox_vm_size
  admin_username      = var.jumpbox_admin_username

  network_interface_ids = [azurerm_network_interface.jumpbox[0].id]

  # Managed identity so `az` works on the VM without an interactive login. Needed
  # because Key Vault is private: seeding the SP secret has to happen from inside
  # the VNet, and Bastion Developer SKU has no file transfer to carry credentials.
  identity {
    type = "SystemAssigned"
  }

  # Fail at plan time rather than deploying a VM nobody can log into.
  lifecycle {
    precondition {
      condition     = var.jumpbox_ssh_public_key != ""
      error_message = "create_jumpbox = true requires jumpbox_ssh_public_key, e.g. file(\"~/.ssh/id_ed25519.pub\")."
    }

  }

  # Key-based auth only; password auth stays off.
  admin_ssh_key {
    username   = var.jumpbox_admin_username
    public_key = var.jumpbox_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Installs the tooling needed for phase 2: az CLI, databricks CLI, func tools.
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - curl
      - jq
      - dnsutils
      - unzip
    runcmd:
      - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
      - curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
      - curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      - apt-get install -y nodejs
      - npm install -g azure-functions-core-tools@4
    CLOUDINIT
  )

  tags = local.tags
}
