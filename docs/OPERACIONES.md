# Instrucciones de operación (entregable 6)

## Probar todo en local, sin AWS (modo simulado)
Guía completa, con lista de verificación y solución de problemas: [PRUEBAS-LOCALES.md](PRUEBAS-LOCALES.md).

Para probar la plataforma y su interfaz sin crear nada en la nube. En `asistencia_backend/.env`:
```
PLATAFORMA_HABILITADA=True
IAC_SIMULADO=True
IAC_SIMULADO_URL_APP=http://localhost:5174    # el enlace "Aplicación" abre la app local
CORS_ALLOWED_ORIGINS=http://localhost:5173,http://127.0.0.1:5173,http://localhost:5174,http://127.0.0.1:5174
```
y luego, en la raíz: `powershell -ExecutionPolicy Bypass -File .\iniciar-local.ps1` (abre backend,
worker, plataforma en **:5173** y app de asistencia en **:5174**). La barra muestra **Modo simulado**.

| Qué se simula | Cómo |
|---|---|
| Terraform / OpenTofu / Pulumi | Pasos, log, progreso y recursos que cambian según el plan; salidas con la misma forma |
| Respaldar, restaurar, desplegar versiones, prueba de aislamiento | Respuestas de las instancias (respetando el aislamiento entre tenants) |
| Alertas de Grafana | Panel **Modo simulado · probar alertas** en *Alertas*: disparar y resolver |
| Fallos, para probar errores y *Reintentar* | Versión `falla` (error permanente), `falla-una-vez` (el reintento funciona), `falla-despliegue` (al *Actualizar*) |

`IAC_SIMULADO_SEG` ajusta cuánto dura cada paso (1 s por defecto). Para volver a AWS: `IAC_SIMULADO=False`.

## 0 · Puesta en marcha (una vez)

| # | Qué | Comando / dónde | Detalle |
|---|---|---|---|
| 1 | Credenciales de AWS | `aws configure` | Usuario con permisos sobre EC2, IAM, SSM, S3 |
| 2 | Estado y respaldos | `infraestructura/terraform/bootstrap` → `terraform apply` | Buckets S3; genera `tenant/backend.hcl` |
| 3 | Imagen base (opcional) | `infraestructura/packer` → `packer build .` | AMI en `manifest.json` → `IAC_AMI_ID` |
| 4 | Monitoreo | `infraestructura/terraform/monitoreo` → `terraform apply -var 'acceso_cidrs=["<tu IP>/32"]'` | Grafana; `IAC_MONITOREO_SG`, `GRAFANA_URL`, `GRAFANA_TOKEN` |
| 5 | Plataforma | `asistencia_backend` con `.env` (ver `.env.example`) | `migrate`, `crear_planes`, `createsuperuser`, `runserver` |
| 6 | Worker | `python manage.py worker_plataforma` (otra terminal) | Ejecuta las operaciones, sincroniza alertas y purga respaldos |
| 7 | Frontend | `asistencia_frontend` → `VITE_PLATAFORMA=true npm run dev` | http://localhost:5173/plataforma |

Variables mínimas del `.env` de la plataforma: `PLATAFORMA_HABILITADA=True`, `DB_*`,
`IAC_BUCKET_RESPALDOS`. Opcionales: `IAC_AMI_ID`, `IAC_MONITOREO_SG`, `GRAFANA_URL`, `GRAFANA_TOKEN`,
`IAC_PULUMI_BACKEND` (+ `PULUMI_CONFIG_PASSPHRASE` en el entorno del worker, solo para Pulumi).

Cada operación se puede hacer de tres formas: **pantalla** de la plataforma, **API**
(`/api/plataforma/...`, token de `login/`) o **a mano** con `infraestructura/terraform/tenant/tenant.ps1`.
Todas quedan registradas: quién, cuándo, resultado, versiones y log (RF-20).

---

## Credenciales
Qué credenciales existen (AWS, plataforma, Grafana, admin de cada tenant, base, SSH) y cómo leerlas
de SSM: [CREDENCIALES.md](CREDENCIALES.md).

## Crear un tenant (RF-07 a RF-11)
- **Pantalla**: *Nuevo tenant* → nombre, identificador (se sugiere solo), contacto, **plan**
  (tarjetas con sus características), entorno, **motor**, versión → *Crear tenant y desplegar*.
  Se abre la operación con su progreso en vivo.
- **API**: `POST /tenants/` `{"nombre","identificador","contacto_email","entorno","plan","motor","app_version"}`.
- **A mano**: copiar `tenants/colegio-demo-dev.tfvars` → `.\tenant.ps1 -Tenant <id> -Entorno dev -Accion apply`.
- Resultado: URL de la app; la contraseña del admin del tenant se lee con el comando `leer_admin_password`.
  La app responde en 1–3 min (con la AMI de Packer) o 5–10 min (Ubuntu limpio).

## Reintentar una operación fallida (RF-12)
Operación → mensaje de error comprensible → **Reintentar** (`POST /operaciones/<id>/reintentar/`).
Crea una operación nueva con los mismos parámetros, enlazada a la fallida. No duplica recursos: el
motor compara con el estado guardado y solo crea lo que falta. Si el estado quedó bloqueado por un
worker caído: `terraform force-unlock <id>` (el mensaje lo indica).

## Actualizar (RF-15)
- **Infraestructura**: *Actualizar* sin cambiar la versión (vuelve a aplicar la plantilla).
- **Aplicación**: *Actualizar* con otra rama/tag → se despliega **en los mismos servidores**: backend
  (dependencias, migraciones, reinicio, prueba de la API) y luego frontend (compilación, cambio atómico).
  Los commits quedan en las versiones de la operación.
- **Muchos tenants a la vez**: `ansible-playbook actualizar-app.yml -e version=v1.2.0 -l entorno_staging`.

## Cambiar de plan (RF-06)
*Cambiar plan* → elegir plan → tabla **Qué cambiará** (recurso, actual, nuevo, efecto) → *Confirmar*.
Opcional: *Ver detalle exacto con el motor* (plan/preview sin aplicar). Detalle de efectos en [PLANES.md](PLANES.md).

## Suspender y reanudar (RF-16, RF-17)
- *Suspender* → se toma un **respaldo** y se **detienen las 3 instancias**. Se conservan base de datos,
  configuración, secretos y dirección web. Solo se paga disco + IP.
- *Reanudar* → se encienden; los servicios arrancan solos con la misma URL.
- Suspendido se puede cambiar de plan (se aplica al reanudar), pero no actualizar la app.
- A mano: `suspendido = true` en el `.tfvars` y `apply`.

## Respaldar y restaurar (RF-19)
- *Respaldar ahora* → `pg_dump` dentro de la instancia db → S3 (`tenants/<id>/<entorno>/`).
  Retención según el plan (7/14/30 días); el worker borra los vencidos.
- *Restaurar* (en la lista de respaldos) → escribir el identificador → se toma un respaldo de
  seguridad, se verifica el sha256, se detiene el backend, `pg_restore` en **una sola transacción**
  (si falla, los datos quedan como estaban) y se vuelve a encender el backend.
- Un tenant eliminado y vuelto a crear con el mismo identificador puede restaurar su respaldo final.

## Eliminar (RF-18)
*Eliminar* → la pantalla lista **recursos** que se borrarán en AWS, **datos** que se perderán y lo que
se conserva → escribir el identificador → *Eliminar definitivamente*. Por defecto se toma un
**respaldo final** (30 días). Opcional: *Ver lista exacta con el motor* (`plan -destroy`).
A mano: `.\tenant.ps1 -Tenant <id> -Entorno dev -Accion plan-destroy` y luego `-Accion destroy`.

## Consultar tenants, operaciones, alertas (RF-14, RF-20, RF-29)
- *Tenants*: filtros por nombre, estado, plan y entorno; campana con alertas activas.
- *Operaciones*: historial con quién, cuándo, resultado y duración; detalle con log y versiones.
- *Alertas*: tenant, severidad, hora de detección y de resolución; enlace a Grafana.
- *Auditoría*: cambios de planes, altas, solicitudes y reintentos.
- El **administrador de un tenant** entra a la misma plataforma y solo ve *Mis servicios* y sus alertas.

## Probar el aislamiento entre tenants (entregable 7)
```powershell
python manage.py probar_aislamiento colegio-a:dev colegio-b:dev --salida ..\docs\evidencia-aislamiento.md
```
Desde las instancias de B intenta llegar a la base y al backend de A (red), leer los secretos de A
(IAM/SSM), escribir en sus respaldos (S3) y usar un token de B en la API de A; cada vía tiene una
prueba de control. Genera un informe con fecha (✅/❌ por prueba).

## Controlar costos
- Suspender los tenants que no se usan; eliminar los de prueba.
- `terraform destroy` del monitoreo al terminar la demo.
- Desregistrar AMIs viejas de Packer.
- Los buckets de estado y respaldos tienen `prevent_destroy` a propósito: se borran a mano.
