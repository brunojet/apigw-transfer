# apigw_s3_proxy

REST API no API Gateway com integração **AWS Service Proxy** (não Lambda)
para servir arquivos do S3 pelo contrato:

```
GET/HEAD /files-delivery/{fileDeliveryId}/files/{fileId}            -> S3 {fileDeliveryId}/{fileId}
GET/HEAD /files-delivery/{fileDeliveryId}/retrievals/{retrievalId}  -> Lambda de fallback
```

O servidor valida e limita o header `Range` antes de repassar ao S3, então
toda resposta de `GET .../files/{fileId}` fica abaixo do teto de payload do
API Gateway. Arquivo ausente vira `302` para `.../retrievals/{fileId}`.

Sem mTLS e sem autorização (ver SPEC.md seção 2/4).

## Separação de responsabilidades

- **`openapi.yaml.tftpl`** = o contrato: paths, parâmetros (o enum de
  `fileDeliveryId` vem de `file_delivery_ids`), integrações com o S3, VTL de
  `Range`, mapeamento de status/headers. É um template (`templatefile()`)
  porque região, role da IAM e ARN da Lambda são injetados pelo Terraform.
- **`main.tf`** = só infra: IAM role assumida pelo API Gateway (leitura nos
  prefixos `{fileDeliveryId}/`), a REST API (`body = local.openapi_spec`,
  `put_rest_api_mode = "overwrite"`, `binary_media_types` e
  `minimum_compression_size` como atributos nativos), deployment e stage
  (stage variables `bucketName`, `maxChunkBytes`, `notFoundMaxAgeSeconds`).

## Uso

```hcl
module "apigw_s3_proxy" {
  source = "./modules/apigw_s3_proxy"

  api_name                      = "apigw-transfer-dev"
  stage_name                    = "dev"
  aws_region                    = "us-east-1"
  bucket_name                   = "brunojet-media-proxy-dev"
  bucket_arn                    = "arn:aws:s3:::brunojet-media-proxy-dev"
  file_delivery_ids             = ["apk", "image"]
  binary_media_types            = ["application/pdf", "application/octet-stream", "image/*", "application/vnd.android.package-archive"]
  minimum_compression_size      = 8192
  fallback_lambda_invoke_arn    = module.fallback_lambda.invoke_arn
  fallback_lambda_function_name = module.fallback_lambda.function_name
  tags                          = { Project = "apigw-transfer" }
}
```

## Testando

```bash
# URLs de teste por canal
terraform output test_file_urls

# Tamanho total
curl -sI "<url de test_file_urls.apk>"

# Download completo seguindo o cache-miss e os 202
python ../scripts/download_range.py "<url de test_file_urls.apk>"
```

## Notas de implementação

- `Cache-Control` das respostas de `files` é repassado do metadado do objeto
  no S3, gravado pela cópia do fallback conforme o canal (imagem com cache
  longo, APK sem cache).
- O API Gateway não valida o `enum` de `fileDeliveryId`: com um valor fora
  da lista o arquivo não existe no S3, então `files` redireciona e
  `retrievals` responde `404` ("unknown fileDeliveryId").
- `binary_media_types` precisa listar os content-types reais servidos:
  vazio corrompe o corpo binário e `"*/*"` faz o XML de erro do S3 ser
  tratado como binário, o que quebra o VTL do redirect e dos corpos
  genéricos de erro (SPEC.md §5).
- Integration responses de `GET .../files/{fileId}`: `200`, `206`, `403`,
  `404` (vira `302`), `412`, `416` e `default` (`502`).
