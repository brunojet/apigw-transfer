# apigw_s3_proxy

REST API no API Gateway com integração **AWS Service Proxy** (não Lambda)
para `GET`/`HEAD` em `/{key+}`, repassando o header `Range` para o S3 e
devolvendo `Content-Range`/`206` quando aplicável.

Sem mTLS e sem autorização (ver SPEC.md seção 2/4 — adiado para PLAN.md
Fases 4-5).

## Separação de responsabilidades

- **`openapi.yaml.tftpl`** = o contrato: paths, methods, parâmetros,
  integrações com o S3 (`x-amazon-apigateway-integration`), mapeamento de
  status/headers e `binaryMediaTypes`. É um template (`templatefile()`)
  porque região/bucket/role da IAM são injetados pelo Terraform.
- **`main.tf`** = só infra: IAM role assumida pelo API Gateway, a REST API
  em si (`body = local.openapi_spec`, `put_rest_api_mode = "overwrite"`),
  deployment (trigger = hash do spec renderizado) e stage.

Mudar o contrato (novo path, header, status code) = editar o `.tftpl`.
Mudar infra (nome da API, tags, role, bucket) = editar `main.tf`/`variables.tf`.

## Uso

```hcl
module "apigw_s3_proxy" {
  source = "./modules/apigw_s3_proxy"

  api_name           = "apigw-transfer-dev"
  stage_name         = "dev"
  aws_region         = "us-east-1"
  bucket_name        = "brunojet-media-proxy-dev"
  bucket_arn         = "arn:aws:s3:::brunojet-media-proxy-dev"
  object_key         = "servicenow-zurich-platform-security-ptbr.pdf"
  binary_media_types = ["*/*"]
  tags               = { Project = "apigw-transfer" }
}
```

## Testando

```bash
# Descobrir tamanho total
curl -sI "$(terraform output -raw test_object_url)"

# Baixar um range específico (bytes 0-1023)
curl -s -H "Range: bytes=0-1023" "$(terraform output -raw test_object_url)" -o chunk0.bin -D -

# Ou com o script de debug (HEAD + blocos, ver scripts/download_range.py)
python ../scripts/download_range.py "$(terraform output -raw test_object_url)"
```

## Notas de implementação

- IAM role escopada só ao `object_key` informado (`s3:GetObject`/
  `s3:HeadObject`), não ao bucket inteiro — outras keys recebem `403` do S3.
- `binary_media_types` controla se o corpo binário vem como bytes reais
  (`["*/*"]`) ou é corrompido (não é "só" base64 — bytes inválidos em UTF-8
  viram `U+FFFD`, ver SPEC.md seção 5) quando vazio (`[]`).
- Dois blocos de resposta no GET do OpenAPI: `default` (200) e `"206"`,
  porque o S3 retorna 206 quando a requisição carrega `Range` — a mesma
  ideia do antigo `selection_pattern = "206"` em HCL puro, só que expressa
  como chave de `responses` no `x-amazon-apigateway-integration`.
- Validado end-to-end (Fase 3): reconstrução de um objeto de ~109MB em
  blocos de 8MB bate byte-a-byte (sha256) antes e depois deste refactor.
