#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build entrypoint: packages the DNF check plugin as an MKP extension.
# Runs inside the Checkmk Docker container.
# See https://docs.checkmk.com/latest/en/mkps.html

set -euo pipefail

SOURCE=/source
CMK=/omd/sites/cmk

# Allow git operations on the mounted source directory
git config --global --add safe.directory "$SOURCE"

# mkp packages every file under the site's local hierarchy, so stage only the
# files git tracks (with their working-tree content), so untracked scratch
# files or notes in lib/ or agents/ never reach the MKP.
STAGE=$(mktemp -d)
git -C "$SOURCE" ls-files -z -- lib agents \
  | tar -C "$SOURCE" --null --ignore-failed-read -T - -cf - \
  | tar -xf - -C "$STAGE"

cd "$CMK/local"

# Copy plugin library files into the site's local hierarchy.
# The two trees must be merged separately because check_mk may be a symlink
# in the stock site layout and cp -R cannot overwrite a non-directory.
cp -R "$STAGE/lib/python3/"* ./lib/python3/
mkdir -p ./lib/check_mk/base/cee/plugins/bakery
cp "$STAGE/lib/check_mk/base/cee/plugins/bakery/dnf.py" \
   ./lib/check_mk/base/cee/plugins/bakery/dnf.py

cd share/check_mk
# Copy agent plugin
cp -R "$STAGE/agents" .

# Create the MKP manifest template (must be run as site user).
# Checkmk 2.5's cmk-mkp-tool 3.0.0 prints the template to stdout instead of
# writing a temp file, so redirect it into the manifest path ourselves. The
# redirect runs inside the site-user shell to keep the manifest free of any
# login-shell output.
MANIFEST="$CMK/tmp/check_mk/dnf.manifest.temp"
su - cmk -c "mkdir -p $CMK/tmp/check_mk && /omd/sites/cmk/bin/mkp template dnf > $MANIFEST"

# Derive the package version: the tag of a tagged commit, otherwise the
# number of commits, which only grows along main (needs the full history).
TAG=$(git -C "$SOURCE" describe --exact-match --tags HEAD 2>/dev/null || true)
SHALLOW=$(git -C "$SOURCE" rev-parse --is-shallow-repository)
if [[ -n "$TAG" ]]; then
  VERSION="${TAG#v}"
elif [[ "$SHALLOW" == "true" ]]; then
  echo "ERROR: shallow clone; the untagged version needs the full history (fetch-depth: 0)" >&2
  exit 1
else
  VERSION="0.0.$(git -C "$SOURCE" rev-list --count HEAD)"
fi
echo "Derived version: $VERSION"

# Checkmk crashes parsing non-standard versions such as 1.2.3-alpha.1
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([ipb][0-9]+)?$ ]]; then
  echo "ERROR: '$VERSION' is not a valid Checkmk version (e.g. 1.2.3, 1.2.3p1, 1.2.3i1, 1.2.3b1)" >&2
  exit 1
fi

# Inject version number and metadata into the manifest
/build-modify-extension.py "$VERSION" "$MANIFEST"

# Ensure the site user can write to plugin directories during packaging
chmod go+rw "$CMK/local/lib/check_mk/base/cee/plugins/bakery"
chmod go+rw "$CMK/local/lib/python3/cmk_addons/plugins/dnf/agent_based"
chmod go+rw "$CMK/local/lib/python3/cmk_addons/plugins/dnf/checkman"
chmod go+rw "$CMK/local/lib/python3/cmk_addons/plugins/dnf/rulesets"

# Package the MKP (must be run as site user)
su - cmk -c "/omd/sites/cmk/bin/mkp package $MANIFEST"

# Copy the built MKP back to the mounted source volume
cp "$CMK/var/check_mk/packages_local/"*.mkp "$SOURCE"

# Let the CI runner user read the created MKP file
chmod go+r "$SOURCE/"*.mkp
