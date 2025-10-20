#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
trap "rm -rf temp/*tmp.* temp/*/*tmp.* temp/*-temporary-files; exit 130" INT

if [[ "${1-}" = "clean" ]]; then
  rm -rf temp build logs build.md
  exit 0
fi

source utils.sh
set_prebuilts

vtf() {
  if ! isoneof "${1}" "true" "false"; then
    abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"
  fi
}

# -- Main config --
toml_prep "${1:-config.toml}" || abort "Could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t=$(toml_get_table_main)
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL="9"
if ! PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs); then
  if [[ "${OS:-}" = Android ]]; then PARALLEL_JOBS=1; else PARALLEL_JOBS=$(nproc); fi
fi
REMOVE_RV_INTEGRATIONS_CHECKS=$(toml_get "$main_config_t" remove-rv-integrations-checks) || REMOVE_RV_INTEGRATIONS_CHECKS="true"
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER="dev"
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version) || DEF_CLI_VER="dev"
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC="anddea/revanced-patches"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source) || DEF_CLI_SRC="inotia00/revanced-cli"
DEF_RV_BRAND=$(toml_get "$main_config_t" rv-brand) || DEF_RV_BRAND="RVX App"

# Create required directories
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

# Handle config update mode
if [[ "${2-}" = "--config-update" ]]; then
  config_update
  exit 0
fi

# Initialize build log
: >build.md

# Validate compression level
if ((COMPRESSION_LEVEL > 9)) || ((COMPRESSION_LEVEL < 0)); then
  abort "compression-level must be within 0-9"
fi

# Check required tools
command -v jq     &>/dev/null || abort "`jq` is not installed. Install it with 'apt install jq' or equivalent"
command -v java   &>/dev/null || abort "`openjdk` is not installed. Install it with 'apt install openjdk-17-jre' or equivalent"
command -v zip    &>/dev/null || abort "`zip` is not installed. Install it with 'apt install zip' or equivalent"

# Check optimization tools when enabled (values used by utils)
optimize_apk=$(toml_get "$main_config_t" optimize-apk) || optimize_apk=false
zipalign=$(toml_get "$main_config_t" zipalign) || zipalign=false

# Clear per-run changelog buffers
find "$TEMP_DIR" -name "changelog.md" -type f -exec : '>' {} \; 2>/dev/null || :

idx=0
for table_name in $(toml_get_table_names); do
  # Skip PatchSources section
  [[ "$table_name" == "PatchSources" ]] && continue
  [[ -z "$table_name" ]] && continue

  t=$(toml_get_table "$table_name")
  enabled=$(toml_get "$t" enabled) || enabled=true
  vtf "$enabled" "enabled"
  [[ "$enabled" = false ]] && continue

  if ((idx >= PARALLEL_JOBS)); then
    wait -n
    idx=$((idx - 1))
  fi

  declare -A app_args
  # Table-specific args
  app_args[rv_brand]=$(toml_get "$t" rv-brand) || app_args[rv_brand]=$DEF_RV_BRAND
  app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
  app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
  app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) && vtf "${app_args[exclusive_patches]}" "exclusive-patches" || app_args[exclusive_patches]=false
  app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
  app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
  app_args[patcher_args]=$(toml_get "$t" patcher-args) || app_args[patcher_args]=""
  app_args[table]=$table_name
  app_args[dpi]=$(toml_get "$t" dpi) || app_args[dpi]="nodpi"

  # Validate patch names format
  [[ -n "${app_args[excluded_patches]}" && ${app_args[excluded_patches]} != *'"'* ]] && abort "Patch names inside excluded-patches must be quoted"
  [[ -n "${app_args[included_patches]}" && ${app_args[included_patches]} != *'"'* ]] && abort "Patch names inside included-patches must be quoted"

  # Set download sources
  app_args[uptodown_dlurl]=$(toml_get "$t" uptodown-dlurl) && {
    app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
    app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%download}
    app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
    app_args[dl_from]=uptodown
  } || app_args[uptodown_dlurl]=""

  app_args[apkmirror_dlurl]=$(toml_get "$t" apkmirror-dlurl) && {
    app_args[apkmirror_dlurl]=${app_args[apkmirror_dlurl]%/}
    app_args[dl_from]=apkmirror
  } || app_args[apkmirror_dlurl]=""

  app_args[archive_dlurl]=$(toml_get "$t" archive-dlurl) && {
    app_args[archive_dlurl]=${app_args[archive_dlurl]%/}
    app_args[dl_from]=archive
  } || app_args[archive_dlurl]=""

  [[ -z "${app_args[dl_from]-}" ]] && abort "ERROR: No 'apkmirror_dlurl', 'uptodown_dlurl' or 'archive_dlurl' option was set for '$table_name'."

  # Process architecture settings
  app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="all"
  if [[ "${app_args[arch]}" != "both" && "${app_args[arch]}" != "all" && ${app_args[arch]} != "arm64-v8a"* && ${app_args[arch]} != "arm-v7a"* ]]; then
    abort "Wrong arch '${app_args[arch]}' for '$table_name'"
  fi

  # NOTE: We do NOT pre-download CLI/patch jars here anymore.
  # utils.sh resolves (and caches) the correct CLI/patch jars per app,
  # including multi-source combination with privacy-last ordering and riplib detection.

  # Handle both architectures if needed
  if [[ "${app_args[arch]}" = both ]]; then
    app_args[table]="$table_name (arm64-v8a)"
    app_args[arch]="arm64-v8a"
    idx=$((idx + 1)); build_rv "$(declare -p app_args)" &

    app_args[table]="$table_name (arm-v7a)"
    app_args[arch]="arm-v7a"
    if ((idx >= PARALLEL_JOBS)); then
      wait -n
      idx=$((idx - 1))
    fi
    idx=$((idx + 1)); build_rv "$(declare -p app_args)" &
  else
    idx=$((idx + 1)); build_rv "$(declare -p app_args)" &
  fi
done

# Wait for all background jobs to complete
wait

# Clean up temporary files
rm -rf temp/tmp.*

# Check for build success (fast check)
if ! find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  abort "All builds failed."
fi

# Generate final output
log "\n- ▶️ » Install [MicroG-RE](https://github.com/WSTxda/MicroG-RE/releases) for non-root YouTube and YT Music APKs\n"
log "$(cat "$TEMP_DIR"/*-rv/changelog.md 2>/dev/null || echo '')"

SKIPPED=$(cat "$TEMP_DIR"/skipped 2>/dev/null || :)
if [[ -n "$SKIPPED" ]]; then
  log "\nSkipped:"
  log "$SKIPPED"
fi

pr "Done"
