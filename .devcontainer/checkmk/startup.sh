#!/bin/bash
# Start the OMD site and then exec the container's main command.
# This runs as root; the devcontainer 'containerUser' handles the VS Code shell.

omd start cmk 2>/dev/null || true

exec "$@"
