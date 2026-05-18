// Platform-engineer-owned infrastructure. Declares:
//
//   1. An `Applications.Core/secretStores` of `type: 'generic'`
//      holding the registry username + password (PAT) the
//      Radius.Compute/containerImages recipe pushes images with.
//
//   2. An `Applications.Core/environments` that references that
//      SecretStore from
//      `recipeConfig.terraform.authentication.registries[<host>]`
//      and registers the Terraform recipes the developer's
//      `app.bicep` consumes.
//
// The Radius terraform driver resolves the referenced SecretStore at
// recipe execution time, materializes a Docker config.json into the
// recipe's working directory, exports `DOCKER_CONFIG` for buildctl,
// and (for Radius.Compute/containerImages specifically) also
// materializes a `kubernetes.io/dockerconfigjson` Secret in the app
// namespace so kubelet can pull the image, surfacing its name as the
// recipe output `imagePullSecretName`. Developers never see the
// credentials, the SecretStore, or the pull Secret.
//
//   rad deploy platform.bicep \
//     -p registryUsername=$GHCR_USER \
//     -p registryPassword=$GHCR_TOKEN \
//     -p registryHost=ghcr.io \
//     -p registryPath=ghcr.io/myorg \
//     -p containerImagesTemplatePath='git::https://…?ref=<sha>' \
//     -p containersTemplatePath='git::https://…?ref=<sha>'

extension radius

@description('Registry host (key under recipeConfig.terraform.authentication.registries). E.g. ghcr.io.')
param registryHost string = 'ghcr.io'

@description('Default registry path the recipe pushes images to. E.g. ghcr.io/myorg/myrepo.')
param registryPath string

@description('Username for authenticating to the registry.')
param registryUsername string

@description('Password (or PAT) for authenticating to the registry.')
@secure()
param registryPassword string

@description('Terraform template path (git::https…?ref=…) for the Radius.Compute/containerImages recipe.')
param containerImagesTemplatePath string

@description('Terraform template path (git::https…?ref=…) for the Radius.Compute/containers recipe.')
param containersTemplatePath string

@description('Kubernetes namespace the environment provisions resources into by default.')
param envNamespace string = 'default'

resource registryCreds 'Applications.Core/secretStores@2023-10-01-preview' = {
  name: 'registry-creds'
  properties: {
    type: 'generic'
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

resource env 'Applications.Core/environments@2023-10-01-preview' = {
  name: 'default'
  properties: {
    compute: {
      kind: 'kubernetes'
      resourceId: 'self'
      namespace: envNamespace
    }
    recipeConfig: {
      terraform: {
        authentication: any({
          registries: {
            '${registryHost}': {
              secret: registryCreds.id
            }
          }
        })
      }
    }
    recipes: {
      'Radius.Compute/containerImages': {
        default: {
          templateKind: 'terraform'
          templatePath: containerImagesTemplatePath
          parameters: {
            registry: registryPath
          }
        }
      }
      'Radius.Compute/containers': {
        default: {
          templateKind: 'terraform'
          templatePath: containersTemplatePath
        }
      }
    }
  }
}
