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

module "apigw_s3_proxy" {
  source = "./modules/apigw_s3_proxy"

  api_name           = var.api_name
  stage_name         = var.stage_name
  aws_region         = var.aws_region
  bucket_name        = data.aws_s3_bucket.media.id
  bucket_arn         = data.aws_s3_bucket.media.arn
  object_key         = var.test_object_key
  missing_object_key = var.missing_object_key
  binary_media_types = var.binary_media_types
  tags               = var.tags
}
