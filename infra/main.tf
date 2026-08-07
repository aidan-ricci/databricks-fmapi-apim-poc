locals {
  # Owner + RemoveAfter tags. Harmless everywhere, and required by some org
  # policies that delete untagged resource groups automatically.
  tags = {
    Owner       = var.owner
    RemoveAfter = var.remove_after
    Service     = "private-link-apim-test"
    Purpose     = "FE test: Databricks front-end Private Link -> APIM -> internet"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.tags
}
