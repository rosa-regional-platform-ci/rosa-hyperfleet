# Boundary tasks call the per-VPC ZOA API Lambda Function URL (ZOA_API_URL) with the
# task role. Identity policy alone is not enough — Lambda requires resource-based
# InvokeFunctionUrl + InvokeFunction (InvokedViaFunctionUrl) permissions, same as
# zoa-access for the invoker role.

resource "aws_lambda_permission" "boundary_task_function_url" {
  statement_id           = "AllowBoundaryTaskRole-${replace(var.cluster_id, "-", "")}"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = var.zoa_lambda_function_arn
  principal              = aws_iam_role.task.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "boundary_task_invoke_function" {
  statement_id             = "AllowBoundaryTaskRoleInvoke-${replace(var.cluster_id, "-", "")}"
  action                   = "lambda:InvokeFunction"
  function_name            = var.zoa_lambda_function_arn
  principal                = aws_iam_role.task.arn
  invoked_via_function_url = true
}
