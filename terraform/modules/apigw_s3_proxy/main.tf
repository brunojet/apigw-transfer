# API Gateway (REST API) -> AWS Service Proxy -> S3, sem Lambda no caminho
# do binário. Sem mTLS e sem autorização nesta rodada (SPEC.md seção 2/4,
# PLAN.md Fases 4-5 adiadas).
#
# GET  /{key+}  -> s3:GetObject  (repassa header Range -> Content-Range/206)
# HEAD /{key+}  -> s3:HeadObject (descoberta de tamanho)

resource "aws_api_gateway_rest_api" "this" {
  name               = var.api_name
  binary_media_types = var.binary_media_types
  tags               = var.tags
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{key+}"
}

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
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:HeadObject"]
      Resource = "${var.bucket_arn}/${var.object_key}"
    }]
  })
}

# --- GET /{key+} -> s3:GetObject -------------------------------------------

resource "aws_api_gateway_method" "get" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "GET"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.key"     = true
    "method.request.header.Range" = false
  }
}

resource "aws_api_gateway_integration" "get" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.get.http_method
  type                    = "AWS"
  integration_http_method = "GET"
  credentials             = aws_iam_role.apigw_s3.arn
  uri                     = "arn:aws:apigateway:${var.aws_region}:s3:path/${var.bucket_name}/{key}"

  request_parameters = {
    "integration.request.path.key"     = "method.request.path.key"
    "integration.request.header.Range" = "method.request.header.Range"
  }
}

resource "aws_api_gateway_method_response" "get_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.get.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Content-Type"   = true
    "method.response.header.Content-Length" = true
    "method.response.header.Accept-Ranges"  = true
    "method.response.header.ETag"           = true
  }
}

resource "aws_api_gateway_method_response" "get_206" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.get.http_method
  status_code = "206"

  response_parameters = {
    "method.response.header.Content-Type"   = true
    "method.response.header.Content-Length" = true
    "method.response.header.Content-Range"  = true
    "method.response.header.Accept-Ranges"  = true
    "method.response.header.ETag"           = true
  }
}

resource "aws_api_gateway_integration_response" "get_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.get.http_method
  status_code = aws_api_gateway_method_response.get_200.status_code

  response_parameters = {
    "method.response.header.Content-Type"   = "integration.response.header.Content-Type"
    "method.response.header.Content-Length" = "integration.response.header.Content-Length"
    "method.response.header.Accept-Ranges"  = "integration.response.header.Accept-Ranges"
    "method.response.header.ETag"           = "integration.response.header.ETag"
  }

  depends_on = [aws_api_gateway_integration.get]
}

# S3 responde 206 quando a requisição carrega Range — mapeado à parte pois
# o status code do backend não é 200 nesse caso.
resource "aws_api_gateway_integration_response" "get_206" {
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.proxy.id
  http_method       = aws_api_gateway_method.get.http_method
  status_code       = aws_api_gateway_method_response.get_206.status_code
  selection_pattern = "206"

  response_parameters = {
    "method.response.header.Content-Type"   = "integration.response.header.Content-Type"
    "method.response.header.Content-Length" = "integration.response.header.Content-Length"
    "method.response.header.Content-Range"  = "integration.response.header.Content-Range"
    "method.response.header.Accept-Ranges"  = "integration.response.header.Accept-Ranges"
    "method.response.header.ETag"           = "integration.response.header.ETag"
  }

  depends_on = [aws_api_gateway_integration.get]
}

# --- HEAD /{key+} -> s3:HeadObject (descoberta de tamanho) -----------------

resource "aws_api_gateway_method" "head" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "HEAD"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.key" = true
  }
}

resource "aws_api_gateway_integration" "head" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.head.http_method
  type                    = "AWS"
  integration_http_method = "HEAD"
  credentials             = aws_iam_role.apigw_s3.arn
  uri                     = "arn:aws:apigateway:${var.aws_region}:s3:path/${var.bucket_name}/{key}"

  request_parameters = {
    "integration.request.path.key" = "method.request.path.key"
  }
}

resource "aws_api_gateway_method_response" "head_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.head.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Content-Type"   = true
    "method.response.header.Content-Length" = true
    "method.response.header.Accept-Ranges"  = true
    "method.response.header.ETag"           = true
  }
}

resource "aws_api_gateway_integration_response" "head_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.head.http_method
  status_code = aws_api_gateway_method_response.head_200.status_code

  response_parameters = {
    "method.response.header.Content-Type"   = "integration.response.header.Content-Type"
    "method.response.header.Content-Length" = "integration.response.header.Content-Length"
    "method.response.header.Accept-Ranges"  = "integration.response.header.Accept-Ranges"
    "method.response.header.ETag"           = "integration.response.header.ETag"
  }

  depends_on = [aws_api_gateway_integration.head]
}

# --- Deploy -----------------------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.get.id,
      aws_api_gateway_integration.get.id,
      aws_api_gateway_integration_response.get_200.id,
      aws_api_gateway_integration_response.get_206.id,
      aws_api_gateway_method.head.id,
      aws_api_gateway_integration.head.id,
      aws_api_gateway_integration_response.head_200.id,
      var.binary_media_types,
    ]))
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
