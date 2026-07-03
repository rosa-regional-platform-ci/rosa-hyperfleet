# =============================================================================
# RDS FleetStore Module
#
# Provisions an RDS PostgreSQL instance for the FleetStore CR store, replacing
# the fleet-db workerless EKS cluster. Multi-AZ with synchronous replication,
# gp3 storage, KMS encryption at rest, and automated backups with PITR.
# =============================================================================

data "aws_caller_identity" "current" {}

# =============================================================================
# Networking
# =============================================================================

resource "aws_db_subnet_group" "fleetstore" {
  name        = "${var.cluster_id}-fleetstore"
  description = "FleetStore RDS subnet group"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name = "${var.cluster_id}-fleetstore"
  }
}

resource "aws_security_group" "fleetstore" {
  name        = "${var.cluster_id}-fleetstore-rds"
  description = "Allow PostgreSQL access from VPC to FleetStore RDS"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_id}-fleetstore-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "fleetstore_postgres" {
  security_group_id = aws_security_group.fleetstore.id
  description       = "Allow PostgreSQL from VPC"
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# =============================================================================
# KMS Key for RDS Encryption at Rest
# =============================================================================

resource "aws_kms_key" "fleetstore" {
  description             = "KMS key for FleetStore RDS encryption at rest"
  deletion_window_in_days = 7
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
        Sid    = "AllowRDSServiceAccess"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:ListGrants"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "rds.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.cluster_id}-fleetstore-rds"
  }
}

resource "aws_kms_alias" "fleetstore" {
  name          = "alias/${var.cluster_id}-fleetstore-rds"
  target_key_id = aws_kms_key.fleetstore.key_id
}

data "aws_region" "current" {}

# =============================================================================
# RDS Parameter Group
# =============================================================================

resource "aws_db_parameter_group" "fleetstore" {
  name        = "${var.cluster_id}-fleetstore-pg16"
  family      = "postgres16"
  description = "FleetStore PostgreSQL 16 parameters"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.cluster_id}-fleetstore-pg16"
  }
}

# =============================================================================
# IAM Role for Enhanced Monitoring
# =============================================================================

resource "aws_iam_role" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name = "${var.cluster_id}-fleetstore-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.cluster_id}-fleetstore-rds-monitoring"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# =============================================================================
# Master Password (Secrets Manager)
# =============================================================================

resource "aws_secretsmanager_secret" "fleetstore_master" {
  name                    = "${var.cluster_id}-fleetstore-master-password"
  description             = "FleetStore RDS master password"
  kms_key_id              = aws_kms_key.fleetstore.arn
  recovery_window_in_days = 7

  tags = {
    Name = "${var.cluster_id}-fleetstore-master-password"
  }
}

resource "random_password" "fleetstore_master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret_version" "fleetstore_master" {
  secret_id     = aws_secretsmanager_secret.fleetstore_master.id
  secret_string = random_password.fleetstore_master.result
}

# =============================================================================
# RDS Instance
# =============================================================================

resource "aws_db_instance" "fleetstore" {
  identifier = "${var.cluster_id}-fleetstore"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.database_name
  username = "fleetstore"
  password = random_password.fleetstore_master.result

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.fleetstore.arn

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.fleetstore.name
  vpc_security_group_ids = [aws_security_group.fleetstore.id]
  publicly_accessible    = false

  parameter_group_name = aws_db_parameter_group.fleetstore.name

  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"
  copy_tags_to_snapshot   = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.cluster_id}-fleetstore-final"

  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_enabled ? aws_kms_key.fleetstore.arn : null

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null

  auto_minor_version_upgrade = true

  tags = {
    Name      = "${var.cluster_id}-fleetstore"
    Component = "fleetstore"
    ManagedBy = "terraform"
  }
}

# =============================================================================
# DSN Secret (Secrets Manager)
#
# Stores the full connection string for consumption by External Secrets
# Operator. The operator and platform-api pods read this via the
# fleetstore-dsn Kubernetes Secret.
# =============================================================================

resource "aws_secretsmanager_secret" "fleetstore_dsn" {
  name                    = "${var.cluster_id}-fleetstore-dsn"
  description             = "FleetStore PostgreSQL DSN for operator and platform-api"
  kms_key_id              = aws_kms_key.fleetstore.arn
  recovery_window_in_days = 7

  tags = {
    Name      = "${var.cluster_id}-fleetstore-dsn"
    Component = "fleetstore"
    ManagedBy = "terraform"
  }
}

resource "aws_secretsmanager_secret_version" "fleetstore_dsn" {
  secret_id = aws_secretsmanager_secret.fleetstore_dsn.id
  secret_string = join("", [
    "postgres://",
    aws_db_instance.fleetstore.username,
    ":",
    random_password.fleetstore_master.result,
    "@",
    aws_db_instance.fleetstore.endpoint,
    "/",
    aws_db_instance.fleetstore.db_name,
    "?sslmode=require",
  ])
}
