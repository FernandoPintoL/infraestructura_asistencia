# Imagen base (AMI) para las 3 instancias de cada tenant: frontend, backend y base de datos.
# Lleva instalado todo lo común; cloud-init solo agrega lo propio de cada tenant.
#
#   packer init .
#   packer validate .
#   packer build .                      # ~10 minutos; crea la AMI y escribe manifest.json
#   packer build -var version=1.1.0 .

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "tipo_instancia" {
  description = "Instancia temporal donde se arma la imagen (se borra al terminar)"
  type        = string
  default     = "t3.small"
}

variable "version" {
  description = "Versión de la imagen (queda en el nombre y en las etiquetas, RF-13)"
  type        = string
  default     = "1.0.0"
}

locals {
  marca = formatdate("YYYYMMDD-hhmm", timestamp())
}

source "amazon-ebs" "base" {
  region          = var.region
  instance_type   = var.tipo_instancia
  ami_name        = "asistencia-base-${var.version}-${local.marca}"
  ami_description = "Ubuntu 24.04 + Nginx, Python, Node.js 22, PostgreSQL, AWS CLI, node_exporter (sistema de asistencia)"

  # Ubuntu 24.04 LTS oficial de Canonical (la más reciente)
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  ssh_username            = "ubuntu"
  temporary_key_pair_type = "ed25519"
  # El firewall temporal solo deja entrar por SSH a la IP de quien ejecuta Packer
  temporary_security_group_source_public_ip = true

  # Las instancias que nazcan de esta imagen exigen IMDSv2
  imds_support = "v2.0"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name     = "asistencia-base"
    Proyecto = "asistencia"
    Version  = var.version
    Base     = "ubuntu-24.04"
    Creada   = local.marca
  }
  run_tags = {
    Name     = "packer-asistencia-base"
    Proyecto = "asistencia"
  }
}

build {
  sources = ["source.amazon-ebs.base"]

  provisioner "shell" {
    script          = "${path.root}/scripts/base.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "VERSION_IMAGEN=${var.version}",
    ]
  }

  # manifest.json: el ID de la AMI creada (para IAC_AMI_ID / ami_id)
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
    custom_data = {
      version = var.version
    }
  }
}
