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
set_prebuilts

# Load and validate configuration
toml_prep "${1:-config.toml}" || abort "Could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t="."

# Extract configuration with defaults
JVM_OPTS="${JVM_OPTS:-$(toml_get "$main_config_t" jvm-flags || echo "$JAVA_OPTS")}"
COMPRESSION_LEVEL=${COMPRESSION_LEVEL:-$(toml_get "$main_config_t" compression-level || echo 9)}
PARALLEL_JOBS=${PARALLEL_JOBS:-$(toml_get "$main_config_t" parallel-jobs || [[ "$OS" = Android ]] && echo 1 || nproc)}
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version || echo "dev")
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version || echo "dev")
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source || echo "anddea/revanced-patches")
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source || echo "inotia00/revanced-cli")
DEF_RV_BRAND=$(toml_get "$main_config_t" rv-brand || echo "RVX App")

export JVM_OPTS
mkdir -p "$TEMP_DIR" "$BUILD_DIR"
: >build.md

# Validate configuration
(( COMPRESSION_LEVEL >= 0 && COMPRESSION_LEVEL <= 9 )) || abort "ERROR: compression-level must be 0-9 (found: $COMPRESSION_LEVEL)"

# Check dependencies
pr "Checking dependencies..."
command -v jq &>/dev/null || abort "jq not installed. Install: apt install jq"
command -v java &>/dev/null || abort "java not installed. Install: apt install openjdk-17-jre"
command -v zip &>/dev/null || abort "zip not installed. Install: apt install zip"
pr "✓ All dependencies available"

find "$TEMP_DIR" -name "changelog.md" -type f -delete 2>/dev/null || :

# Build jobs tracking
idx=0 failed_jobs=0
declare -a job_pids=() job_names=()

for table_name in $(toml_get_table_names); do
  [[ "$table_name" == "PatchSources" || -z "$table_name" ]] && continue

  t=$(toml_get_table "$table_name")
  enabled=$(toml_get "$t" enabled || echo true)
  [[ "$enabled" =~ ^(true|false)$ ]] || abort "ERROR: '$enabled' invalid for 'enabled' in $table_name"
  [[ "$enabled" = false ]] && continue

  # Wait for job slot if needed
  if (( idx >= PARALLEL_JOBS )); then
    wait -n
    for pid in "${job_pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && continue
      wait "$pid" 2>/dev/null || (( failed_jobs++ ))
      job_pids=("${job_pids[@]/$pid}")
    done
    (( idx-- ))
  fi

  # Build app arguments
  declare -A app_args=(
    [rv_brand]=$(toml_get "$t" rv-brand || echo "$DEF_RV_BRAND")
    [excluded_patches]=$(toml_get "$t" excluded-patches || echo "")
    [included_patches]=$(toml_get "$t" included-patches || echo "")
    [exclusive_patches]=$(toml_get "$t" exclusive-patches || echo false)
    [version]=$(toml_get "$t" version || echo "auto")
    [app_name]=$(toml_get "$t" app-name || echo "$table_name")
    [patcher_args]=$(toml_get "$t" patcher-args || echo "")
    [table]=$table_name
    [dpi]=$(toml_get "$t" dpi || echo "nodpi")
  )

  # Validate
  [[ "${app_args[exclusive_patches]}" =~ ^(true|false)$ ]] || abort "ERROR: exclusive-patches must be true/false"
  [[ -n "${app_args[excluded_patches]}" && ${app_args[excluded_patches]} != *'"'* ]] && abort "Excluded patches must be quoted"
  [[ -n "${app_args[included_patches]}" && ${app_args[included_patches]} != *'"'* ]] && abort "Included patches must be quoted"
  validate_version "${app_args[version]}" || abort "Invalid version for '$table_name'"
  validate_dpi "${app_args[dpi]}"

  # Get download source
  for src in uptodown apkmirror archive; do
    url=$(toml_get "$t" "${src}-dlurl" 2>/dev/null) || continue
    app_args[${src}_dlurl]=${url%/}
    [[ "$src" = uptodown ]] && app_args[${src}_dlurl]=${app_args[${src}_dlurl]%download}
    [[ "$src" = uptodown ]] && app_args[${src}_dlurl]=${app_args[${src}_dlurl]%/}
    app_args[dl_from]=$src
  done
  [[ -z "${app_args[dl_from]:-}" ]] && abort "No download URL set for '$table_name'"

  app_args[arch]=$(toml_get "$t" arch || echo "all")
  validate_arch "${app_args[arch]}" || abort "Invalid architecture for '$table_name'"

  # Handle both architectures
  if [[ "${app_args[arch]}" = both ]]; then
    for arch in arm64-v8a arm-v7a; do
      app_args[table]="$table_name ($arch)"
      app_args[arch]=$arch
      build_rv "$(serialize_array app_args)" &
      job_pids+=($!) job_names+=("$table_name ($arch)")
      (( ++idx >= PARALLEL_JOBS )) && { wait -n; (( idx-- )); }
    done
  else
    build_rv "$(serialize_array app_args)" &
    job_pids+=($!) job_names+=("$table_name")
    (( idx++ ))
  fi
done

# Wait for all jobs
wait
for pid in "${job_pids[@]}"; do
  [[ -z "$pid" ]] && continue
  wait "$pid" 2>/dev/null || (( failed_jobs++ ))
done

rm -rf temp/tmp.*

(( failed_jobs > 0 )) && epr "⚠️  WARNING: $failed_jobs job(s) failed"
find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q . || abort "All builds failed"

log "\n▶️ Install [MicroG-RE](https://github.com/WSTxda/MicroG-RE/releases) for non-root YouTube/YT Music\n"
log "$(cat "$TEMP_DIR"/*-rv/changelog.md 2>/dev/null || :)"

SKIPPED=$(cat "$TEMP_DIR"/skipped 2>/dev/null || :)
[[ -n "$SKIPPED" ]] && log "\nSkipped:\n$SKIPPED"

pr "✅ Done"
