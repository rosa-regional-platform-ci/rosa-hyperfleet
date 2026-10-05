# ZOA Access Lambda execution role (RC only)

Single Terraform owner for the IAM role the ZOA Access Lambda runs as. The role is created **before** `zoa-boundary` and `zoa-access` in the regional stack so boundary `AssumeRole` trust policies reference a real principal in one `terraform apply`.

- **`zoa-access-role`** — role shell (this module)
- **`zoa-access`** — Lambda function + inline policies on that role
- **`zoa-boundary`** — trusts this role ARN for `boundary-access` / exec-scoped roles

On destroy, `zoa-access` removes policies and the function first; this role is removed last via the dependency graph.

MC stacks receive `arn` via RC Terraform outputs (`zoa_access_lambda_role_arn`) for MC boundary trust — they do not instantiate this module.
