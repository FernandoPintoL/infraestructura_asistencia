# Comparación de motores de aprovisionamiento

La plataforma deja elegir el motor de cada tenant (RF-08). **Terraform** es el motor principal;
**OpenTofu** usa las mismas plantillas; **Pulumi** es la segunda implementación completa; y
**CloudFormation** es la tercera: una plantilla nativa más una parte en la plataforma para lo que
CloudFormation no puede hacer solo. Los cuatro crean exactamente la misma infraestructura.

## Qué hay de cada uno en el proyecto

| Motor | Implementación | En la plataforma |
|---|---|---|
| Terraform | [`terraform/tenant`](../terraform/tenant) (+ `bootstrap/`, `monitoreo/`) | ✅ motor principal |
| OpenTofu | Las mismas plantillas de Terraform (`-Motor tofu` / motor `tofu`) | ✅ |
| Pulumi (Python) | [`pulumi/tenant`](../pulumi/tenant), mismos cloud-init y salidas | ✅ segunda implementación |
| CloudFormation | [`cloudformation/tenant/tenant.yaml`](../cloudformation/tenant/tenant.yaml) + `plataforma/motores/cloudformation.py`, mismos cloud-init y salidas | ✅ tercera implementación |

La primera versión de un solo sistema (trabajo anterior del módulo) se conserva en
[`cloudformation/un-tenant/`](../cloudformation/un-tenant/README.md) como referencia.

## Datos medidos en este proyecto

| | Terraform | Pulumi | CloudFormation |
|---|---|---|---|
| Versión de 1 tenant (trabajo anterior), líneas sin comentarios | 275 | 142 | 340 |
| Versión multi-tenant, líneas sin comentarios | 610 (9 archivos) | 193 (1 archivo; líneas más largas) | 319 de plantilla **+ ~480 de Python** en la plataforma |
| Recursos por tenant | 25 tipos declarados | los mismos | 20 en la pila (5 condicionales) + 4 parámetros SSM y el estado de las instancias desde la plataforma |
| Pruebas sin la nube | `terraform validate` + render de cloud-init | 3 pruebas con *mocks* de Pulumi (`test_programa.py`) | `cfn-lint` (0 avisos) + 10 pruebas del motor con AWS falso (`MotorCloudFormationTests`) |

## Comparación técnica

| Criterio | Terraform / OpenTofu | Pulumi | CloudFormation |
|---|---|---|---|
| Lenguaje | HCL declarativo | Python (o TS, Go…) | YAML/JSON declarativo |
| Nubes | Multi-nube | Multi-nube (mismos proveedores) | Solo AWS |
| Estado | Archivo de estado; aquí en **S3 cifrado, versionado, con bloqueo**, una *key* por tenant | Igual, en el **mismo bucket** (`pulumi/`), una *pila* por tenant | Lo guarda AWS (una pila por tenant); no hay archivo que proteger ni bloqueo que liberar |
| Secretos generados | ✅ `random_password` → SSM SecureString | ✅ `RandomPassword` → SSM SecureString; además cifra los secretos del estado con una frase | ⚠️ No puede crear SSM **SecureString**: los genera la plataforma (Python `secrets`) y los guarda en SSM antes de crear la pila |
| Componer el `.env` con varios secretos | ✅ | ✅ | ⚠️ No puede leer un secreto para escribir otro: lo arma la plataforma en cuanto la pila crea la base y la IP pública (el backend lo espera al arrancar) |
| Vista previa de cambios | `plan` (JSON: `show -json`) | `preview --json` | *Change sets* (tenant existente) o lista de recursos de la plantilla (tenant nuevo) |
| Bucles / condicionales | `for_each`, `count`, expresiones | Todo Python | `Conditions`, sin bucles: los 3 servidores y las 5 reglas de métricas van escritos uno por uno |
| Detener/encender instancias (suspender) | `aws_ec2_instance_state` | `aws.ec2transitgateway.InstanceState` | ⚠️ No existe ese recurso: la plataforma usa la API de EC2 después de la pila |
| Ignorar cambios (cloud-init solo al primer arranque) | `lifecycle.ignore_changes` | `ignore_changes` | ⚠️ No existe: la plataforma manda la AMI y el user_data **con el valor previo** (`UsePreviousValue`); si no, se reiniciaría o reemplazaría la instancia |
| Agrandar el disco de la base | En sitio | En sitio | ❌ Cambiar el tamaño en la plantilla **reemplaza** la instancia (se perderían los datos): la plataforma lo agranda con la API de EC2 |
| Límites | — | — | 4096 bytes por parámetro: el user_data va comprimido (gzip) |
| Pruebas unitarias | Limitadas (`terraform test`) | Naturales (pytest + *mocks*) | `cfn-lint`, `taskcat`; el motor se prueba con clientes de AWS falsos |
| Herramienta en el worker | Binario `terraform` / `tofu` | CLI `pulumi` + venv con los SDK | Ninguna (API de AWS con boto3) |
| Permisos extra | — | — | `AWSCloudFormationFullAccess` para el usuario de la plataforma |
| Curva de aprendizaje del curso | Baja; es el estándar del mercado | Media (requiere programar) | Baja en sintaxis, alta en limitaciones |

## Cómo los integra la plataforma
Los cuatro motores implementan el mismo contrato (`plataforma/motores/base.py`): `aplicar`,
`previsualizar`, `destruir` y `versiones`. Reciben las **mismas variables** (datos del tenant,
recursos del plan, versión, `suspendido`, bucket de respaldos, monitoreo) y devuelven las **mismas
salidas** (URLs, IDs de instancias, IPs). Por eso suspender, respaldar, desplegar en sitio,
monitorear y probar el aislamiento funcionan igual sin importar el motor.

Única diferencia visible: con CloudFormation la llave SSH la genera la propia pila y queda en
`/ec2/keypair/<id>` (la salida `leer_llave_ssh` lo indica), no en `/asistencia/<tenant>/<entorno>/ssh/`.

## Conclusión
- **Terraform** queda como motor principal: el más difundido, multi-nube, estado explícito y bien
  protegido, y las plantillas sirven también para **OpenTofu** (licencia abierta) sin cambios.
- **Pulumi** es la mejor alternativa cuando el equipo prefiere programar: el tenant entero cabe en
  un archivo de Python, se prueba con pytest sin tocar AWS y reutiliza los mismos cloud-init.
  Costo: un runtime más en el worker y una frase secreta adicional que custodiar.
- **CloudFormation** funciona y tiene ventajas reales (sin herramienta que instalar, sin archivo de
  estado, *rollback* automático si la creación falla), pero **la plantilla sola no alcanza**: los
  secretos, el `.env`, la suspensión, el tamaño del disco y "no tocar el user_data" los resuelve
  código de la plataforma (~480 líneas). Es decir, parte de la infraestructura deja de estar en la
  plantilla, y eso la hace más difícil de leer y de mantener que Terraform o Pulumi. Se ofrece como
  opción para quien ya trabaja con CloudFormation, no como recomendación.
