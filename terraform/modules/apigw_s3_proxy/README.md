# apigw_s3_proxy

REST API no API Gateway com integração **AWS Service Proxy** (não Lambda)
para `GET`/`HEAD` em `/{key+}`. O servidor valida e limita o header `Range`
antes de repassar ao S3, então toda resposta de `GET` fica abaixo do teto de
payload do API Gateway. `/fallback/{key+}` aponta para a Lambda de fallback
(cache-miss).

Sem mTLS e sem autorização (ver SPEC.md seção 2/4 — adiado para PLAN.md
Fases 4-5).

## Separação de responsabilidades

- **`openapi.yaml.tftpl`** = o contrato: paths, methods, parâmetros,
  integrações com o S3 (`x-amazon-apigateway-integration`), VTL de `Range`,
  mapeamento de status/headers. É um template (`templatefile()`) porque
  região, role da IAM e ARN da Lambda são injetados pelo Terraform.
- **`main.tf`** = só infra: IAM role assumida pelo API Gateway, a REST API
  (`body = local.openapi_spec`, `put_rest_api_mode = "overwrite"`,
  `binary_media_types` e `minimum_compression_size` como atributos nativos),
  deployment e stage (stage variables `bucketName`, `maxChunkBytes`,
  `notFoundMaxAgeSeconds`).

Mudar o contrato (novo path, header, status code) = editar o `.tftpl`.
Mudar infra (nome da API, tags, role, bucket) = editar `main.tf`/`variables.tf`.

## Uso

```hcl
module "apigw_s3_proxy" {
  source = "./modules/apigw_s3_proxy"

  api_name                      = "apigw-transfer-dev"
  stage_name                    = "dev"
  aws_region                    = "us-east-1"
  bucket_name                   = "brunojet-media-proxy-dev"
  bucket_arn                    = "arn:aws:s3:::brunojet-media-proxy-dev"
  object_key                    = "servicenow-zurich-platform-security-ptbr.pdf"
  fallback_test_object_key      = "apigw-transfer-fallback-test.bin"
  binary_media_types            = ["application/pdf", "application/octet-stream", "image/*", "application/vnd.android.package-archive"]
  minimum_compression_size      = 8192
  fallback_lambda_invoke_arn    = module.fallback_lambda.invoke_arn
  fallback_lambda_function_name = module.fallback_lambda.function_name
  tags                          = { Project = "apigw-transfer" }
}
```

## Testando

```bash
# Descobrir tamanho total
curl -sI "$(terraform output -raw test_object_url)"

# Baixar um range específico (bytes 0-1023)
curl -s -H "Range: bytes=0-1023" "$(terraform output -raw test_object_url)" -o chunk0.bin -D -

# Ou com o cliente de referência (HEAD + blocos, ver scripts/download_range.py)
python ../scripts/download_range.py "$(terraform output -raw test_object_url)"
```

## Notas de implementação

- IAM role escopada às keys de teste (`object_key`, `missing_object_key`,
  `fallback_test_object_key`), não ao bucket inteiro. Outras keys existentes
  recebem `403`.
- `binary_media_types` precisa listar os content-types reais servidos:
  vazio corrompe o corpo binário (bytes inválidos em UTF-8 viram `U+FFFD`) e
  `"*/*"` faz o XML de erro do S3 ser tratado como binário, o que quebra o
  VTL do redirect `404 -> 302` e dos corpos genéricos de erro (SPEC.md §5).
- Mudanças em `binary_media_types` e `minimum_compression_size` só valem no
  stage após novo deployment; por isso entram no hash do trigger junto com o
  contrato.
- Integration responses do `GET`: `200`, `206`, `403`, `404` (vira `302`),
  `412`, `416` e `default` (`502`). O `default` pega qualquer status sem
  regra própria, por isso é erro e nunca `200`.
