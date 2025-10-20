#!/usr/bin/env bash

# Combine patches from multiple sources with ReVanced FIRST, then others.
# Exposes (global) rv_cli_jar and rv_patches_jar for the caller (build_rv).
get_multi_source_patches() {
  local tbl=$1 cfg=$2
  local -a srcs rvx_jars other_jars
  local ps_tbl first_cli

  IFS=',' read -ra srcs <<< "${cfg//[\[\]\" ]/}"

  ps_tbl=$(toml_get_table "PatchSources") || { epr "PatchSources table not found"; return 1; }

  for src in "${srcs[@]}"; do
    [[ -z "$src" ]] && continue

    local st ps_src ps_ver cli_src cli_ver RVP cli ptch
    st=$(toml_get "$ps_tbl" "$src") || { epr "Unknown patch source: $src"; return 1; }

    ps_src=$(toml_get "$st" source)      || { epr "No source for $src"; return 1; }
    ps_ver=$(toml_get "$st" version)     || ps_ver="latest"
    cli_src=$(toml_get "$st" cli-source) || cli_src="ReVanced/revanced-cli"
    cli_ver=$(toml_get "$st" cli-version)|| cli_ver="latest"

    RVP=$(get_rv_prebuilts "$cli_src" "$cli_ver" "$ps_src" "$ps_ver") || { epr "Failed getting prebuilts for $src"; return 1; }
    read -r cli ptch <<<"$RVP"
    [[ -z "$first_cli" ]] && first_cli=$cli

    # Treat anything revanced-like as RVX group
    if [[ "$ps_src" =~ (revanced|anddea|inotia) ]]; then
      rvx_jars+=("$ptch")
    else
      other_jars+=("$ptch")
    fi
  done

  if [[ ${#rvx_jars[@]} -eq 0 && ${#other_jars[@]} -eq 0 ]]; then
    epr "No patches found for $tbl"
    return 1
  fi

  local -a all_jars=("${rvx_jars[@]}" "${other_jars[@]}")

  if [[ ${#all_jars[@]} -eq 1 ]]; then
    rv_cli_jar=$first_cli
    rv_patches_jar=${all_jars[0]}
    return 0
  fi

  local combined="${TEMP_DIR}/combined-${tbl//[^a-zA-Z0-9]/-}.jar"
  local merge_d="${TEMP_DIR}/patches-$$"
  mkdir -p "$merge_d"

  for jar in "${all_jars[@]}"; do
    unzip -qo "$jar" -d "$merge_d" &>/dev/null || :
  done

  (cd "$merge_d" && jar cf "$combined" .) &>/dev/null || { epr "Failed combining patches"; rm -rf "$merge_d"; return 1; }
  rm -rf "$merge_d"

  rv_cli_jar=$first_cli
  rv_patches_jar=$combined
  return 0
}

# Patch an APK with ReVanced CLI. Third arg is a string of patcher args.
patch_apk() {
  local stock=$1 out=$2 args_str=$3 cli=$4 ptch=$5
  java ${JVM_OPTS:-} -jar "$cli" patch -b "$ptch" -o "$out" $args_str "$stock" 2>&1 || return 1
  return 0
}

# Optimize an APK by pruning resources and optionally zipalign.
# AAPT2 is not required; we repackage with zip and apply zipalign if available.
optimize_apk() {
  local inp=$1 out=$2 tbl=$3
  local opt_en opt_lang opt_dens use_za
  local tmpd="${TEMP_DIR}/opt-$$"

  opt_en=$(toml_get "$tbl" optimize-apk) || opt_en=false
  if [[ "$opt_en" != true ]]; then
    cp -f "$inp" "$out"
    return 0
  fi

  opt_lang=$(toml_get "$tbl" optimize-languages)  || opt_lang=""
  opt_dens=$(toml_get "$tbl" optimize-densities)  || opt_dens=""
  use_za=$(toml_get "$tbl" zipalign)              || use_za=false

  mkdir -p "$tmpd"
  unzip -q "$inp" -d "$tmpd" &>/dev/null || { rm -rf "$tmpd"; cp -f "$inp" "$out"; return 1; }

  # Language filter (values-xx)
  if [[ -n "$opt_lang" ]]; then
    while read -r d; do
      local keep=false
      for lang in ${opt_lang//,/ }; do
        [[ "$d" =~ values-${lang}$ ]] && { keep=true; break; }
      done
      [[ "$keep" = false ]] && rm -rf "$d"
    done < <(find "$tmpd/res" -type d -name "values-*" 2>/dev/null)
  fi

  # Density filter (drawables/mipmaps etc). Keep only requested densities.
  if [[ -n "$opt_dens" ]]; then
    local -a keepdens
    IFS=',' read -ra keepdens <<<"$opt_dens"
    while read -r d; do
      local base=$(basename "$d")
      local keep=false
      for den in "${keepdens[@]}"; do
        [[ "$base" == *"$den"* ]] && { keep=true; break; }
      done
      [[ "$keep" = false ]] && rm -rf "$d"
    done < <(find "$tmpd/res" -type d \( -name "drawable-*" -o -name "mipmap-*" -o -name "values-*" \) 2>/dev/null)
  fi

  (cd "$tmpd" && zip -qr "$out" .) || { rm -rf "$tmpd"; cp -f "$inp" "$out"; return 1; }
  rm -rf "$tmpd"

  if [[ "$use_za" = true ]] && command -v zipalign &>/dev/null; then
    local aligned="${out}.aligned"
    zipalign -f 4 "$out" "$aligned" &>/dev/null && mv -f "$aligned" "$out"
  fi
  return 0
}

# Main build function (patched to respect multi-source patches and proper arrays).
build_rv() {
  eval "declare -A args=${1#*=}"
  local version="" pkg_name=""
  local version_mode=${args[version]}
  local app_name=${args[app_name]}
  local app_name_l=${app_name,,}
  app_name_l=${app_name_l// /-}
  local table=${args[table]}
  local dl_from=${args[dl_from]}
  local arch=${args[arch]}
  local arch_f="${arch// /}"

  # Get table configuration
  local t
  t=$(toml_get_table "$table") || return 1

  # Setup patcher args as an array for proper handling
  local p_patcher_args=()
  [[ "${args[excluded_patches]}" ]] && p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)")
  [[ "${args[included_patches]}" ]] && p_patcher_args+=("$(join_args "${args[included_patches]}" -e)")
  [[ "${args[exclusive_patches]}" = true ]] && p_patcher_args+=("--exclusive")

  # Download procedures with better error handling
  local tried_dl=()
  for dl_p in archive apkmirror uptodown; do
    [[ -z "${args[${dl_p}_dlurl]}" ]] && continue
    if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
      args[${dl_p}_dlurl]=""
      epr "ERROR: Could not find ${table} in ${dl_p}"
      continue
    fi
    tried_dl+=("$dl_p")
    dl_from=$dl_p
    break
  done

  if [[ -z "$pkg_name" ]]; then
    epr "Empty package name, not building ${table}."
    return 0
  fi

  # Determine patches/cli jars
  local patch_sources_cfg rv_cli_jar rv_patches_jar
  patch_sources_cfg=$(toml_get "$t" "patch-sources") || patch_sources_cfg=""
  if [[ -z "$patch_sources_cfg" ]]; then
    local patches_src cli_src patches_ver cli_ver
    patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
    patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
    cli_src=$(toml_get "$t" cli-source)        || cli_src=$DEF_CLI_SRC
    cli_ver=$(toml_get "$t" cli-version)       || cli_ver=$DEF_CLI_VER
    local RVP
    RVP="$(get_rv_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")" || { epr "Could not download ReVanced prebuilts"; return 1; }
    read -r rv_cli_jar rv_patches_jar <<<"$RVP"
  else
    get_multi_source_patches "$table" "$patch_sources_cfg" || { epr "Failed to get patches from multiple sources for $table"; return 1; }
    # rv_cli_jar and rv_patches_jar set globally by get_multi_source_patches
  fi

  # List patches for version resolution
  local list_patches
  list_patches=$(java $JVM_OPTS -jar "$rv_cli_jar" list-patches "$rv_patches_jar" -f "$pkg_name" -v -p 2>&1) || { epr "Failed to list patches for $pkg_name"; return 1; }

  # Version selection
  local get_latest_ver=false
  if [[ "$version_mode" = auto ]]; then
    if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" "${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}"); then
      return 1
    elif [[ -z "$version" ]]; then
      get_latest_ver=true
    fi
  elif [[ "$version_mode" =~ ^(latest|beta)$ ]]; then
    get_latest_ver=true
    p_patcher_args+=("-f")
  else
    version=$version_mode
    p_patcher_args+=("-f")
  fi

  if [[ $get_latest_ver = true ]]; then
    local __AAV__=$([[ "$version_mode" = beta ]] && echo "true" || echo "false")
    local pkgvers
    pkgvers=$(get_"${dl_from}"_vers) || { epr "Failed to get versions from $dl_from"; return 1; }
    version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
  fi

  if [[ -z "$version" ]]; then
    epr "Empty version, not building ${table}."
    return 0
  fi

  pr "Choosing version '${version}' for ${table}"
  local version_f=${version// /}
  version_f=${version_f#v}

  # APK caching
  local cache_apk=false use_cached=false
  cache_apk=$(toml_get "$t" "cache-apk") || cache_apk="false"
  vtf "$cache_apk" "cache-apk"

  local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"

  if [[ "$cache_apk" = "true" && -f "$stock_apk" ]]; then
    pr "Using cached APK for $table version $version"
    use_cached=true
  else
    for dl_p in archive apkmirror uptodown; do
      [[ -z "${args[${dl_p}_dlurl]}" ]] && continue
      pr "Downloading '${table}' from ${dl_p}"
      if ! isoneof "$dl_p" "${tried_dl[@]}"; then
        get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || continue
      fi
      if dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
        break
      else
        epr "ERROR: Could not download '${table}' from ${dl_p} with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
      fi
    done
    [[ ! -f "$stock_apk" ]] && return 0
  fi

  # Signature check
  if [[ "$use_cached" = false ]]; then
    local OP
    OP=$(check_sig "$stock_apk" "$pkg_name" 2>&1) || {
      if ! grep -qFx "ERROR: Missing META-INF/MANIFEST.MF" <<<"$OP"; then
        abort "APK signature mismatch '$stock_apk': $OP"
      fi
    }
  fi

  log "🟢 » ${table}: \`${version}\`"

  # MicroG / GmsCore patch auto-handling
  local microg_patch
  microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :)
  microg_patch=${microg_patch#*: }
  if [[ -n "$microg_patch" && ${p_patcher_args[*]} =~ $microg_patch ]]; then
    epr "You can't include/exclude microg patch as that's done automatically."
    p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
  fi
  [[ -n "$microg_patch" ]] && p_patcher_args+=("-e" "$microg_patch")

  # Patcher args passthrough
  local rv_brand_f=${args[rv_brand],,}
  rv_brand_f=${rv_brand_f// /-}
  [[ "${args[patcher_args]}" ]] && p_patcher_args+=("${args[patcher_args]}")

  pr "Building '${table}' in APK mode"
  local patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"

  # RIP libs
  if [[ "${args[riplib]}" = true ]]; then
    p_patcher_args+=("--rip-lib" "x86_64" "--rip-lib" "x86")
    [[ "$arch" = "arm64-v8a" ]] && p_patcher_args+=("--rip-lib" "armeabi-v7a")
    [[ "$arch" = "arm-v7a" ]]  && p_patcher_args+=("--rip-lib" "arm64-v8a")
  fi

  # Apply patches
  if [[ "${NORB:-}" != true || ! -f "$patched_apk" ]]; then
    if ! patch_apk "$stock_apk" "$patched_apk" "${p_patcher_args[*]}" "$rv_cli_jar" "$rv_patches_jar"; then
      epr "Building '${table}' failed!"
      return 0
    fi
  fi

  # Optimization
  local optimized_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-opt.apk"
  optimize_apk "$patched_apk" "$optimized_apk" "$t" || { epr "Optimization failed for ${table}, using unoptimized APK"; optimized_apk="$patched_apk"; }

  # Finalize
  local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
  mv -f "$optimized_apk" "$apk_output"
  pr "Built ${table} (APK): '${apk_output}'"

  # Clean up combined jar
  [[ -n "$patch_sources_cfg" && "$rv_patches_jar" == "${TEMP_DIR}/combined-"* ]] && rm -f "$rv_patches_jar"

  return 0
}
