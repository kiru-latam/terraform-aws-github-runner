locals {
  environment = "default"
  aws_region  = "eu-west-1"
}

resource "random_password" "random" {
  length = 28
}


################################################################################
### Hybrid acccount
################################################################################

module "runners" {
  source                          = "../../"
  create_service_linked_role_spot = true
  aws_region                      = local.aws_region
  vpc_id                          = module.vpc.vpc_id
  subnet_ids                      = module.vpc.private_subnets

  environment = local.environment
  tags = {
    Project = "ProjectX"
  }

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = random_password.random.result
  }

  webhook_lambda_zip                = "lambdas-download/webhook.zip"
  runner_binaries_syncer_lambda_zip = "lambdas-download/runner-binaries-syncer.zip"
  runners_lambda_zip                = "lambdas-download/runners.zip"
  enable_organization_runners       = false
  runner_extra_labels               = "default,example"

  # enable access to the runners via SSM
  enable_ssm_on_runners = true

  # use S3 or KMS SSE to runners S3 bucket
  # runner_binaries_s3_sse_configuration = {
  #   rule = {
  #     apply_server_side_encryption_by_default = {
  #       sse_algorithm = "AES256"
  #     }
  #   }
  # }

  # Uncommet idle config to have idle runners from 9 to 5 in time zone Amsterdam
  # idle_config = [{
  #   cron      = "* * 9-17 * * *"
  #   timeZone  = "Europe/Amsterdam"
  #   idleCount = 1
  # }]

  # Let the module manage the service linked role
  # create_service_linked_role_spot = true

  instance_types = ["m5.2xlarge", "c5.large"]

  # override delay of events in seconds
  delay_webhook_event = 5

  # override scaling down
  scale_down_schedule_expression = "cron(* * * * ? *)"
}
