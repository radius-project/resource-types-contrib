## Overview

This directory contains the Resource Type definition and Recipes for Redis, a popular in-memory data structure store used as a cache or database.

## Resource Type Schema Definition

The Resource Type schema for Redis is defined in the `redis.yaml` file. 

Input properties include:
- Environment: The Radius environment ID to which the resource belongs to.
- Application: The Radius application ID to which the resource belongs to.
- Capacity: The size of the Redis cache.

Output properties include:
- Hostname: The hostname of the Redis cache.
- Port: The port number of the Redis cache.
- Username: The username for accessing the Redis cache.
- Password: The password for accessing the Redis cache.
- Connection String: The connection string for connecting to the Redis cache.

## Recipes

Below is a summary of the available Recipes for the Redis Resource Type, categorized by platform and Infrastructure as Code (IaC) language. 

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes.bicep | Alpha |
| Kubernetes | Terraform | kubernetes/main.tf | Alpha |