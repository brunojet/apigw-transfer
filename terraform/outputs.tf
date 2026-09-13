output "rest_api_id" {
  description = "ID da REST API criada no API Gateway"
  value       = module.apigw_s3_proxy.rest_api_id
}

output "invoke_url" {
  description = "Base URL do stage de deploy"
  value       = module.apigw_s3_proxy.invoke_url
}

output "test_object_url" {
  description = "URL completa para baixar o objeto de teste (HEAD/GET com Range)"
  value       = "${module.apigw_s3_proxy.invoke_url}/${var.test_object_key}"
}

output "fallback_test_object_url" {
  description = "URL direta do objeto de teste do fallback (deve 404/302 ate a Lambda popular)"
  value       = "${module.apigw_s3_proxy.invoke_url}/${var.fallback_test_object_key}"
}

output "fallback_endpoint_url" {
  description = "URL do endpoint /fallback para o objeto de teste"
  value       = "${module.apigw_s3_proxy.invoke_url}/fallback/${var.fallback_test_object_key}"
}

output "missing_object_url" {
  description = "URL de um objeto que nunca existe -- usada pra validar o mapeamento 404 -> 302"
  value       = "${module.apigw_s3_proxy.invoke_url}/${var.missing_object_key}"
}
