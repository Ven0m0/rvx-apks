# Changelog: Enhanced ReVanced APK Builder

## New Features
- Multi-source patching: Combine patches from different sources in a single APK
- APK optimization with AAPT2 to reduce file size
- Zipalign support for better runtime performance
- Optimized JVM settings for faster builds
- APK caching to avoid redownloading unchanged versions

## Core Improvements
- Added PatchSources configuration section for defining multiple patch repositories
- Implemented smart patch jar combining that handles conflicts appropriately
- Optimized java execution with tuned JVM parameters
- Added AAPT2-based resource optimization with language and density filtering
- Added atomic file operations for safer processing

## Configuration Options
- `patch-sources`: Array of patch sources to combine (e.g. ["rvx", "privacy"])
- `jvm-flags`: Customize JVM optimization parameters
- `optimize-apk`: Enable AAPT2 resource optimization
- `optimize-languages`: Target languages to keep (reduces APK size)
- `optimize-densities`: Target screen densities to keep
- `zipalign`: Apply zipalign for better runtime performance
- `cache-apk`: Cache downloaded APKs to avoid redownloading
