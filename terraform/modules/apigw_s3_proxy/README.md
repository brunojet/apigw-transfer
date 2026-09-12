# apigw_s3_proxy

REST API no API Gateway com integração **AWS Service Proxy** (não Lambda)
para `GET`/`HEAD` em `/{key+}`, repassando o header `Range` para o S3 e
devolvendo `Content-Range`/`206` quando aplicável.

Sem mTLS e sem autorização (ver SPEC.md seção 2/4 — adiado para PLAN.md
Fases 4-5).

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
```

## Notas de implementação

- IAM role escopada só ao `object_key` informado (`s3:GetObject`/
  `s3:HeadObject`), não ao bucket inteiro — outras keys recebem `403` do S3.
- `binary_media_types` controla se o corpo binário vem como bytes reais
  (`["*/*"]`) ou base64 (`[]`) — ver SPEC.md seção 5 sobre o teto prático de
  payload em cada caso.
- Dois `aws_api_gateway_integration_response` no GET: um default (200) e um
  com `selection_pattern = "206"`, porque o S3 retorna 206 quando a
  requisição carrega `Range`.
