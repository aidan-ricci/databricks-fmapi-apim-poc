output "resource_group_name" {
  description = "Resource group holding everything."
  value       = azurerm_resource_group.this.name
}

output "workspace_url" {
  description = "Workspace URL. Only resolves from inside the VNet (or via the jumpbox)."
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "workspace_private_endpoint_ip" {
  description = "Private IP the workspace hostname should resolve to."
  value       = azurerm_private_endpoint.dbx_ui_api.private_service_connection[0].private_ip_address
}

output "apim_gateway_url" {
  description = "APIM gateway URL. In External mode this resolves publicly; in Internal mode only inside the VNet."
  value       = "https://${azurerm_api_management.this.name}.azure-api.net"
}

output "apim_mode" {
  description = "APIM VNet integration mode (External = public gateway, Internal = private VIP)."
  value       = var.apim_virtual_network_type
}

output "apim_public_ips" {
  description = "APIM public gateway IP(s). Populated in External mode; empty in Internal mode."
  value       = azurerm_api_management.this.public_ip_addresses
}

output "apim_private_ips" {
  description = "APIM private VIP(s) inside the VNet."
  value       = azurerm_api_management.this.private_ip_addresses
}

output "nat_gateway_egress_ip" {
  description = "Public IP all Databricks and APIM egress leaves from. Use this for upstream allowlisting."
  value       = azurerm_public_ip.nat.ip_address
}

output "jumpbox_name" {
  description = "Jumpbox VM name. Private-only: no public IP, so reach it via Bastion."
  value       = var.create_jumpbox ? azurerm_linux_virtual_machine.jumpbox[0].name : null
}

output "jumpbox_private_ip" {
  description = "Jumpbox private IP inside snet-jumpbox."
  value       = var.create_jumpbox ? azurerm_network_interface.jumpbox[0].private_ip_address : null
}

output "jumpbox_connect" {
  description = <<-EOT
    How to reach the private-only jumpbox. It has no public IP by design; reach
    it via Bastion or the Azure VM agent.
  EOT
  value = var.create_jumpbox ? join("\n", [
    "# Option 1: Bastion Developer SKU (free, no AzureBastionSubnet needed):",
    "az network bastion ssh --name <bastion> --resource-group ${azurerm_resource_group.this.name} \\",
    "  --target-resource-id ${azurerm_linux_virtual_machine.jumpbox[0].id} \\",
    "  --auth-type ssh-key --username ${var.jumpbox_admin_username} --ssh-key ~/.ssh/${var.prefix}-jumpbox",
    "",
    "# Option 2: az ssh vm (needs the AAD login extension on the VM)",
    "",
    "# Create the free Bastion Developer host first:",
    "az network bastion create --name ${var.prefix}-bastion --resource-group ${azurerm_resource_group.this.name} \\",
    "  --vnet-name ${azurerm_virtual_network.this.name} --location ${var.location} --sku Developer",
  ]) : null
}

output "function_hostname" {
  description = "Function hostname. Resolves to a private IP inside the VNet only."
  value       = azurerm_linux_function_app.this.default_hostname
}

output "key_vault_name" {
  description = "Key Vault holding the Databricks SP OAuth secret. Seed it from inside the VNet."
  value       = azurerm_key_vault.this.name
}

output "apim_subscription_key" {
  description = "APIM subscription key for the FMAPI product."
  value       = azurerm_api_management_subscription.fmapi.primary_key
  sensitive   = true
}

output "fmapi_chat_url" {
  description = "Full-chain endpoint: APIM -> Function -> FMAPI."
  value       = "https://${azurerm_api_management.this.name}.azure-api.net/fmapi/chat"
}

output "verification_steps" {
  description = "How to confirm each hop actually works."
  value       = <<-EOT
    From a jumpbox VM inside ${azurerm_virtual_network.this.name}:

    1. Private Link resolves to a private IP (NOT a public one):
         nslookup ${azurerm_databricks_workspace.this.workspace_url}
         expected: ${azurerm_private_endpoint.dbx_ui_api.private_service_connection[0].private_ip_address}

    2. Workspace reachable privately, and public path is closed:
         curl -sSI https://${azurerm_databricks_workspace.this.workspace_url}/login.html
         Then try the same from your laptop - it MUST fail. That failure is the
         proof that public_network_access_enabled = false is in effect.

    3. APIM gateway resolves to its internal VIP:
         nslookup ${azurerm_api_management.this.name}.azure-api.net

    4. Databricks -> APIM -> internet, run from a notebook on a cluster in
       this workspace. Both APIs require a subscription key:
         %sh curl -sS -H 'Ocp-Apim-Subscription-Key: <key>' \
               https://${azurerm_api_management.this.name}.azure-api.net/egress/zen
       A GitHub zen string means the full chain works. Get the key with
       `terraform output -raw apim_subscription_key`.

    5. Confirm egress leaves via the NAT Gateway, from a notebook:
         %sh curl -sS https://api.ipify.org
         expected: ${azurerm_public_ip.nat.ip_address}
  EOT
}
