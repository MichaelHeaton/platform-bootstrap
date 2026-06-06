# These tests require GitHub App credentials or override_data stubs.
# Run with: terraform test
# Resources created during the test run are destroyed automatically on completion.
#
# WARNING: github_repository resources have prevent_destroy = true in the main
# module. The test framework destroys resources post-run regardless, but be
# aware that applying this module outside of `terraform test` will protect repos
# from accidental deletion.

run "validation_rejects_platform_bootstrap" {
  command = plan

  override_data {
    target = data.github_app_token.local_exec
    values = {
      token = "test-installation-token"
    }
  }

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
    codeowners                 = ["@test-owner"]
    github_org                 = "test-org"
    github_app_id              = "12345"
    github_app_installation_id = "67890"
    github_app_pem             = "dummy-pem"
  }
}

run "empty_repositories_succeeds" {
  command = plan

  override_data {
    target = data.github_app_token.local_exec
    values = {
      token = "test-installation-token"
    }
  }

  variables {
    repositories               = []
    codeowners                 = ["@test-owner"]
    github_org                 = "test-org"
    github_app_id              = "12345"
    github_app_installation_id = "67890"
    github_app_pem             = "dummy-pem"
  }

  assert {
    condition     = length(github_repository.managed) == 0
    error_message = "repository_ids must be an empty map when no repositories are provided"
  }
}

run "pages_workflow_configures_repository_pages" {
  command = plan

  override_data {
    target = data.github_app_token.local_exec
    values = {
      token = "test-installation-token"
    }
  }

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
    codeowners                 = ["@test-owner"]
    github_org                 = "test-org"
    github_app_id              = "12345"
    github_app_installation_id = "67890"
    github_app_pem             = "dummy-pem"
  }

  assert {
    condition     = github_repository_pages.managed["docs-site"].build_type == "workflow"
    error_message = "workflow Pages config should create a github_repository_pages resource"
  }
}

run "validation_rejects_workflow_pages_source" {
  command = plan

  override_data {
    target = data.github_app_token.local_exec
    values = {
      token = "test-installation-token"
    }
  }

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
    codeowners                 = ["@test-owner"]
    github_org                 = "test-org"
    github_app_id              = "12345"
    github_app_installation_id = "67890"
    github_app_pem             = "dummy-pem"
  }
}
