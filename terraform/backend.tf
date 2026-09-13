terraform {
  backend "s3" {
    bucket  = "brunojet-tfstate"
    key     = "apigw-transfer/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
