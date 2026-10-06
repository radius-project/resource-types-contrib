extension radius

@description('Dedicated test Recipe Pack name.')
param packName string

@description('Recipe implementation under test.')
@allowed(['bicep', 'terraform'])
param recipeKind string

@description('Immutable old source or locally published new PostgreSQL source.')
param postgresqlSource string

var registry = 'reciperegistry:5000/radius-recipes'
var moduleServer = 'http://tf-module-server.radius-test-tf-module-server.svc.cluster.local'

resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: packName
  properties: {
    recipes: {
      'Radius.Data/postgreSqlDatabases': {
        kind: recipeKind
        source: postgresqlSource
        plainHttp: startsWith(postgresqlSource, 'reciperegistry:5000/')
      }
      'Radius.Compute/containers': {
        kind: recipeKind
        source: recipeKind == 'bicep'
          ? '${registry}/compute/containers/kubernetes/bicep/kubernetes-containers:latest'
          : '${moduleServer}/containers-kubernetes.zip'
        plainHttp: true
      }
      'Radius.Security/secrets': {
        kind: recipeKind
        source: recipeKind == 'bicep'
          ? '${registry}/security/secrets/kubernetes/bicep/kubernetes-secrets:latest'
          : '${moduleServer}/secrets-kubernetes.zip'
        plainHttp: true
      }
    }
  }
}
