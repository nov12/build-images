#!/usr/bin/env bash
set -e

source "${BASH_SOURCE[0]%/*}/python.sh"

kind="$1" binary="$2"
shift 2
common_python_environment
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$(extra_tools_root)/python-interpreters}"
export UV_TOOL_DIR="${UV_TOOL_DIR:-$UV_ENVIRONMENTS_ROOT/tools}"

if [[ "$kind" == environment ]]; then
  common_python_isolate
  exec "$binary" "$@"
fi

# Inspect uv's own options only. Arguments passed to `uv run`'s command are opaque.
command='' action='' directory="${UV_WORKING_DIR:-$PWD}" project="${UV_PROJECT:-}"
python_request="${UV_PYTHON:-}"
explicit=0 project_override=0 previous=''
discovery=() arguments=("$@")
action_index=0
for ((index = 0; index < ${#arguments[@]}; index++)); do
  argument="${arguments[index]}"
  if [[ -n "$previous" ]]; then
    case "$previous" in
      --directory) directory="$argument" ;;
      --project) project="$argument" ;;
      --config-file) discovery+=(--config-file "$argument") ;;
      --python | -p) python_request="$argument" ;;
    esac
    previous=''
    continue
  fi
  case "$argument" in
    --) break ;;
    --directory | --project | --config-file) previous="$argument" ;;
    --directory=*) directory="${argument#*=}" ;;
    --project=*) project="${argument#*=}" ;;
    --config-file=*) discovery+=("$argument") ;;
    --no-config) discovery+=("$argument") ;;
    --active | --no-project | --script | --script=*) project_override=1 ;;
    --python=* | -p?*) explicit=1; python_request="${argument#*=}"; python_request="${python_request#-p}" ;;
    --target | --target=* | -t | -t?* | --prefix | --prefix=* | --python | -p | --system)
      explicit=1
      case "$argument" in --target | -t | --prefix | --python | -p) previous="$argument" ;; esac ;;
    --with | --with-editable | --with-requirements | --extra | --group | --package | --python-version | --python-platform | --index | --default-index | --index-url | -i | --extra-index-url | --find-links | -f | --cache-dir | --color | --allow-insecure-host | --resolution | --prerelease | --link-mode | --config-setting | --env-file | --exclude | --exclude-newer)
      previous="$argument" ;;
    -*) ;;
    *)
      if [[ -z "$command" ]]; then command="$argument"
      elif [[ "$command" == pip && -z "$action" ]]; then action="$argument"; action_index=$((index + 1))
      elif [[ "$command" == run ]]; then break
      fi ;;
  esac
done

if [[ "$directory" != /* ]]; then directory="$PWD/$directory"; fi
if [[ -n "$project" && "$project" != /* ]]; then project="$directory/$project"; fi

case "$command" in
  pip)
    # Explicit targets, Python selections and activated environments retain uv's behavior.
    if [[ "$explicit" == 0 && -z "${VIRTUAL_ENV:-}" && -z "${UV_PYTHON:-}" && "${UV_SYSTEM_PYTHON:-false}" != true ]]; then
      case "$action" in
        install | uninstall | list | freeze | show)
          exec "$binary" "${arguments[@]:0:action_index}" --system --target "$PYTHON_PACKAGES_ROOT" "${arguments[@]:action_index}" ;;
      esac
    fi
    common_python_isolate ;;
  run | sync | add | remove)
    common_python_isolate
    if [[ -z "${UV_PROJECT_ENVIRONMENT:-}" && "$project_override" == 0 ]]; then
      # uv resolves workspace membership itself. Older uv releases fall back to
      # their normal .venv behavior instead of guessing the wrong workspace root.
      if [[ -n "$project" ]]; then discovery+=(--project "$project"); fi
      if root="$("$binary" workspace dir --directory "$directory" "${discovery[@]}" 2>/dev/null)" && [[ -d "$root" ]]; then
        key="$(
          {
            printf '%s\0' "$(realpath -- "$root")" "$python_request"
            for file in pyproject.toml uv.lock .python-version; do
              if [[ -f "$root/$file" ]]; then sha256sum -- "$root/$file"; fi
            done
          } | sha256sum
        )"
        export UV_PROJECT_ENVIRONMENT="$UV_ENVIRONMENTS_ROOT/projects/${key%% *}"
      fi
    fi ;;
  *) common_python_isolate ;;
esac

exec "$binary" "$@"
