# Monitoring — imagen base de New Relic (Java APM)

Este repositorio **no levanta ningún stack de monitoreo**. Con New Relic el
modelo es *push a SaaS*: cada servicio lleva adentro un **agente Java APM** que
envía métricas, trazas y logs a la nube de New Relic.

Lo que vive acá es el **template compartido**: una **imagen Docker base** que ya
trae el agente instalado y configurado, más el `newrelic.yml` baseline. El resto
de los servicios (`Assets`, `Snippets`, `Language`, `Permissions`) la
**importan con `FROM`** y quedan monitoreados sin tocar su código.

```
                        ┌─────────────────────────────┐
                        │   New Relic (SaaS, la nube)  │
                        │  APM · métricas · trazas ·   │
                        │  logs · dashboards · alertas │
                        └──────────────▲──────────────┘
                                       │  push (HTTPS, con license key)
          ┌────────────┬──────────────┼──────────────┬────────────┐
   ┌──────────┐ ┌──────────┐  ┌──────────┐    ┌─────────────┐
   │  Assets  │ │ Snippets │  │ Language │    │ Permissions │
   └──────────┘ └──────────┘  └──────────┘    └─────────────┘
          └──── todos hacen FROM newrelic-jvm-base ────┘
```

## Qué hay en este repo

| Archivo         | Rol                                                                 |
|-----------------|---------------------------------------------------------------------|
| `Dockerfile`    | Construye la imagen base compartida con el agente ya enganchado.    |
| `newrelic.yml`  | Configuración baseline del agente (común a todos los servicios).    |
| `.env.example`  | Plantilla de las variables de entorno (la license key es secreta).  |
| `.github/workflows/cd.yml` | CD: publica la imagen base a GHCR.                       |
| `alerts/`       | Alertas de New Relic como código (Terraform).                       |
| `docs/plan.md`  | Decisión de arquitectura (por qué New Relic y no Grafana).          |

## Cómo funciona

La imagen base usa dos mecanismos para que cualquier servicio derivado quede
instrumentado **sin cambiar su código ni su `ENTRYPOINT`**:

1. Copia `newrelic.jar` a `/opt/newrelic/` dentro de la imagen.
2. Define `JAVA_TOOL_OPTIONS=-javaagent:/opt/newrelic/newrelic.jar`. La JVM lee
   esa variable al arrancar y carga el agente automáticamente, sea cual sea el
   comando con el que se inicie el servicio.

La config que **varía por servicio o es secreta** se pasa por variable de
entorno, que siempre gana sobre el `newrelic.yml`:

| Variable                 | Qué es                                            | Dónde se setea              |
|--------------------------|---------------------------------------------------|-----------------------------|
| `NEW_RELIC_LICENSE_KEY`  | Secreto de la cuenta New Relic                    | Runtime / secret de CI      |
| `NEW_RELIC_APP_NAME`     | Nombre del servicio en la UI (distinto por micro) | Dockerfile/compose del micro|
| `NEW_RELIC_ENVIRONMENT`  | `production` / `staging` / ...                    | Runtime (opcional)          |

## Construir y publicar la imagen base

```bash
# Build local
docker build -t newrelic-jvm-base:21 .

# Publicar al registry para que los otros repos la puedan importar
docker tag newrelic-jvm-base:21 ghcr.io/<tu-org>/newrelic-jvm-base:21
docker push ghcr.io/<tu-org>/newrelic-jvm-base:21
```

> Para builds reproducibles, fijá la versión del agente en lugar de `current`:
> `docker build --build-arg NEW_RELIC_AGENT_VERSION=8.25.0 -t newrelic-jvm-base:21 .`

## Cómo instrumentar un servicio (lo que hace cada repo)

En el `Dockerfile` del servicio, cambiá la imagen base por la nuestra:

```dockerfile
# ---- Build stage ---- NO se toca: necesita JDK para compilar.
FROM eclipse-temurin:21-jdk AS build
# ... (build del servicio, sin cambios)

# ---- Run stage ---- SOLO acá va la imagen base de Monitoring.
# Antes:  FROM eclipse-temurin:21-jre
FROM ghcr.io/tp1-2-ingsis/monitoring-config:latest
WORKDIR /app
COPY --from=build /workspace/build/libs/*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
# No hace falta -javaagent: ya viene en JAVA_TOOL_OPTIONS de la imagen base.
```

> **Error común:** si cambiás también el `FROM` del *build stage*, Gradle falla
> con `Cannot find a Java installation ... languageVersion=21`. La imagen base
> es un **JRE** (no tiene compilador). El agente solo debe ir en el run stage.

Y en el `docker-compose.yml`:

```yaml
services:
  assets:
    build: .
    environment:
      - NEW_RELIC_LICENSE_KEY=${NEW_RELIC_LICENSE_KEY}  # desde .env / secret
      - NEW_RELIC_APP_NAME=assets
```

Eso es todo: ~3 líneas por servicio, cero cambios de código.

## Verificar que funciona

1. Arrancá el servicio y mandale **al menos dos requests**.
2. Esperá 2–3 minutos.
3. Debería aparecer en New Relic → **APM & services** con el nombre de
   `NEW_RELIC_APP_NAME`, mostrando latencia HTTP, consultas JPA/Postgres,
   errores y métricas de JVM.

Si no aparece nada tras cinco minutos, revisá los logs del contenedor (el agente
escribe a STDOUT) y confirmá que la license key llegó.

## Publicar la imagen (CD)

El workflow `.github/workflows/cd.yml` publica la imagen base a GHCR, siguiendo
el mismo patrón que el CD de `Assets`:

- Se dispara en push a `main`, en tags `v*`, o manualmente (`workflow_dispatch`).
- Login a GHCR con el `GITHUB_TOKEN` del repo.
- `docker/build-push-action` construye y pushea.
- Tags: siempre `:latest`; si el push es un tag `vX.Y.Z`, también publica `:X.Y.Z`
  para que los servicios puedan fijar una versión concreta.

No hay pasos de Gradle/`bootJar` como en Assets: este repo solo construye la
imagen base, no compila una app.

## Alertas (New Relic como código, opcional)

> Para el piloto las alertas se crearon **a mano en la UI** (ver el
> procedimiento de arriba). Esta sección es la alternativa como código con
> Terraform, con las mismas queries. El HCL **no fue validado** con
> `terraform validate`.

El TP pide **al menos 3 alertas**. Definidas con Terraform en `alerts/main.tf`,
sobre métricas que el agente APM ya reporta:

1. **Exceso de respuestas 5xx** — conteo absoluto de transacciones con status
   `5xx`. Se dispara al superar `fivexx_threshold` (la "X", por defecto 5) en 5
   minutos.
2. **Error rate (%) alto** — proporción de transacciones con error sobre el
   total. Capta degradación con cualquier volumen de tráfico.
3. **Latencia p95 alta** — el p95 de la duración de las transacciones web supera
   el umbral (por defecto 2s). Detecta lentitud aunque los status sean 200.

Aplicarlas (una policy por servicio, pasando su `app_name`):

```bash
cd alerts
export TF_VAR_account_id=1234567
export TF_VAR_api_key=NRAK-xxxx        # User API key, NO la license key
terraform init
terraform apply -var 'app_name=assets'
```

Los umbrales son variables (`fivexx_threshold`, `error_rate_threshold_pct`), así
que se ajustan sin tocar el código. Ver `alerts/terraform.tfvars.example`.

## Procedimiento: monitorear un servicio nuevo (paso a paso)

Probado con `Assets` como piloto. Repetir para `Snippets`, `Language` y
`Permissions` cambiando el nombre del servicio.

### 1. Cuenta y license key (una sola vez)

1. Crear la cuenta en New Relic (free tier) y anotar la **región** (US o EU).
2. Ir a *API keys* y copiar la key de tipo **"INGEST - LICENSE"** (no la
   `NRAK-...` de usuario, que es solo para Terraform/NerdGraph).
3. Si la cuenta es **EU**, agregar `NEW_RELIC_HOST=collector.eu01.nr-data.net`.

### 2. Instrumentar el servicio

1. `FROM` del **run stage** apuntando a la imagen base (ver sección anterior).
2. Crear `.env` en el repo del servicio (gitignorado) con:
   ```
   NEW_RELIC_LICENSE_KEY=<license key de ingesta>
   NEW_RELIC_APP_NAME=<nombre del servicio, único>
   ```
3. En su `docker-compose.yml`, servicio de la app:
   ```yaml
   environment:
     - NEW_RELIC_LICENSE_KEY=${NEW_RELIC_LICENSE_KEY}
     - NEW_RELIC_APP_NAME=<nombre del servicio>
   ```
4. `docker compose up -d --build`.

### 3. Verificar que reporta

```bash
docker compose logs -f <servicio> | grep -i newrelic
```

- Correcto: el agente conecta y deja de reintentar.
- `license_key is empty`: la variable no llegó al contenedor. Revisar `.env` y
  `docker compose config | grep NEW_RELIC`.
- `LicenseException` y `reconnecting` en bucle: la key es inválida o del tipo
  equivocado (debe ser la de ingesta, ~40 caracteres) o la cuenta es EU.

Mandar al menos 2 requests y esperar 2–3 minutos: el servicio aparece en
*APM & services*.

### 4. Crear las alertas en la UI

*Alerts → Alert conditions → New alert condition → NRQL*. Crear una **policy**
`<servicio> - alertas` y en ella estas condiciones. Reemplazar `assets` por el
`NEW_RELIC_APP_NAME` del servicio.

| # | Condición | Query NRQL | Umbral |
|---|-----------|------------|--------|
| 1 | Exceso de 5xx | `SELECT count(*) FROM Transaction WHERE appName = 'assets' AND httpResponseCode LIKE '5%'` | `above 5` por 5 min |
| 2 | Error rate alto | `SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName = 'assets'` | `above 5` (%) por 5 min |
| 3 | Latencia p95 alta | `SELECT percentile(duration, 95) FROM Transaction WHERE appName = 'assets' AND transactionType = 'Web'` | `above 2` (s) por 5 min |
| 4 | Servicio caído | `SELECT count(*) FROM Transaction WHERE appName = 'assets'` | ver abajo |

**Condición 4 (servicio caído / pérdida de señal).** Sin ella, apagar el
servicio no dispara nada: el modelo es *push*, y sin tráfico no hay errores ni
latencia que superen un umbral. En *Condition settings → Signal loss* activar
*Open a new incident when a signal is lost* con un tiempo de **5 minutos**.
Las alertas 1–3 solo evalúan datos que llegan **después** de crearlas.

### 5. Probar que las alertas funcionan

Con las condiciones ya creadas, provocar 5xx reales sin tocar código. En
`Assets`, `POST /v1/assets/{id}` falla si Azurite está apagado:

```bash
docker compose stop azurite

# En paralelo: cada request espera ~30–60 s por los reintentos del SDK de Azure
# antes de devolver 500, así que de a uno no se acumulan dentro de la ventana.
for i in (seq 1 12)        # fish; en bash: for i in $(seq 1 12); do ... & done
  curl -s -o /dev/null --max-time 600 -w "status=%{http_code} tiempo=%{time_total}s\n" \
    -X POST -H "Content-Type: text/plain" --data hola \
    http://localhost:8080/v1/assets/(uuidgen) &
end
wait

docker compose start azurite   # al terminar
```

Esperado: los 12 devuelven `500` con un spike de latencia. En New Relic:

- *APM → servicio → Summary / Errors*: sube el tiempo de respuesta y el error rate.
- *Query your data*:
  `SELECT count(*) FROM Transaction WHERE appName = 'assets' AND httpResponseCode LIKE '5%' SINCE 30 minutes ago TIMESERIES`
- *Alerts → Issues & activity*: aparece el incidente de la alerta 1 (y la 3 si
  el p95 supera 2 s).

Para probar la alerta 4, bajar el servicio (`docker compose stop <servicio>`) y
esperar más que el tiempo de pérdida de señal.

### Qué esperar al bajar, levantar o redeployar

- Un servicio apagado **no se muestra como error**: simplemente dejan de llegar
  datos y la app queda sin reportar. Solo la condición 4 lo detecta.
- Al levantarlo de nuevo, el agente se reconecta solo con el mismo
  `NEW_RELIC_APP_NAME`: los datos siguen en la misma app, sin duplicados.
- El hostname es el ID del contenedor, así que cada recreate aparece como una
  instancia nueva y la anterior queda sin datos.
- El arranque de la JVM muestra unos segundos de latencia alta; New Relic no
  registra los deploys automáticamente.

## Notas de seguridad
- La **license key nunca va al repo**. Vive en `.env` (gitignorado) en local y
  como *secret* del pipeline en CI/CD.
- `record_sql` está en `obfuscated` en el `newrelic.yml`: no se envían valores
  crudos de las consultas.

## Referencias

- [Instalar el agente Java en Docker](https://docs.newrelic.com/docs/apm/agents/java-agent/additional-installation/install-new-relic-java-agent-docker/)
- [Configuración del agente Java](https://docs.newrelic.com/docs/apm/agents/java-agent/configuration/java-agent-configuration-config-file/)

_El contenido de las referencias de New Relic fue reformulado por cumplimiento de licencias._
# monitoring-config
