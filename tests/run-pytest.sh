#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Run the pytest suite with the Checkmk Python interpreter and libraries.
# Intended to run inside the Checkmk image (see `make test-python-docker`).
#
# The Checkmk image has no uv, so the "test" dependency group is exported from
# uv.lock beforehand, with hashes, and mounted at $TEST_REQUIREMENTS:
#   uv export --frozen --only-group test --no-emit-project -o requirements-test.txt
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="/omd/versions/default/bin/python3"
DEPS_DIR="$(mktemp -d)"
TEST_REQUIREMENTS="${TEST_REQUIREMENTS:-/requirements-test.txt}"

if [[ ! -f "${TEST_REQUIREMENTS}" ]]; then
    echo "ERROR: ${TEST_REQUIREMENTS} not found; export it from uv.lock (see the header of $0)" >&2
    exit 1
fi
"${PYTHON}" -m pip install --quiet --disable-pip-version-check --require-hashes \
    --target "${DEPS_DIR}" -r "${TEST_REQUIREMENTS}"

cd "${REPO_DIR}"
export PYTHONPATH="${DEPS_DIR}:${REPO_DIR}/lib/python3"

# Fail loudly instead of letting the test modules skip themselves
"${PYTHON}" -c "import cmk.agent_based.v2, cmk.base.cee.plugins.bakery.bakery_api.v1, cmk_addons.plugins.dnf.agent_based.dnf, cmk_addons.plugins.dnf.rulesets.ruleset_dnf_bakery"

"${PYTHON}" -m pytest -p no:cacheprovider "$@" tests/
