terraform {
  required_version = ">= 1.14.3"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.56.0"
      configuration_aliases = [aws.targets_ssm]
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}
