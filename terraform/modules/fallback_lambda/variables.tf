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

variable "test_keys" {
  description = "Keys as quais a IAM role tem permissao (escopo minimo, nao o bucket inteiro) -- ver PLAN.md/memoria de projeto"
  type        = list(string)
}

variable "memory_size" {
  description = "Memoria da Lambda (MB)"
  type        = number
  default     = 256
}

variable "timeout" {
  description = "Timeout da Lambda (segundos)"
  type        = number
  default     = 30
}

variable "lock_ttl_seconds" {
  description = "TTL do lock distribuido (segundos) -- deve ser < timeout"
  type        = number
  default     = 20
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
