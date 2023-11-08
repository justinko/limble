terraform {
  backend "s3" {
    bucket         = "tf-remote-state20231106023735974900000001"
    key            = "staging/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "cef70415-8bdf-49f8-a8ea-832f8e596e3c"
    dynamodb_table = "tf-remote-state-lock"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = "Staging"
    }
  }
}

module "wordpress" {
  source = "../../modules/wordpress"
  name = "limble-staging"
}
