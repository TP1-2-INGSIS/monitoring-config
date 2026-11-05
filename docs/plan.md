# Plan de monitoreo con New Relic

New Relic cambia bastante el panorama respecto a Grafana. Este documento
replantea la arquitectura desde cero para New Relic, porque el modelo es
fundamentalmente distinto.

## El cambio de modelo: push a SaaS, no pull autohospedado

La diferencia clave con el stack de Grafana:

|                                   | Grafana + Prometheus                     | New Relic                                |
|-----------------------------------|------------------------------------------|------------------------------------------|
| Modelo                            | **Pull** — Prometheus raspa a tus servicios | **Push** — cada servicio *envía* datos a New Relic |
| Dónde viven los datos             | Autohospedado (tu Docker)                | SaaS (la nube de New Relic)              |
| Infraestructura que operás        | Prometheus + Grafana + Loki/Tempo        | **Ninguna**                              |
| Carpeta `Monitoring/` con stack   | Sí, pesada                               | Casi vacía (solo config/docs)            |
| Cómo se conecta un servicio       | Expone `/actuator/prometheus`            | Un **agente** dentro del servicio con una license key |

Con New Relic no levantás ningún contenedor de monitoreo. New Relic es la
plataforma (APM completo: métricas, trazas, logs, todo unificado) y tus
servicios le mandan datos. Esto encaja muy bien con lo que venís haciendo:
configuración por variable de entorno, igual que la connection string de Azure.

## Cómo se instrumenta un servicio Spring Boot

New Relic ofrece dos caminos. Para Spring Boot el recomendado es el **agente
Java** (APM), que instrumenta automáticamente sin tocar tu código:

### Camino A — Agente Java APM (recomendado)

- Un `.jar` del agente que se engancha al arrancar la JVM:
  `java -javaagent:newrelic.jar -jar assets.jar`.
- Captura automáticamente: latencia de endpoints HTTP, llamadas a la DB
  (JPA/Postgres), errores/excepciones, métricas de JVM, y **trazas
  distribuidas** entre servicios.
- Cero código. Se configura con dos cosas: la **license key** y el **app name**
  (para distinguir cada servicio).

### Camino B — OpenTelemetry + exporter OTLP a New Relic

- Usás `micrometer` / `opentelemetry` en el código y exportás vía OTLP al
  endpoint de New Relic.
- Más estándar y portable (no te casás con New Relic), pero más setup.

Para un TP, el **Camino A** es el más directo y el que da más valor con menos
esfuerzo.

## Qué hay que agregar — por servicio

Con el agente Java, por cada servicio (`Assets`, `Snippets`, `Language`,
`Permissions`):

1. **Descargar el agente** (`newrelic.jar` + `newrelic.yml`) — normalmente se
   mete en la imagen Docker.
2. **Modificar el `Dockerfile`** para arrancar con `-javaagent`:
   ```dockerfile
   ENTRYPOINT ["java", "-javaagent:/app/newrelic/newrelic.jar", "-jar", "/app/app.jar"]
   ```
3. **Pasar config por variables de entorno** en el `docker-compose.yml`:
   ```yaml
   environment:
     - NEW_RELIC_LICENSE_KEY=${NEW_RELIC_LICENSE_KEY}
     - NEW_RELIC_APP_NAME=assets
   ```

No hace falta tocar `build.gradle` ni el código con el camino del agente. El
`NEW_RELIC_APP_NAME` distinto por servicio es lo que te los separa en el
dashboard de New Relic.

## La arquitectura general

```
                        ┌─────────────────────────────┐
                        │   New Relic (SaaS, la nube)  │
                        │  APM · métricas · trazas ·   │
                        │  logs · dashboards · alertas │
                        └──────────────▲──────────────┘
                                       │  push (HTTPS, con license key)
          ┌────────────┬──────────────┼──────────────┬────────────┐
          │            │              │               │            │
   ┌──────────┐ ┌──────────┐  ┌──────────┐    ┌─────────────┐
   │  Assets  │ │ Snippets │  │ Language │    │ Permissions │   ← cada uno con
   │ +agente  │ │ +agente  │  │ +agente  │    │  +agente    │     newrelic.jar
   └──────────┘ └──────────┘  └──────────┘    └─────────────┘
```

Comparado con Grafana: desaparecen Prometheus, Loki, Tempo y el Grafana
autohospedado. No hay "red compartida para scrapear" ni `prometheus.yml` con la
lista de targets. Cada servicio es autónomo y habla directo con la nube de New
Relic.

## Implicancias prácticas / decisiones

1. **La carpeta `Monitoring/` cambia de rol.** Ya no aloja un stack de
   contenedores. Pasa a ser **documentación + configuración compartida**: el
   `newrelic.yml` base, un README de cómo instrumentar, y quizás definiciones de
   dashboards/alertas como código. El monitoreo real vive en la cuenta de New
   Relic.

2. **La license key es un secreto.** A diferencia de la connection string
   pública de Azurite, la license key de New Relic **no va al repo**. Se inyecta
   por variable de entorno / GitHub Actions secret, igual que la credencial de
   Azure en producción. Esto ya lo tenés resuelto como patrón.

3. **No se resuelve el problema de red entre servicios.** Con Grafana
   necesitabas que todos compartieran red Docker para el scrape. Con New Relic
   no: cada servicio solo necesita salida a internet hacia New Relic. Menos
   acoplamiento de infraestructura.

4. **Trazas distribuidas gratis.** El agente propaga automáticamente el contexto
   de traza entre servicios (Snippets → Assets → Language). En Grafana eso
   requería Tempo + instrumentación de tracing explícita.

5. **Free-tier.** New Relic tiene un free-tier conocido por ser generoso (cupo
   de ingesta de datos por mes + usuario full gratis). Como siempre, conviene
   confirmar los límites vigentes en su web antes de comprometerse, porque
   cambian.

## Esfuerzo real

Bajo, y sobre todo en infra (Dockerfile + compose), no en código:

- Por servicio: agregar el agente a la imagen + 2 variables de entorno.
  ~10 líneas.
- En `Monitoring/`: `newrelic.yml` base + README. Dashboards/alertas se arman en
  la UI de New Relic.

## Recomendación de alcance

1. Instrumentar **Assets** primero como piloto (agente Java vía Dockerfile +
   `NEW_RELIC_LICENSE_KEY`/`NEW_RELIC_APP_NAME`).
2. Verificar que aparezca en New Relic con métricas de HTTP/JPA/JVM.
3. Replicar el mismo patrón en los otros servicios.
4. Dejar en `Monitoring/` el `newrelic.yml` compartido + un README documentando
   el procedimiento.

> Pendiente de confirmar en los PDFs de la consigna: si piden el **agente APM** o
> instrumentación vía **OpenTelemetry**, y si esperan dashboards/alertas
> concretos. Eso afina qué se deja en `Monitoring/`.
