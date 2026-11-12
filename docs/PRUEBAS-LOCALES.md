# Probar la plataforma en local, sin AWS (modo simulado)

Guía para probar **toda la plataforma de tenants en tu PC**: crear tenants, cambiar planes,
suspender, respaldar, alertas, fallos y reintentos. **No se crea nada en la nube y no cuesta nada.**

> El modo simulado reemplaza Terraform/OpenTofu/Pulumi, los comandos en las instancias y Grafana
> por versiones que responden igual. Prueba la **plataforma** (pantallas, flujos, estados,
> permisos, historial). No prueba que los servidores reales de AWS funcionen: eso se hace al final
> con `IAC_SIMULADO=False`.

---

## 1 · Preparación (una sola vez)

| Necesitas | Comprobar |
|---|---|
| Python 3.12+ | `python --version` |
| Node.js 20+ | `node --version` |
| PostgreSQL con la base `asistencia_db` | pgAdmin o `psql -U postgres -l` |

```powershell
# Backend
cd asistencia_backend
python -m venv venv
venv\Scripts\pip install -r requirements.txt
copy .env.example .env          # si no existe; luego edítalo (paso 2)
venv\Scripts\python manage.py migrate
venv\Scripts\python manage.py crear_planes
venv\Scripts\python manage.py createsuperuser   # o crear_demo (usuario admin / admin1234)

# Frontend
cd ..\asistencia_frontend
npm ci
```

## 2 · Configurar `asistencia_backend/.env`

Además de la conexión a la base (`DB_*`), agrega:

```
PLATAFORMA_HABILITADA=True
IAC_SIMULADO=True
IAC_SIMULADO_SEG=1.0
IAC_SIMULADO_URL_APP=http://localhost:5174
CORS_ALLOWED_ORIGINS=http://localhost:5173,http://127.0.0.1:5173,http://localhost:5174,http://127.0.0.1:5174
```

| Variable | Para qué |
|---|---|
| `PLATAFORMA_HABILITADA` | Publica la API y las pantallas de la plataforma |
| `IAC_SIMULADO` | Todo simulado: **nunca** llama a AWS |
| `IAC_SIMULADO_SEG` | Segundos que dura cada paso simulado (`0.2` = muy rápido, `3` = para una demo pausada) |
| `IAC_SIMULADO_URL_APP` | A dónde lleva el enlace "Aplicación" de cada tenant (la app local) |
| `CORS_ALLOWED_ORIGINS` | Permite que la plataforma (5173) y la app (5174) llamen al backend |

## 3 · Levantar todo

Cierra antes cualquier `runserver` o `npm run dev` que tengas abierto, y desde la **raíz** del proyecto:

```powershell
powershell -ExecutionPolicy Bypass -File .\iniciar-local.ps1
```

Se abren 4 ventanas:

| Ventana | Qué es | Dirección |
|---|---|---|
| Backend :8000 | API de Django | http://127.0.0.1:8000 |
| Worker | Ejecuta las operaciones en segundo plano | — |
| Plataforma :5173 | Administración de tenants | **http://localhost:5173/plataforma** |
| App de asistencia :5174 | Lo que ve cada institución | **http://localhost:5174** |

Entra a la plataforma con tu superusuario (con `crear_demo`: **admin / admin1234**). La barra
superior debe mostrar el aviso amarillo **Modo simulado**.

<details>
<summary>Sin el script (4 terminales a mano)</summary>

```powershell
# 1. Backend
cd asistencia_backend; venv\Scripts\python manage.py runserver
# 2. Worker
cd asistencia_backend; venv\Scripts\python manage.py worker_plataforma
# 3. Plataforma
cd asistencia_frontend; $env:VITE_PLATAFORMA="true"; npx vite --port 5173
# 4. App de asistencia
cd asistencia_frontend; npx vite --port 5174
```
</details>

## 4 · Qué probar (lista de verificación)

| # | Prueba | Cómo | Qué deberías ver |
|---|---|---|---|
| 1 | Crear tenants con distintos planes y motores | *Nuevo tenant*: uno Básico con Terraform y otro Estándar con Pulumi | Operación con barra de progreso y log en vivo → *Exitosa*; versiones registradas (motor "simulado") |
| 2 | Filtrar tenants | *Tenants*: filtros por nombre, estado, plan y entorno | La lista se filtra; la URL guarda los filtros |
| 3 | Ver qué cambia antes de cambiar de plan | Tenant → *Cambiar plan* → elegir otro | Tabla *Qué cambiará* (instancias, disco, límites, efecto) |
| 4 | Detalle exacto con el motor | *Ver detalle exacto con el motor* | Operación *Previsualizar* con la lista de recursos a modificar |
| 5 | Cambiar de plan | *Confirmar cambio de plan* | El plan del tenant cambia al terminar |
| 6 | Suspender y reanudar | Tenant → *Suspender* → *Reanudar* | Estado *Suspendido* con aviso, respaldo automático en la lista; luego *Activo* |
| 7 | Respaldar y restaurar | *Respaldar ahora* → en la lista, *Restaurar* (escribir el identificador) | Respaldo con fecha de vencimiento según el plan; la restauración toma antes un respaldo de seguridad |
| 8 | Actualizar la versión | *Actualizar* con `v2.0` | Despliegue en sitio: commits del backend y frontend en las versiones |
| 9 | Error y reintento | Crear un tenant con versión **`falla-una-vez`** | Operación *Fallida* con mensaje comprensible → *Reintentar* → *Exitosa* |
| 10 | Error permanente | Crear un tenant con versión **`falla`** | Mensaje "límite de IPs elásticas"; el tenant queda *Con error* |
| 11 | Error al desplegar | *Actualizar* con versión **`falla-despliegue`** | Falla en el despliegue; el log muestra `couldn't find remote ref` |
| 12 | Alertas | *Alertas* → panel **Modo simulado · probar alertas** → *Disparar* / *Resolver* | Alerta con tenant y hora; campana en la lista de tenants; luego *Resuelta* |
| 13 | Eliminar | Tenant → *Eliminar* → escribir el identificador | Lista de recursos y datos; respaldo final; estado *Eliminado* |
| 14 | Admin de un tenant | En `/django-admin/` crear un usuario y agregarlo como administrador de un tenant; entrar con él | Solo ve *Mis servicios* y sus alertas; no ve los demás tenants |
| 15 | Aislamiento | `venv\Scripts\python manage.py probar_aislamiento <a>:dev <b>:dev` | 11 pruebas ✅ (red, secretos, respaldos, tokens) |
| 16 | La app del tenant | Enlace *Aplicación* del tenant | Abre la app de asistencia local (5174) |

### Versiones especiales (fallos a pedido)

| Versión de la app | Dónde | Resultado |
|---|---|---|
| `falla` | Crear o actualizar | Error permanente (límite de IPs elásticas) |
| `falla-una-vez` | Crear o actualizar | Falla la primera vez (sin conexión); el reintento funciona |
| `falla-despliegue` | Actualizar | Falla el despliegue de la versión (rama inexistente) |
| cualquier otra | — | Funciona |

## 5 · Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| El login de la plataforma dice error aunque la contraseña es correcta | Hay un backend viejo corriendo, iniciado antes de cambiar el `.env` (Django no relee el `.env`) | Ciérralo y vuelve a correr `iniciar-local.ps1` |
| No aparece el aviso **Modo simulado** | Falta `IAC_SIMULADO=True` o el backend no se reinició | Revisa el `.env` y reinicia el backend y el worker |
| Una operación se queda *En cola* | El worker no está corriendo | Abre la ventana *Worker* o `manage.py worker_plataforma` |
| "Port 5173 is already in use" | Ya hay otro `npm run dev` abierto | Ciérralo (o cámbiale el puerto) |
| Error de CORS en la consola del navegador | Falta el puerto en `CORS_ALLOWED_ORIGINS` | Agrega `http://localhost:5174` (y 5173) y reinicia el backend |
| No recuerdo la contraseña del admin | — | `venv\Scripts\python manage.py changepassword admin` |
| El motor "CloudFormation" sale deshabilitado | Es intencional | Ver [COMPARACION-MOTORES.md](COMPARACION-MOTORES.md) |

## 6 · Empezar de cero

Para borrar los tenants de prueba sin tocar la app de asistencia:

```powershell
cd asistencia_backend
venv\Scripts\python manage.py shell -c "from plataforma.models import *; Alerta.objects.all().delete(); Auditoria.objects.all().delete(); Respaldo.objects.all().delete(); Operacion.objects.all().delete(); Tenant.objects.all().delete()"
Remove-Item -Recurse -Force .iac-trabajo\simulado -ErrorAction SilentlyContinue
```

## 7 · Pasar a AWS

Cuando la plataforma esté probada: `IAC_SIMULADO=False` en el `.env`, y seguir la puesta en
marcha de [OPERACIONES.md](OPERACIONES.md#0--puesta-en-marcha-una-vez) (bootstrap, monitoreo,
credenciales). El resto del flujo es idéntico.
