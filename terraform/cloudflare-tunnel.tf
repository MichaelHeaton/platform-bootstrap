# Cloudflare Tunnel substrate for kb-mcp off-LAN (#1135 / homelab-infra).
#
# Ownership (HomeLab 2.0): public Tunnel DNS + SM token wiring live HERE.
# Homelab GitOps owns the cloudflared connector (gitops/platform/cloudflared).
# Do not put private LAN IPs in Cloudflare DNS.
#
# Prereq before setting kb_mcp_tunnel_id: seed SM
# platform-bootstrap/cloudflare-api-token (DNS Edit + Zone Read) — runbook 08.
#
# After Zero Trust tunnel create, set TF_VAR_kb_mcp_tunnel_id=<uuid> (Actions
# var). Empty UUID skips the CNAME and does not read SM (safe default).

data "aws_secretsmanager_secret_version" "cloudflare_api_token" {
  count = var.kb_mcp_tunnel_id != "" ? 1 : 0

  secret_id = var.cloudflare_api_token_secret_name
}

provider "cloudflare" {
  # Dummy token when no tunnel DNS is managed — provider unused until UUID is set.
  api_token = (
    var.kb_mcp_tunnel_id != ""
    ? trimspace(data.aws_secretsmanager_secret_version.cloudflare_api_token[0].secret_string)
    : "not-used-until-kb_mcp_tunnel_id-is-set"
  )
}

data "cloudflare_zone" "specterrealm" {
  count = var.kb_mcp_tunnel_id != "" ? 1 : 0

  filter = {
    name = "specterrealm.com"
  }
}

# Public path for Knowledge Base MCP. LAN stays UniFi CNAME → Traefik (homelab-infra).
resource "cloudflare_dns_record" "specterrealm_com_kb_mcp" {
  count = var.kb_mcp_tunnel_id != "" ? 1 : 0

  zone_id = data.cloudflare_zone.specterrealm[0].zone_id
  name    = "kb-mcp.specterrealm.com"
  type    = "CNAME"
  content = "${var.kb_mcp_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

output "kb_mcp_tunnel_cname" {
  description = "Public kb-mcp CNAME target when kb_mcp_tunnel_id is set; empty otherwise."
  value = (
    var.kb_mcp_tunnel_id != ""
    ? "${var.kb_mcp_tunnel_id}.cfargotunnel.com"
    : ""
  )
}
