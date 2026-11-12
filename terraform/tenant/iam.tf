# ───────────── Roles IAM de las instancias ─────────────
# Cada instancia tiene su propio rol:
#   - db      → solo lee  /asistencia/<tenant>/<entorno>/db/*
#   - backend → solo lee  /asistencia/<tenant>/<entorno>/backend/*
#   - frontend → no lee secretos
# Así un tenant nunca puede leer los secretos de otro (aislamiento).
# Los tres pueden usar Session Manager (entrar sin SSH ni IP abierta).

data "aws_caller_identity" "actual" {}

locals {
  arn_parametros    = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.actual.account_id}:parameter${local.ssm_prefijo}"
  respaldos_prefijo = "tenants/${var.tenant_id}/${var.entorno}"

  # Ruta de SSM que cada servicio puede leer (null = ninguna)
  lectura_ssm = {
    frontend = null
    backend  = "${local.arn_parametros}/backend/*"
    db       = "${local.arn_parametros}/db/*"
  }
}

data "aws_iam_policy_document" "asumir_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "servicio" {
  for_each = local.lectura_ssm

  name               = "${local.nombre}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.asumir_ec2.json
}

# Session Manager (consola de AWS → EC2 → Connect → Session Manager)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = aws_iam_role.servicio

  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lectura de los secretos propios. Con la llave administrada aws/ssm no hace falta
# permiso KMS explícito: la política de esa llave ya permite descifrar vía SSM.
resource "aws_iam_role_policy" "leer_secretos" {
  for_each = { for k, v in local.lectura_ssm : k => v if v != null }

  name = "leer-secretos-propios"
  role = aws_iam_role.servicio[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = each.value
    }]
  })
}

# La instancia db sube y descarga respaldos SOLO en el prefijo de su tenant (RF-19)
resource "aws_iam_role_policy" "respaldos_db" {
  count = var.bucket_respaldos == "" ? 0 : 1

  name = "respaldos-propios"
  role = aws_iam_role.servicio["db"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject"]
      Resource = "arn:aws:s3:::${var.bucket_respaldos}/${local.respaldos_prefijo}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "servicio" {
  for_each = aws_iam_role.servicio

  name = each.value.name
  role = each.value.name
}
