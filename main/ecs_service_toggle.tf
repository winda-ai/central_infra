data "archive_file" "ecs_service_toggle_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/ecs_service_toggle.py"
  output_path = "${path.module}/lambda/ecs_service_toggle.zip"
}

data "aws_iam_policy_document" "ecs_service_toggle_lambda_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ecs_service_toggle_lambda" {
  name               = "${local.name_prefix}-ecs-service-toggle-lambda"
  assume_role_policy = data.aws_iam_policy_document.ecs_service_toggle_lambda_assume.json
  tags               = local.common_tags
}

resource "aws_cloudwatch_log_group" "ecs_service_toggle_lambda" {
  name              = "/aws/lambda/${local.name_prefix}-ecs-service-toggle"
  retention_in_days = 7
  tags              = local.common_tags
}

data "aws_iam_policy_document" "ecs_service_toggle_lambda_policy" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["${aws_cloudwatch_log_group.ecs_service_toggle_lambda.arn}:*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ecs:DescribeClusters",
      "ecs:ListServices",
      "ecs:DescribeServices",
      "ecs:UpdateService"
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "application-autoscaling:DescribeScalableTargets",
      "application-autoscaling:RegisterScalableTarget"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_service_toggle_lambda" {
  name   = "${local.name_prefix}-ecs-service-toggle-lambda"
  policy = data.aws_iam_policy_document.ecs_service_toggle_lambda_policy.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_service_toggle_lambda" {
  role       = aws_iam_role.ecs_service_toggle_lambda.name
  policy_arn = aws_iam_policy.ecs_service_toggle_lambda.arn
}

resource "aws_lambda_function" "ecs_service_toggle" {
  function_name = "${local.name_prefix}-ecs-service-toggle"
  role          = aws_iam_role.ecs_service_toggle_lambda.arn
  handler       = "ecs_service_toggle.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.ecs_service_toggle_lambda.output_path
  source_code_hash = data.archive_file.ecs_service_toggle_lambda.output_base64sha256

  timeout     = 120
  memory_size = 256

  depends_on = [aws_cloudwatch_log_group.ecs_service_toggle_lambda]

  tags = local.common_tags
}

# ------------------------------------------------------------
# Step Functions state machine (input: {"action":"on"|"off"})
# ------------------------------------------------------------

data "aws_iam_policy_document" "ecs_service_toggle_sfn_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ecs_service_toggle_sfn" {
  name               = "${local.name_prefix}-ecs-service-toggle-sfn"
  assume_role_policy = data.aws_iam_policy_document.ecs_service_toggle_sfn_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "ecs_service_toggle_sfn_policy" {
  statement {
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = [
      aws_lambda_function.ecs_service_toggle.arn,
      "${aws_lambda_function.ecs_service_toggle.arn}:*"
    ]
  }
}

resource "aws_iam_policy" "ecs_service_toggle_sfn" {
  name   = "${local.name_prefix}-ecs-service-toggle-sfn"
  policy = data.aws_iam_policy_document.ecs_service_toggle_sfn_policy.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_service_toggle_sfn" {
  role       = aws_iam_role.ecs_service_toggle_sfn.name
  policy_arn = aws_iam_policy.ecs_service_toggle_sfn.arn
}

resource "aws_sfn_state_machine" "ecs_service_toggle" {
  name     = "${local.name_prefix}-ecs-service-toggle"
  role_arn = aws_iam_role.ecs_service_toggle_sfn.arn

  definition = jsonencode({
    Comment = "Toggle all ECS services in the cluster on/off"
    StartAt = "ValidateInput"
    States = {
      ValidateInput = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.action"
            StringEquals = "on"
            Next         = "ToggleServices"
          },
          {
            Variable     = "$.action"
            StringEquals = "off"
            Next         = "ToggleServices"
          }
        ]
        Default = "InvalidAction"
      }
      InvalidAction = {
        Type  = "Fail"
        Error = "InvalidAction"
        Cause = "action must be 'on' or 'off'"
      }
      ToggleServices = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.ecs_service_toggle.arn
          Payload = {
            "action.$"  = "$.action"
            "input.$"   = "$"
            cluster_arn = aws_ecs_cluster.this.arn
          }
        }
        OutputPath = "$.Payload"
        End        = true
      }
    }
  })

  tags = local.common_tags
}

output "ecs_service_toggle_state_machine_arn" {
  value       = aws_sfn_state_machine.ecs_service_toggle.arn
  description = "Step Functions state machine ARN to turn all ECS services on/off (input: {action:on|off})"
}
