# Tenant con Pulumi (segunda implementación del motor)

El mismo tenant que [`terraform/tenant`](../../terraform/tenant), escrito en Python con Pulumi:
mismos recursos y nombres (`asistencia-<id>-<entorno>-*`), mismas etiquetas, **mismos archivos
cloud-init** (los lee de `../../terraform/tenant/cloud-init`) y mismas salidas. Por eso la
plataforma, Ansible, Prometheus y las pruebas de aislamiento lo tratan igual que a Terraform.
Comparación: [docs/COMPARACION-MOTORES.md](../../../docs/COMPARACION-MOTORES.md).

## Preparar el worker (una vez)
```powershell
winget install Pulumi.Pulumi
cd infraestructura\pulumi\tenant
python -m venv venv; venv\Scripts\pip install -r requirements.txt
```
`.env` de la plataforma:
```
IAC_PULUMI_BACKEND=s3://asistencia-tfstate-<cuenta>/pulumi?region=us-east-1   # mismo bucket que Terraform
```
y en el entorno del worker (no en el repositorio): `PULUMI_CONFIG_PASSPHRASE=<frase larga>`; cifra
los secretos dentro del estado de Pulumi. Si se pierde, no se pueden volver a operar las pilas.

## Cómo lo usa la plataforma
- Una **pila** por tenant: `<tenant_id>-<entorno>`, con estado en S3 (cifrado, versionado).
- La configuración (las mismas variables que recibe Terraform) va en un `--config-file` en la
  carpeta de trabajo del tenant; no contiene secretos.
- `pulumi up` (crear/actualizar/suspender), `pulumi preview --json` (previsualizar),
  `pulumi stack export` (qué se eliminaría), `pulumi destroy`.

## A mano
```powershell
$env:PULUMI_BACKEND_URL="s3://asistencia-tfstate-<cuenta>/pulumi?region=us-east-1"
$env:PULUMI_CONFIG_PASSPHRASE="<frase>"
pulumi stack select --create colegio-demo-dev
pulumi config set aws:region us-east-1
pulumi config set tenant_id colegio-demo
pulumi config set tenant_nombre "Colegio Demo"
pulumi config set contacto_email admin@colegio-demo.edu
pulumi preview
pulumi up
```

## Pruebas sin AWS
```powershell
venv\Scripts\pip install pytest
venv\Scripts\python -m pytest test_programa.py -q
```
Ejecutan el programa con *mocks* de Pulumi: comprueban las 3 instancias y su tamaño, el cloud-init
sin secretos, la suspensión, los recursos que envía la plataforma, las reglas de métricas y los
permisos IAM de cada servicio.
