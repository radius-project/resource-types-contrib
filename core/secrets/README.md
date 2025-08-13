## Overview
The Radius.Security/secrets resource type models secrets used by applications: generic key/value pairs, TLS certificates/keys, basic auth credentials, container registry (docker config), SSH keys, certificate bundles, AWS IRSA (IAM Roles for Service Accounts), and Azure Workload Identity. It supports embedding literal (inline) values or referencing provider-managed secrets (external).

## Resource Type Schema Definition
Top-level properties (apiVersion 2023-10-01-preview):
- environment (string, required): Resource ID of the target environment.
- application (string, required): Resource ID of the owning application.
- kind (string, required): Logical secret kind. One of: generic, tls, basicAuth, awsIRSA, azureWorkloadIdentity, dockerConfig, sshKey, certificate.
- format (string, optional): Content encoding hint for inline material. One of: kv, pem, pkcs12, json, binary.
- annotations (object, optional): Arbitrary key/value metadata for recipes or operators.
- data (object, required): Holds secret payload definitions.
  - inline (object, optional): Map<string,string> of literal secret values stored in the resource.
  - external (object, optional): Map<string, { uri: string; version?: string }> referencing secrets in an external provider (e.g., akv://...).

Notes:
- Either inline, external, or both may be supplied.
- Keys inside inline and external are independent (you may use the same name in both, but avoiding collisions is recommended).
- format + kind together inform downstream tooling how to package or deliver the data (e.g., kubernetes Secret type, certificate assembly, docker config file).

## Data Structure
```yaml
data:
  inline:
    <logicalKey>: <string value>
  external:
    <logicalKey>:
      uri: akv://vault/secrets/...
      version: <optional version>
```

## Examples

### 1. Generic key/value with mixed inline + external
```bicep
resource appSecrets 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'app-secrets'
  properties: {
    environment: '/envs/dev'
    application: '/apps/sample'
    kind: 'generic'
    format: 'kv'
    annotations: {
      'radius.io/recipe': 'kubernetes-secret'
      'environment': 'development'
    }
    data: {
      inline: {
        username: 'appuser'
        password: 'c2VjcmV0Cg=='
      }
      external: {
        apiToken: {
          uri: 'akv://mainvault/secrets/apiToken'
        }
      }
    }
  }
}
```

### 2. TLS certificate (PEM) with external CA bundle
```bicep
resource tlsSecrets 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'tls-secrets'
  properties: {
    environment: '/envs/prod'
    application: '/apps/webapp'
    kind: 'tls'
    format: 'pem'
    data: {
      inline: {
        cert: '''
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----'''
        key: '''
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----'''
      }
      external: {
        caBundle: {
          uri: 'akv://mainvault/secrets/caBundle'
        }
      }
    }
  }
}
```

### 3. Certificate bundle (PKCS12)
```bicep
resource certBundle 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'cert-bundle'
  properties: {
    environment: '/envs/staging'
    application: '/apps/service'
    kind: 'certificate'
    format: 'pkcs12'
    data: {
      inline: {
        bundle: 'BASE64_PKCS12_CONTENT'
        bundlePassword: 'p@ssw0rd'
      }
    }
  }
}
```

### 4. Docker config (registry credentials)
```bicep
resource registryCreds 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'registry-creds'
  properties: {
    environment: '/envs/dev'
    application: '/apps/container-app'
    kind: 'dockerConfig'
    format: 'json'
    data: {
      inline: {
        'config.json': '{"auths":{"registry.example.com":{"username":"u","password":"p"}}}'
      }
    }
  }
}
```

### 5. SSH key pair
```bicep
resource sshKeys 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'ssh-keys'
  properties: {
    environment: '/envs/dev'
    application: '/apps/gitops'
    kind: 'sshKey'
    format: 'pem'
    data: {
      inline: {
        public: 'ssh-ed25519 AAAAC3Nz...'
        private: '''
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----'''
      }
    }
  }
}
```

### 6. Basic auth (username inline, password external)
```bicep
resource basicCreds 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'basic-creds'
  properties: {
    environment: '/envs/prod'
    application: '/apps/api'
    kind: 'basicAuth'
    data: {
      inline: {
        username: 'serviceUser'
      }
      external: {
        password: {
          uri: 'akv://mainvault/secrets/servicePassword'
        }
      }
    }
  }
}
```

### 7. External-only (rotation handled by provider)
```bicep
resource dbSecrets 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'db-secrets'
  properties: {
    environment: '/envs/prod'
    application: '/apps/database-client'
    kind: 'generic'
    data: {
      external: {
        dbPassword: {
          uri: 'akv://mainvault/secrets/dbPassword'
          version: '2024-01-01'
        }
      }
    }
  }
}
```

### 8. AWS IRSA (IAM Roles for Service Accounts)
```bicep
resource awsIrsa 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'aws-workload-identity'
  properties: {
    environment: '/envs/prod'
    application: '/apps/aws-app'
    kind: 'awsIRSA'
    data: {
      inline: {
        roleArn: 'arn:aws:iam::123456789012:role/MyAppServiceRole'
        audience: 'sts.amazonaws.com'
      }
    }
  }
}
```

### 9. Azure Workload Identity
```bicep
resource azureWi 'Radius.Security/secrets@2023-10-01-preview' = {
  name: 'azure-workload-identity'
  properties: {
    environment: '/envs/prod'
    application: '/apps/azure-app'
    kind: 'azureWorkloadIdentity'
    data: {
      inline: {
        clientId: '12345678-1234-1234-1234-123456789012'
        tenantId: '87654321-4321-4321-4321-210987654321'
      }
      external: {
        clientSecret: {
          uri: 'akv://mainvault/secrets/azureAppClientSecret'
        }
      }
    }
  }
}
```

## Guidance
- Prefer external for secrets requiring rotation or auditing.
- Keep inline values small; large binary blobs should be referenced externally.
- format should reflect the predominant encoding of inline content; mixed encodings per key are not explicitly modeled—tooling may infer via file-like key names (e.g., config.json).
- Avoid committing real secret values (especially inline) to version control
