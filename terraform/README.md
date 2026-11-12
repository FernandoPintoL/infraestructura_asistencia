# Infraestructura por tenant · Terraform / OpenTofu

Cada **tenant** (institución educativa) tiene su propio stack en AWS: **3 instancias EC2
separadas** (frontend, backend y base de datos), sus propios firewalls, rol IAM, secretos y estado.
Es el modelo *silo*: el aislamiento entre tenants lo garantiza la infraestructura.

```
infraestructura/terraform/
├── bootstrap/            # UNA vez por cuenta: bucket S3 para el estado de todos los tenants
│   └── main.tf
└── tenant/               # El stack de UN tenant (se aplica una vez por tenant y entorno)
    ├── versions.tf       # proveedores + backend "s3" (configuración parcial)
    ├── variables.tf      # tenant_id, nombre, contacto, entorno, plan, versión...
    ├── planes.tf         # catálogo de planes: Básico, Estándar, Avanzado
    ├── red.tf            # VPC por defecto, security groups, IP elástica del frontend
    ├── secretos.tf       # contraseñas generadas → SSM Parameter Store (SecureString)
    ├── iam.tf            # un rol por instancia: solo lee los secretos de SU tenant
    ├── instancias.tf     # las 3 EC2
    ├── outputs.tf        # URLs, IDs de instancias, comandos (sin secretos)
    ├── cloud-init/       # db.yaml, backend.yaml, frontend.yaml
    ├── tenants/          # un .tfvars por tenant: <tenant_id>-<entorno>.tfvars
    └── tenant.ps1        # ejecuta init/plan/apply/destroy para un tenant
```

## Imagen y configuración posterior
- **AMI**: variable `ami_id`. Vacía = Ubuntu 24.04 de Canonical; con la imagen de
  [Packer](../packer/README.md) los servidores arrancan en 1 a 3 minutos en vez de 5 a 10.
- **Configuración posterior** de la flota (endurecimiento, PostgreSQL según la memoria,
  actualizaciones masivas, verificación): [Ansible](../ansible/README.md).
- cloud-init solo corre en el primer arranque; Terraform ignora después los cambios de
  `user_data` y de AMI para no recrear servidores. Para renovar uno: `-replace=aws_instance.backend`.

## Otros motores
La misma infraestructura en Pulumi está en [`../pulumi/tenant`](../pulumi/tenant/README.md) (motor
`pulumi` de la plataforma). Con OpenTofu se usan estas mismas plantillas (`tenant.ps1 -Motor tofu`).

## Monitoreo
Un servidor aparte ([`monitoreo/`](monitoreo/README.md)) con Prometheus y Grafana vigila a todos
los tenants. La variable `monitoreo_sg_id` abre los puertos de métricas (9100, 9187 y `/metrics`
del backend) **solo** a ese servidor.

## Arquitectura de un tenant

```
                 Internet
                    │ :80
        ┌───────────▼───────────┐   IP elástica (se conserva al suspender)
        │ frontend  (Nginx)     │   React compilado + proxy /api, /django-admin, /static
        └───────────┬───────────┘
                    │ :80  (solo desde el SG del frontend de este tenant)
        ┌───────────▼───────────┐
        │ backend (Nginx+Gunicorn+Django)  ← lee su .env de SSM al arrancar
        └───────────┬───────────┘
                    │ :5432 (solo desde el SG del backend de este tenant)
        ┌───────────▼───────────┐
        │ db  (PostgreSQL)      │  ← lee su contraseña de SSM al arrancar
        └───────────────────────┘
```

- **Solo el frontend es público.** El navegador habla con un solo origen; Nginx reenvía la API
  al backend por IP privada. No se necesita CORS y el backend no está expuesto.
- **Una IP elástica por tenant.** AWS permite 5 por región por defecto → máximo 5 tenants a la vez
  (se puede pedir aumento de cuota).
- Todos los recursos llevan el prefijo `asistencia-<tenant_id>-<entorno>` y las etiquetas
  `Tenant`, `Entorno`, `Plan` (útiles para costos y, más adelante, para Prometheus).

## Catálogo de planes (`planes.tf`)

| | Básico | Estándar | Avanzado |
|---|---|---|---|
| Frontend | t3.micro | t3.micro | t3.small |
| Backend | t3.micro | t3.small | t3.medium |
| Base de datos | t3.micro | t3.small | t3.medium |
| Disco de la base | 10 GB | 20 GB | 40 GB |
| Máx. estudiantes | 100 | 500 | 2000 |
| Máx. módulos | 2 | 10 | 50 |

La plataforma puede enviar sus propios valores con la variable `recursos` (planes editados por
el administrador). Los límites llegan al backend como `MAX_ESTUDIANTES` y `MAX_MODULOS` en su `.env`.

**Efecto de cambiar de plan** (`terraform plan` lo muestra antes de aplicar):

| Cambio | Qué pasa |
|---|---|
| Tipo de instancia | Se modifica en sitio: stop → cambiar tipo → start. Disco e IP privada se conservan |
| Disco de la base | Se agranda en sitio. **EBS no se puede reducir**: al bajar de plan se mantiene el disco |
| Límites (estudiantes, módulos) | Cambia el parámetro SSM y una asociación de SSM reinicia Gunicorn sola |
| `app_version` | No se recrea nada: la plataforma (o Ansible) despliega la versión en sitio |

## Secretos: dónde están y cómo se protegen

| Secreto | Dónde vive | Quién lo puede leer |
|---|---|---|
| Contraseña de PostgreSQL | SSM `/asistencia/<t>/<e>/db/password` | rol de la instancia db |
| `.env` del backend (SECRET_KEY, DB...) | SSM `/asistencia/<t>/<e>/backend/env` | rol de la instancia backend |
| Contraseña inicial del admin del tenant | SSM `/asistencia/<t>/<e>/backend/admin_password` | rol backend + plataforma |
| Llave SSH privada | SSM `/asistencia/<t>/<e>/ssh/private_key` | solo la plataforma |

- Todos son `SecureString`, cifrados con KMS (`aws/ssm`).
- No están en el código, en los `.tfvars`, ni en el `user_data` (que se ve en la consola de AWS).
- El rol IAM de cada instancia solo permite leer la ruta de **su** tenant y **su** servicio.
- IMDSv2 obligatorio y discos cifrados en las 3 instancias.

## Estado del motor de infraestructura

- Un bucket S3 por cuenta (`asistencia-tfstate-<cuenta>`), creado por `bootstrap/`.
- **Un archivo de estado por tenant y entorno**: `tenants/<tenant_id>/<entorno>/terraform.tfstate`.
  Un error o un `destroy` en un tenant no afecta a los demás.
- **Cifrado** en reposo (SSE-KMS) y en tránsito (la política del bucket rechaza HTTP).
- **Acceso público bloqueado**; solo lo leen credenciales con permisos sobre el bucket.
- **Versionado**: se puede recuperar un estado anterior (las versiones viejas se borran a los 90 días).
- **Bloqueo** (`use_lockfile`): dos operaciones sobre el mismo tenant no pueden correr a la vez.
- El estado **sí contiene secretos** (Terraform guarda los valores generados): por eso todo lo anterior.
- El estado de `bootstrap/` queda local (solo describe el bucket; no tiene secretos).

## Paso a paso (manual)

Requisitos: Terraform ≥ 1.10 (u OpenTofu ≥ 1.10) y AWS CLI con `aws configure` hecho.

### 1 · Bootstrap (una sola vez por cuenta)
```powershell
cd infraestructura\terraform\bootstrap
terraform init
terraform apply          # crea el bucket S3 (no crea instancias). Escribe "yes"
```
Genera `tenant/backend.hcl` con el nombre del bucket.

### 2 · Definir el tenant
```powershell
cd ..\tenant
copy tenants\colegio-demo-dev.tfvars tenants\mi-colegio-dev.tfvars
```
Edita `tenant_id`, `tenant_nombre`, `contacto_email`, `entorno` y `plan`.

### 3 · Revisar qué se va a crear (no crea nada)
```powershell
.\tenant.ps1 -Tenant mi-colegio -Entorno dev
```

### 4 · Crear el tenant (aquí sí se crean las instancias y empieza el costo)
```powershell
.\tenant.ps1 -Tenant mi-colegio -Entorno dev -Accion apply
.\tenant.ps1 -Tenant mi-colegio -Entorno dev -Accion output
```
Espera 5 a 10 minutos a que cloud-init termine. La contraseña del administrador se lee con el
comando `leer_admin_password` que muestran las salidas.

### 5 · Entrar a una instancia (sin SSH)
Usa el comando `session_manager` de las salidas (requiere el
[plugin de Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html))
o la consola de AWS → EC2 → *Connect* → *Session Manager*. Dentro:
```bash
cloud-init status --long
sudo tail -n 50 /var/log/cloud-init-output.log   # termina con "... LISTO"
```

### 6 · Eliminar el tenant (controla costos)
```powershell
.\tenant.ps1 -Tenant mi-colegio -Entorno dev -Accion plan-destroy   # muestra qué se borra
.\tenant.ps1 -Tenant mi-colegio -Entorno dev -Accion destroy        # borra todo, incluida la base
```

Con OpenTofu, agrega `-Motor tofu` a cualquier comando.

## Costos aproximados por tenant (us-east-1)
- Básico: 3 × t3.micro + 3 IPv4 públicas + 34 GB gp3 → unos USD 35/mes encendido.
- Suspendido (instancias detenidas): solo discos + IP elástica → unos USD 6/mes.
- Destruido: USD 0 (el bucket de estado cuesta centavos).

## Suspender, reanudar y respaldos

### PolÃ­tica de suspensiÃ³n (RF-16, RF-17)
| | Al suspender | Al reanudar |
|---|---|---|
| Instancias EC2 (frontend, backend, db) | Se **detienen** (`aws_ec2_instance_state` = `stopped`) | Se encienden; los servicios arrancan solos |
| Disco de la base de datos | Se conserva (los datos no se tocan) | â€” |
| IP pÃºblica fija (frontend) | Se conserva: la direcciÃ³n web no cambia | â€” |
| Secretos SSM, roles, security groups | Se conservan | â€” |
| Respaldo | Se toma uno automÃ¡tico **antes** de detener | â€” |
| Costo mientras estÃ¡ suspendido | Solo discos + IP elÃ¡stica (â‰ˆ USD 6/mes en BÃ¡sico) | â€” |

Con el tenant suspendido se puede cambiar de plan (se aplica al reanudar) pero no actualizar la
aplicaciÃ³n: los servidores nuevos se apagarÃ­an a mitad de su instalaciÃ³n.

A mano: `suspendido = true` en el `.tfvars` del tenant y `.\tenant.ps1 ... -Accion apply`.

### Respaldos (RF-19)
- **QuÃ©**: `pg_dump --format=custom` de la base `asistencia_db` del tenant.
- **DÃ³nde**: bucket `asistencia-respaldos-<cuenta>` (lo crea `bootstrap/`), prefijo
  `tenants/<tenant_id>/<entorno>/`. Cifrado (SSE-KMS), privado, solo HTTPS.
- **CÃ³mo**: la plataforma ejecuta el respaldo **dentro** de la instancia db con SSM Run Command.
  El rol IAM de esa instancia solo puede leer/escribir **su** prefijo: un tenant no puede ver ni
  pisar los respaldos de otro.
- **Restaurar**: se toma un respaldo de seguridad de los datos actuales, se verifica el sha256
  del archivo, se detiene el backend, `pg_restore --clean --single-transaction` (si falla, no
  cambia nada) y se vuelve a encender el backend.

### RetenciÃ³n
| Respaldo | Se guarda |
|---|---|
| Manual, antes de suspender, antes de restaurar | SegÃºn el plan: BÃ¡sico 7 dÃ­as Â· EstÃ¡ndar 14 Â· Avanzado 30 |
| Final (antes de eliminar el tenant) | 30 dÃ­as (`RETENCION_RESPALDO_FINAL_DIAS`) |
| Red de seguridad del bucket | Todo objeto se borra a los 180 dÃ­as |

El worker de la plataforma borra los respaldos vencidos cada 10 minutos. Un tenant eliminado y
vuelto a crear con el mismo identificador y entorno puede restaurar su respaldo final.
