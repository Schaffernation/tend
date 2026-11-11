#!/bin/zsh
# Draw the README screenshots, docs/screenshot-light.png and -dark.png.
#
# Usage: app/screenshot/make.sh
#
# It renders the real panel (ContentView in app/Tend.swift) offscreen. A
# stand-in for tend, fake-tend, supplies example sessions, so the screenshot
# shows none of your own sessions or folders, and nothing touches tmux. Rerun
# it after you change the panel's design. To change the example sessions,
# edit fake-tend.

emulate -L zsh
setopt err_exit no_unset

here=${0:A:h}
app=$here/../build/Screenshot.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cat > $app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.tend-screenshot</string>
<key>CFBundleExecutable</key><string>Shot</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cp $here/fake-tend $app/Contents/Resources/tend
chmod 755 $app/Contents/Resources/tend

# Tend.swift has its own @main, so compile a copy without it.
sed 's/^@main$//' $here/../Tend.swift > $app/../Tend-for-screenshot.swift
swiftc -parse-as-library -O -o $app/Contents/MacOS/Shot \
  $app/../Tend-for-screenshot.swift $here/Shot.swift
$app/Contents/MacOS/Shot $here/../../docs
