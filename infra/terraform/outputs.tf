output "cluster_name" {
  description = "Nome do cluster kind."
  value       = kind_cluster.mural.name
}

output "kubeconfig_path" {
  description = "Kubeconfig do cluster (use com KUBECONFIG=...)."
  value       = kind_cluster.mural.kubeconfig_path
}

output "url" {
  description = "URL do Mural."
  value       = "http://${var.host}/"
}

output "curl_hint" {
  description = "Teste sem depender do DNS de localtest.me."
  value       = "curl --resolve ${var.host}:80:127.0.0.1 http://${var.host}/"
}
