terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

//////////////////////////////////////////
// Common Radius variables
//////////////////////////////////////////

variable "context" {
  description = "This variable contains Radius Recipe context."
  type        = any
}

variable "eksClusterName" {
  description = "Name of the EKS cluster. Used to discover VPC, subnets, and security groups."
  type        = string
}

locals {
  resource_name    = var.context.resource.name
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
}

//////////////////////////////////////////
// MySQL variables
//////////////////////////////////////////

locals {
  port        = 3306
  database    = try(var.context.resource.properties.database, "mysql_db")
  secret_name = var.context.resource.properties.secretName
  version     = try(var.context.resource.properties.version, "8.4")

  unique_suffix = substr(md5("${local.resource_name}-${var.eksClusterName}"), 0, 13)

  # RDS identifier must be lowercase alphanumeric and hyphens, max 63 chars
  sanitized_identifier = "rds-dbinstance-${local.unique_suffix}"

  # Database name must be alphanumeric and underscores
  sanitized_database = replace(local.database, "/[^a-zA-Z0-9_]/", "_")

  tags = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/application" = local.application_name
    "radapp.io/environment" = local.environment_name
  }
}

//////////////////////////////////////////
// EKS cluster networking
//////////////////////////////////////////

data "aws_eks_cluster" "cluster" {
  name = var.eksClusterName
}

//////////////////////////////////////////
// Credentials
//////////////////////////////////////////

# Read credentials from the Kubernetes secret provided by the developer
data "kubernetes_secret" "db_credentials" {
  metadata {
    name      = local.secret_name
    namespace = local.namespace
  }
}

//////////////////////////////////////////
// RDS Deployment
//////////////////////////////////////////

resource "aws_db_subnet_group" "mysql" {
  name        = "rds-dbsubnetgroup-${local.unique_suffix}"
  description = "rds-dbsubnetgroup-${local.unique_suffix}"
  subnet_ids  = data.aws_eks_cluster.cluster.vpc_config[0].subnet_ids

  tags = local.tags
}

resource "aws_db_instance" "mysql" {
  identifier     = local.sanitized_identifier
  engine         = "mysql"
  engine_version = local.version
  instance_class = "db.t3.micro"

  db_name  = local.sanitized_database
  username = data.kubernetes_secret.db_credentials.data["USERNAME"]
  password = data.kubernetes_secret.db_credentials.data["PASSWORD"]
  port     = local.port

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id]
  publicly_accessible    = false

  backup_retention_period   = 1
  skip_final_snapshot       = true
  final_snapshot_identifier = "${local.sanitized_identifier}-final"

  tags = local.tags
}

//////////////////////////////////////////
// Output
//////////////////////////////////////////

output "result" {
  value = {
    resources = []
    values = {
      host     = aws_db_instance.mysql.address
      port     = aws_db_instance.mysql.port
      database = local.sanitized_database
    }
  }
}
