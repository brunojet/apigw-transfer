variable "api_name" {
  description = "Nome da REST API"
  type        = string
}

variable "stage_name" {
  description = "Nome do stage de deploy"
  type        = string
}

variable "aws_region" {
  description = "Região AWS (usada para montar o ARN da integração de serviço)"
  type        = string
}

variable "bucket_name" {
  description = "Nome do bucket S3 alvo (data source, não criado por este módulo)"
  type        = string
}

variable "bucket_arn" {
  description = "ARN do bucket S3 alvo, usado para escopar a IAM role"
  type        = string
}

variable "object_key" {
  description = "Key do objeto de teste — a IAM role da API Gateway só recebe s3:GetObject/s3:HeadObject para esta key, não para o bucket inteiro"
  type        = string
}

variable "missing_object_key" {
  description = "Key que deliberadamente NÃO existe no bucket, usada só para validar o mapeamento 404 -> 302 (S3 responde 404 de verdade, não 403, porque a IAM libera esta key também)"
  type        = string
  default     = "apigw-transfer-poc-404-test-do-not-create.bin"
}

variable "binary_media_types" {
  description = "Binary media types da REST API"
  type        = list(string)
  default     = []
}

variable "fallback_test_object_key" {
  description = "Key de teste do fluxo de fallback -- liberada no proxy direto tambem, pra o cliente conseguir ler depois que a Lambda popular"
  type        = string
}

variable "fallback_lambda_invoke_arn" {
  description = "Invoke ARN da Lambda de fallback (aws_lambda_function.invoke_arn), usado no path /fallback/{key+}"
  type        = string
}

variable "fallback_lambda_function_name" {
  description = "Nome da Lambda de fallback, para o aws_lambda_permission"
  type        = string
}

variable "tags" {
  description = "Tags aplicadas aos recursos"
  type        = map(string)
  default     = {}
}
