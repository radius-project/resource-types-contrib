# Run with Terraform 1.11.4, including plan-time mock support.
# These plans use synthetic inputs and never contact AWS.
mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.0.0.0/16"
    }
  }

  # Supply only computed identifiers, leaving the recipe parameters intact.
  # A known name lets the JSON checker verify the instance's group attachment.
  mock_resource "aws_db_parameter_group" {
    override_during = plan
    defaults = {
      name = "mysql-tls-test-parameters"
      id   = "mysql-tls-test-parameters"
    }
  }
}

mock_provider "random" {}

variables {
  vpcId     = "vpc-00000000000000000"
  subnetIds = "[\"subnet-00000000000000000\", \"subnet-11111111111111111\"]"
  context = {
    application = { name = "tls-test" }
    environment = { name = "tls-test" }
    resource = {
      name = "mysql-tls-test"
      properties = {
        database = "tls_test"
        username = "testuser"
        password = "synthetic-test-password"
        version  = "8.0"
      }
    }
  }
}

run "omitted" {
  command = plan
}

run "required" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = "required" })
      })
    })
  }
}

run "optional" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = "optional" })
      })
    })
  }
}

run "null_policy" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = null })
      })
    })
  }
}
