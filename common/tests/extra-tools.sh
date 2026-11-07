#!/usr/bin/env bash
set -Eeuo pipefail

source "${BASH_SOURCE[0]%/*}/../init.sh"

for dependency in jq uv python3 node npm; do
  command -v "$dependency" >/dev/null || { printf 'Missing test dependency: %s\n' "$dependency" >&2; exit 1; }
done

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export EXTRA_TOOLS_ROOT="$test_root/shared"
export PYTHON_PACKAGES_ROOT="$test_root/pythonlib" UV_ENVIRONMENTS_ROOT="$test_root/uvenvs"
export TOOLS_UPDATE_INTERVAL=86400 TOOLS_INSTALL_MODE=update
export PYTHON_PACKAGES=''
test_python="$(type -P python3)"
mkdir -p "$test_root/fixtures"
: >"$test_root/downloads"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
download_count() { wc -l <"$test_root/downloads" | tr -d ' '; }
use_profile() { test_profile="$test_root/$1"; }
# Simulate separate containers without exposing another user-facing setting.
extra_tools_profile_directory() { printf '%s\n' "$test_profile"; }
go_version() { "$test_root/$1/bin/go" version; }

# Defaults follow the actual HOME, including non-node users and paths with spaces.
# shellcheck disable=SC2016
defaults="$(env -u AGENT_CLI_ROOT -u EXTRA_TOOLS_ROOT -u PYTHON_PACKAGES_ROOT -u UV_ENVIRONMENTS_ROOT HOME="$test_root/other user" \
  bash -c 'source "$1"; agent_cli_root; extra_tools_root; python_packages_root; uv_environments_root' \
  bash "${BASH_SOURCE[0]%/*}/../extra-tools/paths.sh")"
assert_equal "$defaults" "$(printf '%s\n' "$test_root/other user/agent-cli" "$test_root/other user/extra-tools" "$test_root/other user/pythonlib" "$test_root/other user/uvenvs")"
# shellcheck disable=SC2016
env PATH="$test_root/no-binaries" /bin/bash -c '
  source "$1"
  test_profile="$2"
  extra_tools_profile_directory() { printf "%s\n" "$test_profile"; }
  common_python_publish_uv
  [[ ! -e "$test_profile/bin/uv" ]]
' bash "${BASH_SOURCE[0]%/*}/../python.sh" "$test_root/no-uv" || fail 'created uv without an installed executable'

# Local release archives exercise the real extraction, selection and publication code.
for version in 1.25.3 1.26.1 1.27.0; do
  directory="$test_root/fixtures/$version/go/bin"
  mkdir -p "$directory"
  printf '#!/bin/sh\nprintf "go version go%s linux/amd64\\n"\n' "$version" >"$directory/go"
  printf '#!/bin/sh\nprintf "%s\\n"\n' "$version" >"$directory/gofmt"
  chmod +x "$directory/"*
  tar -czf "$test_root/fixtures/$version.tar.gz" -C "${directory%/go/bin}" go
done

extra_tools_fetch() {
  [[ "${test_metadata_fail:-0}" == 0 ]] || return 1
  local version hash
  for version in 1.25.3 1.26.1 1.27.0; do
    hash="$(sha256sum "$test_root/fixtures/$version.tar.gz")"
    jq -n --arg version "go$version" --arg hash "${hash%% *}" \
      '{version:$version, stable:true, files:[{os:"linux",arch:"amd64",kind:"archive",filename:($version+".tar.gz"),sha256:$hash},{os:"linux",arch:"arm64",kind:"archive",filename:($version+".tar.gz"),sha256:$hash}]}'
  done | jq -s .
}

extra_tools_download() {
  local version="${1##*/}"
  version="${version#go}"
  [[ "${test_download_fail:-0}" == 0 ]] || return 1
  # Make overlapping initializations contend for the shared installation lock.
  sleep 0.1
  cp -- "$test_root/fixtures/$version" "$2"
  printf '%s  %s\n' "$3" "$2" | "${4}sum" -c - >/dev/null
  printf '%s\n' "$version" >>"$test_root/downloads"
}

extra_tools_detect_system() {
  [[ "$1" == python ]] || return 1
  EXTRA_TOOLS_INTERNAL_SYSTEM_BINARY="$test_python"
  EXTRA_TOOLS_INTERNAL_SYSTEM_VERSION="$(extra_tools_version python "$test_python")"
}

use_profile a
export EXTRA_TOOLS=go@1.25.3
extra_tools_initialize
assert_equal "$(go_version a)" 'go version go1.25.3 linux/amd64'
old_release="$(readlink -f "$test_root/a/go/current")"

use_profile b
export EXTRA_TOOLS=go@1.26.1
extra_tools_initialize
assert_equal "$(go_version b)" 'go version go1.26.1 linux/amd64'
assert_equal "$(go_version a)" 'go version go1.25.3 linux/amd64'
assert_equal "$(download_count)" 2

# A fresh container reuses the full pinned version without querying upstream.
use_profile c
export EXTRA_TOOLS=go@1.25.3
test_metadata_fail=1
extra_tools_initialize
assert_equal "$(readlink -f "$test_root/c/go/current")" "$old_release"
assert_equal "$(download_count)" 2

# Pre-existing caches without metadata are adopted without moving their files.
rm "$old_release/.version"
use_profile legacy
extra_tools_initialize
assert_equal "$(readlink -f "$test_root/legacy/go/current")" "$old_release"
test_metadata_fail=0

# Reinstalling the same version never deletes another container's release.
use_profile a
export TOOLS_INSTALL_MODE=overwrite
extra_tools_initialize
[[ "$(readlink -f "$test_root/a/go/current")" != "$old_release" ]] || fail 'overwrite reused the old installation'
[[ -d "$old_release" ]] || fail 'overwrite removed an active shared release'
assert_equal "$(go_version c)" 'go version go1.25.3 linux/amd64'
assert_equal "$(download_count)" 3

# A failed replacement leaves the selected version runnable.
replacement="$(readlink -f "$test_root/a/go/current")"
test_download_fail=1
extra_tools_initialize
assert_equal "$(readlink -f "$test_root/a/go/current")" "$replacement"
assert_equal "$(go_version a)" 'go version go1.25.3 linux/amd64'
test_download_fail=0
export TOOLS_INSTALL_MODE=update

# Two containers racing to install one new version download it only once.
# A killed installer can leave an executable without completing the release.
mkdir -p "$EXTRA_TOOLS_ROOT/go/releases/1.27.0.interrupted/bin"
cp "$test_root/fixtures/1.27.0/go/bin/go" "$EXTRA_TOOLS_ROOT/go/releases/1.27.0.interrupted/bin/go"
touch "$EXTRA_TOOLS_ROOT/go/releases/1.27.0.interrupted/.installing"
export EXTRA_TOOLS=go@1.27.0
(use_profile concurrent-a; extra_tools_initialize) &
first_pid=$!
(use_profile concurrent-b; extra_tools_initialize) &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
assert_equal "$(download_count)" 4
assert_equal "$(readlink -f "$test_root/concurrent-a/go/current")" "$(readlink -f "$test_root/concurrent-b/go/current")"

# Range selection works offline and does not pick a different minor version.
test_metadata_fail=1
use_profile offline
export EXTRA_TOOLS=go@1.25
extra_tools_initialize
assert_equal "$(go_version offline)" 'go version go1.25.3 linux/amd64'
assert_equal "$(go_version b)" 'go version go1.26.1 linux/amd64'
assert_equal "$(download_count)" 4
test_metadata_fail=0

# Verify the public command entry point, not only the version symlinks.
assert_equal "$(PATH="$test_root/b/bin:$PATH" gofmt)" 1.26.1
assert_equal "$(jq -r .go.version "$test_root/a/extra-tools-state.json")" go1.25.3
assert_equal "$(jq -r .go.version "$test_root/b/extra-tools-state.json")" go1.26.1

# Build two dependency-free wheels locally, so Python isolation tests need no registry.
"$test_python" - "$test_root/fixtures" <<'PY'
import base64, csv, hashlib, io, pathlib, sys, zipfile
for version in ['1.0.0', '2.0.0']:
    dist = f'shared_demo-{version}.dist-info'
    files = {
        'shared_demo.py': f'__version__ = "{version}"\ndef main():\n    print(__version__)\n',
        f'{dist}/METADATA': f'Metadata-Version: 2.1\nName: shared-demo\nVersion: {version}\n',
        f'{dist}/WHEEL': 'Wheel-Version: 1.0\nGenerator: shared-tools-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
        f'{dist}/entry_points.txt': '[console_scripts]\nshared-demo = shared_demo:main\n',
    }
    record = io.StringIO()
    writer = csv.writer(record)
    for name, contents in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(contents.encode()).digest()).decode().rstrip('=')
        writer.writerow([name, f'sha256={digest}', len(contents.encode())])
    writer.writerow([f'{dist}/RECORD', '', ''])
    files[f'{dist}/RECORD'] = record.getvalue()
    with zipfile.ZipFile(pathlib.Path(sys.argv[1]) / f'shared_demo-{version}-py3-none-any.whl', 'w') as wheel:
        for name, contents in files.items():
            wheel.writestr(name, contents)
PY

# Manual installs use the shared package root, independently of uv's environments.
common_python_environment
use_profile public-uv
common_python_publish_uv
[[ -x "$test_profile/bin/uv" ]] || fail 'system uv did not get a public command entry'
run_uv() { "$test_root/public-uv/bin/uv" "$@"; }
export PIP_DISABLE_PIP_VERSION_CHECK=1
"$test_python" -m pip install --no-index "$test_root/fixtures/shared_demo-1.0.0-py3-none-any.whl"
assert_equal "$("$test_python" -c 'import shared_demo; print(shared_demo.__version__)')" 1.0.0
assert_equal "$("$PYTHON_PACKAGES_ROOT/bin/shared-demo")" 1.0.0
"$test_python" -m pip install --no-index --target "$test_root/explicit-pip" "$test_root/fixtures/shared_demo-2.0.0-py3-none-any.whl"
[[ -f "$test_root/explicit-pip/shared_demo.py" ]] || fail 'pip ignored an explicit target'
run_uv pip install --offline --python "$test_python" --target "$test_root/explicit-uv" "$test_root/fixtures/shared_demo-2.0.0-py3-none-any.whl"
[[ -f "$test_root/explicit-uv/shared_demo.py" ]] || fail 'uv ignored an explicit target'
run_uv pip uninstall shared-demo
run_uv pip install --offline "$test_root/fixtures/shared_demo-2.0.0-py3-none-any.whl"
assert_equal "$("$test_python" -c 'import shared_demo; print(shared_demo.__version__)')" 2.0.0
run_uv pip install --offline -- "$test_root/fixtures/shared_demo-2.0.0-py3-none-any.whl"
run_uv pip list --format json | jq -e 'any(.[]; .name == "shared-demo" and .version == "2.0.0")' >/dev/null

# uv projects keep their own dependencies, even if the shared directory has a
# conflicting package version. Spaces and options before/after the subcommand
# exercise the public command wrapper rather than a synthetic argument mock.
for project in 'project a' project-b; do
  mkdir -p "$test_root/$project"
  cat >"$test_root/$project/pyproject.toml" <<TOML
[project]
name = "${project// /-}"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["shared-demo==1.0.0"]
[tool.uv.sources]
shared-demo = { path = "$test_root/fixtures/shared_demo-1.0.0-py3-none-any.whl" }
TOML
  # Lock first so both sync and run select the completed dependency configuration.
  run_uv lock --offline --directory "$test_root/$project" --python "$test_python"
  run_uv --directory "$test_root/$project" sync --offline --python "$test_python"
done
project_a_env="$(run_uv run --offline --directory "$test_root/project a" python -c 'import sys; print(sys.prefix)')"
project_b_env="$(run_uv run --offline --project "$test_root/project-b" python -c 'import sys; print(sys.prefix)')"
[[ "$project_a_env" == "$UV_ENVIRONMENTS_ROOT/projects/"* ]] || fail 'uv project escaped the environment root'
[[ "$project_a_env" != "$project_b_env" ]] || fail 'different uv projects share an environment'
assert_equal "$(run_uv run --offline --directory "$test_root/project a" python -c 'import shared_demo; print(shared_demo.__version__)')" 1.0.0
assert_equal "$(run_uv run --offline --directory "$test_root/project a" python -c 'import os; print(os.getenv("PIP_TARGET", "unset"))')" unset
assert_equal "$(run_uv run --offline --directory "$test_root/project a" python -c 'import sys; print(sys.argv[1])' --project /not-a-project)" --project
[[ ! -e "$test_root/project a/.venv" ]] || fail 'uv created a project-local environment'
explicit_env="$(UV_PROJECT_ENVIRONMENT="$test_root/custom-env" run_uv run --offline --directory "$test_root/project a" python -c 'import sys; print(sys.prefix)')"
assert_equal "$explicit_env" "$test_root/custom-env"
run_uv pip install --offline --python "$explicit_env/bin/python" "$test_root/fixtures/shared_demo-1.0.0-py3-none-any.whl"
assert_equal "$(PYTHONPATH='' "$explicit_env/bin/python" -c 'import shared_demo; print(shared_demo.__version__)')" 1.0.0
VIRTUAL_ENV="$explicit_env" run_uv pip install --offline "$test_root/fixtures/shared_demo-1.0.0-py3-none-any.whl"
assert_equal "$("$test_python" -c 'import shared_demo; print(shared_demo.__version__)')" 2.0.0

# Members of one uv workspace select the root's environment, not one per member.
mkdir -p "$test_root/workspace/member"
cat >"$test_root/workspace/pyproject.toml" <<'TOML'
[project]
name = "workspace-root"
version = "0.1.0"
requires-python = ">=3.11"
[tool.uv.workspace]
members = ["member"]
TOML
cat >"$test_root/workspace/member/pyproject.toml" <<'TOML'
[project]
name = "workspace-member"
version = "0.1.0"
requires-python = ">=3.11"
TOML
run_uv lock --offline --project "$test_root/workspace" --python "$test_python"
workspace_env="$(run_uv run --offline --project "$test_root/workspace" python -c 'import sys; print(sys.prefix)')"
assert_equal "$(run_uv run --offline --directory "$test_root/workspace/member" python -c 'import sys; print(sys.prefix)')" "$workspace_env"

export TOOLS_INSTALL_MODE=skip UV_OFFLINE=1
python_version="$($test_python -c 'import platform; print(platform.python_version())')"
export EXTRA_TOOLS="python@$python_version"
export PYTHON_PACKAGES="$test_root/fixtures/shared_demo-1.0.0-py3-none-any.whl"
use_profile python-a
extra_tools_initialize
python_a_release="$(readlink -f "$test_root/python-a/python/current")"
[[ "$python_a_release" == "$UV_ENVIRONMENTS_ROOT/packages/"* ]] || fail 'managed packages stayed in the tool store'
assert_equal "$("$test_root/python-a/bin/python" -c 'import shared_demo; print(shared_demo.__version__)')" 1.0.0
assert_equal "$("$test_root/python-a/bin/shared-demo")" 1.0.0

export PYTHON_PACKAGES="$test_root/fixtures/shared_demo-2.0.0-py3-none-any.whl"
use_profile python-b
extra_tools_initialize
assert_equal "$("$test_root/python-b/bin/shared-demo")" 2.0.0
assert_equal "$("$test_root/python-a/bin/shared-demo")" 1.0.0

# Identical interpreter/package selections reuse the completed shared environment.
export PYTHON_PACKAGES="$test_root/fixtures/shared_demo-1.0.0-py3-none-any.whl"
use_profile python-c
extra_tools_initialize
assert_equal "$(readlink -f "$test_root/python-c/python/current")" "$python_a_release"

# A failed package change restores the previous environment for that container.
use_profile python-a
export PYTHON_PACKAGES="$test_root/fixtures/does_not_exist-3.0.0-py3-none-any.whl"
extra_tools_initialize
assert_equal "$(readlink -f "$test_root/python-a/python/current")" "$python_a_release"
assert_equal "$("$test_root/python-a/bin/shared-demo")" 1.0.0

export PYTHON_PACKAGES="$test_root/fixtures/shared_demo-1.0.0-py3-none-any.whl"
export TOOLS_INSTALL_MODE=overwrite
extra_tools_initialize
[[ "$(readlink -f "$test_root/python-a/python/current")" != "$python_a_release" ]] || fail 'Python overwrite reused an environment'
assert_equal "$("$test_root/python-c/bin/shared-demo")" 1.0.0
assert_equal "$("$test_root/python-b/bin/shared-demo")" 2.0.0
(
  use_profile python-c
  export TOOLS_INSTALL_MODE=update UV_ENVIRONMENTS_ROOT="$test_root/moved-uvenvs"
  extra_tools_initialize
  [[ "$(readlink -f "$test_profile/python/current")" == "$UV_ENVIRONMENTS_ROOT/packages/"* ]] || fail 'changing the environment root reused the previous directory'
  assert_equal "$("$test_profile/bin/shared-demo")" 1.0.0
)

# CLI maintenance must keep using the image Node, even after tool initialization.
expected_node="$(type -P node)"
mkdir -p "$test_root/fake-profile/bin"
printf '#!/bin/sh\necho v99.0.0\n' >"$test_root/fake-profile/bin/node"
chmod +x "$test_root/fake-profile/bin/node"
cp "$test_root/fake-profile/bin/node" "$PYTHON_PACKAGES_ROOT/bin/node"
use_profile fake-profile
export AGENT_CLIS=none
export PATH="$test_profile/bin:$PATH"
agent_cli_initialize
assert_equal "$AGENT_CLI_MANAGER_NODE" "$expected_node"

# Exercise complete initialization with no requested installs and a system uv.
(
  export PATH="$AGENT_CLI_MANAGER_PATH"
  # shellcheck disable=SC2317,SC2329 # Invoked indirectly by common_initialize.
  extra_tools_profile_directory() { printf '%s\n' "$test_root/initialized"; }
  export AGENT_CLIS=none EXTRA_TOOLS=none PYTHON_PACKAGES=none AGENT_CLI_ROOT="$test_root/cli"
  common_initialize
  assert_equal "$AGENT_CLI_ROOT" "$test_root/cli"
  assert_equal "$PIP_TARGET" "$PYTHON_PACKAGES_ROOT"
  [[ -x "$test_root/initialized/bin/uv" ]] || fail 'complete initialization omitted system uv'
  assert_equal "$AGENT_CLI_MANAGER_NODE" "$expected_node"
)

printf 'PASS: HOME defaults, shared versions, concurrency, recovery, pip targets, uv projects/workspaces, Python package isolation and CLI runtime isolation\n'
