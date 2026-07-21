@description('Radius recipe context. Carries resource properties, environment, and runtime info.')
param context object

@description('Registry prefix for pushed images, such as `ghcr.io/myorg`.')
#disable-next-line no-unused-params // Consumed by the Radius Bicep driver from the registered recipe definition.
param registry string

@description('Kubernetes Secret containing `username` and `password`. Leave empty for an unauthenticated registry.')
#disable-next-line no-unused-params // Consumed by the Radius Bicep driver from the registered recipe definition.
param registrySecretName string = ''

// Radius runs this statically embedded script after deployment.
#disable-next-line no-unused-vars // Consumed by the Radius Bicep driver from the compiled template.
var radiusContainerImagesBuildScript = loadTextContent('build.sh')

var properties = context.resource.properties
var build = properties.build

// Radius passes these fields to build.sh as matching flags and adds the operator registry.
output imageBuild object = {
  resourceName: context.resource.name
  tag: properties.?tag ?? ''
  tagProvided: properties.?tag != null
  source: build.source
  dockerfile: build.?dockerfile ?? 'Dockerfile'
  platforms: build.?platforms ?? [
    'linux/amd64'
    'linux/arm64'
  ]
  buildArgs: build.?args ?? {}
}

// The driver adds imageReference after build.sh pushes the image.
output result object = {
  resources: []
  values: {}
}
