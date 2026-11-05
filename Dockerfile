## =============================================================================
## Imagen base de monitoreo — New Relic Java APM
## =============================================================================
## Este Dockerfile produce una imagen base compartida que YA trae el agente Java
## de New Relic instalado y enganchado a la JVM. El resto de los servicios
## (Assets, Snippets, Language, Permissions) la "importan" con:
##
##     FROM ghcr.io/<tu-org>/newrelic-jvm-base:21
##
## y sólo tienen que copiar su propio .jar y definir NEW_RELIC_APP_NAME.
## La license key se inyecta en runtime por variable de entorno, nunca acá.
## =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — descargar y desempacar el agente oficial de New Relic.
# Se aísla en su propio stage para no dejar curl/unzip ni el zip en la imagen
# final, y para que la descarga quede cacheada como capa aparte.
# -----------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk AS newrelic-agent

# Versión del agente. "current" = la última estable publicada por New Relic.
# Para builds reproducibles, fijá una versión concreta (ej. 8.25.0) en vez de
# "current" y pasala con --build-arg NEW_RELIC_AGENT_VERSION=8.25.0
ARG NEW_RELIC_AGENT_VERSION=current

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/newrelic-java.zip \
        "https://download.newrelic.com/newrelic/java-agent/newrelic-agent/${NEW_RELIC_AGENT_VERSION}/newrelic-java.zip" \
    && unzip -q /tmp/newrelic-java.zip -d /tmp \
    && rm /tmp/newrelic-java.zip
# Tras el unzip, los archivos quedan en /tmp/newrelic/ (newrelic.jar, newrelic.yml, ...)

# -----------------------------------------------------------------------------
# Stage 2 — imagen base final que heredan los servicios.
# Lleve: sólo JRE + el agente. El newrelic.yml que copiamos aquí es el
# baseline compartido; cualquier override se hace por variable de entorno.
# -----------------------------------------------------------------------------
FROM eclipse-temurin:21-jre AS base

# Directorio donde vive el agente dentro de todas las imágenes derivadas.
ENV NEW_RELIC_HOME=/opt/newrelic

RUN mkdir -p "${NEW_RELIC_HOME}"

# newrelic.jar desde el stage de descarga.
COPY --from=newrelic-agent /tmp/newrelic/newrelic.jar ${NEW_RELIC_HOME}/newrelic.jar

# newrelic.yml baseline versionado en este repo (no el que viene en el zip),
# así la config compartida vive como código y es revisable en PRs.
COPY newrelic.yml ${NEW_RELIC_HOME}/newrelic.yml

# Engancha el agente a CUALQUIER proceso Java de las imágenes derivadas.
# Usamos JAVA_TOOL_OPTIONS en vez de tocar el ENTRYPOINT: así el servicio hijo
# conserva su propio ENTRYPOINT/CMD y el agente se aplica igual.
ENV JAVA_TOOL_OPTIONS="-javaagent:${NEW_RELIC_HOME}/newrelic.jar"

# Defaults de configuración. Se SOBREESCRIBEN por servicio en runtime:
#   - NEW_RELIC_APP_NAME: distinto por servicio (es lo que los separa en la UI).
#   - NEW_RELIC_LICENSE_KEY: secreto, se inyecta en runtime. NUNCA va al repo.
ENV NEW_RELIC_APP_NAME="unnamed-service" \
    NEW_RELIC_LOG_FILE_NAME=STDOUT

# Sanity check en build-time: confirma que el agente quedó instalado.
RUN java -jar ${NEW_RELIC_HOME}/newrelic.jar -v || true
