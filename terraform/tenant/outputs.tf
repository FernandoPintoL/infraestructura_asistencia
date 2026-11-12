# Ninguna salida contiene secretos: se indican los comandos para leerlos de SSM.

output "tenant" {
  value = {
    id       = var.tenant_id
    nombre   = var.tenant_nombre
    entorno  = var.entorno
    plan     = var.plan
    version  = var.app_version
    recursos = local.recursos
    ami      = local.ami
  }
}

output "url_frontend" {
  description = "Abre esta dirección en el navegador (espera 5 a 10 minutos a cloud-init)"
  value       = "http://${aws_eip.frontend.public_ip}"
}

output "url_panel_admin" {
  value = "http://${aws_eip.frontend.public_ip}/panel/login"
}

output "url_api" {
  value = "http://${aws_eip.frontend.public_ip}/api/modulo-activo/"
}

output "url_django_admin" {
  value = "http://${aws_eip.frontend.public_ip}/django-admin/"
}

# La plataforma usará estos IDs para suspender/reanudar (stop/start) el tenant
output "instancias" {
  value = {
    frontend = aws_instance.frontend.id
    backend  = aws_instance.backend.id
    db       = aws_instance.db.id
  }
}

output "ips_privadas" {
  value = {
    frontend = aws_instance.frontend.private_ip
    backend  = aws_instance.backend.private_ip
    db       = aws_instance.db.private_ip
  }
}

output "ssm_prefijo" {
  value = local.ssm_prefijo
}

output "suspendido" {
  value = var.suspendido
}

output "respaldos" {
  description = "Dónde guarda sus respaldos este tenant"
  value       = var.bucket_respaldos == "" ? "" : "s3://${var.bucket_respaldos}/${local.respaldos_prefijo}/"
}

output "leer_admin_password" {
  description = "Comando para ver la contraseña inicial del administrador del tenant"
  value       = "aws ssm get-parameter --region ${var.region} --name ${aws_ssm_parameter.admin_password.name} --with-decryption --query Parameter.Value --output text"
}

output "leer_llave_ssh" {
  description = "Comando para guardar la llave SSH privada del tenant"
  value       = "aws ssm get-parameter --region ${var.region} --name ${aws_ssm_parameter.ssh_privada.name} --with-decryption --query Parameter.Value --output text > ${local.nombre}.pem"
}

output "session_manager" {
  description = "Entrar a cada instancia sin SSH (requiere el plugin de Session Manager)"
  value = {
    frontend = "aws ssm start-session --region ${var.region} --target ${aws_instance.frontend.id}"
    backend  = "aws ssm start-session --region ${var.region} --target ${aws_instance.backend.id}"
    db       = "aws ssm start-session --region ${var.region} --target ${aws_instance.db.id}"
  }
}
