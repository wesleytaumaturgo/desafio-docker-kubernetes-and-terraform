locals {
  kubeconfig_path = coalesce(var.kubeconfig_path, "${abspath(path.module)}/.kube/config")
  app_dir         = abspath("${path.module}/../../app")

  # Tag = hash8 do conteúdo (contexto de build + Dockerfile). Muda só quando o código muda.
  api_files = [for f in sort(fileset("${local.app_dir}/api", "**")) : f if f != "api"] # app/api/api = binário local ignorado
  web_files = sort(fileset("${local.app_dir}/web", "**"))

  api_tag = substr(sha1(join("", concat(
    [for f in local.api_files : filesha1("${local.app_dir}/api/${f}")],
    [filesha1("${local.app_dir}/docker/api.Dockerfile")],
  ))), 0, 8)
  web_tag = substr(sha1(join("", concat(
    [for f in local.web_files : filesha1("${local.app_dir}/web/${f}")],
    [filesha1("${local.app_dir}/docker/web.Dockerfile")],
  ))), 0, 8)
}

# ---------------------------------------------------------------- cluster
resource "kind_cluster" "mural" {
  name            = var.cluster_name
  node_image      = var.node_image
  wait_for_ready  = true
  kubeconfig_path = local.kubeconfig_path

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }
  }
}

# Providers configurados pelos atributos do cluster (sem ler arquivo no plan).
provider "kubernetes" {
  host                   = kind_cluster.mural.endpoint
  client_certificate     = kind_cluster.mural.client_certificate
  client_key             = kind_cluster.mural.client_key
  cluster_ca_certificate = kind_cluster.mural.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.mural.endpoint
    client_certificate     = kind_cluster.mural.client_certificate
    client_key             = kind_cluster.mural.client_key
    cluster_ca_certificate = kind_cluster.mural.cluster_ca_certificate
  }
}

# ---------------------------------------------------------------- namespace
resource "kubernetes_namespace_v1" "mural" {
  metadata {
    name = var.namespace
  }
}

# ---------------------------------------------------------------- ingress
# Traefik exposto por hostPort no node com ingress-ready=true (sem LoadBalancer no kind).
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true
  wait             = true

  set = [
    { name = "ports.web.hostPort", value = "80" },
    { name = "ports.websecure.hostPort", value = "443" },
    { name = "service.spec.type", value = "ClusterIP" },
    { name = "nodeSelector.ingress-ready", value = "true", type = "string" },
    { name = "ingressClass.enabled", value = "true" },
    { name = "ingressClass.isDefaultClass", value = "true" },
    { name = "ingressClass.name", value = "traefik" },
  ]
}

# ---------------------------------------------------------------- imagens
# Build no Docker do host + carga no containerd do node. Recria quando o conteúdo
# muda ou quando o cluster é recriado (cluster novo não tem as imagens).
resource "terraform_data" "image_api" {
  input            = { tag = local.api_tag, app_dir = local.app_dir, cluster = var.cluster_name }
  triggers_replace = [local.api_tag, kind_cluster.mural.id]
  depends_on       = [kind_cluster.mural]

  provisioner "local-exec" {
    command = "docker build -t mural-api:${self.input.tag} -f ${self.input.app_dir}/docker/api.Dockerfile ${self.input.app_dir}/api && kind load docker-image mural-api:${self.input.tag} --name ${self.input.cluster}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "docker rmi -f mural-api:${self.input.tag}"
  }
}

resource "terraform_data" "image_web" {
  input            = { tag = local.web_tag, app_dir = local.app_dir, cluster = var.cluster_name }
  triggers_replace = [local.web_tag, kind_cluster.mural.id]
  depends_on       = [kind_cluster.mural]

  provisioner "local-exec" {
    command = "docker build -t mural-web:${self.input.tag} -f ${self.input.app_dir}/docker/web.Dockerfile ${self.input.app_dir}/web && kind load docker-image mural-web:${self.input.tag} --name ${self.input.cluster}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "docker rmi -f mural-web:${self.input.tag}"
  }
}

# ---------------------------------------------------------------- credencial
# Gerada aqui, entregue ao chart só por set_sensitive; alfanumérica porque entra na DATABASE_URL.
resource "random_password" "db" {
  length  = 24
  special = false
}

# ---------------------------------------------------------------- Mural
resource "helm_release" "mural" {
  name             = var.release
  chart            = "${path.module}/../helm/mural"
  namespace        = kubernetes_namespace_v1.mural.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  set = [
    { name = "api.image.tag", value = terraform_data.image_api.output.tag },
    { name = "web.image.tag", value = terraform_data.image_web.output.tag },
    { name = "ingress.host", value = var.host },
    { name = "ingress.className", value = "traefik" },
  ]

  set_sensitive = [
    { name = "db.password", value = random_password.db.result },
  ]

  depends_on = [helm_release.traefik, terraform_data.image_api, terraform_data.image_web]
}
