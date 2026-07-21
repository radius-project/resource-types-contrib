@description('Radius recipe context. Carries resource properties, environment, and runtime info.')
param context object

@description('Operator Recipe parameter for the registry prefix (e.g. `ghcr.io/myorg`) into which images are pushed.')
param registry string

@description('Operator Recipe parameter naming the Kubernetes Secret containing `username` and `password`. Leave empty for an unauthenticated registry.')
param registrySecretName string = ''

// Platform engineers customize build.sh and republish this recipe. Radius reads this exact
// compiled-template variable; resource properties and recipe parameters are never evaluated
// as shell code.
#disable-next-line no-unused-vars // Consumed by the Radius Bicep driver from the compiled template.
var radiusContainerImagesBuildScript = loadTextContent('build.sh')

var properties = context.resource.properties
var build = properties.build

// Radius consumes this private, typed output synchronously after the Bicep deployment. The
// driver replaces the evaluated registry fields with the registered operator Recipe parameters
// before passing values to build.sh as arguments; no values are interpolated into script text.
output imageBuild object = {
  resourceName: context.resource.name
  registry: registry
  registrySecretName: registrySecretName
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

// build.sh reports imageReference only after buildctl has pushed the image successfully.
output result object = {
  resources: []
  values: {}
}
