module "default_label" {
  source     = "git::https://github.com/cloudposse/terraform-terraform-label.git?ref=tags/0.5.0"
  namespace  = var.namespace
  stage      = var.stage
  name       = var.name
  attributes = var.attributes
}

locals {
  subscription_name = "${module.default_label.id}-pipeline-updates"
}

resource "aws_sns_topic" "pipeline_updates" {
  # tfsec:ignore:AWS016
  name = local.subscription_name
}

resource "aws_sns_topic_subscription" "pipeline_updates" {
  topic_arn = aws_sns_topic.pipeline_updates.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.pipeline_notification.arn
}

resource "aws_codestarnotifications_notification_rule" "pipeline_updates" {
  count          = length(var.codepipelines)
  detail_type    = "FULL"
  event_type_ids = var.event_type_ids
  name           = "slackNotification${var.codepipelines[count.index].name}"
  resource       = var.codepipelines[count.index].arn

  target {
    address = aws_sns_topic.pipeline_updates.arn
    type    = "SNS"
  }
}

resource "aws_sns_topic_policy" "pipeline_updates" {
  arn    = aws_sns_topic.pipeline_updates.arn
  policy = data.aws_iam_policy_document.pipeline_updates_policy.json
}

data "aws_iam_policy_document" "pipeline_updates_policy" {
  statement {
    sid    = "codestar-notification"
    effect = "Allow"
    resources = [
      aws_sns_topic.pipeline_updates.arn
    ]

    principals {
      identifiers = [
        "codestar-notifications.amazonaws.com"
      ]
      type = "Service"
    }
    actions = [
      "SNS:Publish"
    ]
  }
}

data "archive_file" "notifier_package" {
  type        = "zip"
  source_file = "${path.module}/lambdas/notifier/notifier.py"
  output_path = "${path.module}/lambdas/notifier.zip"
}

resource "aws_lambda_function" "pipeline_notification" {
  filename         = "${path.module}/lambdas/notifier.zip"
  function_name    = module.default_label.id
  role             = aws_iam_role.pipeline_notification.arn
  runtime          = "python3.8"
  source_code_hash = data.archive_file.notifier_package.output_base64sha256
  handler          = "notifier.handler"
  timeout          = 10

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_url
      SLACK_CHANNEL     = var.slack_channel
      SLACK_USERNAME    = var.slack_username
      SLACK_EMOJI       = var.slack_emoji
      ENVIRONMENT       = var.stage
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.pipeline_notification,
    data.archive_file.notifier_package,
  ]
}

resource "aws_lambda_permission" "pipeline_notification" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_notification.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.pipeline_updates.arn
}

resource "aws_iam_role" "pipeline_notification" {
  name = "${module.default_label.id}-pipeline-notification"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "pipeline_notification" {
  name        = "${module.default_label.id}-pipeline-notification"
  path        = "/"
  description = "IAM policy for the Slack notification lambda"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:*:*:*"
      ],
      "Effect": "Allow"
    },
    {
      "Action": [
        "codepipeline:GetPipelineExecution"
      ],
      "Resource": ${jsonencode(var.codepipelines.*.arn)},
      "Effect": "Allow"
    },
    {
      "Action": [
        "iam:PassRole"
      ],
      "Resource": [
        "${aws_iam_role.pipeline_notification.arn}"
      ],
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "pipeline_notification" {
  role       = aws_iam_role.pipeline_notification.name
  policy_arn = aws_iam_policy.pipeline_notification.arn
}
