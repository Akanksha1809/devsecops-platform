FROM jenkins/jenkins:lts-jdk17

USER root

# docker CLI only (no daemon) — pipeline talks to the host's Docker over the
# mounted socket (docker-outside-of-docker), so build/scan containers don't
# run nested inside Jenkins' own container.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx640m"
COPY init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/login || exit 1

# Stays root at runtime (see docs/SECURITY.md): the mounted Colima Docker
# socket is only accessible to root inside this container, and this image
# is a local single-user CI sandbox, not a multi-tenant Jenkins install.

