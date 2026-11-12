# Credenciales: cuáles hay y cómo obtenerlas

Regla general: **casi ninguna contraseña se escribe a mano.** Terraform (o Pulumi) las genera al
crear cada recurso y las guarda cifradas en **AWS SSM Parameter Store** (`SecureString`). Se leen
con la AWS CLI desde una PC con permisos; no aparecen en el log de la plataforma (se redactan) ni en
los repositorios.

> No pegues contraseñas ni claves de AWS en chats, issues o capturas. Si una se filtra, ver
> [Rotar una credencial](#rotar-una-credencial).

Todos los comandos son para PowerShell y asumen la región `us-east-1`.

---

## Resumen

| Credencial | Usuario | Contraseña / valor | Dónde se usa |
|---|---|---|---|
| AWS (quien despliega) | usuario IAM | Access key en `aws configure` | Terraform, worker de la plataforma |
| Plataforma de tenants | superusuario de Django | La que elegiste al crearlo | http://localhost:5173/plataforma |
| Grafana | `admin` | SSM `/asistencia/plataforma/grafana/admin_password` | `grafana_url` (puerto 3000) |
| Token de Grafana | — | Lo creas en Grafana | `.env` → `GRAFANA_TOKEN` |
| App de cada tenant | `admin` | SSM `/asistencia/<tenant>/<entorno>/backend/admin_password` | `http://<IP>/panel/login` y `/django-admin/` |
| Base de datos de cada tenant | `asistencia` | SSM `/asistencia/<tenant>/<entorno>/db/password` | Solo el backend del tenant |
| Llave SSH de cada tenant | `ubuntu` | SSM `/asistencia/<tenant>/<entorno>/ssh/private_key` | Emergencias (normalmente se usa Session Manager) |
| Pulumi | — | `PULUMI_CONFIG_PASSPHRASE` (la inventas) | Solo si usas el motor Pulumi |

---

## 1 · AWS (quien despliega)

Un usuario IAM con estas políticas administradas: `AmazonEC2FullAccess`, `AmazonS3FullAccess`,
`AmazonSSMFullAccess` e `IAMFullAccess`.

1. Consola de AWS (con la cuenta raíz o un administrador) → **IAM → Users** → el usuario →
   **Add permissions → Attach policies directly** → marcar las 4.
2. **Security credentials → Create access key** → *Command Line Interface*.
3. En la PC:
   ```powershell
   aws configure                 # Access key, Secret, región us-east-1, formato json
   aws sts get-caller-identity   # comprueba con qué usuario y cuenta estás
   ```

Si `terraform apply` dice `AccessDenied ... no identity-based policy allows the s3:CreateBucket`
(u otra acción), al usuario le falta una de esas políticas; no es un problema de créditos.

## 2 · Plataforma de tenants

Es el superusuario del Django de la plataforma (`asistencia_backend`), en tu base local:

```powershell
cd asistencia_backend
venv\Scripts\python manage.py createsuperuser      # crear uno
venv\Scripts\python manage.py changepassword admin # olvidaste la contraseña
```

Los **administradores de un tenant** (que solo ven su institución) se crean en
`http://127.0.0.1:8000/django-admin/` y se asignan al tenant (ver [OPERACIONES.md](OPERACIONES.md)).

## 3 · Grafana

**Contraseña de `admin`** (la genera `terraform/monitoreo`):
```powershell
aws ssm get-parameter --region us-east-1 --name /asistencia/plataforma/grafana/admin_password --with-decryption --query Parameter.Value --output text
```
La dirección sale de `terraform output grafana_url` en `infraestructura\terraform\monitoreo`.

**Conectar la plataforma con Grafana** (para que traiga las alertas). Dos formas, en `asistencia_backend\.env`:

| Forma | Cómo | Ventaja |
|---|---|---|
| Token (preferida) | Grafana → *Administration → Users and access → Service accounts → Add service account* (rol **Viewer**) → *Add service account token* → copiar a `GRAFANA_TOKEN=` | Solo lectura |
| Usuario y contraseña | `GRAFANA_USUARIO=admin` y `GRAFANA_PASSWORD=<la de SSM>` | Sigue sirviendo si el servidor de monitoreo se recrea |

> El servidor de monitoreo **se recrea** cuando cambia su configuración (`terraform apply` en
> `monitoreo/` muestra `must be replaced`). Al recrearse, Grafana empieza de cero: el **token se
> pierde** y hay que crear otro. La contraseña de `admin` no cambia (está en el estado de Terraform).

Después de editar el `.env`, reinicia el backend y el worker.

## 4 · App de cada tenant

- **Usuario:** `admin` (variable `admin_usuario` de la plantilla).
- **Contraseña:**
  ```powershell
  aws ssm get-parameter --region us-east-1 --name /asistencia/<tenant>/<entorno>/backend/admin_password --with-decryption --query Parameter.Value --output text
  ```
  Ejemplo: `/asistencia/colegio-madre-clara/dev/backend/admin_password`.
- **Dónde entrar:** `http://<IP del tenant>/panel/login` (panel de la app) o
  `http://<IP del tenant>/django-admin/`. La IP aparece en el detalle del tenant en la plataforma.

El mismo comando aparece en la salida `leer_admin_password` de la operación *Crear* (registro de la
operación) o con `terraform output leer_admin_password` si lo creaste a mano con `tenant.ps1`.

La app responde **5 a 10 minutos después** de que la operación termine (los servidores se instalan
solos). Antes de eso verás "Welcome to nginx!" o errores 502/404: es normal.

## 5 · Base de datos de cada tenant

No hace falta para usar la app: el backend la lee solo de SSM. Para diagnóstico:
```powershell
aws ssm get-parameter --region us-east-1 --name /asistencia/<tenant>/<entorno>/db/password --with-decryption --query Parameter.Value --output text
```
La base solo acepta conexiones desde el backend del mismo tenant (security group). Para entrar,
abre una sesión en la instancia db y usa `sudo -u postgres psql asistencia_db`.

## 6 · Entrar a un servidor

**Session Manager (recomendado, sin llaves ni puertos abiertos):**
```powershell
aws ssm start-session --target <id de la instancia>
```
Requiere el [plugin de Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
Los id de las instancias aparecen en el detalle del tenant y en la consola de EC2. También se puede
desde la consola: EC2 → instancia → **Conectar → Session Manager**.

**SSH (solo si se habilitó `IAC_SSH_CIDRS` con tu IP):**
```powershell
aws ssm get-parameter --region us-east-1 --name /asistencia/<tenant>/<entorno>/ssh/private_key --with-decryption --query Parameter.Value --output text > tenant.pem
ssh -i tenant.pem ubuntu@<IP pública del frontend>
```
Borra `tenant.pem` al terminar.

## 7 · Pulumi (opcional)

Solo si creas tenants con el motor Pulumi. La frase la inventas tú y debe ser **siempre la misma**
(cifra los secretos del estado). Va en el entorno del worker, nunca en el `.env`:
```powershell
$env:PULUMI_CONFIG_PASSPHRASE = "<tu frase>"
venv\Scripts\python manage.py worker_plataforma
```

## Ver todos los secretos de un tenant

Lista los nombres (sin valores):
```powershell
aws ssm get-parameters-by-path --region us-east-1 --path /asistencia/<tenant>/<entorno>/ --recursive --query "Parameters[].Name"
```

## Rotar una credencial

| Credencial | Cómo |
|---|---|
| Access key de AWS | IAM → usuario → *Security credentials* → crear una nueva, `aws configure`, desactivar y borrar la vieja |
| Token de Grafana | Borrarlo en *Service accounts* y crear otro |
| Admin de un tenant | Cambiarla desde `/django-admin/` del tenant (SSM conserva la inicial) |
| Base de datos del tenant | No está automatizado: la contraseña se fija al instalar la base. Lo más simple es respaldar, eliminar y volver a crear el tenant, y restaurar el respaldo |
