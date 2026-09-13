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

variable "file_deliveries" {
  description = "Canais de entrega por fileDeliveryId e o Cache-Control gravado no objeto (repassado nas respostas de files). Imagens são imutáveis por fileId (cache longo); APK não é cacheado."
  type = map(object({
    cache_control = string
  }))
  default = {
    image = { cache_control = "private, max-age=2592000, immutable" }
    apk   = { cache_control = "no-store" }
  }
}

variable "test_file_ids" {
  description = "fileId de teste por canal, usados só nos outputs de URL. Os objetos são semeados manualmente em origin/{fileDeliveryId}/{fileId} (aws s3 cp, fora do Terraform)"
  type        = map(string)
  default = {
    image = "5f2c9a1be3d04c7a9e1f6b8d2a4c7e90"
    apk   = "9b1e7d3c5a2f4e6b8c0d1a3e5f7b9c2d"
  }
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
  description = "Binary media types da REST API -- os content-types reais servidos. Nao usar \"*/*\": trata tambem o XML de erro do S3 como binario e quebra o VTL (redirect 404 -> 302 e corpos genericos de erro). Lista vazia corrompe o binario. Ver SPEC.md §5."
  type        = list(string)
  default = [
    "application/pdf",
    "application/octet-stream",
    "image/*",
    "application/vnd.android.package-archive",
  ]

  validation {
    condition     = length(var.binary_media_types) > 0 && !contains(var.binary_media_types, "*/*")
    error_message = "binary_media_types precisa listar os content-types reais: vazio corrompe o binario e \"*/*\" quebra o VTL (SPEC.md §5)."
  }
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
  description = "Offset máximo do range em GET .../files/{fileId} -- chunk real = valor + 1 byte. O servidor sempre injeta/ajusta o Range (nunca deixa passar deste teto). Lido em runtime via stage variable, sem redeploy. Default 8388607 = 8MiB - 1 (já validado end-to-end)."
  type        = number
  default     = 8388607
}

variable "origin_prefix" {
  description = "Prefixo no bucket usado como origem simulada pela Lambda de fallback (mesmo bucket, ver memoria de projeto)"
  type        = string
  default     = "origin/"
}

variable "fallback_lambda_function_name" {
  description = "Nome da Lambda de fallback"
  type        = string
  default     = "apigw-transfer-dev-fallback"
}

variable "fallback_lambda_timeout" {
  description = "Timeout da Lambda de fallback (segundos) -- limita a duracao da copia assincrona"
  type        = number
  default     = 300
}

variable "fallback_lock_ttl_seconds" {
  description = "TTL do lock distribuido (segundos) -- deve ser >= fallback_lambda_timeout"
  type        = number
  default     = 360
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
