# Literal tag (no ARG) so Dependabot can detect and bump it
FROM ghcr.io/astral-sh/uv:0.12.18 AS uv

# Latest Checkmk 2.5 patch release, same as build/Dockerfile. The tag floats on
# purpose; rebuild the devcontainer to pick up a new patch release.
FROM docker.io/checkmk/check-mk-ultimatemt:2.5.0-latest

RUN /docker-entrypoint.sh /bin/true

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends \
       gcc vim sudo less curl git jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN echo "cmk ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cmk \
    && chmod 440 /etc/sudoers.d/cmk

# Dev dependencies from uv.lock (with hashes), installed into the site's Python
COPY pyproject.toml uv.lock /tmp/deps/
RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv \
    uv export --project /tmp/deps --frozen --only-group dev --no-emit-project \
       --output-file /tmp/requirements.txt \
    && PATH="/omd/sites/cmk/bin:${PATH}" \
       OMD_ROOT="/omd/sites/cmk" \
       /omd/sites/cmk/bin/pip3 install -r /tmp/requirements.txt

COPY .devcontainer/checkmk/startup.sh /startup.sh
RUN chmod +x /startup.sh

ENTRYPOINT ["/startup.sh"]
CMD ["sleep", "infinity"]
