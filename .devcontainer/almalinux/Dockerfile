# AlmaLinux 9 — Monitored Test Host
# Serves as a CheckMK agent target for testing the DNF update plugin.
# On startup, the entrypoint downloads the agent from the CheckMK server,
# registers with the site, and starts the agent controller daemon.
FROM docker.io/almalinux:9.8

# Install packages needed by the CheckMK agent and the dnf plugin
# --allowerasing: AlmaLinux 9 ships curl-minimal which conflicts with curl
RUN dnf -y --allowerasing install \
      curl \
      procps-ng \
      hostname \
      iproute \
      rpm \
      dnf \
      sudo \
      openssl \
      which \
      findutils \
    && dnf clean all

# Create directories used by the CheckMK agent
RUN mkdir -p /usr/lib/check_mk_agent/plugins \
             /usr/lib/check_mk_agent/local \
             /var/lib/check_mk_agent/cache

# Copy and enable the entrypoint script
COPY .devcontainer/almalinux/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
