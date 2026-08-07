"""APIM -> Function -> Databricks FMAPI over Private Link.

Flow per request:
  1. read the Databricks SP OAuth secret from Key Vault (cached)
  2. mint an OAuth M2M token against the workspace token endpoint (cached)
  3. POST the chat payload to the FMAPI serving endpoint
  4. return the model response

Everything egresses through the VNet, so the workspace hostname resolves to the
private endpoint IP rather than a public address.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from typing import Any

import azure.functions as func
import httpx
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

DATABRICKS_HOST = (os.environ.get("DATABRICKS_HOST") or "").rstrip("/")
FMAPI_ENDPOINT_NAME = os.environ.get("FMAPI_ENDPOINT_NAME", "")
KEY_VAULT_URI = os.environ.get("KEY_VAULT_URI", "")
SP_CLIENT_ID = os.environ.get("DATABRICKS_SP_CLIENT_ID", "")
SP_SECRET_KV_NAME = os.environ.get("DATABRICKS_SP_SECRET_KV_NAME", "")

# Relay upstream error text to the caller. Off unless explicitly enabled: a
# token-mint failure body can name the SP client id, and FMAPI errors can carry
# workspace identifiers. The full detail is always written to the logs, so
# turning this off costs nothing diagnostically - it only changes what a client
# sees. Mirrors the verbose_errors Terraform variable.
VERBOSE_ERRORS = os.environ.get("VERBOSE_ERRORS", "").lower() in ("1", "true", "yes")

# Refresh a little before actual expiry so an in-flight request never races it.
_TOKEN_EXPIRY_SKEW_SECONDS = 300
_HTTP_TIMEOUT = httpx.Timeout(connect=10.0, read=120.0, write=30.0, pool=10.0)

# Reentrant: the token-mint path fetches the secret while already holding the
# lock, and a plain Lock would self-deadlock on the first request.
_lock = threading.RLock()
_cached_secret: str | None = None
_cached_token: str | None = None
_cached_token_expires_at: float = 0.0


class UpstreamError(RuntimeError):
    """Databricks returned something we cannot turn into a useful response."""

    def __init__(self, message: str, status_code: int = 502) -> None:
        super().__init__(message)
        self.status_code = status_code


def _get_sp_secret() -> str:
    """Fetch the SP OAuth secret from Key Vault via managed identity."""
    global _cached_secret

    if _cached_secret is not None:
        return _cached_secret

    with _lock:
        if _cached_secret is not None:
            return _cached_secret

        if not KEY_VAULT_URI or not SP_SECRET_KV_NAME:
            raise UpstreamError(
                "KEY_VAULT_URI and DATABRICKS_SP_SECRET_KV_NAME must be set", 500
            )

        client = SecretClient(
            vault_url=KEY_VAULT_URI, credential=DefaultAzureCredential()
        )
        _cached_secret = client.get_secret(SP_SECRET_KV_NAME).value
        logging.info("Loaded Databricks SP secret from Key Vault.")
        return _cached_secret


def _mint_oauth_token(client: httpx.Client) -> str:
    """Mint an OAuth M2M token against the workspace token endpoint.

    Route-optimized FMAPI endpoints reject PATs and cluster tokens outright, so
    OAuth is mandatory rather than a preference. scope must be all-apis; any
    downscoping happens through authorization_details, not scope.
    """
    global _cached_token, _cached_token_expires_at

    now = time.time()
    if _cached_token and now < _cached_token_expires_at:
        return _cached_token

    if not SP_CLIENT_ID:
        raise UpstreamError("DATABRICKS_SP_CLIENT_ID is not set", 500)

    # Fetch the secret before taking the lock: it does its own locking, and
    # holding ours across a network call would serialize every caller.
    secret = _get_sp_secret()

    with _lock:
        now = time.time()
        if _cached_token and now < _cached_token_expires_at:
            return _cached_token

        # Workspace-level token endpoint, NOT the account-level accounts.* URL.
        token_url = f"{DATABRICKS_HOST}/oidc/v1/token"

        response = client.post(
            token_url,
            auth=(SP_CLIENT_ID, secret),
            data={"grant_type": "client_credentials", "scope": "all-apis"},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )

        if response.status_code != 200:
            raise UpstreamError(
                f"token mint failed ({response.status_code}): {response.text[:400]}"
            )

        payload = response.json()
        token = payload.get("access_token")
        if not token:
            raise UpstreamError("token response contained no access_token")

        expires_in = int(payload.get("expires_in", 3600))
        _cached_token = token
        _cached_token_expires_at = (
            time.time() + max(expires_in - _TOKEN_EXPIRY_SKEW_SECONDS, 60)
        )
        logging.info("Minted Databricks OAuth token, expires_in=%ss.", expires_in)
        return token


def _invoke_fmapi(client: httpx.Client, token: str, payload: dict[str, Any]):
    url = f"{DATABRICKS_HOST}/serving-endpoints/{FMAPI_ENDPOINT_NAME}/invocations"

    response = client.post(
        url,
        json=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    return response


@app.route(route="chat", methods=["POST"])
def chat(req: func.HttpRequest) -> func.HttpResponse:
    """Proxy a chat completion request to the FMAPI endpoint."""
    if not DATABRICKS_HOST or not FMAPI_ENDPOINT_NAME:
        return func.HttpResponse(
            json.dumps({"error": "DATABRICKS_HOST and FMAPI_ENDPOINT_NAME must be set"}),
            status_code=500,
            mimetype="application/json",
        )

    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "request body must be valid JSON"}),
            status_code=400,
            mimetype="application/json",
        )

    if "messages" not in body:
        return func.HttpResponse(
            json.dumps({"error": "body must include a 'messages' array"}),
            status_code=400,
            mimetype="application/json",
        )

    try:
        with httpx.Client(timeout=_HTTP_TIMEOUT) as client:
            token = _mint_oauth_token(client)
            response = _invoke_fmapi(client, token, body)

            # A stale cached token reads as 401; retry once with a fresh one.
            if response.status_code == 401:
                global _cached_token, _cached_token_expires_at
                logging.warning("FMAPI returned 401, re-minting token and retrying.")
                with _lock:
                    _cached_token = None
                    _cached_token_expires_at = 0.0
                token = _mint_oauth_token(client)
                response = _invoke_fmapi(client, token, body)

            if response.status_code != 200:
                # Always logged in full; only echoed to the caller when asked.
                logging.error(
                    "FMAPI error %s: %s", response.status_code, response.text[:400]
                )
                body = {
                    "error": "FMAPI request failed",
                    "status": response.status_code,
                }
                if VERBOSE_ERRORS:
                    body["detail"] = response.text[:400]
                return func.HttpResponse(
                    json.dumps(body),
                    status_code=502,
                    mimetype="application/json",
                )

            return func.HttpResponse(
                response.text, status_code=200, mimetype="application/json"
            )

    except UpstreamError as exc:
        # str(exc) can embed the raw token-endpoint response, which names the SP
        # client id on an auth failure. Logged in full, generic to the caller.
        logging.exception("Upstream failure.")
        return func.HttpResponse(
            json.dumps(
                {"error": str(exc) if VERBOSE_ERRORS else "upstream request failed"}
            ),
            status_code=exc.status_code,
            mimetype="application/json",
        )
    except httpx.ConnectError as exc:
        # Almost always DNS or the private endpoint, not the model. The hint is
        # deliberately kept even when not verbose: it describes this stack's own
        # misconfiguration modes and leaks no identifiers.
        logging.exception("Could not connect to the workspace.")
        body = {
            "error": "could not reach the Databricks workspace",
            "hint": (
                "check that privatelink.azuredatabricks.net resolves to the "
                "private endpoint IP from inside the VNet, and that "
                "vnet_route_all_enabled is true on the Function"
            ),
        }
        if VERBOSE_ERRORS:
            body["detail"] = str(exc)[:200]
        return func.HttpResponse(
            json.dumps(body),
            status_code=502,
            mimetype="application/json",
        )


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    """Config check that makes no upstream call. Useful for APIM probes."""
    return func.HttpResponse(
        json.dumps(
            {
                "status": "ok",
                "databricks_host_set": bool(DATABRICKS_HOST),
                "fmapi_endpoint": FMAPI_ENDPOINT_NAME or None,
                "key_vault_configured": bool(KEY_VAULT_URI and SP_SECRET_KV_NAME),
                "sp_client_id_set": bool(SP_CLIENT_ID),
            }
        ),
        status_code=200,
        mimetype="application/json",
    )
