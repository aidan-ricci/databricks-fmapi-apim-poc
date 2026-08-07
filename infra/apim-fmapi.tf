# ---------------------------------------------------------------------------
# Phase 5: APIM -> Function API surface.
#
# APIM stays a thin gateway. All Databricks auth lives in the Function, because
# the OAuth token mint needs a form-encoded call plus JSON handling that is
# painful and error-prone to express in APIM policy XML.
# ---------------------------------------------------------------------------

# Function host key, so APIM can call a function-auth-level endpoint.
data "azurerm_function_app_host_keys" "this" {
  name                = azurerm_linux_function_app.this.name
  resource_group_name = azurerm_resource_group.this.name

  depends_on = [azurerm_linux_function_app.this]
}

# Stored as a secret named value rather than inline in policy, so it does not
# appear in plain text in the APIM policy document.
resource "azurerm_api_management_named_value" "function_key" {
  name                = "fmapi-function-key"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  display_name        = "fmapi-function-key"
  value               = data.azurerm_function_app_host_keys.this.default_function_key
  secret              = true
}

# Backend targets the Function's ORIGINAL hostname, not the private IP: TLS/SNI
# and certificate validation both depend on the real hostname. Private DNS
# resolves it to the private endpoint from inside the VNet.
resource "azurerm_api_management_backend" "function" {
  name                = "fmapi-function"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = "https://${azurerm_linux_function_app.this.default_hostname}/api"
  description         = "FMAPI proxy Function, reached over its private endpoint."

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

resource "azurerm_api_management_api" "fmapi" {
  name                = "fmapi"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  revision            = "1"
  display_name        = "Databricks FMAPI"
  description         = "Chat completions via a Databricks pay-per-token FMAPI endpoint over Private Link."
  path                = "fmapi"
  protocols           = ["https"]

  subscription_required = true
}

resource "azurerm_api_management_api_operation" "fmapi_chat" {
  operation_id        = "chat"
  api_name            = azurerm_api_management_api.fmapi.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Chat completion"
  method              = "POST"
  url_template        = "/chat"
  description         = "Forwards an OpenAI-shaped chat payload to the FMAPI endpoint."

  response {
    status_code = 200
    description = "Model response."
  }

  response {
    status_code = 502
    description = "Upstream Databricks or connectivity failure."
  }
}

resource "azurerm_api_management_api_operation" "fmapi_health" {
  operation_id        = "health"
  api_name            = azurerm_api_management_api.fmapi.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Health"
  method              = "GET"
  url_template        = "/health"
  description         = "Function config check. Makes no upstream call."

  response {
    status_code = 200
    description = "Config summary."
  }
}

# API-level policy: route to the Function backend, inject the host key, and apply
# the abuse controls below.
#
# The size cap and rate limit are not decoration. This API fronts a
# pay-per-token FMAPI endpoint, so an oversized `messages` array or a tight loop
# turns directly into spend, and the Function forwards bodies to Databricks
# without inspecting their length.
resource "azurerm_api_management_api_policy" "fmapi" {
  api_name            = azurerm_api_management_api.fmapi.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <!--
          Reject oversized bodies before they reach the Function or Databricks.
          128 KB is generous for a chat payload while ruling out the pathological
          case. Applies to requests with no Content-Length too.
        -->
        <check-header name="Content-Length" failed-check-httpcode="411" failed-check-error-message="Content-Length required." ignore-case="true" />
        <choose>
          <when condition="@(context.Request.Headers.GetValueOrDefault(&quot;Content-Length&quot;,&quot;0&quot;).AsInt(0) > 131072)">
            <return-response>
              <set-status code="413" reason="Payload Too Large" />
              <set-header name="Content-Type" exists-action="override">
                <value>application/json</value>
              </set-header>
              <set-body>{"error":"request body exceeds the 128 KB limit"}</set-body>
            </return-response>
          </when>
        </choose>
        <!--
          Per-subscription rate limit. Sized for interactive testing, not load
          testing: raise it deliberately if you need throughput, rather than
          discovering the ceiling during a demo.
        -->
        <rate-limit-by-key calls="30" renewal-period="60"
          counter-key="@(context.Subscription?.Id ?? context.Request.IpAddress)"
          remaining-calls-header-name="x-ratelimit-remaining"
          retry-after-header-name="retry-after" />
        <set-backend-service backend-id="${azurerm_api_management_backend.function.name}" />
        <set-header name="x-functions-key" exists-action="override">
          <value>{{${azurerm_api_management_named_value.function_key.name}}}</value>
        </set-header>
        <!-- Strip any client-supplied auth: the Function owns Databricks auth. -->
        <set-header name="Authorization" exists-action="delete" />
      </inbound>
      <backend>
        <!-- FMAPI calls can be slow; allow one retry on 5xx only. -->
        <retry condition="@(context.Response.StatusCode >= 500)" count="1" interval="2" first-fast-retry="false">
          <forward-request buffer-request-body="true" timeout="180" />
        </retry>
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
        <!--
          The upstream error message is useful when debugging this stack and
          inappropriate to hand to an API consumer: token-mint failures can name
          the SP client id, and FMAPI errors can carry workspace identifiers.
          Gated on verbose_errors, which defaults to false.
        -->
        %{if var.verbose_errors}
        <set-header name="x-fmapi-error" exists-action="override">
          <value>@(context.LastError?.Message ?? "unknown")</value>
        </set-header>
        %{endif}
      </on-error>
    </policies>
  XML

  depends_on = [
    azurerm_api_management_api_operation.fmapi_chat,
    azurerm_api_management_api_operation.fmapi_health,
  ]
}

resource "azurerm_api_management_product" "fmapi" {
  product_id            = "fmapi-test"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  display_name          = "FMAPI Test"
  description           = "FE test product for the Databricks FMAPI proxy."
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "fmapi" {
  api_name            = azurerm_api_management_api.fmapi.name
  product_id          = azurerm_api_management_product.fmapi.product_id
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_api_management_subscription" "fmapi" {
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  product_id          = azurerm_api_management_product.fmapi.id
  display_name        = "FMAPI test subscription"
  state               = "active"
}
