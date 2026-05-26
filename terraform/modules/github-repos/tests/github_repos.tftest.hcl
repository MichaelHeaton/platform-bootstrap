# These tests require a valid GITHUB_TOKEN environment variable with repo
# creation permissions in the target organisation.
# Run with: terraform test
# Resources created during the test run are destroyed automatically on completion.
#
# WARNING: github_repository resources have prevent_destroy = true in the main
# module. The test framework destroys resources post-run regardless, but be
# aware that applying this module outside of `terraform test` will protect repos
# from accidental deletion.

run "validation_rejects_platform_bootstrap" {
  command = plan

  # Expect Terraform to surface the validation error defined in variables.tf.
  expect_failures = [var.repositories]

  variables {
    repositories = [
      {
        name        = "platform-bootstrap"
        description = "Should be rejected by validation rule (ADR-004)"
        visibility  = "private"
        topics      = []
      }
    ]
    codeowners = ["@test-owner"]
  }
}

run "empty_repositories_succeeds" {
  command = plan

  variables {
    repositories = []
    codeowners   = ["@test-owner"]
  }

  assert {
    condition     = length(github_repository.managed) == 0
    error_message = "repository_ids must be an empty map when no repositories are provided"
  }
}

run "pages_workflow_configures_repository_pages" {
  command = plan

  variables {
    repositories = [
      {
        name        = "docs-site"
        description = "Repository with GitHub Pages managed by Terraform"
        visibility  = "private"
        pages = {
          build_type = "workflow"
        }
      }
    ]
    codeowners = ["@test-owner"]
  }

  assert {
    condition     = github_repository_pages.managed["docs-site"].build_type == "workflow"
    error_message = "workflow Pages config should create a github_repository_pages resource"
  }
}

run "validation_rejects_workflow_pages_source" {
  command = plan

  expect_failures = [var.repositories]

  variables {
    repositories = [
      {
        name        = "docs-site"
        description = "Repository with invalid workflow Pages source"
        visibility  = "private"
        pages = {
          build_type = "workflow"
          source = {
            branch = "main"
            path   = "/docs"
          }
        }
      }
    ]
    codeowners = ["@test-owner"]
  }
}
