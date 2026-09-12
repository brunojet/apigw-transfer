aws_region      = "us-east-1"
bucket_name     = "brunojet-media-proxy-dev"
test_object_key = "servicenow-zurich-platform-security-ptbr.pdf"
api_name        = "apigw-transfer-dev"
stage_name      = "dev"

# ["*/*"] = respostas binárias reais; [] = base64 (~+33% payload) — ver
# SPEC.md seção 5. Fase 3 testa os dois valores.
binary_media_types = ["*/*"]

tags = {
  Project     = "apigw-transfer"
  Environment = "dev"
}
