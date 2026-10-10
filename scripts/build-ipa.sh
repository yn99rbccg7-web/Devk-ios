#!/bin/bash
# build-ipa.sh — archive, dev-sign, and export a sideloadable .ipa + install manifest.
# Usage: ./scripts/build-ipa.sh <TEAM_ID> [BUNDLE_ID] [DEVICE_UDID]
#   TEAM_ID   — from the Apple ID's developer team (Xcode > Settings > Accounts,
#               or https://developer.apple.com/account — free accounts have one too)
#   BUNDLE_ID — must be unique to the signer; default com.deck.Deck
#   DEVICE_UDID is only needed if you want to pre-register it; Xcode handles
#   device registration automatically when the phone is connected/paired.
set -euo pipefail

TEAM_ID="${1:?Pass TEAM_ID as first arg}"
BUNDLE_ID="${2:-com.deck.Deck}"
OUT="build"

echo "==> Bundle ID: $BUNDLE_ID | Team: $TEAM_ID"

# Stamp the unique bundle id + team into the project (idempotent via backup restore)
cp Deck.xcodeproj/project.pbxproj /tmp/project.pbxproj.bak
sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = com\.deck\.Deck;/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;/g" \
    Deck.xcodeproj/project.pbxproj
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID" Deck/Info.plist 2>/dev/null || true

mkdir -p "$OUT"

echo "==> Archiving (Release, generic iOS device)"
xcodebuild \
  -project Deck.xcodeproj \
  -scheme Deck \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT/Deck.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  archive

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>development</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>compileBitcode</key>
	<false/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF

echo "==> Exporting .ipa"
xcodebuild -exportArchive \
  -archivePath "$OUT/Deck.xcarchive" \
  -exportPath "$OUT/ipa" \
  -exportOptionsPlist "$OUT/ExportOptions.plist"

IPA="$OUT/ipa/Deck.ipa"
echo "==> Built: $IPA ($(du -h "$IPA" | cut -f1))"

# itms-services manifest — fill in the public HTTPS URL of the .ipa after hosting.
cat > "$OUT/manifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>__IPA_URL__</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>$BUNDLE_ID</string>
				<key>bundle-version</key>
				<string>1.0</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>Deck</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF

echo "==> Manifest template: $OUT/manifest.plist"
echo "Replace __IPA_URL__ with the public HTTPS URL of Deck.ipa, host both files,"
echo 'then install on the iPhone via: itms-services://?action=download-manifest&url=<manifest-url>'
