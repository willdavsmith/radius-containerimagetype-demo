# `Radius.Compute/containerImages` — UX

## Platform Engineer — one-time

```bash
# 1. Install Radius.
rad install kubernetes
rad workspace create kubernetes default \
  --context "$(kubectl config current-context)" --group default
rad workspace switch default

# 2. Register resource types.
rad resource-type create -f Security/secrets/secrets.yaml
rad resource-type create -f Compute/containerImages/containerImages.yaml
rad resource-type create -f Compute/containers/containers.yaml

# 3. Deploy platform.bicep — declares the recipePack (which registers
#    the containerImages + containers recipes) and the env.
rad deploy platform.bicep \
  -p registryPath="ghcr.io/my-org"

# 4. Deploy secrets.bicep — declares the registry credentials secret.
rad deploy secrets.bicep \
  -p registryUsername="$GHCR_USER" \
  -p registryPassword="$GHCR_TOKEN"
```

> Operators enforcing PSA `restricted` cluster-wide on K8s ≥ 1.30
> with `UserNamespacesSupport` may opt into the stricter sidecar
> profile via `--set dynamicrp.buildkit.psaMode=restricted`.

`platform.bicep`:

```bicep
extension radius

param registryPath string
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
        recipeLocation: 'git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform'
        parameters: {
          registry: registryPath
          registrySecretName: 'ghcr-creds'
        }
      }
      'Radius.Compute/containers': {
        recipeKind: 'terraform'
        recipeLocation: 'git::https://github.com/radius-project/resource-types-contrib.git//Compute/containers/recipes/kubernetes/terraform'
      }
    }
  }
}

resource env 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'default'
  properties: {
    providers: { kubernetes: { namespace: envNamespace } }
    recipePacks: [ recipes.id ]
  }
}
```

`secrets.bicep`:

```bicep
extension radius

param registryUsername string
@secure()
param registryPassword string

resource env 'Radius.Core/environments@2025-08-01-preview' existing = {
  name: 'default'
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

## Developer — every deploy

```bicep
extension radius
extension containerImages
extension containers

param environment string
param buildSource string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'demo'
  properties: { environment: environment }
}

resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'demo-image'
  properties: {
    environment: environment
    application: app.id
    imageName:   'demo-image'  // optional
    imageTag:    'latest'      // optional
    build: {
      source:     buildSource
      dockerfile: 'Dockerfile' // optional, default 'Dockerfile'
    }
  }
}

resource demo 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: demoImage.properties.imageReference
        ports: { web: { containerPort: 3000 } }
      }
    }
    connections: { demoContainerImage: { source: demoImage.id } }
  }
}
```

```bash
rad deploy app.bicep -p buildSource="git::https://github.com/my-org/my-app.git#main"
```

> Builds produce a multi-arch (`linux/amd64` + `linux/arm64`) manifest
> by default. The Dockerfile must cross-compile using
> `FROM --platform=$BUILDPLATFORM` and `TARGETARCH`. To target a
> single architecture, set `build.platforms: ['linux/amd64']`.

## Examples

### 1. Local development — building from a path on disk

The developer iterates on `./frontend` in their working tree.
`rad deploy` tarballs the local directory, uploads it to dynamic-rp,
and BuildKit builds + pushes inside the cluster. No out-of-band
`docker build`/`docker push`:

```bicep
resource frontendImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'frontend-image'
  properties: {
    environment: env.id
    application: app.id
    imageTag:    'dev'
    build: {
      source: './frontend'
    }
  }
}
```

### 2. Building from a git URL

The developer has pushed their code; BuildKit clones the repo
in-cluster on each deploy:

```bicep
resource frontendImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'frontend-image'
  properties: {
    environment: env.id
    application: app.id
    imageTag:    'a1b2c3d'
    build: {
      source: 'git::https://github.com/alice/myapp.git#a1b2c3d:frontend'
    }
  }
}
```

### 3. Monorepo with two Dockerfiles in different sub-directories

```bicep
resource apiImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'api-image'
  properties: {
    environment: env.id
    application: app.id
    imageTag:    'a1b2c3d'
    build: {
      source:     'git::https://github.com/alice/myapp.git#a1b2c3d'
      dockerfile: 'services/api/Dockerfile'
    }
  }
}

resource workerImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'worker-image'
  properties: {
    environment: env.id
    application: app.id
    imageTag:    'a1b2c3d'
    build: {
      source:     'git::https://github.com/alice/myapp.git#a1b2c3d'
      dockerfile: 'services/worker/Dockerfile'
    }
  }
}
```

Each `containerImages` resource produces an independent
`imageReference` consumed by the matching `containers` resource.

### 4. Two Dockerfiles in one directory (e.g. prod + debug)

A single source tree with `Dockerfile` and `Dockerfile.debug`
side-by-side — build both as separate images:

```bicep
resource appProd 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'app-prod'
  properties: {
    environment: env.id
    application: app.id
    imageName:   'app'
    imageTag:    'a1b2c3d'
    build: {
      source:     'git::https://github.com/alice/myapp.git#a1b2c3d'
      dockerfile: 'Dockerfile'        // optional, this is the default
    }
  }
}

resource appDebug 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'app-debug'
  properties: {
    environment: env.id
    application: app.id
    imageName:   'app'
    imageTag:    'a1b2c3d-debug'      // disambiguate in the registry
    build: {
      source:     'git::https://github.com/alice/myapp.git#a1b2c3d'
      dockerfile: 'Dockerfile.debug'
    }
  }
}
```

### 5. Pre-built image (no build)

If the image already exists in your registry, skip
`Radius.Compute/containerImages` entirely and point the container
straight at the reference:

```bicep
resource demo 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'demo'
  properties: {
    environment: env.id
    application: app.id
    containers: {
      demo: {
        image: 'ghcr.io/my-org/demo:v1.2.3'
        ports: { web: { containerPort: 3000 } }
      }
    }
  }
}
```

### 6. Mixing a built image with a published sidecar

A single container resource consumes both a freshly-built image
(via `apiImage.properties.imageReference`) and a third-party image
(literal reference) in the same pod:

```bicep
resource api 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'api'
  properties: {
    environment: env.id
    application: app.id
    containers: {
      api: {
        image: apiImage.properties.imageReference
        ports: { http: { containerPort: 8080 } }
      }
      sidecar: {
        image: 'ghcr.io/my-org/log-forwarder:1.4.0'
      }
    }
    connections: {
      apiImage: { source: apiImage.id }
    }
  }
}
```
