variable "function_name" {
  description = "Nome da funcao Lambda de fallback"
  type        = string
}

variable "zip_path" {
  description = "Caminho local do zip do binario (scripts/build-lambda.sh)"
  type        = string
}

variable "bucket_arn" {
  description = "ARN do bucket S3 alvo"
  type        = string
}

variable "bucket_name" {
  description = "Nome do bucket S3 alvo"
  type        = string
}

variable "origin_prefix" {
  description = "Prefixo no mesmo bucket usado como origem simulada"
  type        = string
  default     = "origin/"
}

variable "file_deliveries" {
  description = "Canais de entrega por fileDeliveryId (ex.: image, apk), com o Cache-Control gravado no objeto ao copiar. Definem tambem os prefixos com permissao no S3"
  type = map(object({
    cache_control = string
  }))
}

variable "memory_size" {
  description = "Memoria da Lambda (MB)"
  type        = number
  default     = 256
}

variable "timeout" {
  description = "Timeout da Lambda (segundos) -- limita a duracao da copia assincrona; a requisicao do API Gateway so faz consultas rapidas"
  type        = number
  default     = 300
}

variable "lock_ttl_seconds" {
  description = "TTL do lock distribuido (segundos) -- deve ser >= timeout, senao o lock expira com a copia ainda em andamento"
  type        = number
  default     = 360
}

variable "retry_after_seconds" {
  description = "Segundos sugeridos ao cliente via header Retry-After quando ja existe um fetch em andamento (lock ocupado)"
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags aplicadas aos recursos"
  type        = map(string)
  default     = {}
}
