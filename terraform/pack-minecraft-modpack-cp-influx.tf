# Colony Protocol: Influx (P3 — design phase).
# Minimal settings until the pack moves to active development.

locals {
  pack_settings_minecraft_modpack_cp_influx = {
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
      { name = "design-decision", color = "0075ca", description = "Requires a design call before implementation" },
      { name = "priority/high", color = "dc2626", description = "Urgent, time-sensitive, blocking other work" },
      { name = "priority/medium", color = "d97706", description = "Important but flexible timeline" },
      { name = "priority/low", color = "6b7280", description = "Nice-to-have, no specific deadline" },
    ])

    labels_remove = tolist([])
  }
}
