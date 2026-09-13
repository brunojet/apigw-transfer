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

variable "minimum_compression_size" {
  description = "Bytes minimos pra API Gateway comprimir a resposta (gzip), se o cliente mandar Accept-Encoding -- null desabilita. Ver SPEC.md secao 5 (achado sobre compressao)."
  type        = number
  default     = null
}

variable "range_clamp_max_chunk_bytes" {
  description = <<-EOT
    Offset maximo somado ao inicio do range (implicito ou pedido pelo
    cliente) no path de spike /test-range-clamp/{key+} -- o tamanho real
    do chunk devolvido e' este valor + 1 byte. So afeta esse path isolado,
    nao o /{key+} de producao. Default 8388607 = 8MiB - 1 (chunk de 8MiB,
    ja validado end-to-end na Fase 3 do PLAN.md).
  EOT
  type        = number
  default     = 8388607
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
