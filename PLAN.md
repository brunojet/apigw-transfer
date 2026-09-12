# apigw-transfer — Plano de implementação

Plano faseado para a PoC descrita em [SPEC.md](SPEC.md). Cada fase produz
algo verificável antes de avançar para a próxima; as questões em aberto da
seção 8 do spec devem ser resolvidas antes das fases que dependem delas
(marcado abaixo).

**Foco da rodada atual: Fases 0–3.5.** O objetivo imediato era validar um
cliente fazendo `HEAD` (tamanho do objeto) seguido de `GET`s com `Range`
(chunks) contra o endpoint do API Gateway, sem mTLS e sem autorização —
decisão explícita do usuário. Na prática, validar isso de ponta a ponta
puxou naturalmente mais duas coisas que fazem parte de qualquer cliente
de download real: o que fazer quando o objeto ainda não existe
(cache-miss) e como garantir que o arquivo baixado em chunks está
consistente — isso virou a Fase 3.5, abaixo. Fases 4 (mTLS) e 5 (token do
banco) seguem adiadas para uma rodada seguinte.

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

**Concluído.** Validado com `curl -L` (segue o redirect de cache-miss
transparentemente) e com o script `scripts/download_range.py`.

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

**Concluído.** Chunk de 8 MiB confirmado como o valor que funciona de
ponta a ponta (SPEC.md §5); `binary_media_types` como atributo nativo do
Terraform (não extensão OpenAPI) restrito aos content-types reais —
necessário não só pelo teto de payload, mas porque o coringa `["*/*"]`
também quebra o VTL usado no redirect dinâmico da Fase 3.5 (ver SPEC.md
§5). Download do objeto de ~109 MB reconstruído com checksum SHA-256
idêntico ao original, via `scripts/download_range.py`.

## Fase 3.5 — Cache-miss (fallback) e consistência do download

Não estava no plano original, mas emergiu diretamente da Fase 2/3: testar
o cliente de ponta a ponta exige responder "o que acontece se o objeto
não existir ainda" e "como sei que os chunks que concatenei formam o
arquivo certo". Ambos resolvidos sem adicionar compute no caminho de um
objeto já populado:

- **Cache-miss:** `404` no path direto vira `302` com `Location`
  dinamicamente resolvido (VTL, sem Lambda — SPEC.md §4/§7) apontando
  pra `/fallback/{key}`, servido por uma Lambda (`cmd/fallback`,
  módulo `terraform/modules/fallback_lambda/`) que busca em
  `origin/{key}` (origem simulada no mesmo bucket), popula o path
  direto, e redireciona de volta.
- **Concorrência:** lock não-bloqueante no S3 — quem perde a corrida
  recebe `202` + `Retry-After` em vez do Lambda ficar esperando; erros
  de lock que não são "já existe" (ex.: `AccessDenied` por IAM) surgem
  como erro real, não como retry silencioso (`IsLockHeld` em
  `go-infra-adapters`).
- **Consistência entre chunks:** `If-Match`/`ETag` — S3 responde `412`
  se o objeto mudou de versão no meio do download; mapeado
  explicitamente no contrato OpenAPI (sem cair no `default` como
  `200`).
- **Retomada de download interrompido:** cliente grava o `ETag` num
  sidecar (`<arquivo>.etag`); se retomar e o `ETag` bater, continua do
  byte onde parou em vez de recomeçar do zero.

Contrato completo do cliente (diagramas de sequência/fluxo, tabela
normativa) em [docs/client-behavior.md](docs/client-behavior.md).

**Critério de conclusão:** download completo (caminho feliz), download
com cache-miss (fallback aciona, popula, redireciona de volta),
concorrência (dois clientes pedindo a mesma key, um recebe 202), objeto
mudando de versão no meio do download (412, cliente aborta), e retomada
de download truncado — todos validados contra AWS real, com checksum
SHA-256 confirmado no resultado final.

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
Fase 0 ──► Fase 1 ──► Fase 2 ──► Fase 3 ──► Fase 3.5
                                                │
                    (paralelo, após Fase 3.5, se as
                     respostas da SPEC §8 chegarem antes)
                                                │
                    Fase 4 ──► Fase 5 ──► Fase 6
```

Fases 2, 3 e 3.5 não dependem de nenhuma questão em aberto e já foram
concluídas. Fases 4 e 5 estão explicitamente bloqueadas até as respostas
da seção 8 do `SPEC.md`.
