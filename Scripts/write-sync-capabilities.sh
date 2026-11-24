#!/bin/bash
set -eu

# Record the actual build's signing configuration, including Personal Team overrides.
supports=false
entitlements="${CODE_SIGN_ENTITLEMENTS:-}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "$entitlements" ]; then
    case "$entitlements" in
        /*) ;;
        *) entitlements="${SRCROOT}/${entitlements}" ;;
    esac
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.ubiquity-kvstore-identifier' "$entitlements" 2>/dev/null || true)
    if [ -n "$identifier" ]; then supports=true; fi
fi

output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/SyncCapabilities.plist"
mkdir -p "$(dirname "$output")"
cat > "$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>supportsICloudKeyValueStore</key><${supports}/>
</dict></plist>
EOF
