#!/usr/bin/env bash

# Define sources and targets
declare -A files=(
  [lists/native.tiktok.txt]="https://github.com/hagezi/dns-blocklists/blob/main/domains/native.tiktok.txt"
  [lists/Ads]="https://github.com/ShadowWhisperer/BlockLists/blob/master/main/RAW/Ads"
  [lists/Bloat]="https://github.com/ShadowWhisperer/BlockLists/blob/master/RAW/Bloat"
  [lists/AdguardMobileAds.txt]="https://github.com/r-a-y/mobile-hosts/blob/master/AdguardMobileAds.txt"
)

# Fetch each file (atomic, safe, fast)
for target in "${!files[@]}"; do
  url="${files[$target]}"
  tmp="$(mktemp)"
  curl -fsSL "$url" >"$tmp" && mv "$tmp" "$target"
done

# Optional: git commit if changes
git add lists/
if ! git diff --cached --quiet; then
  git -c user.name="sync-bot" -c user.email="sync@localhost" commit -m "chore: update blocklists"
  git push
fi
