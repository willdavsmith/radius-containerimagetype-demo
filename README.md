# Radius.Compute/containerImages Demo

A demo of a custom Radius resource type (`Radius.Compute/containerImages`) that builds a container image from local source and pushes it to GitHub Container Registry (ghcr.io).

## How it works

```
Host machine                          kind cluster node
┌─────────────────────┐              ┌──────────────────────────────┐
│ ~/dev/myapp/        │  extraMount  │ /app/myapp/                  │
│   Dockerfile        │ ──────────►  │   Dockerfile                 │
│   src/              │              │   src/                       │
└─────────────────────┘              │                              │
                                     │  Build Job (Terraform recipe)│
                                     │  ┌────────────────────────┐  │
                                     │  │ BuildKit               │  │
                                     │  │  hostPath → /workspace │  │
                                     │  │  builds image          │  │
                                     │  │  pushes to ghcr.io     │  │
                                     │  │  (creds from Radius    │  │
                                     │  │   Secret)              │  │
                                     │  └────────────────────────┘  │
                                     └──────────────────────────────┘
```

1. Source code lives on the host and is mounted into the kind node via `extraMounts`
2. The Terraform recipe creates a Kubernetes Job with a `hostPath` volume pointing at the source
3. BuildKit builds the image and pushes it to ghcr.io using credentials from a `Radius.Security/secrets` resource
4. The Terraform `kubernetes_job_v1` resource uses `wait_for_completion = true`, so Radius correctly waits for the build to finish before proceeding
5. Downstream `Radius.Compute/containers` resources reference the built image via a connection

## Repository structure

```
├── resource-types/
│   └── Compute/containerImages/            # Custom resource type (this project)
│       ├── containerImages.yaml
│       ├── README.md
│       └── recipes/kubernetes/
│           ├── bicep/
│           │   └── kubernetes-containerImages.bicep
│           └── terraform/
│               ├── main.tf                 # Terraform recipe (recommended)
│               └── var.tf
│
├── resource-types-contrib/                 # Git submodule → radius-project/resource-types-contrib
│   ├── Compute/containers/                 # Radius.Compute/containers type + recipes
│   ├── Compute/persistentVolumes/          # Radius.Compute/persistentVolumes type + recipes
│   ├── Compute/routes/                     # Radius.Compute/routes type + recipes
│   └── Security/secrets/                   # Radius.Security/secrets type + recipes
│
└── demo/
    ├── app/                                # Sample Node.js application
    │   ├── Dockerfile
    │   └── server.js
    ├── app.bicep                           # Radius application definition
    ├── bicepconfig.json                    # Bicep extension configuration
    └── kind-config.yaml                    # kind cluster with extraMounts
```

> **Note:** This repo uses Terraform recipes for `Radius.Compute/containers` and `Radius.Security/secrets`
> from [radius-project/resource-types-contrib](https://github.com/radius-project/resource-types-contrib)
> (included as a git submodule). Terraform recipes are preferred over Bicep because the Terraform
> Kubernetes provider has built-in health monitoring (`wait_for_rollout`, `wait_for_completion`),
> while Bicep recipes return immediately after creating resources without waiting for them to
> become healthy.

## Quick start

### Prerequisites

- [kind](https://kind.sigs.k8s.io/)
- [Radius CLI](https://docs.radapp.io/tutorials/install-radius/)
- [Terraform](https://developer.hashicorp.com/terraform/install)
- A GitHub Personal Access Token with `write:packages` scope

### 1. Clone and configure credentials

```bash
git clone --recurse-submodules https://github.com/YOUR_ORG/radius-containerimagetype-demo.git
cd radius-containerimagetype-demo

cp .env.example .env
# Edit .env with your GitHub username and PAT
source .env
```

### 2. Create the kind cluster

```bash
cd demo
kind create cluster --name radius-demo --config kind-config.yaml
```

This mounts `demo/app/` into the kind node at `/app/demo`.

### 3. Install Radius

```bash
rad install kubernetes
kubectl get pods -n radius-system
```

### 4. Create a resource group, environment, and workspace

```bash
rad group create default
rad environment create default
rad workspace create kubernetes default \
  --context $(kubectl config current-context) \
  --environment default \
  --group default
```

### 5. Register resource types and build Bicep extensions

From the repo root:

```bash
make setup
```

This runs `make register-types`, `make build`, and `make register-recipes` in sequence:
- Registers all resource types from the `resource-types-contrib` submodule and the custom `containerImages` type
- Generates Bicep extension `.tgz` files into `demo/`
- Registers Terraform recipes for each resource type

> **Note:** Edit the `Makefile` and replace `YOUR_ORG` in the `register-recipes` target with your GitHub username before running `make setup`, or run `make register-types build` and register recipes manually.

### 6. Deploy

Edit `app.bicep` if needed, then:

```bash
cd demo
rad deploy app.bicep \
  -p ghcrUsername=$YOUR_GITHUB_USERNAME \
  -p ghcrPassword=$YOUR_GITHUB_PAT \
  -p image=ghcr.io/your-org/demo:latest
```

This will:
1. Create a `Radius.Security/secrets` resource with GHCR credentials (→ Kubernetes Secret)
2. Build the container image from `demo/app/` (mounted at `/app/demo`) and push to ghcr.io
3. Wait for the build Job to complete (Terraform `wait_for_completion`)
4. Deploy a `Radius.Compute/containers` running the built image

### 7. Test

```bash
rad resource expose Radius.Compute/containers demo -a demo --port 3000
```

Navigate to http://localhost:3000. Press `CTRL+C` to stop.

### 8. Cleanup

```bash
rad application delete demo
kind delete cluster --name radius-demo
```

## Why Terraform recipes?

Bicep recipes for Kubernetes have a health monitoring gap: the Bicep Kubernetes extension
creates resources and returns immediately without waiting for pods to be ready or Jobs to
complete. The Radius `dynamic-rp` does not fill this gap, so resources are marked "Completed"
even when the underlying workloads are failing.

The Terraform Kubernetes provider has built-in wait behavior:

| Resource | Terraform default | Bicep behavior |
|---|---|---|
| `kubernetes_deployment` | `wait_for_rollout = true` (waits for pods) | Returns immediately |
| `kubernetes_job_v1` | `wait_for_completion = true` (waits for Job) | Returns immediately |

See `repro/` for a full reproduction of this issue.

## CI/CD

The repo includes a GitHub Actions workflow (`.github/workflows/e2e.yaml`) that runs the
full E2E test on every push to `main` and on PRs:

1. Creates a k3d cluster with the demo app source mounted
2. Installs Radius and registers all resource types + Terraform recipes
3. Deploys the application using `GITHUB_TOKEN` for GHCR authentication
4. Verifies the build Job completed, the container is running, and the app responds

The workflow uses `GITHUB_TOKEN` (with `packages: write`) — no additional secrets needed.
Recipe references are pinned to the exact commit SHA to ensure CI validates the code under test.
