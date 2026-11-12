# Plataforma de tenants · Sistema de asistencia

Plataforma para crear y administrar **tenants** (instituciones educativas) de la aplicación de
registro de asistencia. Cada tenant tiene su propio **frontend, backend y base de datos** en AWS
(3 EC2), elegidos según un **plan**, aprovisionados con **Terraform, OpenTofu o Pulumi**,
monitoreados con **Grafana**, y con suspensión, respaldos y eliminación controlada.

## Estructura

| Carpeta | Contenido |
|---|---|
| [`asistencia_backend/`](asistencia_backend/README.md) | Django: la app de asistencia (lo que corre en cada tenant) + `plataforma/` (planes, tenants, operaciones, worker, motores, respaldos, alertas) |
| [`asistencia_frontend/`](asistencia_frontend/README.md) | React: la app de asistencia + `src/plataforma/` (pantallas de la plataforma, solo con `VITE_PLATAFORMA=true`) |
| [`infraestructura/terraform/`](infraestructura/terraform/README.md) | `bootstrap/` (estado y respaldos), `tenant/` (un tenant), `monitoreo/` (Prometheus + Grafana) |
| [`infraestructura/pulumi/`](infraestructura/pulumi/tenant/__main__.py) | El mismo tenant en Pulumi (segunda implementación) |
| [`infraestructura/packer/`](infraestructura/packer/README.md) | Imagen base (AMI) |
| [`infraestructura/ansible/`](infraestructura/ansible/README.md) | Configuración posterior de la flota de tenants |
| [`docs/`](docs/) | Arquitectura, planes, operación, comparación de motores y guion de la demo |
| [`anteriores/`](anteriores/README.md) | Trabajos previos del módulo (un solo sistema con cada herramienta). No los usa la plataforma |

## Documentos (entregables)

| # | Entregable | Documento |
|---|---|---|
| 1 | Código del frontend y backend | `asistencia_frontend/`, `asistencia_backend/` |
| 2 | Código de infraestructura y configuración | `infraestructura/` |
| 3 | Diagrama de arquitectura y flujo de creación de un tenant | [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md) |
| 4 | Catálogo de planes y límites | [docs/PLANES.md](docs/PLANES.md) |
| 5 | Tablero de Grafana con métricas y alertas | [monitoreo/README.md](infraestructura/terraform/monitoreo/README.md) · [tablero](infraestructura/terraform/monitoreo/config/grafana/dashboards/tenants.json) · [reglas](infraestructura/terraform/monitoreo/config/grafana/provisioning/alerting/reglas.yml) |
| 6 | Instrucciones de operación | [docs/OPERACIONES.md](docs/OPERACIONES.md) |
| 7 | Evidencia de aislamiento entre tenants | `manage.py probar_aislamiento` → `docs/evidencia-aislamiento.md` · [cómo](docs/OPERACIONES.md#probar-el-aislamiento-entre-tenants-entregable-7) |
| 8 | Demostración y diseño | [docs/GUIA-DEMO.md](docs/GUIA-DEMO.md) · [comparación de motores](docs/COMPARACION-MOTORES.md) |

## Requisitos → implementación

| Requisito | Implementación | Pruebas |
|---|---|---|
| RF-01–04 Catálogo de planes, recursos, elección, edición | `Plan`, pantalla *Planes*, tarjetas en *Nuevo tenant*, auditoría de cambios | `CambioPlanTests` |
| RF-05 No exceder límites | `MAX_ESTUDIANTES` / `MAX_MODULOS` en el backend del tenant + alertas de Grafana | `LimitesPlanTests` |
| RF-06 Cambiar plan y ver qué cambia | `diferencias_plan`, *Cambiar plan*, preview del motor | `CambioPlanTests` |
| RF-07–08 Crear tenant y elegir motor | *Nuevo tenant*; motores Terraform, OpenTofu, Pulumi | `CreacionTests`, `MotorPulumiTests` |
| RF-09–10 Recursos y conexión a la base | Plantillas Terraform/Pulumi + cloud-init (secretos por SSM) | `test_programa.py` (Pulumi) |
| RF-11 Progreso y errores comprensibles | Operaciones con paso, %, log sin secretos, `traducir_error` | `SeguridadTests`, `FallosYReintentosTests` |
| RF-12 Reintentar sin duplicar | `reintentar` + estado de IaC en S3 | `FallosYReintentosTests` |
| RF-13 Versiones registradas | Motor, plantilla (sha256), proveedores, AMI, app, commits | `CreacionTests`, `DespliegueTests` |
| RF-14 Consultar tenants | Filtros por nombre, estado, plan, entorno | `test_filtrar_tenants` |
| RF-15 Actualizar app e infraestructura | Apply + despliegue en sitio por SSM; Ansible para la flota | `DespliegueTests` |
| RF-16–17 Suspender / reanudar, política | `aws_ec2_instance_state` + respaldo previo; [política](infraestructura/terraform/README.md#suspender-reanudar-y-respaldos) | `SuspensionYRespaldosTests` |
| RF-18 Confirmar antes de eliminar | Resumen de recursos y datos + identificador + respaldo final | `EliminacionTests` |
| RF-19 Respaldar y restaurar | `pg_dump`/`pg_restore` por SSM a S3, retención por plan | `SuspensionYRespaldosTests` |
| RF-20 Quién, cuándo, resultado | `Operacion` + `Auditoria` | varias |
| RF-21 Requisitos de la app | `asistencia_backend/asistencia` (sin cambios funcionales) | 28 pruebas de la app |
| RF-25–28 Grafana, métricas, alertas | `terraform/monitoreo`, `/metrics` de Django, 10 reglas | `MetricasTests` |
| RF-29 Alertas en la plataforma | `Alerta`, sincronización con la API de Grafana, pantalla *Alertas* | `MonitoreoTests` |
| No funcionales | Aislamiento silo, secretos en SSM, estado en S3 cifrado, trabajos en segundo plano, operaciones idempotentes, costos | `AislamientoTests`, `PermisosTests`, [arquitectura](docs/ARQUITECTURA.md) |

## Probar en local sin AWS
Modo simulado: `IAC_SIMULADO=True` en `asistencia_backend/.env` y `.\iniciar-local.ps1`.
Toda la plataforma funciona (crear, cambiar plan, suspender, respaldar, alertas, fallos y reintentos)
sin crear nada en la nube. Guía paso a paso: [docs/PRUEBAS-LOCALES.md](docs/PRUEBAS-LOCALES.md).

## Credenciales
Qué usuario y contraseña tiene cada cosa (AWS, plataforma, Grafana, admin de cada tenant) y cómo
leerlas de SSM: [docs/CREDENCIALES.md](docs/CREDENCIALES.md).

## Pruebas
```powershell
cd asistencia_backend; $env:DB_ENGINE="sqlite"; python manage.py test      # app + plataforma
cd infraestructura\pulumi\tenant; python -m pytest test_programa.py         # programa de Pulumi con mocks
cd infraestructura\terraform\tenant; terraform validate                     # plantillas
```
