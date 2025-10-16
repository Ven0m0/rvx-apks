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

  # Check for patch sources configuration with improved variable management
  local patch_sources_cfg rv_cli_jar rv_patches_jar
  patch_sources_cfg=$(toml_get "$t" "patch-sources") || patch_sources_cfg=""

  if [[ -z "$patch_sources_cfg" ]]; then
    # Standard single source with cleaner variable handling
    local patches_src cli_src patches_ver cli_ver
    patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
    patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
    cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
    cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER

    if ! RVP="$(get_rv_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")"; then
      epr "Could not download ReVanced prebuilts"
      return 1
    fi
    read -r rv_cli_jar rv_patches_jar <<<"$RVP"
  else
    # Multi-source patching with better error handling
    if ! get_multi_source_patches "$table" "$patch_sources_cfg"; then
      epr "Failed to get patches from multiple sources for $table"
      return 1
    fi
  fi

  # Improved version determination logic
  local list_patches
  list_patches=$(java $JVM_OPTS -jar "$rv_cli_jar" list-patches "$rv_patches_jar" -f "$pkg_name" -v -p 2>&1) || {
    epr "Failed to list patches for $pkg_name"
    return 1
  }

  # Streamlined version determination
  local get_latest_ver=false
  if [[ "$version_mode" = auto ]]; then
    if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
      "${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}"); then
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

  # Get latest version if needed
  if [[ $get_latest_ver = true ]]; then
    local __AAV__=$([[ "$version_mode" = beta ]] && echo "true" || echo "false")
    local pkgvers
    pkgvers=$(get_"${dl_from}"_vers) || {
      epr "Failed to get versions from $dl_from"
      return 1
    }
    version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
  fi

  if [[ -z "$version" ]]; then
    epr "Empty version, not building ${table}."
    return 0
  fi

  pr "Choosing version '${version}' for ${table}"
  local version_f=${version// /}
  version_f=${version_f#v}

  # Improved APK caching
  local cache_apk=false use_cached=false
  cache_apk=$(toml_get "$t" "cache-apk") || cache_apk="false"
  vtf "$cache_apk" "cache-apk"

  local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"

  # More robust cached APK handling
  if [[ "$cache_apk" = "true" && -f "$stock_apk" ]]; then
    pr "Using cached APK for $table version $version"
    use_cached=true
  else
    # Streamlined download logic
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

  # Signature check with improved error handling
  if ! use_cached; then
    local OP
    OP=$(check_sig "$stock_apk" "$pkg_name" 2>&1) || {
      if ! grep -qFx "ERROR: Missing META-INF/MANIFEST.MF" <<<"$OP"; then
        abort "APK signature mismatch '$stock_apk': $OP"
      fi
    }
  fi

  log "🟢 » ${table}: \`${version}\`"

  # Cleaner microg patch handling
  local microg_patch
  microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :)
  microg_patch=${microg_patch#*: }

  if [[ -n "$microg_patch" && ${p_patcher_args[*]} =~ $microg_patch ]]; then
    epr "You can't include/exclude microg patch as that's done automatically."
    p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
  fi

  # Add microg patch for APK builds
  [[ -n "$microg_patch" ]] && p_patcher_args+=("-e \"${microg_patch}\"")

  # Add patcher args if provided
  local rv_brand_f=${args[rv_brand],,}
  rv_brand_f=${rv_brand_f// /-}
  [[ "${args[patcher_args]}" ]] && p_patcher_args+=("${args[patcher_args]}")

  # APK patching with clearer logging
  pr "Building '${table}' in APK mode"
  local patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"

  # More efficient RIP lib options
  if [[ "${args[riplib]}" = true ]]; then
    p_patcher_args+=("--rip-lib x86_64 --rip-lib x86")
    [[ "$arch" = "arm64-v8a" ]] && p_patcher_args+=("--rip-lib armeabi-v7a")
    [[ "$arch" = "arm-v7a" ]] && p_patcher_args+=("--rip-lib arm64-v8a")
  fi

  # Apply patches with better error handling
  if [[ "${NORB:-}" != true || ! -f "$patched_apk" ]]; then
    if ! patch_apk "$stock_apk" "$patched_apk" "${p_patcher_args[*]}" "$rv_cli_jar" "$rv_patches_jar"; then
      epr "Building '${table}' failed!"
      return 0
    fi
  fi

  # Optimization phase
  local optimized_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-opt.apk"
  optimize_apk "$patched_apk" "$optimized_apk" "$t" || {
    epr "Optimization failed for ${table}, using unoptimized APK"
    optimized_apk="$patched_apk"
  }

  # Create final output
  local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
  mv -f "$optimized_apk" "$apk_output"
  pr "Built ${table} (APK): '${apk_output}'"

  # Clean up combined patches if created
  [[ -n "$patch_sources_cfg" && "$rv_patches_jar" == "${TEMP_DIR}/combined-"* ]] && rm -f "$rv_patches_jar"

  return 0
}
