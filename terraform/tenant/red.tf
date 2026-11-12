# ───────────── Red: VPC por defecto de la cuenta ─────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "principal" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.region}a"
  default_for_az    = true
}

# Ubuntu 24.04 LTS oficial (Canonical). Solo se usa si no se pasa ami_id.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

locals {
  nombre = "asistencia-${var.tenant_id}-${var.entorno}" # prefijo único por tenant y entorno
  ami    = coalesce(var.ami_id, data.aws_ami.ubuntu.id)
}

# ───────────── Firewalls (security groups) ─────────────
# Aislamiento: cada tenant tiene sus propios grupos y solo SU backend llega a SU base.
#
#   Internet ──80──► frontend ──80──► backend ──5432──► db

resource "aws_security_group" "frontend" {
  name        = "${local.nombre}-frontend"
  description = "Frontend del tenant ${var.tenant_id}: unica entrada publica"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP publico"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = length(var.ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH de administracion"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.nombre}-frontend" }
}

resource "aws_security_group" "backend" {
  name        = "${local.nombre}-backend"
  description = "Backend del tenant ${var.tenant_id}: solo desde su frontend"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP solo desde el frontend del mismo tenant"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  dynamic "ingress" {
    for_each = length(var.ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH de administracion"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_cidrs
    }
  }

  egress {
    description = "Salida a internet (git, pip, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.nombre}-backend" }
}

resource "aws_security_group" "db" {
  name        = "${local.nombre}-db"
  description = "PostgreSQL del tenant ${var.tenant_id}: solo desde su backend"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL solo desde el backend del mismo tenant"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  dynamic "ingress" {
    for_each = length(var.ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH de administracion"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_cidrs
    }
  }

  egress {
    description = "Salida a internet (paquetes, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.nombre}-db" }
}

# ───────────── IP pública fija: solo el frontend ─────────────
# Se conserva al suspender (stop) y reanudar (start) el tenant.
# Límite por defecto de AWS: 5 IPs elásticas por región (= 5 tenants a la vez).

resource "aws_eip" "frontend" {
  domain = "vpc"
  tags   = { Name = "${local.nombre}-frontend" }
}

# ───────────── Métricas: solo el servidor de monitoreo (Prometheus) puede leerlas ─────────────
#   node_exporter :9100 en las 3 instancias · postgres_exporter :9187 en la db
#   /metrics de Django por el puerto 80 del backend

locals {
  puertos_metricas = var.monitoreo_sg_id == "" ? {} : {
    frontend-node = { sg = aws_security_group.frontend.id, puerto = 9100, que = "node_exporter" }
    backend-node  = { sg = aws_security_group.backend.id, puerto = 9100, que = "node_exporter" }
    db-node       = { sg = aws_security_group.db.id, puerto = 9100, que = "node_exporter" }
    db-postgres   = { sg = aws_security_group.db.id, puerto = 9187, que = "postgres_exporter" }
    backend-app   = { sg = aws_security_group.backend.id, puerto = 80, que = "metricas de Django" }
  }
}

resource "aws_vpc_security_group_ingress_rule" "metricas" {
  for_each = local.puertos_metricas

  security_group_id            = each.value.sg
  referenced_security_group_id = var.monitoreo_sg_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.puerto
  to_port                      = each.value.puerto
  description                  = "Monitoreo: ${each.value.que}"
}
