terraform {
  required_version = ">= 0.14"
  backend "s3" {
    bucket = "kiru-infra-terraform-state-infrastructure"
    key    = "github-runners-scalable/infra.tfstate"

    # NOTE: This is the region the state s3 bucket is in, not the region the aws provider will deploy into
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
    profile        = "default"
  }
}
