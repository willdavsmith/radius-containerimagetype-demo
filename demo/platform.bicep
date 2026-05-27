// Platform-engineer baseline. Declares the recipe pack and the
// environment that references it. Registry credentials live in
// `secrets.bicep`, deployed separately, so the env + recipePack +
// secret never form a symbolic cycle (BCP080) and credential
// rotation is decoupled from recipe config.
//
// The recipePack wires the literal string 'ghcr-creds' as the
// `registrySecretName` parameter; secrets.bicep declares a
// Radius.Security/secrets of that exact name in the same env.
//
// Deploy order:
//   rad deploy platform.bicep \
//     -p registryPath=ghcr.io/myorg \
//     -p containerImagesTemplatePath='git::https://…?ref=<sha>' \
//     -p containersTemplatePath='git::https://…?ref=<sha>'
//   rad deploy secrets.bicep \
//     -p registryUsername=$GHCR_USER \
//     -p registryPassword=$GHCR_TOKEN

extension radius

@description('Registry path the containerImages recipe pushes images to. E.g. ghcr.io/myorg.')
param registryPath string

@description('Terraform template path for the Radius.Compute/containerImages recipe.')
param containerImagesTemplatePath string

@description('Terraform template path for the Radius.Compute/containers recipe.')
param containersTemplatePath string

@description('Kubernetes namespace the environment provisions resources into by default.')
param envNamespace string = 'default'

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default-recipes'
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
