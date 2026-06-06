data "aws_secretsmanager_secret_version" "tfe_api_token" {
  secret_id = "platform-bootstrap/tfe-api-token"
}

data "aws_secretsmanager_secret_version" "github_app_pem" {
  secret_id = "platform-bootstrap/github-app-pem"
}

locals {
  tfe_api_token  = trimspace(data.aws_secretsmanager_secret_version.tfe_api_token.secret_string)
  github_app_pem = trimspace(data.aws_secretsmanager_secret_version.github_app_pem.secret_string)
}
