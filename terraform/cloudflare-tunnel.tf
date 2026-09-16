# Cloudflare Tunnel substrate for kb-mcp off-LAN (#1135 / homelab-infra).
#
# Ownership (HomeLab 2.0): public Tunnel DNS + remote tunnel ingress live HERE.
# Homelab GitOps owns the cloudflared connector (gitops/platform/cloudflared).
# Do not put private LAN IPs in Cloudflare DNS.
#
# Token path (sibling runner): Vault AppRole →
#   homelab/cloudflare/tunnel-substrate-api (api_token) →
#   scripts/ci-cloudflare-tunnel-token-prereq.sh → TF_VAR_cloudflare_api_token.
# SM platform-bootstrap/cloudflare-api-token is optional fallback only.
# Token needs Zone DNS Edit + Zone Read on specterrealm.com AND Account →
# Cloudflare Tunnel → Edit — runbook 08.
#
# After Zero Trust tunnel create, set TF_VAR_kb_mcp_tunnel_id=<uuid> (Actions
# var) or kb_mcp.auto.tfvars. Empty UUID skips CNAME + ingress (safe default).
#
# DNS and tunnel config are independent: this root owns the proxied CNAME and
# the remote ingress rules. Do not let the Zero Trust "Published application"
# UI create a second DNS record for kb-mcp.

locals {
  cloudflare_tunnel_manage = var.kb_mcp_tunnel_id != ""
  # Prefer Vault-injected TF_VAR (CI); SM only when var empty (laptop/break-glass).
  cloudflare_api_token_from_sm = (
    local.cloudflare_tunnel_manage && var.cloudflare_api_token == ""
  )
}

data "aws_secretsmanager_secret_version" "cloudflare_api_token" {
  count = local.cloudflare_api_token_from_sm ? 1 : 0

  secret_id = var.cloudflare_api_token_secret_name
}

provider "cloudflare" {
  api_token = (
    !local.cloudflare_tunnel_manage
    ? "not-used-until-kb_mcp_tunnel_id-is-set"
    : (
      var.cloudflare_api_token != ""
      ? var.cloudflare_api_token
      : trimspace(data.aws_secretsmanager_secret_version.cloudflare_api_token[0].secret_string)
    )
  )
}

data "cloudflare_zone" "specterrealm" {
  count = local.cloudflare_tunnel_manage ? 1 : 0

  filter = {
    name = "specterrealm.com"
  }
}

# Public path for Knowledge Base MCP. LAN stays UniFi CNAME → Traefik (homelab-infra).
resource "cloudflare_dns_record" "specterrealm_com_kb_mcp" {
  count = local.cloudflare_tunnel_manage ? 1 : 0

  zone_id = data.cloudflare_zone.specterrealm[0].zone_id
  name    = "kb-mcp.specterrealm.com"
  type    = "CNAME"
  content = "${var.kb_mcp_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Remote tunnel ingress only — does not create DNS. Hostname allowlist is kb-mcp;
# catch-all 404 is required by Cloudflare.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "kb_mcp" {
  count = local.cloudflare_tunnel_manage ? 1 : 0

  account_id = data.cloudflare_zone.specterrealm[0].account.id
  tunnel_id  = var.kb_mcp_tunnel_id
  source     = "cloudflare"

  config = {
    ingress = [
      {
        hostname = "kb-mcp.specterrealm.com"
        service  = "http://kb-mcp.knowledge-base.svc:8000"
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

output "kb_mcp_tunnel_cname" {
  description = "Public kb-mcp CNAME target when kb_mcp_tunnel_id is set; empty otherwise."
  value = (
    local.cloudflare_tunnel_manage
    ? "${var.kb_mcp_tunnel_id}.cfargotunnel.com"
    : ""
  )
}

output "kb_mcp_tunnel_ingress_hostname" {
  description = "Public hostname managed in tunnel remote config when kb_mcp_tunnel_id is set."
  value = (
    local.cloudflare_tunnel_manage
    ? "kb-mcp.specterrealm.com"
    : ""
  )
}
