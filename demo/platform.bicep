// Platform-engineer baseline. Declares everything the developer's
// `app.bicep` depends on: a Radius environment, a recipe pack with
// inline parameters wiring registry credentials into the
// containerImages recipe, a `platform` application that hosts the
// registry secret, and the Radius.Security/secrets resource that
// materializes the underlying Kubernetes Secret kubelet and buildctl
// will consume.
//
// Deploy:
//   rad deploy platform.bicep \
//     -p registryUsername=$GHCR_USER \
//     -p registryPassword=$GHCR_TOKEN \
//     -p registryPath=ghcr.io/myorg \
//     -p containerImagesTemplatePath='git::https://…?ref=<sha>' \
//     -p containersTemplatePath='git::https://…?ref=<sha>'

extension radius

@description('Registry path the containerImages recipe pushes images to. E.g. ghcr.io/myorg.')
param registryPath string

@description('Registry username.')
param registryUsername string

@description('Registry password / PAT.')
@secure()
param registryPassword string

@description('Terraform template path for the Radius.Compute/containerImages recipe.')
param containerImagesTemplatePath string

@description('Terraform template path for the Radius.Compute/containers recipe.')
param containersTemplatePath string

@description('Kubernetes namespace the environment provisions resources into by default.')
param envNamespace string = 'default'

// Default Radius namespace convention: <env>-<app>. This is the
// namespace the Radius.Security/secrets recipe materializes the
// `ghcr-creds` Kubernetes Secret into.
var registrySecretNamespace = '${envNamespace}-platform'

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default-recipes'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Security/secrets': {
        recipeKind: 'terraform'
        recipeLocation: 'git::https://github.com/radius-project/resource-types-contrib.git//Security/secrets/recipes/kubernetes/terraform'
      }
      'Radius.Compute/containerImages': {
        recipeKind: 'terraform'
        recipeLocation: containerImagesTemplatePath
        parameters: {
          registry: registryPath
          registrySecretName: 'ghcr-creds'
          registrySecretNamespace: registrySecretNamespace
        }
      }
      'Radius.Compute/containers': {
        recipeKind: 'terraform'
        recipeLocation: containersTemplatePath
      }
    }
  }
}

resource env 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'default'
  location: 'global'
  properties: {
    providers: {
      kubernetes: {
        namespace: envNamespace
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}

resource platform 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'platform'
  location: 'global'
  properties: {
    environment: env.id
  }
}

resource ghcrCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-creds'
  properties: {
    environment: env.id
    application: platform.id
    kind: 'generic'
    data: {
      username: {
        value: registryUsername
      }
      password: {
        value: registryPassword
      }
    }
  }
}
