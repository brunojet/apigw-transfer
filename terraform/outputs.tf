output "rest_api_id" {
  description = "ID da REST API criada no API Gateway"
  value       = module.apigw_s3_proxy.rest_api_id
}

output "invoke_url" {
  description = "Base URL do stage de deploy"
  value       = module.apigw_s3_proxy.invoke_url
}

output "test_file_urls" {
  description = "URL do arquivo de teste por canal (GET/HEAD .../files/{fileId}; 302 para retrievals enquanto nao estiver no S3)"
  value = {
    for id, file_id in var.test_file_ids :
    id => "${module.apigw_s3_proxy.invoke_url}/files-delivery/${id}/files/${file_id}"
  }
}

output "test_retrieval_urls" {
  description = "URL da busca na origem do arquivo de teste por canal (GET/HEAD .../retrievals/{retrievalId})"
  value = {
    for id, file_id in var.test_file_ids :
    id => "${module.apigw_s3_proxy.invoke_url}/files-delivery/${id}/retrievals/${file_id}"
  }
}
