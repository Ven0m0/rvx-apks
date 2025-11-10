#!/usr/bin/env bash
set -euo pipefail

# Extras script for build workflows
# Usage: ./extras.sh <command> [args...]

# ================================================================================
# HELPER FUNCTIONS
# ================================================================================

# Extract global settings from TOML (everything before first section)
extract_global_settings(){
  local config_file=$1
  awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { print }
  ' "$config_file"
}

# Extract PatchSources section from TOML
extract_patch_sources(){
  local config_file=$1
  awk '
    /^\[PatchSources\./ { in_section = 1 }
    /^\[/ && !/^\[PatchSources\./ && in_section == 1 { exit }
    in_section == 1 { print }
  ' "$config_file"
}

# Extract specific app section from TOML
extract_app_section(){
  local config_file=$1 key=$2
  awk -v key="$key" '
    /^\[/ && tolower($1) == "[" tolower(key) "]" { in_section = 1; print; next }
    /^\[/ && in_section == 1 { exit }
    in_section == 1 { print }
  ' "$config_file"
}

# Extract changelog information from build logs
extract_changelog_info(){
  local log_file=$1
  awk '/^>.*CLI:/{p=1} p{print} /^\[.*Changelog\]/{print ""; p=0}' "$log_file" 2>/dev/null || true
}

# ================================================================================
# MAIN COMMANDS
# ================================================================================

command="${1:-}"

case "$command" in
  separate-config)
    # Extract a section from TOML config file along with global config and PatchSources
    # Usage: ./extras.sh separate-config <config_file> <key_to_match> <output_file>

    if [[ $# -ne 4 ]]; then
      echo "Usage: $0 separate-config <config_file> <key_to_match> <output_file>"
      exit 1
    fi

    config_file="$2"
    key_to_match="$3"
    output_file="$4"

    # Extract configuration sections using helper functions
    global_content=$(extract_global_settings "$config_file")
    patch_sources_content=$(extract_patch_sources "$config_file")
    section_content=$(extract_app_section "$config_file" "$key_to_match")

    if [[ -z "$section_content" ]]; then
      echo "Key '$key_to_match' not found in the config file."
      exit 1
    fi

    # Write combined config
    {
      echo "# ---- Global Settings ----"
      echo "$global_content"
      echo ""
      if [[ -n "$patch_sources_content" ]]; then
        echo "# ---- Patch Sources ----"
        echo "$patch_sources_content"
        echo ""
      fi
      echo "# ---- App Configuration ----"
      echo "$section_content"
    } > "$output_file"

    echo "Section for '$key_to_match' written to $output_file with global config and patch sources"
    ;;

  combine-logs)
    # Combine build logs from multiple matrix jobs
    # Usage: ./extras.sh combine-logs <build-logs-dir>

    build_logs_dir="${2:-build-logs}"

    # Extract success messages from all logs
    for log in "$build_logs_dir"/build-log-*/build.md; do
      [[ -f "$log" ]] && grep "^🟢" "$log" 2>/dev/null || true
    done
    echo ""

    # Extract MicroG installation note (only once)
    for log in "$build_logs_dir"/build-log-*/build.md; do
      if [[ -f "$log" ]] && grep -q "MicroG" "$log"; then
        grep -A 1 "^-.*MicroG" "$log" 2>/dev/null || true
        echo ""
        break
      fi
    done

    # Extract and deduplicate changelog information
    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' EXIT

    for log in "$build_logs_dir"/build-log-*/build.md; do
      [[ -f "$log" ]] && extract_changelog_info "$log" >> "$temp_file"
    done

    # Remove duplicate lines
    awk '!seen[$0]++' "$temp_file"
    ;;

  *)
    echo "Unknown command: $command"
    echo ""
    echo "Available commands:"
    echo "  separate-config <config_file> <key_to_match> <output_file>"
    echo "  combine-logs [build-logs-dir]"
    exit 1
    ;;
esac
