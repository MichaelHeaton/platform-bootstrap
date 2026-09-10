#!/usr/bin/env bash
# Canonical Vault API URL for homelab automation (Terraform, Forgejo, Ansible).
#
# Service DNS via Traefik — survives Vault moving off NAS01; update the backend in
# stacks/traefik/dynamic/routes-vault.yaml when the host changes.
#
# Override: export HOMELAB_VAULT_ADDR=... before sourcing vault-terraform-env.sh
# Break-glass (mgmt VLAN direct): HOMELAB_VAULT_ADDR_BREAKGLASS in scripts/vault-approle-login.sh
if [[ -z "${HOMELAB_VAULT_ADDR_DEFAULT:-}" ]]; then
  readonly HOMELAB_VAULT_ADDR_DEFAULT="https://vault.specterrealm.com"
fi
