#!/usr/bin/env bash
# ================================================================================
# ReVanced APK Builder - Utility Functions
# ================================================================================
# This file contains all core utilities for building ReVanced APKs.
#
# MAIN FUNCTIONS:
#   - Configuration parsing (TOML → JSON)
#   - APK downloading (APKMirror, Uptodown, Archive.org)
#   - Patch application and APK optimization
#   - Network operations with automatic retry logic
#   - Input validation and error handling
#
# FOR BEGINNERS:
#   - Functions starting with '_' are internal (don't call directly)
#   - Functions starting with 'get_' fetch data from external sources
#   - Functions starting with 'dl_' download files
#   - All network operations retry automatically on failure
# ================================================================================

# ================================================================================
# CONFIGURATION CONSTANTS
# Centralized configuration values used throughout the build process
# ================================================================================

readonly MAX_RETRY_ATTEMPTS=3      # Maximum number of retry attempts for network operations
readonly INITIAL_RETRY_DELAY=2     # Initial delay in seconds before retrying (doubles each time)
readonly DEFAULT_COMPRESSION_LEVEL=9  # ZIP compression level (0-9, 9 = maximum)
readonly DOWNLOAD_TIMEOUT=300      # Timeout for file downloads in seconds (5 minutes)
readonly CONNECTION_TIMEOUT=30     # Timeout for establishing connections in seconds
readonly REQUEST_TIMEOUT=60        # Timeout for HTTP requests in seconds

# ================================================================================
# CORE UTILITY FUNCTIONS
# Basic functions used throughout the build process
# ================================================================================

# Error Handling Convention:
# - abort()   : Fatal errors, exits immediately (e.g., missing dependencies, invalid config)
# - return 1  : Recoverable errors, caller can retry or use fallback (e.g., network failures)
# - return 0  : Success, or graceful skip (e.g., build_rv skips apps gracefully)
# - epr()     : Print error message to stderr (does not exit or return)

abort(){ echo "ABORT: $*" >&2; exit 1; }
epr(){ echo -e "$*" >&2; }
pr(){ echo -e "$*"; }
log(){ echo -e "$*" >> build.md 2>/dev/null || :; }

# ================================================================================
# INPUT VALIDATION FUNCTIONS
# These functions validate user input from config.toml to prevent errors
# ================================================================================

validate_version(){
  # Accepts: auto, latest, beta, or semantic versioning (e.g., 19.09.36)
  [[ "$1" =~ ^(auto|latest|beta|[0-9]+\.[0-9]+(\.[0-9]+)?([.-][a-zA-Z0-9]+)?)$ ]] || {
    epr "ERROR: Invalid version '$1'. Use: auto, latest, beta, or version number (e.g., 19.09.36)"
    return 1
  }
}

validate_arch(){
  # all: universal APK | both: arm64-v8a + arm-v7a builds | specific arch
  [[ "$1" =~ ^(all|both|arm64-v8a|arm-v7a)$ ]] || {
    epr "ERROR: Invalid architecture '$1'. Valid: all, both, arm64-v8a, arm-v7a"
    return 1
  }
}

validate_dpi(){
  # nodpi: all densities | specific DPI: targets specific screen density
  [[ "$1" =~ ^(nodpi|[0-9]+|[lmhx]+dpi|xxhdpi|xxxhdpi)$ ]] || epr "WARNING: Unusual DPI '$1'"
}

# ================================================================================
# ENVIRONMENT SETUP
# Initialize build directories and environment variables
# ================================================================================

set_prebuilts(){
  # Set up directory structure for build process
  export TEMP_DIR=${TEMP_DIR:-temp}          # Temporary files during build
  export BUILD_DIR=${BUILD_DIR:-build}       # Final APK output directory
  export LOG_DIR=${LOG_DIR:-logs}            # Build logs
  export BIN_DIR=${BIN_DIR:-bin}             # Build tools (CLI, patches, etc)
  export OS=${OS:-$(uname -s)}               # Operating system
  export ARCH=${ARCH:-$(uname -m)}           # CPU architecture
  export JVM_OPTS="${JVM_OPTS:-${JAVA_OPTS:--Dfile.encoding=UTF-8}}"

  mkdir -p "$TEMP_DIR" "$BUILD_DIR" "$LOG_DIR" "$BIN_DIR/patchcache"
  [[ ":$PATH:" != *":$BIN_DIR:"* ]] && export PATH="$BIN_DIR:$PATH"
}

# ================================================================================
# TOML CONFIGURATION PARSING
# Convert TOML config files to JSON for easy processing with jq
# ================================================================================

_toml_to_json_with_tq(){
  local file=$1 out=$2
  # Try tq with JSON output format
  if command -v tq &>/dev/null; then
    if tq -f "$file" --format json . >"$out" 2>/dev/null && jq -e . "$out" &>/dev/null; then
      return 0
    fi
  fi
  # Try prebuilt tq binaries
  local arch; arch=$(uname -m)
  local tq_path="$BIN_DIR/toml/tq-${arch}"
  if [[ -x "$tq_path" ]]; then
    if "$tq_path" -f "$file" --format json . >"$out" 2>/dev/null && jq -e . "$out" &>/dev/null; then
      return 0
    fi
  fi
  for tp in "$BIN_DIR/toml/tq" "$BIN_DIR/toml/tq-arm64" "$BIN_DIR/toml/tq-x86_64"; do
    if [[ -x "$tp" ]]; then
      if "$tp" -f "$file" --format json . >"$out" 2>/dev/null && jq -e . "$out" &>/dev/null; then
        return 0
      fi
    fi
  done
  return 127
}
_toml_to_json_with_python(){
  local file=$1 out=$2
  command -v python3 &>/dev/null || return 127
  python3 - "$file" >"$out" <<'PY'
import sys,json
try:
  import tomllib
except:
  import tomli as tomllib
with open(sys.argv[1],'rb') as f:
  data=tomllib.load(f)
json.dump(data,sys.stdout,ensure_ascii=False)
PY
}
toml_prep(){
  [[ -f "${1:-config.toml}" ]] || return 1
  mkdir -p "$TEMP_DIR"
  local out="$TEMP_DIR/config.json"
  _toml_to_json_with_tq "${1:-config.toml}" "$out" || _toml_to_json_with_python "${1:-config.toml}" "$out" || {
    epr "TOML parser unavailable"
    return 1
  }
  export TOML_JSON="$out"
  [[ -s "$TOML_JSON" ]]
}

toml_get_table(){ printf '.%s' "${1//./\\.}"; }
toml_get_table_names(){ jq -r 'to_entries|map(select(.value|type=="object"))|.[].key' "$TOML_JSON"; }
toml_get(){ jq -r "${1}|.[\"$2\"]//empty" "$TOML_JSON"; }
# ================================================================================
# DATA SERIALIZATION UTILITIES
# Safely pass data between functions and background jobs
# ================================================================================

# Serialize associative array to JSON (safer than declare -p + eval)
serialize_array(){
  local -n arr=$1
  local json="{"
  local first=true
  for key in "${!arr[@]}"; do
    [[ "$first" = false ]] && json+=","
    # Escape special characters in value
    local val="${arr[$key]}"
    val="${val//\\/\\\\}"  # Escape backslashes
    val="${val//\"/\\\"}"  # Escape quotes
    json+="\"$key\":\"$val\""
    first=false
  done
  json+="}"
  echo "$json"
}

# Deserialize JSON to associative array (safer than eval)
deserialize_array(){
  local json=$1
  local -n target=$2
  # Parse JSON using jq and populate associative array
  while IFS='=' read -r key value; do
    target["$key"]="$value"
  done < <(echo "$json" | jq -r 'to_entries | .[] | "\(.key)=\(.value)"')
}

join_args(){
  local list_str=$1 flag=$2
  local -a items=(); eval "items=($list_str)"
  local -a out=()
  for it in "${items[@]}"; do
    out+=("$flag" "$it")
  done
  printf '%q ' "${out[@]}" | sed 's/ $//'
}

# Get highest version from list (natural sort)
get_highest_ver(){ sort -V | tail -n1; }

# ================================================================================
# NETWORK OPERATIONS WITH RETRY LOGIC
# Download files and fetch data from GitHub/APK sources with automatic retries
# ================================================================================

# GitHub API request with retry logic and rate limit awareness
gh_req(){
  [[ -z "${GITHUB_TOKEN:-}" ]] && epr "WARNING: GITHUB_TOKEN not set. Rate limit: 60/hr vs 5000/hr with token"

  local delay=$INITIAL_RETRY_DELAY
  local attempt
  for attempt in $(seq 1 $MAX_RETRY_ATTEMPTS); do
    local response=$(curl -sL -H "Authorization: token ${GITHUB_TOKEN:-}" "$1" 2>&1)
    [[ -n "$response" ]] && { echo "$response"; return 0; }
    (( attempt < MAX_RETRY_ATTEMPTS )) && { epr "GitHub request failed (attempt $attempt/$MAX_RETRY_ATTEMPTS), retry in ${delay}s..."; sleep "$delay"; (( delay *= 2 )); }
  done

  epr "ERROR: GitHub request failed after $MAX_RETRY_ATTEMPTS attempts: $1"
  return 1
}

# Download file with retry logic and exponential backoff
dl_file(){
  local url=$1 out=$2
  local attempt=1 delay=$INITIAL_RETRY_DELAY

  while ((attempt <= MAX_RETRY_ATTEMPTS)); do
    if curl -fSL --connect-timeout $CONNECTION_TIMEOUT --max-time $DOWNLOAD_TIMEOUT -o "$out" "$url" 2>/dev/null; then
      # Verify file was actually downloaded and has content
      if [[ -f "$out" && -s "$out" ]]; then
        return 0
      fi
    fi

    if ((attempt < MAX_RETRY_ATTEMPTS)); then
      epr "Download failed (attempt $attempt/$MAX_RETRY_ATTEMPTS), retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done

  epr "ERROR: Failed to download after $MAX_RETRY_ATTEMPTS attempts: $url"
  return 1
}

# Download ReVanced CLI and patches JAR files from GitHub releases
# Args:
#   $1 - CLI source repository (e.g., "ReVanced/revanced-cli")
#   $2 - CLI version ("dev", "latest", or specific version)
#   $3 - Patches source repository (e.g., "anddea/revanced-patches")
#   $4 - Patches version ("dev", "latest", or specific version)
# Returns: Prints "$cli_jar $patch_jar" on success
get_rv_prebuilts(){
  local cli_src=$1 cli_ver=$2 patch_src=$3 patch_ver=$4
  local cli_jar patch_jar
  
  if [[ "$cli_ver" == "dev" || "$cli_ver" == "latest" ]]; then
    local cli_api="https://api.github.com/repos/${cli_src}/releases/latest"
    local cli_dl; cli_dl=$(gh_req "$cli_api"|jq -r '.assets[]|select(.name|endswith(".jar"))|.browser_download_url'|head -1)
    [[ -z "$cli_dl" ]] && return 1
    cli_jar="$BIN_DIR/revanced-cli-${cli_ver}.jar"
    [[ -f "$cli_jar" ]] || dl_file "$cli_dl" "$cli_jar" || return 1
  else
    cli_jar="$BIN_DIR/revanced-cli-${cli_ver}.jar"
    [[ -f "$cli_jar" ]] || dl_file "https://github.com/${cli_src}/releases/download/v${cli_ver}/revanced-cli-${cli_ver}-all.jar" "$cli_jar" || return 1
  fi
  
  if [[ "$patch_ver" == "dev" || "$patch_ver" == "latest" ]]; then
    local patch_api="https://api.github.com/repos/${patch_src}/releases/latest"
    local patch_dl; patch_dl=$(gh_req "$patch_api"|jq -r '.assets[]|select(.name|endswith(".rvp")|not)|select(.name|endswith(".jar"))|.browser_download_url'|head -1)
    [[ -z "$patch_dl" ]] && return 1
    patch_jar="$BIN_DIR/revanced-patches-${patch_ver}.jar"
    [[ -f "$patch_jar" ]] || dl_file "$patch_dl" "$patch_jar" || return 1
  else
    patch_jar="$BIN_DIR/revanced-patches-${patch_ver}.jar"
    [[ -f "$patch_jar" ]] || dl_file "https://github.com/${patch_src}/releases/download/v${patch_ver}/revanced-patches-${patch_ver}.jar" "$patch_jar" || return 1
  fi
  
  echo "$cli_jar $patch_jar"
}

# ================================================================================
# APK SOURCE DOWNLOADERS
# Download stock APKs from APKMirror, Uptodown, and Archive.org
# Responses are cached in memory to avoid repeated requests
# ================================================================================

declare -A _APKM_RESP _UPD_RESP _ARCH_RESP  # Cache for web responses

# --- APKMirror Functions ---
# Fetch and cache APKMirror response with retry logic
get_apkmirror_resp(){
  local url=$1
  [[ -n "${_APKM_RESP[$url]:-}" ]] && return 0

  local attempt=1 delay=$INITIAL_RETRY_DELAY
  while ((attempt <= MAX_RETRY_ATTEMPTS)); do
    _APKM_RESP[$url]=$(curl -sL --connect-timeout $CONNECTION_TIMEOUT --max-time $REQUEST_TIMEOUT "$url" 2>/dev/null)
    if [[ -n "${_APKM_RESP[$url]}" ]]; then
      return 0
    fi
    if ((attempt < MAX_RETRY_ATTEMPTS)); then
      epr "APKMirror request failed (attempt $attempt/$MAX_RETRY_ATTEMPTS), retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done
  return 1
}
get_apkmirror_pkg_name(){
  grep -oP 'package-name">\K[^<]+' <<<"${_APKM_RESP[$1]//\"/\'}"|head -1
}
get_apkmirror_vers(){
  grep -oP 'All versions.*?</h5>' <<<"${_APKM_RESP[$1]}"|grep -oP '\d+\.\d+\.\d+[^<]*'
}
dl_apkmirror(){
  local base_url=$1 ver=$2 out=$3 arch=$4 dpi=$5
  local vers_url="${base_url}/versions"
  local resp; resp=$(curl -sL "$vers_url")
  local ver_path; ver_path=$(grep -oP "href=\"\K[^\"]*${ver}[^\"]*" <<<"$resp"|head -1)
  [[ -z "$ver_path" ]] && return 1
  local dl_page="https://www.apkmirror.com${ver_path}"
  resp=$(curl -sL "$dl_page")
  local final_url; final_url=$(grep -oP 'href="\K/wp-content/themes/APKMirror/download\.php[^"]+' <<<"$resp"|head -1)
  [[ -z "$final_url" ]] && return 1
  dl_file "https://www.apkmirror.com${final_url}" "$out"
}

# Fetch and cache Uptodown response with retry logic
get_uptodown_resp(){
  local url=$1
  [[ -n "${_UPD_RESP[$url]:-}" ]] && return 0

  local attempt=1 delay=$INITIAL_RETRY_DELAY
  while ((attempt <= MAX_RETRY_ATTEMPTS)); do
    _UPD_RESP[$url]=$(curl -sL --connect-timeout $CONNECTION_TIMEOUT --max-time $REQUEST_TIMEOUT "${url}/versions" 2>/dev/null)
    if [[ -n "${_UPD_RESP[$url]}" ]]; then
      return 0
    fi
    if ((attempt < MAX_RETRY_ATTEMPTS)); then
      epr "Uptodown request failed (attempt $attempt/$MAX_RETRY_ATTEMPTS), retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done
  return 1
}
get_uptodown_pkg_name(){
  grep -oP 'package">\K[^<]+' <<<"${_UPD_RESP[$1]}"|head -1
}
get_uptodown_vers(){
  grep -oP 'data-version="\K[^"]+' <<<"${_UPD_RESP[$1]}"
}
dl_uptodown(){
  local url=$1 ver=$2 out=$3
  local dl; dl=$(curl -sL "${url}/download/${ver}"|grep -oP 'data-url="\K[^"]+')
  [[ -z "$dl" ]] && return 1
  dl_file "$dl" "$out"
}

# Fetch and cache Archive.org response with retry logic
get_archive_resp(){
  local url=$1
  [[ -n "${_ARCH_RESP[$url]:-}" ]] && return 0

  local attempt=1 delay=$INITIAL_RETRY_DELAY
  while ((attempt <= MAX_RETRY_ATTEMPTS)); do
    _ARCH_RESP[$url]=$(curl -sL --connect-timeout $CONNECTION_TIMEOUT --max-time $REQUEST_TIMEOUT "$url" 2>/dev/null)
    if [[ -n "${_ARCH_RESP[$url]}" ]]; then
      return 0
    fi
    if ((attempt < MAX_RETRY_ATTEMPTS)); then
      epr "Archive.org request failed (attempt $attempt/$MAX_RETRY_ATTEMPTS), retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done
  return 1
}
get_archive_pkg_name(){
  basename "$1"|sed 's/^apks\///'
}
get_archive_vers(){
  grep -oP '\d+\.\d+\.\d+[^<]*\.apk' <<<"${_ARCH_RESP[$1]}"|sed 's/\.apk$//'|sort -uV
}
dl_archive(){
  local url=$1 ver=$2 out=$3
  local dl="${url}/${ver}.apk"
  dl_file "$dl" "$out"
}


# ================================================================================
# APK SIGNATURE VERIFICATION
# Verify downloaded APKs against known good signatures in sig.txt
# ================================================================================

# Verify APK signature against known signatures (optional security check)
check_sig(){
  local apk=$1 pkg=$2
  local sig_file="sig.txt"

  # Skip if sig.txt doesn't exist (verification is optional)
  [[ ! -f "$sig_file" ]] && return 0

  # Calculate SHA256 hash of the downloaded APK
  local actual_hash
  if command -v sha256sum &>/dev/null; then
    actual_hash=$(sha256sum "$apk" 2>/dev/null | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual_hash=$(shasum -a 256 "$apk" 2>/dev/null | awk '{print $1}')
  else
    epr "WARNING: No SHA256 tool available, skipping signature verification"
    return 0
  fi

  [[ -z "$actual_hash" ]] && { epr "WARNING: Could not calculate hash for $apk"; return 0; }

  # Look up expected hash from sig.txt
  local expected_hash
  expected_hash=$(grep -E "^[a-f0-9]{64} ${pkg}$" "$sig_file" 2>/dev/null | awk '{print $1}')

  # If no signature found in sig.txt, skip verification
  [[ -z "$expected_hash" ]] && return 0

  # Compare hashes - warn if mismatch but don't fail build
  if [[ "$expected_hash" == "$actual_hash" ]]; then
    pr "✓ Signature verified for $pkg"
    return 0
  else
    epr "⚠️  WARNING: Signature mismatch for $pkg!"
    epr "   Expected: $expected_hash"
    epr "   Actual:   $actual_hash"
    epr "   This may indicate the APK is from a different source or version."
    return 0  # Don't fail - just warn
  fi
}

# ================================================================================
# PATCH MANAGEMENT
# Download and combine patches from multiple sources (RVX, Privacy, etc.)
# ================================================================================

# Combine patches from multiple sources into a single JAR
# Enables using patches from ReVanced Extended + Privacy Patches together
# Args:
#   $1 - Table name (app configuration from config.toml)
#   $2 - Comma-separated patch sources (e.g., "privacy,rvx")
# Side effects: Sets rv_cli_jar and rv_patches_jar variables
# Returns: 0 on success, 1 on failure
get_multi_source_patches(){
  local tbl=$1 cfg=$2
  local -a srcs rvx_jars mid_jars privacy_jars src_keys
  local ps_tbl first_cli
  IFS=',' read -ra srcs <<<"${cfg//[\[\]\" ]/}"
  ps_tbl=$(toml_get_table "PatchSources")||{ epr "PatchSources not found"; return 1; }
  for src in "${srcs[@]}"; do
    [[ -z "$src" ]] && continue
    local st ps_src ps_ver cli_src cli_ver RVP cli ptch
    st=$(toml_get "$ps_tbl" "$src")||{ epr "Unknown patch source: $src"; return 1; }
    ps_src=$(toml_get "$st" source)||{ epr "No source for $src"; return 1; }
    ps_ver=$(toml_get "$st" version)||ps_ver="latest"
    cli_src=$(toml_get "$st" cli-source)||cli_src="ReVanced/revanced-cli"
    cli_ver=$(toml_get "$st" cli-version)||cli_ver="latest"
    RVP=$(get_rv_prebuilts "$cli_src" "$cli_ver" "$ps_src" "$ps_ver")||{ epr "Failed prebuilts for $src"; return 1; }
    read -r cli ptch <<<"$RVP"
    [[ -z "$first_cli" ]] && first_cli=$cli
    if [[ "$src" == "privacy" || "$ps_src" =~ [Pp]rivacy[-_]?revanced ]]; then
      privacy_jars+=("$ptch")
    elif [[ "$ps_src" =~ (revanced|anddea|inotia) ]]; then
      rvx_jars+=("$ptch")
    else
      mid_jars+=("$ptch")
    fi
    src_keys+=("${src}:${ps_src}@${ps_ver}")
  done
  if [[ ${#rvx_jars[@]} -eq 0 && ${#mid_jars[@]} -eq 0 && ${#privacy_jars[@]} -eq 0 ]]; then epr "No patches for $tbl"; return 1; fi
  local key hash; key=$(printf '%s\0' "${src_keys[@]}")
  if command -v sha1sum &>/dev/null; then hash=$(printf '%s' "$key"|sha1sum|awk '{print $1}'); else hash=${key//[^A-Za-z0-9]/-}; fi
  local cache_dir="bin/patchcache"; mkdir -p "$cache_dir" &>/dev/null || :
  local combined="${cache_dir}/combined-${hash}.jar"
  if [[ $(( ${#rvx_jars[@]}+${#mid_jars[@]}+${#privacy_jars[@]} )) -eq 1 ]]; then
    rv_cli_jar=$first_cli
    if [[ ${#rvx_jars[@]} -eq 1 ]]; then rv_patches_jar=${rvx_jars[0]}
    elif [[ ${#mid_jars[@]} -eq 1 ]]; then rv_patches_jar=${mid_jars[0]}
    else rv_patches_jar=${privacy_jars[0]}
    fi
    return 0
  fi
  if [[ -f "$combined" ]]; then rv_cli_jar=$first_cli; rv_patches_jar="$combined"; return 0; fi
  local -a all_jars=("${rvx_jars[@]}" "${mid_jars[@]}" "${privacy_jars[@]}")
  local merge_d="${TEMP_DIR}/patches-${hash}-$$"; mkdir -p "$merge_d"
  for jar in "${all_jars[@]}"; do unzip -qo "$jar" -d "$merge_d" &>/dev/null || :; done
  (cd "$merge_d" && jar cf "$combined" .)&>/dev/null||{ epr "Combine failed"; rm -rf "$merge_d"; return 1; }
  rm -rf "$merge_d"
  rv_cli_jar=$first_cli; rv_patches_jar="$combined"; return 0
}

# ================================================================================
# APK PATCHING AND OPTIMIZATION
# Core functions for applying patches and optimizing final APKs
# ================================================================================

# Apply ReVanced patches to a stock APK
# This is the main patching function - calls ReVanced CLI with all options
# Args:
#   $1 - Stock APK file path (unmodified from APKMirror/etc)
#   $2 - Output patched APK file path
#   $3 - Additional patcher arguments string (patches to include/exclude)
#   $4 - ReVanced CLI JAR path
#   $5 - ReVanced patches JAR path
# Returns: 0 on success, 1 on failure
patch_apk(){
  local stock=$1 out=$2 args_str=$3 cli=$4 ptch=$5
  local -a cmd=(java ${JVM_OPTS:-} -jar "$cli" patch -b "$ptch" -o "$out")

  # Add keystore for proper signing if it exists
  if [[ -f "ks.keystore" ]]; then
    cmd+=(--keystore "ks.keystore")
  fi

  # Add options.json for patch configuration if it exists
  if [[ -f "options.json" ]]; then
    cmd+=(--options "options.json")
  fi

  # Add purge flag to remove unnecessary files from patched APK
  cmd+=(--purge)

  eval "cmd+=($args_str)"
  cmd+=("$stock")
  "${cmd[@]}" 2>&1||return 1
  return 0
}

# Optimize APK by stripping unwanted resources (languages, densities) and compressing
# This reduces APK size by removing resources for unused languages and screen densities,
# removing unnecessary files, and recompressing with maximum compression
# Args:
#   $1 - Input APK file path
#   $2 - Output optimized APK file path
#   $3 - TOML table reference for optimization settings
# Returns: 0 on success, 1 on failure (falls back to copying input)
optimize_apk(){
  local inp=$1 out=$2 tbl=$3
  local opt_en opt_lang opt_dens use_za tmpd comp_level
  tmpd="${TEMP_DIR}/opt-$$"
  opt_en=$(toml_get "$tbl" optimize-apk)||opt_en=false
  if [[ "$opt_en" != true ]]; then cp -f "$inp" "$out"; return 0; fi

  opt_lang=$(toml_get "$tbl" optimize-languages)||opt_lang=""
  opt_dens=$(toml_get "$tbl" optimize-densities)||opt_dens=""
  use_za=$(toml_get "$tbl" zipalign)||use_za=true  # Default to true for better performance
  comp_level=$(toml_get "$tbl" compression-level)||comp_level="${COMPRESSION_LEVEL:-9}"

  mkdir -p "$tmpd"
  pr "  Optimizing APK: stripping resources and recompressing..."
  unzip -q "$inp" -d "$tmpd" &>/dev/null||{ rm -rf "$tmpd"; cp -f "$inp" "$out"; return 1; }

  # Remove language-specific resources (keep only specified languages)
  if [[ -n "$opt_lang" ]]; then
    local removed_langs=0
    while read -r d; do
      local keep=false
      for lang in ${opt_lang//,/ }; do
        [[ "$d" =~ values-${lang}$ || "$d" =~ values$ ]] && { keep=true; break; }
      done
      if [[ "$keep" = false ]]; then
        rm -rf "$d"
        ((removed_langs++))
      fi
    done < <(find "$tmpd/res" -type d -name "values-*" 2>/dev/null)
    [[ $removed_langs -gt 0 ]] && pr "    Removed $removed_langs language resource directories"
  fi

  # Remove density-specific resources (keep only specified densities)
  if [[ -n "$opt_dens" ]]; then
    local -a keepdens; IFS=',' read -ra keepdens <<<"$opt_dens"
    local removed_dens=0
    while read -r d; do
      local base keep=false; base=$(basename "$d")
      for den in "${keepdens[@]}"; do
        [[ "$base" == *"$den"* || "$base" =~ ^(drawable|mipmap)$ ]] && { keep=true; break; }
      done
      if [[ "$keep" = false ]]; then
        rm -rf "$d"
        ((removed_dens++))
      fi
    done < <(find "$tmpd/res" -type d \( -name "drawable-*" -o -name "mipmap-*" \) 2>/dev/null)
    [[ $removed_dens -gt 0 ]] && pr "    Removed $removed_dens density resource directories"
  fi

  # Remove unnecessary files to reduce APK size
  find "$tmpd" -type f \( -name "*.kotlin_*" -o -name "*.version" -o -name "*.properties" \) -delete 2>/dev/null

  # Recompress with maximum compression for smaller APK size
  (cd "$tmpd" && zip -q -r -"$comp_level" "$out" .)||{ rm -rf "$tmpd"; cp -f "$inp" "$out"; return 1; }
  rm -rf "$tmpd"

  # Zipalign for optimal performance (aligns data on 4-byte boundaries)
  if [[ "$use_za" = true ]]; then
    local aligned="${out}.aligned"
    if command -v zipalign &>/dev/null; then
      zipalign -f 4 "$out" "$aligned" &>/dev/null && mv -f "$aligned" "$out" && pr "    Zipaligned APK (4-byte alignment)"
    elif [[ -x "bin/aapt2/aapt2-$(uname -m)" ]]; then
      # Fallback: use aapt2 if available (not ideal but better than nothing)
      pr "    Note: zipalign not available, APK alignment skipped"
    fi
  fi

  # Report optimization results
  local orig_size opt_size reduction
  orig_size=$(stat -c%s "$inp" 2>/dev/null || stat -f%z "$inp" 2>/dev/null || echo "0")
  opt_size=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out" 2>/dev/null || echo "0")
  if [[ $orig_size -gt 0 && $opt_size -gt 0 && $opt_size -lt $orig_size ]]; then
    reduction=$(( (orig_size - opt_size) * 100 / orig_size ))
    pr "    APK size: $(numfmt --to=iec $orig_size 2>/dev/null || echo "${orig_size}B") → $(numfmt --to=iec $opt_size 2>/dev/null || echo "${opt_size}B") (${reduction}% smaller)"
  fi

  return 0
}

# ================================================================================
# BUILD HELPER FUNCTIONS
# Extracted from build_rv() for better modularity and testability
# ================================================================================

# Resolve the target APK version based on configuration and available patches
# Args:
#   $1 - Version mode (auto, latest, beta, or specific version)
#   $2 - Package name
#   $3 - CLI JAR path
#   $4 - Patches JAR path
#   $5 - Download source (apkmirror, uptodown, archive)
#   $6 - Download source URL
# Returns: Prints resolved version on stdout, returns 0 on success
resolve_app_version(){
  local version_mode=$1 pkg_name=$2 cli=$3 ptch=$4 dl_from=$5 dl_url=$6
  local version="" get_latest_ver=false

  # List available patches for this package
  local list_patches
  list_patches=$(java ${JVM_OPTS:-} -jar "$cli" list-patches "$ptch" -f "$pkg_name" -v -p 2>&1)||{
    epr "Failed to list patches for $pkg_name"
    return 1
  }

  # Determine version based on mode
  if [[ "$version_mode" = auto ]]; then
    # Auto mode: use highest compatible version from patches
    version=$(grep -oP 'Compatible.*?to \K[\d.]+' <<<"$list_patches"|get_highest_ver)||get_latest_ver=true
  elif [[ "$version_mode" =~ ^(latest|beta)$ ]]; then
    # Latest/beta mode: use newest available version
    get_latest_ver=true
  else
    # Specific version requested
    version=$version_mode
  fi

  # Fetch latest version from download source if needed
  if [[ $get_latest_ver = true ]]; then
    local pkgvers; pkgvers=$(get_"${dl_from}"_vers "$dl_url")||{
      epr "Failed to get versions from $dl_from"
      return 1
    }
    version=$(get_highest_ver <<<"$pkgvers")||version=$(head -1 <<<"$pkgvers")
  fi

  [[ -z "$version" ]] && { epr "Could not resolve version for package $pkg_name"; return 1; }
  echo "$version"
}

# Download stock APK from configured sources with fallback
# Args:
#   $1 - Table name (for logging)
#   $2 - Package name
#   $3 - Version to download
#   $4 - Architecture
#   $5 - DPI
#   $6 - Output APK path
#   $7 - Space-separated list of tried download sources
# Plus associative array passed via reference with download URLs
# Returns: 0 on success, 1 on failure
download_stock_apk(){
  local table=$1 pkg_name=$2 version=$3 arch=$4 dpi=$5 stock_apk=$6 tried_dl=$7
  shift 7
  # Remaining args should be key=value pairs for download URLs
  declare -A dl_urls
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    dl_urls[$key]="$val"
    shift
  done

  # Try each download source
  for dl_p in archive apkmirror uptodown; do
    [[ -z "${dl_urls[${dl_p}_dlurl]:-}" ]] && continue
    pr "Downloading '$table' from ${dl_p}"

    # Ensure response is cached
    if ! isoneof "$dl_p" $tried_dl; then
      get_${dl_p}_resp "${dl_urls[${dl_p}_dlurl]}"||continue
    fi

    # Attempt download
    if dl_${dl_p} "${dl_urls[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "$dpi"; then
      return 0
    else
      epr "ERROR: Could not download '$table' from ${dl_p} with version '$version', arch '$arch', dpi '$dpi'"
    fi
  done

  return 1
}

# Build patch arguments string based on configuration
# Args:
#   $1 - Excluded patches (space-separated, quoted)
#   $2 - Included patches (space-separated, quoted)
#   $3 - Exclusive patches flag (true/false)
#   $4 - Additional patcher arguments
#   $5 - Microg patch name (optional, auto-detected)
#   $6 - Version mode (to determine if -f flag needed)
#   $7 - Riplib flag (true/false)
#   $8 - Architecture (for riplib)
# Returns: Prints patch arguments string on stdout
setup_patch_arguments(){
  local excluded=$1 included=$2 exclusive=$3 patcher_args=$4 microg_patch=$5 version_mode=$6 riplib=$7 arch=$8
  local PP=""

  # Add excluded/included patches
  [[ -n "$excluded" ]] && PP+=" $(join_args "$excluded" -d)"
  [[ -n "$included" ]] && PP+=" $(join_args "$included" -e)"
  [[ "$exclusive" = true ]] && PP+=" --exclusive"

  # Add version compatibility flag for latest/beta/specific versions
  [[ "$version_mode" =~ ^(latest|beta)$ || "$version_mode" != "auto" ]] && PP+=" -f"

  # Auto-enable MicroG patch if available
  [[ -n "$microg_patch" ]] && PP+=" -e '$microg_patch'"

  # Add custom patcher arguments
  [[ -n "$patcher_args" ]] && PP+=" $patcher_args"

  # Rip unnecessary libraries to reduce APK size
  if [[ "$riplib" = true ]]; then
    PP+=" --rip-lib x86_64 --rip-lib x86"
    [[ "$arch" = "arm64-v8a" ]] && PP+=" --rip-lib armeabi-v7a"
    [[ "$arch" = "arm-v7a" ]] && PP+=" --rip-lib arm64-v8a"
  fi

  echo "$PP"
}

# Helper function to check if value is in array
isoneof(){
  local needle=$1; shift
  for item in "$@"; do
    [[ "$item" = "$needle" ]] && return 0
  done
  return 1
}

# ================================================================================
# MAIN BUILD ORCHESTRATION
# Coordinates the entire build process for a single app
# ================================================================================

# Main build function - orchestrates the entire APK patching process
# This is the top-level function called for each app in config.toml
#
# Build Process:
#   1. Deserialize build config from JSON
#   2. Download ReVanced CLI and patches from GitHub
#   3. Determine target APK version (auto-detect or use specified)
#   4. Download stock APK from APKMirror/Uptodown/Archive.org
#   5. Verify APK signature (optional)
#   6. Apply ReVanced patches with configured options
#   7. Optimize APK (strip resources, compress, zipalign)
#   8. Move final APK to build/ directory
#
# Args:
#   $1 - JSON string containing build configuration
# Returns: 0 on success or graceful skip, non-zero on fatal error
build_rv(){
  # Safely deserialize arguments from JSON instead of using eval
  local json_args="$1"
  declare -A args
  deserialize_array "$json_args" args
  local version="" pkg_name=""
  local version_mode=${args[version]}
  local app_name=${args[app_name]}
  local app_name_l=${app_name,,}; app_name_l=${app_name_l// /-}
  local table=${args[table]}
  local dl_from=${args[dl_from]}
  local arch=${args[arch]}
  local arch_f="${arch// /}"

  local t; t=$(toml_get_table "$table")||return 1

  local PP=""
  [[ "${args[excluded_patches]}" ]] && PP+=" $(join_args "${args[excluded_patches]}" -d)"
  [[ "${args[included_patches]}" ]] && PP+=" $(join_args "${args[included_patches]}" -e)"
  [[ "${args[exclusive_patches]}" = true ]] && PP+=" --exclusive"

  local tried_dl=()
  for dl_p in archive apkmirror uptodown; do
    [[ -z "${args[${dl_p}_dlurl]}" ]] && continue
    if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"||! pkg_name=$(get_"${dl_p}"_pkg_name "${args[${dl_p}_dlurl]}"); then
      args[${dl_p}_dlurl]=""; epr "ERROR: Could not find ${table} in ${dl_p}"; continue
    fi
    tried_dl+=("$dl_p"); dl_from=$dl_p; break
  done
  [[ -z "$pkg_name" ]] && { epr "Empty package name, not building ${table}."; return 0; }

  local patch_sources_cfg rv_cli_jar rv_patches_jar
  patch_sources_cfg=$(toml_get "$t" "patch-sources")||patch_sources_cfg=""
  if [[ -z "$patch_sources_cfg" ]]; then
    local patches_src cli_src patches_ver cli_ver RVP
    patches_src=$(toml_get "$t" patches-source)||patches_src=$DEF_PATCHES_SRC
    patches_ver=$(toml_get "$t" patches-version)||patches_ver=$DEF_PATCHES_VER
    cli_src=$(toml_get "$t" cli-source)||cli_src=$DEF_CLI_SRC
    cli_ver=$(toml_get "$t" cli-version)||cli_ver=$DEF_CLI_VER
    RVP="$(get_rv_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")"||{ epr "Could not download ReVanced prebuilts"; return 1; }
    read -r rv_cli_jar rv_patches_jar <<<"$RVP"
  else
    get_multi_source_patches "$table" "$patch_sources_cfg"||{ epr "Failed to get patches from multiple sources for $table"; return 1; }
  fi

  local list_patches
  list_patches=$(java ${JVM_OPTS:-} -jar "$rv_cli_jar" list-patches "$rv_patches_jar" -f "$pkg_name" -v -p 2>&1)||{ epr "Failed to list patches for $pkg_name"; return 1; }

  local get_latest_ver=false
  if [[ "$version_mode" = auto ]]; then
    version=$(grep -oP 'Compatible.*?to \K[\d.]+' <<<"$list_patches"|get_highest_ver)||get_latest_ver=true
  elif [[ "$version_mode" =~ ^(latest|beta)$ ]]; then
    get_latest_ver=true; PP+=" -f"
  else
    version=$version_mode; PP+=" -f"
  fi

  if [[ $get_latest_ver = true ]]; then
    local pkgvers; pkgvers=$(get_"${dl_from}"_vers "${args[${dl_from}_dlurl]}")||{ epr "Failed to get versions from $dl_from"; return 1; }
    version=$(get_highest_ver <<<"$pkgvers")||version=$(head -1 <<<"$pkgvers")
  fi
  [[ -z "$version" ]] && { epr "Empty version, not building ${table}."; return 0; }

  pr "Choosing version '${version}' for ${table}"
  local version_f=${version// /}; version_f=${version_f#v}

  local cache_apk=false use_cached=false
  cache_apk=$(toml_get "$t" "cache-apk")||cache_apk="false"

  local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
  if [[ "$cache_apk" = "true" && -f "$stock_apk" ]]; then
    pr "Using cached APK for $table version $version"; use_cached=true
  else
    for dl_p in archive apkmirror uptodown; do
      [[ -z "${args[${dl_p}_dlurl]}" ]] && continue
      pr "Downloading '${table}' from ${dl_p}"
      if ! isoneof "$dl_p" "${tried_dl[@]}"; then get_${dl_p}_resp "${args[${dl_p}_dlurl]}"||continue; fi
      if dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}"; then break
      else epr "ERROR: Could not download '${table}' from ${dl_p} with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
      fi
    done
    [[ ! -f "$stock_apk" ]] && return 0
  fi

  if [[ "$use_cached" = false ]]; then
    check_sig "$stock_apk" "$pkg_name" 2>&1||:
  fi

  log "🟢 » ${table}: \`${version}\`"

  local microg_patch
  microg_patch=$(grep "^Name: " <<<"$list_patches"|grep -i "gmscore\|microg"||:)
  microg_patch=${microg_patch#*: }
  [[ -n "$microg_patch" ]] && PP+=" -e '$microg_patch'"

  local rv_brand_f=${args[rv_brand],,}; rv_brand_f=${rv_brand_f// /-}
  [[ "${args[patcher_args]}" ]] && PP+=" ${args[patcher_args]}"

  pr "Building '${table}' in APK mode"
  local patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"

  local riplib; riplib=$(toml_get "$t" riplib)||riplib=false
  if [[ "$riplib" = true ]]; then
    PP+=" --rip-lib x86_64 --rip-lib x86"
    [[ "$arch" = "arm64-v8a" ]] && PP+=" --rip-lib armeabi-v7a"
    [[ "$arch" = "arm-v7a" ]] && PP+=" --rip-lib arm64-v8a"
  fi

  if [[ "${NORB:-}" != true || ! -f "$patched_apk" ]]; then
    if ! patch_apk "$stock_apk" "$patched_apk" "$PP" "$rv_cli_jar" "$rv_patches_jar"; then epr "Building '${table}' failed!"; return 0; fi
  fi

  local optimized_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-opt.apk"
  optimize_apk "$patched_apk" "$optimized_apk" "$t"||{ epr "Optimization failed for ${table}, using unoptimized APK"; optimized_apk="$patched_apk"; }

  local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
  mv -f "$optimized_apk" "$apk_output"
  pr "Built ${table} (APK): '${apk_output}'"
  return 0
}
