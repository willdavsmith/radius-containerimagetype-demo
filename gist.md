# `Radius.Compute/containerImages` — UX

Two personas: PE provisions a registry secret and registers recipes
once via Bicep; developer writes Bicep and runs `rad deploy`. Developer
never references registry credentials and never declares a secret.

No upstream `Radius.Core/*` changes. No driver changes. Everything is
expressed with existing types: `Radius.Core/recipePacks`,
`Radius.Core/environments`, `Radius.Core/applications`,
`Radius.Security/secrets`, `Radius.Compute/containerImages`,
`Radius.Compute/containers`.

## PE — one-time

```bash
# 1. Install Radius + create group/workspace/env.
rad install kubernetes
rad group create default
rad workspace create kubernetes default \
  --context "$(kubectl config current-context)" --group default
rad workspace switch default
rad env create default --preview --group default
rad env switch default --preview

# 2. Register resource types.
rad resource-type create -f Security/secrets/secrets.yaml
rad resource-type create -f Compute/containerImages/containerImages.yaml
rad resource-type create -f Compute/containers/containers.yaml

# 3. Register the Radius.Security/secrets recipe imperatively so
#    platform.bicep below can deploy the ghcr-creds secret.
rad recipe register default \
  --resource-type Radius.Security/secrets \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Security/secrets/recipes/kubernetes/terraform"

# 4. Deploy platform.bicep — declares the recipePack (which registers
#    the containerImages + containers recipes), the env, the platform
#    app, and the ghcr-creds secret in one shot.
rad deploy platform.bicep \
  -p registryUsername="$GHCR_USER" \
  -p registryPassword="$GHCR_TOKEN" \
  -p registryPath="ghcr.io/my-org" \
  -p containerImagesTemplatePath="git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform" \
  -p containersTemplatePath="git::https://github.com/radius-project/resource-types-contrib.git//Compute/containers/recipes/kubernetes/terraform"
```

`platform.bicep`:

```bicep
extension radius

param registryPath string
param registryUsername string
@secure()
param registryPassword string
param containerImagesTemplatePath string
param containersTemplatePath string
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
          registryCredentials: ghcrCreds.id
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
    providers: { kubernetes: { namespace: envNamespace } }
    recipePacks: [ recipes.id ]
  }
}

resource ghcrCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-creds'
  properties: {
    environment: env.id
    kind: 'generic'
    data: {
      username: { value: registryUsername }
      password: { value: registryPassword }
    }
  }
}
```

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

resource app 'Radius.Core/applications@2025-08-01-preview' = {
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

1. Driver resolves the `registryCredentials` recipe parameter (a
   `Radius.Security/secrets` resource ID) and projects the secret's
   `data` into the recipe's variable scope as
   `var.registry_credentials = { username, password }`.
2. Recipe renders a Docker `config.json` to its working dir, exports
   `DOCKER_CONFIG`, and runs
   `buildctl build ... --output type=image,name=ghcr.io/my-org/demo-image:<tag>,push=true`
   against the in-cluster BuildKit sidecar.
3. Recipe materializes a `kubernetes.io/dockerconfigjson` Secret in the
   developer's app namespace and patches that namespace's `default`
   ServiceAccount with `imagePullSecrets: [<resource>-pull]`, so every
   Pod in the namespace pulls without explicit wiring.

## Developer never

- Runs `docker build` / `docker push`
- Installs a Docker daemon
- Runs `kubectl create secret docker-registry`
- Patches a ServiceAccount with `imagePullSecrets`
- Hard-codes a registry hostname
- Passes registry credentials as `rad deploy` params
- Declares a secret of any kind
- References the registry Secret directly
