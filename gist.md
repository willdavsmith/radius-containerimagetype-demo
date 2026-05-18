# `Radius.Compute/containerImages` — UX

Two personas: PE provisions a registry secret and registers the recipe
once; developer writes Bicep and runs `rad deploy`. Developer never
references registry credentials and never declares a secret.

No upstream `Radius.Core/*` changes. No driver changes. Everything is
expressed with existing types: `Radius.Security/secrets`,
`Radius.Core/applications`, `Radius.Core/environments`,
`Radius.Compute/containerImages`, `Radius.Compute/containers`.

## PE — one-time

```bash
# 1. Install Radius + create group/workspace/env.
rad install kubernetes
rad group create default
rad workspace create kubernetes default \
  --context "$(kubectl config current-context)" --group default
rad env create default --group default
rad workspace switch default && rad env switch default

# 2. Register resource types.
rad resource-type create -f Security/secrets/secrets.yaml
rad resource-type create -f Compute/containerImages/containerImages.yaml
rad resource-type create -f Compute/containers/containers.yaml

# 3. Register the Radius.Security/secrets recipe (needed for step 4).
rad recipe register default \
  --resource-type Radius.Security/secrets \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Security/secrets/recipes/kubernetes/terraform"

# 4. Provision a "platform" app containing the registry secret.
#    The recipe materializes a K8s Secret in the platform app's
#    namespace (default-platform here).
rad deploy registry-secret.bicep \
  -p registryUsername="$GHCR_USER" \
  -p registryPassword="$GHCR_TOKEN"

# 5. Register the containerImages recipe, telling it where to find
#    the K8s Secret.
rad recipe register default \
  --resource-type Radius.Compute/containerImages \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform" \
  --parameters registry="ghcr.io/my-org" \
  --parameters registrySecretName="ghcr-creds" \
  --parameters registrySecretNamespace="default-platform"

rad recipe register default \
  --resource-type Radius.Compute/containers \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Compute/containers/recipes/kubernetes/terraform"
```

`registry-secret.bicep`:

```bicep
extension radius

param environment string
param registryUsername string
@secure()
param registryPassword string

resource platform 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'platform'
  properties: { environment: environment }
}

resource ghcrCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-creds'
  properties: {
    environment: environment
    application: platform.id
    type: 'generic'
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

1. PE-provided `registrySecretName` + `registrySecretNamespace` reach
   the recipe as Terraform variables at execution time.
2. Recipe's `kubernetes_secret` data source reads
   `<namespace>/<name>` and surfaces `username` + `password`.
3. Recipe renders a Docker `config.json` to its working dir, exports
   `DOCKER_CONFIG`, and runs
   `buildctl build ... --output type=image,name=ghcr.io/my-org/demo-image:<tag>,push=true`
   against the in-cluster BuildKit sidecar.
4. Recipe creates a `kubernetes.io/dockerconfigjson` Secret named
   `<resource>-pull` (here `demo-image-pull`) in the app namespace and
   surfaces its name as `imagePullSecretName`.
5. `containers` recipe creates a Deployment whose pod spec references
   `imagePullSecrets: [demo-image-pull]`.

## Developer never

- Runs `docker build` / `docker push`
- Installs a Docker daemon
- Runs `kubectl create secret docker-registry`
- Patches a ServiceAccount with `imagePullSecrets`
- Hard-codes a registry hostname
- Passes registry credentials as `rad deploy` params
- Declares a secret of any kind
