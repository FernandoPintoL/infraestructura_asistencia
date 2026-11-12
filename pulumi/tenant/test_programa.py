"""
Pruebas del programa de Pulumi SIN la CLI y SIN AWS (mocks del motor de Pulumi).

    pip install -r requirements.txt pytest
    python -m pytest test_programa.py -q

Ejecuta __main__.py de verdad, pero cada recurso "se crea" en memoria: así se comprueba qué
recursos declara, con qué nombres, etiquetas y user_data, y qué salidas produce.
"""
import json
import runpy
from pathlib import Path

import pulumi
import pytest

PROYECTO = "asistencia-tenant"
recursos_creados = []


class Mocks(pulumi.runtime.Mocks):
    def new_resource(self, args):
        salidas = dict(args.inputs)
        n = len(recursos_creados) + 10
        if args.typ == "aws:ec2/instance:Instance":
            salidas.update(privateIp=f"172.31.0.{n}", publicIp=f"54.0.0.{n}")
        elif args.typ == "random:index/randomPassword:RandomPassword":
            salidas["result"] = "s" * int(args.inputs["length"])
        elif args.typ == "tls:index/privateKey:PrivateKey":
            salidas.update(privateKeyOpenssh="LLAVE-PRIVADA", publicKeyOpenssh="ssh-ed25519 AAAA")
        elif args.typ == "aws:ec2/eip:Eip":
            salidas.update(publicIp="3.3.3.3", allocationId="eipalloc-1")
        recursos_creados.append((args.typ, args.name, salidas))
        return [f"{args.name}-id", salidas]

    def call(self, args):
        if args.token == "aws:ec2/getVpc:getVpc":
            return {"id": "vpc-1", "cidrBlock": "172.31.0.0/16"}
        if args.token == "aws:ec2/getSubnet:getSubnet":
            return {"id": "subnet-1"}
        if args.token == "aws:ec2/getAmi:getAmi":
            return {"id": "ami-ubuntu"}
        if args.token == "aws:index/getCallerIdentity:getCallerIdentity":
            return {"accountId": "123456789012", "arn": "arn", "id": "1", "userId": "u"}
        return {}


def ejecutar(config):
    recursos_creados.clear()
    pulumi.runtime.set_mocks(Mocks(), project=PROYECTO, stack="prueba", preview=False)
    for clave, valor in config.items():
        pulumi.runtime.set_config(clave if ":" in clave else f"{PROYECTO}:{clave}",
                                  valor if isinstance(valor, str) else json.dumps(valor))
    return runpy.run_path(str(Path(__file__).with_name("__main__.py")))


BASE = {"tenant_id": "colegio-demo", "tenant_nombre": "Colegio Demo", "contacto_email": "a@colegio.edu",
        "entorno": "dev", "plan": "basico", "aws:region": "us-east-1"}


def de_tipo(tipo):
    return [(n, s) for t, n, s in recursos_creados if t == tipo]


@pulumi.runtime.test
def test_tres_instancias_con_su_tamano_etiquetas_y_cloud_init():
    g = ejecutar({**BASE, "suspendido": False})

    def verificar(_):
        instancias = dict(de_tipo("aws:ec2/instance:Instance"))
        assert set(instancias) == {"db", "backend", "frontend"}
        assert instancias["db"]["instanceType"] == "t3.micro"
        assert instancias["db"]["rootBlockDevice"]["volumeSize"] == 10
        assert instancias["backend"]["tags"]["Servicio"] == "backend"
        assert instancias["backend"]["metadataOptions"]["httpTokens"] == "required"
        # El cloud-init es el mismo de Terraform, con las variables reemplazadas y sin secretos
        ud = instancias["backend"]["userData"]
        assert ud.startswith("#cloud-config") and "${" not in ud.split("location = /metrics")[0]
        assert "/asistencia/colegio-demo/dev" in ud and "allow 172.31.0.0/16;" in ud
        assert "s" * 24 not in ud  # la contraseña de la base NO viaja en el user_data
        estados = {n: s["state"] for n, s in de_tipo("aws:ec2transitgateway/instanceState:InstanceState")}
        assert estados == {"estado-db": "running", "estado-backend": "running", "estado-frontend": "running"}
        nombres = {s["name"] for _, s in de_tipo("aws:ec2/securityGroup:SecurityGroup")}
        assert nombres == {f"asistencia-colegio-demo-dev-{x}" for x in ("frontend", "backend", "db")}

    return pulumi.Output.all(*(e.id for e in g["estados"].values())).apply(verificar)


@pulumi.runtime.test
def test_suspendido_recursos_de_la_plataforma_y_monitoreo():
    recursos = {"tipo_frontend": "t3.small", "tipo_backend": "t3.large", "tipo_db": "t3.medium",
                "disco_db_gb": 60, "max_estudiantes": 3000, "max_modulos": 80}
    g = ejecutar({**BASE, "plan": "plan-a-medida", "recursos": recursos, "suspendido": True,
                  "monitoreo_sg_id": "sg-mon", "bucket_respaldos": "respaldos-x"})

    def verificar(_):
        instancias = dict(de_tipo("aws:ec2/instance:Instance"))
        assert instancias["backend"]["instanceType"] == "t3.large"
        assert instancias["db"]["rootBlockDevice"]["volumeSize"] == 60
        assert {s["state"] for _, s in de_tipo("aws:ec2transitgateway/instanceState:InstanceState")} == {"stopped"}
        assert len(de_tipo("aws:vpc/securityGroupIngressRule:SecurityGroupIngressRule")) == 5
        politicas = {n: json.loads(s["policy"]) for n, s in de_tipo("aws:iam/rolePolicy:RolePolicy")}
        assert politicas["db-respaldos"]["Statement"][0]["Resource"] == \
            "arn:aws:s3:::respaldos-x/tenants/colegio-demo/dev/*"
        assert politicas["backend-secretos"]["Statement"][0]["Resource"].endswith(
            ":parameter/asistencia/colegio-demo/dev/backend/*")

    return pulumi.Output.all(*(e.id for e in g["estados"].values())).apply(verificar)


def test_identificador_invalido_se_rechaza():
    with pytest.raises(ValueError, match="tenant_id"):
        ejecutar({**BASE, "tenant_id": "Colegio Demo"})
