#!/bin/zsh
# Build Tend.app, a universal (Apple silicon and Intel) app with the tend CLI
# inside it, and install it in ~/Applications.
#
# Usage: app/build.sh [--no-install] [--release]
#   --no-install  Build app/build/Tend.app only.
#   --release     Sign with your Developer ID and the hardened runtime, for
#                 notarization. Without it, the build is signed ad hoc, which
#                 runs only on this Mac. release.sh uses this flag.

emulate -L zsh
setopt err_exit no_unset

here=${0:A:h}
build=$here/build
app=$build/Tend.app
install=1 release=0
for arg in "$@"; do
  case $arg in
    --no-install) install=0 ;;
    --release) release=1 ;;
    *) print -u2 "build.sh: unknown option $arg"; exit 2 ;;
  esac
done

rm -rf $app $build/arch
mkdir -p $app/Contents/MacOS $app/Contents/Resources $build/arch
cp $here/Info.plist $app/Contents/Info.plist
cp $here/AppIcon.icns $app/Contents/Resources/AppIcon.icns
cp $here/../bin/tend $app/Contents/Resources/tend
chmod 755 $app/Contents/Resources/tend

for arch in arm64 x86_64; do
  swiftc -parse-as-library -O -warnings-as-errors \
    -target $arch-apple-macos14 \
    -o $build/arch/Tend-$arch \
    $here/Tend.swift
done
lipo -create -output $app/Contents/MacOS/Tend $build/arch/Tend-arm64 $build/arch/Tend-x86_64

if (( release )); then
  identity=${TEND_SIGN_IDENTITY:-"Developer ID Application"}
  codesign --force --options runtime --timestamp \
    --entitlements $here/Tend.entitlements \
    --sign $identity $app
  codesign --verify --strict --verbose=2 $app
else
  codesign --force --sign - $app
fi

if (( install )); then
  mkdir -p ~/Applications
  pkill -x Tend 2>/dev/null || true
  rm -rf ~/Applications/Tend.app
  cp -R $app ~/Applications/
  open ~/Applications/Tend.app
  print "Installed ~/Applications/Tend.app and opened it."
else
  print "Built $app"
fi
