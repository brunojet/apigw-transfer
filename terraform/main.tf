terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Bucket já existente (reaproveitado do media-proxy) — nunca criado aqui.
# Ver PLAN.md Fase 1 / SPEC.md seção 3.
data "aws_s3_bucket" "media" {
  bucket = var.bucket_name
}

module "fallback_lambda" {
  source = "./modules/fallback_lambda"

  function_name       = var.fallback_lambda_function_name
  zip_path            = "${path.module}/../build/fallback.zip"
  bucket_arn          = data.aws_s3_bucket.media.arn
  bucket_name         = data.aws_s3_bucket.media.id
  origin_prefix       = var.origin_prefix
  test_keys           = [var.fallback_test_object_key]
  lock_ttl_seconds    = var.fallback_lock_ttl_seconds
  retry_after_seconds = var.fallback_retry_after_seconds
  timeout             = var.fallback_lambda_timeout
  tags                = var.tags
}

module "apigw_s3_proxy" {
  source = "./modules/apigw_s3_proxy"

  api_name                      = var.api_name
  stage_name                    = var.stage_name
  aws_region                    = var.aws_region
  bucket_name                   = data.aws_s3_bucket.media.id
  bucket_arn                    = data.aws_s3_bucket.media.arn
  object_key                    = var.test_object_key
  missing_object_key            = var.missing_object_key
  fallback_test_object_key      = var.fallback_test_object_key
  binary_media_types            = var.binary_media_types
  minimum_compression_size      = var.minimum_compression_size
  max_chunk_bytes               = var.max_chunk_bytes
  notfound_max_age_seconds      = var.notfound_max_age_seconds
  fallback_lambda_invoke_arn    = module.fallback_lambda.invoke_arn
  fallback_lambda_function_name = module.fallback_lambda.function_name
  tags                          = var.tags
}
