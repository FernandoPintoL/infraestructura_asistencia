# Comparación de motores de aprovisionamiento

La plataforma deja elegir el motor de cada tenant (RF-08). **Terraform** es el motor principal;
**OpenTofu** usa las mismas plantillas; **Pulumi** es la segunda implementación completa; y
**CloudFormation** se evaluó con una implementación de un solo tenant (`anteriores/cloud_init/cloudformation`)
y se documenta aquí por qué no se adoptó como motor multi-tenant.

## Qué hay de cada uno en el proyecto

| Motor | Implementación | Multi-tenant en la plataforma |
|---|---|---|
| Terraform | [`infraestructura/terraform/tenant`](../infraestructura/terraform/tenant) (+ `bootstrap/`, `monitoreo/`) | ✅ motor principal |
| OpenTofu | Las mismas plantillas de Terraform (`-Motor tofu` / motor `tofu`) | ✅ |
| Pulumi (Python) | [`infraestructura/pulumi/tenant`](../infraestructura/pulumi/tenant), mismos cloud-init y salidas | ✅ segunda implementación |
| CloudFormation | [`anteriores/cloud_init/cloudformation`](../anteriores/cloud_init/cloudformation/asistencia.yaml) (versión de 1 tenant) | ❌ ver conclusión |

## Datos medidos en este proyecto

| | Terraform | Pulumi | CloudFormation |
|---|---|---|---|
| Versión de 1 tenant (`anteriores/cloud_init/`), líneas sin comentarios | 275 | 142 | 340 |
| Versión multi-tenant (`infraestructura/`), líneas sin comentarios | 610 (9 archivos) | 193 (1 archivo; líneas más largas) | — |
| Recursos por tenant | 25 tipos declarados | los mismos | — |
| Pruebas sin la nube | `terraform validate` + render de cloud-init | 3 pruebas con *mocks* de Pulumi (`test_programa.py`) | `cfn-lint` (no incluido) |

## Comparación técnica

| Criterio | Terraform / OpenTofu | Pulumi | CloudFormation |
|---|---|---|---|
| Lenguaje | HCL declarativo | Python (o TS, Go…) | YAML/JSON declarativo |
| Nubes | Multi-nube | Multi-nube (mismos proveedores) | Solo AWS |
| Estado | Archivo de estado; aquí en **S3 cifrado, versionado, con bloqueo**, una *key* por tenant | Igual, en el **mismo bucket** (`pulumi/`), una *pila* por tenant | Lo guarda AWS (pila); no hay archivo que proteger |
| Secretos generados (`random_password`) | ✅ `random_password` → SSM SecureString | ✅ `RandomPassword` → SSM SecureString; además cifra los secretos del estado con una frase | ⚠️ No puede crear SSM **SecureString**; habría que usar Secrets Manager (USD 0,40/secreto/mes) o una función Lambda personalizada |
| Componer un `.env` con varios secretos | ✅ | ✅ | ❌ (`!Sub` no puede leer valores de Secrets Manager dentro de otro secreto) |
| Vista previa de cambios | `plan` (JSON: `show -json`) | `preview --json` | *Change sets* |
| Bucles / condicionales | `for_each`, `count`, expresiones | Todo Python | `Conditions`, sin bucles reales (macros/`Fn::ForEach` limitado) |
| Detener/encender instancias (suspender) | `aws_ec2_instance_state` | `aws.ec2transitgateway.InstanceState` (mismo recurso, otro módulo) | ❌ no existe: haría falta una Lambda o la API de EC2 fuera de la pila |
| Ignorar cambios (cloud-init solo al primer arranque) | `lifecycle.ignore_changes` | `ignore_changes` | ❌ un cambio de `UserData` reemplaza o reinicia la instancia |
| Pruebas unitarias | Limitadas (`terraform test`) | Naturales (pytest + *mocks*) | `cfn-lint`, `taskcat` |
| Herramienta en el worker | Binario `terraform` / `tofu` | CLI `pulumi` + venv con los SDK | Ninguna (API de AWS con boto3) |
| Curva de aprendizaje del curso | Baja; es el estándar del mercado | Media (requiere programar) | Baja en sintaxis, alta en limitaciones |

## Cómo los integra la plataforma
Los tres motores implementan el mismo contrato (`plataforma/motores/base.py`): `aplicar`,
`previsualizar`, `destruir` y `versiones`. Reciben las **mismas variables** (datos del tenant,
recursos del plan, versión, `suspendido`, bucket de respaldos, monitoreo) y devuelven las **mismas
salidas** (URLs, IDs de instancias, IPs). Por eso suspender, respaldar, desplegar en sitio,
monitorear y probar el aislamiento funcionan igual sin importar el motor.

## Conclusión
- **Terraform** queda como motor principal: el más difundido, multi-nube, estado explícito y bien
  protegido, y las plantillas sirven también para **OpenTofu** (licencia abierta) sin cambios.
- **Pulumi** es la mejor alternativa cuando el equipo prefiere programar: el tenant entero cabe en
  un archivo de Python, se prueba con pytest sin tocar AWS y reutiliza los mismos cloud-init.
  Costo: un runtime más en el worker y una frase secreta adicional que custodiar.
- **CloudFormation** sirve para una instalación fija (así se hizo en `anteriores/cloud_init/cloudformation`,
  donde las contraseñas las genera un script y se pasan como parámetros `NoEcho`), pero para una
  plataforma multi-tenant le faltan tres piezas que el diseño necesita: generar secretos y
  guardarlos como SSM SecureString, componer el `.env` con ellos y detener/encender instancias
  dentro de la pila. Resolverlas exige funciones Lambda personalizadas, es decir, código propio
  fuera de la plantilla. Por eso en la plataforma aparece como **no disponible**.
