# apigw-transfer

PoC: download de arquivos privados do S3 através do Amazon API Gateway
(mTLS + token do banco), sem aplicação/compute no caminho de dados.

- [SPEC.md](SPEC.md) — motivação, escopo, arquitetura proposta, achados
  técnicos e questões em aberto.
- [PLAN.md](PLAN.md) — fases de implementação e critérios de conclusão de
  cada uma.
- [docs/client-behavior.md](docs/client-behavior.md) — contrato que o
  cliente precisa seguir (HEAD + Range, cache-miss/fallback, retry),
  com diagramas de sequência e de fluxo.
