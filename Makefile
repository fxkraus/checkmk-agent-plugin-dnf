# SPDX-License-Identifier: GPL-2.0-only
# Makefile for the CheckMK DNF Update Plugin
# Run `make help` to see available targets.
#
# Usage:
#   make build           Build the MKP package
#   make lint            Run all linters and the secret scan (pre-commit, same as CI)
#   make secrets         Scan the full git history for secrets (gitleaks)
#   make test            Run all tests
#   make test-systemd    End-to-end test with the real agent under systemd
#   make deploy-plugin   Symlink plugin into CMK site (devcontainer)
#   make discover        Discover services on AlmaLinux host (devcontainer)
#   make clean           Remove build artifacts

.PHONY: help lint secrets format \
        test test-shell test-python test-python-docker test-systemd \
        build clean \
        deploy-plugin discover redeploy

SHELL := /bin/bash
PYTHON := python3

# Proxy build arguments (pass-through for corporate environments)
BUILD_ARGS := $(if $(HTTP_PROXY),--build-arg HTTP_PROXY=$(HTTP_PROXY) --build-arg http_proxy=$(HTTP_PROXY),) \
              $(if $(HTTPS_PROXY),--build-arg HTTPS_PROXY=$(HTTPS_PROXY) --build-arg https_proxy=$(HTTPS_PROXY),) \
              $(if $(NO_PROXY),--build-arg NO_PROXY=$(NO_PROXY) --build-arg no_proxy=$(NO_PROXY),)

# Image that provides the Checkmk agent RPM for test-systemd
CMK_IMAGE ?= docker.io/checkmk/check-mk-ultimatemt:2.5.0-latest

# Devcontainer paths (only relevant inside the CheckMK devcontainer)
WORKSPACE ?= /workspace
CMK_LOCAL ?= /omd/sites/cmk/local

# =============================================================================
# Default target
# =============================================================================

help:
	@echo "Available targets:"
	@echo ""
	@echo "  Linting & Formatting:"
	@echo "    lint           Run all pre-commit hooks: linters + secret scan (same as CI)"
	@echo "    secrets        Scan the full git history for secrets (gitleaks, Docker)"
	@echo "    format         Format and autofix Python code with ruff"
	@echo ""
	@echo "  Testing:"
	@echo "    test           Run all tests"
	@echo "    test-shell     Run BATS shell tests"
	@echo "    test-python    Run pytest Python tests (inside a Checkmk site)"
	@echo "    test-python-docker  Run pytest inside the Checkmk build image"
	@echo "    test-systemd   End-to-end test: real agent RPM under systemd (Docker)"
	@echo ""
	@echo "  Building:"
	@echo "    build          Build the MKP package (requires podman/docker)"
	@echo "    clean          Remove build artifacts"
	@echo ""
	@echo "  DevContainer (run inside the CheckMK devcontainer):"
	@echo "    deploy-plugin  Symlink plugin files into CMK site + reload"
	@echo "    discover       Discover services on AlmaLinux host"
	@echo "    redeploy       Deploy plugin + discover services"

# =============================================================================
# Linting
# =============================================================================

lint:
	@echo "==> Running pre-commit hooks (same as CI)..."
	pre-commit run --all-files

secrets:
	@echo "==> Scanning the full git history for secrets..."
	docker run --rm -v "$$PWD:/repo:ro" ghcr.io/gitleaks/gitleaks:v8.30.1 git --redact --verbose /repo

format:
	@echo "==> Formatting Python code with ruff..."
	ruff format .
	ruff check --fix .

# =============================================================================
# Testing
# =============================================================================

test: test-shell test-python

test-shell:
	@echo "==> Running BATS tests..."
	bats tests/test_agent_dnf.bats

test-python:
	@echo "==> Running pytest..."
	pytest tests/

test-python-docker:
	@echo "==> Running pytest inside the Checkmk build image..."
	docker build $(BUILD_ARGS) -t checkmk-dnf-build -f build/Dockerfile .
	REQ_DIR="$$(mktemp -d)" && \
	uv export --quiet --frozen --only-group test --no-emit-project -o "$$REQ_DIR/requirements-test.txt" && \
	docker run --rm -v "$$PWD:/source:ro" -v "$$REQ_DIR/requirements-test.txt:/requirements-test.txt:ro" \
		--entrypoint /source/tests/run-pytest.sh checkmk-dnf-build; \
	rc=$$?; rm -rf "$$REQ_DIR"; exit $$rc

test-systemd:
	@echo "==> Running the agent end-to-end under systemd..."
	RPM_DIR="$$(mktemp -d)" && \
	docker run --rm --entrypoint bash $(CMK_IMAGE) -c \
		'cat /omd/versions/default/share/check_mk/agents/check-mk-agent-*.noarch.rpm' > "$$RPM_DIR/agent.rpm" && \
	tests/systemd/test-socket-activated-agent.sh "$$RPM_DIR/agent.rpm"; \
	rc=$$?; rm -rf "$$RPM_DIR"; exit $$rc

# =============================================================================
# Building
# =============================================================================

build:
	@echo "==> Building MKP package..."
	@if command -v podman &>/dev/null; then \
		podman build --format docker $(BUILD_ARGS) -t checkmk-dnf-build -f build/Dockerfile .; \
		podman run --rm -v "$$PWD:/source:Z" checkmk-dnf-build; \
	elif command -v docker &>/dev/null; then \
		docker build $(BUILD_ARGS) -t checkmk-dnf-build -f build/Dockerfile .; \
		docker run --rm -v "$$PWD:/source" checkmk-dnf-build; \
	else \
		echo "ERROR: Neither podman nor docker found"; \
		exit 1; \
	fi

clean:
	@echo "==> Cleaning build artifacts..."
	rm -f *.mkp
	rm -rf __pycache__ .pytest_cache .mypy_cache .ruff_cache
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

# =============================================================================
# DevContainer operations (run inside the CheckMK devcontainer)
# =============================================================================

deploy-plugin:
	@echo "==> Deploying plugin into CheckMK site..."
	@bash "$(WORKSPACE)/.devcontainer/scripts/deploy-plugin.sh"

discover:
	@echo "==> Discovering services on AlmaLinux host..."
	@bash "$(WORKSPACE)/.devcontainer/scripts/discover-services.sh" almalinux-host

redeploy: deploy-plugin discover
	@echo "==> Redeploy complete."
