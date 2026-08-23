#!/usr/bin/env bash
set -euo pipefail

REPO="kumardeepak9/mistral-7b-gke-production"

echo "Configuring GitHub Actions Secrets for ${REPO}..."

gh secret set GCP_PROJECT_ID \
  --body "project-d9f9eda6-2e99-4916-a87" \
  --repo "${REPO}"

gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER \
  --body "projects/712588614047/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider" \
  --repo "${REPO}"

gh secret set GCP_SERVICE_ACCOUNT \
  --body "github-actions-sa@project-d9f9eda6-2e99-4916-a87.iam.gserviceaccount.com" \
  --repo "${REPO}"

gh secret set GKE_CLUSTER_NAME \
  --body "mistral-cluster" \
  --repo "${REPO}"

gh secret set GKE_CLUSTER_REGION \
  --body "europe-west4" \
  --repo "${REPO}"

echo " All 5 secrets configured successfully."
echo "Triggering workflow re-run..."
gh workflow run cd.yaml --repo "${REPO}" || true
