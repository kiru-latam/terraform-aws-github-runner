locals {
  environment = "ubuntu"
  aws_region  = "us-east-1"
}

resource "random_password" "random" {
  length = 28
}

data "aws_ssm_parameter" "github_app_key_base64" {
  name = "/actions_runner/ubuntu/github_app_key_base64_tf"
}

data "aws_ssm_parameter" "github_app_client_id" {
  name = "/actions_runner/ubuntu/github_app_client_id_tf"
}

data "aws_ssm_parameter" "github_app_id" {
  name = "/actions_runner/ubuntu/github_app_id_tf"
}

data "aws_ssm_parameter" "github_app_client_secret" {
  name = "/actions_runner/ubuntu/github_app_client_secret_tf"
}

data "aws_ssm_parameter" "github_app_runner_vpc_id" {
  name = "/actions_runner/ubuntu/github_app_runner_vpc_id"
}

data "aws_ssm_parameter" "github_app_runner_subnet_ids" {
  name = "/actions_runner/ubuntu/github_app_runner_subnet_ids"
}

module "runners" {
  source = "../../"

  aws_region = local.aws_region
  # vpc_id     = module.vpc.vpc_id
  # subnet_ids = module.vpc.private_subnets
  # Provide network vpc ID and subnets ids
  vpc_id     = data.aws_ssm_parameter.github_app_runner_vpc_id.value
  subnet_ids = [data.aws_ssm_parameter.github_app_runner_subnet_ids.value]

  environment = local.environment
  tags = {
    Project = "ProjectX"
  }

  github_app = {
    # key_base64     = var.github_app_key_base64
    # id             = var.github_app_id
    key_base64     = data.aws_ssm_parameter.github_app_key_base64.value
    id             = data.aws_ssm_parameter.github_app_id.value
    webhook_secret = random_password.random.result
  }

  webhook_lambda_zip                = "lambdas-download/webhook.zip"
  runner_binaries_syncer_lambda_zip = "lambdas-download/runner-binaries-syncer.zip"
  runners_lambda_zip                = "lambdas-download/runners.zip"

  enable_organization_runners = false
  runner_extra_labels         = "ubuntu,example"

  # enable access to the runners via SSM
  enable_ssm_on_runners = true

  userdata_template = "./templates/user-data.sh"
  ami_owners        = ["099720109477"] # Canonical's Amazon account ID

  ami_filter = {
    name = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  block_device_mappings = {
    # Set the block device name for Ubuntu root device
    device_name = "/dev/sda1"
  }

  runner_log_files = [
    {
      "log_group_name" : "syslog",
      "prefix_log_group" : true,
      "file_path" : "/var/log/syslog",
      "log_stream_name" : "{instance_id}"
    },
    {
      "log_group_name" : "user_data",
      "prefix_log_group" : true,
      "file_path" : "/var/log/user-data.log",
      "log_stream_name" : "{instance_id}/user_data"
    },
    {
      "log_group_name" : "runner",
      "prefix_log_group" : true,
      "file_path" : "/home/runners/actions-runner/_diag/Runner_**.log",
      "log_stream_name" : "{instance_id}/runner"
    }
  ]

  # Uncommet idle config to have idle runners from 9 to 5 in time zone Amsterdam
  # idle_config = [{
  #   cron      = "* * 9-17 * * *"
  #   timeZone  = "Europe/Amsterdam"
  #   idleCount = 1
  # }]

  # disable KMS and encryption
  # encrypt_secrets = false
}
