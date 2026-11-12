# CloudFormation · un tenant (tercera implementación)

[`tenant.yaml`](tenant.yaml) crea la misma infraestructura que [`terraform/tenant`](../../terraform/tenant)
y [`pulumi/tenant`](../../pulumi/tenant): 3 EC2 (frontend, backend, db), security groups encadenados,
IP elástica, roles IAM que solo leen los secretos de su tenant, llave SSH y reglas de métricas para el
monitoreo. Usa los **mismos cloud-init** (`terraform/tenant/cloud-init`).

La usa la plataforma cuando el tenant se crea con el motor **CloudFormation**
(`asistencia_backend/plataforma/motores/cloudformation.py`). Una pila por tenant:
`asistencia-<tenant>-<entorno>`.

## Qué hace la plataforma además de la pila

CloudFormation no puede hacer estas cosas por sí solo; el motor las hace con la API de AWS:

| Qué | Cuándo |
|---|---|
| Generar las contraseñas (base, admin, `SECRET_KEY`) y guardarlas como **SSM SecureString** | Antes de crear la pila (nunca las cambia después) |
| Armar el **`.env` del backend** con esos secretos, la IP pública y la IP de la base | Mientras se crea la pila, apenas existen la IP y la base; el backend espera hasta 10 min a que aparezca |
| Completar los cloud-init y pasarlos como parámetros (backend y db comprimidos, por el límite de 4096 bytes) | Al crear |
| Mandar la AMI, el user_data y el disco **con el valor previo** en cada actualización | Al actualizar (cambiarlos reemplazaría instancias) |
| Agrandar el disco de la base | Al cambiar a un plan con más disco |
| Reiniciar el backend si cambió el `.env` (límites del plan) | Al actualizar |
| Detener / encender las 3 instancias | Suspender / reanudar |
| Borrar los 4 parámetros SSM | Al eliminar el tenant (después de borrar la pila) |

## Permisos
El usuario de AWS de la plataforma necesita, además de EC2/S3/SSM/IAM, la política administrada
**`AWSCloudFormationFullAccess`**. La pila crea roles con nombre, por eso se envía con
`CAPABILITY_NAMED_IAM`.

## Validar sin AWS
```powershell
pip install cfn-lint
cfn-lint tenant.yaml --regions us-east-1
```
Las pruebas del motor (con CloudFormation, SSM y EC2 falsos) están en
`asistencia_backend/plataforma/tests.py` → `MotorCloudFormationTests`.

## Ver una pila
```powershell
aws cloudformation describe-stacks --stack-name asistencia-<tenant>-<entorno> --query "Stacks[0].[StackStatus,Outputs]"
aws cloudformation describe-stack-events --stack-name asistencia-<tenant>-<entorno> --max-items 20
```
Si una creación falla, la pila queda en `ROLLBACK_COMPLETE` (CloudFormation deshace lo creado).
*Reintentar* en la plataforma la borra y la vuelve a crear; los secretos de SSM se conservan.

Comparación con los otros motores: [docs/COMPARACION-MOTORES.md](../../docs/COMPARACION-MOTORES.md).
