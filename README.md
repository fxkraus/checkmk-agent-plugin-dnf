# Checkmk Agent Plugin — DNF Update Check

> [!NOTE]
> **Credits:** This project builds on the original
> [checkmk-agent-plugin-yum](https://github.com/HenriWahl/checkmk-agent-plugin-yum)
> by **[Henri Wahl](https://github.com/HenriWahl)**, who created the plugin in
> 2015, with later contributions from Moritz Schlarb, Marco Lenhardt,
> Henrik Giessel and Timo Klecker. This fork has since changed
> a lot (Checkmk 2.5 APIs, dnf5 support, background refresh, CI/CD), but the
> idea and much of its groundwork are his. Thank you, Henri!
>
> Like the original, this project is licensed under the
> [GNU General Public License v2.0](LICENSE).

A [Checkmk](https://checkmk.com) extension package (MKP) that monitors
available package updates on RPM-based Linux distributions.

> **Checkmk ≥ 2.5.0** is required.
> This plugin uses the **Agent Based API v2**, **Rulesets API v1**, and
> **Bakery API v1**.

---

## Supported Distributions

| Distribution | Versions | Package Manager |
|---|---|---|
| Red Hat Enterprise Linux (RHEL) | 8, 9, 10 | dnf |
| AlmaLinux | 8, 9, 10 | dnf |
| Rocky Linux | 8, 9, 10 | dnf |
| Oracle Linux | 8, 9, 10 | dnf |
| CentOS Stream | 8, 9, 10 | dnf |
| Fedora | 41+ | dnf5 |

The agent plugin automatically detects the best available package manager
(`dnf5` → `dnf` → `yum`).

---

## Features

- **Update count** — reports the total number of available package updates.
- **Security update count** — reports security-classified updates separately
  (with an optional package list in the service details).
- **Reboot detection** — compares the running kernel against the latest
  installed kernel to flag pending reboots.
- **Last update age** — warns when the system has not been updated within a
  configurable number of days.
- **Never blocks the agent** — every agent run answers from a cache right away.
  When repo metadata or the installed packages change (repo `repomd.xml`, rpm
  database), a detached background run recomputes the result, capped at 5
  minutes. The first run after installing reports "running in the background"
  (UNKNOWN) until that refresh finishes. Hosts without `setsid`/`flock`
  (util-linux) refresh inline, capped at 45 s.
- **WATO rules** — fully configurable thresholds via the Checkmk GUI.
- **Agent Bakery** — deploy the agent plugin automatically, with an optional
  async execution interval.
- **Graphing** — emits `normal_updates` and `security_updates` metrics,
  rendered by Checkmk 2.5's built-in update graphs and perfometer.

---

## Installation

### From a release MKP

1. Download the latest `.mkp` file from the
   [Releases](https://github.com/fxkraus/checkmk-agent-plugin-dnf/releases)
   page.
2. Upload and install via **Setup → Maintenance → Extension packages** in the
   Checkmk GUI, or with the CLI:

   ```bash
   mkp install dnf-<version>.mkp
   ```

### Manual (development)

Copy the file tree under `lib/` into
`~/local/lib/` of your Checkmk site and the `agents/` tree into
`~/local/share/check_mk/agents/`.

---

## Configuration

### Check Parameters

**Setup → Services → Service monitoring rules → DNF Updates**

| Parameter | Description | Default |
|---|---|---|
| Normal updates | WARN / CRIT thresholds on the number of pending updates | 1 / 10 |
| Security updates | WARN / CRIT thresholds on the number of security updates | 1 / 1 |
| Reboot required | Service state when a reboot is pending | CRIT |
| Last update age | Days after which missing updates trigger an alert | 60 |
| Last update state | Service state for the "too old" condition | WARN |

### Agent Bakery

**Setup → Agents → Windows, Linux, Solaris, AIX → Agent rules → DNF Update Check (Linux)**

Deploy the agent plugin to hosts via the Agent Bakery.
Optionally configure an asynchronous execution interval (in seconds) so the
plugin runs in the background at a fixed cadence rather than on every agent
call.

---

## File Layout

```
agents/
  plugins/
    dnf                          # Bash agent plugin (deployed to monitored hosts)
lib/check_mk/base/cee/plugins/bakery/
    dnf.py                       # Bakery plugin (Agent Bakery deployment)
lib/python3/
  cmk_addons/plugins/dnf/
    agent_based/
      dnf.py                     # Server-side check plugin (Agent Based API v2)
    checkman/
      dnf                        # Checkmk manual page
    rulesets/
      ruleset_dnf_bakery.py      # WATO ruleset: bakery configuration
      ruleset_dnf_check_parameters.py  # WATO ruleset: check thresholds
pyproject.toml                   # Dev dependency groups (uv) + ruff/mypy/pytest config
uv.lock                          # Locked dev dependency versions
.pre-commit-config.yaml          # Linters + secret scan (local and CI)
.hadolint.yaml                   # Dockerfile lint configuration
build/
  build-entrypoint.sh            # Packages the MKP inside the container
  build-modify-extension.py      # Injects version + metadata into the manifest
  Dockerfile                     # Build container definition
.github/
  dependabot.yml                 # Dependabot version-update configuration
  workflows/
    ci.yml                       # Lint, secret scan, tests and MKP build
    release.yml                  # Build and publish the MKP on version tags
    dependabot-auto-merge.yml    # Auto-merge minor/patch uv + pre-commit Dependabot PRs
.devcontainer/
  docker-compose.yml             # Multi-container dev environment
  checkmk/Dockerfile             # Checkmk 2.5 Ultimate MT dev container
  almalinux/Dockerfile           # AlmaLinux 9 monitored test host
  almalinux/entrypoint.sh         # Agent install + registration automation
  scripts/post-create.sh         # Symlinks plugin into CMK site
  scripts/deploy-plugin.sh       # Redeploy plugin + reload CMK
  scripts/discover-services.sh   # Trigger service discovery via REST API
.vscode/
  tasks.json                     # VS Code task definitions
tests/
  run-pytest.sh                  # Runs pytest with the Checkmk interpreter
  test_check_dnf.py              # Python unit tests (pytest)
  test_agent_dnf.bats            # Shell tests (BATS)
  fixtures/fake-pm               # Fake dnf5/dnf/yum used by the BATS tests
```

---

## Building from Source

The build runs inside a Checkmk container to ensure the correct `mkp`
tooling is available. Both **Docker** and **Podman** are supported.

### Using Podman (recommended)

```bash
# Build the container image
podman build --format docker -t checkmk-dnf-build -f build/Dockerfile .

# Run the build (produces an MKP in the repo root)
podman run --rm -v "$PWD:/source:Z" checkmk-dnf-build
```

> **Note:** The `:Z` suffix is required on SELinux-enabled systems (RHEL,
> Fedora) to relabel the volume for container access. The `--format docker`
> flag suppresses HEALTHCHECK warnings from the base image.

### Using Docker

```bash
docker build -t checkmk-dnf-build -f build/Dockerfile .
docker run --rm -v "$PWD:/source" checkmk-dnf-build
```

### Build Output

The resulting `dnf-<version>.mkp` file is written to the repository root.

A version number is derived automatically:

- If the current commit is tagged (e.g. `v1.2.3`), the tag is used.
- Otherwise a numeric version is generated from the commit hash.

> [!WARNING]
> **The git tag must be a valid Checkmk version string** such as `1.2.3`,
> `1.2.3p1`, or `1.2.3i1`. Non-standard suffixes like `-alpha`, `-beta`, or
> `-rc1` will cause the Checkmk server to crash when parsing
> `parse_check_mk_version()`, so the build rejects them.
>
> **Good:** `v0.1.0`, `v0.1.0p1`, `v1.0.0`
> **Bad:** `v0.1.0-alpha`, `v1.0.0-beta2`

### Releasing

Push a version tag; the **Release MKP** workflow builds the MKP and publishes a
GitHub release (`iN`/`bN` tags as pre-releases):

```bash
git tag v1.2.3
git push origin v1.2.3
```

---

## Development

### DevContainer (Recommended)

The project includes a full devcontainer setup with two containers on a
shared Docker network:

| Container | Image | Purpose |
| --- | --- | --- |
| `checkmk-dnf-checkmk` | Checkmk 2.5 Ultimate MT (`2.5.0-latest`) | Checkmk server + dev environment |
| `checkmk-dnf-almalinux` | AlmaLinux 9 | Monitored RHEL-equivalent test host |

**Quick start:**

1. Open the repository in VS Code.
2. When prompted, click **Reopen in Container** (or run
   `Dev Containers: Reopen in Container` from the command palette).
3. Both containers build and start automatically. The AlmaLinux host
   registers itself with the CheckMK server, installs the agent, and
   deploys the dnf plugin.
4. Enable the [pre-commit hooks](#pre-commit-hooks) once per clone
   (`pre-commit` is preinstalled in the devcontainer, from `uv.lock`):

   ```bash
   pre-commit install
   pre-commit run --all-files   # optional: check the whole tree once
   ```

   The hooks run the linters and the gitleaks secret scan on every commit.
   If you also commit from the host, `pre-commit` must be installed there
   too (see below); otherwise the hook refuses the commit.

**Credentials:**

- **Web UI:** `http://localhost:5000/cmk/`
- **Login:** `cmkadmin` / `cmk`

**VS Code Tasks** (run via `Terminal → Run Task…`):

| Task | Description |
| --- | --- |
| Build MKP Package | Build the `.mkp` extension package |
| Deploy Plugin (Server-Side) | Symlink plugin into the CMK site and reload |
| Discover Services | Trigger service discovery on the AlmaLinux host |
| Deploy + Discover | Deploy and discover in one step |
| Run Linters / Tests | Lint and test targets from the Makefile |
| Reload CheckMK | Reload the CMK core configuration |

**Makefile DevContainer targets** (run inside the devcontainer):

```bash
make deploy-plugin   # Symlink plugin into CMK site + reload
make discover        # Discover services on AlmaLinux host
make redeploy        # Deploy + discover in one step
```

> **Note:** The devcontainer and the build image use the
> `checkmk/check-mk-ultimatemt` Docker image, a commercial Checkmk edition.
> Review the [Checkmk licensing terms](https://checkmk.com/pricing) before use.

### Prerequisites (local development without devcontainer)

Install development tools:

```bash
# RHEL/Fedora
dnf install bats

# Debian/Ubuntu
apt install bats

# uv: https://docs.astral.sh/uv/getting-started/installation/
```

Python dev dependencies (pytest, ruff, mypy, pre-commit, …) are declared in
`pyproject.toml` and pinned in `uv.lock`. Create the local `.venv` and enable
the hooks in your clone before the first commit:

```bash
uv sync                      # installs the locked dev dependencies into .venv
uv run pre-commit install
```

Run tools through `uv run` (e.g. `uv run make lint`) or activate the
environment with `source .venv/bin/activate`. After changing dependencies in
`pyproject.toml`, run `uv lock` and commit `uv.lock`; CI fails if it is out
of date.

### Pre-commit Hooks

All linters and the secret scan are defined in `.pre-commit-config.yaml`.
CI runs exactly the same hooks, so a clean local run means a clean CI run.

| Hook | Checks |
|---|---|
| gitleaks, detect-private-key | secrets and private keys in staged changes |
| ruff (check + format) | Python lint and formatting |
| mypy | type checks for the build script |
| shellcheck | shell scripts, including the agent plugin |
| hadolint | Dockerfiles (`.hadolint.yaml`) |
| actionlint | GitHub Actions workflows |
| pre-commit-hooks | YAML/TOML/JSON syntax, large files, merge conflicts, whitespace, shebangs |

Enable the hooks once per clone, so every commit is checked before it is
created and commits containing secrets are blocked:

```bash
pre-commit install
```

Run all hooks against the whole repository:

```bash
make lint            # = pre-commit run --all-files
make secrets         # full git history scan with gitleaks (Docker)
```

### Makefile Targets

```bash
make lint         # Run all pre-commit hooks (linters + secret scan)
make secrets      # Scan the full git history for secrets
make format       # Auto-format Python code
make test         # Run all tests
make build        # Build the MKP package
make clean        # Remove build artifacts
```

### Testing

**Shell Tests (BATS):**

```bash
bats tests/test_agent_dnf.bats
```

The package-manager parsing tests use a fake `dnf5`/`dnf`
([`tests/fixtures/fake-pm`](tests/fixtures/fake-pm)) and run on any Linux host.
The tests against the real package manager need `dnf`/`dnf5` with a populated
metadata cache. One test upgrades a real package and only runs with
`DNF_AGENT_TEST_ALLOW_UPGRADE=1`, so run it in a throwaway container:

```bash
docker run --rm -v "$PWD:/code:ro" -w /code -e DNF_AGENT_TEST_ALLOW_UPGRADE=1 \
  fedora:42 bash -c 'dnf -y -q install bats && dnf -q makecache && bats tests/test_agent_dnf.bats'
```

CI runs this suite on AlmaLinux 8, 9 and 10 (dnf) and Fedora 42 (dnf5).

**Python Unit Tests:**

The check plugin needs the Checkmk libraries. Run them inside the Checkmk
build image (no local Checkmk required):

```bash
make test-python-docker
```

Inside the devcontainer or a Checkmk site, `pytest tests/` works directly.

### CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push to `main`, pull requests | pre-commit lint, gitleaks secret scan, BATS on AlmaLinux 8/9/10 and Fedora 42, pytest against Checkmk 2.5, MKP build |
| `release.yml` | tag `vX.Y.Z` (optionally `pN`, `iN`, `bN` suffix) | builds the MKP and publishes a GitHub release (`iN`/`bN` as pre-release) |
| `dependabot-auto-merge.yml` | Dependabot pull requests | enables auto-merge for minor/patch uv and pre-commit updates (public repository only) |

Every commit on `main` produces an MKP, attached to the CI run as the
artifact `dnf-mkp-<commit-sha>` (kept 90 days, version `0.0.<n>`
derived from the commit hash). Tagged releases get a proper version.

Dependabot minor and patch updates of the uv and pre-commit ecosystems are
merged automatically once all required checks pass. Docker image and GitHub
Actions updates, and all major updates, always need a manual review. The
Checkmk images use the floating `2.5.0-latest` tag and are not managed by
Dependabot (see the note in `.github/dependabot.yml`).

Auto-merge relies on two repository settings; without them, the workflow would
merge immediately, before CI has finished:

1. **Settings → General → Allow auto-merge** enabled.
2. A branch ruleset on `main` requiring the status checks `lint`, `secrets`,
   `bats (almalinux:8)`, `bats (almalinux:9)`, `bats (almalinux:10)`,
   `bats (fedora:42)`, `pytest (Checkmk 2.5)` and `mkp`.

---

## Upstream

Based on [HenriWahl/checkmk-agent-plugin-yum](https://github.com/HenriWahl/checkmk-agent-plugin-yum)
(GPL-2.0). This repository starts from a fresh history and does not share
commits with upstream; the copyright headers in `agents/plugins/dnf` and
`lib/python3/cmk_addons/plugins/dnf/agent_based/dnf.py` record the original
authors.

---

## License

[GPL-2.0](LICENSE), the same license as the
[original project](https://github.com/HenriWahl/checkmk-agent-plugin-yum) by
Henri Wahl.
