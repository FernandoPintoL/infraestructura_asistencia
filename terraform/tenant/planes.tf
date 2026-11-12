# ───────────── Catálogo de planes (RF-01, RF-02) ─────────────
# Los 3 planes usan 3 instancias separadas (frontend, backend, base de datos).
# Lo que cambia es el tamaño de cada una, el disco de la base y los límites de uso.
#
# Este catálogo es el valor por defecto. La plataforma puede enviar sus propios valores
# con la variable "recursos" (los planes editados por el administrador, RF-04).
#
# Disco de la base: EBS solo puede CRECER. Al bajar de plan, la plataforma debe enviar
# max(disco_actual, disco_nuevo); Terraform fallaría si se intenta reducir.

locals {
  catalogo = {
    basico = {
      tipo_frontend   = "t3.micro"
      tipo_backend    = "t3.micro"
      tipo_db         = "t3.micro"
      disco_db_gb     = 10
      max_estudiantes = 100
      max_modulos     = 2
    }
    estandar = {
      tipo_frontend   = "t3.micro"
      tipo_backend    = "t3.small"
      tipo_db         = "t3.small"
      disco_db_gb     = 20
      max_estudiantes = 500
      max_modulos     = 10
    }
    avanzado = {
      tipo_frontend   = "t3.small"
      tipo_backend    = "t3.medium"
      tipo_db         = "t3.medium"
      disco_db_gb     = 40
      max_estudiantes = 2000
      max_modulos     = 50
    }
  }

  recursos = var.recursos != null ? var.recursos : local.catalogo[var.plan]

  disco_app_gb = 12 # frontend y backend: sistema + código + dependencias
}
