#!/usr/bin/env bash
# ReVanced APK Builder - Main Build Script
# This script orchestrates parallel building of ReVanced APKs from config.toml
# Features:
#   - Parallel job management with configurable concurrency
#   - Multi-architecture support (arm64-v8a, arm-v7a)
#   - Safe argument passing using JSON serialization
#   - Background job error tracking and reporting
#   - Automatic cleanup on interrupt
#
# Usage: ./build.sh [config.toml]
#        ./build.sh clean  # Remove build artifacts

set -euo pipefail
shopt -s nullglob
trap "rm -rf temp/*tmp.* temp/*/*tmp.* temp/*-temporary-files; exit 130" INT

if [[ "${1-}" = "clean" ]]; then
  rm -rf temp build logs build.md
  exit 0
fi

source utils.sh
declare -F set_prebuilts &>/dev/null && set_prebuilts

vtf(){
  if ! isoneof "${1}" "true" "false"; then
    abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"
  fi
}

# Check if required tools are available
command -v jq && echo "✓ jq installed" || echo "✗ jq missing"
command -v java && echo "✓ java installed" || echo "✗ java missing"
command -v zip && echo "✓ zip installed" || echo "✗ zip missing"

toml_prep "${1:-config.toml}"||abort "Could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t=$(toml_get_table_main)

if JF=$(toml_get "$main_config_t" jvm-flags); then
  export JVM_OPTS="$JF"
elif [[ -n "${JAVA_OPTS:-}" ]]; then
  export JVM_OPTS="$JAVA_OPTS"
fi

COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level)||COMPRESSION_LEVEL="9"
if ! PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs); then
  if [[ "${OS:-}" = Android ]]; then PARALLEL_JOBS=1; else PARALLEL_JOBS=$(nproc); fi
fi
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version)||DEF_PATCHES_VER="dev"
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version)||DEF_CLI_VER="dev"
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source)||DEF_PATCHES_SRC="anddea/revanced-patches"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source)||DEF_CLI_SRC="inotia00/revanced-cli"
DEF_RV_BRAND=$(toml_get "$main_config_t" rv-brand)||DEF_RV_BRAND="RVX App"

mkdir -p "$TEMP_DIR" "$BUILD_DIR"

: >build.md

if ((COMPRESSION_LEVEL>9))||((COMPRESSION_LEVEL<0)); then
  abort "compression-level must be within 0-9"
fi

command -v jq &>/dev/null||abort "jq not installed. Install: apt install jq"
command -v java &>/dev/null||abort "java not installed. Install: apt install openjdk-17-jre"
command -v zip &>/dev/null||abort "zip not installed. Install: apt install zip"

find "$TEMP_DIR" -name "changelog.md" -type f -exec : '>' {} \; 2>/dev/null||:

idx=0
declare -a job_pids=()
declare -a job_names=()
failed_jobs=0

for table_name in $(toml_get_table_names); do
  [[ "$table_name" == "PatchSources" ]] && continue
  [[ -z "$table_name" ]] && continue

  t=$(toml_get_table "$table_name")
  enabled=$(toml_get "$t" enabled)||enabled=true
  vtf "$enabled" "enabled"
  [[ "$enabled" = false ]] && continue

  if ((idx>=PARALLEL_JOBS)); then
    wait -n
    # Check if the completed job failed
    for pid in "${job_pids[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        if ! wait "$pid" 2>/dev/null; then
          ((failed_jobs++))
        fi
        # Remove this PID from tracking
        job_pids=("${job_pids[@]/$pid}")
      fi
    done
    idx=$((idx-1))
  fi

  declare -A app_args
  app_args[rv_brand]=$(toml_get "$t" rv-brand)||app_args[rv_brand]=$DEF_RV_BRAND
  app_args[excluded_patches]=$(toml_get "$t" excluded-patches)||app_args[excluded_patches]=""
  app_args[included_patches]=$(toml_get "$t" included-patches)||app_args[included_patches]=""
  app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) && vtf "${app_args[exclusive_patches]}" "exclusive-patches"||app_args[exclusive_patches]=false
  app_args[version]=$(toml_get "$t" version)||app_args[version]="auto"
  app_args[app_name]=$(toml_get "$t" app-name)||app_args[app_name]=$table_name
  app_args[patcher_args]=$(toml_get "$t" patcher-args)||app_args[patcher_args]=""
  app_args[table]=$table_name
  app_args[dpi]=$(toml_get "$t" dpi)||app_args[dpi]="nodpi"

  # Validate inputs
  [[ -n "${app_args[excluded_patches]}" && ${app_args[excluded_patches]} != *'"'* ]] && abort "Patch names inside excluded-patches must be quoted"
  [[ -n "${app_args[included_patches]}" && ${app_args[included_patches]} != *'"'* ]] && abort "Patch names inside included-patches must be quoted"
  validate_version "${app_args[version]}" || abort "Invalid version for '$table_name'"
  validate_dpi "${app_args[dpi]}"

  app_args[uptodown_dlurl]=$(toml_get "$t" uptodown-dlurl) && {
    app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
    app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%download}
    app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
    app_args[dl_from]=uptodown
  }||app_args[uptodown_dlurl]=""

  app_args[apkmirror_dlurl]=$(toml_get "$t" apkmirror-dlurl) && {
    app_args[apkmirror_dlurl]=${app_args[apkmirror_dlurl]%/}
    app_args[dl_from]=apkmirror
  }||app_args[apkmirror_dlurl]=""

  app_args[archive_dlurl]=$(toml_get "$t" archive-dlurl) && {
    app_args[archive_dlurl]=${app_args[archive_dlurl]%/}
    app_args[dl_from]=archive
  }||app_args[archive_dlurl]=""

  [[ -z "${app_args[dl_from]-}" ]] && abort "ERROR: No 'apkmirror_dlurl', 'uptodown_dlurl' or 'archive_dlurl' option was set for '$table_name'."

  app_args[arch]=$(toml_get "$t" arch)||app_args[arch]="all"
  validate_arch "${app_args[arch]}" || abort "Invalid architecture for '$table_name'"

  if [[ "${app_args[arch]}" = both ]]; then
    app_args[table]="$table_name (arm64-v8a)"; app_args[arch]="arm64-v8a"
    idx=$((idx+1))
    build_rv "$(serialize_array app_args)" &
    job_pids+=($!)
    job_names+=("$table_name (arm64-v8a)")

    app_args[table]="$table_name (arm-v7a)"; app_args[arch]="arm-v7a"
    if ((idx>=PARALLEL_JOBS)); then
      wait -n
      for pid in "${job_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
          if ! wait "$pid" 2>/dev/null; then
            ((failed_jobs++))
          fi
          job_pids=("${job_pids[@]/$pid}")
        fi
      done
      idx=$((idx-1))
    fi
    idx=$((idx+1))
    build_rv "$(serialize_array app_args)" &
    job_pids+=($!)
    job_names+=("$table_name (arm-v7a)")
  else
    idx=$((idx+1))
    build_rv "$(serialize_array app_args)" &
    job_pids+=($!)
    job_names+=("$table_name")
  fi
done

# Wait for all remaining jobs and check their exit codes
wait
for pid in "${job_pids[@]}"; do
  [[ -z "$pid" ]] && continue
  if ! wait "$pid" 2>/dev/null; then
    ((failed_jobs++))
  fi
done

rm -rf temp/tmp.*

if ((failed_jobs > 0)); then
  epr "⚠️  WARNING: $failed_jobs job(s) failed during the build process"
fi

if ! find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -print -quit|grep -q .; then
  abort "All builds failed."
fi

log "\n▶️ Install [MicroG-RE](https://github.com/WSTxda/MicroG-RE/releases) for non-root YouTube/YT Music\n"
log "$(cat "$TEMP_DIR"/*-rv/changelog.md 2>/dev/null||:)"

SKIPPED=$(cat "$TEMP_DIR"/skipped 2>/dev/null||:)
if [[ -n "$SKIPPED" ]]; then
  log "\nSkipped:"
  log "$SKIPPED"
fi

pr "✅ Done"
