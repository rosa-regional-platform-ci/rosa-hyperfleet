# State migration: module.zoa_boundary merged into module.zoa_lambda.

moved {
  from = module.zoa_boundary.aws_cloudwatch_log_group.boundary
  to   = module.zoa_lambda.aws_cloudwatch_log_group.boundary
}

moved {
  from = module.zoa_boundary.aws_cloudwatch_log_group.boundary_exec
  to   = module.zoa_lambda.aws_cloudwatch_log_group.boundary_exec
}

moved {
  from = module.zoa_boundary.aws_security_group.boundary
  to   = module.zoa_lambda.aws_security_group.boundary
}

moved {
  from = module.zoa_boundary.aws_security_group_rule.eks_ingress_from_boundary
  to   = module.zoa_lambda.aws_security_group_rule.eks_ingress_from_boundary
}

moved {
  from = module.zoa_boundary.aws_ecs_cluster.boundary
  to   = module.zoa_lambda.aws_ecs_cluster.boundary
}

moved {
  from = module.zoa_boundary.null_resource.stop_boundary_tasks
  to   = module.zoa_lambda.null_resource.stop_boundary_tasks
}

moved {
  from = module.zoa_boundary.aws_ecs_task_definition.boundary
  to   = module.zoa_lambda.aws_ecs_task_definition.boundary
}

moved {
  from = module.zoa_boundary.aws_iam_role.task
  to   = module.zoa_lambda.aws_iam_role.task
}

moved {
  from = module.zoa_boundary.aws_iam_role.execution
  to   = module.zoa_lambda.aws_iam_role.execution
}

moved {
  from = module.zoa_boundary.aws_iam_role.boundary_access
  to   = module.zoa_lambda.aws_iam_role.boundary_access
}

moved {
  from = module.zoa_boundary.aws_iam_role.exec_scoped
  to   = module.zoa_lambda.aws_iam_role.exec_scoped
}

moved {
  from = module.zoa_boundary.aws_lambda_permission.boundary_task_function_url
  to   = module.zoa_lambda.aws_lambda_permission.boundary_task_function_url
}

moved {
  from = module.zoa_boundary.aws_lambda_permission.boundary_task_invoke_function
  to   = module.zoa_lambda.aws_lambda_permission.boundary_task_invoke_function
}
