# Catálogo de planes y límites (entregable 4)

Cada tenant tiene **siempre 3 instancias separadas** (frontend, backend y base de datos). El plan
define su tamaño, el disco de la base, los límites de uso y la retención de respaldos. El
administrador de la plataforma puede editar los planes o crear otros (pantalla **Planes**, RF-04);
estos son los valores iniciales (`manage.py crear_planes`).

| | **Básico** | **Estándar** | **Avanzado** |
|---|---|---|---|
| Para quién | Institución pequeña, un curso a la vez | Varios cursos y más estudiantes | Instituciones grandes |
| Frontend (EC2) | t3.micro | t3.micro | t3.small |
| Backend (EC2) | t3.micro | t3.small | t3.medium |
| Base de datos (EC2) | t3.micro | t3.small | t3.medium |
| Disco de la base | 10 GB | 20 GB | 40 GB |
| **Máx. estudiantes por módulo** | 100 | 500 | 2000 |
| **Máx. módulos guardados** | 2 | 10 | 50 |
| Retención de respaldos | 7 días | 14 días | 30 días |
| Precio de referencia | US$ 35/mes | US$ 55/mes | US$ 110/mes |

## Cómo se hacen cumplir los límites (RF-05)
- **Cómputo y almacenamiento**: los aplica la infraestructura (tamaño de instancia y disco).
- **Estudiantes y módulos**: Terraform/Pulumi escriben `MAX_ESTUDIANTES` y `MAX_MODULOS` en el `.env`
  del backend del tenant. El backend **rechaza** importar un módulo que los supere, tanto en la vista
  previa como al confirmar, y el servicio vuelve a comprobarlo antes de guardar. El panel del tenant
  muestra su plan y su uso.
- **Avisos**: Grafana alerta cuando un tenant usa todos sus módulos o más del 90 % de sus estudiantes.

## Qué pasa al cambiar de plan (RF-06)
La plataforma muestra, antes de confirmar, qué recurso cambia, su valor actual y nuevo, y el efecto:

| Cambio | Efecto |
|---|---|
| Tipo de instancia | Se detiene, cambia de tamaño y vuelve a arrancar (1–3 min sin servicio). Disco, datos e IP se conservan |
| Disco de la base (sube) | Se amplía en sitio, sin detener la base |
| Disco de la base (baja) | **Se mantiene**: los discos de AWS no se pueden reducir |
| Límites de estudiantes / módulos | El backend se reinicia solo (unos segundos). Si ya se superan, no se borra nada; solo no se puede crear más |
| Retención de respaldos | Se aplica a los respaldos nuevos |

Además, **«Ver detalle exacto con el motor»** ejecuta un `plan`/`preview` y lista los recursos
exactos que se crearían, modificarían o reemplazarían, sin aplicar nada.

## Costos aproximados (us-east-1, encendido todo el mes)
| | Básico | Estándar | Avanzado |
|---|---|---|---|
| 3 EC2 + discos + IPs públicas | ≈ USD 37 | ≈ USD 53 | ≈ USD 91 |
| Suspendido (solo discos + IP elástica) | ≈ USD 6 | ≈ USD 7 | ≈ USD 9 |

El precio de referencia del catálogo cubre además el servidor de monitoreo compartido y los respaldos.

Para pruebas: **suspender** o **eliminar** los tenants al terminar (requisito de control de costos).
