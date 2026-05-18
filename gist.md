# `Radius.Compute/containerImages` — UX

Two personas: PE configures the environment once; developer writes Bicep
and runs `rad deploy`. Developer never references registry credentials.

## PE — one-time

```bash
# 1. Install
rad install kubernetes

# 2. Group + workspace (env is declared in platform.bicep below)
rad group create default
rad workspace create kubernetes default \
  --context "$(kubectl config current-context)" \
  --environment default --group default

# 3. Resource types
rad resource-type create -f Compute/containerImages/containerImages.yaml
rad resource-type create -f Compute/containers/containers.yaml

# 4. Provision environment, registry credentials, and recipes
rad deploy platform.bicep \
  -p registryUsername="$GHCR_USER" \
  -p registryPassword="$GHCR_TOKEN" \
  -p registryHost="ghcr.io" \
  -p registryPath="ghcr.io/my-org" \
  -p containerImagesTemplatePath="git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform" \
  -p containersTemplatePath="git::https://github.com/radius-project/resource-types-contrib.git//Compute/containers/recipes/kubernetes/terraform"
```

`platform.bicep`:

```bicep
extension radius

param registryUsername string
@secure()
param registryPassword string
param registryHost string = 'ghcr.io'
param registryPath string
param containerImagesTemplatePath string
param containersTemplatePath string

resource registryCreds 'Applications.Core/secretStores@2023-10-01-preview' = {
  name: 'registry-creds'
  properties: {
    type: 'generic'
    data: {
      username: { value: registryUsername }
      password: { value: registryPassword }
    }
  }
}

resource env 'Applications.Core/environments@2023-10-01-preview' = {
  name: 'default'
  properties: {
    compute: { kind: 'kubernetes', resourceId: 'self', namespace: 'default' }
    recipeConfig: {
      terraform: {
        authentication: {
          registries: {
            '${registryHost}': { secret: registryCreds.id }
          }
        }
      }
    }
    recipes: {
      'Radius.Compute/containerImages': {
        default: {
          templateKind: 'terraform'
          templatePath: containerImagesTemplatePath
          parameters: { registry: registryPath }
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
```

The SecretStore holds the raw `username` + `password`. The Radius
terraform driver resolves it at recipe execution time, renders a Docker
`config.json` into the recipe's working directory, and exports
`DOCKER_CONFIG` for buildctl. For `Radius.Compute/containerImages`
recipes specifically the driver also materializes a
`kubernetes.io/dockerconfigjson` Secret in the application namespace
(so kubelet can pull the image) and injects its name into the recipe
output as `imagePullSecretName`.

> Operators enforcing PSA `restricted` cluster-wide on K8s ≥ 1.30
> with `UserNamespacesSupport` may opt into the stricter sidecar
> profile via `--set dynamicrp.buildkit.psaMode=restricted`.

## Developer — every deploy

```bicep
extension radius
extension containerImages
extension containers

param environment string
param imageTag string
param buildContext string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'demo'
  properties: { environment: environment }
}

resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'demo-image'
  properties: {
    environment: environment
    application: app.id
    tag:         imageTag
    build: { context: buildContext }
  }
}

resource demo 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
    application: app.id
    imagePullSecrets: [demoImage.properties.imagePullSecretName]
    containers: {
      demo: {
        image: demoImage.properties.image
        ports: { web: { containerPort: 3000 } }
      }
    }
    connections: { demoContainerImage: { source: demoImage.id } }
  }
}
```

```bash
rad deploy app.bicep \
  -p imageTag="$(git rev-parse HEAD)" \
  -p buildContext="git::https://github.com/my-org/my-app.git//.?ref=$(git rev-parse HEAD)"
```

## Flow

1. Terraform driver resolves the `registry-creds` SecretStore listed
   under `recipeConfig.terraform.authentication.registries["ghcr.io"]`,
   writes a Docker `config.json` to the recipe working dir, and exports
   `DOCKER_CONFIG`.
2. `containerImages` recipe runs
   `buildctl build ... --output type=image,name=ghcr.io/my-org/demo-image:<tag>,push=true`
   against the in-cluster BuildKit sidecar.
3. Driver creates `<resource>-pull` (here `demo-image-pull`) in the app
   namespace with the same credentials and injects
   `imagePullSecretName` into the recipe output.
4. `containers` recipe creates a Deployment whose pod spec references
   `imagePullSecrets: [demo-image-pull]`.

## Developer never

- Runs `docker build` / `docker push`
- Installs a Docker daemon
- Runs `kubectl create secret docker-registry`
- Patches a ServiceAccount with `imagePullSecrets`
- Hard-codes a registry hostname
- Passes registry credentials as `rad deploy` params
- Declares a SecretStore for registry creds
