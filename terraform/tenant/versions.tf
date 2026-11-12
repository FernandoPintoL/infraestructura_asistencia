terraform {
  required_version = ">= 1.10" # use_lockfile (bloqueo nativo en S3); OpenTofu >= 1.10 también

  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 5.0" }
    tls    = { source = "hashicorp/tls", version = ">= 4.0" }
    random = { source = "hashicorp/random", version = ">= 3.5" }
  }

  # Configuración parcial: bucket/región salen de backend.hcl (lo genera bootstrap/)
  # y la key de cada tenant se pasa en el init:
  #   -backend-config="key=tenants/<tenant_id>/<entorno>/terraform.tfstate"
  backend "s3" {}
}

# Las credenciales NO van aquí: se toman de "aws configure" o de variables de entorno.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Proyecto      = "asistencia"
      Tenant        = var.tenant_id
      Entorno       = var.entorno
      Plan          = var.plan
      GestionadoPor = "terraform"
    }
  }
}
