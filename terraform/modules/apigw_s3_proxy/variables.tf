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

variable "binary_media_types" {
  description = "Binary media types da REST API"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags aplicadas aos recursos"
  type        = map(string)
  default     = {}
}
