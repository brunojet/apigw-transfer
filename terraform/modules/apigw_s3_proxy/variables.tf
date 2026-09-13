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

variable "file_delivery_ids" {
  description = "Valores aceitos de fileDeliveryId (ex.: image, apk): viram o enum do parametro no contrato e os prefixos \"{fileDeliveryId}/\" com permissao de leitura no S3"
  type        = list(string)
}

variable "binary_media_types" {
  description = "Binary media types da REST API -- content-types reais servidos (nem vazio, nem \"*/*\"; ver SPEC.md secao 5)"
  type        = list(string)
}

variable "minimum_compression_size" {
  description = "Bytes minimos pra API Gateway comprimir a resposta (gzip), se o cliente mandar Accept-Encoding -- null desabilita. Ver SPEC.md secao 5 (achado sobre compressao)."
  type        = number
  default     = null
}

variable "notfound_max_age_seconds" {
  description = <<-EOT
    Cache-Control: max-age (segundos) na resposta 404 da Lambda de
    fallback (cmd/fallback) quando a key não existe nem na origem
    simulada -- caso irrecuperável, não transitório (só um humano
    populando origin/ resolve). Protege contra clientes batendo
    repetidamente numa key que sabemos que vai continuar falhando, sem
    custo de infra (client-side caching -- ver SPEC.md). Lido pela
    Lambda via event.StageVariables["notFoundMaxAgeSeconds"], não env
    var, pra ser ajustável sem redeploy do binário. Default 60s.
  EOT
  type        = number
  default     = 60
}

variable "max_chunk_bytes" {
  description = <<-EOT
    Offset maximo somado ao inicio do range (implicito ou pedido pelo
    cliente) em GET /files-delivery/{fileDeliveryId}/files/{fileId} -- o
    tamanho real do chunk devolvido e' este
    valor + 1 byte. O servidor sempre injeta/ajusta o Range antes de
    repassar ao S3 (ver openapi.yaml.tftpl), entao nenhuma resposta passa
    desse teto, mesmo que o cliente peca mais ou nao mande Range nenhum.
    Lido em runtime via stage variable (maxChunkBytes) -- mudar este
    valor nao dispara redeploy do aws_api_gateway_deployment. Default
    8388607 = 8MiB - 1 (chunk de 8MiB, ja validado end-to-end na Fase 3
    do PLAN.md e novamente contra o path de producao apos o merge do
    spike -- ver SPEC.md secao 9).
  EOT
  type        = number
  default     = 8388607
}

variable "fallback_lambda_invoke_arn" {
  description = "Invoke ARN da Lambda de fallback (aws_lambda_function.invoke_arn), usado nas rotas /files-delivery/{fileDeliveryId}/retrievals/{retrievalId}"
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
