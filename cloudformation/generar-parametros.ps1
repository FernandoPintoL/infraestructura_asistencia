# Genera parametros.json para la pila de CloudFormation:
#   - busca tu IP pública, la VPC y la subnet por defecto
#   - crea contraseñas aleatorias para PostgreSQL y Django
#   - usa la contraseña de administrador que le pases
#
# Uso:  powershell -ExecutionPolicy Bypass -File .\generar-parametros.ps1 -AdminPassword "TuClave2026"

param(
    [Parameter(Mandatory = $true)][string]$AdminPassword,
    [string]$AdminUsuario = "admin",
    [switch]$Forzar
)
$ErrorActionPreference = "Stop"
$archivo = Join-Path $PSScriptRoot "parametros.json"

# Las contraseñas deben ser siempre las mismas para una pila ya creada
if ((Test-Path $archivo) -and -not $Forzar) {
    throw "parametros.json ya existe. Usa -Forzar solo si vas a crear una pila nueva."
}
if ($AdminPassword.Length -lt 8 -or $AdminPassword -match "['""$``\\]") {
    throw "La contraseña de administrador necesita mínimo 8 caracteres y sin comillas, $, `` ni \."
}

function Nueva-Clave([int]$largo) {
    $letras = [char[]]"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    $bytes = New-Object byte[] $largo
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $letras[$_ % $letras.Length] })
}

$region = (aws configure get region).Trim()
$vpc = (aws ec2 describe-vpcs --filters Name=is-default,Values=true --query "Vpcs[0].[VpcId,CidrBlock]" --output text).Trim() -split "\s+"
$subnet = (aws ec2 describe-subnets --filters Name=vpc-id,Values=$($vpc[0]) Name=default-for-az,Values=true `
        Name=availability-zone,Values="$($region)a" --query "Subnets[0].SubnetId" --output text).Trim()
$miIp = (Invoke-RestMethod https://checkip.amazonaws.com).Trim() + "/32"

$parametros = @(
    "MiIp=$miIp"
    "VpcId=$($vpc[0])"
    "VpcCidr=$($vpc[1])"
    "SubnetId=$subnet"
    "AdminUsuario=$AdminUsuario"
    "AdminPassword=$AdminPassword"
    "DbPassword=$(Nueva-Clave 24)"
    "DjangoSecretKey=$(Nueva-Clave 60)"
)

# UTF-8 sin BOM: el AWS CLI no acepta el BOM que agrega PowerShell 5.1
[IO.File]::WriteAllText($archivo, (ConvertTo-Json $parametros), (New-Object Text.UTF8Encoding $false))

Write-Host "parametros.json creado:"
Write-Host "  Region   $region"
Write-Host "  MiIp     $miIp"
Write-Host "  VPC      $($vpc[0]) ($($vpc[1]))"
Write-Host "  Subnet   $subnet"
Write-Host "  Admin    $AdminUsuario (contraseñas guardadas en el archivo, no se muestran)"
