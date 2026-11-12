# Ejecuta Terraform u OpenTofu para UN tenant, con su propio estado en S3.
# Es lo mismo que hara despues el worker de la plataforma, pero a mano.
#
# Uso (PowerShell, en esta carpeta):
#   .\tenant.ps1 -Tenant colegio-demo -Entorno dev                       # plan: muestra, NO crea nada
#   .\tenant.ps1 -Tenant colegio-demo -Entorno dev -Accion apply         # crea/actualiza (pide "yes")
#   .\tenant.ps1 -Tenant colegio-demo -Entorno dev -Accion output        # URLs y comandos
#   .\tenant.ps1 -Tenant colegio-demo -Entorno dev -Accion plan-destroy  # que se borraria
#   .\tenant.ps1 -Tenant colegio-demo -Entorno dev -Accion destroy       # borra (pide "yes")
#   Agrega -Motor tofu para usar OpenTofu en lugar de Terraform.

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9-]{1,18}[a-z0-9]$')]
    [string]$Tenant,

    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Entorno,

    [ValidateSet('init', 'validate', 'plan', 'apply', 'output', 'plan-destroy', 'destroy')]
    [string]$Accion = 'plan',

    [ValidateSet('terraform', 'tofu')]
    [string]$Motor = 'terraform'
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$vars = "tenants/$Tenant-$Entorno.tfvars"
if (-not (Test-Path 'backend.hcl')) {
    throw "Falta backend.hcl. Ejecuta primero bootstrap/ (ver README.md)."
}
if (-not (Test-Path $vars)) {
    throw "Falta $vars. Copia tenants/colegio-demo-dev.tfvars y editalo."
}

# El archivo debe corresponder al tenant y entorno pedidos (evita pisar el estado de otro)
$contenido = Get-Content $vars -Raw
if ($contenido -notmatch ('tenant_id\s*=\s*"' + $Tenant + '"') -or
    $contenido -notmatch ('entorno\s*=\s*"' + $Entorno + '"')) {
    throw "$vars no coincide con -Tenant $Tenant -Entorno $Entorno."
}

# Carpeta de trabajo propia por tenant: varios tenants sin mezclar estados ni bloqueos
$env:TF_DATA_DIR = ".terraform-tenants/$Tenant-$Entorno"
$key = "tenants/$Tenant/$Entorno/terraform.tfstate"

function Ejecutar {
    & $Motor @args
    if ($LASTEXITCODE -ne 0) { throw "Fallo: $Motor $($args -join ' ')" }
}

Write-Host "== $Motor | tenant $Tenant | entorno $Entorno | estado s3://.../$key" -ForegroundColor Cyan
Ejecutar init -input=false -backend-config=backend.hcl "-backend-config=key=$key"

switch ($Accion) {
    'init'         { }
    'validate'     { Ejecutar validate }
    'plan'         { Ejecutar plan "-var-file=$vars" }
    'apply'        { Ejecutar apply "-var-file=$vars" }
    'output'       { Ejecutar output }
    'plan-destroy' { Ejecutar plan -destroy "-var-file=$vars" }
    'destroy'      { Ejecutar destroy "-var-file=$vars" }
}
