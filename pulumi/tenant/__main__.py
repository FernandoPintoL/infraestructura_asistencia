"""
Un tenant del sistema de asistencia con Pulumi (Python): la misma infraestructura que
infraestructura/terraform/tenant, para poder elegir el motor (RF-08) y compararlos.

Se reutilizan los mismos archivos cloud-init (../../terraform/tenant/cloud-init) y se producen
las mismas salidas, así la plataforma trata a los dos motores igual.

Configuración (la escribe la plataforma en un archivo --config-file):
  tenant_id, tenant_nombre, contacto_email, entorno, plan, recursos{...}, app_version,
  repo_backend_url, repo_frontend_url, admin_usuario, ami_id, ssh_cidrs, suspendido,
  bucket_respaldos, monitoreo_sg_id, aws:region
"""
import hashlib
import ipaddress
import re
from pathlib import Path

import pulumi
import pulumi_aws as aws
import pulumi_random as random
import pulumi_tls as tls

cfg = pulumi.Config()
region = pulumi.Config("aws").get("region") or "us-east-1"

# ───────────── Variables (mismas reglas que variables.tf) ─────────────

CATALOGO = {
    "basico": dict(tipo_frontend="t3.micro", tipo_backend="t3.micro", tipo_db="t3.micro",
                   disco_db_gb=10, max_estudiantes=100, max_modulos=2),
    "estandar": dict(tipo_frontend="t3.micro", tipo_backend="t3.small", tipo_db="t3.small",
                     disco_db_gb=20, max_estudiantes=500, max_modulos=10),
    "avanzado": dict(tipo_frontend="t3.small", tipo_backend="t3.medium", tipo_db="t3.medium",
                     disco_db_gb=40, max_estudiantes=2000, max_modulos=50),
}


def validar(condicion, mensaje):
    if not condicion:
        raise ValueError(mensaje)


tenant_id = cfg.require("tenant_id")
validar(re.fullmatch(r"[a-z][a-z0-9-]{1,18}[a-z0-9]", tenant_id), "tenant_id: 3 a 20 minúsculas, números y guiones.")
tenant_nombre = cfg.require("tenant_nombre")
validar(3 <= len(tenant_nombre) <= 80 and not re.search(r"[\"'$`\\]", tenant_nombre),
        "tenant_nombre: 3 a 80 caracteres, sin comillas, $, ` ni \\.")
contacto_email = cfg.require("contacto_email")
validar(re.fullmatch(r"[^@\s\"'$`]+@[^@\s\"'$`]+\.[^@\s\"'$`]+", contacto_email), "contacto_email inválido.")
entorno = cfg.get("entorno") or "dev"
validar(entorno in ("dev", "staging", "prod"), "entorno: dev, staging o prod.")
plan = cfg.get("plan") or "basico"
recursos = cfg.get_object("recursos") or CATALOGO.get(plan)
validar(recursos is not None, "Sin recursos, el plan debe ser basico, estandar o avanzado.")
app_version = cfg.get("app_version") or "main"
validar(re.fullmatch(r"[A-Za-z0-9._/-]+", app_version), "app_version: rama o tag de git.")
admin_usuario = cfg.get("admin_usuario") or "admin"
repo_backend = cfg.get("repo_backend_url") or "https://github.com/FernandoPintoL/asistencia_backend.git"
repo_frontend = cfg.get("repo_frontend_url") or "https://github.com/FernandoPintoL/asistencia_frontend.git"
ssh_cidrs = cfg.get_object("ssh_cidrs") or []
for c in ssh_cidrs:
    ipaddress.ip_network(c)  # ValueError si no es un CIDR
suspendido = cfg.get_bool("suspendido") or False
bucket_respaldos = cfg.get("bucket_respaldos") or ""
monitoreo_sg_id = cfg.get("monitoreo_sg_id") or ""

nombre = f"asistencia-{tenant_id}-{entorno}"
ssm_prefijo = f"/asistencia/{tenant_id}/{entorno}"
respaldos_prefijo = f"tenants/{tenant_id}/{entorno}"
DISCO_APP_GB = 12
CLOUD_INIT = Path(__file__).resolve().parent.parent.parent / "terraform" / "tenant" / "cloud-init"

# Etiquetas por defecto en todos los recursos (Prometheus y Ansible las usan)
proveedor = aws.Provider("aws", region=region, default_tags={"tags": {
    "Proyecto": "asistencia", "Tenant": tenant_id, "Entorno": entorno, "Plan": plan, "GestionadoPor": "pulumi",
}})
opts = pulumi.ResourceOptions(provider=proveedor)
invoke = pulumi.InvokeOptions(provider=proveedor)


def cloud_init(archivo, **valores):
    """Como templatefile(): reemplaza ${variable}; los $host de Nginx quedan intactos."""
    plantilla = (CLOUD_INIT / archivo).read_text(encoding="utf-8")
    return pulumi.Output.all(**valores).apply(
        lambda v: re.sub(r"\$\{(\w+)\}", lambda m: str(v[m.group(1)]), plantilla).replace("\r", ""))


# ───────────── Red ─────────────

vpc = aws.ec2.get_vpc(default=True, opts=invoke)
subnet = aws.ec2.get_subnet(vpc_id=vpc.id, availability_zone=f"{region}a", default_for_az=True, opts=invoke)
ami = cfg.get("ami_id") or aws.ec2.get_ami(
    most_recent=True, owners=["099720109477"], opts=invoke,
    filters=[{"name": "name", "values": ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]}],
).id

SALIDA = [{"protocol": "-1", "from_port": 0, "to_port": 0, "cidr_blocks": ["0.0.0.0/0"]}]
SSH = ([{"description": "SSH de administracion", "protocol": "tcp", "from_port": 22, "to_port": 22,
         "cidr_blocks": ssh_cidrs}] if ssh_cidrs else [])

sg_frontend = aws.ec2.SecurityGroup(
    "frontend", name=f"{nombre}-frontend", description=f"Frontend del tenant {tenant_id}: unica entrada publica",
    vpc_id=vpc.id, egress=SALIDA, tags={"Name": f"{nombre}-frontend"}, opts=opts,
    ingress=[{"description": "HTTP publico", "protocol": "tcp", "from_port": 80, "to_port": 80,
              "cidr_blocks": ["0.0.0.0/0"]}, *SSH])
sg_backend = aws.ec2.SecurityGroup(
    "backend", name=f"{nombre}-backend", description=f"Backend del tenant {tenant_id}: solo desde su frontend",
    vpc_id=vpc.id, egress=SALIDA, tags={"Name": f"{nombre}-backend"}, opts=opts,
    ingress=[{"description": "HTTP solo desde el frontend del mismo tenant", "protocol": "tcp",
              "from_port": 80, "to_port": 80, "security_groups": [sg_frontend.id]}, *SSH])
sg_db = aws.ec2.SecurityGroup(
    "db", name=f"{nombre}-db", description=f"PostgreSQL del tenant {tenant_id}: solo desde su backend",
    vpc_id=vpc.id, egress=SALIDA, tags={"Name": f"{nombre}-db"}, opts=opts,
    ingress=[{"description": "PostgreSQL solo desde el backend del mismo tenant", "protocol": "tcp",
              "from_port": 5432, "to_port": 5432, "security_groups": [sg_backend.id]}, *SSH])

eip = aws.ec2.Eip("frontend", domain="vpc", tags={"Name": f"{nombre}-frontend"}, opts=opts)

if monitoreo_sg_id:  # métricas: solo el servidor de monitoreo
    for clave, sg, puerto in (("frontend-node", sg_frontend, 9100), ("backend-node", sg_backend, 9100),
                              ("db-node", sg_db, 9100), ("db-postgres", sg_db, 9187), ("backend-app", sg_backend, 80)):
        aws.vpc.SecurityGroupIngressRule(
            f"metricas-{clave}", security_group_id=sg.id, referenced_security_group_id=monitoreo_sg_id,
            ip_protocol="tcp", from_port=puerto, to_port=puerto, description=f"Monitoreo: {clave}", opts=opts)

# ───────────── Secretos (en SSM, nunca en el código ni en el user_data) ─────────────

db_password = random.RandomPassword("db", length=24, special=False)
django_secret = random.RandomPassword("django-secret", length=60, special=False)
admin_password = random.RandomPassword("admin", length=16, special=False)
llave = tls.PrivateKey("ssh", algorithm="ED25519")
key_pair = aws.ec2.KeyPair("ssh", key_name=f"{nombre}-key", public_key=llave.public_key_openssh, opts=opts)

p_db = aws.ssm.Parameter("db-password", name=f"{ssm_prefijo}/db/password", type="SecureString",
                         value=db_password.result, opts=opts)
p_admin = aws.ssm.Parameter("admin-password", name=f"{ssm_prefijo}/backend/admin_password",
                            type="SecureString", value=admin_password.result, opts=opts)
p_ssh = aws.ssm.Parameter("ssh-privada", name=f"{ssm_prefijo}/ssh/private_key", type="SecureString",
                          value=llave.private_key_openssh, opts=opts)

# ───────────── Roles IAM: cada instancia solo lee SUS secretos ─────────────

cuenta = aws.get_caller_identity(opts=invoke).account_id
arn_parametros = f"arn:aws:ssm:{region}:{cuenta}:parameter{ssm_prefijo}"
LECTURA = {"frontend": None, "backend": f"{arn_parametros}/backend/*", "db": f"{arn_parametros}/db/*"}
perfiles = {}
for servicio, arn in LECTURA.items():
    rol = aws.iam.Role(servicio, name=f"{nombre}-{servicio}", opts=opts, assume_role_policy=pulumi.Output.json_dumps({
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Action": "sts:AssumeRole", "Principal": {"Service": "ec2.amazonaws.com"}}],
    }))
    aws.iam.RolePolicyAttachment(f"{servicio}-ssm-core", role=rol.name, opts=opts,
                                 policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore")
    if arn:
        aws.iam.RolePolicy(f"{servicio}-secretos", role=rol.id, name="leer-secretos-propios", opts=opts,
                           policy=pulumi.Output.json_dumps({"Version": "2012-10-17", "Statement": [
                               {"Effect": "Allow", "Action": ["ssm:GetParameter", "ssm:GetParameters"], "Resource": arn}]}))
    if servicio == "db" and bucket_respaldos:
        aws.iam.RolePolicy("db-respaldos", role=rol.id, name="respaldos-propios", opts=opts,
                           policy=pulumi.Output.json_dumps({"Version": "2012-10-17", "Statement": [
                               {"Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"],
                                "Resource": f"arn:aws:s3:::{bucket_respaldos}/{respaldos_prefijo}/*"}]}))
    perfiles[servicio] = aws.iam.InstanceProfile(servicio, name=f"{nombre}-{servicio}", role=rol.name, opts=opts)

# ───────────── Instancias ─────────────


def instancia(servicio, tipo, disco, sg, user_data, ignorar, depende=()):
    return aws.ec2.Instance(
        servicio, ami=ami, instance_type=tipo, subnet_id=subnet.id, vpc_security_group_ids=[sg.id],
        key_name=key_pair.key_name, iam_instance_profile=perfiles[servicio].name,
        metadata_options={"http_endpoint": "enabled", "http_tokens": "required"},
        root_block_device={"volume_size": disco, "volume_type": "gp3", "encrypted": True},
        user_data=user_data, tags={"Name": f"{nombre}-{servicio}", "Servicio": servicio},
        # Igual que en Terraform: cloud-init solo al primer arranque; nueva AMI = solo instancias nuevas
        opts=pulumi.ResourceOptions(provider=proveedor, ignore_changes=ignorar, depends_on=list(depende)),
    )


db = instancia("db", recursos["tipo_db"], recursos["disco_db_gb"], sg_db,
               cloud_init("db.yaml", region=region, ssm_prefijo=ssm_prefijo, vpc_cidr=vpc.cidr_block),
               ["ami", "userData"], [p_db])

env_backend = pulumi.Output.all(django_secret.result, db_password.result, eip.public_ip, db.private_ip).apply(
    lambda v: "\n".join([
        f"SECRET_KEY={v[0]}", "DEBUG=False", f"ALLOWED_HOSTS={v[2]},localhost,127.0.0.1",
        f"CORS_ALLOWED_ORIGINS=http://{v[2]}", "DB_NAME=asistencia_db", "DB_USER=asistencia",
        f"DB_PASSWORD={v[1]}", f"DB_HOST={v[3]}", "DB_PORT=5432", "JWT_HORAS=8", f"TENANT_ID={tenant_id}",
        f'TENANT_NOMBRE="{tenant_nombre}"', f"ENTORNO={entorno}", f"PLAN={plan}",
        f"MAX_ESTUDIANTES={recursos['max_estudiantes']}", f"MAX_MODULOS={recursos['max_modulos']}", "METRICAS=True", "",
    ]))
p_env = aws.ssm.Parameter("backend-env", name=f"{ssm_prefijo}/backend/env", type="SecureString",
                          value=pulumi.Output.secret(env_backend), opts=opts)

backend = instancia("backend", recursos["tipo_backend"], DISCO_APP_GB, sg_backend,
                    cloud_init("backend.yaml", region=region, ssm_prefijo=ssm_prefijo, repo_url=repo_backend,
                               app_version=app_version, admin_usuario=admin_usuario,
                               contacto_email=contacto_email, vpc_cidr=vpc.cidr_block),
                    ["ami", "userData"], [p_env, p_admin])
frontend = instancia("frontend", recursos["tipo_frontend"], DISCO_APP_GB, sg_frontend,
                     cloud_init("frontend.yaml", repo_url=repo_frontend, app_version=app_version,
                                backend_ip=backend.private_ip),
                     ["ami", "userData"])
aws.ec2.EipAssociation("frontend", instance_id=frontend.id, allocation_id=eip.allocation_id, opts=opts)

# Suspender / reanudar (RF-16): detener o encender las 3 instancias
estados = {
    servicio: aws.ec2transitgateway.InstanceState(  # así se llama en Pulumi el aws_ec2_instance_state
        f"estado-{servicio}", instance_id=inst.id, state="stopped" if suspendido else "running", opts=opts)
    for servicio, inst in (("db", db), ("backend", backend), ("frontend", frontend))
}

# Reinicio del backend cuando cambia su .env (p. ej. límites de un cambio de plan)
aws.ssm.Association(
    "reiniciar-backend", name="AWS-RunShellScript", association_name=f"{nombre}-reiniciar-backend",
    targets=[{"key": "InstanceIds", "values": [backend.id]}], opts=opts,
    parameters={"commands": pulumi.Output.unsecret(env_backend.apply(lambda e: "\n".join([
        f"# huella del .env: {hashlib.sha256(e.encode()).hexdigest()[:12]}",
        "if systemctl is-active --quiet asistencia; then systemctl restart asistencia; fi"])))})

# ───────────── Salidas (las mismas claves que Terraform; sin secretos) ─────────────

url = eip.public_ip.apply(lambda ip: f"http://{ip}")
pulumi.export("tenant", {"id": tenant_id, "nombre": tenant_nombre, "entorno": entorno, "plan": plan,
                         "version": app_version, "recursos": recursos, "ami": ami})
pulumi.export("url_frontend", url)
pulumi.export("url_panel_admin", url.apply(lambda u: f"{u}/panel/login"))
pulumi.export("url_api", url.apply(lambda u: f"{u}/api/modulo-activo/"))
pulumi.export("url_django_admin", url.apply(lambda u: f"{u}/django-admin/"))
pulumi.export("instancias", {"frontend": frontend.id, "backend": backend.id, "db": db.id})
pulumi.export("ips_privadas", {"frontend": frontend.private_ip, "backend": backend.private_ip, "db": db.private_ip})
pulumi.export("ssm_prefijo", ssm_prefijo)
pulumi.export("suspendido", suspendido)
pulumi.export("respaldos", f"s3://{bucket_respaldos}/{respaldos_prefijo}/" if bucket_respaldos else "")
pulumi.export("leer_admin_password", f"aws ssm get-parameter --region {region} --name {ssm_prefijo}/backend/admin_password "
                                     "--with-decryption --query Parameter.Value --output text")
pulumi.export("leer_llave_ssh", f"aws ssm get-parameter --region {region} --name {ssm_prefijo}/ssh/private_key "
                                f"--with-decryption --query Parameter.Value --output text > {nombre}.pem")
pulumi.export("session_manager", {k: v.id.apply(lambda i: f"aws ssm start-session --region {region} --target {i}")
                                  for k, v in (("frontend", frontend), ("backend", backend), ("db", db))})
