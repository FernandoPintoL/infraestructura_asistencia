# Levanta TODO en local para probar la plataforma sin AWS (modo simulado).
# Abre 4 ventanas: backend, worker, plataforma (5173) y app de asistencia (5174).
#
# Uso (PowerShell, en la carpeta infraestructura):
#   powershell -ExecutionPolicy Bypass -File .\iniciar-local.ps1
#
# Requisitos (una vez): asistencia_backend\venv con requirements.txt, npm ci en asistencia_frontend,
# y en asistencia_backend\.env: PLATAFORMA_HABILITADA=True e IAC_SIMULADO=True.
# Para cerrar todo: cierra las 4 ventanas.

# Este script vive en infraestructura/; el backend y el frontend están al lado (carpetas hermanas).
$raiz = Split-Path $PSScriptRoot -Parent
$back = Join-Path $raiz "asistencia_backend"
$front = Join-Path $raiz "asistencia_frontend"
$py = Join-Path $back "venv\Scripts\python.exe"

if (-not (Test-Path $py)) { throw "Falta el venv del backend: cd asistencia_backend; python -m venv venv; venv\Scripts\pip install -r requirements.txt" }
if (-not (Test-Path (Join-Path $front "node_modules"))) { throw "Faltan las dependencias del frontend: cd asistencia_frontend; npm ci" }

function Ventana($titulo, $carpeta, $comando) {
    Start-Process powershell -WorkingDirectory $carpeta -ArgumentList @(
        "-NoExit", "-Command", "`$Host.UI.RawUI.WindowTitle = '$titulo'; $comando"
    )
}

& $py (Join-Path $back "manage.py") migrate --noinput
& $py (Join-Path $back "manage.py") crear_planes

Ventana "Backend :8000" $back "& '$py' manage.py runserver 127.0.0.1:8000"
Ventana "Worker" $back "& '$py' manage.py worker_plataforma"
Ventana "Plataforma :5173" $front "`$env:VITE_PLATAFORMA='true'; npx vite --port 5173 --strictPort"
Ventana "App de asistencia :5174" $front "Remove-Item Env:VITE_PLATAFORMA -ErrorAction SilentlyContinue; npx vite --port 5174 --strictPort"

Write-Host ""
Write-Host "Listo. En unos segundos:" -ForegroundColor Green
Write-Host "  Plataforma:        http://localhost:5173/plataforma   (usuario admin de Django)"
Write-Host "  App de asistencia: http://localhost:5174              (lo que ve cada tenant)"
Write-Host "  Modo simulado: no se crea nada en AWS."
