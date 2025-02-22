# Terraform module for scalable self hosted GitHub action runners <!-- omit in toc -->

[![awesome-runners](https://img.shields.io/badge/listed%20on-awesome--runners-blue.svg)](https://github.com/jonico/awesome-runners)[![Terraform registry](https://img.shields.io/github/v/release/philips-labs/terraform-aws-github-runner?label=Terraform%20Registry)](https://registry.terraform.io/modules/philips-labs/github-runner/aws/) ![Terraform checks](https://github.com/philips-labs/terraform-aws-github-runner/workflows/Terraform%20root%20module%20checks/badge.svg) ![Lambda Webhook](https://github.com/philips-labs/terraform-aws-github-runner/workflows/Lambda%20Agent%20Webhook/badge.svg) ![Lambda Runners](https://github.com/philips-labs/terraform-aws-github-runner/workflows/Lambda%20Runners/badge.svg) ![Lambda Syncer](https://github.com/philips-labs/terraform-aws-github-runner/workflows/Lambda%20Runner%20Binaries%20Syncer/badge.svg)

This [Terraform](https://www.terraform.io/) module creates the required infrastructure needed to host [GitHub Actions](https://github.com/features/actions) self hosted, auto scaling runners on [AWS spot instances](https://aws.amazon.com/ec2/spot/). It provides the required logic to handle the life cycle for scaling up and down using a set of AWS Lambda functions. Runners are scaled down to zero to avoid costs when no workflows are active.

- [Motivation](#motivation)
- [Overview](#overview)
  - [ARM64 support via Graviton/Graviton2 instance-types](#arm64-support-via-gravitongraviton2-instance-types)
- [Usages](#usages)
  - [Setup GitHub App (part 1)](#setup-github-app-part-1)
  - [Setup terraform module](#setup-terraform-module)
  - [Setup the webhook / GitHub App (part 2)](#setup-the-webhook--github-app-part-2)
    - [Option 1: Webhook](#option-1-webhook)
    - [Option 2: App](#option-2-app)
    - [Install app](#install-app)
  - [Encryption](#encryption)
  - [Idle runners](#idle-runners)
- [Examples](#examples)
- [Sub modules](#sub-modules)
  - [ARM64 configuration for submodules](#arm64-configuration-for-submodules)
- [Debugging](#debugging)
- [Requirements](#requirements)
- [Providers](#providers)
- [Modules](#modules)
- [Resources](#resources)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Contribution](#contribution)
- [Philips Forest](#philips-forest)

## Motivation

GitHub Actions `self hosted` runners provide a flexible option to run CI workloads on infrastructure of your choice. Currently there is no option provided to automate the creation and scaling of action runners. This module takes care of creating the AWS infrastructure to host action runners on spot instances. It provides lambda modules to orchestrate the life cycle of the action runners.

Lambda is chosen as runtime for two major reasons. First it allows to create small components with minimal access to AWS and GitHub. Secondly it provides a scalable setup with minimal costs that works on repo level and scales to organization level. The lambdas will create Linux based EC2 instances with Docker to serve CI workloads that can run on Linux and/or Docker. The main goal is to support Docker based workloads.

A logical question would be why not Kubernetes? In the current approach we stay close to the way the GitHub action runners are available today. The approach is to install the runner on a host where the required software is available. With this setup we stay quite close to the current GitHub approach. Another logical choice would be AWS Auto Scaling groups. This choice would typically require much more permissions on instance level to GitHub. And besides that, scaling up and down is not trivial.

## Overview

The moment a GitHub action workflow requiring a `self-hosted` runner is triggered, GitHub will try to find a runner which can execute the workload. This module reacts to GitHub's [`check_run` event](https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads#check_run) or [`workflow_job` event](https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#workflow_job) for the triggered workflow and creates a new runner if necessary.

For receiving the `check_run` or `workflow_job` event by the webhook (lambda) a webhook in GitHub needs to be created. The `workflow_job` is the preferred option and the `check_run` option will be maintained for backward compatibility. Advantage of the `workflow_job` event is that the runner checks if the received event can run on the configured runners by matching the labels, which avoid instances are scaled up and never used. The following options are available:

- `workflow_job`: **(preferred option)** create a webhook on enterprise, org or app level.
- `check_run`: create a webhook on enterprise, org, repo or app level. When using the app option, the app needs to be installed to repo's are using the self-hosted runners.
-  a Webhook needs to be created. The webhook hook can be defined on enterprise, org, repo, or app level. 


In AWS a [API gateway](https://docs.aws.amazon.com/apigateway/index.html) endpoint is created that is able to receive the GitHub webhook events via HTTP post. The gateway triggers the webhook lambda which will verify the signature of the event. This check guarantees the event is sent by the GitHub App. The lambda only handles `workflow_job` or `check_run` events with status `queued` and matching the runner labels (only for `workflow_job`). The accepted events are posted on a SQS queue. Messages on this queue will be delayed for a configurable amount of seconds (default 30 seconds) to give the available runners time to pick up this build.

The "scale up runner" lambda is listening to the SQS queue and picks up events. The lambda runs various checks to decide whether a new EC2 spot instance needs to be created. For example, the instance is not created if the build is already started by an existing runner, or the maximum number of runners is reached.

The Lambda first requests a registration token from GitHub which is needed later by the runner to register itself. This avoids that the EC2 instance, which later in the process will install the agent, needs administration permissions to register the runner. Next the EC2 spot instance is created via the launch template. The launch template defines the specifications of the required instance and contains a [`user_data`](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html) script. This script will install the required software and configure it. The registration token for the action runner is stored in the parameter store (SSM) from which the user data script will fetch it and delete it once it has been retrieved. Once the user data script is finished the action runner should be online and the workflow will start in seconds.

Scaling down the runners is at the moment brute-forced, every configurable amount of minutes a lambda will check every runner (instance) if it is busy. In case the runner is not busy it will be removed from GitHub and the instance terminated in AWS. At the moment there seems no other option to scale down more smoothly.

Downloading the GitHub Action Runner distribution can be occasionally slow (more than 10 minutes). Therefore a lambda is introduced that synchronizes the action runner binary from GitHub to an S3 bucket. The EC2 instance will fetch the distribution from the S3 bucket instead of the internet.

Secrets and private keys are stored in SSM Parameter Store. These values are encrypted using the default KMS key for SSM or passing in a custom KMS key.

![Architecture](docs/component-overview.svg)

Permission are managed on several places. Below the most important ones. For details check the Terraform sources.

- The GitHub App requires access to actions and publish `workflow_job` events to the AWS webhook (API gateway).
- The scale up lambda should have access to EC2 for creating and tagging instances.
- The scale down lambda should have access to EC2 to terminate instances.

Besides these permissions, the lambdas also need permission to CloudWatch (for logging and scheduling), SSM and S3. For more details about the required permissions see the [documentation](./modules/setup-iam-permissions/README.md) of the IAM module which uses permission boundaries.

### ARM64 support via Graviton/Graviton2 instance-types

When using the default example or top-level module, specifying an `instance_type` that matches a Graviton/Graviton 2 (ARM64) architecture (e.g. a1 or any 6th-gen `g` or `gd` type), the sub-modules will be automatically configured to provision with ARM64 AMIs and leverage GitHub's ARM64 action runner. See below for more details.

## Usages

Examples are provided in [the example directory](examples/). Please ensure you have installed the following tools.

- Terraform, or [tfenv](https://github.com/tfutils/tfenv).
- Bash shell or compatible
- Docker (optional, to build lambdas without node).
- AWS cli (optional)
- Node and yarn (for lambda development).

The module supports two main scenarios for creating runners. On repository level a runner will be dedicated to only one repository, no other repository can use the runner. On organization level you can use the runner(s) for all the repositories within the organization. See [GitHub instructions](https://help.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners) for more information. Before starting the deployment you have to choose one option.

GitHub workflows fail immediately if there is no action runner available for your builds. Since this module supports scaling down to zero, builds will fail in case there is no active runner available. We recommend to create an offline runner with matching labels to the configuration. Create this runner manually by following the [GitHub instructions](https://help.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners) for adding a new runner on your local machine. If you stop the process after the step of running the `config.sh` script the runner will remain offline. This offline runner ensures that builds will not fail immediately and stay queued until there is an EC2 runner to pick it up.

Another convenient way of deploying this temporary required runner is using following approach. This automates all the manual labor.

<details>
  <summary>Temporary runner using Docker</summary>

  ```bash
  docker run -it --name my-runner \
      -e RUNNER_LABELS=selfhosted,Linux,Ubuntu -e RUNNER_NAME=my-repo-docker-runner \
      -e GITHUB_ACCESS_TOKEN=$GH_PERSONAL_ACCESS_TOKEN \
      -e RUNNER_REPOSITORY_URL=https://github.com/my-org/my-repo \
      -v /var/run/docker.sock:/var/run/docker.sock \
      tcardonne/github-runner:ubuntu-20.04
  ```

</details>

You should stop and remove the container once the runner is registered as the builds would otherwise go to your local Docker container.

The setup consists of running Terraform to create all AWS resources and manually configuring the GitHub App. The Terraform module requires configuration from the GitHub App and the GitHub app requires output from Terraform. Therefore you first create the GitHub App and configure the basics, then run Terraform, and afterwards finalize the configuration of the GitHub App.

### Setup GitHub App (part 1)

Go to GitHub and [create a new app](https://docs.github.com/en/developers/apps/creating-a-github-app). Beware you can create apps your organization or for a user. For now we support only organization level apps.

1. Create app in Github
2. Choose a name
3. Choose a website (mandatory, not required for the module).
4. Disable the webhook for now (we will configure this later or create an alternative webhook).
5. Permissions for all runners:
    - Repository:
      - `Actions`: Read-only (check for queued jobs)
      - `Checks`: Read-only (receive events for new builds)
      - `Metadata`: Read-only (default/required)
6. _Permissions for repo level runners only_:
   - Repository:
     - `Administration`: Read & write (to register runner)
7. _Permissions for organization level runners only_:
   - Organization
     - `Self-hosted runners`: Read & write (to register runner)
8. Save the new app.
9. On the General page, make a note of the "App ID" and "Client ID" parameters.
10. Generate a new private key and save the `app.private-key.pem` file.

### Setup terraform module

#### Download lambdas <!-- omit in toc -->

To apply the terraform module, the compiled lambdas (.zip files) need to be available either locally or in an S3 bucket. They can be either downloaded from the GitHub release page or build locally.

To read the files from S3, set the `lambda_s3_bucket` variable and the specific object key for each lambda.

The lambdas can be downloaded manually from the [release page](https://github.com/philips-labs/terraform-aws-github-runner/releases) or using the [download-lambda](./modules/download-lambda) terraform module (requires `curl` to be installed on your machine). In the `download-lambda` directory, run `terraform init && terraform apply`. The lambdas will be saved to the same directory.

For local development you can build all the lambdas at once using `.ci/build.sh` or individually using `yarn dist`.

#### Service-linked role <!-- omit in toc -->

To create spot instances the `AWSServiceRoleForEC2Spot` role needs to be added to your account. You can do that manually by following the [AWS docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-requests.html#service-linked-roles-spot-instance-requests). To use terraform for creating the role, either add the following resource or let the module manage the the service linked role by setting `create_service_linked_role_spot` to `true`. Be aware this is an account global role, so maybe you don't want to manage it via a specific deployment.

```hcl
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
}
```

#### Terraform module <!-- omit in toc -->

Next create a second terraform workspace and initiate the module, or adapt one of the [examples](./examples).

Note that `github_app.key_base64` needs to be a base64-encoded string of the `.pem` file i.e. the output of `base64 app.private-key.pem`. The decoded string can either be a multiline value or a single line value with new lines represented with literal `\n` characters.

```terraform
module "github-runner" {
  source  = "philips-labs/github-runner/aws"
  version = "REPLACE_WITH_VERSION"

  aws_region = "eu-west-1"
  vpc_id     = "vpc-123"
  subnet_ids = ["subnet-123", "subnet-456"]

  environment = "gh-ci"

  github_app = {
    key_base64     = "base64string"
    id             = "1"
    webhook_secret = "webhook_secret"
  }

  webhook_lambda_zip                = "lambdas-download/webhook.zip"
  runner_binaries_syncer_lambda_zip = "lambdas-download/runner-binaries-syncer.zip"
  runners_lambda_zip                = "lambdas-download/runners.zip"
  enable_organization_runners = true
}
```

**ARM64** support: Specify an `a1` or `*6g*` (6th-gen Graviton2) instance type to stand up an ARM64 runner, otherwise the default is x86_64.

Run terraform by using the following commands

```bash
terraform init
terraform apply
```

The terraform output displays the API gateway url (endpoint) and secret, which you need in the next step.

The lambda for syncing the GitHub distribution to S3 is triggered via CloudWatch (by default once per hour). After deployment the function is triggered via S3 to ensure the distribution is cached.

### Setup the webhook / GitHub App (part 2)

At this point you have 2 options. Either create a separate webhook (enterprise, 
org, or repo), or create webhook in the App. 

#### Option 1: Webhook

1. Create a new webhook on repo level for repo level for repo level runner, or org (or enterprise level) for an org level runner.
2. Provide the webhook url, should be part of the output of terraform.
3. Provide the webhook secret (`terraform output -raw <NAME_OUTPUT_VAR>`).
4. In the "Permissions & Events" section and then "Subscribe to Events" subsection, check either "Workflow Job" or "Check Run" (choose only 1 option!!!).
5. In the "Install App" section, install the App in your organization, either in all or in selected repositories.
 
#### Option 2: App

Go back to the GitHub App and update the following settings.

1. Enable the webhook.
2. Provide the webhook url, should be part of the output of terraform.
3. Provide the webhook secret (`terraform output -raw <NAME_OUTPUT_VAR>`).
4. In the "Permissions & Events" section and then "Subscribe to Events" subsection, check either "Workflow Job" or "Check Run" (choose only 1 option!!!).

#### Install app

Finally you need to ensure the app is installed to all or selected repositories.

Go back to the GitHub App and update the following settings.

1. In the "Install App" section, install the App in your organization, either in all or in selected repositories.

You are now ready to run action workloads on self hosted runner. Remember that builds will fail if there is no (offline) runner available with matching labels.

### Encryption

The module support 2 scenarios to manage environment secrets and private key of the Lambda functions.

#### Encrypted via a module managed KMS key (default) <!-- omit in toc -->

This is the default, no additional configuration is required.

#### Encrypted via a provided KMS key <!-- omit in toc -->

You have to create an configure you KMS key. The module will use the context with key: `Environment` and value `var.environment` as encryption context.

```hcl
resource "aws_kms_key" "github" {
  is_enabled = true
}

module "runners" {

  ...
  kms_key_arn = aws_kms_key.github.arn
  ...

```

### Idle runners

The module will scale down to zero runners be default, by specifying a `idle_config` config idle runners can be kept active. The scale down lambda checks if any of the cron expressions matches the current time with a marge of 5 seconds. When there is a match the number of runners specified in the idle config will be kept active. In case multiple cron expressions matches only the first one is taken in to account. Below an idle configuration for keeping runners active from 9 to 5 on working days.

```hcl
idle_config = [{
   cron      = "* * 9-17 * * 1-5"
   timeZone  = "Europe/Amsterdam"
   idleCount = 2
}]
```

#### Supported config <!-- omit in toc -->

Cron expressions are parsed by [cron-parser](https://github.com/harrisiirak/cron-parser#readme). The supported syntax.

```bash
*    *    *    *    *    *
┬    ┬    ┬    ┬    ┬    ┬
│    │    │    │    │    |
│    │    │    │    │    └ day of week (0 - 7) (0 or 7 is Sun)
│    │    │    │    └───── month (1 - 12)
│    │    │    └────────── day of month (1 - 31)
│    │    └─────────────── hour (0 - 23)
│    └──────────────────── minute (0 - 59)
└───────────────────────── second (0 - 59, optional)
```

For time zones please check [TZ database name column](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) for the supported values.

## Examples

Examples are located in the [examples](./examples) directory. The following examples are provided:

- _[Default](examples/default/README.md)_: The default example of the module
- _[Permissions boundary](examples/permissions-boundary/README.md)_: Example usages of permissions boundaries.

## Sub modules

The module contains several submodules, you can use the module via the main module or assemble your own setup by initializing the submodules yourself.

The following submodules are the core of the module and are mandatory:

- _[runner-binaries-syncer](./modules/runner-binaries-syncer/README.md)_ - Syncs the action runner distribution.
- _[runners](./modules/runners/README.md)_ - Scales the action runners up and down
- _[webhook](./modules/webhook/README.md)_ - Handles GitHub webhooks

The following sub modules are optional and are provided as example or utility:

- _[download-lambda](./modules/download-lambda/README.md)_ - Utility module to download lambda artifacts from GitHub Release
- _[setup-iam-permissions](./modules/setup-iam-permissions/README.md)_ - Example module to setup permission boundaries

### ARM64 configuration for submodules

When not using the top-level module and specifying an `a1` or `*6g*` (6th-gen Graviton2) `instance_type`, the `runner-binaries-syncer` and `runners` submodules need to be configured appropriately for pulling the ARM64 GitHub action runner binary and leveraging the arm64 AMI for the runners.

When configuring `runner-binaries-syncer`

- _runner_architecture_ - set to `arm64`, defaults to `x64`

When configuring `runners`

- _ami_filter_ - set to `["amzn2-ami-hvm-2*-arm64-gp2"]`, defaults to `["amzn2-ami-hvm-2.*-x86_64-ebs"]`

## Debugging

In case the setup does not work as intended follow the trace of events:

- In the GitHub App configuration, the Advanced page displays all webhook events that were sent.
- In AWS CloudWatch, every lambda has a log group. Look at the logs of the `webhook` and `scale-up` lambdas.
- In AWS SQS you can see messages available or in flight.
- Once an EC2 instance is running, you can connect to it in the EC2 user interface using Session Manager. Check the user data script using `cat /var/log/user-data.log`. By default several log files of the instances are streamed to AWS CloudWatch, look for a log group named `<environment>/runners`. In the log group you should see at least the log streams for the user data installation and runner agent.
- Registered instances should show up in the Settings - Actions page of the repository or organization (depending on the installation mode).

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 0.14.1 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 3.38 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.38 |
| <a name="provider_random"></a> [random](#provider\_random) | n/a |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_runner_binaries"></a> [runner\_binaries](#module\_runner\_binaries) | ./modules/runner-binaries-syncer | n/a |
| <a name="module_runners"></a> [runners](#module\_runners) | ./modules/runners | n/a |
| <a name="module_ssm"></a> [ssm](#module\_ssm) | ./modules/ssm | n/a |
| <a name="module_webhook"></a> [webhook](#module\_webhook) | ./modules/webhook | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_resourcegroups_group.resourcegroups_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/resourcegroups_group) | resource |
| [aws_sqs_queue.queued_builds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [random_string.random](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ami_filter"></a> [ami\_filter](#input\_ami\_filter) | List of maps used to create the AMI filter for the action runner AMI. By default amazon linux 2 is used. | `map(list(string))` | `{}` | no |
| <a name="input_ami_owners"></a> [ami\_owners](#input\_ami\_owners) | The list of owners used to select the AMI of action runner instances. | `list(string)` | <pre>[<br>  "amazon"<br>]</pre> | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region. | `string` | n/a | yes |
| <a name="input_block_device_mappings"></a> [block\_device\_mappings](#input\_block\_device\_mappings) | The EC2 instance block device configuration. Takes the following keys: `device_name`, `delete_on_termination`, `volume_type`, `volume_size`, `encrypted`, `iops` | `map(string)` | `{}` | no |
| <a name="input_cloudwatch_config"></a> [cloudwatch\_config](#input\_cloudwatch\_config) | (optional) Replaces the module default cloudwatch log config. See https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html for details. | `string` | `null` | no |
| <a name="input_create_service_linked_role_spot"></a> [create\_service\_linked\_role\_spot](#input\_create\_service\_linked\_role\_spot) | (optional) create the serviced linked role for spot instances that is required by the scale-up lambda. | `bool` | `false` | no |
| <a name="input_delay_webhook_event"></a> [delay\_webhook\_event](#input\_delay\_webhook\_event) | The number of seconds the event accepted by the webhook is invisible on the queue before the scale up lambda will receive the event. | `number` | `30` | no |
| <a name="input_disable_check_wokflow_job_labels"></a> [disable\_check\_wokflow\_job\_labels](#input\_disable\_check\_wokflow\_job\_labels) | Disable the the check of workflow labels for received workflow job events. | `bool` | `false` | no |
| <a name="input_enable_cloudwatch_agent"></a> [enable\_cloudwatch\_agent](#input\_enable\_cloudwatch\_agent) | Enabling the cloudwatch agent on the ec2 runner instances, the runner contains default config. Configuration can be overridden via `cloudwatch_config`. | `bool` | `true` | no |
| <a name="input_enable_organization_runners"></a> [enable\_organization\_runners](#input\_enable\_organization\_runners) | Register runners to organization, instead of repo level | `bool` | `false` | no |
| <a name="input_enable_ssm_on_runners"></a> [enable\_ssm\_on\_runners](#input\_enable\_ssm\_on\_runners) | Enable to allow access the runner instances for debugging purposes via SSM. Note that this adds additional permissions to the runner instances. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | A name that identifies the environment, used as prefix and for tagging. | `string` | n/a | yes |
| <a name="input_ghes_ssl_verify"></a> [ghes\_ssl\_verify](#input\_ghes\_ssl\_verify) | GitHub Enterprise SSL verification. Set to 'false' when custom certificate (chains) is used for GitHub Enterprise Server (insecure). | `bool` | `true` | no |
| <a name="input_ghes_url"></a> [ghes\_url](#input\_ghes\_url) | GitHub Enterprise Server URL. Example: https://github.internal.co - DO NOT SET IF USING PUBLIC GITHUB | `string` | `null` | no |
| <a name="input_github_app"></a> [github\_app](#input\_github\_app) | GitHub app parameters, see your github app. Ensure the key is the base64-encoded `.pem` file (the output of `base64 app.private-key.pem`, not the content of `private-key.pem`). | <pre>object({<br>    key_base64     = string<br>    id             = string<br>    webhook_secret = string<br>  })</pre> | n/a | yes |
| <a name="input_idle_config"></a> [idle\_config](#input\_idle\_config) | List of time period that can be defined as cron expression to keep a minimum amount of runners active instead of scaling down to 0. By defining this list you can ensure that in time periods that match the cron expression within 5 seconds a runner is kept idle. | <pre>list(object({<br>    cron      = string<br>    timeZone  = string<br>    idleCount = number<br>  }))</pre> | `[]` | no |
| <a name="input_instance_profile_path"></a> [instance\_profile\_path](#input\_instance\_profile\_path) | The path that will be added to the instance\_profile, if not set the environment name will be used. | `string` | `null` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | [DEPRECATED] See instance\_types. | `string` | `"m5.large"` | no |
| <a name="input_instance_types"></a> [instance\_types](#input\_instance\_types) | List of instance types for the action runner. | `list(string)` | `null` | no |
| <a name="input_job_queue_retention_in_seconds"></a> [job\_queue\_retention\_in\_seconds](#input\_job\_queue\_retention\_in\_seconds) | The number of seconds the job is held in the queue before it is purged | `number` | `86400` | no |
| <a name="input_key_name"></a> [key\_name](#input\_key\_name) | Key pair name | `string` | `null` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | Optional CMK Key ARN to be used for Parameter Store. This key must be in the current account. | `string` | `null` | no |
| <a name="input_lambda_s3_bucket"></a> [lambda\_s3\_bucket](#input\_lambda\_s3\_bucket) | S3 bucket from which to specify lambda functions. This is an alternative to providing local files directly. | `any` | `null` | no |
| <a name="input_lambda_security_group_ids"></a> [lambda\_security\_group\_ids](#input\_lambda\_security\_group\_ids) | List of security group IDs associated with the Lambda function. | `list(string)` | `[]` | no |
| <a name="input_lambda_subnet_ids"></a> [lambda\_subnet\_ids](#input\_lambda\_subnet\_ids) | List of subnets in which the action runners will be launched, the subnets needs to be subnets in the `vpc_id`. | `list(string)` | `[]` | no |
| <a name="input_log_level"></a> [log\_level](#input\_log\_level) | Logging level for lambda logging. Valid values are  'silly', 'trace', 'debug', 'info', 'warn', 'error', 'fatal'. | `string` | `"info"` | no |
| <a name="input_log_type"></a> [log\_type](#input\_log\_type) | Logging format for lambda logging. Valid values are 'json', 'pretty', 'hidden'. | `string` | `"pretty"` | no |
| <a name="input_logging_retention_in_days"></a> [logging\_retention\_in\_days](#input\_logging\_retention\_in\_days) | Specifies the number of days you want to retain log events for the lambda log group. Possible values are: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, and 3653. | `number` | `180` | no |
| <a name="input_market_options"></a> [market\_options](#input\_market\_options) | Market options for the action runner instances. Setting the value to `null` let the scaler create on-demand instances instead of spot instances. | `string` | `"spot"` | no |
| <a name="input_minimum_running_time_in_minutes"></a> [minimum\_running\_time\_in\_minutes](#input\_minimum\_running\_time\_in\_minutes) | The time an ec2 action runner should be running at minimum before terminated if not busy. | `number` | `5` | no |
| <a name="input_repository_white_list"></a> [repository\_white\_list](#input\_repository\_white\_list) | List of repositories allowed to use the github app | `list(string)` | `[]` | no |
| <a name="input_role_path"></a> [role\_path](#input\_role\_path) | The path that will be added to role path for created roles, if not set the environment name will be used. | `string` | `null` | no |
| <a name="input_role_permissions_boundary"></a> [role\_permissions\_boundary](#input\_role\_permissions\_boundary) | Permissions boundary that will be added to the created roles. | `string` | `null` | no |
| <a name="input_runner_additional_security_group_ids"></a> [runner\_additional\_security\_group\_ids](#input\_runner\_additional\_security\_group\_ids) | (optional) List of additional security groups IDs to apply to the runner | `list(string)` | `[]` | no |
| <a name="input_runner_allow_prerelease_binaries"></a> [runner\_allow\_prerelease\_binaries](#input\_runner\_allow\_prerelease\_binaries) | Allow the runners to update to prerelease binaries. | `bool` | `false` | no |
| <a name="input_runner_as_root"></a> [runner\_as\_root](#input\_runner\_as\_root) | Run the action runner under the root user. | `bool` | `false` | no |
| <a name="input_runner_binaries_s3_sse_configuration"></a> [runner\_binaries\_s3\_sse\_configuration](#input\_runner\_binaries\_s3\_sse\_configuration) | Map containing server-side encryption configuration for runner-binaries S3 bucket. | `any` | `{}` | no |
| <a name="input_runner_binaries_syncer_lambda_timeout"></a> [runner\_binaries\_syncer\_lambda\_timeout](#input\_runner\_binaries\_syncer\_lambda\_timeout) | Time out of the binaries sync lambda in seconds. | `number` | `300` | no |
| <a name="input_runner_binaries_syncer_lambda_zip"></a> [runner\_binaries\_syncer\_lambda\_zip](#input\_runner\_binaries\_syncer\_lambda\_zip) | File location of the binaries sync lambda zip file. | `string` | `null` | no |
| <a name="input_runner_boot_time_in_minutes"></a> [runner\_boot\_time\_in\_minutes](#input\_runner\_boot\_time\_in\_minutes) | The minimum time for an EC2 runner to boot and register as a runner. | `number` | `5` | no |
| <a name="input_runner_ec2_tags"></a> [runner\_ec2\_tags](#input\_runner\_ec2\_tags) | Map of tags that will be added to the launch template instance tag specificatons. | `map(string)` | `{}` | no |
| <a name="input_runner_egress_rules"></a> [runner\_egress\_rules](#input\_runner\_egress\_rules) | List of egress rules for the GitHub runner instances. | <pre>list(object({<br>    cidr_blocks      = list(string)<br>    ipv6_cidr_blocks = list(string)<br>    prefix_list_ids  = list(string)<br>    from_port        = number<br>    protocol         = string<br>    security_groups  = list(string)<br>    self             = bool<br>    to_port          = number<br>    description      = string<br>  }))</pre> | <pre>[<br>  {<br>    "cidr_blocks": [<br>      "0.0.0.0/0"<br>    ],<br>    "description": null,<br>    "from_port": 0,<br>    "ipv6_cidr_blocks": [<br>      "::/0"<br>    ],<br>    "prefix_list_ids": null,<br>    "protocol": "-1",<br>    "security_groups": null,<br>    "self": null,<br>    "to_port": 0<br>  }<br>]</pre> | no |
| <a name="input_runner_extra_labels"></a> [runner\_extra\_labels](#input\_runner\_extra\_labels) | Extra labels for the runners (GitHub). Separate each label by a comma | `string` | `""` | no |
| <a name="input_runner_group_name"></a> [runner\_group\_name](#input\_runner\_group\_name) | Name of the runner group. | `string` | `"Default"` | no |
| <a name="input_runner_iam_role_managed_policy_arns"></a> [runner\_iam\_role\_managed\_policy\_arns](#input\_runner\_iam\_role\_managed\_policy\_arns) | Attach AWS or customer-managed IAM policies (by ARN) to the runner IAM role | `list(string)` | `[]` | no |
| <a name="input_runner_log_files"></a> [runner\_log\_files](#input\_runner\_log\_files) | (optional) Replaces the module default cloudwatch log config. See https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html for details. | <pre>list(object({<br>    log_group_name   = string<br>    prefix_log_group = bool<br>    file_path        = string<br>    log_stream_name  = string<br>  }))</pre> | <pre>[<br>  {<br>    "file_path": "/var/log/messages",<br>    "log_group_name": "messages",<br>    "log_stream_name": "{instance_id}",<br>    "prefix_log_group": true<br>  },<br>  {<br>    "file_path": "/var/log/user-data.log",<br>    "log_group_name": "user_data",<br>    "log_stream_name": "{instance_id}",<br>    "prefix_log_group": true<br>  },<br>  {<br>    "file_path": "/home/ec2-user/actions-runner/_diag/Runner_**.log",<br>    "log_group_name": "runner",<br>    "log_stream_name": "{instance_id}",<br>    "prefix_log_group": true<br>  }<br>]</pre> | no |
| <a name="input_runner_metadata_options"></a> [runner\_metadata\_options](#input\_runner\_metadata\_options) | Metadata options for the ec2 runner instances. | `map(any)` | <pre>{<br>  "http_endpoint": "enabled",<br>  "http_put_response_hop_limit": 1,<br>  "http_tokens": "optional"<br>}</pre> | no |
| <a name="input_runners_lambda_s3_key"></a> [runners\_lambda\_s3\_key](#input\_runners\_lambda\_s3\_key) | S3 key for runners lambda function. Required if using S3 bucket to specify lambdas. | `any` | `null` | no |
| <a name="input_runners_lambda_s3_object_version"></a> [runners\_lambda\_s3\_object\_version](#input\_runners\_lambda\_s3\_object\_version) | S3 object version for runners lambda function. Useful if S3 versioning is enabled on source bucket. | `any` | `null` | no |
| <a name="input_runners_lambda_zip"></a> [runners\_lambda\_zip](#input\_runners\_lambda\_zip) | File location of the lambda zip file for scaling runners. | `string` | `null` | no |
| <a name="input_runners_maximum_count"></a> [runners\_maximum\_count](#input\_runners\_maximum\_count) | The maximum number of runners that will be created. | `number` | `3` | no |
| <a name="input_runners_scale_down_lambda_timeout"></a> [runners\_scale\_down\_lambda\_timeout](#input\_runners\_scale\_down\_lambda\_timeout) | Time out for the scale down lambda in seconds. | `number` | `60` | no |
| <a name="input_runners_scale_up_lambda_timeout"></a> [runners\_scale\_up\_lambda\_timeout](#input\_runners\_scale\_up\_lambda\_timeout) | Time out for the scale up lambda in seconds. | `number` | `180` | no |
| <a name="input_scale_down_schedule_expression"></a> [scale\_down\_schedule\_expression](#input\_scale\_down\_schedule\_expression) | Scheduler expression to check every x for scale down. | `string` | `"cron(*/5 * * * ? *)"` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | List of subnets in which the action runners will be launched, the subnets needs to be subnets in the `vpc_id`. | `list(string)` | n/a | yes |
| <a name="input_syncer_lambda_s3_key"></a> [syncer\_lambda\_s3\_key](#input\_syncer\_lambda\_s3\_key) | S3 key for syncer lambda function. Required if using S3 bucket to specify lambdas. | `any` | `null` | no |
| <a name="input_syncer_lambda_s3_object_version"></a> [syncer\_lambda\_s3\_object\_version](#input\_syncer\_lambda\_s3\_object\_version) | S3 object version for syncer lambda function. Useful if S3 versioning is enabled on source bucket. | `any` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Map of tags that will be added to created resources. By default resources will be tagged with name and environment. | `map(string)` | `{}` | no |
| <a name="input_userdata_post_install"></a> [userdata\_post\_install](#input\_userdata\_post\_install) | Script to be ran after the GitHub Actions runner is installed on the EC2 instances | `string` | `""` | no |
| <a name="input_userdata_pre_install"></a> [userdata\_pre\_install](#input\_userdata\_pre\_install) | Script to be ran before the GitHub Actions runner is installed on the EC2 instances | `string` | `""` | no |
| <a name="input_userdata_template"></a> [userdata\_template](#input\_userdata\_template) | Alternative user-data template, replacing the default template. By providing your own user\_data you have to take care of installing all required software, including the action runner. Variables userdata\_pre/post\_install are ignored. | `string` | `null` | no |
| <a name="input_volume_size"></a> [volume\_size](#input\_volume\_size) | Size of runner volume | `number` | `30` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | The VPC for security groups of the action runners. | `string` | n/a | yes |
| <a name="input_webhook_lambda_s3_key"></a> [webhook\_lambda\_s3\_key](#input\_webhook\_lambda\_s3\_key) | S3 key for webhook lambda function. Required if using S3 bucket to specify lambdas. | `any` | `null` | no |
| <a name="input_webhook_lambda_s3_object_version"></a> [webhook\_lambda\_s3\_object\_version](#input\_webhook\_lambda\_s3\_object\_version) | S3 object version for webhook lambda function. Useful if S3 versioning is enabled on source bucket. | `any` | `null` | no |
| <a name="input_webhook_lambda_timeout"></a> [webhook\_lambda\_timeout](#input\_webhook\_lambda\_timeout) | Time out of the webhook lambda in seconds. | `number` | `10` | no |
| <a name="input_webhook_lambda_zip"></a> [webhook\_lambda\_zip](#input\_webhook\_lambda\_zip) | File location of the webhook lambda zip file. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_binaries_syncer"></a> [binaries\_syncer](#output\_binaries\_syncer) | n/a |
| <a name="output_runners"></a> [runners](#output\_runners) | n/a |
| <a name="output_ssm_parameters"></a> [ssm\_parameters](#output\_ssm\_parameters) | n/a |
| <a name="output_webhook"></a> [webhook](#output\_webhook) | n/a |
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->

## Contribution

We welcome contribution, please checkout the [contribution guide](CONTRIBUTING.md). Be-aware we use [pre commit hooks](https://pre-commit.com/) to update the docs.

## Philips Forest

This module is part of the Philips Forest.

```bash

                                                     ___                   _
                                                    / __\__  _ __ ___  ___| |_
                                                   / _\/ _ \| '__/ _ \/ __| __|
                                                  / / | (_) | | |  __/\__ \ |_
                                                  \/   \___/|_|  \___||___/\__|

                                                                 Infrastructure

```

Talk to the forestkeepers in the `forest`-channel on Slack.

[![Slack](https://img.shields.io/badge/Slack-4A154B?style=for-the-badge&logo=slack&logoColor=white)](https://join.slack.com/t/philips-software/shared_invite/zt-xecw65v5-i1531hGP~mdVwgxLFx7ckg)
