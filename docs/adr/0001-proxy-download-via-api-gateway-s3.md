# ADR 0001 — Proxy de download via API Gateway direto ao S3

**Status:** Proposta (PoC validada contra AWS real) — falta aplicar a
esta API o mTLS e a validação de token já em produção para outro BFF da
organização (ver seção "O que falta").
**Data:** 2026-09-13
**Contexto do projeto:** [apigw-transfer](../../README.md) · detalhes
completos de implementação e histórico de achados em [SPEC.md](../../SPEC.md)
e [PLAN.md](../../PLAN.md).

## Contexto

A organização mantém uma loja de aplicativos baseados em ServiceNow,
totalmente customizados. Um desses aplicativos (POS) já passou por uma
migração de WebView para Android nativo + APIs REST, com um BFF que faz
a transformação entre o POS e o ServiceNow — inclusive gerenciando os
tokens do ServiceNow de forma transparente, sem expor esse detalhe ao
POS. Para esse BFF já existe em produção a infraestrutura de **API
Gateway com mTLS e token de acesso governado pelo banco** — o padrão
consolidado da organização para exposição de APIs a consumidores
externos.

O que ainda falta nesse fluxo é a **recepção de arquivos binários**
(imagens e APKs) vindos do ServiceNow através desse mesmo canal. Como o
LDM já é a peça principal do conglomerado para gestão de aplicativos,
por ora o suporte via este canal cobre só **imagens** — mas como ainda
não existe integração entre a loja de aplicativos e o LDM, o mesmo
mecanismo já resolveria a transferência de **APKs** de forma incidental,
trazendo de quebra capacidades de retomada de download e observabilidade
que esse fluxo não tem hoje.

A pergunta técnica que motivou esta PoC: dá para servir esses arquivos —
potencialmente grandes (dezenas a centenas de MB, no caso de um APK) —
através do mesmo padrão de API Gateway já em produção para esse BFF, sem
introduzir compute (Lambda/aplicação) no caminho de transferência do
binário?

## Decisão

Usar **API Gateway (REST API) com integração AWS Service Proxy direta ao
S3** — sem Lambda nem aplicação no caminho de um objeto já existente no
bucket. Três elementos centrais:

1. **Download em range sempre limitado pelo servidor.** O `GET /{key+}`
   ajusta/injeta o header `Range` antes de repassar ao S3 via uma
   transformação de requisição (VTL), garantindo que nenhuma resposta
   ultrapasse o teto rígido de payload do API Gateway (10 MB) —
   independente do que o cliente peça ou deixe de pedir. O cliente só
   precisa reagir ao `Content-Range` da resposta e continuar pedindo até
   cobrir o objeto inteiro; não precisa saber nem calcular um tamanho de
   bloco. O formato do `Range` é validado por regex (`bytes=N-` ou
   `bytes=N-M`); qualquer outro é ignorado e tratado como `bytes=0-`.
2. **Fallback assíncrono só no cache-miss, executado pelo BFF.** Quando o
   objeto ainda não existe no path direto, o servidor responde `302`
   (montado dinamicamente via VTL, sem compute nesse primeiro passo)
   apontando para `/fallback/{key}`, que aciona o fallback — a única vez
   que compute entra no caminho, e só para popular o cache, nunca para
   servir um objeto já presente. Na solução final quem executa é o
   **próprio BFF**, que já fala com o ServiceNow: ele dispara a cópia em
   background e responde `202` + `Retry-After` **a todos, inclusive a
   quem pegou o lock**. O API Gateway só recebe respostas imediatas,
   então o tamanho do arquivo e a lentidão da origem não esbarram no
   timeout de integração (29 s); quanto esperar fica a cargo do cliente.
   O lock no S3 evita cópias duplicadas; seu TTL precisa cobrir a cópia
   mais longa esperada e é o que libera a key se o processo morrer sem
   liberar o lock. Esta PoC simula o mesmo comportamento com uma Lambda
   (`cmd/fallback`) que responde `202` e executa a cópia numa
   autoinvocação assíncrona — validado contra AWS real com um objeto de
   ~109 MB (cópia em background de ~7 s, cliente recebendo `202` até o
   objeto existir, SHA-256 idêntico).
3. **Configuração via stage variables, não hardcoded no contrato.** Bucket
   alvo, teto de chunk e tempo de cache de erros ficam em variáveis do
   stage do API Gateway, não embutidas no corpo da API — ajustá-los não
   dispara um novo deployment.

## Premissas

- **Conteúdo imutável por `sys_id`.** O ServiceNow não troca o conteúdo
  de um anexo mantendo o mesmo `sys_id`: uma alteração gera outro
  registro. Com o `sys_id` na key, o objeto copiado para o S3 nunca fica
  desatualizado e não há invalidação de cache a fazer.
- **Autorização por diretório.** Na versão final, ACLs liberam
  diretórios específicos do bucket para cada consumidor. A PoC não tem
  autorização.
- **URLs assinadas não são aceitas pela política atual** (nem CloudFront
  Signed URLs nem URLs pré-assinadas do S3) — por isso o acesso passa
  sempre pelo API Gateway com mTLS e token.

## Ganhos em relação ao fluxo atual (via ServiceNow)

- **A proposta imediata é imagens — que nem exigiriam range/resume dado
  o tamanho pequeno — mas a mesma infraestrutura já está validada para
  arquivos grandes.** O objeto de teste desta PoC tem ~109 MB, na faixa
  de tamanho de um APK, e foi baixado (e retomado) de ponta a ponta sem
  nenhum trabalho de infraestrutura adicional. Ou seja: estender esse
  canal pra APKs no futuro é uma decisão de escopo, não um novo projeto
  de engenharia.
- **Retomada de download em caso de perda de conexão.** O uso nativo de
  `Range`/`Content-Range`/`If-Match` permite a um cliente interrompido
  continuar exatamente do byte onde parou, em vez de reiniciar o arquivo
  inteiro — validado tanto com o recurso nativo de resume do `curl`
  (`-C -`) quanto com o cliente de referência
  (`scripts/download_range.py`). Pouco relevante pra imagens pequenas,
  mas decisivo pra arquivos grandes (como um APK) em conectividade
  instável — hoje uma queda de conexão no meio de um download desses
  obriga a recomeçar do zero.
- **Compressão transparente ponta a ponta.** O ServiceNow também suporta
  compressão no backend, mas ela não está habilitada hoje no caminho via
  API Gateway do BFF existente — o ganho potencial fica sem uso. Nesta
  solução, `Accept-Encoding`/`Content-Encoding` funcionam de ponta a
  ponta (validado empiricamente: ~14% de redução real no objeto de
  teste), sem exigir nada do cliente além de uma lib HTTP que já suporte
  isso. Ressalva no Android: o gzip transparente padrão do OkHttp é
  desligado quando a requisição tem `Range`, então é preciso configurar o
  `CompressionInterceptor(Gzip)` (OkHttp 5.2+) — ver
  [docs/examples/OkHttpFallbackInterceptor.kt](../examples/OkHttpFallbackInterceptor.kt).
- **Maior capacidade e resiliência.** A transferência do binário em si
  não passa pelo ServiceNow — só o cache-miss inicial aciona o fallback
  pra buscar da origem uma vez; toda leitura seguinte do mesmo arquivo
  vem direto do S3. Isso tira do ServiceNow a carga de servir bytes
  repetidamente para o mesmo arquivo (e os limites de capacidade/
  throughput inerentes a uma instância ServiceNow), deixando S3 e API
  Gateway — dimensionados justamente para esse tipo de carga — como
  responsáveis pela distribuição.

## Consequências

**Positivas:**
- Nenhum compute no caminho de dados de um objeto já populado — custo e
  latência mínimos, alinhados ao padrão aprovado (API GW + mTLS/token,
  quando essas duas peças forem adicionadas — ver "O que falta").
- Cliente fica mais simples: não precisa saber tamanho de chunk, não
  precisa necessariamente fazer `HEAD` antes de baixar (ver
  [docs/client-behavior.md](../client-behavior.md) §1) — o servidor
  garante o teto de payload sozinho.
- Cache-miss, concorrência (lock não-bloqueante) e consistência entre
  chunks (`If-Match`/`ETag`) resolvidos sem infraestrutura de estado
  adicional (sem DynamoDB/Redis) — o S3 já serve de fonte da verdade e
  de mecanismo de lock.

**Negativas / trade-offs aceitos:**
- A lógica de transformação de requisição (VTL/Velocity) tem
  particularidades reais e não óbvias (ex.: hífen é caractere válido em
  nome de referência, o que quebrava `"bytes=$rangeStart-$rangeEnd"` de
  forma silenciosa — encontrado e corrigido, ver SPEC.md §9). O trade-off
  que fica não é sobre o estado atual (já validado contra AWS real,
  funcionando) — é de processo: esse tipo de particularidade só aparece
  testando contra a AWS de verdade, não lendo a documentação; qualquer
  mudança futura nessa VTL precisa do mesmo rigor de validação. VTL não
  tem test runner local — iterar numa mudança exige deploy real. Isso é
  mitigado pela esteira de CI/CD já em uso na organização: além dos
  testes unitários, há testes de aplicação integrados pós-deploy, e está
  em construção um teste integrado ponta a ponta (incluindo obtenção de
  token STS, mTLS e todo o caminho) — uma regressão nessa VTL seria
  pega em tempo de deploy, não silenciosamente em produção.
- `binary_media_types` mal configurado corrompe silenciosamente tanto
  corpo de erro (bloqueando VTL) quanto corpo binário de sucesso — é uma
  fonte de bugs sutis específica dessa abordagem (ver SPEC.md §5).
- Multi-range numa única requisição não é suportado (limitação do S3, não
  desta solução) — cada bloco é sempre uma requisição HTTP separada.
- Anexo removido no ServiceNow continua disponível no S3 até um processo
  de limpeza removê-lo — a imutabilidade por `sys_id` resolve alteração,
  não remoção.
- Se o processo de fallback morrer sem liberar o lock (queda abrupta do
  pod, OOM), a key fica respondendo `202` até o TTL do lock expirar.

## Custo

A planilha [docs/custo/apigw-vs-cloudfront.xlsx](../custo/apigw-vs-cloudfront.xlsx)
calcula o custo mensal deste padrão e de uma CDN a partir do volume medido
em produção: na aba **Consumo**, informe os dias cobertos e, por categoria
de arquivo, downloads, tamanho médio, % com `HEAD` e % de requisições
extras; o resultado sai na aba **Comparativo**. Preços e parâmetros ficam
na aba **Premissas** (us-east-1, conferidos em 2026-09-13 — revisar para a
região e a data da decisão).

O que o modelo considera:

- **API Gateway:** requisições por bloco (teto de 10 MB, bloco de 8 MiB),
  transferência para a internet em faixas, um `GET`/`HEAD` no S3 por
  requisição (sem cache) e o Lambda authorizer nas requisições que não
  acertam o cache do authorizer.
- **CloudFront sob demanda:** uma requisição por arquivo, free tier de
  1 TB e 10 milhões de requisições por mês, transferência em faixas e
  `GET` no S3 só nos cache-miss.
- **CloudFront plano fixo:** o menor plano cujos limites comportam o
  volume (referência — não verificado se os planos atendem mTLS).

Leitura geral:

- **Custo marginal por GB é equivalente** nas duas opções sob demanda
  (~$0,09 x ~$0,085 na primeira faixa). Requisições, leituras no S3 e
  authorizer somam centavos por milhar de downloads.
- **Em volume baixo, o free tier de 1 TB do CloudFront pesa** na
  comparação: com os valores de exemplo da planilha (~1,8 TB/mês), o API
  Gateway sai ~$165/mês contra ~$62/mês no CloudFront sob demanda, e a
  diferença de ~$100/mês é basicamente o free tier. Em volumes maiores a
  razão se aproxima de 1.
- **Em volume alto, os planos fixos de CDN abrem distância** (ex.: Pro a
  $15/mês até 50 TB) — vantagem que a variante CDN não consegue usar hoje
  pela exigência de validação online (ver "Alternativas consideradas").

## Alternativas consideradas

| Alternativa | Avaliação |
| :---- | :---- |
| **API Gateway → S3 direto (Service Proxy)** | ✅ Escolhida — sem compute no caminho de dados, custo mínimo, alinhada ao padrão de API Gateway já consolidado na organização |
| API Gateway → compute (Lambda/ECS/EKS/etc.) → S3 (proxy integration) | Não escolhida pro caminho de dados — adiciona compute (custo + eventual cold start + limite de payload mais restritivo que o do API GW) sem necessidade, já que não há transformação de binário a fazer. Vale só pro caminho de dados; o fallback (cache-miss) já usa compute de propósito, ver "Decisão" |
| URL pré-assinada do S3 entregue pelo BFF | Não aceita pela política atual de exposição de arquivos privados, apesar de dispensar o teto de 10 MB e ter range nativo |
| CloudFront + viewer mTLS + S3 privado (OAC) | Não escolhida — o CloudFront valida o certificado contra um trust store, mas a validação do token e da **revogação do certificado de cliente** exige consulta online à infra de governança, o que o Lambda authorizer do API Gateway faz hoje. Na borda isso não cabe: CloudFront Functions não tem acesso à rede e Lambda@Edge não roda em VPC. Seria a opção natural (sem teto de 10 MB, cache na borda) se a validação pudesse ser offline. Custo comparado em "Custo" |
| Fallback síncrono (compute responde `302` ao fim da cópia) | Não escolhido — amarra o tempo de cópia ao timeout de integração do API Gateway (29 s). Foi a primeira versão da PoC |
| Cliente escolhe o tamanho de chunk (proposta inicial) | Substituída — exige o cliente conhecer/sincronizar um número "mágico" com o servidor; o servidor decidir o teto sozinho é mais simples e mais robusto (protege até clientes mal-comportados) |
| Cache de erro só no CDN automático do API Gateway edge-optimized | Não se aplica — essa distribuição CloudFront é só roteamento de latência, não cacheia por `Cache-Control` (confirmado contra doc oficial). Optou-se por `Cache-Control` no cliente (sem custo) + decisão adiada sobre stage cache nativo do API Gateway (tem custo real, ~$15/mês) |

## O que falta

Não é um risco em aberto — mTLS e a validação de token do banco já rodam
em produção para o BFF POS↔ServiceNow, então isso não é um desenho a
validar. Não foram cabeados **nesta PoC** simplesmente porque não
agregam nada ao que este documento está validando (a mecânica de
transferência via API Gateway direto ao S3) — em uma implementação real,
seria só reaproveitar a configuração e o mecanismo já existentes, não um
trabalho novo.

Ver [SPEC.md §8](../../SPEC.md) para os detalhes específicos desta
integração (qual CA usar no truststore, claims exatas do token) a
confirmar com quem mantém o BFF existente.
