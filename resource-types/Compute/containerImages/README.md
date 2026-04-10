## Overview

The Radius.Compute/containerImages Resource Type builds a container image from local source and pushes it to a remote container registry (e.g., ghcr.io). It is always part of a Radius Application.

The Kubernetes recipe uses a standard server-side recipe pattern:

1. The source directory is available on the kind cluster node via `extraMounts`
2. A **BuildKit** container reads the source via a `hostPath` volume, builds the image, and pushes it to the registry
3. Registry credentials are provided via a Kubernetes Secret

This approach requires no client-side tooling or rad CLI changes — it runs entirely in the cluster.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Prerequisites

### 1. kind cluster with extraMounts

The kind cluster must mount the host source directory into the node:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /Users/you/dev/myapp    # your local source
        containerPath: /app/myapp          # path visible inside the node
```

```bash
kind create cluster --config kind-config.yaml
```

### 2. GHCR credentials secret

Create a Kubernetes Secret with your GitHub Personal Access Token:

```bash
kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=YOUR_GITHUB_PAT
```

The PAT needs the `write:packages` scope.

## Architecture

```
Host machine                          kind cluster node
┌─────────────────────┐              ┌──────────────────────────────┐
│ ~/dev/myapp/        │  extraMount  │ /app/myapp/                  │
│   Dockerfile        │ ──────────►  │   Dockerfile                 │
│   src/              │              │   src/                       │
└─────────────────────┘              │                              │
                                     │  Build Job pod:              │
                                     │  ┌────────────────────────┐  │
                                     │  │ BuildKit               │  │
                                     │  │  hostPath: /app/myapp  │  │
                                     │  │  → builds image        │  │
                                     │  │  → pushes to ghcr.io   │  │
                                     │  │  (creds from K8s       │  │
                                     │  │   Secret)              │  │
                                     │  └────────────────────────┘  │
                                     └──────────────────────────────┘
```

## Recipes

| Platform | IaC Language | Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes-containerImages.bicep | Alpha |

## Recipe Input Properties

| Radius Property | Description |
|---|---|
| `image` | Full image reference including registry (e.g., `ghcr.io/myorg/myapp:latest`) |
| `build.context` | Host path to source directory (must match kind extraMount `containerPath`) |
| `build.dockerfile` | Dockerfile path relative to build context (default: `Dockerfile`) |
| `registry.secretName` | Kubernetes Secret of type `kubernetes.io/dockerconfigjson` for ghcr.io push auth |

## Recipe Output Properties

There are no output properties that need to be set by the Recipe.
