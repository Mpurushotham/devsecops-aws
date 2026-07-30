terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used to fetch the OIDC issuer thumbprint for the IRSA provider.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
