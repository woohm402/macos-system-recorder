#!/bin/sh
# Builds build/Rec.app; pass --install to copy it into ~/Applications.
set -e
cd "$(dirname "$0")"
rm -rf build/Rec.app
mkdir -p build/Rec.app/Contents/MacOS
cp Info.plist build/Rec.app/Contents/Info.plist
# Explicit target: swiftc otherwise stamps minos from the SDK, which can exceed the running OS
swiftc -O -parse-as-library -target arm64-apple-macos15.0 RecApp.swift -o build/Rec.app/Contents/MacOS/Rec
codesign --force --sign - build/Rec.app
if [ "$1" = "--install" ]; then
  rm -rf ~/Applications/Rec.app
  ditto build/Rec.app ~/Applications/Rec.app
  echo "installed: ~/Applications/Rec.app"
fi
