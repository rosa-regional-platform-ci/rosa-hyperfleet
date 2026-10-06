# ECS Fargate infrastructure for bootstrapping the VPC CNI and ArgoCD on
# private EKS clusters.
# See docs/design/fully-private-eks-bootstrap.md for architecture.

locals {
  bootstrap_container_name = "bootstrap"
  log_retention_days       = 365

  common_tags = {
    function  = "cluster-infra"
    module    = "ecs-bootstrap"
    ManagedBy = "terraform"
  }
}

# Current AWS region information
data "aws_region" "current" {}

# ECS Cluster for bootstrap tasks
resource "aws_ecs_cluster" "bootstrap" {
  name = "${var.cluster_id}-bootstrap"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-bootstrap"
  })
}

# KMS key for CloudWatch log group encryption (FedRAMP AU-09)
resource "aws_kms_key" "bootstrap_logs" {
  description             = "KMS key for ECS bootstrap CloudWatch log group encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-bootstrap-logs"
  })
}

# CloudWatch Log Group for bootstrap tasks
resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/ecs/${var.cluster_id}/bootstrap"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.bootstrap_logs.arn

  depends_on = [aws_kms_key.bootstrap_logs]

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-bootstrap"
  })
}

# Idempotent task: installs/updates the VPC CNI and ArgoCD, the cluster secret,
# and the root Application.
resource "aws_ecs_task_definition" "bootstrap" {
  family                   = "${var.cluster_id}-bootstrap"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name  = local.bootstrap_container_name
      image = var.container_image

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== ArgoCD Bootstrap ==="
          echo "Tools: aws=$(aws --version 2>&1 | head -1), kubectl=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion'), helm=$(helm version --short), git=$(git --version)"

          # Clone the platform repo so bootstrap uses the same charts that
          # ArgoCD will manage, eliminating drift between bootstrap and
          # steady-state configuration.
          REPO_DIR=/tmp/repo
          echo "Cloning $REPOSITORY_URL @ $REPOSITORY_BRANCH..."
          git clone --depth 1 -b "$REPOSITORY_BRANCH" "$REPOSITORY_URL" "$REPO_DIR"
          echo "✓ Repository cloned"

          # Configure kubectl for EKS
          aws eks update-kubeconfig --name $CLUSTER_NAME

          # The CNI resources were seeded before the node group was created.
          # Wait for the DaemonSet now that nodes are available.
          source "$REPO_DIR/scripts/bootstrap-vpc-cni.sh"
          kubectl rollout status daemonset/aws-node -n kube-system --timeout=10m
          echo "✓ Self-managed AWS VPC CNI is ready"

          # Wait for essential addons on the bootstrap node group before
          # installing ArgoCD. Pod Identity agent must be active so that
          # workloads deployed by ArgoCD (LBC, EBS CSI) can authenticate.
          for ADDON in coredns metrics-server eks-pod-identity-agent; do
            echo "Waiting for $ADDON to be active..."
            aws eks wait addon-active \
              --cluster-name "$CLUSTER_NAME" \
              --addon-name "$ADDON" \
              --region "$AWS_REGION"
            echo "✓ $ADDON active"
          done

          if ! kubectl get deployment argocd-server -n argocd 2>/dev/null; then
            echo "Installing ArgoCD from repo chart..."

            # Create argocd namespace
            kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

            # Fetch chart dependencies (charts/ is gitignored)
            helm repo add argo https://argoproj.github.io/argo-helm
            helm dependency build "$REPO_DIR/argocd/config/shared/argocd"

            # tracking-id annotations let the self-managed ArgoCD app adopt these resources.
            # redisSecretInit creates the Redis auth secret (disabled in the self-managed app).
            helm upgrade --install argocd "$REPO_DIR/argocd/config/shared/argocd" \
              --namespace argocd \
              --set argo-cd.redisSecretInit.enabled=true \
              --set-string 'argo-cd.controller.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --set-string 'argo-cd.server.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --set-string 'argo-cd.repoServer.annotations.argocd\.argoproj\.io/tracking-id=argocd:argoproj.io/Application:argocd/argocd' \
              --wait --timeout=10m

            echo "✓ ArgoCD installation complete"

            # Wait for ArgoCD to be ready
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-repo-server -n argocd
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-applicationset-controller -n argocd

            echo "✓ ArgoCD is running and ready"
          else
            echo "✓ ArgoCD is already installed and running, skipping installation"
          fi

          echo "Creating/updating cluster identity secret with values:"
          echo "  ENVIRONMENT: $ENVIRONMENT"
          echo "  AWS_REGION: $AWS_REGION"
          echo "  REGION_DEPLOYMENT: $REGION_DEPLOYMENT"
          echo "  CLUSTER_NAME: $CLUSTER_NAME"
          echo "  CLUSTER_TYPE: $CLUSTER_TYPE"
          echo "  REPOSITORY_URL: $REPOSITORY_URL"
          echo "  REPOSITORY_BRANCH: $REPOSITORY_BRANCH"
          echo "  DNS_ZONE_OPERATOR_ROLE_ARN: $DNS_ZONE_OPERATOR_ROLE_ARN"
          echo "  OIDC_KEY_READER_ROLE_ARN: $OIDC_KEY_READER_ROLE_ARN"

          cat <<-SECRET_EOF | kubectl apply -f -
          apiVersion: v1
          kind: Secret
          metadata:
            name: local-cluster-identity
            namespace: argocd
            labels:
              argocd.argoproj.io/secret-type: cluster
              environment: "$ENVIRONMENT"
              region_deployment: "$REGION_DEPLOYMENT"
              aws_region: "$AWS_REGION"
              cluster_type: "$CLUSTER_TYPE"
              cluster_name: "$CLUSTER_NAME"
            annotations:
              git_repo: "$REPOSITORY_URL"
              git_revision: "$REPOSITORY_BRANCH"
              api_target_group_arn: "$API_TARGET_GROUP_ARN"
              dynamodb_prefix: "$CLUSTER_NAME"
              dynamodb_region: "$AWS_REGION"
              thanos_kms_key_arn: "$THANOS_KMS_KEY_ARN"
              thanos_target_group_arn: "$THANOS_TARGET_GROUP_ARN"
              thanos_query_target_group_arn: "$THANOS_QUERY_TARGET_GROUP_ARN"
              loki_kms_key_arn: "$LOKI_KMS_KEY_ARN"
              loki_distributor_target_group_arn: "$LOKI_DISTRIBUTOR_TARGET_GROUP_ARN"
              loki_query_frontend_target_group_arn: "$LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN"
              aws_account_id: "$AWS_ACCOUNT_ID"
              rc_aws_account_id: "$RC_AWS_ACCOUNT_ID"
              management_clusters: "$MANAGEMENT_CLUSTERS"
              rhobs_api_url: "$RHOBS_API_URL"
              dns_zone_operator_role_arn: "$DNS_ZONE_OPERATOR_ROLE_ARN"
              oidc_key_reader_role_arn: "$OIDC_KEY_READER_ROLE_ARN"
              oidc_bucket_name: "$OIDC_BUCKET_NAME"
              oidc_cloudfront_domain: "$OIDC_CLOUDFRONT_DOMAIN"
              sre_grafana_target_group_arn: "$SRE_GRAFANA_TARGET_GROUP_ARN"
              sre_argocd_target_group_arn: "$SRE_ARGOCD_TARGET_GROUP_ARN"
              sre_prometheus_target_group_arn: "$SRE_PROMETHEUS_TARGET_GROUP_ARN"
              sre_thanos_target_group_arn: "$SRE_THANOS_TARGET_GROUP_ARN"
              sre_alb_dns_name: "$SRE_ALB_DNS_NAME"
              sre_domain: "$SRE_DOMAIN"
              redis_endpoint: "$REDIS_ENDPOINT"
              vpc_id: "$VPC_ID"
              vpc_cni_image_registry: "$VPC_CNI_IMAGE_REGISTRY"
              cluster_endpoint: "$CLUSTER_ENDPOINT"
          type: Opaque
          stringData:
            name: in-cluster
            server: https://kubernetes.default.svc
            config: |
              {
                "tlsClientConfig": { "insecure": false }
              }
          SECRET_EOF

          echo "Creating/updating ArgoCD Root Application..."
          echo "  Repository URL: $REPOSITORY_URL"
          echo "  Target Revision: $REPOSITORY_BRANCH"
          echo "  Target Path: $REPOSITORY_PATH"
          
          cat <<-APP_EOF | kubectl apply -f -
          apiVersion: argoproj.io/v1alpha1
          kind: Application
          metadata:
            name: root
            namespace: argocd
          spec:
            destination:
              namespace: argocd
              server: https://kubernetes.default.svc
            project: default
            source:
              repoURL: $REPOSITORY_URL
              targetRevision: $REPOSITORY_BRANCH
              path: $REPOSITORY_PATH
            syncPolicy:
              automated:
                prune: false
                selfHeal: true
              syncOptions:
                - CreateNamespace=true
          APP_EOF

          echo "=== Bootstrap completed successfully ==="
        EOF
      ]

      essential = true

      environment = [
        {
          name  = "AWS_REGION"
          value = data.aws_region.current.region
        },
        {
          name  = "AWS_DEFAULT_REGION"
          value = data.aws_region.current.region
        },
        {
          name  = "THANOS_KMS_KEY_ARN"
          value = var.thanos_kms_key_arn
        },
        {
          name  = "LOKI_KMS_KEY_ARN"
          value = var.loki_kms_key_arn
        },
        {
          name  = "AWS_ACCOUNT_ID"
          value = data.aws_caller_identity.current.account_id
        },
        {
          name  = "MANAGEMENT_CLUSTERS"
          value = var.management_clusters
        },
        {
          name  = "RC_AWS_ACCOUNT_ID"
          value = var.rc_aws_account_id
        },
        {
          name  = "REDIS_ENDPOINT"
          value = var.redis_endpoint
        },
        {
          name  = "VPC_ID"
          value = var.vpc_id
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bootstrap.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-bootstrap"
  })
}

# Terraform-managed one-shot task used before the bootstrap node group exists.
# It applies the CNI resources and exits; aws-node becomes ready when nodes join.
resource "aws_ecs_task_definition" "cni_seed" {
  family                   = "${var.cluster_id}-cni-seed"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name  = "cni-seed"
      image = var.container_image

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail
          REPO_DIR=/tmp/repo
          git clone --depth 1 -b "$REPOSITORY_BRANCH" "$REPOSITORY_URL" "$REPO_DIR"
          aws eks update-kubeconfig --name "$CLUSTER_NAME"
          source "$REPO_DIR/scripts/bootstrap-vpc-cni.sh"
          kubectl get daemonset aws-node -n kube-system --request-timeout=30s
          echo "=== VPC CNI seed completed ==="
        EOF
      ]

      essential = true

      environment = [
        {
          name  = "AWS_REGION"
          value = data.aws_region.current.region
        },
        {
          name  = "AWS_DEFAULT_REGION"
          value = data.aws_region.current.region
        },
        {
          name  = "CLUSTER_NAME"
          value = var.eks_cluster_name
        },
        {
          name  = "REPOSITORY_URL"
          value = var.repository_url
        },
        {
          name  = "REPOSITORY_BRANCH"
          value = var.repository_branch
        },
        {
          name  = "VPC_ID"
          value = var.vpc_id
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bootstrap.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "cni-seed"
        }
      }
    }
  ])

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-cni-seed"
  })
}

resource "null_resource" "cni_seed" {
  triggers = {
    task_definition = aws_ecs_task_definition.cni_seed.arn
  }

  depends_on = [aws_eks_access_policy_association.bootstrap_cluster_admin]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      TASK_ARN=$(aws ecs run-task \
        --region ${data.aws_region.current.region} \
        --cluster ${aws_ecs_cluster.bootstrap.arn} \
        --task-definition ${aws_ecs_task_definition.cni_seed.arn} \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[${join(",", var.private_subnets)}],securityGroups=[${aws_security_group.bootstrap_task.id}],assignPublicIp=DISABLED}" \
        --query 'tasks[0].taskArn' \
        --output text)

      if [[ -z "$TASK_ARN" || "$TASK_ARN" == "None" ]]; then
        echo "ERROR: Failed to start the VPC CNI seed ECS task" >&2
        exit 1
      fi

      aws ecs wait tasks-stopped \
        --region ${data.aws_region.current.region} \
        --cluster ${aws_ecs_cluster.bootstrap.arn} \
        --tasks "$TASK_ARN"

      EXIT_CODE=$(aws ecs describe-tasks \
        --region ${data.aws_region.current.region} \
        --cluster ${aws_ecs_cluster.bootstrap.arn} \
        --tasks "$TASK_ARN" \
        --query 'tasks[0].containers[0].exitCode' \
        --output text)
      if [[ "$EXIT_CODE" != "0" ]]; then
        echo "ERROR: VPC CNI seed ECS task failed with exit code $EXIT_CODE" >&2
        exit 1
      fi
    EOT
  }
}
