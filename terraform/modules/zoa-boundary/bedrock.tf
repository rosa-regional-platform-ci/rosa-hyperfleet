# Classic Amazon Bedrock (InvokeModel / bedrock-runtime) for Claude Code in boundary tasks.
#
# Haiku 4.5 cannot be invoked with the foundation-model ID alone, and AWS rejects
# application inference profiles whose source is only the in-region foundation model
# ("does not support On Demand inference"). Use a Bedrock system inference profile ID
# (default: US Haiku 4.5 profile in the deployment region).

data "aws_bedrock_inference_profile" "claude_haiku" {
  inference_profile_id = var.claude_bedrock_inference_profile_id
}

locals {
  claude_bedrock_invoke_model_id = data.aws_bedrock_inference_profile.claude_haiku.inference_profile_id
}
