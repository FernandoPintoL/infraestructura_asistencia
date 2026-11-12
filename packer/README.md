# Imagen base con Packer

**Packer** crea una **AMI** (imagen de disco de EC2) con todo lo que las 3 instancias de cada
tenant tienen en común. Las instancias nacen de esa imagen y cloud-init solo hace lo propio de
cada tenant (secretos, código, migraciones).

| | Sin Packer (Ubuntu limpio) | Con la imagen de Packer |
|---|---|---|
| cloud-init instala Nginx, Python, PostgreSQL, Node.js, AWS CLI | Sí, en **cada** instancia | No: ya vienen instalados |
| Tiempo hasta que el tenant responde | 5 a 10 minutos | 1 a 3 minutos |
| Versiones de los paquetes | Las del día de creación de cada instancia | Las mismas para todos los tenants (imagen versionada) |
| Endurecimiento (SSH sin contraseña, parches automáticos, journald) | No | Sí, de fábrica |

## Qué contiene ([scripts/base.sh](scripts/base.sh))
- Ubuntu 24.04 LTS (Canonical) actualizado.
- Nginx, Python 3 + venv, PostgreSQL (**apagado**: solo lo enciende la instancia db), cliente
  de PostgreSQL, Node.js 22, AWS CLI v2, `prometheus-node-exporter` (métricas para Grafana).
- Parches de seguridad automáticos, SSH sin contraseña ni root, límite de 200 MB para journald,
  zona horaria America/La_Paz.
- `/etc/asistencia-imagen`: nombre, versión y fecha de la imagen (Ansible la muestra).
- Limpieza final: sin llaves SSH, sin machine-id ni registros de cloud-init (cada instancia
  arranca como nueva).

## Crear la imagen
```powershell
winget install Hashicorp.Packer          # una vez
cd infraestructura\packer
packer init .                            # descarga el plugin de Amazon (una vez)
packer validate .
packer build .                           # ~10 min; crea una EC2 temporal, la configura y la borra
packer build -var version=1.1.0 .        # versión nueva de la imagen
```
Usa las credenciales de `aws configure`. Al terminar, `manifest.json` tiene el ID de la AMI
(`artifact_id`, con forma `us-east-1:ami-0abc…`).

La instancia temporal solo acepta SSH desde tu IP pública y se elimina al terminar.

## Usar la imagen
- **Plataforma**: en su `.env`, `IAC_AMI_ID=ami-0abc…`. Los tenants nuevos nacen de esa imagen
  y cada operación registra qué AMI usó (RF-13).
- **A mano**: `ami_id = "ami-0abc…"` en el `.tfvars` del tenant.

Los tenants existentes **no** cambian de imagen solos (Terraform ignora cambios de AMI para no
recrear servidores con datos). Para renovar un tenant con la imagen nueva:
`terraform apply -replace=aws_instance.backend -replace=aws_instance.frontend`.
La base de datos no se reemplaza nunca de forma automática.

## Costos
La AMI guarda un snapshot de 8 GB (≈ USD 0,40/mes). Las imágenes viejas se borran desde la
consola de EC2 → AMIs → *Deregister* (y luego su snapshot).
