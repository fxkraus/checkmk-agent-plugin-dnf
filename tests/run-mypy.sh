#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Type-check the plugin modules against the Checkmk libraries with mypy.
# Intended to run inside the Checkmk image (see `make typecheck-docker`), with
# the "test" dependency group mounted like for tests/run-pytest.sh.
#
# Checkmk ships no py.typed markers, so mypy would treat its packages as
# untyped. Instead, the cmk namespace package (split between site-packages and
# lib/python3) is mirrored as symlinks into one source tree on MYPYPATH. The
# bakery plugin is placed next to bakery_api in that tree, so its relative
# import resolves. Errors inside Checkmk itself are silenced.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="/omd/versions/default/bin/python3"
CMK_SOURCES=(/omd/versions/default/lib/python3.13/site-packages/cmk /omd/versions/default/lib/python3/cmk)
WORK_DIR="$(mktemp -d)"
TYPE_PATH="${WORK_DIR}/typepath"
TEST_REQUIREMENTS="${TEST_REQUIREMENTS:-/requirements-test.txt}"

if [[ ! -f "${TEST_REQUIREMENTS}" ]]; then
    echo "ERROR: ${TEST_REQUIREMENTS} not found; export it from uv.lock (see tests/run-pytest.sh)" >&2
    exit 1
fi
"${PYTHON}" -m pip install --quiet --disable-pip-version-check --require-hashes \
    --target "${WORK_DIR}/deps" -r "${TEST_REQUIREMENTS}"

# mirror <dest> <src dirs...>: symlink the entries of all src dirs into dest.
# A directory present in several sources becomes a real directory that
# mirrors all of them.
mirror() {
    local dest="$1" src entry name
    shift
    mkdir -p "${dest}"
    for src in "$@"; do
        for entry in "${src}"/*; do
            name="${entry##*/}"
            if [[ -L "${dest}/${name}" && -d "${entry}" ]]; then
                local first
                first="$(readlink "${dest}/${name}")"
                rm "${dest}/${name}"
                mirror "${dest}/${name}" "${first}" "${entry}"
            elif [[ -d "${dest}/${name}" && -d "${entry}" ]]; then
                mirror "${dest}/${name}" "${entry}"
            elif [[ ! -e "${dest}/${name}" ]]; then
                ln -s "${entry}" "${dest}/${name}"
            fi
        done
    done
}

mirror "${TYPE_PATH}/cmk" "${CMK_SOURCES[@]}"

# Unfold cmk/base/cee/plugins/bakery into real directories and add the plugin.
bakery="cmk/base/cee/plugins/bakery"
path="${TYPE_PATH}"
for part in ${bakery//\// }; do
    path="${path}/${part}"
    if [[ -L "${path}" ]]; then
        target="$(readlink "${path}")"
        rm "${path}"
        mirror "${path}" "${target}"
    fi
done
ln -s "${REPO_DIR}/lib/check_mk/base/cee/plugins/bakery/dnf.py" "${TYPE_PATH}/${bakery}/dnf.py"

cd "${REPO_DIR}"
PYTHONPATH="${WORK_DIR}/deps" MYPYPATH="${TYPE_PATH}:${REPO_DIR}/lib/python3" \
    "${PYTHON}" -m mypy --config-file pyproject.toml --cache-dir "${WORK_DIR}/cache" \
    --follow-imports=silent \
    -m cmk_addons.plugins.dnf.agent_based.dnf \
    -m cmk_addons.plugins.dnf.rulesets.ruleset_dnf_bakery \
    -m cmk_addons.plugins.dnf.rulesets.ruleset_dnf_check_parameters \
    -m cmk.base.cee.plugins.bakery.dnf
