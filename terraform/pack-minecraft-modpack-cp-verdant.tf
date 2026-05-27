# SpecterRealm pack repo GitHub settings — copy this file when onboarding another pack.
# Wire the repo name in locals.managed_repositories_resolved (terraform/main.tf).

locals {
  pack_settings_minecraft_modpack_cp_verdant = {
    has_discussions     = true
    main_branch_ruleset = true

    # Pages source is GitHub Actions. The pack repo's Pages workflow uploads
    # docs/ as the artifact; GitHub does not expose that path in Pages settings
    # when build_type is "workflow".
    pages = {
      build_type = "workflow"
    }

    # GitHub exposes no API to create discussion categories. "ideas" is a default
    # category when Discussions is enabled; create "mod-suggestions" once in the
    # repo UI (Settings → Discussions). Slugs verified by compliance_check.py.
    # See docs/runbooks/05-specterrealm-pack-github-settings.md.

    # Remove Memex vault labels if they were copied onto this repo; do not recreate.
    labels_remove = tolist([
      "triage/needs-grooming",
      "type/brain-dump",
      "domain/adobe",
      "domain/uv-cyber",
      "domain/homelab",
      "domain/learning",
      "domain/iot",
      "domain/mtb",
      "domain/personal",
      "cat/gathering",
      "cat/defense",
      "cat/utility",
      "cat/maintenance",
      "cat/organic",
      "cat/stone",
      "cat/mob",
      "cat/sieve",
      "cat/food",
      "cat/ore-processing",
      "cat/containment",
      "cat/crafting",
      "cat/fluid",
      "cat/item-movement",
      "cat/generate",
      "cat/move",
      "cat/store",
      "cat/computing",
      "cat/networking",
      "cat/rest",
      "cat/sustenance",
      "cat/lighting",
    ])

    labels = tolist([
      { name = "bug", color = "d73a4a", description = "Something isn't working" },
      { name = "documentation", color = "0075ca", description = "Improvements or additions to documentation" },
      { name = "duplicate", color = "cfd3d7", description = "This issue or pull request already exists" },
      { name = "enhancement", color = "a2eeef", description = "New feature or request" },
      { name = "good first issue", color = "7057ff", description = "Good for newcomers" },
      { name = "help wanted", color = "008672", description = "Extra attention is needed" },
      { name = "invalid", color = "e4e669", description = "This doesn't seem right" },
      { name = "question", color = "d876e3", description = "Further information is requested" },
      { name = "wontfix", color = "ffffff", description = "This will not be worked on" },
      { name = "quest", color = "f9d71c", description = "Quest content, structure, or text" },
      { name = "mod-review", color = "8b3dcc", description = "Mod evaluation, research, or config decisions" },
      { name = "recipe", color = "e8730a", description = "Recipe additions, changes, or gating" },
      { name = "qa", color = "0e8a6e", description = "In-game validation and testing" },
      { name = "design-decision", color = "0075ca", description = "Requires a design call before implementation" },
      { name = "needs-testing", color = "e4e669", description = "Requires in-game verification" },
      { name = "audit", color = "d93f0b", description = "Requires a full audit pass" },
      { name = "priority/high", color = "dc2626", description = "Urgent, time-sensitive, blocking other work" },
      { name = "priority/medium", color = "d97706", description = "Important but flexible timeline" },
      { name = "priority/low", color = "6b7280", description = "Nice-to-have, no specific deadline" },
      { name = "status/needs-confirmation", color = "e9c32c", description = "Awaiting repro on current pack version" },
      { name = "status/confirmed", color = "0e8a16", description = "Reproduced on latest exported build" },
      { name = "status/fixed-in-dev", color = "a309ec", description = "Fixed on main, not in a playtest zip yet" },
      { name = "in-progress", color = "1d76db", description = "Active development this session" },
      { name = "content", color = "f9d71c", description = "Quest, narrative, or Patchouli content" },
    ])
  }
}
