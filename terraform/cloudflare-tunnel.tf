# Cloudflare Tunnel substrate for the homelab MCPs off-LAN (#1135 / HLB-397).
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
# DNS and tunnel config are independent: this root owns the proxied CNAMEs and
# the remote ingress rules. Do not let the Zero Trust "Published application"
# UI create a second DNS record for kb-mcp or obs-mcp.
#
# Ingress must match homelab-infra gitops/platform/cloudflared/allowlist.yaml
# (CI-enforced Host list there). Every MCP Host sits behind a Cloudflare Access
# app owned by homelab-infra terraform/cloudflare — apply that root first.
# iris + auth (browser Hosts) have no Access app; homelab-infra's identity root
# (iris-web group binding) must be applied first instead.

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

# Public path for Observability MCP (HLB-397). LAN stays UniFi → Traefik.
# HLB-856 gate: Access app "obs-mcp" with per-agent service tokens
# (homelab-infra terraform/cloudflare/mcp_agents_access.tf) must exist first.
resource "cloudflare_dns_record" "specterrealm_com_obs_mcp" {
  count = local.cloudflare_tunnel_manage ? 1 : 0

  zone_id = data.cloudflare_zone.specterrealm[0].zone_id
  name    = "obs-mcp.specterrealm.com"
  type    = "CNAME"
  content = "${var.kb_mcp_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Public path for the Iris web UI (2026-10-14). LAN stays UniFi → Traefik.
# Same hostname on and off LAN, so Iris's OIDC redirect URI is unchanged.
resource "cloudflare_dns_record" "specterrealm_com_iris" {
  count = local.cloudflare_tunnel_manage ? 1 : 0

  zone_id = data.cloudflare_zone.specterrealm[0].zone_id
  name    = "iris.specterrealm.com"
  type    = "CNAME"
  content = "${var.kb_mcp_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Authentik login, public only because Iris sign-in redirects browsers here.
# No Cloudflare Access (Michael, 2026-10-14); the admin UI is 404'd in ingress.
resource "cloudflare_dns_record" "specterrealm_com_auth" {
  count = local.cloudflare_tunnel_manage ? 1 : 0

  zone_id = data.cloudflare_zone.specterrealm[0].zone_id
  name    = "auth.specterrealm.com"
  type    = "CNAME"
  content = "${var.kb_mcp_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Remote tunnel ingress only — does not create DNS. Hostnames are a subset of the
# homelab-infra cloudflared allowlist; catch-all 404 is required by Cloudflare.
# tickets.specterrealm.com is on that allowlist but not live here (2026-10-13
# plan): adding it would publish Plane, which is a separate decision.
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
        hostname = "obs-mcp.specterrealm.com"
        service  = "http://obs-mcp.observability-mcp.svc:8000"
      },
      # Iris + Authentik go to Traefik websecure, not the pods: Traefik holds the
      # certs and routes by Host, and HTTPS makes Authentik build https:// URLs.
      # origin_server_name sets SNI (and cert check) to the public Host.
      {
        hostname = "iris.specterrealm.com"
        service  = "https://traefik.traefik.svc.cluster.local:443"
        origin_request = {
          origin_server_name = "iris.specterrealm.com"
          http_host_header   = "iris.specterrealm.com"
        }
      },
      # Authentik admin UI stays LAN/VPN; must sit above the catch-all auth rule.
      {
        hostname = "auth.specterrealm.com"
        path     = "^/if/admin"
        service  = "http_status:404"
      },
      {
        hostname = "auth.specterrealm.com"
        service  = "https://traefik.traefik.svc.cluster.local:443"
        origin_request = {
          origin_server_name = "auth.specterrealm.com"
          http_host_header   = "auth.specterrealm.com"
        }
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

output "tunnel_ingress_hostnames" {
  description = "All public hostnames in the tunnel remote config (empty when kb_mcp_tunnel_id is unset)."
  value = (
    local.cloudflare_tunnel_manage
    ? ["kb-mcp.specterrealm.com", "obs-mcp.specterrealm.com", "iris.specterrealm.com", "auth.specterrealm.com"]
    : []
  )
}
