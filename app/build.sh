#!/bin/zsh
# Build Tend.app and install it in ~/Applications.
# Usage: app/build.sh [--no-install]
#
# Source: ~/src/tend/app/build.sh

emulate -L zsh
setopt err_exit no_unset

here=${0:A:h}
build=$here/build
app=$build/Tend.app

rm -rf $app
mkdir -p $app/Contents/MacOS
cp $here/Info.plist $app/Contents/Info.plist
swiftc -parse-as-library -O \
  -target arm64-apple-macos14 \
  -o $app/Contents/MacOS/Tend \
  $here/Tend.swift
codesign --force --sign - $app

if [[ ${1:-} != --no-install ]]; then
  mkdir -p ~/Applications
  pkill -x Tend 2>/dev/null || true
  rm -rf ~/Applications/Tend.app
  cp -R $app ~/Applications/
  open ~/Applications/Tend.app
  print "Installed ~/Applications/Tend.app and opened it."
else
  print "Built $app"
fi
