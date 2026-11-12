# ───────────── Secretos del tenant ─────────────
# Se generan aquí y se guardan en SSM Parameter Store como SecureString (cifrados con KMS).
# NO van en terraform.tfvars, ni en el código, ni en el user_data de las instancias:
# cada instancia los lee de SSM al arrancar, con un rol IAM que solo ve los de SU tenant.
#
# Ojo: Terraform también los guarda en su estado. Por eso el estado vive en un bucket S3
# privado, cifrado y solo accesible con credenciales de la plataforma (ver bootstrap/).

locals {
  ssm_prefijo = "/asistencia/${var.tenant_id}/${var.entorno}"
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "django_secret" {
  length  = 60
  special = false
}

resource "random_password" "admin" {
  length  = 16
  special = false
}

# Llave SSH del tenant: la privada solo queda en SSM (no se escribe en disco)
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ssh" {
  key_name   = "${local.nombre}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# ───────────── Parámetros en SSM ─────────────

resource "aws_ssm_parameter" "db_password" {
  name        = "${local.ssm_prefijo}/db/password"
  description = "Contraseña de PostgreSQL del tenant ${var.tenant_id}"
  type        = "SecureString"
  value       = random_password.db.result
}

# .env completo del backend. Se regenera en la instancia cada vez que arranca Gunicorn;
# si cambia, aws_ssm_association.reiniciar_backend reinicia el servicio automáticamente.
resource "aws_ssm_parameter" "backend_env" {
  name        = "${local.ssm_prefijo}/backend/env"
  description = "Archivo .env del backend del tenant ${var.tenant_id}"
  type        = "SecureString"
  value = join("\n", [
    "SECRET_KEY=${random_password.django_secret.result}",
    "DEBUG=False",
    # El navegador solo habla con el frontend; su Nginx reenvía /api con Host = IP pública
    "ALLOWED_HOSTS=${aws_eip.frontend.public_ip},localhost,127.0.0.1",
    "CORS_ALLOWED_ORIGINS=http://${aws_eip.frontend.public_ip}",
    "DB_NAME=asistencia_db",
    "DB_USER=asistencia",
    "DB_PASSWORD=${random_password.db.result}",
    "DB_HOST=${aws_instance.db.private_ip}",
    "DB_PORT=5432",
    "JWT_HORAS=8",
    "TENANT_ID=${var.tenant_id}",
    "TENANT_NOMBRE=\"${var.tenant_nombre}\"",
    "ENTORNO=${var.entorno}",
    "PLAN=${var.plan}",
    "MAX_ESTUDIANTES=${local.recursos.max_estudiantes}",
    "MAX_MODULOS=${local.recursos.max_modulos}",
    "METRICAS=True", # /metrics para Prometheus (el Nginx del backend lo limita a la VPC)
    "",
  ])
}

resource "aws_ssm_parameter" "admin_password" {
  name        = "${local.ssm_prefijo}/backend/admin_password"
  description = "Contraseña inicial del administrador del tenant ${var.tenant_id}"
  type        = "SecureString"
  value       = random_password.admin.result
}

resource "aws_ssm_parameter" "ssh_privada" {
  name        = "${local.ssm_prefijo}/ssh/private_key"
  description = "Llave SSH privada de las instancias del tenant ${var.tenant_id}"
  type        = "SecureString"
  value       = tls_private_key.ssh.private_key_openssh
}
