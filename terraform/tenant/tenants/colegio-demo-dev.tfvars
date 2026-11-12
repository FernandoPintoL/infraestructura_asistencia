# Un archivo por tenant y entorno: tenants/<tenant_id>-<entorno>.tfvars
# NO lleva secretos: las contraseñas se generan y se guardan en SSM Parameter Store.

tenant_id      = "colegio-demo"
tenant_nombre  = "Colegio Demo"
contacto_email = "admin@colegio-demo.edu"
entorno        = "dev"
plan           = "basico" # basico | estandar | avanzado  (ver planes.tf)
app_version    = "main"   # rama o tag de git

# Opcional: tu IP para entrar por SSH (https://checkip.amazonaws.com + "/32").
# Vacío = sin SSH; se entra con Session Manager.
ssh_cidrs = []
