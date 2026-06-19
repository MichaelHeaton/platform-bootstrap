# Infrastructure managed by this platform.
# Add new repos, pipelines, and service accounts here — Terraform picks this file up automatically.

pipelines = [
  {
    repo_name                   = "cloudflare"
    github_org                  = "McCleaton" # must match var.mccleaton_org (default)
    environment                 = "shared"
    cloud                       = "cloudflare"
    function                    = "dns"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/cloudflare-api-token"]
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
    repo_name                   = "homelab-observability"
    github_org                  = "specterrealm-homelab" # must match var.specterrealm_homelab_org
    environment                 = "personal"
    cloud                       = "grafana"
    function                    = "cloud"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/grafana-cloud-api-token"]
    tfe_workspace_name          = "homelab-observability"
    terraform_working_directory = "terraform"
  },
  # homelab-infra repo: one HCP workspace per terraform/<stack>/ root (homelab-<stack>).
  # Add separate pipelines entries for proxmox, unifi, etc. — same repo, scoped working_directory,
  # isolated state, and smaller blast radius. Portainer is first (local execution on mgmt VLAN).
  {
    repo_name                   = "homelab-infra"
    github_org                  = "specterrealm-homelab" # must match var.specterrealm_homelab_org
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "substrate"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/portainer-api-token", "personal/homelab-alloy-grafana-env"]
    tfe_workspace_enabled       = true
    tfe_workspace_name          = "homelab-portainer"
    tfe_execution_mode          = "local" # HCP remote state; plan/apply on mgmt VLAN (Portainer unreachable from cloud)
    terraform_working_directory = "terraform/portainer"
  },
  {
    repo_name                   = "homelab-infra"
    github_org                  = "specterrealm-homelab" # must match var.specterrealm_homelab_org
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "nas01"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = [] # DSM creds from Vault (TF_VAR_synology_*), not SM
    tfe_workspace_enabled       = true
    tfe_workspace_name          = "homelab-nas01"
    tfe_execution_mode          = "local" # HCP remote state; plan/apply on mgmt VLAN (DSM API unreachable from cloud)
    terraform_working_directory = "terraform/nas01"
  },
  {
    github_org                  = "specterrealm-homelab" # must match var.specterrealm_homelab_org
    environment                 = "personal"
    cloud                       = "homelab"
    function                    = "vault"
    allowed_refs                = ["refs/heads/main"]
    secretsmanager_secret_names = ["personal/vault-terraform-token"]
    tfe_workspace_enabled       = true
    tfe_workspace_name          = "homelab-vault"
    tfe_execution_mode          = "local" # Vault API on NAS01 mgmt VLAN only
    terraform_working_directory = "terraform"
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
  # ── Platform / domain infrastructure ────────────────────────────────────────
  {
    name              = "cloudflare"
    description       = "Cloudflare DNS and edge configuration (Terraform spoke)"
    visibility        = "private"
    topics            = ["terraform", "cloudflare", "dns"]
    branch_protection = false # McCleaton free org: private branch protection requires GitHub Team
  },
]

specterrealm_homelab_repositories = [
  # ── Homelab — substrate (UniFi, Proxmox, NAS/Portainer) ─────────────────────
  {
    name              = "homelab-infra"
    description       = "Homelab substrate: UniFi, Proxmox, NAS/Portainer, and Synology automation"
    visibility        = "private"
    topics            = ["homelab", "terraform", "proxmox", "unifi", "portainer"]
    branch_protection = false # free org: private branch protection requires GitHub Team
  },
  # ── Homelab — observability (Phase 2) ───────────────────────────────────────
  {
    name              = "homelab-observability"
    description       = "Homelab observability: Grafana Cloud, agents, dashboards, and alerting"
    visibility        = "private"
    topics            = ["homelab", "grafana", "observability", "terraform"]
    branch_protection = false # free org: private branch protection requires GitHub Team
  },
  {
    name              = "homelab-vault"
    description       = "Homelab Vault: KV mounts, policies, and AppRoles (Terraform)"
    visibility        = "private"
    topics            = ["homelab", "vault", "terraform", "secrets"]
    branch_protection = false
  },
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
