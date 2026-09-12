# Mural de Recados: do compose ao cluster com Terraform

O enunciado original está em `git show a7f29ae:README.md`.

## O que é esta entrega

O Mural tem 4 serviços: `db` (Postgres), `migrate` (aplica as migrations), `api` (Go) e `web` (nginx servindo o front e fazendo proxy de `/api`). A entrega leva essa app por quatro etapas, sem alterar `app/api` nem `app/web`:

1. **`docker-compose.yml`**: ambiente de desenvolvimento com os 4 serviços e as dependências de saúde.
2. **`app/docker/`**: `api.Dockerfile` (multi-stage, imagem final distroless) e `web.Dockerfile` (nginx com proxy parametrizável).
3. **`infra/helm/mural/`**: chart com Postgres em StatefulSet+PVC, Secret, ConfigMaps, Job de migração, Deployments, Services e Ingress.
4. **`infra/terraform/`**: um `apply` cria o cluster kind, builda e carrega as imagens, instala o Traefik e aplica o chart no namespace `mural`.

## Pré-requisitos

| ferramenta | versão usada |
|---|---|
| docker | builder legado (sem buildx) funciona |
| kind | v0.33.0 |
| kubectl | v1.37.0 |
| helm | v4.3.0 |
| terraform | 1.16.2 (`required_version = ">= 1.16"`) |

Portas 80 e 443 do host livres: o Traefik escuta nelas via `hostPort`.

**Versão do Kubernetes.** O provider `tehcyx/kind` (`~> 0.11`, a versão mais recente é a 0.11.0) embute a biblioteca do kind v0.31.0 e não sobe o node padrão do kind CLI v0.33.0 (`kubeadm init` falha). Por isso o cluster criado pelo Terraform usa **k8s v1.35.0**, com a imagem pinada por digest:

```
kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f
```

Com `kubectl` v1.37.0 o cliente avisa `version difference … exceeds the supported minor version skew of +/-1`. É só um aviso; nenhum comando abaixo falha por isso.

## Como rodar

### Cluster completo (Terraform)

```bash
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform apply -auto-approve
```

O primeiro `apply` cria 7 recursos: `kind_cluster`, `kubernetes_namespace_v1`, `helm_release` do Traefik, dois `terraform_data` (build e carga das imagens), `random_password` e `helm_release` do Mural. O `wait` do Helm só termina quando a API fica `Ready`, ou seja, depois da migração.

Conferência:

```bash
KUBECONFIG=infra/terraform/.kube/config kubectl -n mural get pods,job,ingress
curl --resolve mural.localtest.me:80:127.0.0.1 http://mural.localtest.me/
curl --resolve mural.localtest.me:80:127.0.0.1 http://mural.localtest.me/api/messages
```

Esperado: pods `api`, `web` e `postgres-0` em `1/1 Running`, Job `mural-migrate-<hash>` `Complete`, front `200`, API `200` com 1 recado (o seed).

O `--resolve` força `mural.localtest.me` para `127.0.0.1` sem depender do DNS. Se o DNS da sua máquina resolver `localtest.me` para `127.0.0.1`, dá para abrir `http://mural.localtest.me/` direto no navegador ou usar o `curl` sem `--resolve`.

**Idempotência.** Um segundo `apply` dá `0 added, 0 changed, 0 destroyed` e nenhum pod é recriado:

```bash
terraform -chdir=infra/terraform apply -auto-approve
terraform -chdir=infra/terraform plan -detailed-exitcode   # rc 0 = nada a fazer
```

**Rollout por mudança de código.** A tag da imagem é o hash do conteúdo. Ao alterar um arquivo de `app/web`, o `plan` sai com rc 2 e mostra só `terraform_data.image_web` sendo substituído e `helm_release.mural` atualizado in-place (`Plan: 1 to add, 1 to change, 1 to destroy.`). A imagem da API não é tocada.

**Destroy.**

```bash
terraform -chdir=infra/terraform destroy -auto-approve
```

Remove os 7 recursos, apaga as tags de imagem criadas pelo `apply` (`docker rmi`) e libera as portas 80/443. Veja em [Limitações](#limitações) o que fica no disco.

### Desenvolvimento (compose)

```bash
cp .env.example .env        # troque POSTGRES_PASSWORD
docker compose up -d
# front em http://localhost:8080
```

## Decisões de arquitetura

- **Migração como Job regular, não hook.** O `helm_release` espera os recursos ficarem prontos (`wait = true`). Um hook `post-install` só rodaria depois dessa espera, mas a API nunca fica pronta sem o schema: deadlock. Um hook `pre-install` rodaria antes de o Postgres existir. O Job é um recurso comum do chart, com um initContainer que espera o Postgres (`pg_isready`). O nome leva o hash do ConfigMap das migrations (`mural-migrate-<hash8>`), então só é recriado quando as migrations mudam; um `upgrade` sem mudança não o toca. As migrations são idempotentes.
- **Senha gerada pelo Terraform.** `random_password` (24 caracteres alfanuméricos, porque ela entra na `DATABASE_URL`) é entregue ao chart por `set_sensitive`. O `values.yaml` versionado tem `db.password: ""`, e o template usa `required`: renderizar sem senha falha. A credencial só existe no Secret `mural-db`.
- **Traefik com hostPort.** Chart `traefik/traefik` 41.5.0 com `ports.web.hostPort=80`, `ports.websecure.hostPort=443`, `service.spec.type=ClusterIP` e `nodeSelector.ingress-ready="true"`. No kind não há LoadBalancer (o Service ficaria `pending`); o node publica 80/443 via `extraPortMappings`. A chave do chart é `service.spec.type`; `service.type` é ignorada sem erro.
- **Imagens por hash de conteúdo.** Um `terraform_data` por imagem roda `docker build` e `kind load docker-image`. A tag é o hash de 8 caracteres dos arquivos do contexto mais o Dockerfile; `triggers_replace` usa esse hash e o id do cluster (cluster recriado recarrega as imagens). `imagePullPolicy: IfNotPresent`, porque a imagem existe só no node.
- **API em distroless nonroot.** Build com `CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w'`; imagem final `gcr.io/distroless/static-debian12:nonroot`, `USER 65532:65532`. Sem shell; o pod roda com `runAsNonRoot: true` e `runAsUser: 65532`.
- **Providers pelos atributos do cluster.** `helm` e `kubernetes` usam `endpoint`, `client_certificate`, `client_key` e `cluster_ca_certificate` do `kind_cluster`, sem ler arquivo de kubeconfig no `plan`. `kubernetes_manifest` não é usado, porque exige o cluster já no `plan`.
- **Namespace pelo provider kubernetes.** `kubernetes_namespace_v1` cria `mural`; o release usa `create_namespace = false`, e o destroy remove o release antes do namespace.
- **Probes.** API: liveness em `/healthz` (não toca o banco), readiness em `/readyz` (banco + tabela), com `failureThreshold: 30` e `periodSeconds: 5` para cobrir a janela da migração. Liveness em `/readyz` derrubaria o pod em loop durante a migração. Front: `/` nas duas. Postgres: `pg_isready` nas duas.
- **Resources.** Todo container e initContainer do chart tem requests e limits:

| workload | requests (cpu/mem) | limits (cpu/mem) |
|---|---|---|
| api | 50m / 64Mi | 200m / 128Mi |
| web | 20m / 32Mi | 100m / 64Mi |
| postgres | 100m / 128Mi | 500m / 512Mi |
| migrate (e `wait-db`) | 50m / 64Mi | 200m / 128Mi |

## Tamanho da imagem da API

| | imagem | `docker images` | bytes |
|---|---|---|---|
| antes | `golang:1.23-alpine` (o que o compose usa com `go run`) | 246MB | 246135626 |
| depois | `mural-api` sobre `gcr.io/distroless/static-debian12:nonroot` | 11.5MB | 11493970 |

Redução de 95,3%. O "antes" foi medido sobre `golang:1.23-alpine`; a `golang:1.23` completa não foi puxada. O front (`mural-web`) fica em 48.3MB, praticamente a base `nginx:1.27-alpine` (48.2MB).

## Estrutura

```
app/docker/api.Dockerfile      multi-stage → distroless nonroot
app/docker/web.Dockerfile      nginx:1.27-alpine + template com API_UPSTREAM
docker-compose.yml             db, migrate, api, web (dev)
.env.example                   variáveis do compose
infra/helm/mural/
  Chart.yaml, values.yaml      imagens mural-api/mural-web, host, resources, db.password vazio
  files/migrations/            001_init.sql, 002_seed.sql
  templates/                   _helpers.tpl, secret, migrations-configmap, postgres,
                               migrate-job, api, web, ingress
infra/terraform/
  versions.tf                  kind ~> 0.11 · helm ~> 3.3 · kubernetes ~> 3.2 · random ~> 3.9
  variables.tf                 cluster_name, namespace, release, host, traefik_chart_version, node_image
  main.tf                      cluster, providers, namespace, Traefik, imagens, senha, release
  outputs.tf                   cluster_name, kubeconfig_path, url, curl_hint
```

Valores padrão em `variables.tf`: cluster `mural`, namespace `mural`, release `mural`, host `mural.localtest.me`, Traefik `41.5.0`.

## Limitações

- **Kubernetes v1.35.0, não v1.37.** O provider `tehcyx/kind` 0.11.0 é a versão mais recente e embute o kind v0.31.0. O kind CLI v0.33.0 sobe v1.37.0, mas o provider não. O `kubectl` v1.37.0 avisa de skew.
- **State local com a senha.** `infra/terraform/terraform.tfstate` e `terraform.tfstate.backup` guardam a senha gerada em claro e continuam no disco depois do `destroy`. São ignorados pelo git. Um `taint` isolado no `random_password` gera senha nova no Secret, mas o Postgres já inicializado mantém a antiga.
- **Kubeconfig residual.** `infra/terraform/.kube/config` sobra após o `destroy` como arquivo vazio de 28 bytes (`apiVersion: v1` / `kind: Config`, sem credenciais). Ignorado pelo git. O `~/.kube/config` do usuário não é tocado.
- **Imagens com o mesmo conteúdo.** O `destroy` roda `docker rmi -f` nas tags por hash. Se existir outra tag da mesma imagem (por exemplo, `mural-api:b3` e `mural-web:b3` de um build manual), o `rmi` só remove a tag e as camadas ficam.
- **Cache de build e imagens base.** Camadas intermediárias e as bases (`golang:1.23-alpine`, `gcr.io/distroless/static-debian12:nonroot`, `nginx:1.27-alpine`) ficam no Docker do host. O Terraform não roda `docker builder prune`, que apagaria cache de outros projetos.
- **Lock dos providers fora do git.** `.terraform.lock.hcl` é ignorado pelo `.gitignore` do repositório-base; as versões são pinadas com `~>` em `versions.tf`.
- **Job em vez de hook.** `docs/arquitetura.md` desenha a migração como "hook Helm"; o enunciado aceita "Job/hook". Aqui é Job regular, pelo deadlock descrito em [Decisões](#decisões-de-arquitetura).
- **Traefik sem limits próprios.** O Traefik usa os requests/limits padrão do chart; requests e limits explícitos cobrem os workloads do Mural.
- **`wait` do Helm e o Job.** O `wait` do Helm 4 não espera o Job concluir. Quem segura o `apply` até a migração terminar é a readiness da API (`/readyz`).

## Como verificar

Depois do `destroy`, nada do cluster fica de pé:

```bash
kind get clusters                                   # No kind clusters found.
docker ps -a --format '{{.Names}}' | grep -c mural  # 0
ss -ltn | grep -E ':(80|443) '                      # vazio
```

O que fica no disco e como limpar à mão:

```bash
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^mural-'
docker rmi mural-api:b3 mural-web:b3                 # só se existirem tags manuais
rm infra/terraform/terraform.tfstate*               # contém a senha gerada
rm -r infra/terraform/.kube                         # kubeconfig vazio
```
