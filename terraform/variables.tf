variable "region" {
  description = "AWS region for the whole stack."
  type        = string
  default     = "eu-west-1"
}

variable "account_id" {
  description = "The lab AWS account. The provider refuses to run against any other account."
  type        = string
}

variable "domain_zone" {
  description = "Optional. EXISTING public Route 53 hosted zone, e.g. lab.example.com, with an ISSUED ACM certificate for web_host + api_host. Not managed here. Leave empty to serve plain HTTP on the ALB's DNS name."
  type        = string
  default     = ""
}

variable "web_host" {
  description = "Public hostname of the payment web page (only used when domain_zone is set)."
  type        = string
  default     = ""
}

variable "api_host" {
  description = "Public hostname of the API (only used when domain_zone is set)."
  type        = string
  default     = ""
}

variable "connection_arn" {
  description = "EXISTING CodeConnections (GitHub) connection ARN, status Available. Created once in the console."
  type        = string
}

variable "github_owner" {
  description = "GitHub user/org that owns the paylab-<service> repos."
  type        = string
}

variable "github_branch" {
  description = "Branch the pipelines build and deploy."
  type        = string
  default     = "main"
}

variable "bootstrap_image_tag" {
  description = "Image tag the Terraform task definitions start with. The pipelines push :latest (and :<sha>) on their first run."
  type        = string
  default     = "latest"
}

variable "create_ecs_service_linked_role" {
  description = "Create the ECS service-linked role. Leave false if it already exists in the account (it usually does)."
  type        = bool
  default     = false
}
