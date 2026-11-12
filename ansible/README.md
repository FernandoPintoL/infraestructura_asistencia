# Ansible · configuración posterior de las instancias de los tenants

**Ansible** se conecta a instancias que ya existen y deja su configuración en el estado
deseado. Es **idempotente**: si algo ya está bien, no lo toca (`ok`); si lo cambia, `changed`.

> No confundir con [`anteriores/ansible/`](../../anteriores/ansible/README.md) (trabajo anterior): allí Ansible
> prepara un *servidor de trabajo* con Terraform/Pulumi/AWS CLI. Esta carpeta configura las
> instancias **de los tenants**.

## Dónde encaja cada herramienta

```
Packer      → imagen base (paquetes comunes, endurecimiento)        una vez por versión de imagen
Terraform   → red, firewalls, roles, secretos, 3 EC2 por tenant      al crear / cambiar plan / suspender
cloud-init  → lo propio de cada instancia en su PRIMER arranque      automático
Ansible     → configuración POSTERIOR de toda la flota               cuando el operador lo decide
Plataforma  → actualizar la app de UN tenant (SSM Run Command)      desde su pantalla
```

## Cómo se conecta: inventario dinámico + SSM
- [`inventario.aws_ec2.yml`](inventario.aws_ec2.yml) pregunta a AWS qué instancias existen y las
  agrupa por las etiquetas que pone Terraform: `servicio_backend`, `tenant_colegio_demo`,
  `entorno_prod`, `plan_avanzado`… No hay IPs escritas a mano.
- La conexión es por **SSM Session Manager**: no se abre el puerto 22 ni se usan llaves SSH.
  Las instancias ya tienen el rol necesario. Las suspendidas no aparecen.

## Playbooks
| Playbook | Qué hace | Cambia algo |
|---|---|---|
| [`configurar.yml`](configurar.yml) | Zona horaria, parches automáticos, SSH endurecido, journald, swap, node_exporter, cabeceras de seguridad en Nginx y **PostgreSQL ajustado a la memoria de la instancia** (tras un cambio de plan) | Sí |
| [`actualizar-app.yml`](actualizar-app.yml) | Despliega una versión en sitio: backends primero (migraciones), luego frontends; de a `lote` instancias y se detiene ante el primer error | Sí |
| [`verificar.yml`](verificar.yml) | Servicios activos, API y proxy responden, disco < 85 %, tamaño de la base, imagen de origen | No |

## Requisitos (una vez)
Ansible no corre en Windows: usa **WSL** (`wsl --install -d Ubuntu`) o cualquier Linux.
```bash
sudo apt install -y ansible python3-boto3
# Plugin de Session Manager para la AWS CLI (Ubuntu x86_64)
curl -fsSLo /tmp/ssm.deb https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
sudo dpkg -i /tmp/ssm.deb
cd infraestructura/ansible
ansible-galaxy collection install -r requirements.yml
```
Credenciales: las de `aws configure` (en WSL, copia `~/.aws` o exporta `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` y `AWS_REGION`). Además:
```bash
export IAC_BUCKET_RESPALDOS=asistencia-respaldos-<cuenta>   # SSM transfiere archivos por S3
export ANSIBLE_CONFIG=ansible.cfg                           # si la carpeta está en /mnt/c o /mnt/d
```

## Uso
```bash
ansible-inventory --graph                                   # qué instancias y grupos hay
ansible-playbook verificar.yml                              # salud de toda la flota
ansible-playbook configurar.yml --check --diff              # qué cambiaría, sin cambiar nada
ansible-playbook configurar.yml -l tenant_colegio_demo      # configurar un tenant
ansible-playbook actualizar-app.yml -e version=v1.2.0 -l entorno_staging
ansible-playbook actualizar-app.yml -e version=v1.2.0 -l 'entorno_prod' -e lote=3
```
Los guiones del identificador se convierten en `_` en los nombres de grupo
(`colegio-demo` → `tenant_colegio_demo`).

## Alternativa por SSH
Si prefieres SSH: pon tu IP en `ssh_cidrs` del tenant, guarda la llave con el comando
`leer_llave_ssh` de las salidas de Terraform y en `group_vars/all.yml` reemplaza la conexión por
`ansible_connection: ssh`, `ansible_user: ubuntu`, `ansible_ssh_private_key_file: <archivo .pem>`
y en el inventario `ansible_host: public_ip_address`.
