output "ecs_cluster_name" {
  description = "Name of the ECS cluster for ZOA Boundary tasks"
  value       = aws_ecs_cluster.boundary.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster for ZOA Boundary tasks"
  value       = aws_ecs_cluster.boundary.arn
}

output "task_definition_arn" {
  description = "ARN of the ZOA Boundary task definition"
  value       = aws_ecs_task_definition.boundary.arn
}

output "task_definition_family" {
  description = "Family name of the ZOA Boundary task definition"
  value       = aws_ecs_task_definition.boundary.family
}

output "security_group_id" {
  description = "Security group ID for ZOA Boundary tasks"
  value       = aws_security_group.boundary.id
}

output "task_role_arn" {
  description = "ARN of the IAM role used by the boundary container"
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the IAM execution role for ECS"
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group for boundary container stdout (awslogs driver)"
  value       = aws_cloudwatch_log_group.boundary.name
}

output "log_group_arn" {
  description = "ARN of the boundary container CloudWatch log group"
  value       = aws_cloudwatch_log_group.boundary.arn
}

output "exec_log_group_name" {
  description = "CloudWatch log group for ECS Exec session transcripts (SSM interactive shell I/O)"
  value       = aws_cloudwatch_log_group.boundary_exec.name
}

output "exec_log_group_arn" {
  description = "ARN of the boundary ECS Exec session CloudWatch log group"
  value       = aws_cloudwatch_log_group.boundary_exec.arn
}

output "container_name" {
  description = "Name of the container in the task definition"
  value       = local.container_name
}

output "run_task_command" {
  description = "AWS CLI command to start a boundary task"
  value       = <<-EOT
    AWS_PAGER="" aws ecs run-task \
      --cluster ${aws_ecs_cluster.boundary.name} \
      --task-definition ${aws_ecs_task_definition.boundary.family} \
      --launch-type FARGATE \
      --enable-execute-command \
      --network-configuration 'awsvpcConfiguration={subnets=[${join(",", var.private_subnet_ids)}],securityGroups=[${aws_security_group.boundary.id}],assignPublicIp=DISABLED}'
  EOT
}

output "exec_scoped_role_arn" {
  description = "IAM role ARN vended on session join for per-task ECS Exec"
  value       = aws_iam_role.exec_scoped.arn
}

output "boundary_access_role_arn" {
  description = "IAM role ARN assumed by RC Access Lambda for cross-account RunTask/StopTask"
  value       = aws_iam_role.boundary_access.arn
}

output "ecs_exec_interactive_command" {
  description = "Interactive shell command for ecs:ExecuteCommand (also ZOA_ECS_EXEC_COMMAND on the task and Access Lambda env)"
  value       = var.ecs_exec_interactive_command
}

output "exec_command_template" {
  description = "AWS CLI command template to connect to a running boundary task (replace <TASK_ID>)"
  value       = <<-EOT
    aws ecs execute-command \
      --cluster ${aws_ecs_cluster.boundary.name} \
      --task <TASK_ID> \
      --container ${local.container_name} \
      --interactive \
      --command '${var.ecs_exec_interactive_command}'
  EOT
}
