# Classic Amazon Bedrock (InvokeModel / bedrock-runtime) for Claude Code in boundary tasks.
#
# Haiku 4.5 does not support on-demand InvokeModel with the foundation-model ID alone; AWS
# requires an inference profile. We create an *application* inference profile whose source is
# the in-region foundation model ARN only (not a us./eu. system cross-region profile).

locals {
  claude_haiku_foundation_model_id  = var.claude_bedrock_foundation_model_id
  claude_haiku_foundation_model_arn = "arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/${local.claude_haiku_foundation_model_id}"
}

resource "aws_bedrock_inference_profile" "claude_haiku" {
  name = "${var.cluster_id}-claude-haiku"

  model_source {
    copy_from = local.claude_haiku_foundation_model_arn
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-claude-haiku-inference-profile"
  })
}

locals {
  claude_bedrock_invoke_model_id = aws_bedrock_inference_profile.claude_haiku.id
}
