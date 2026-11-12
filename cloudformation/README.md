# Infraestructura · AWS con CloudFormation + cloud-init

Crea **3 instancias EC2** (Ubuntu 24.04), una por servicio, con una sola plantilla
(`asistencia.yaml`). Cada instancia se instala sola al arrancar con un **`#cloud-config`**
que va dentro de la plantilla, en `UserData`.

| Instancia | Qué corre | Acceso |
|---|---|---|
| `<pila>-db` | PostgreSQL | Puerto 5432 **solo desde el backend** |
| `<pila>-backend` | Nginx + Gunicorn + Django | Puerto 80 público (IP elástica) |
| `<pila>-frontend` | Nginx sirviendo React compilado | Puerto 80 público (IP elástica) |

SSH (puerto 22) solo se permite desde tu IP.

## Anatomía del cloud-init

Cada `UserData` usa solo tres bloques:

| Bloque | Para qué |
|---|---|
| `packages` | Instala software con `apt` (PostgreSQL, Nginx, Git, Python...) |
| `write_files` | Crea archivos: `.env`, servicio de systemd, configuración de Nginx, SQL inicial |
| `runcmd` | Ejecuta comandos en orden, como root, al final: clonar, compilar, migrar, activar servicios |

`Fn::Base64: !Sub |` reemplaza las variables `${...}` (parámetros, IPs elásticas, IP privada
de la base de datos) antes de crear la instancia: cumple el papel de `templatefile()` en Terraform.

## Requisitos
- AWS CLI configurado (`aws configure`, comprueba con `aws sts get-caller-identity`).
- Repositorios del backend y del frontend **públicos**, con la rama `main` actualizada.

## Paso 1 · Generar los parámetros
```powershell
cd "cloud_init\cloudformation"
powershell -ExecutionPolicy Bypass -File .\generar-parametros.ps1 -AdminPassword "TuClaveSegura2026"
```
Crea `parametros.json` con tu IP, la VPC y la subnet por defecto, y contraseñas aleatorias
para PostgreSQL y Django. La contraseña del administrador: mínimo 8 caracteres, sin comillas,
`$`, `` ` `` ni `\`. Este archivo no se sube a git y **no hay que regenerarlo** mientras la pila exista.

## Paso 2 · Validar la plantilla (no crea nada)
```powershell
aws cloudformation validate-template --template-body file://asistencia.yaml
```

## Paso 3 · Crear la pila
```powershell
aws cloudformation deploy --stack-name asistencia-cloudinit --template-file asistencia.yaml --parameter-overrides file://parametros.json
```
Tarda 2 a 3 minutos y termina con `Successfully created/updated stack`.
También puedes seguir el avance en la consola web: **CloudFormation → asistencia-cloudinit → Events**.

## Paso 4 · Ver las URLs
```powershell
aws cloudformation describe-stacks --stack-name asistencia-cloudinit --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table
```
**Espera 5 a 10 minutos**: cloud-init sigue instalando después de que la pila termina.

## Paso 5 · Verificar
- `UrlApi` debe responder un JSON con `{"modulo": null}`.
- `UrlFrontend` muestra la pantalla de estudiantes.
- `UrlPanelAdmin` → entra con tu usuario y contraseña, e importa un módulo con los Excel de
  la carpeta `ejemplos/` del backend.

## SSH (opcional)
La llave privada la guarda AWS en SSM Parameter Store (output `LlaveSshParametro`). Descárgala:
```powershell
$param = aws cloudformation describe-stacks --stack-name asistencia-cloudinit --query "Stacks[0].Outputs[?OutputKey=='LlaveSshParametro'].OutputValue" --output text
aws ssm get-parameter --name $param --with-decryption --query Parameter.Value --output text | Out-File -Encoding ascii asistencia-cloudinit-key.pem
icacls asistencia-cloudinit-key.pem /inheritance:r /grant:r "$($env:USERNAME):R"
```
Luego usa los comandos de los outputs `SshFrontend`, `SshBackend` o `SshDb`. Dentro de la instancia:
```bash
cloud-init status --long                      # done / running / error
tail -n 50 /var/log/cloud-init-output.log     # salida de packages y runcmd
```
Cada instancia termina con `BASE DE DATOS LISTA`, `BACKEND LISTO` o `FRONTEND LISTO`.

## Eliminar todo (para no seguir pagando)
```powershell
aws cloudformation delete-stack --stack-name asistencia-cloudinit
aws cloudformation wait stack-delete-complete --stack-name asistencia-cloudinit
```
Borra las 3 instancias, las IPs, la llave **y la base de datos con sus datos**.
Si después creas una pila nueva, puedes regenerar `parametros.json` con `-Forzar`.

## Terraform vs CloudFormation en este proyecto

| | Terraform (`cloud_init/terraform`) | CloudFormation (aquí) |
|---|---|---|
| cloud-init | Archivos `.yaml` aparte + `templatefile()` | Dentro de la plantilla con `!Sub` |
| Contraseñas aleatorias | `random_password` | `generar-parametros.ps1` + parámetros `NoEcho` |
| Llave SSH | Archivo `.pem` local | SSM Parameter Store |
| VPC por defecto | La busca sola (`data`) | Parámetros `VpcId` / `SubnetId` |
| Estado | `terraform.tfstate` en tu PC | Lo guarda AWS (la pila) |
| Crear / borrar | `terraform apply` / `destroy` | `cloudformation deploy` / `delete-stack` |

## Costos y limitaciones
- 3 × `t3.micro` + 2 IPs elásticas. Con capa gratuita/créditos puede ser $0; si no, unos USD 30/mes.
- Funciona con **HTTP** (sin candado). Para HTTPS hace falta un dominio y un certificado.
- El `UserData` (con las contraseñas) se puede ver desde la consola de AWS.
