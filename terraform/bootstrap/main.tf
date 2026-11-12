# ───────────── Bootstrap: bucket S3 para el estado de todos los tenants ─────────────
# Se ejecuta UNA sola vez por cuenta de AWS. Su propio estado queda local
# (huevo y gallina: el bucket aún no existe cuando se crea).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws   = { source = "hashicorp/aws", version = ">= 5.0" }
    local = { source = "hashicorp/local", version = ">= 2.4" }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Proyecto   = "asistencia"
      Componente = "plataforma"
    }
  }
}

variable "region" {
  description = "Región de AWS donde vive el bucket de estado"
  type        = string
  default     = "us-east-1"
}

data "aws_caller_identity" "actual" {}

# El ID de cuenta hace único el nombre del bucket (los nombres S3 son globales)
resource "aws_s3_bucket" "estado" {
  bucket = "asistencia-tfstate-${data.aws_caller_identity.actual.account_id}"

  # El estado de todos los tenants vive aquí: Terraform se niega a borrarlo
  lifecycle {
    prevent_destroy = true
  }
}

# Versionado: cada apply guarda una versión nueva; se puede volver a una anterior
resource "aws_s3_bucket_versioning" "estado" {
  bucket = aws_s3_bucket.estado.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Cifrado en reposo con la llave KMS administrada por AWS (aws/s3)
resource "aws_s3_bucket_server_side_encryption_configuration" "estado" {
  bucket = aws_s3_bucket.estado.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Nada público, nunca
resource "aws_s3_bucket_public_access_block" "estado" {
  bucket                  = aws_s3_bucket.estado.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "estado" {
  bucket = aws_s3_bucket.estado.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Rechaza cualquier acceso sin HTTPS
resource "aws_s3_bucket_policy" "estado" {
  bucket = aws_s3_bucket.estado.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SoloHTTPS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.estado.arn, "${aws_s3_bucket.estado.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.estado]
}

# Versiones viejas del estado se borran a los 90 días (controla costos)
resource "aws_s3_bucket_lifecycle_configuration" "estado" {
  bucket = aws_s3_bucket.estado.id
  rule {
    id     = "versiones-antiguas"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  depends_on = [aws_s3_bucket_versioning.estado]
}

# ───────────── Bucket de respaldos de las bases de datos de los tenants ─────────────
# Cada tenant escribe en tenants/<id>/<entorno>/ (su rol IAM no ve los demás prefijos).
# La plataforma borra los respaldos según la retención del plan; esta regla es solo
# una red de seguridad por si algo queda huérfano.

resource "aws_s3_bucket" "respaldos" {
  bucket = "asistencia-respaldos-${data.aws_caller_identity.actual.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "respaldos" {
  bucket = aws_s3_bucket.respaldos.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "respaldos" {
  bucket                  = aws_s3_bucket.respaldos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "respaldos" {
  bucket = aws_s3_bucket.respaldos.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "respaldos" {
  bucket = aws_s3_bucket.respaldos.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SoloHTTPS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.respaldos.arn, "${aws_s3_bucket.respaldos.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.respaldos]
}

resource "aws_s3_bucket_lifecycle_configuration" "respaldos" {
  bucket = aws_s3_bucket.respaldos.id
  rule {
    id     = "red-de-seguridad"
    status = "Enabled"
    filter {}
    expiration {
      days = 180
    }
  }
}

# Para ejecutar tenant.ps1 a mano: Terraform carga *.auto.tfvars automáticamente.
# (La plataforma pasa el mismo valor desde IAC_BUCKET_RESPALDOS.)
resource "local_file" "respaldos_tfvars" {
  filename = "${path.module}/../tenant/respaldos.auto.tfvars"
  content  = "bucket_respaldos = \"${aws_s3_bucket.respaldos.bucket}\"\n"
}

output "bucket_respaldos" {
  value = aws_s3_bucket.respaldos.bucket
}

# Escribe la configuración del backend que usará cada tenant (no contiene secretos)
resource "local_file" "backend_hcl" {
  filename = "${path.module}/../tenant/backend.hcl"
  content  = <<-EOT
    # Generado por bootstrap/. La "key" de cada tenant se pasa al hacer init.
    bucket       = "${aws_s3_bucket.estado.bucket}"
    region       = "${var.region}"
    encrypt      = true
    use_lockfile = true
  EOT
}

output "bucket_estado" {
  value = aws_s3_bucket.estado.bucket
}
