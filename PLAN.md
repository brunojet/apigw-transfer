# apigw-transfer — Plano de implementação

Plano faseado para a PoC descrita em [SPEC.md](SPEC.md). Cada fase produz
algo verificável antes de avançar para a próxima; as questões em aberto da
seção 8 do spec devem ser resolvidas antes das fases que dependem delas
(marcado abaixo).

**Foco da rodada atual: Fases 0–3.** O objetivo imediato é validar um
cliente fazendo `HEAD` (tamanho do objeto) seguido de `GET`s com `Range`
(chunks) contra o endpoint do API Gateway, sem mTLS e sem autorização —
decisão explícita do usuário. Fases 4 (mTLS) e 5 (token do banco) ficam
adiadas para uma rodada seguinte.

## Fase 0 — Scaffold do repositório

Segue o padrão de IaC já validado em `go-edge-cache` (ver SPEC.md §7 e
memória de projeto `infra_pattern_go_edge_cache.md`), adaptado para API
Gateway + S3 Service Proxy em vez de CloudFront + Lambda:

- `terraform/` — módulo raiz: `main.tf` (provider + `data
  "aws_caller_identity"` + chamadas de módulo), `variables.tf`,
  `outputs.tf`, `backend.tf` (state remoto em S3, reaproveitando o bucket
  `brunojet-tfstate` já usado pelo `go-edge-cache`: `key =
  "apigw-transfer/terraform.tfstate"`, `region = "us-east-1"`, `encrypt =
  true`).
- `terraform/modules/<concern>/` — um módulo por serviço (ex.:
  `apigw_s3_proxy` para a REST API + integração Service Proxy, `iam_role`
  reaproveitável). Cada módulo com `main.tf`/`variables.tf`/`outputs.tf` e
  toggles via `count = var.create ? 1 : 0` (mesmo padrão de
  `enable_lambda`/`enable_xray` do `go-edge-cache`) para as features que só
  entram nas fases seguintes (mTLS, authorizer).
- `env/<dev|staging|prod>/terraform.tfvars` — um arquivo por ambiente,
  commitado (sem segredos). Para esta PoC, só `env/dev/` é necessário por
  ora.
- `bootstrap/` — reservado para passos pré-`terraform apply`, caso a Fase 4
  (mTLS) precise provisionar a CA/truststore fora do Terraform antes do
  `apply` (padrão igual ao `bootstrap/provision-cf-keys.py` do
  `go-edge-cache`) — vazio até lá.
- `docs/` e `scripts/` (se necessário para testes manuais).
- `.gitignore` (Terraform state, `.terraform/`, `*.tfvars.json`,
  credenciais locais).
- `README.md` apontando para `SPEC.md` e `PLAN.md`.

**Critério de conclusão:** `terraform init` roda sem erro (mesmo sem
recursos ainda).

## Fase 1 — S3 de teste

- **Decidido:** reaproveitar o bucket já existente `brunojet-media-proxy-dev`
  (`arn:aws:s3:::brunojet-media-proxy-dev`), mesmo bucket usado no PoC do
  `go-infra-adapters`/`media-proxy` — sem criar bucket novo.
- Referenciar via Terraform `data "aws_s3_bucket"` (não criação), sem tocar
  na configuração existente do bucket (compartilhado com o `media-proxy`).
- IAM role da API Gateway escopada só ao objeto de teste no bucket
  (`s3:GetObject`/`s3:HeadObject`), não ao prefixo `/cdn` usado pelo
  `media-proxy`.

**Critério de conclusão:** `terraform plan` mostra o bucket/objeto de teste
acessível via data source.

## Fase 2 — API Gateway → S3, sem auth (spike)

- REST API com integração **AWS Service Proxy** (não Lambda) para:
  - `GET /{key+}` → `s3:GetObject`, repassando o header `Range` da
    requisição de entrada para a integração, e devolvendo `Content-Range`
    e status (`200`/`206`) na resposta.
  - `HEAD /{key+}` → `s3:HeadObject` (ou `GetObject` com
    range vazio, o que for mais direto na integração), para o cliente
    descobrir o tamanho total.
- IAM Role de execução do API Gateway com `s3:GetObject`/`s3:HeadObject`
  escopado ao bucket da Fase 1.
- **Sem mTLS e sem autorização ainda** — endpoint aberto só para validar a
  mecânica da integração Service Proxy + mapping templates.

**Critério de conclusão:** `curl` com `Range` manual contra o endpoint do
API Gateway devolve o chunk esperado com `Content-Range` correto.

## Fase 3 — Validar o teto de payload na prática

- Repetir o download do objeto de ~109 MB em chunks de 8 MB (mesma lógica
  do `cmd/s3_range_download` do `go-infra-adapters`) através do endpoint
  da Fase 2, primeiro **sem** binary media types configurados, depois
  **com**.
- Registrar o teto real observado em cada configuração (SPEC.md estimou
  ~7.5 MB sem binary media types, ~10 MB com — confirmar ou corrigir).
- Ajustar o `main.go` do PoC do `go-infra-adapters` (ou uma cópia local
  simples aqui) para apontar pro endpoint do API Gateway em vez de ir
  direto ao S3, reaproveitando a mesma lógica de chunking/clamping do
  último byte.

**Critério de conclusão:** documento atualizado com o teto real de bytes
por chunk para essa integração, e download completo do objeto de teste
reconstruído byte-a-byte igual ao original (comparação de tamanho e,
idealmente, checksum).

## Fase 4 — mTLS *(adiada — fora do escopo desta rodada; também bloqueada por SPEC.md §8 — emissão da CA)*

- Custom domain no API Gateway com mTLS habilitado.
- Truststore em S3 com o certificado/CA definido pelo banco (ou uma CA de
  teste própria, se a definitiva ainda não estiver disponível — deixar
  isso explícito na PoC).
- Repetir o teste da Fase 3 exigindo certificado de cliente.

**Critério de conclusão:** requisição sem certificado de cliente é
rejeitada na camada TLS; requisição com certificado válido funciona como
na Fase 3.

## Fase 5 — Token do banco *(adiada — fora do escopo desta rodada; também bloqueada por SPEC.md §8 — formato do token)*

- Dependendo da resposta à questão em aberto:
  - Se JWT padrão → configurar JWT Authorizer nativo do API Gateway (sem
    compute adicional).
  - Se validação custom → Lambda authorizer (compute só na
    autenticação, não no caminho do binário — ainda alinhado ao
    objetivo da PoC).
- Testar: token ausente/inválido → `401`/`403`; token válido → segue para
  o S3.

**Critério de conclusão:** fluxo completo (mTLS + token + range download)
funcionando de ponta a ponta.

## Fase 6 — Documentação final

- Atualizar `SPEC.md` com os achados reais das Fases 3–5 (tetos de
  payload confirmados, mecanismo de auth definido).
- Diagrama de arquitetura final (mesmo estilo do documento
  `arquitetura-cloudfront-media-proxy.docx.md` do `go-infra-adapters`, para
  facilitar comparação lado a lado com o `media-proxy` existente).
- Seção de decisão: manter como PoC, propor substituição do `media-proxy`,
  ou operar os dois em paralelo para casos de uso diferentes.

## Ordem de dependências

```
Fase 0 ──► Fase 1 ──► Fase 2 ──► Fase 3
                                    │
                    (paralelo, após Fase 2, se as
                     respostas da SPEC §8 chegarem antes)
                                    │
                    Fase 4 ──► Fase 5 ──► Fase 6
```

Fases 2 e 3 não dependem de nenhuma questão em aberto e podem começar
imediatamente. Fases 4 e 5 estão explicitamente bloqueadas até as
respostas da seção 8 do `SPEC.md`.
