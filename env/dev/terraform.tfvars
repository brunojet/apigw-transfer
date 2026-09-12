aws_region      = "us-east-1"
bucket_name     = "brunojet-media-proxy-dev"
test_object_key = "servicenow-zurich-platform-security-ptbr.pdf"
api_name        = "apigw-transfer-dev"
stage_name      = "dev"

# "*/*" trata TUDO como binario, inclusive o XML de erro do S3 -- quebra
# qualquer responseTemplates/VTL (ver memoria de projeto: "Unable to
# transform response"). Restrito aos tipos de arquivo reais que o proxy
# serve, para o XML de erro (application/xml) ficar de fora e virar texto
# processavel. [] = base64 (~+33% payload) -- ver SPEC.md secao 5.
binary_media_types = [
  "application/pdf",
  "application/octet-stream",
  "image/*",
  "application/vnd.android.package-archive",
]

tags = {
  Project     = "apigw-transfer"
  Environment = "dev"
}
