# Lambda de fallback: GET/HEAD /fallback/{key+} -> busca no prefixo
# "origin/" do mesmo bucket (origem simulada) -> copia pro path direto ->
# redireciona. So invocada em cache-miss -- o path direto (/{key+})
# continua 100% sem Lambda (PLAN.md / memoria de projeto).

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
        Sid      = "ReadOrigin"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = [for k in var.test_keys : "${var.bucket_arn}/${var.origin_prefix}${k}"]
      },
      {
        Sid      = "ReadWriteDirect"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:HeadObject", "s3:PutObject"]
        Resource = [for k in var.test_keys : "${var.bucket_arn}/${k}"]
      },
      {
        Sid      = "LockOps"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for k in var.test_keys : "${var.bucket_arn}/${k}.lock"]
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
    }
  }
}
