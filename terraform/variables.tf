variable "aws_region" {
  description = "Região AWS onde os recursos são criados"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Bucket S3 já existente a ser exposto via proxy (usado como data source, nunca criado por este stack)"
  type        = string
  default     = "brunojet-media-proxy-dev"
}

variable "test_object_key" {
  description = "Key do objeto de teste no bucket, usada para escopar a IAM role da API Gateway e montar a invoke URL de saída"
  type        = string
  default     = "servicenow-zurich-platform-security-ptbr.pdf"
}

variable "missing_object_key" {
  description = "Key que deliberadamente NÃO existe no bucket -- só pra validar o mapeamento 404 -> 302 (S3 responde 404 real, não 403)"
  type        = string
  default     = "apigw-transfer-poc-404-test-do-not-create.bin"
}

variable "api_name" {
  description = "Nome da REST API no API Gateway"
  type        = string
  default     = "apigw-transfer-dev"
}

variable "stage_name" {
  description = "Nome do stage de deploy da API"
  type        = string
  default     = "dev"
}

variable "binary_media_types" {
  description = "Binary media types da REST API. Lista vazia = respostas binárias vêm em base64 (~+33% de payload); ver SPEC.md §5. Fase 3 testa com e sem."
  type        = list(string)
  default     = ["*/*"]
}

variable "minimum_compression_size" {
  description = "Bytes mínimos (default: 8KB) pra API Gateway comprimir a resposta (gzip) quando o cliente manda Accept-Encoding -- opt-in do cliente, nunca forçado. Ver SPEC.md §5/§6."
  type        = number
  default     = 8192
}

variable "notfound_max_age_seconds" {
  description = "Cache-Control: max-age (segundos) na resposta 404 da Lambda de fallback quando a key não existe nem na origem simulada -- caso irrecuperável, protege contra clientes repetindo a mesma key que vai continuar falhando. Default 60s."
  type        = number
  default     = 60
}

variable "max_chunk_bytes" {
  description = "Offset máximo do range em GET /{key+} -- chunk real = valor + 1 byte. O servidor sempre injeta/ajusta o Range (nunca deixa passar deste teto). Lido em runtime via stage variable, sem redeploy. Default 8388607 = 8MiB - 1 (já validado end-to-end)."
  type        = number
  default     = 8388607
}

variable "origin_prefix" {
  description = "Prefixo no bucket usado como origem simulada pela Lambda de fallback (mesmo bucket, ver memoria de projeto)"
  type        = string
  default     = "origin/"
}

variable "fallback_test_object_key" {
  description = "Key de teste para o fluxo de fallback -- ausente na raiz, semeada em origin/ (ver docs/seed-fallback-test-object)"
  type        = string
  default     = "apigw-transfer-fallback-test.bin"
}

variable "fallback_lambda_function_name" {
  description = "Nome da Lambda de fallback"
  type        = string
  default     = "apigw-transfer-dev-fallback"
}

variable "fallback_lambda_timeout" {
  description = "Timeout da Lambda de fallback (segundos)"
  type        = number
  default     = 30
}

variable "fallback_lock_ttl_seconds" {
  description = "TTL do lock distribuido (segundos)"
  type        = number
  default     = 20
}

variable "fallback_retry_after_seconds" {
  description = "Segundos sugeridos ao cliente via Retry-After quando ja existe um fetch em andamento"
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags aplicadas aos recursos"
  type        = map(string)
  default = {
    Project     = "apigw-transfer"
    Environment = "dev"
  }
}
