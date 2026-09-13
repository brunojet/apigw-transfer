# ADR 0001 — Proxy de download via API Gateway direto ao S3

**Status:** Aceito (PoC validada contra AWS real) — mTLS e token do banco
ainda pendentes (ver seção "O que falta").
**Data:** 2026-09-13
**Contexto do projeto:** [apigw-transfer](../../README.md) · detalhes
completos de implementação e histórico de achados em [SPEC.md](../../SPEC.md)
e [PLAN.md](../../PLAN.md).

## Contexto

O conglomerado tem um padrão consolidado para exposição de APIs a
consumidores externos: **API Gateway com mTLS e token de acesso
governado pelo banco** — já em uso nas demais APIs expostas pela
organização. Este projeto parte de uma pergunta natural de extensão
desse padrão: como aplicá-lo também ao cenário de **expor arquivos
privados do S3 a um consumidor externo**, incluindo arquivos grandes
(dezenas a centenas de MB)?

A pergunta técnica que motivou a PoC: dá para servir esses arquivos
através do padrão de API Gateway, sem introduzir compute
(Lambda/aplicação) no caminho de transferência do binário?

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
   bloco.
2. **Fallback assíncrono só no cache-miss.** Quando o objeto ainda não
   existe no path direto, o servidor responde `302` (montado
   dinamicamente via VTL, sem compute nesse primeiro passo) apontando
   para `/fallback/{key}`, que aí sim aciona um serviço de fallback — a
   única vez que compute entra no caminho, e só para popular o cache,
   nunca para servir um objeto já presente. Esse serviço pode ser
   qualquer solução de compute (Lambda, ECS, EKS, ou outra) — o desenho
   não depende de qual; esta PoC usa Lambda (invocação esporádica,
   compatível com o modelo de custo por evento), documentado em
   `cmd/fallback`.
3. **Configuração via stage variables, não hardcoded no contrato.** Bucket
   alvo, teto de chunk e tempo de cache de erros ficam em variáveis do
   stage do API Gateway, não embutidas no corpo da API — ajustá-los não
   dispara um novo deployment.

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
  nome de referência, quebrando `"bytes=$rangeStart-$rangeEnd"` de forma
  silenciosa — ver SPEC.md §9) — exige testar contra a AWS real, não só
  ler a documentação.
- `binary_media_types` mal configurado corrompe silenciosamente tanto
  corpo de erro (bloqueando VTL) quanto corpo binário de sucesso — é uma
  fonte de bugs sutis específica dessa abordagem (ver SPEC.md §5).
- Multi-range numa única requisição não é suportado (limitação do S3, não
  desta solução) — cada bloco é sempre uma requisição HTTP separada.

## Alternativas consideradas

| Alternativa | Avaliação |
| :---- | :---- |
| **API Gateway → S3 direto (Service Proxy)** | ✅ Escolhida — sem compute no caminho de dados, custo mínimo, alinhada ao padrão de API Gateway já consolidado na organização |
| API Gateway → compute (Lambda/ECS/EKS/etc.) → S3 (proxy integration) | Não escolhida pro caminho de dados — adiciona compute (custo + eventual cold start + limite de payload mais restritivo que o do API GW) sem necessidade, já que não há transformação de binário a fazer. Vale só pro caminho de dados; o fallback (cache-miss) já usa compute de propósito, ver "Decisão" |
| Cliente escolhe o tamanho de chunk (proposta inicial) | Substituída — exige o cliente conhecer/sincronizar um número "mágico" com o servidor; o servidor decidir o teto sozinho é mais simples e mais robusto (protege até clientes mal-comportados) |
| Cache de erro só no CDN automático do API Gateway edge-optimized | Não se aplica — essa distribuição CloudFront é só roteamento de latência, não cacheia por `Cache-Control` (confirmado contra doc oficial). Optou-se por `Cache-Control` no cliente (sem custo) + decisão adiada sobre stage cache nativo do API Gateway (tem custo real, ~$15/mês) |

## O que falta

Fora de escopo desta rodada, mas necessário antes de produção real:

- **mTLS** (custom domain + truststore) — quem fornece a CA ainda não
  está definido.
- **Validação do token do banco** — formato (JWT nativo vs. Lambda
  authorizer custom) ainda não especificado.

Ver [SPEC.md §8](../../SPEC.md) (questões em aberto) para o detalhamento
completo dessas pendências.
