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

variable "tags" {
  description = "Tags aplicadas aos recursos"
  type        = map(string)
  default = {
    Project     = "apigw-transfer"
    Environment = "dev"
  }
}
