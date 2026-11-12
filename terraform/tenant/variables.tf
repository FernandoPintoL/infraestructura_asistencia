# ───────────── Identidad del tenant (RF-07) ─────────────

variable "tenant_id" {
  description = "Identificador único del tenant (minúsculas, números y guiones). Se usa en nombres de recursos"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.tenant_id))
    error_message = "De 3 a 20 caracteres: minúsculas, números y guiones; empieza con letra y no termina en guion."
  }
}

variable "tenant_nombre" {
  description = "Nombre de la institución educativa"
  type        = string

  validation {
    condition     = length(var.tenant_nombre) >= 3 && length(var.tenant_nombre) <= 80 && !can(regex("[\"'$`\\\\]", var.tenant_nombre))
    error_message = "De 3 a 80 caracteres y sin comillas, $, ` ni \\."
  }
}

variable "contacto_email" {
  description = "Correo de contacto del tenant (también es el correo del administrador)"
  type        = string

  validation {
    condition     = can(regex("^[^@\\s\"'$`]+@[^@\\s\"'$`]+\\.[^@\\s\"'$`]+$", var.contacto_email))
    error_message = "Debe ser un correo válido."
  }
}

variable "entorno" {
  description = "Entorno del tenant"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.entorno)
    error_message = "Valores permitidos: dev, staging, prod."
  }
}

variable "plan" {
  description = "Código del plan contratado. Ver el catálogo en planes.tf"
  type        = string
  default     = "basico"

  # Con "recursos" (lo envía la plataforma) el plan puede tener cualquier código creado
  # por el administrador; sin "recursos" debe existir en el catálogo de planes.tf.
  validation {
    condition = can(regex("^[a-z][a-z0-9-]{1,29}$", var.plan)) && (
      var.recursos != null || contains(["basico", "estandar", "avanzado"], var.plan)
    )
    error_message = "Sin la variable recursos, el plan debe ser basico, estandar o avanzado."
  }
}

# La plataforma guarda los planes en su base de datos (RF-04: el administrador los
# modifica) y pasa aquí los recursos concretos. Si es null se usa el catálogo de planes.tf.
variable "recursos" {
  description = "Recursos explícitos del plan (lo envía la plataforma). null = usar el catálogo por defecto"
  type = object({
    tipo_frontend   = string
    tipo_backend    = string
    tipo_db         = string
    disco_db_gb     = number
    max_estudiantes = number
    max_modulos     = number
  })
  default = null
}

# ───────────── Aplicación ─────────────

variable "repo_backend_url" {
  description = "URL HTTPS del repositorio del backend (público)"
  type        = string
  default     = "https://github.com/FernandoPintoL/asistencia_backend.git"
}

variable "repo_frontend_url" {
  description = "URL HTTPS del repositorio del frontend (público)"
  type        = string
  default     = "https://github.com/FernandoPintoL/asistencia_frontend.git"
}

variable "app_version" {
  description = "Rama o tag de git que se despliega en ambos repositorios (RF-13)"
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.app_version))
    error_message = "Solo letras, números, punto, guion, guion bajo y /."
  }
}

variable "admin_usuario" {
  description = "Usuario administrador del tenant (la contraseña se genera y se guarda en SSM)"
  type        = string
  default     = "admin"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{3,30}$", var.admin_usuario))
    error_message = "De 3 a 30 caracteres: letras, números, punto, guion o guion bajo."
  }
}

# ───────────── Infraestructura ─────────────

variable "region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "AMI a usar (más adelante, la de Packer). null = última Ubuntu 24.04 de Canonical"
  type        = string
  default     = null
}

variable "suspendido" {
  description = "true = las 3 instancias se detienen (RF-16). Discos, datos e IP se conservan"
  type        = bool
  default     = false
}

variable "bucket_respaldos" {
  description = "Bucket S3 de respaldos (lo crea bootstrap/). Vacío = la base no puede respaldarse en S3"
  type        = string
  default     = ""
}

variable "monitoreo_sg_id" {
  description = "Security group del servidor de monitoreo (salida de terraform/monitoreo). Vacío = sin métricas"
  type        = string
  default     = ""
}

variable "ssh_cidrs" {
  description = "IPs (CIDR) que pueden entrar por SSH. Vacío = sin SSH (se entra con Session Manager)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.ssh_cidrs : can(cidrhost(c, 0))])
    error_message = "Cada elemento debe ser un CIDR, por ejemplo 181.115.10.20/32."
  }
}
