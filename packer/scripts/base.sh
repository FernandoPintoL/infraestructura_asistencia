#!/bin/bash
# Se ejecuta UNA vez, dentro de la instancia temporal de Packer, para armar la imagen base.
# Todo lo que queda aquí ya no tiene que instalarlo cloud-init en cada instancia nueva.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Esperar a que termine el cloud-init de la instancia temporal (usa apt al arrancar)
cloud-init status --wait || true

# ── Sistema al día ──
apt-get update
apt-get -y upgrade

# ── Paquetes comunes a los 3 servicios ──
#   nginx                    frontend y backend
#   python3-venv             backend (Django + Gunicorn)
#   postgresql               base de datos (se enciende solo en la instancia db)
#   postgresql-client        backend (espera a la base) y respaldos
#   prometheus-node-exporter métricas de CPU, memoria y disco (Grafana)
#   prometheus-postgres-exporter métricas de PostgreSQL (se enciende solo en la instancia db)
#   unattended-upgrades      parches de seguridad automáticos
apt-get install -y --no-install-recommends \
  nginx git curl ca-certificates python3-venv python3-pip \
  postgresql postgresql-client \
  prometheus-node-exporter prometheus-postgres-exporter unattended-upgrades

# ── Node.js 22 (el de Ubuntu es muy antiguo para Vite) ──
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# ── AWS CLI v2 (lee secretos de SSM y sube respaldos a S3) ──
snap install aws-cli --classic

# ── Servicios: cada instancia enciende solo lo suyo (lo hace cloud-init) ──
systemctl disable --now postgresql prometheus-postgres-exporter
rm -f /etc/nginx/sites-enabled/default

# ── Endurecimiento básico ──
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/ssh/sshd_config.d/50-asistencia.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/asistencia.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
timedatectl set-timezone America/La_Paz

# ── Marca de la imagen (la plataforma y Ansible pueden leerla) ──
cat > /etc/asistencia-imagen <<EOF
nombre=asistencia-base
version=${VERSION_IMAGEN:-desconocida}
creada=$(date -u +%Y-%m-%dT%H:%M:%SZ)
node=$(node --version)
python=$(python3 --version | cut -d' ' -f2)
postgresql=$(ls /etc/postgresql)
EOF

# ── Limpieza: cada instancia que nazca de la imagen debe arrancar "como nueva" ──
apt-get -y autoremove
apt-get clean
rm -rf /var/lib/apt/lists/*
cloud-init clean --logs --machine-id
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
cat /etc/asistencia-imagen
