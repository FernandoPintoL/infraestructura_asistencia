# Arquitectura de la plataforma de tenants

## Vista general

```mermaid
flowchart LR
  subgraph PC["Plataforma (instalación única)"]
    FE["Frontend React<br/>/plataforma"] --> API["Backend Django<br/>/api/plataforma"]
    API --> PG[("PostgreSQL<br/>planes, tenants,<br/>operaciones, alertas")]
    W["Worker<br/>manage.py worker_plataforma"] --> PG
  end

  subgraph AWS["AWS · us-east-1"]
    S3E[("S3 estado<br/>1 key / pila por tenant")]
    S3R[("S3 respaldos<br/>prefijo por tenant")]
    SSM[("SSM Parameter Store<br/>secretos por tenant")]
    subgraph T1["Tenant A (3 EC2)"]
      A1[frontend] --> A2[backend] --> A3[(db)]
    end
    subgraph T2["Tenant B (3 EC2)"]
      B1[frontend] --> B2[backend] --> B3[(db)]
    end
    MON["Monitoreo (EC2)<br/>Prometheus · Blackbox · Grafana"]
  end

  W -- "terraform / tofu / pulumi" --> S3E
  W -- "crea / cambia / suspende / elimina" --> T1 & T2
  W -- "SSM Run Command<br/>respaldos, despliegues" --> A3 & B3
  A3 & B3 -- pg_dump --> S3R
  A2 & B2 -. "lee sus secretos" .-> SSM
  MON -- "métricas (solo su SG)" --> T1 & T2
  W -- "API de alertas cada 30 s" --> MON
  U(("Usuarios del tenant")) --> A1 & B1
  ADM(("Admin plataforma")) --> FE
```

## Qué hace cada herramienta (sección 4 del enunciado)

| Herramienta | Función en esta arquitectura | Dónde |
|---|---|---|
| **Terraform / OpenTofu** | Motor principal: red, firewalls, roles IAM, secretos, 3 EC2 por tenant, suspender (detener instancias). Además el bucket de estado (`bootstrap/`) y el servidor de monitoreo | `infraestructura/terraform` |
| **Pulumi** | Segunda implementación del mismo tenant, elegible por tenant (RF-08) | `infraestructura/pulumi/tenant` |
| **CloudFormation** | Tercera implementación del mismo tenant, elegible por tenant; la plataforma completa lo que la pila no puede (secretos, `.env`, suspender) | `cloudformation/tenant`, [comparación](COMPARACION-MOTORES.md) |
| **cloud-init** | Configuración inicial de cada VM en su primer arranque: lee sus secretos de SSM, clona la app, migra, enciende servicios | `infraestructura/terraform/tenant/cloud-init` |
| **Packer** | Imagen base (AMI) con todo lo común ya instalado y endurecido: arranques de 1–3 min | `infraestructura/packer` |
| **Ansible** | Configuración posterior de la flota: endurecimiento, PostgreSQL según la memoria, actualizaciones masivas, verificación de salud; inventario dinámico por etiquetas, conexión por SSM | `infraestructura/ansible` |
| **Grafana** (+ Prometheus) | Métricas por tenant y entorno, tablero y 10 reglas de alerta; la plataforma muestra las alertas | `infraestructura/terraform/monitoreo` |

## Flujo de creación de un tenant

```mermaid
sequenceDiagram
  actor Admin as Admin de la plataforma
  participant UI as Frontend (/plataforma)
  participant API as Backend Django
  participant DB as Base de la plataforma
  participant W as Worker
  participant IaC as Terraform / OpenTofu / Pulumi
  participant AWS as AWS
  participant EC2 as EC2 del tenant (cloud-init)

  Admin->>UI: Nuevo tenant (datos, plan, entorno, motor)
  UI->>API: POST /tenants/
  API->>API: valida (identificador único, motor disponible)
  API->>DB: Tenant PENDIENTE + Operación CREAR PENDIENTE + Auditoría
  API-->>UI: 201 → pantalla de la operación
  loop cada 2 s (RF-11)
    UI->>API: GET /operaciones/<id>/ (progreso, paso, log sin secretos)
  end
  W->>DB: toma la operación (SELECT … FOR UPDATE SKIP LOCKED)
  W->>W: registra versiones (motor, plantillas, AMI, app) (RF-13)
  W->>IaC: init/plan/apply (estado propio en S3, con bloqueo)
  IaC->>AWS: SG, IAM, SSM (secretos), 3 EC2, IP elástica
  AWS-->>EC2: arranque
  EC2->>AWS: lee SUS secretos de SSM (rol IAM propio)
  EC2->>EC2: db: PostgreSQL · backend: Django+migraciones · frontend: build React
  IaC-->>W: salidas (URLs, instancias, IPs)
  W->>DB: Tenant ACTIVO · Operación EXITOSA (o FALLIDA + error comprensible)
  Note over W,DB: Si falla: «Reintentar» crea otra operación con los mismos datos;<br/>el motor compara contra el estado y solo crea lo que falta (RF-12)
```

## Estados de un tenant

```mermaid
stateDiagram-v2
  [*] --> PENDIENTE: registrar
  PENDIENTE --> APROVISIONANDO: CREAR
  APROVISIONANDO --> ACTIVO
  APROVISIONANDO --> ERROR
  ACTIVO --> ACTUALIZANDO: ACTUALIZAR / CAMBIAR_PLAN
  ACTUALIZANDO --> ACTIVO
  ACTIVO --> RESPALDANDO: RESPALDAR
  RESPALDANDO --> ACTIVO
  ACTIVO --> RESTAURANDO: RESTAURAR
  RESTAURANDO --> ACTIVO
  ACTIVO --> SUSPENDIENDO: SUSPENDER (respaldo + detener)
  SUSPENDIENDO --> SUSPENDIDO
  SUSPENDIDO --> REANUDANDO: REANUDAR
  REANUDANDO --> ACTIVO
  SUSPENDIDO --> ACTUALIZANDO: CAMBIAR_PLAN
  ERROR --> APROVISIONANDO: reintentar
  ACTIVO --> ELIMINANDO: ELIMINAR (respaldo final)
  SUSPENDIDO --> ELIMINANDO
  ERROR --> ELIMINANDO
  ELIMINANDO --> ELIMINADO
  ELIMINADO --> [*]
```
Una sola operación a la vez por tenant (restricción en la base de datos). Si una operación falla
antes de tocar la infraestructura (por ejemplo, el respaldo previo), el tenant vuelve a su estado
anterior; si el motor llegó a ejecutarse, queda en `ERROR` para revisar y reintentar.

## Aislamiento entre tenants (modelo *silo*)

| Capa | Cómo se aísla | Se prueba en |
|---|---|---|
| Cómputo y datos | Cada tenant tiene sus 3 EC2 y su propia base PostgreSQL | — |
| Red | Security groups encadenados: internet → frontend → backend → db, **del mismo tenant** | `probar_aislamiento` (Red) |
| Secretos | SSM `/asistencia/<tenant>/<entorno>/…`; el rol IAM de cada instancia solo lee su ruta y su servicio | `probar_aislamiento` (Secretos) |
| Respaldos | Prefijo S3 `tenants/<tenant>/<entorno>/`; solo el rol de la db de ese tenant escribe ahí | `probar_aislamiento` (Respaldos) |
| Aplicación | `SECRET_KEY` distinta por tenant: un token de un tenant no vale en otro | `probar_aislamiento` (Aplicación) |
| Estado de IaC | Una key (Terraform) o pila (Pulumi, CloudFormation) por tenant: un error o `destroy` no toca a otros | — |
| Métricas | Puertos de métricas abiertos solo al security group del monitoreo | — |
| Plataforma | El admin de un tenant solo ve sus tenants, operaciones, respaldos y alertas | pruebas automáticas del backend |

## Seguridad de secretos y del estado
- Ningún secreto en el código, en los `.tfvars` ni en el `user_data`: los genera el motor y van a
  **SSM SecureString** (KMS). Las instancias los leen con su rol IAM.
- El **estado** sí contiene secretos: por eso vive en S3 **privado, cifrado (SSE-KMS), solo HTTPS,
  versionado y con bloqueo**, con una key por tenant. Pulumi además cifra los secretos con
  `PULUMI_CONFIG_PASSPHRASE`.
- Los logs de las operaciones pasan por un **redactor** que oculta contraseñas, tokens, llaves de
  AWS y bloques PEM; los errores técnicos se traducen a mensajes comprensibles (RF-11).
- IMDSv2 obligatorio y discos cifrados en todas las instancias; SSH cerrado (acceso por Session Manager).
