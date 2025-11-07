#!/usr/bin/env bash
# ReVanced APK Builder - Utility Functions
# This file contains core utilities for building ReVanced APKs:
# - TOML configuration parsing
# - APK downloading from multiple sources (APKMirror, Uptodown, Archive.org)
# - Patch application and APK optimization
# - Network operations with retry logic
# - Input validation and error handling

declare -F abort &>/dev/null || abort(){ echo "ABORT: $*" >&2; exit 1; }
declare -F epr &>/dev/null || epr(){ echo -e "$*" >&2; }
declare -F pr &>/dev/null || pr(){ echo -e "$*"; }
declare -F log &>/dev/null || log(){ echo -e "$*" >> build.md 2>/dev/null || :; }
declare -F isoneof &>/dev/null || isoneof(){ local t=$1; shift; for x in "$@"; do [[ "$t" == "$x" ]] && return 0; done; return 1; }

# Input validation functions
validate_patch_name(){
  local name=$1
  # Allow alphanumeric, spaces, hyphens, underscores, dots, and parentheses
  if [[ ! "$name" =~ ^[a-zA-Z0-9' ._()'-]+$ ]]; then
    epr "ERROR: Invalid patch name: '$name'. Only alphanumeric characters, spaces, dots, hyphens, underscores, and parentheses are allowed."
    return 1
  fi
  return 0
}

validate_version(){
  local ver=$1
  # Allow semantic versioning, 'auto', 'latest', or 'beta'
  if [[ "$ver" =~ ^(auto|latest|beta)$ ]] || [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-][a-zA-Z0-9]+)?$ ]]; then
    return 0
  fi
  epr "ERROR: Invalid version format: '$ver'. Use 'auto', 'latest', 'beta', or semantic versioning (e.g., 1.2.3)"
  return 1
}

validate_arch(){
  local arch=$1
  if isoneof "$arch" "all" "both" "arm64-v8a" "arm-v7a"; then
    return 0
  fi
  epr "ERROR: Invalid architecture: '$arch'. Must be one of: all, both, arm64-v8a, arm-v7a"
  return 1
}

validate_dpi(){
  local dpi=$1
  # Allow nodpi, or numeric values, or common DPI values
  if [[ "$dpi" == "nodpi" ]] || [[ "$dpi" =~ ^[0-9]+$ ]] || isoneof "$dpi" "ldpi" "mdpi" "hdpi" "xhdpi" "xxhdpi" "xxxhdpi"; then
    return 0
  fi
  epr "WARNING: Unusual DPI value: '$dpi'. Common values: nodpi, ldpi, mdpi, hdpi, xhdpi, xxhdpi, xxxhdpi, or numeric."
  return 0  # Don't fail, just warn
}

declare -F set_prebuilts &>/dev/null || set_prebuilts(){
  export TEMP_DIR="${TEMP_DIR:-temp}"
  export BUILD_DIR="${BUILD_DIR:-build}"
  export LOG_DIR="${LOG_DIR:-logs}"
  export BIN_DIR="${BIN_DIR:-bin}"
  mkdir -p "$TEMP_DIR" "$BUILD_DIR" "$LOG_DIR" "$BIN_DIR" "$BIN_DIR/patchcache" &>/dev/null || :
  export OS="${OS:-$(uname -s)}"
  export ARCH="${ARCH:-$(uname -m)}"
  local _default="-Dfile.encoding=UTF-8"
  export JVM_OPTS="${JVM_OPTS:-${JAVA_OPTS:-$_default}}"
  [[ ":$PATH:" == *":$BIN_DIR:"* ]] || export PATH="$BIN_DIR:$PATH"
}

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
  local file=${1:-config.toml}
  [[ -f "$file" ]] || return 1
  mkdir -p "$TEMP_DIR" &>/dev/null || :
  local out="$TEMP_DIR/config.json"
  if ! _toml_to_json_with_tq "$file" "$out"; then
    _toml_to_json_with_python "$file" "$out" || { epr "TOML parser unavailable"; return 1; }
  fi
  export TOML_JSON="$out"
  [[ -s "$TOML_JSON" ]]
}
toml_get_table_main(){ echo "."; }
toml_get_table(){ local n=$1; printf '.%s' "${n//./\\.}"; }
toml_get_table_names(){ jq -r 'to_entries|map(select(.value|type=="object"))|.[].key' "$TOML_JSON"; }
toml_get(){
  local tbl=$1 key=$2 v
  v=$(jq -r "${tbl}|.[\"$key\"]//empty" "$TOML_JSON")
  [[ -n "$v" ]] || return 1
  echo "$v"
}
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
get_highest_ver(){ sort -V|tail -n1; }

# GitHub API request with retry logic
gh_req(){
  local url=$1
  local max_attempts=3 attempt=1 delay=2

  # Warn if GITHUB_TOKEN is not set
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    epr "WARNING: GITHUB_TOKEN not set. API rate limit: 60 requests/hour (vs 5000 with token)"
  fi

  while ((attempt <= max_attempts)); do
    local response
    response=$(curl -sL -H "Authorization: token ${GITHUB_TOKEN:-}" "$url" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 && -n "$response" ]]; then
      echo "$response"
      return 0
    fi

    if ((attempt < max_attempts)); then
      epr "GitHub request failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done

  epr "ERROR: GitHub request failed after $max_attempts attempts: $url"
  return 1
}

# Download file with retry logic and exponential backoff
dl_file(){
  local url=$1 out=$2
  local max_attempts=3 attempt=1 delay=2

  while ((attempt <= max_attempts)); do
    if curl -fSL --connect-timeout 30 --max-time 300 -o "$out" "$url" 2>/dev/null; then
      # Verify file was actually downloaded and has content
      if [[ -f "$out" && -s "$out" ]]; then
        return 0
      fi
    fi

    if ((attempt < max_attempts)); then
      epr "Download failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done

  epr "ERROR: Failed to download after $max_attempts attempts: $url"
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

declare -A _APKM_RESP _UPD_RESP _ARCH_RESP

# Fetch and cache APKMirror response with retry logic
get_apkmirror_resp(){
  local url=$1
  [[ -n "${_APKM_RESP[$url]:-}" ]] && return 0

  local max_attempts=3 attempt=1 delay=2
  while ((attempt <= max_attempts)); do
    _APKM_RESP[$url]=$(curl -sL --connect-timeout 30 --max-time 60 "$url" 2>/dev/null)
    if [[ -n "${_APKM_RESP[$url]}" ]]; then
      return 0
    fi
    if ((attempt < max_attempts)); then
      epr "APKMirror request failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
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

  local max_attempts=3 attempt=1 delay=2
  while ((attempt <= max_attempts)); do
    _UPD_RESP[$url]=$(curl -sL --connect-timeout 30 --max-time 60 "${url}/versions" 2>/dev/null)
    if [[ -n "${_UPD_RESP[$url]}" ]]; then
      return 0
    fi
    if ((attempt < max_attempts)); then
      epr "Uptodown request failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
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

  local max_attempts=3 attempt=1 delay=2
  while ((attempt <= max_attempts)); do
    _ARCH_RESP[$url]=$(curl -sL --connect-timeout 30 --max-time 60 "$url" 2>/dev/null)
    if [[ -n "${_ARCH_RESP[$url]}" ]]; then
      return 0
    fi
    if ((attempt < max_attempts)); then
      epr "Archive.org request failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
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

# Verify APK signature against known signatures in sig.txt
check_sig(){
  local apk=$1 pkg=$2
  local sig_file="sig.txt"

  # Skip if sig.txt doesn't exist
  [[ ! -f "$sig_file" ]] && return 0

  # Calculate SHA256 hash of the APK
  local actual_hash
  if command -v sha256sum &>/dev/null; then
    actual_hash=$(sha256sum "$apk" 2>/dev/null | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual_hash=$(shasum -a 256 "$apk" 2>/dev/null | awk '{print $1}')
  else
    epr "WARNING: No SHA256 tool available (sha256sum/shasum), skipping signature verification"
    return 0
  fi

  [[ -z "$actual_hash" ]] && { epr "WARNING: Could not calculate hash for $apk"; return 0; }

  # Look up expected hash from sig.txt
  local expected_hash
  expected_hash=$(grep -E "^[a-f0-9]{64} ${pkg}$" "$sig_file" 2>/dev/null | awk '{print $1}')

  # If no signature found in sig.txt, skip verification
  [[ -z "$expected_hash" ]] && return 0

  # Compare hashes
  if [[ "$expected_hash" == "$actual_hash" ]]; then
    pr "✓ Signature verified for $pkg"
    return 0
  else
    epr "⚠️  WARNING: Signature mismatch for $pkg!"
    epr "   Expected: $expected_hash"
    epr "   Actual:   $actual_hash"
    epr "   This may indicate the APK has been modified or is from a different source."
    # Don't fail the build, just warn
    return 0
  fi
}

# Combine patches from multiple sources into a single JAR
# This enables using patches from ReVanced Extended, Privacy Patches, and others together
# Args:
#   $1 - Table name (app configuration)
#   $2 - Comma-separated patch sources config string
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

# Apply ReVanced patches to a stock APK
# Args:
#   $1 - Stock APK file path
#   $2 - Output patched APK file path
#   $3 - Additional patcher arguments string
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

# Main build function - orchestrates the entire APK patching process
# This function:
#   1. Deserializes build arguments from JSON
#   2. Downloads patches from configured sources
#   3. Determines target APK version (auto-detect or specific)
#   4. Downloads stock APK from APKMirror/Uptodown/Archive.org
#   5. Applies ReVanced patches
#   6. Optimizes the patched APK
#   7. Moves final APK to build directory
# Args:
#   $1 - JSON string containing build configuration (serialized associative array)
# Returns: 0 on success (or graceful skip), non-zero on fatal error
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
