# Guion de la demostración (entregable 8 · criterios mínimos de aceptación)

Preparación previa (ver [OPERACIONES.md](OPERACIONES.md) §0): bootstrap, monitoreo, plataforma,
worker y frontend encendidos. Ideal: AMI de Packer, para que cada tenant esté listo en 1–3 min.
Crear los tenants **antes** de la presentación ahorra la espera.

| # | Criterio | Qué mostrar | Dónde |
|---|---|---|---|
| 1 | Crear tenants con distintos planes | Crear `colegio-a` (Básico, Terraform) y `colegio-b` (Estándar, Pulumi u OpenTofu). Mostrar el progreso en vivo y las versiones registradas | *Nuevo tenant* → operación |
| 2 | Frontend, backend y base por tenant | Abrir la URL de cada uno, entrar como admin del tenant, importar un módulo (Excel de `asistencia_backend/ejemplos`) | Detalle del tenant → *Servicios* |
| 3 | Cambiar el plan y explicar el efecto | `colegio-a`: Básico → Estándar. Mostrar la tabla *Qué cambiará* y el aviso de reinicio; confirmar | *Cambiar plan* |
| 4 | Suspender y reanudar conservando datos | Suspender `colegio-a` (respaldo automático + servidores detenidos; la URL no responde). Reanudar: la URL vuelve con los mismos módulos | Detalle → *Suspender* / *Reanudar* |
| 5 | Respaldar y restaurar | *Respaldar ahora* → eliminar un módulo en la app → *Restaurar* ese respaldo → el módulo vuelve | Detalle → *Respaldos* |
| 6 | Salud en Grafana + alerta de ejemplo | Tablero filtrado por tenant (disponibilidad, CPU, memoria, latencia, errores, base). Detener el backend (`sudo systemctl stop asistencia` por Session Manager): en ~3 min aparece *La aplicación no responde* en Grafana y en *Alertas* de la plataforma; encenderlo y verla resuelta | Detalle → *Ver en Grafana*; *Alertas* |
| 7 | Un tenant no puede ver los datos de otro | `manage.py probar_aislamiento colegio-a:dev colegio-b:dev --salida docs/evidencia-aislamiento.md` y mostrar el informe (11 pruebas: red, secretos, respaldos, tokens). Además: el admin de `colegio-b` en la plataforma no ve a `colegio-a` | Terminal + informe |
| 8 | Historial de una operación fallida y reintento | Fallo controlado (abajo): mostrar en *Operaciones* la operación **Fallida**, su mensaje comprensible, el log sin secretos y quién/cuándo; corregir la causa y **Reintentar** → nueva operación enlazada, *Exitosa* | *Operaciones* → detalle |

## Fallo controlado para el criterio 8
*Reintentar* repite la operación con **los mismos parámetros**, así que el fallo debe venir del
entorno, no de los datos:
1. Detener el worker, quitar `IAC_BUCKET_RESPALDOS` del `.env` y volver a encenderlo.
2. *Respaldar ahora* → falla con "No hay bucket de respaldos configurado…". El tenant sigue
   *Activo* (no se tocó la infraestructura).
3. Restaurar la variable, reiniciar el worker y **Reintentar** → *Exitosa*.

Otro ejemplo visible en el historial: *Actualizar* a una rama que no existe falla en el despliegue
(`git fetch`); se corrige con una nueva actualización a una versión válida.

## Al terminar
Eliminar `colegio-a` y `colegio-b` (con respaldo final) y `terraform destroy` del monitoreo.
