# `Radius.Compute/containerImages` — End-to-End UX

This demo introduces a new resource type, `Radius.Compute/containerImages`,
that lets Radius build and push a container image as part of a normal
`rad deploy`. The image is then consumed by a `Radius.Compute/containers`
resource in the same deployment.

The work is split across two personas. The **platform engineer** sets up
the environment once, including registry credentials. The **developer**
writes Bicep and runs `rad deploy` — they never see, configure, or
reference registry credentials in any form.

---

## Platform engineer — one-time setup

### 1. Install Radius (with the BuildKit sidecar enabled)

The `dynamic-rp` chart ships a rootless `buildkitd` sidecar that the
recipe talks to via `BUILDKIT_HOST`.

```bash
rad install kubernetes
# Production clusters: leave psaMode at the default (`restricted`).
# Local kind on ubuntu-latest: --set dynamicrp.buildkit.psaMode=baseline
```

### 2. Create a group, environment, and workspace

```bash
rad group create default
rad environment create default --group default
rad workspace create kubernetes default \
  --context "$(kubectl config current-context)" \
  --environment default \
  --group default
```

### 3. Provision registry credentials (PE-owned)

A single `kubernetes.io/dockerconfigjson` Secret in `radius-system`,
created with normal Kubernetes tooling. The recipe (registered below)
reads from this Secret and copies the credential into each application
namespace as a per-resource pull Secret. Developers never see it.

```bash
kubectl create secret docker-registry ghcr-creds \
  --namespace radius-system \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USER" \
  --docker-password="$GHCR_TOKEN"
```

### 4. Register the resource types

```bash
rad resource-type create -f Compute/containerImages/containerImages.yaml
rad resource-type create -f Compute/containers/containers.yaml
```

### 5. Register the recipes

The `containerImages` recipe takes two PE-owned parameters: where to
push (`registry`) and which Secret holds the push credentials
(`registrySecretName`).

```bash
rad recipe register default \
  --resource-type Radius.Compute/containerImages \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform" \
  --parameters registry="ghcr.io/my-org" \
  --parameters registrySecretName="ghcr-creds"

rad recipe register default \
  --resource-type Radius.Compute/containers \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Compute/containers/recipes/kubernetes/terraform"
```

That's it. The PE has now configured **where images go**, **how the
build authenticates**, and **how kubelet pulls** — all in one place,
without exposing credentials to developer Bicep or `rad deploy`
parameters.

---

## Developer — every deployment

### 1. Write the Bicep

A complete app (build + run) is two resources. **Notice what's
absent**: no `Radius.Security/secrets`, no `extension secrets`, no
`registryUsername`, no `registryPassword`, no registry hostname.

```bicep
extension radius
extension containerImages
extension containers

param environment string
param imageTag string
param buildContext string             // git URL or local path

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'demo'
  properties: { environment: environment }
}

// Build & push. The recipe uses the PE-provided registry credentials.
resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'demo-image'
  properties: {
    environment: environment
    application: app.id
    tag:         imageTag
    build: { context: buildContext }
  }
}

// Run the image. `imagePullSecretName` is a read-only output of the
// containerImages resource — the recipe materializes a pull Secret
// in this namespace and surfaces its name here so the developer never
// has to know what's in it.
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
    connections: {
      demoContainerImage: { source: demoImage.id }
    }
  }
}
```

### 2. Deploy

```bash
rad deploy app.bicep \
  -p imageTag="$(git rev-parse HEAD)" \
  -p buildContext="git::https://github.com/my-org/my-app.git//.?ref=$(git rev-parse HEAD)"
```

What happens, in order:

1. The `containerImages` recipe reads the PE-owned `ghcr-creds` Secret
   from `radius-system`, writes a Docker `config.json` to disk, and
   runs `buildctl build ... --output type=image,name=ghcr.io/my-org/demo-image:<sha>,push=true`
   against the in-cluster BuildKit sidecar.
2. The same recipe creates a `kubernetes.io/dockerconfigjson` Secret
   in the application namespace named `demo-image-pull` containing
   the same credentials.
3. The recipe returns `properties.image` (the fully-qualified ref) and
   `properties.imagePullSecretName` (`"demo-image-pull"`).
4. The `containers` recipe creates a Deployment whose pod spec
   references `imagePullSecrets: [demo-image-pull]`, so kubelet uses
   that Secret to pull the image that was just pushed.

### 3. Iterate

Edit code → `rad deploy` again. The recipe content-hashes the build
context for local sources (so unchanged code is a no-op rebuild), or
respects `tag` for git contexts.

---

## What the developer does **not** have to do

- ❌ Run `docker build` / `docker push` locally
- ❌ Install or configure a Docker daemon
- ❌ Run `kubectl create secret docker-registry`
- ❌ Patch the default ServiceAccount with `imagePullSecrets`
- ❌ Hard-code a registry hostname in their Bicep
- ❌ Pass registry credentials as `rad deploy` parameters
- ❌ Declare a `Radius.Security/secrets` resource for registry creds
- ❌ Manage credentials at the application level

The only inputs are **source location and a tag** — everything else
flows from the platform engineer's one-time setup.
