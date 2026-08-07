variable "subscription_id" {
  description = "Target Azure subscription id. No default - set this in terraform.tfvars."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = "Name prefix for every resource. Keep it short: APIM and storage names have tight length limits."
  type        = string
  default     = "dbx-pl"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,14}$", var.prefix))
    error_message = "prefix must be 3-14 chars, lowercase alphanumeric and hyphens only."
  }
}

variable "owner" {
  description = "Owner tag applied to every resource group. Many org policies require an owner tag."
  type        = string
  default     = "you@example.com"
}

variable "remove_after" {
  description = "RemoveAfter tag, YYYY-MM-DD. A cleanup date for the resource group; some org policies require it."
  type        = string
  default     = "2099-12-31"

  validation {
    condition     = can(formatdate("YYYY-MM-DD", "${var.remove_after}T00:00:00Z"))
    error_message = "remove_after must be a valid YYYY-MM-DD date."
  }
}

variable "apim_publisher_email" {
  description = "APIM publisher email (required by the service; receives APIM notifications)."
  type        = string
  default     = "you@example.com"
}

variable "apim_publisher_name" {
  description = "APIM publisher/organization name (required by the service; shown in the developer portal)."
  type        = string
  default     = "Example Org"
}

variable "apim_sku" {
  description = <<-EOT
    APIM SKU. VNet integration requires Developer or Premium (stv2).
    Developer_1 is ~$50/mo and NOT SLA-backed - fine for a test. Premium_1 is
    ~$2800/mo; only use it if you need production SLA and scale.
  EOT
  type        = string
  default     = "Developer_1"

  validation {
    condition     = can(regex("^(Developer|Premium)_[0-9]+$", var.apim_sku))
    error_message = "Internal VNet mode only supports Developer or Premium SKUs."
  }
}

variable "apim_virtual_network_type" {
  description = <<-EOT
    APIM VNet integration mode, which decides the direction of the test:

      "External" - the gateway gets a PUBLIC IP and <name>.azure-api.net resolves
        publicly, so an internet caller can reach it. This is the inbound test:
        internet -> APIM -> Function (private endpoint) -> FMAPI -> response.
        Requires apim_ingress_cidrs to be non-empty, or nothing can actually get
        in past the NSG.

      "Internal" - the gateway is a private VIP only, reachable from inside the
        VNet. This is the outbound/egress test: private Databricks -> APIM ->
        internet.
  EOT
  type        = string
  default     = "External"

  validation {
    condition     = contains(["External", "Internal"], var.apim_virtual_network_type)
    error_message = "apim_virtual_network_type must be \"External\" or \"Internal\"."
  }
}

variable "apim_ingress_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the PUBLIC APIM gateway on 443, set at deploy
    time (e.g. your caller's public IP as a /32). Only used when
    apim_virtual_network_type = "External".

    Validation rejects 0.0.0.0/0: exposing the gateway to the entire internet
    should be a deliberate choice, not an accident. Many org policies also strip
    internet-wide NSG rules automatically. Widen only if you know you need it.

    Empty = no public ingress rule is created. In External mode that means the
    gateway has a public IP but the NSG lets nobody in, so set this to test.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.apim_ingress_cidrs : !contains(["0.0.0.0/0", "0.0.0.0/32", "*", "internet", "any"], lower(c))
    ])
    error_message = "Refusing 0.0.0.0/0. Use a narrow CIDR, e.g. your public IP as a /32."
  }
}

variable "create_browser_auth_endpoint" {
  description = <<-EOT
    Create the browser_authentication private endpoint for SSO over Private Link.
    The limit is one per region per PRIVATE DNS ZONE, not per tenant - and this
    stack owns its own private DNS zone, so it does not collide with other
    browser-auth endpoints in the same region. Set false if you do not need SSO
    (API/CLI access over Private Link works without it) and want to skip the
    second workspace.
  EOT
  type        = bool
  default     = true
}

variable "create_jumpbox" {
  description = <<-EOT
    Create a jumpbox VM in snet-jumpbox. Required to reach anything in this
    stack: the workspace, Key Vault, and Function all have public access
    disabled, so seeding secrets, publishing Function code, and every
    verification step must run from inside the VNet.
    B1s is ~$7.59/mo vs Bastion Basic at ~$139/mo.
  EOT
  type        = bool
  default     = false
}

variable "jumpbox_vm_size" {
  description = "Jumpbox size. B1s (~$7.59/mo) is enough for CLI work; B1ls has too little RAM."
  type        = string
  default     = "Standard_B1s"
}

variable "jumpbox_admin_username" {
  description = "Jumpbox admin username."
  type        = string
  default     = "azureuser"
}

variable "jumpbox_ssh_public_key" {
  description = "SSH public key for the jumpbox, e.g. file(\"~/.ssh/id_ed25519.pub\"). Required when create_jumpbox is true."
  type        = string
  default     = ""

  validation {
    condition     = var.jumpbox_ssh_public_key == "" || can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) ", var.jumpbox_ssh_public_key))
    error_message = "jumpbox_ssh_public_key must be an OpenSSH public key (ssh-rsa, ssh-ed25519, or ecdsa-sha2-*)."
  }
}

variable "jumpbox_ssh_source_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to SSH to the jumpbox. Keep this narrow -
    ideally your current public IP as a /32. Empty means no SSH rule is created
    and the jumpbox is unreachable.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.jumpbox_ssh_source_cidrs : !contains(["0.0.0.0/0", "0.0.0.0/32", "*", "internet", "any"], lower(c))
    ])
    error_message = "Refusing internet-wide SSH. Use a narrow CIDR."
  }
}

variable "function_plan_sku" {
  description = <<-EOT
    App Service Plan SKU for the Function. EP1 (Elastic Premium, ~$150/mo) gives
    App Service networking semantics - instances take real subnet IPs and egress
    is predictable. Flex Consumption (FC1) is cheaper but has documented issues
    combining outbound VNet integration with an inbound private endpoint.
  EOT
  type        = string
  default     = "EP1"
}

variable "fmapi_endpoint_name" {
  description = <<-EOT
    Pay-per-token FMAPI serving endpoint the Function calls. eastus2 supports
    pay-per-token.

    Verified working on this stack: /serving-endpoints/<name>/invocations returns
    a normal chat completion over Private Link.

    ALWAYS confirm the name appears in YOUR workspace under Serving first. An
    endpoint can list as READY and still fail: databricks-claude-opus-5 did
    exactly that here, returning RESOURCE_DOES_NOT_EXIST on every invocation
    while system.ai reported 0 models. A fresh workspace has no serving
    endpoints at all until it is enabled for Foundation Model APIs.
  EOT
  type        = string
  default     = "databricks-claude-opus-4-7"
}

variable "databricks_sp_client_id" {
  description = <<-EOT
    Databricks service principal (application) ID used for OAuth M2M against
    FMAPI. Created in phase 2; leave empty until then. Not a secret.
  EOT
  type        = string
  default     = ""
}

variable "verbose_errors" {
  description = <<-EOT
    Relay upstream error detail to API callers - the APIM x-fmapi-error header
    and the Function's "detail" field.

    Genuinely useful while bringing the stack up, since a failure here is
    usually DNS or the private endpoint rather than the model. Leave false for
    anything client-facing: OAuth token-mint failures can name the service
    principal client id, and FMAPI errors can carry workspace identifiers.
  EOT
  type        = bool
  default     = false
}

variable "databricks_sp_secret_name" {
  description = "Key Vault secret name holding the SP's OAuth secret. Value is set out-of-band, never in Terraform."
  type        = string
  default     = "databricks-sp-oauth-secret"
}

variable "vnet_cidr" {
  description = "VNet address space."
  type        = string
  default     = "10.180.0.0/16"
}

variable "allowed_admin_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the APIM gateway. Keep this narrow; validation
    rejects 0.0.0.0/0. Empty list = no external ingress at all (VNet-internal only),
    which is the safest default for this test.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.allowed_admin_cidrs : !contains(["0.0.0.0/0", "0.0.0.0/32", "*", "internet", "any"], lower(c))
    ])
    error_message = "Refusing 0.0.0.0/0. Use a narrow CIDR."
  }
}
