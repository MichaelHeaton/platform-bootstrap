#!/usr/bin/env bash
# Canonical Vault API URL for homelab automation (Terraform, GHA, Ansible).
#
# Service DNS via k3s Traefik → vault-ha (#600). Do not point at NAS 172.16.0.5.
#
# Override: export HOMELAB_VAULT_ADDR=... before sourcing vault-terraform-env.sh
# Break-glass (mgmt VLAN): HOMELAB_VAULT_ADDR_BREAKGLASS or peer discovery in
# scripts/vault-approle-login.sh
if [[ -z "${HOMELAB_VAULT_ADDR_DEFAULT:-}" ]]; then
  readonly HOMELAB_VAULT_ADDR_DEFAULT="https://vault.specterrealm.com"
fi
