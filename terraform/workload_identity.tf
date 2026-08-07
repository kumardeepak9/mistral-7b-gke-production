locals {
  k8s_namespace = "mistral-gateway"

  workload_identity_bindings = {
    fastapi-sa        = google_service_account.fastapi_gsa.name
    vllm-sa           = google_service_account.vllm_gsa.name
    model-download-sa = google_service_account.model_download_gsa.name
  }
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each           = local.workload_identity_bindings
  service_account_id = each.value
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_identity_pool}[${local.k8s_namespace}/${each.key}]"

  depends_on = [
    google_container_cluster.primary,
    google_service_account.fastapi_gsa,
    google_service_account.vllm_gsa,
    google_service_account.model_download_gsa,
  ]
}
