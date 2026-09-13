# Lambda de fallback: GET/HEAD /files-delivery/{fileDeliveryId}/retrievals/
# {retrievalId} responde 202 e dispara a copia
# origin/{fileDeliveryId}/{fileId} -> {fileDeliveryId}/{fileId} numa
# autoinvocacao assincrona (simula o fallback assincrono do BFF, ADR 0001).
# So invocada em cache-miss -- as rotas files continuam 100% sem Lambda.

resource "aws_iam_role" "fallback" {
  name = "${var.function_name}-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.fallback.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "fallback" {
  name = "${var.function_name}-policy"
  role = aws_iam_role.fallback.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Com ListBucket o S3 responde 404 (e nao 403) para objeto ausente,
        # o que separa "nao existe na origem" de erro de permissao.
        Sid      = "ListForNotFound"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.bucket_arn
      },
      {
        Sid      = "ReadOrigin"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = [for id in keys(var.file_deliveries) : "${var.bucket_arn}/${var.origin_prefix}${id}/*"]
      },
      {
        # Arquivos copiados ({id}/{fileId}) e locks ({id}/{fileId}.lock).
        Sid      = "DeliveryObjectsAndLocks"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for id in keys(var.file_deliveries) : "${var.bucket_arn}/${id}/*"]
      },
    ]
  })
}

resource "aws_lambda_function" "fallback" {
  function_name = var.function_name
  role          = aws_iam_role.fallback.arn
  tags          = var.tags

  filename         = var.zip_path
  source_code_hash = filebase64sha256(var.zip_path)

  handler       = "bootstrap"
  runtime       = "provided.al2"
  architectures = ["arm64"]
  memory_size   = var.memory_size
  timeout       = var.timeout

  environment {
    variables = {
      S3_BUCKET           = var.bucket_name
      ORIGIN_PREFIX       = var.origin_prefix
      LOCK_TTL_SECONDS    = tostring(var.lock_ttl_seconds)
      RETRY_AFTER_SECONDS = tostring(var.retry_after_seconds)
      # {"image":"<cache-control>","apk":"<cache-control>"}: canais aceitos
      # e o Cache-Control gravado no objeto copiado de cada um.
      FILE_DELIVERIES = jsonencode({ for id, d in var.file_deliveries : id => d.cache_control })
    }
  }

  lifecycle {
    precondition {
      condition     = var.lock_ttl_seconds >= var.timeout
      error_message = "lock_ttl_seconds deve ser >= timeout: senao o lock expira com a copia assincrona ainda em andamento e outra requisicao dispara uma copia duplicada."
    }
  }
}

# A requisicao do API Gateway dispara a copia invocando a propria funcao
# de forma assincrona (InvocationType Event).
resource "aws_iam_role_policy" "self_invoke" {
  name = "${var.function_name}-self-invoke"
  role = aws_iam_role.fallback.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.fallback.arn
    }]
  })
}

# Sem retry automatico da invocacao assincrona: a copia libera o lock ao
# terminar (com ou sem erro), entao um retry rodaria sem lock. O cliente
# reenvia a requisicao e uma nova copia e' disparada.
resource "aws_lambda_function_event_invoke_config" "fallback" {
  function_name                = aws_lambda_function.fallback.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 300
}
