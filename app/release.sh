#!/bin/zsh
# Build, sign, and notarize Tend, and package it as a disk image you can put
# on GitHub Releases. Gatekeeper opens the result on any Mac without a warning.
#
# Usage: app/release.sh
#
# Before the first release, store your notarization credentials in the
# keychain. Use an app-specific password from https://account.apple.com:
#
#   xcrun notarytool store-credentials tend-notary \
#     --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#
# Set TEND_NOTARY_PROFILE to use a different keychain profile name.

emulate -L zsh
setopt err_exit no_unset pipe_fail

here=${0:A:h}
build=$here/build
app=$build/Tend.app
profile=${TEND_NOTARY_PROFILE:-tend-notary}
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $here/Info.plist)
dmg=$build/Tend-$version.dmg

$here/build.sh --no-install --release

# Notarize the app and staple its ticket, so it opens offline after you copy
# it out of the disk image.
print "Notarizing Tend.app…"
ditto -c -k --keepParent $app $build/Tend.zip
xcrun notarytool submit $build/Tend.zip --keychain-profile $profile --wait
xcrun stapler staple $app
rm $build/Tend.zip

# Package the app with a link to /Applications, then sign and notarize the
# disk image too.
print "Building $dmg…"
stage=$build/dmg
rm -rf $stage $dmg
mkdir -p $stage
cp -R $app $stage/
ln -s /Applications $stage/Applications
hdiutil create -volname "Tend $version" -srcfolder $stage -fs HFS+ -format UDZO -ov $dmg
rm -rf $stage
codesign --force --timestamp --sign ${TEND_SIGN_IDENTITY:-"Developer ID Application"} $dmg

print "Notarizing $dmg…"
xcrun notarytool submit $dmg --keychain-profile $profile --wait
xcrun stapler staple $dmg
spctl --assess --type open --context context:primary-signature --verbose=2 $dmg

print
print "Built $dmg"
print "To publish it:"
print "  gh release create v$version $dmg --title 'Tend $version' --generate-notes"
