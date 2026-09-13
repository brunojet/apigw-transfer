# apigw-transfer — Especificação

Proxy de download de arquivos privados do S3 via Amazon API Gateway, sem
aplicação/compute no caminho de dados, respeitando o único padrão de
exposição de arquivos privados oficialmente aceito no conglomerado:
**API Gateway com mTLS e token de acesso governado pelo banco**.

## 1. Motivação

O padrão hoje usado no projeto `media-proxy` (CloudFront + Signed URLs,
ver `arquitetura-cloudfront-media-proxy.docx.md` no repo `go-infra-adapters`)
não é oficialmente aceito pelo conglomerado como mecanismo de controle de
acesso a arquivos privados — apesar de tecnicamente funcional. O único
padrão aprovado para exposição de arquivos privados à internet é API
Gateway com mTLS + token do banco, o mesmo padrão já usado para as demais
APIs expostas.

**Objetivo desta PoC:** provar que dá para servir arquivos grandes do S3
(dezenas a centenas de MB) através desse padrão aprovado, sem precisar de
Lambda/aplicação no caminho de transferência do binário — só na camada de
autenticação/autorização, que já é custo aceito e existente.

> **Nota:** este documento assume que "API Gateway com mTLS e token do
> banco" descreve a autenticação na borda (mTLS de client certificate +
> validação de um token emitido pelo banco). Os detalhes exatos de como
> esse token é validado (formato, emissor, TTL) não foram especificados
> ainda — ver seção 8 (Questões em aberto).

## 2. Escopo

**Dentro do escopo (rodada atual):**
- Leitura (download) de um objeto S3 já existente, em ranges de bytes.
- Descoberta do tamanho total do objeto (equivalente a `HeadObject`), via
  `HEAD` feito pelo cliente.
- Cliente solicitando `HEAD` (tamanho) e depois `GET`s com `Range` (chunks)
  contra o endpoint do API Gateway — **este é o objetivo principal desta
  rodada**: validar a mecânica do proxy (API Gateway → S3 Service Proxy)
  de ponta a ponta, sem autenticação na borda ainda.
- Validação prática dos limites de payload do API Gateway (10 MB de
  resposta, sem truncamento gracioso — ver seção 5) usando o mesmo objeto
  de teste de ~109 MB já usado na PoC do `go-infra-adapters`
  (`s3://brunojet-media-proxy-dev/servicenow-zurich-platform-security-ptbr.pdf`).
- **Cache-miss com fallback para uma origem simulada:** se o objeto não
  existir ainda no path direto, o servidor responde `302` com um
  `Location` dinâmico (montado via VTL, sem Lambda no caminho de dados
  ainda) apontando para `/fallback/{key}`; esse endpoint (agora sim, com
  Lambda) busca o objeto de um prefixo `origin/` no mesmo bucket, copia
  pro path direto e redireciona de volta — simula uma origem real sem
  provisionar infraestrutura extra. Ver detalhes em
  [docs/client-behavior.md](docs/client-behavior.md).
- **Consistência entre chunks e retomada de download interrompido:** o
  cliente usa `If-Match`/`ETag` pra garantir que todos os chunks vêm da
  mesma versão do objeto (o S3 responde `412` se o objeto mudou no meio
  do download), e grava o `ETag` num sidecar pra poder retomar um
  download parcial em vez de recomeçar do zero.

**Fora do escopo (por ora):**
- **mTLS e validação de token do banco.** Adiados para uma rodada
  seguinte (PLAN.md Fases 4 e 5) — decisão explícita do usuário. O
  endpoint desta rodada roda **sem nenhuma autenticação na borda**; a
  seção 1 (Motivação) e o restante deste documento descrevem o *padrão
  aprovado* de destino (mTLS + token), mas ele não faz parte do que está
  sendo testado agora.
- Upload de arquivos (`PutObject`) através do gateway.
- Cache do lado do gateway/CDN (o S3 já é a fonte da verdade; sem camada
  de cache adicional nesta PoC).
- Migração ou descomissionamento do `media-proxy` (CloudFront) existente —
  este projeto é uma PoC paralela, não uma substituição decidida.
- Multi-range em uma única requisição (o S3 não suporta múltiplos ranges
  por `GetObject`; cada chunk é uma requisição HTTP separada).

## 3. Componentes propostos

| Componente | Serviço AWS | Responsabilidade |
| :---- | :---- | :---- |
| Ponto de entrada | API Gateway (REST API) | Recebe requisição e repassa pro S3 (sem auth na borda nesta rodada — ver seção 2) |
| Integração | AWS Service Proxy (não-Lambda) | Traduz a requisição HTTP em `GetObject`/`HeadObject` no S3, repassando `Range` |
| Armazenamento | Amazon S3 (privado) | Bucket já existente `brunojet-media-proxy-dev` (`arn:aws:s3:::brunojet-media-proxy-dev`), reaproveitado do PoC do `go-infra-adapters`/`media-proxy` — sem criação de bucket novo |
| Autenticação de transporte *(adiado)* | mTLS (custom domain + truststore) | Padrão de destino aprovado — fora do escopo desta rodada (PLAN.md Fase 4) |
| Autorização *(adiado)* | Token do banco (mecanismo a confirmar — seção 8) | Padrão de destino aprovado — fora do escopo desta rodada (PLAN.md Fase 5) |
| Permissão de acesso ao S3 | IAM Role de execução do API Gateway | `s3:GetObject`/`s3:HeadObject` escopado ao objeto de teste no bucket reaproveitado (não ao prefixo `/cdn` usado pelo `media-proxy`) |
| Cache-miss (fallback) | AWS Lambda (`cmd/fallback`) | Só entra em ação quando o objeto ainda não existe no path direto: busca em `origin/{key}` (origem simulada no mesmo bucket), copia pro path direto e redireciona de volta — não fica no caminho de dados de um objeto já populado |
| Origem simulada | Amazon S3 (mesmo bucket, prefixo `origin/`) | Substitui uma origem externa real pra fins de PoC — sem provisionar infraestrutura adicional |

Diferença chave em relação ao `media-proxy` atual: **não há Lambda nem
cache intermediário no caminho do binário** — o API Gateway fala
diretamente com o S3 para cada requisição.

## 4. Fluxo de requisição

Fluxo testado nesta rodada (sem mTLS/token — ver seção 2):

```
Cliente
  ▼
API Gateway (endpoint padrão, sem auth na borda)
  ▼
Integração AWS Service Proxy → S3
  │  1. HEAD /{bucket}/{key}          → tamanho total do objeto
  │  2. GET /{bucket}/{key}, Range: bytes=X-Y  → chunk pedido
  ▼
S3 responde 206 Partial Content + Content-Range
  ▼
API Gateway repassa a resposta ao cliente (binário, sem base64 se
binary media types estiver configurado)
```

**Cache-miss (objeto ainda não existe no path direto):** o `HEAD`/`GET`
inicial responde `404` do S3, e o API Gateway converte isso em `302` com
um `Location` **já resolvido com a key real** (montado via VTL —
`$context.responseOverride.header.Location`, ver §7) apontando para
`/fallback/{key}`. Esse segundo endpoint é servido por uma Lambda
(`cmd/fallback`) que busca o objeto em `origin/{key}` (origem simulada no
mesmo bucket), copia pro path direto, e responde outro `302` de volta pro
path original — que agora responde `200`/`206` normalmente. Concorrência
é tratada com um lock não-bloqueante no S3: quem chega e encontra o lock
já tomado recebe `202 Accepted` + `Retry-After` em vez de esperar (ver
§6). Diagramas de sequência completos (caminho feliz, cache-miss,
concorrência) e a tabela normativa de comportamento do cliente estão em
[docs/client-behavior.md](docs/client-behavior.md) — não repetidos aqui.

**Consistência entre chunks:** o cliente envia `If-Match: <etag>` (do
`HEAD` inicial) em todo `GET` com `Range`; se o objeto mudar de versão no
meio do download, o S3 responde `412 Precondition Failed` e o servidor
repassa isso sem mascarar como `200` — o cliente trata como erro
permanente pro download em andamento (recomeça do zero com um novo
`HEAD`). Ver §6 e docs/client-behavior.md §6.

Fluxo de destino (produção, com mTLS + token — PLAN.md Fases 4-5, fora do
escopo desta rodada):

```
Cliente
  │  1. TLS handshake com certificado de cliente (mTLS)
  ▼
API Gateway (custom domain, mTLS habilitado)
  │  2. Valida certificado contra o truststore
  │  3. Autorizador valida o token do banco
  ▼
Integração AWS Service Proxy → S3
  │  4. HEAD /{bucket}/{key}          → tamanho total do objeto
  │  5. GET /{bucket}/{key}, Range: bytes=X-Y  → chunk pedido
  ▼
S3 responde 206 Partial Content + Content-Range
  ▼
API Gateway repassa a resposta ao cliente
```

O cliente é responsável por:
1. Fazer `HEAD` primeiro para descobrir o tamanho total.
2. Sempre pedir em ranges limitados (nunca um `GET` sem `Range` para
   objetos que podem ultrapassar o teto de payload — ver seção 5).
3. Repetir o passo 2 até cobrir o objeto inteiro.

Esse é exatamente o padrão já implementado e validado do lado cliente em
`go-infra-adapters` (branch `feature/storage-ranges`,
`pkg/storage/contracts.BucketObject.Range`/`ContentRange`, PoC
`cmd/s3_range_download`).

## 5. Limite de payload — achado crítico

O API Gateway (REST API) tem um teto **rígido** de 10 MB por corpo de
resposta, que **não pode ser aumentado**. Ultrapassar esse limite não
resulta em uma resposta parcial "amigável" — a requisição falha (tipicamente
`502 Bad Gateway` ou corpo truncado/inválido). Não existe modo
"entrega o que der e avisa que falta o resto".

Se a integração não tiver **binary media types** configurados, o corpo
binário do S3 é convertido para base64 antes de retornar ao cliente, o que
infla o payload em ~33%. Isso reduz o teto prático de bytes por chunk para
~7.5 MB (não 10 MB), a menos que os binary media types estejam
corretamente configurados na API.

**Implicação de design:** o range solicitado por chunk (do lado do
servidor, imposto ou apenas documentado?) precisa ficar com folga desse
teto. A PoC deve validar o comportamento real com um chunk de 8 MB (mesmo
tamanho já usado no PoC do `go-infra-adapters`) tanto com quanto sem
binary media types configurados, para confirmar o teto efetivo na prática.

**Confirmado na prática:** chunk de 8 MiB validado ponta a ponta com o
objeto de teste real (~109 MB), reconstruído com checksum SHA-256
idêntico ao original, com `binary_media_types` corretamente restrito aos
content-types reais servidos (não `["*/*"]` — ver achado abaixo).

**Achado adicional — `binary_media_types = ["*/*"]` quebra qualquer
`responseTemplates` (VTL):** com o coringa, o API Gateway passa a tratar
**toda** resposta da integração como binária — inclusive o corpo XML de
erro que o S3 devolve num `404`/`412`. VTL não consegue transformar
conteúdo binário (`Execution failed due to configuration error: Unable
to transform response`, só visível com CloudWatch Logs habilitado na
stage). Isso quebrou silenciosamente o redirect dinâmico do cache-miss
(§4) até restringir `binary_media_types` aos content-types reais do
proxy. Ver `env/dev/terraform.tfvars` e memória de projeto para o
histórico completo do diagnóstico.

**Achado adicional — compressão (gzip) do API Gateway, habilitada como
opt-in (`minimum_compression_size = 8192`):** `Range`/`Content-Encoding`
operam em **camadas diferentes e independentes**, e é importante isolar
isso pra não confundir os dois:

- **Camada do range (seleção):** decide *quais bytes* do objeto
  original (tal como armazenado no S3) fazem parte desta resposta. É
  resolvida no `GetObject`, antes de qualquer coisa relacionada a
  transporte. `Content-Range: bytes X-Y/Z` descreve sempre essa posição
  no arquivo original — nunca muda, com ou sem compressão.
- **Camada de transporte (codificação):** decide *como* os bytes já
  selecionados pela camada acima trafegam na rede entre servidor e
  cliente. `Content-Encoding: gzip`, se estivesse ativo, comprimiria só
  essa transmissão — é revertido inteiramente pelo cliente antes da
  aplicação ver o corpo. `Content-Length` pertence a essa camada:
  descreve o tamanho do que foi **transmitido** (encolheria com
  compressão), não o tamanho do range em si.

Como as duas camadas são independentes, elas nunca competem: a seleção
de bytes já aconteceu antes da compressão entrar em cena, e a
descompressão desfaz a camada de transporte antes da aplicação
concatenar os blocos — não existe cenário de "bytes gzip de chunks
diferentes que precisariam ser concatenados comprimidos" (contanto que a
lib HTTP do cliente decodifique `Content-Encoding` automaticamente, como
fazem `requests`, `OkHttp` e browsers — `urllib` puro não decodifica
sozinho, mas também não manda `Accept-Encoding: gzip` por padrão, então
nem aciona a compressão nesse caso).

**Validado empiricamente contra o endpoint real** (chunk de 8MiB do PDF
de teste, `bytes=0-8388607`):

| Requisição | `Content-Encoding` | Bytes na rede | Íntegro? |
| :---- | :---- | :---- | :---- |
| sem `Accept-Encoding` | — | 8.388.608 | baseline |
| `curl --compressed` (nego­cia e descompacta sozinho) | `deflate` | 7.223.243 | ✅ MD5 idêntico ao baseline |
| `Accept-Encoding: gzip` na mão, sem descompactar | `gzip` | 7.223.255 | bytes crus (`1f 8b...`) — cliente que não decodifica recebe isto |

Correção importante em relação à suposição original deste documento: o
ganho **não é "quase zero"** — deu **~14% de redução** (8.39MB → 7.22MB).
PDF mistura streams já comprimidos com estrutura interna não comprimida
(xref, dicionários de objeto), então gzip por cima ainda captura algo.
APK continua um caso à parte: é um ZIP, e entradas armazenadas com
`STORE` (ex.: `.so` com `extractNativeLibs=false`, assets `noCompress`)
comprimiriam bem com gzip por cima, mas isso é opaco pro proxy (não
inspecionamos a estrutura interna do zip) — não muda a decisão abaixo.

O motivo real pra manter isso **opt-in** (nunca forçado) é outro, e
continua valendo com o número real: depende de **toda** lib de cliente
decodificar `Content-Encoding` corretamente. Um cliente com
implementação HTTP mínima que manda `Accept-Encoding: gzip` mas não
decodifica sozinho recebe bytes comprimidos crus e corrompe o chunk
silenciosamente, sem sinal de erro — confirmado na tabela acima e
reproduzido de forma independente com `urllib.request` puro (Python) em
[go-infra-adapters](../go-infra-adapters) (`resp.read()` devolve os
bytes gzip crus, sem descompactar). Isso vira requisito obrigatório do
contrato do cliente: só mandar `Accept-Encoding` se a lib também
decodifica `Content-Encoding` — ver `docs/client-behavior.md`.

## 6. Decisões técnicas e alternativas consideradas

| Alternativa | Avaliação |
| :---- | :---- |
| API Gateway → S3 direto (Service Proxy) | ✅ Escolhida — sem compute no caminho de dados, custo mínimo, usa o padrão de auth já aprovado |
| API Gateway → Lambda → S3 (proxy integration) | ❌ Rejeitada para o caminho de dados — adiciona compute (custo + cold start + limite de payload do Lambda, mais restritivo que o do API GW) sem benefício, já que não há transformação necessária no binário |
| CloudFront Signed URLs (padrão do `media-proxy`) | ❌ Não é o padrão aceito pelo conglomerado para exposição de arquivos privados — mantido apenas como referência de arquitetura alternativa |
| Multi-range por requisição | ❌ Não suportado pelo S3; cada range é uma requisição HTTP separada |
| Redirect dinâmico do cache-miss via VTL (`$context.responseOverride.header.Location`) | ✅ Escolhida — resolve a key real sem Lambda no caminho do `404` inicial; exige `binary_media_types` restrito (ver §5) e a base do mapeamento como referência dinâmica, não literal |
| Lambda de fallback com lock **não-bloqueante** (202 + `Retry-After`) | ✅ Escolhida — evita Lambda ocioso esperando outra invocação terminar (custo) e evita que erros de IAM/permissão (`AccessDenied`) sejam mascarados como "concorrência normal"; qualquer erro que não seja literalmente "lock já existe" vira erro real, não retry silencioso |
| Consistência entre chunks via `If-Match`/`ETag` (S3 nativo) | ✅ Escolhida — sem custo adicional (S3 já valida `If-Match` se enviado); evita concatenar bytes de versões diferentes do mesmo objeto se ele mudar no meio do download |
| Compressão (gzip) via `minimum_compression_size = 8192` | ✅ Habilitada, mas **opt-in** (só ativa se o cliente mandar `Accept-Encoding`) — validado empiricamente: ~14% de redução real, sem corromper o chunk quando o cliente decodifica `Content-Encoding` corretamente (ver §5) |

## 7. Padrão de infraestrutura (Terraform)

O scaffold do `terraform/` desta PoC segue o mesmo padrão de IaC já validado
no projeto `go-edge-cache` (referência completa em memória de projeto —
`infra_pattern_go_edge_cache.md`): módulo raiz (`main.tf`/`variables.tf`/
`outputs.tf`/`backend.tf`) + `terraform/modules/<concern>/` por serviço +
`env/<dev|staging|prod>/terraform.tfvars` commitados (sem segredos) +
backend de state em S3 (`brunojet-tfstate/apigw-transfer/terraform.tfstate`).
Detalhes ficam no [PLAN.md](PLAN.md) (Fase 0); não repetidos aqui.

**Extensão própria deste projeto (além do padrão do `go-edge-cache`):** o
contrato da REST API (paths, methods, integrações, mapeamento de
status/headers, `binaryMediaTypes`) fica separado em um documento OpenAPI
(`terraform/modules/apigw_s3_proxy/openapi.yaml.tftpl`), renderizado via
`templatefile()` e passado como `body` do `aws_api_gateway_rest_api`
(`put_rest_api_mode = "overwrite"`). O Terraform (`main.tf` do módulo) fica
só com o wrapper de infra: IAM role, a REST API em si, deployment e stage.
Motivo: o `go-edge-cache` não tem esse problema (poucos recursos, sem REST
API complexa); aqui, declarar cada `method`/`integration`/`*_response` em
HCL puro escala mal à medida que a API cresce (mTLS, authorizer, novos
paths) — um único contrato OpenAPI é mais legível e mais fácil de revisar
como "isso é o que a API faz", independente de como ela é provisionada.

## 8. Questões em aberto

Estas dependem de informação que só o time/banco pode fornecer — não foram
assumidas neste documento:

- **Formato e validação do token do banco:** é um JWT validável via JWT
  authorizer nativo do API Gateway, ou requer um Lambda authorizer
  custom (chamando um serviço do banco)? Isso define se existe *algum*
  compute no caminho, mesmo que só na autenticação.
- **Emissão/gestão do certificado mTLS:** o truststore do API Gateway
  precisa de um bucket S3 com a CA/certificados confiáveis — quem
  fornece essa CA (o banco, ou é gerada para esta PoC)?
- **Este projeto substitui o `media-proxy` ou coexiste com ele?** Se
  substituir, precisa considerar migração de clientes já integrados via
  CloudFront Signed URLs.
- **Escopo de autorização por objeto:** o token do banco carrega
  claims que restringem quais paths/buckets o chamador pode acessar, ou
  a autorização é binária (autenticado = acesso a tudo no bucket)?

## 9. Spike — clamp de range reativo no servidor (VTL)

Path isolado `GET /test-range-clamp/{key+}` (mesmo bucket/objeto de
teste, IAM já liberada) — **não usado pelo `/{key+}` de produção**. Testa
uma ideia complementar à do §4: em vez do cliente precisar saber de
antemão o tamanho de chunk "certo", o servidor **sempre** ajusta/injeta
o `Range` antes de repassar ao S3, garantindo que nenhuma resposta passe
de `range_clamp_max_chunk_bytes + 1` bytes — mesmo que o cliente peça
mais, ou não mande `Range` nenhum. O cliente só precisa saber uma coisa:
olhar `Content-Range` e continuar pedindo enquanto `end < total - 1`
(igual a qualquer download resumível padrão de mercado).

**Fora do escopo deste spike** (isolado de propósito, não é regressão):
`If-Match`/`412`, `404`→fallback, `202`/lock — a máquina completa do
`/{key+}` (ver §4/§6). Decisão de mesclar ou não com produção ainda em
aberto.

**Bug real encontrado e corrigido**, confirmado via CloudWatch Logs
(`API-Gateway-Execution-Logs_<rest-api-id>/dev`): a VTL originalmente
proposta montava o header de saída como

```
#set($context.requestOverride.header.Range = "bytes=$rangeStart-$rangeEnd")
```

Velocity aceita hífen como caractere válido de nome de referência —
`$rangeStart-` é lido como o nome de **uma** referência só
("rangeStart-", inexistente, renderiza vazio), não como `$rangeStart`
seguido do literal `-`. O log de execução mostrou o sintoma exato:

```
Request parameter overrides: Add Range: bytes=8388607
```

(faltando o `0-` do início). Como esse Range malformado não bate a
sintaxe HTTP (`bytes=<start>-<end>`), o S3 o ignorou e devolveu o objeto
inteiro (114.540.033 bytes) como `200`, e o API Gateway rejeitou a
resposta com a mensagem exata (mais precisa que a genérica do §5):

```
Execution failed due to configuration error: Integration response of
reported length 114540033 is larger than allowed maximum of 10485760
bytes.
```

Fix: delimitar a referência com chaves — `"bytes=$${rangeStart}-$${rangeEnd}"`
no `.tftpl` (o `$$` escapa o `${...}` pro Terraform não tentar
interpolar como variável dele mesmo antes de virar VTL).

Também aplicado, de forma defensiva (não era a causa raiz deste bug
específico, mas é um risco real e documentado do VTL/Velocity no API
Gateway): `$input.params('Range')` e o resultado de `.split("-")`
retornam `String`, e Velocity não converte `String` pra `Number`
automaticamente em operadores aritméticos (`$rangeStart + $maxChunk`
pode falhar ou concatenar em vez de somar). Mitigado com o padrão da
comunidade `#set($Integer = 0)` + `$Integer.parseInt(...)` antes de
qualquer conta.

**Validado empiricamente** com os 3 casos que motivaram o spike, todos
contra o objeto real de ~109MB, teto configurado em 8MiB
(`range_clamp_max_chunk_bytes = 8388607`):

| Caso | `Range` pedido | `Content-Range` devolvido | Bytes | MD5 |
| :---- | :---- | :---- | :---- | :---- |
| sem tamanho de bloco | `bytes=0-` | `bytes 0-8388607/114540033` | 8.388.608 | idêntico nos 3 |
| exatamente no teto | `bytes=0-8388607` | `bytes 0-8388607/114540033` | 8.388.608 | idêntico nos 3 |
| bem acima do teto | `bytes=0-999999999` | `bytes 0-8388607/114540033` | 8.388.608 | idêntico nos 3 |

Os três casos devolveram exatamente os mesmos bytes (MD5 igual,
cabeçalho `%PDF-1.5` intacto) — o servidor nunca deixa passar do teto,
independente do que (ou se) o cliente pede.
