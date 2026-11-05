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
# Antes:  FROM eclipse-temurin:21-jre
FROM ghcr.io/<tu-org>/newrelic-jvm-base:21

WORKDIR /app
COPY build/libs/assets.jar /app/app.jar

# El servicio define SOLO su nombre. La license key llega en runtime.
ENV NEW_RELIC_APP_NAME=assets

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
# No hace falta -javaagent: ya viene en JAVA_TOOL_OPTIONS de la imagen base.
```

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
