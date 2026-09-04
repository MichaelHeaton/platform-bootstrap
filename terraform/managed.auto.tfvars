# Infrastructure managed by this platform.
# Add new repos, pipelines, and service accounts here — Terraform picks this file up automatically.

pipelines = [
  {
    # Consolidated into homelab-infra/terraform/cloudflare (#102 Wave D). Workspace name must stay
    # "cloudflare" (not homelab-infra). Remote execution retired — state is PostgreSQL (#259).
    # HCP workspace deleted under homelab-infra #214.
    repo_name                   = "homelab-infra"
    environment                 = "shared"
    cloud                       = "cloudflare"
    function                    = "dns"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/cloudflare-api-token"]
    tfe_workspace_name          = "cloudflare"
    tfe_workspace_enabled       = false
    tfe_execution_mode          = "local" # Cloudflare API is public; pg state backend is VLAN 1 only (#259)
    terraform_working_directory = "terraform/cloudflare"
  },
  {
    repo_name                   = "minecraft-modpack-cp-verdant"
    environment                 = "personal"
    cloud                       = "aws"
    function                    = "curseforge-verdant"
    allowed_refs                = ["refs/heads/main", "refs/tags/v*"]
    secretsmanager_secret_names = ["personal/curseforge-api-key"]
    tfe_workspace_enabled       = false
  },
  {
    repo_name                   = "specterrealm-core"
    github_org                  = "SpecterRealm"
    environment                 = "personal"
    cloud                       = "aws"
    function                    = "curseforge-specterrealm-core"
    allowed_refs                = ["refs/heads/main", "refs/tags/v*"]
    secretsmanager_secret_names = ["personal/curseforge-api-key"]
    tfe_workspace_enabled       = false
  },
  {
    # Consolidated into homelab-infra/terraform/observability (#102 Wave C). Workspace name
    # unchanged → VCS re-point. State on PostgreSQL (#258). HCP shell deleted (#214).
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "grafana"
    function                    = "cloud"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/grafana-cloud-api-token"]
    tfe_workspace_name          = "homelab-observability"
    tfe_workspace_enabled       = false
    tfe_execution_mode          = "local" # Grafana API is public; pg + Vault are not
    terraform_working_directory = "terraform/observability"
  },
  # homelab-infra repo: pipelines retain OIDC/SM wiring; HCP workspaces off after pg cutover (#214).
  {
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "substrate"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/portainer-api-token", "personal/homelab-alloy-grafana-env"]
    tfe_workspace_enabled       = false
    tfe_workspace_name          = "homelab-portainer"
    tfe_execution_mode          = "local" # HCP remote state; plan/apply on mgmt VLAN (Portainer unreachable from cloud)
    terraform_working_directory = "terraform/portainer"
  },
  {
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "nas01"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = [] # DSM creds from Vault (TF_VAR_synology_*), not SM
    tfe_workspace_enabled       = false
    tfe_workspace_name          = "homelab-nas01"
    tfe_execution_mode          = "local" # HCP remote state; plan/apply on mgmt VLAN (DSM API unreachable from cloud)
    terraform_working_directory = "terraform/nas01"
  },
  {
    # Consolidated into homelab-infra/terraform/vault (#102 Wave A). Workspace name
    # unchanged → VCS re-point, not a state migration. homelab-vault repo to be archived.
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "vault"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/vault-terraform-token"]
    tfe_workspace_enabled       = false
    tfe_workspace_name          = "homelab-vault"
    tfe_execution_mode          = "local" # Vault API on NAS01 mgmt VLAN only
    terraform_working_directory = "terraform/vault"
  },
  {
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "proxmox"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = [] # Proxmox API token from Vault (homelab/proxmox/api-token)
    tfe_workspace_enabled       = false
    tfe_workspace_name          = "homelab-proxmox"
    tfe_execution_mode          = "local" # Proxmox API on mgmt VLAN only; Vault also unreachable from cloud
    terraform_working_directory = "terraform/proxmox"
  },
  {
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "unifi"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = [] # UDM API key from Vault (homelab/unifi/controller-credentials)
    tfe_workspace_enabled       = false
    tfe_workspace_name          = "homelab-unifi"
    tfe_execution_mode          = "local" # UDM API on mgmt VLAN only
    terraform_working_directory = "terraform/unifi"
  },
  {
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "azure"
    allowed_refs                = ["refs/heads/main"]
    tfe_workspace_enabled       = false
    tfe_workspace_name          = "homelab-azure"
    tfe_execution_mode          = "local" # Azure AD API is public; pg state backend is VLAN 1 only
    terraform_working_directory = "terraform/azure"
  },
  {
    # Consolidated into homelab-infra/terraform/identity (#102 Wave B). Workspace name
    # unchanged → VCS re-point, not a state migration. homelab-identity repo to be archived.
    repo_name                   = "homelab-infra"
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "identity"
    allowed_refs                = ["refs/heads/main"]
    tfe_workspace_enabled       = false
    tfe_workspace_name          = "homelab-identity"
    tfe_execution_mode          = "local" # Authentik API on NAS01 mgmt VLAN only
    terraform_working_directory = "terraform/identity"
  },
]

service_accounts = [
  # Each entry creates: S3 artifacts bucket, Lambda permission boundary, GitHub Actions OIDC deploy role.
  # The deploy role is scoped to {service_name}-* resources and cannot delete the bucket or modify IAM
  # outside the service prefix. The permission boundary caps what Lambda execution roles can ever do.
  {
    service_name                 = "memex-suite"
    repo_name                    = "memex-suite"
    artifact_bucket_name         = "memex-suite-sam-artifacts"
    allowed_ref                  = "refs/heads/main"
    aws_region                   = "us-east-1"
    stack_name                   = "memex-prod"
    resource_name_prefixes       = ["memex-"]
    execution_role_name_prefixes = ["memex-prod-"]
    ssm_parameter_names          = ["/memex/database_url"]
  },
]

managed_repositories = [
  # ── Personal ────────────────────────────────────────────────────────────────
  {
    name        = "MichaelHeaton"
    description = "GitHub profile README"
    visibility  = "public"
    topics      = ["readme-profile"]
  },
  {
    name        = "memex"
    description = "My Default Obsidian Vault"
    visibility  = "private"
  },
  {
    name        = "memex-suite"
    description = "Memex Suite"
    visibility  = "public"
  },
  {
    name           = "workspaces"
    description    = "VS Code multi-root workspace configuration"
    visibility     = "private"
    default_branch = "Master"
  },
  {
    name        = "workstation-devops"
    description = "Personal workstation setup: dotfiles, software installs, and tooling configuration"
    visibility  = "public"
  },

  # ── Homelab ─────────────────────────────────────────────────────────────────
  {
    name        = "homelab-infra"
    description = "Homelab substrate: UniFi, Proxmox, NAS/Portainer, and Synology automation"
    visibility  = "private"
    topics      = ["homelab", "terraform", "proxmox", "unifi", "portainer"]
  },

  # ── Skills & tooling ────────────────────────────────────────────────────────
  {
    name        = "claude-skills"
    description = "Custom Claude Code skills for daily workflows"
    visibility  = "private"
  },
  {
    name        = "ai-skills"
    description = "Reusable AI assistant skills and workflows"
    visibility  = "public"
    license = {
      spdx_id = "MIT"
    }
  },

  # ── Esports ──────────────────────────────────────────────────────────────────
  {
    name        = "minecraft-modpack-family"
    description = "Family Minecraft modpack"
    visibility  = "private"
  },
  {
    name        = "minecraft-modpack-cp-verdant"
    description = "Colony Protocol: Verdant — Specter Realms modpack series"
    visibility  = "private"
  },
  {
    name        = "minecraft-modpack-ltm"
    description = "Specter Realms LTM — Persistent biodome world"
    visibility  = "private"
  },
]

mccleaton_repositories = [
  # cloudflare consolidated into homelab-infra/terraform/cloudflare (#102 Wave D) and archived.
  # Entry removed after `terraform state rm module.github_repos_mccleaton...` (repo had
  # prevent_destroy, so it was state-removed before this entry was dropped).
]

specterrealm_homelab_repositories = [
  # homelab-infra transferred to MichaelHeaton personal account (#92).
  # Entry removed after GitHub transfer + `terraform state rm module.github_repos_specterrealm_homelab...`
  # and import into module.github_repos (repo had prevent_destroy).
  # homelab-observability, homelab-vault, homelab-identity consolidated into
  # homelab-infra/terraform/{observability,vault,identity} (#102 Waves A–C) and archived.
  # Entries removed after `terraform state rm module.github_repos_specterrealm_homelab...`
  # (repos had prevent_destroy, so they were state-removed before these entries were dropped).
]

specterrealm_repositories = [
  # ── SpecterRealm — shared library ───────────────────────────────────────────
  {
    name        = "specterrealm-core"
    description = "Shared NeoForge library mod for all Colony Protocol packs (modId: specterrealm)"
    visibility  = "public"
    topics      = ["minecraft", "neoforge", "minecraft-mod", "colony-protocol"]
    license = {
      spdx_id = "MIT"
    }
  },

  # ── Colony Protocol packs ────────────────────────────────────────────────────
  {
    name        = "minecraft-modpack-cp-elysian"
    description = "Colony Protocol: Elysian — P2 magic/nature/exploration modpack (NeoForge 1.21.1)"
    visibility  = "public"
    topics      = ["minecraft", "neoforge", "packwiz", "colony-protocol"]
  },
  {
    name        = "minecraft-modpack-cp-influx"
    description = "Colony Protocol: Influx — P3 skyblock/EMC design phase (NeoForge 1.21.1)"
    visibility  = "public"
    topics      = ["minecraft", "neoforge", "packwiz", "colony-protocol"]
  },
  {
    name        = "minecraft-modpack-cp-liminal"
    description = "Colony Protocol: Liminal — P4 hostile contact/combat design phase (NeoForge 1.21.1)"
    visibility  = "public"
    topics      = ["minecraft", "neoforge", "packwiz", "colony-protocol"]
  },
]
