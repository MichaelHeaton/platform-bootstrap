data "aws_secretsmanager_secret_version" "tfe_api_token" {
  secret_id = "platform-bootstrap/tfe-api-token"
}

locals {
  tfe_api_token = trimspace(data.aws_secretsmanager_secret_version.tfe_api_token.secret_string)
}
