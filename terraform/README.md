# Terraform Infrastructure — Mistral Gateway on GKE

This directory contains the production-grade Terraform configuration that provisions
all Google Cloud Platform resources required by the Mistral Inference Gateway.

## Architecture Overview

```
GCP Project
├── VPC Network (mistral-vpc)
│   └── Subnet (mistral-subnet, 10.10.0.0/20)
│       ├── Secondary range: pods    (10.20.0.0/16)
│       └── Secondary range: services (10.30.0.0/20)
│
├── GKE Standard Cluster (mistral-cluster)
│   ├── System Node Pool (e2-standard-4, 1–3 nodes, auto-scale)
│   └── GPU Node Pool    (g2-standard-12 + NVIDIA L4, 1–3 nodes)
│
├── Artifact Registry (mistral-registry)
│   └── Docker repository for FastAPI images
│
├── GCS Bucket (${project_id}-mistral-models)
│   └── Mistral-7B-Instruct-v0.3 model weights
│
└── IAM Service Accounts
    ├── gke-node-sa          → nodes (minimal permissions)
    ├── fastapi-gsa          → Cloud Logging + Cloud Trace (Workload Identity)
    ├── vllm-gsa             → Cloud Logging + GCS objectViewer (Workload Identity)
    └── model-download-gsa   → GCS objectAdmin on model bucket (Workload Identity)
```

## File Structure

| File | Purpose |
|------|---------|
| `versions.tf` | Provider versions and Terraform backend (GCS remote state) |
| `variables.tf` | All input variables with descriptions and defaults |
| `locals.tf` | Computed values and common labels |
| `networking.tf` | VPC, subnet, secondary IP ranges, Cloud Router, Cloud NAT |
| `iam.tf` | GCP Service Accounts and IAM role bindings |
| `artifact_registry.tf` | Docker repository for FastAPI container images |
| `gcs.tf` | GCS bucket for Mistral model weights |
| `gke.tf` | GKE Standard cluster + system node pool |
| `node_pool_gpu.tf` | NVIDIA L4 GPU node pool (separate for independent scaling) |
| `workload_identity.tf` | Workload Identity bindings: K8s SA → GCP SA |
| `outputs.tf` | Cluster endpoint, registry URL, bucket name, SA emails |

## Prerequisites

1. GCP project with billing enabled
2. APIs enabled (see `versions.tf`)
3. Terraform >= 1.7 and `google` provider >= 6.0
4. GCS bucket for Terraform remote state created **before** `terraform init`

## Usage

```bash
cd terraform/

# 1. Create the remote state bucket (one-time, outside Terraform)
gcloud storage buckets create gs://${PROJECT_ID}-tf-state \
  --location=us-central1 \
  --project=${PROJECT_ID}

# 2. Initialise Terraform
terraform init \
  -backend-config="bucket=${PROJECT_ID}-tf-state" \
  -backend-config="prefix=mistral-gateway"

# 3. Preview
terraform plan -var="project_id=${PROJECT_ID}" -var="region=us-central1"

# 4. Apply (~15 min)
terraform apply -var="project_id=${PROJECT_ID}" -var="region=us-central1"

# 5. Configure kubectl
gcloud container clusters get-credentials \
  $(terraform output -raw cluster_name) \
  --region=$(terraform output -raw region) \
  --project=${PROJECT_ID}
```

## Workload Identity Bindings

| Kubernetes SA | Namespace | GCP SA | Permissions |
|--------------|-----------|--------|-------------|
| `fastapi-sa` | `mistral-gateway` | `fastapi-gsa` | Logging write, Trace write |
| `vllm-sa` | `mistral-gateway` | `vllm-gsa` | Logging write, GCS objectViewer |
| `model-download-sa` | `mistral-gateway` | `model-download-gsa` | GCS objectAdmin on model bucket |

## Cost Estimate (us-central1, on-demand)

| Resource | Est. Monthly Cost |
|----------|------------------|
| GKE Cluster control plane | ~$73 |
| System node pool (e2-standard-4 × 1-3) | $50–$150 |
| GPU node pool (g2-standard-12 + L4 × 1-3) | $600–$1,800 |
| GCS bucket (model weights ~30 GB) | ~$1 |
| Artifact Registry | ~$0.10/GB |
| Cloud NAT | ~$1 |
| **Total (min / max)** | **~$724 / ~$2,024** |

> **Tip**: Use preemptible GPU nodes to cut GPU costs by ~70% in dev/staging.
