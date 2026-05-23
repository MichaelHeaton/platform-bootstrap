# Infrastructure managed by this platform.
# Add new repos, pipelines, and service accounts here — Terraform picks this file up automatically.

service_accounts = [
  # Each entry creates: S3 artifacts bucket, Lambda permission boundary, GitHub Actions OIDC deploy role.
  # The deploy role is scoped to {service_name}-* resources and cannot delete the bucket or modify IAM
  # outside the service prefix. The permission boundary caps what Lambda execution roles can ever do.
  {
    service_name         = "memex-suite"
    repo_name            = "memex-suite"
    artifact_bucket_name = "memex-suite-sam-artifacts"
    allowed_ref          = "refs/heads/main"
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
    visibility  = "public"
  },

  # ── Homelab — config ────────────────────────────────────────────────────────
  {
    name        = "homelab-core"
    description = "Homelab config: homelab-core"
    visibility  = "private"
  },
  {
    name        = "homelab-automation"
    description = "Homelab config: homelab-automation"
    visibility  = "private"
  },
  {
    name        = "homelab-esports"
    description = "Homelab config: homelab-esports"
    visibility  = "private"
  },
  {
    name        = "homelab-identity"
    description = "Homelab config: homelab-identity"
    visibility  = "private"
  },
  {
    name        = "homelab-infra"
    description = "Homelab config: homelab-infra"
    visibility  = "private"
  },
  {
    name        = "homelab-observability"
    description = "Homelab config: homelab-observability"
    visibility  = "private"
  },
  {
    name        = "homelab-streaming"
    description = "Homelab config: homelab-streaming"
    visibility  = "private"
  },
  {
    name        = "homelab-cicd-templates"
    description = "Shared GitLab CI/CD pipeline templates"
    visibility  = "private"
  },

  # ── Homelab — Ansible roles ──────────────────────────────────────────────────
  {
    name        = "ansible-role-base-server"
    description = "Ansible role: ansible-role-base-server"
    visibility  = "private"
  },
  {
    name        = "ansible-role-cloudflared"
    description = "Ansible role: ansible-role-cloudflared"
    visibility  = "private"
  },
  {
    name        = "ansible-role-factorio"
    description = "Ansible role: ansible-role-factorio"
    visibility  = "private"
  },
  {
    name        = "ansible-role-minecraft"
    description = "Ansible role: ansible-role-minecraft"
    visibility  = "private"
  },
  {
    name        = "ansible-role-traefik"
    description = "Ansible role: ansible-role-traefik"
    visibility  = "private"
  },

  # ── Homelab — Terraform modules ──────────────────────────────────────────────
  {
    name        = "tf-module-cloudflare-tunnel"
    description = "Terraform module: tf-module-cloudflare-tunnel"
    visibility  = "private"
  },
  {
    name        = "tf-module-dns-record"
    description = "Terraform module: tf-module-dns-record"
    visibility  = "private"
  },
  {
    name        = "tf-module-docker-service"
    description = "Terraform module: tf-module-docker-service"
    visibility  = "private"
  },
  {
    name        = "tf-module-game-server"
    description = "Terraform module: tf-module-game-server"
    visibility  = "private"
  },
  {
    name        = "tf-module-ssl-cert"
    description = "Terraform module: tf-module-ssl-cert"
    visibility  = "private"
  },
  {
    name        = "tf-module-vm-lxc"
    description = "Terraform module: tf-module-vm-lxc"
    visibility  = "private"
  },

  # ── Esports ──────────────────────────────────────────────────────────────────
  {
    name        = "factorio-blueprints"
    description = "Factorio blueprint collection"
    visibility  = "private"
  },
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
