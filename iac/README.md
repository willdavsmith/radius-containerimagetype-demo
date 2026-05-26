# IaC for cloud E2E clusters

Provisions throwaway AKS and EKS clusters used by the
`E2E (AKS)` and `E2E (EKS)` GitHub Actions workflows. Both
configurations:

* Create a single-node cluster (cheap; appropriate for a demo).
* Wire OIDC federation so the GitHub Actions workflow assumes a
  cloud identity with no long-lived secrets stored in the repo.
* Print the exact GitHub Actions secret values you need at the end
  of `terraform apply` as outputs.

> ⚠️ These clusters cost money while they exist. Run
> `terraform destroy` when you're done.

## Prerequisites

| Cluster | Tools | Auth |
|---|---|---|
| AKS | `terraform`, `az` | `az login` against a subscription with permission to create resource groups, AKS clusters, AAD applications, and role assignments |
| EKS | `terraform`, `aws` | `aws configure` (or env vars) with permission to manage VPC, EKS, IAM |

## AKS

```bash
cd iac/aks
terraform init
terraform apply -var "github_repository=<owner>/<repo>"
```

When apply completes, copy the printed outputs into the GitHub
repo's **Settings → Secrets and variables → Actions** as
**repository secrets**:

| Output | GitHub secret name |
|---|---|
| `AKS_RESOURCE_GROUP` | `AKS_RESOURCE_GROUP` |
| `AKS_CLUSTER_NAME` | `AKS_CLUSTER_NAME` |
| `AZURE_CLIENT_ID` | `AZURE_CLIENT_ID` |
| `AZURE_TENANT_ID` | `AZURE_TENANT_ID` |
| `AZURE_SUBSCRIPTION_ID` | `AZURE_SUBSCRIPTION_ID` |

Then trigger the `E2E (AKS)` workflow from the Actions tab.

Destroy when finished:

```bash
terraform destroy -var "github_repository=<owner>/<repo>"
```

## EKS

```bash
cd iac/eks
terraform init
terraform apply -var "github_repository=<owner>/<repo>"
```

Set these GitHub Actions repository secrets:

| Output | GitHub secret name |
|---|---|
| `EKS_CLUSTER_NAME` | `EKS_CLUSTER_NAME` |
| `AWS_REGION` | `AWS_REGION` |
| `AWS_ROLE_ARN` | `AWS_ROLE_ARN` |

Then trigger the `E2E (EKS)` workflow from the Actions tab.

Destroy:

```bash
terraform destroy -var "github_repository=<owner>/<repo>"
```

## Notes

* The AKS OIDC federation creates two federated credentials: one
  for `refs/heads/main`, and one for the `aks-e2e` GitHub
  Environment. To run the AKS workflow from `workflow_dispatch` on
  any branch, either (a) trigger from `main`, or (b) protect the
  job in `e2e-aks.yaml` with `environment: aks-e2e` and create an
  Environment of that name in GitHub.
* The EKS OIDC federation uses `StringLike` on the subject claim
  (`repo:<owner>/<repo>:*`), so any branch / workflow_dispatch from
  this repo can assume the role.
* **EKS: the GitHub Actions OIDC provider is account-scoped.** AWS
  allows only one OIDC provider per URL per account, so
  `iac/eks/main.tf` looks it up via `data
  "aws_iam_openid_connect_provider"` rather than creating it. If
  your account doesn't have one yet, `terraform apply` will fail
  with "no matching OIDC provider found" — create it once with:

  ```bash
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
  ```

  Then re-run `terraform apply`.
* Neither cluster includes a managed registry (ACR/ECR). The demo
  uses GHCR for everything (built application images **and** the
  pushed `dynamic-rp` image), so no cross-cloud registry IAM is
  required. The workflows create a `ghcr-pull` Kubernetes Secret
  in `radius-system` and pass it to the chart via
  `global.imagePullSecrets` so the cluster can pull the
  `dynamic-rp` image from GHCR.
