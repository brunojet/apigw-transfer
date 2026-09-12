# apigw-transfer — Plano de implementação

Plano faseado para a PoC descrita em [SPEC.md](SPEC.md). Cada fase produz
algo verificável antes de avançar para a próxima; as questões em aberto da
seção 7 do spec devem ser resolvidas antes das fases que dependem delas
(marcado abaixo).

## Fase 0 — Scaffold do repositório

- Estrutura de diretórios: `terraform/` (IaC, seguindo o padrão já usado em
  `lambda-repo-template`), `docs/`, `scripts/` (se necessário para testes
  manuais).
- `terraform/backend.tf`, `variables.tf`, `outputs.tf`, `main.tf` — mesmo
  esqueleto do `lambda-repo-template`.
- `.gitignore` (Terraform state, `.terraform/`, credenciais locais).
- `README.md` apontando para `SPEC.md` e `PLAN.md`.

**Critério de conclusão:** `terraform init` roda sem erro (mesmo sem
recursos ainda).

## Fase 1 — S3 de teste

- Reaproveitar o bucket `brunojet-media-proxy-dev` (já contém o objeto de
  ~109 MB usado na PoC do `go-infra-adapters`) ou criar um bucket novo
  dedicado a esta PoC — decidir e documentar a escolha aqui.
- Confirmar via Terraform (data source, não criação) as permissões
  necessárias, sem tocar no bucket existente do `media-proxy` se ele for
  compartilhado.

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

## Fase 4 — mTLS *(bloqueada por SPEC.md §7 — emissão da CA)*

- Custom domain no API Gateway com mTLS habilitado.
- Truststore em S3 com o certificado/CA definido pelo banco (ou uma CA de
  teste própria, se a definitiva ainda não estiver disponível — deixar
  isso explícito na PoC).
- Repetir o teste da Fase 3 exigindo certificado de cliente.

**Critério de conclusão:** requisição sem certificado de cliente é
rejeitada na camada TLS; requisição com certificado válido funciona como
na Fase 3.

## Fase 5 — Token do banco *(bloqueada por SPEC.md §7 — formato do token)*

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
                     respostas da SPEC §7 chegarem antes)
                                    │
                    Fase 4 ──► Fase 5 ──► Fase 6
```

Fases 2 e 3 não dependem de nenhuma questão em aberto e podem começar
imediatamente. Fases 4 e 5 estão explicitamente bloqueadas até as
respostas da seção 7 do `SPEC.md`.
