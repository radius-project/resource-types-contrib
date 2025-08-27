## Overview
The Radius.Security/secrets resource type models secrets used by applications: generic key/value pairs, certificates in PEM or PKCS12 format (TLS/SSL, client certs, bundles), basic authentication credentials, SSH keys, AWS IRSA (IAM Roles for Service Accounts), and Azure Workload Identity. 

## Resource Type Schema Definition
Top-level properties (apiVersion: 2025-08-01-preview):
- environment (string, required): Resource ID of the target environment.
- application (string, optional): Resource ID of the application.
- kind (string, optional): Logical secret kind. One of: generic, certificate-pem, certificate-pkcs12, basicAuthentication, awsIRSA, azureWorkloadIdentity. Defaults to "generic".
- data (object, required): Map of secret names to objects containing value and optional encoding.
  Each key in the `data` object maps to an object with:
  - `value` (string, required): The secret value - either literal content or external URI (e.g., "akv://vault/secrets/...")
  - `encoding` (string, optional): Content encoding for this key. One of: string, base64. Defaults to "string".

Notes:
- Per-key encoding allows mixed formats within a single secret.
- kind + encoding inform downstream tooling how to package or deliver the data (e.g., kubernetes Secret type, certificate assembly).

## Required Fields by Kind
Certain secret kinds have required keys in the `data` object to ensure compatibility with existing functionality (e.g., [private Bicep registry](https://docs.radapp.io/guides/recipes/howto-private-bicep-registry/) support):

- **basicAuthentication**: Requires `username` and `password` keys
- **certificate-pem**: Requires `tls.crt` and `tls.key` keys
- **awsIRSA**: Requires `roleArn` key
- **azureWorkloadIdentity**: Requires `clientId` and `tenantId` keys  

## Examples

### 1. Generic key/value with mixed literal + external
```bicep
resource appSecrets 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'app-secrets'
  properties: {
    environment: environment
    application: myApp.id             // kind field (not provided in the eg.) will default to 'generic'
    data: {
      username: { value: 'appuser' }  // uses default 'string' encoding
      password: { value: 'c2VjcmV0Cg==', encoding: 'base64' }
      apiToken: { value: 'akv://mainvault/secrets/apiToken' }  // external URI
    }
  }
}
```

### 2. TLS certificate (PEM format) with external CA bundle
```bicep
resource tlsSecrets 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'tls-secrets'
  properties: {
    environment: environment
    application: myApp.id
    kind: 'certificate-pem'
    data: {
      'tls.crt': { 
        value: '''
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----'''
      }
      'tls.key': { 
        value: '''
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----'''
      }
      caBundle: { value: 'akv://mainvault/secrets/caBundle' }  // external URI
    }
  }
}
```

### 3. Certificate bundle (PKCS12 format)
```bicep
resource certBundle 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'cert-bundle'
  properties: {
    environment: environment
    kind: 'certificate-pkcs12'
    data: {
      bundle: { value: 'BASE64_PKCS12_CONTENT', encoding: 'base64' }
      bundlePassword: { value: 'p@ssw0rd' }  // uses default 'string' encoding
    }
  }
}
```

### 4. SSH key pair
```bicep
resource sshKeys 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ssh-keys'
  properties: {
    environment: environment
    data: {
      public: { value: 'ssh-ed25519 AAAAC3Nz...' }  // uses default 'string' encoding
      private: { 
        value: '''
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----'''  // uses default 'string' encoding  - PEM format
      }
    }
  }
}
```

### 5. Basic authentication (username literal, password external)
```bicep
resource basicCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'basic-creds'
  properties: {
    environment: environment
    application: myApp.id
    kind: 'basicAuthentication'
    data: {
      username: { value: 'serviceUser' }  // Required key, uses default 'string' encoding
      password: { value: 'akv://mainvault/secrets/servicePassword' }  // Required key, external URI
    }
  }
}
```

### 6. AWS IRSA (IAM Roles for Service Accounts)
```bicep
resource awsIrsa 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'aws-workload-identity'
  properties: {
    environment: environment
    application: myApp.id
    kind: 'awsIRSA'
    data: {
      roleArn: { value: 'arn:aws:iam::123456789012:role/MyAppServiceRole' }  // Required key
      audience: { value: 'sts.amazonaws.com' }
    }
  }
}
```

### 7. Azure Workload Identity
```bicep
resource azureWi 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'azure-workload-identity'
  properties: {
    environment: environment
    application: myApp.id
    kind: 'azureWorkloadIdentity'
    data: {
      clientId: { value: '12345678-1234-1234-1234-123456789012' }  // Required key
      tenantId: { value: '87654321-4321-4321-4321-210987654321' }  // Required key
      clientSecret: { value: 'akv://mainvault/secrets/azureAppClientSecret' }  // external URI
    }
  }
}
```

## Guidance
- Prefer external references (URIs) for secrets requiring rotation or auditing.
- Use per-key encoding to mix different formats within a single secret (e.g., plain text usernames with base64-encoded passwords).
- Specify explicit encoding for non-string content (base64). Default is 'string' encoding.
- Avoid committing real secret values (especially literal values) to version control.