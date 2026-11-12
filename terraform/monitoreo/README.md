# Monitoreo · Prometheus + Grafana (RF-25 a RF-29)

Un solo servidor (EC2 `asistencia-monitoreo`) vigila a **todos** los tenants.

```
 Tenant (3 EC2)                                Servidor de monitoreo (Docker)
 ├ frontend  node_exporter :9100   ◄──┐        ├ Prometheus  descubre las EC2 por etiquetas
 ├ backend   node_exporter :9100   ◄──┤        ├ Blackbox    prueba de punta a punta
 │           Django /metrics :80   ◄──┼─────── └ Grafana :3000 (solo desde tus IPs)
 └ db        node_exporter :9100   ◄──┤             │ tablero + 10 reglas de alerta
             postgres_exporter     ◄──┘             ▼
                                         Plataforma: consulta las alertas cada 30 s (RF-29)
```

- **Sin configuración por tenant**: Prometheus encuentra las instancias por sus etiquetas EC2
  (`Proyecto`, `Tenant`, `Entorno`, `Servicio`, `Plan`) y las copia como etiquetas de las métricas.
  Un tenant nuevo aparece solo en Grafana.
- **Aislamiento**: los tenants abren sus puertos de métricas **solo** al security group de este
  servidor. `/metrics` de Django no es público: el frontend no lo reenvía y el Nginx del backend
  lo restringe a la red privada.
- Los tenants **suspendidos** no se vigilan (sus instancias están detenidas).

## Qué se mide (RF-26)
| Requisito | Métrica | Origen |
|---|---|---|
| Disponibilidad | `probe_success`: frontend → API → base, como un usuario | Blackbox |
| CPU y memoria | `node_cpu_seconds_total`, `node_memory_*` (+ disco) | node_exporter |
| Latencia | `asistencia_http_latencia_segundos` (p95) | Django (middleware propio) |
| Errores del backend | `asistencia_http_peticiones_total{estado="5xx"}` | Django |
| Estado de la base | `pg_up`, conexiones, tamaño | postgres_exporter |
| Uso del plan | `asistencia_uso_*` vs. `asistencia_limite_*` | Django |

El tablero **Asistencia · Salud de los tenants** tiene filtros de **entorno** y **tenant** (RF-27).

## Alertas (RF-28) — [`reglas.yml`](config/grafana/provisioning/alerting/reglas.yml)
| Regla | Se dispara cuando | Severidad |
|---|---|---|
| La aplicación no responde | la prueba de punta a punta falla 2 min | crítica |
| Un servicio no responde a las métricas | `up == 0` 2 min (instancia o proceso caído) | crítica |
| La base de datos no está disponible | `pg_up == 0` 1 min | crítica |
| Aumentaron los errores del backend | > 5 % de respuestas 5xx en 5 min | crítica |
| El backend responde lento | p95 > 1 s durante 10 min | aviso |
| CPU alta / Memoria casi agotada | > 85 % / > 90 % durante 10 min | aviso |
| Disco casi lleno | > 85 % durante 5 min | crítica |
| Límite de módulos del plan alcanzado | usa todos los módulos de su plan | aviso |
| Cerca del límite de estudiantes del plan | > 90 % de los estudiantes del plan | aviso |

La plataforma muestra cada alerta con su **tenant**, **entorno** y **hora de detección**, y la
marca como resuelta cuando Grafana deja de dispararla (RF-29).

## Crear el servidor
```powershell
cd infraestructura\terraform\monitoreo
terraform init -backend-config="..\tenant\backend.hcl" -backend-config="key=plataforma/monitoreo/terraform.tfstate"
terraform apply -var 'acceso_cidrs=["<tu IP>/32"]'      # tu IP: https://checkip.amazonaws.com
terraform output
```
- Genera `../tenant/monitoreo.auto.tfvars`: los tenants que apliques después abren sus métricas
  a este servidor. Para los ya creados: **Actualizar** desde la plataforma (o `tenant.ps1 -Accion apply`).
- Contraseña de Grafana (usuario `admin`): comando `leer_password_grafana` de las salidas.
- Espera 2 a 3 minutos a que Docker descargue las imágenes.

## Conectar la plataforma (`.env` del backend)
```
IAC_MONITOREO_SG=sg-...                    # salida monitoreo_sg_id
GRAFANA_URL=http://<IP>:3000               # salida grafana_url
GRAFANA_TOKEN=glsa_...                     # recomendado (o GRAFANA_PASSWORD)
```
Token: Grafana → *Administration → Users and access → Service accounts → Add service account*
(rol **Viewer**) → *Add service account token*. El worker sincroniza las alertas cada 30 s; en la
pantalla Alertas, **Actualizar ahora** lo hace al instante.

## Demostración: una alerta de ejemplo
Con un tenant activo, detén su backend (Session Manager o comando de las salidas del tenant):
```bash
sudo systemctl stop asistencia
```
En ~3 minutos se disparan **La aplicación no responde** y **Un servicio no responde a las
métricas** (django). Aparecen en Grafana y en la plataforma (Alertas, detalle del tenant y lista
de tenants). Luego `sudo systemctl start asistencia`: en ~2 minutos quedan **resueltas**.

## Costos
`t3.small` + 20 GB + IP pública ≈ USD 20/mes encendido. Para la demo: `terraform destroy` al
terminar (Prometheus guarda 15 días de métricas, que se pierden al destruir).
