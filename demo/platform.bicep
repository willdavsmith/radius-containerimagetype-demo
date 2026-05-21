// Platform-engineer baseline. Declares everything the developer's
// `app.bicep` depends on: a Radius environment, a recipe pack
// (wiring the registry credentials secret name into the
// containerImages recipe), and an env-scoped Radius.Security/secrets
// resource whose recipe materializes the underlying Kubernetes
// Secret.
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
          registrySecretName: ghcrCreds.name
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

resource ghcrCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-creds'
  properties: {
    environment: env.id
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
