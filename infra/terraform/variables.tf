variable "cluster_name" {
  description = "Nome do cluster kind (contexto kind-<nome>)."
  type        = string
  default     = "mural"
}

variable "namespace" {
  description = "Namespace do Mural."
  type        = string
  default     = "mural"
}

variable "release" {
  description = "Nome do release Helm do Mural."
  type        = string
  default     = "mural"
}

variable "host" {
  description = "Host do Ingress."
  type        = string
  default     = "mural.localtest.me"
}

variable "traefik_chart_version" {
  description = "Versão do chart traefik/traefik."
  type        = string
  default     = "41.5.0"
}

variable "node_image" {
  description = "Imagem do node kind (pinada por digest)."
  type        = string
  default     = "kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f"
}

variable "kubeconfig_path" {
  description = "Onde o kind grava o kubeconfig do cluster (ignorado pelo git)."
  type        = string
  default     = null
}
