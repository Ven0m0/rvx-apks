# Enhanced build_rv with multi-source patching and optimization (APK-only)
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
  t=$(toml_get_table "$table")
  
  # Setup patcher args
  local p_patcher_args=()
  if [[ "${args[excluded_patches]}" ]]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
  if [[ "${args[included_patches]}" ]]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
  [[ "${args[exclusive_patches]}" = true ]] && p_patcher_args+=("--exclusive")

  # Download procedures
  local tried_dl=()
  for dl_p in archive apkmirror uptodown; do
    if [[ -z "${args[${dl_p}_dlurl]}" ]]; then continue; fi
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
    epr "empty pkg name, not building ${table}."
    return 0
  fi
  
  # Check for patch sources configuration
  local patch_sources_cfg rv_cli_jar rv_patches_jar
  patch_sources_cfg=$(toml_get "$t" "patch-sources") || patch_sources_cfg=""
  
  if [[ -z "$patch_sources_cfg" ]]; then
    # Standard single source
    local patches_src cli_src patches_ver cli_ver
    patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
    patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
    cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
    cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER
    
    if ! RVP="$(get_rv_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")"; then
      epr "could not download rv prebuilts"
      return 1
    fi
    read -r rv_cli_jar rv_patches_jar <<<"$RVP"
  else
    # Multi-source patching
    if ! get_multi_source_patches "$table" "$patch_sources_cfg"; then
      epr "Failed to get patches from multiple sources for $table"
      return 1
    fi
  fi
  
  # Get patch information
  local list_patches
  list_patches=$(java $JVM_OPTS -jar "$rv_cli_jar" list-patches "$rv_patches_jar" -f "$pkg_name" -v -p 2>&1)

  # Version determination
  local get_latest_ver=false
  if [[ "$version_mode" = auto ]]; then
    if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
      "${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}"); then
      exit 1
    elif [[ -z "$version" ]]; then get_latest_ver=true; fi
  elif isoneof "$version_mode" latest beta; then
    get_latest_ver=true
    p_patcher_args+=("-f")
  else
    version=$version_mode
    p_patcher_args+=("-f")
  fi
  
  if [[ $get_latest_ver = true ]]; then
    if [[ "$version_mode" = beta ]]; then __AAV__="true"; else __AAV__="false"; fi
    pkgvers=$(get_"${dl_from}"_vers)
    version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
  fi
  
  if [[ -z "$version" ]]; then
    epr "empty version, not building ${table}."
    return 0
  fi

  pr "Choosing version '${version}' for ${table}"
  local version_f=${version// /}
  version_f=${version_f#v}
  
  # APK caching support
  local cache_apk use_cached=false
  cache_apk=$(toml_get "$t" "cache-apk") || cache_apk="false"
  vtf "$cache_apk" "cache-apk"
  
  local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
  
  # Use cached APK if available
  if [[ "$cache_apk" = "true" && -f "$stock_apk" ]]; then
    pr "Using cached APK for $table version $version"
    use_cached=true
  else
    # Download stock APK if needed
    for dl_p in archive apkmirror uptodown; do
      if [[ -z "${args[${dl_p}_dlurl]}" ]]; then continue; fi
      pr "Downloading '${table}' from ${dl_p}"
      if ! isoneof $dl_p "${tried_dl[@]}"; then get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; fi
      if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
        epr "ERROR: Could not download '${table}' from ${dl_p} with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
        continue
      fi
      break
    done
    if [[ ! -f "$stock_apk" ]]; then return 0; fi
  fi

  # Check signature
  if ! use_cached; then
    if ! OP=$(check_sig "$stock_apk" "$pkg_name" 2>&1) && ! grep -qFx "ERROR: Missing META-INF/MANIFEST.MF" <<<"$OP"; then
      abort "apk signature mismatch '$stock_apk': $OP"
    fi
  fi
  
  log "🟢 » ${table}: \`${version}\`"

  # Handle microg patch
  local microg_patch
  microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
  if [[ -n "$microg_patch" && ${p_patcher_args[*]} =~ $microg_patch ]]; then
    epr "You cant include/exclude microg patch as that's done automatically."
    p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
  fi

  # Add microg patch for APK builds
  if [[ -n "$microg_patch" ]]; then
    p_patcher_args+=("-e \"${microg_patch}\"")
  fi

  # Add patcher args if provided
  local rv_brand_f=${args[rv_brand],,}
  rv_brand_f=${rv_brand_f// /-}
  if [[ "${args[patcher_args]}" ]]; then p_patcher_args+=("${args[patcher_args]}"); fi

  # APK patching - always build APK regardless of config
  pr "Building '${table}' in APK mode"
  local patched_apk
  patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
  
  # RIP lib options
  if [[ "${args[riplib]}" = true ]]; then
    p_patcher_args+=("--rip-lib x86_64 --rip-lib x86")
    if [[ "$arch" = "arm64-v8a" ]]; then
      p_patcher_args+=("--rip-lib armeabi-v7a")
    elif [[ "$arch" = "arm-v7a" ]]; then
      p_patcher_args+=("--rip-lib arm64-v8a")
    fi
  fi
  
  # Apply patches
  if [[ "${NORB:-}" != true || ! -f "$patched_apk" ]]; then
    if ! patch_apk "$stock_apk" "$patched_apk" "${p_patcher_args[*]}" "$rv_cli_jar" "$rv_patches_jar"; then
      epr "Building '${table}' failed!"
      return 0
    fi
  fi

  # Optimization phase
  local optimized_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-opt.apk"
  optimize_apk "$patched_apk" "$optimized_apk" "$t"

  # Create final output
  local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
  mv -f "$optimized_apk" "$apk_output"
  pr "Built ${table} (APK): '${apk_output}'"
  
  # Clean up combined patches if created
  if [[ -n "$patch_sources_cfg" && "$rv_patches_jar" == "${TEMP_DIR}/combined-"* ]]; then
    rm -f "$rv_patches_jar"
  fi
}
