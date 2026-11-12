# ───────────── Servidor de monitoreo de la plataforma (RF-25 a RF-28) ─────────────
# UNA instancia para todos los tenants: Prometheus + Blackbox exporter + Grafana (Docker).
#   - Prometheus descubre solo las EC2 de los tenants por sus etiquetas (no hay IPs a mano).
#   - Grafana es lo único accesible desde fuera, y solo desde las IPs de acceso_cidrs.
#   - Los tenants abren sus puertos de métricas SOLO a este security group.
#
#   terraform init -backend-config=../tenant/backend.hcl -backend-config="key=plataforma/monitoreo/terraform.tfstate"
#   terraform apply -var 'acceso_cidrs=["<tu IP>/32"]'

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 5.0" }
    random = { source = "hashicorp/random", version = ">= 3.5" }
    local  = { source = "hashicorp/local", version = ">= 2.4" }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Proyecto   = "asistencia"
      Componente = "monitoreo"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "tipo_instancia" {
  description = "Prometheus + Grafana necesitan ~1,5 GB de memoria"
  type        = string
  default     = "t3.small"
}

variable "acceso_cidrs" {
  description = "IPs (CIDR) que pueden abrir Grafana, ej. [\"181.115.10.20/32\"]"
  type        = list(string)

  validation {
    condition     = length(var.acceso_cidrs) > 0 && alltrue([for c in var.acceso_cidrs : can(cidrhost(c, 0))])
    error_message = "Indica al menos una IP en formato CIDR (no 0.0.0.0/0 salvo que sepas lo que haces)."
  }
}

variable "ami_id" {
  description = "AMI (la de Packer sirve). null = última Ubuntu 24.04 de Canonical"
  type        = string
  default     = null
}

# ───────────── Red ─────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "principal" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.region}a"
  default_for_az    = true
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_caller_identity" "actual" {}

locals {
  nombre       = "asistencia-monitoreo"
  ssm_password = "/asistencia/plataforma/grafana/admin_password"
  carpeta      = "/opt/monitoreo"
  config       = "${path.module}/config"
  archivos_fijo = ["docker-compose.yml", "blackbox.yml", "grafana/provisioning/datasources/prometheus.yml",
  "grafana/provisioning/dashboards/proveedor.yml", "grafana/provisioning/alerting/reglas.yml", "grafana/dashboards/tenants.json"]
}

resource "aws_security_group" "monitoreo" {
  name        = local.nombre
  description = "Grafana solo desde las IPs de administracion; sale a internet y a los tenants"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.acceso_cidrs
  }

  egress {
    description = "Lectura de metricas de los tenants e internet (imagenes Docker)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.nombre }
}

# ───────────── Rol: descubrir instancias y leer la contraseña de Grafana ─────────────

resource "aws_iam_role" "monitoreo" {
  name = local.nombre
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "monitoreo" {
  name = "descubrir-y-leer-secreto"
  role = aws_iam_role.monitoreo.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescubrimientoEC2"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
        Resource = "*"
      },
      {
        Sid      = "PasswordGrafana"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.actual.account_id}:parameter${local.ssm_password}"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.monitoreo.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoreo" {
  name = local.nombre
  role = aws_iam_role.monitoreo.name
}

# ───────────── Contraseña del administrador de Grafana (en SSM, no en el código) ─────────────

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "grafana" {
  name        = local.ssm_password
  description = "Contraseña del usuario admin de Grafana"
  type        = "SecureString"
  value       = random_password.grafana.result
}

# ───────────── Instancia ─────────────
# La configuración (Prometheus, reglas de alerta, tablero) viaja en el user_data comprimido.

locals {
  cloud_init = join("\n", ["#cloud-config", yamlencode({
    packages = ["docker.io", "docker-compose-v2"]
    write_files = concat(
      [for f in local.archivos_fijo : {
        path     = "${local.carpeta}/${f}"
        encoding = "b64"
        content  = base64encode(file("${local.config}/${f}"))
      }],
      [{
        path     = "${local.carpeta}/prometheus.yml"
        encoding = "b64"
        content  = base64encode(templatefile("${local.config}/prometheus.yml.tftpl", { region = var.region }))
      }],
    )
    runcmd = [
      "snap list aws-cli >/dev/null 2>&1 || snap install aws-cli --classic",
      join("\n", [
        "set -e",
        "until P=$(/snap/bin/aws ssm get-parameter --region ${var.region} --name ${local.ssm_password} --with-decryption --query Parameter.Value --output text); do sleep 10; done",
        "umask 077",
        "printf 'GF_SECURITY_ADMIN_PASSWORD=%s\\n' \"$P\" > ${local.carpeta}/.env",
      ]),
      "cd ${local.carpeta} && docker compose up -d",
      "echo MONITOREO LISTO",
    ]
  })])
}

resource "aws_instance" "monitoreo" {
  ami                    = coalesce(var.ami_id, data.aws_ami.ubuntu.id)
  instance_type          = var.tipo_instancia
  subnet_id              = data.aws_subnet.principal.id
  vpc_security_group_ids = [aws_security_group.monitoreo.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoreo.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # los contenedores también consultan el rol
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_base64            = base64gzip(local.cloud_init)
  user_data_replace_on_change = true # sin datos importantes: cambiar la configuración recrea el servidor

  depends_on = [aws_ssm_parameter.grafana, aws_iam_role_policy.monitoreo]

  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = local.nombre }
}

resource "aws_eip" "monitoreo" {
  domain   = "vpc"
  instance = aws_instance.monitoreo.id
  tags     = { Name = local.nombre }
}

# Para tenant.ps1: los tenants abren sus puertos de métricas a este security group
resource "local_file" "tenant_tfvars" {
  filename = "${path.module}/../tenant/monitoreo.auto.tfvars"
  content  = "monitoreo_sg_id = \"${aws_security_group.monitoreo.id}\"\n"
}

# ───────────── Salidas ─────────────

output "grafana_url" {
  value = "http://${aws_eip.monitoreo.public_ip}:3000"
}

output "monitoreo_sg_id" {
  description = "Para IAC_MONITOREO_SG de la plataforma"
  value       = aws_security_group.monitoreo.id
}

output "leer_password_grafana" {
  value = "aws ssm get-parameter --region ${var.region} --name ${local.ssm_password} --with-decryption --query Parameter.Value --output text"
}

output "tamano_user_data" {
  description = "Bytes del user_data comprimido (límite de AWS: 16384)"
  value       = length(base64gzip(local.cloud_init))
}
