# Infra do API Gateway -> S3 Service Proxy. O CONTRATO (paths, methods,
# integrações, mapeamento de headers, binary media types) vive em
# openapi.yaml.tftpl — este arquivo só monta o wrapper: IAM role assumida
# pelo API Gateway, a REST API (corpo = OpenAPI renderizado), deployment
# e stage. Sem mTLS/autorização nesta rodada (PLAN.md Fases 4-5 adiadas).

# IAM role assumida pelo API Gateway para chamar o S3 diretamente.
# Escopo: só GetObject/HeadObject no objeto de teste, não no bucket inteiro
# nem no prefixo /cdn usado pelo media-proxy (PLAN.md Fase 1).
resource "aws_iam_role" "apigw_s3" {
  name = "${var.api_name}-apigw-s3-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "apigw_s3" {
  name = "${var.api_name}-apigw-s3-policy"
  role = aws_iam_role.apigw_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Necessario para o S3 conseguir diferenciar 404 (NoSuchKey) de 403
        # (AccessDenied) -- sem ListBucket, GetObject numa key inexistente
        # sempre volta AccessDenied, mesmo com permissao na key certa.
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.bucket_arn
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:HeadObject"]
        Resource = [
          "${var.bucket_arn}/${var.object_key}",
          # Key que nunca existe -- so pra provocar 404 real do S3 (em vez
          # de 403 por falta de permissao) e validar o mapeamento 404 -> 302.
          "${var.bucket_arn}/${var.missing_object_key}",
        ]
      },
    ]
  })
}

locals {
  openapi_spec = templatefile("${path.module}/openapi.yaml.tftpl", {
    api_name           = var.api_name
    aws_region         = var.aws_region
    bucket_name        = var.bucket_name
    execution_role_arn = aws_iam_role.apigw_s3.arn
    binary_media_types = var.binary_media_types
  })
}

resource "aws_api_gateway_rest_api" "this" {
  name              = var.api_name
  body              = local.openapi_spec
  put_rest_api_mode = "overwrite"
  tags              = var.tags
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(local.openapi_spec)
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name
  tags          = var.tags
}
