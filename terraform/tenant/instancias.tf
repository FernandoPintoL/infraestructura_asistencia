# ───────────── Las 3 instancias del tenant (RF-09, RF-10) ─────────────
#
# Qué provoca cada cambio en un "terraform apply":
#   - Cambio de plan (tipo de instancia): se modifica EN SITIO (stop → cambiar tipo → start).
#     El disco y la IP privada se conservan.
#   - Cambio de disco de la base: se agranda en sitio (EBS solo crece).
#   - Cambio de límites del plan: cambia el parámetro SSM y Gunicorn se reinicia solo
#     (aws_ssm_association.reiniciar_backend, al final de este archivo).
#   - Cambio de app_version: NO se recrea ninguna instancia. La plataforma despliega la
#     versión nueva en sitio (SSM Run Command) y Ansible puede hacerlo para toda la flota.
#     cloud-init (user_data) solo se usa al primer arranque, por eso se ignoran sus cambios.
#   - Nueva AMI (Packer) o cambios en cloud-init: se aplican a instancias NUEVAS. Para
#     renovar una existente: terraform apply -replace=aws_instance.backend (y frontend,
#     que guarda la IP privada del backend). La db nunca se reemplaza sola: tiene los datos.

locals {
  # IMDSv2 obligatorio (protege las credenciales del rol frente a SSRF)
  metadata = {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
}

# ───────────── Instancia 1: base de datos ─────────────

resource "aws_instance" "db" {
  ami                    = local.ami
  instance_type          = local.recursos.tipo_db
  subnet_id              = data.aws_subnet.principal.id
  vpc_security_group_ids = [aws_security_group.db.id]
  key_name               = aws_key_pair.ssh.key_name
  iam_instance_profile   = aws_iam_instance_profile.servicio["db"].name

  metadata_options {
    http_endpoint = local.metadata.http_endpoint
    http_tokens   = local.metadata.http_tokens
  }

  root_block_device {
    volume_size = local.recursos.disco_db_gb
    volume_type = "gp3"
    encrypted   = true
  }

  # Sin secretos: la contraseña se lee de SSM dentro de la instancia
  user_data = replace(templatefile("${path.module}/cloud-init/db.yaml", {
    region      = var.region
    ssm_prefijo = local.ssm_prefijo
    vpc_cidr    = data.aws_vpc.default.cidr_block
  }), "\r", "")

  # El parámetro debe existir antes de que la instancia intente leerlo
  depends_on = [aws_ssm_parameter.db_password, aws_iam_role_policy.leer_secretos]

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${local.nombre}-db", Servicio = "db" }
}

# ───────────── Instancia 2: backend (Django) ─────────────

resource "aws_instance" "backend" {
  ami                    = local.ami
  instance_type          = local.recursos.tipo_backend
  subnet_id              = data.aws_subnet.principal.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  key_name               = aws_key_pair.ssh.key_name
  iam_instance_profile   = aws_iam_instance_profile.servicio["backend"].name

  metadata_options {
    http_endpoint = local.metadata.http_endpoint
    http_tokens   = local.metadata.http_tokens
  }

  root_block_device {
    volume_size = local.disco_app_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = replace(templatefile("${path.module}/cloud-init/backend.yaml", {
    region         = var.region
    ssm_prefijo    = local.ssm_prefijo
    repo_url       = var.repo_backend_url
    app_version    = var.app_version
    admin_usuario  = var.admin_usuario
    contacto_email = var.contacto_email
    vpc_cidr       = data.aws_vpc.default.cidr_block
  }), "\r", "")

  depends_on = [
    aws_ssm_parameter.backend_env,
    aws_ssm_parameter.admin_password,
    aws_iam_role_policy.leer_secretos,
  ]

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${local.nombre}-backend", Servicio = "backend" }
}

# ───────────── Instancia 3: frontend (React) ─────────────

resource "aws_instance" "frontend" {
  ami                    = local.ami
  instance_type          = local.recursos.tipo_frontend
  subnet_id              = data.aws_subnet.principal.id
  vpc_security_group_ids = [aws_security_group.frontend.id]
  key_name               = aws_key_pair.ssh.key_name
  iam_instance_profile   = aws_iam_instance_profile.servicio["frontend"].name

  metadata_options {
    http_endpoint = local.metadata.http_endpoint
    http_tokens   = local.metadata.http_tokens
  }

  root_block_device {
    volume_size = local.disco_app_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = replace(templatefile("${path.module}/cloud-init/frontend.yaml", {
    repo_url    = var.repo_frontend_url
    app_version = var.app_version
    backend_ip  = aws_instance.backend.private_ip
  }), "\r", "")

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${local.nombre}-frontend", Servicio = "frontend" }
}

# ───────────── Suspender / reanudar (RF-16, RF-17) ─────────────
# Política: al suspender se DETIENEN las 3 instancias. Se conservan los discos (datos de
# la base), la IP pública fija, los secretos y la configuración; solo se paga el disco y
# la IP. Al reanudar arrancan con la misma IP privada y los servicios se inician solos.

resource "aws_ec2_instance_state" "servicio" {
  for_each = {
    db       = aws_instance.db.id
    backend  = aws_instance.backend.id
    frontend = aws_instance.frontend.id
  }

  instance_id = each.value
  state       = var.suspendido ? "stopped" : "running"
}

# ───────────── Reinicio automático del backend al cambiar su .env ─────────────
# Cuando cambia el parámetro SSM backend/env (por ejemplo, los límites de un cambio de plan),
# cambia la huella y SSM vuelve a ejecutar el comando en la instancia: Gunicorn se reinicia
# y su ExecStartPre descarga el .env nuevo. Si el backend aún se está instalando, no hace nada.

resource "aws_ssm_association" "reiniciar_backend" {
  name             = "AWS-RunShellScript"
  association_name = "${local.nombre}-reiniciar-backend"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.backend.id]
  }

  parameters = {
    commands = join("\n", [
      "# huella del .env: ${nonsensitive(substr(sha256(aws_ssm_parameter.backend_env.value), 0, 12))}",
      "if systemctl is-active --quiet asistencia; then systemctl restart asistencia; fi",
    ])
  }
}

resource "aws_eip_association" "frontend" {
  instance_id   = aws_instance.frontend.id
  allocation_id = aws_eip.frontend.id
}
