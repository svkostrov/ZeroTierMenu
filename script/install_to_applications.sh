#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ZeroTierMenu"
DIST_APP="$ROOT_DIR/dist/$APP_NAME.app"
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"

if [[ ! -d "$DIST_APP" ]]; then
  echo "missing app bundle: $DIST_APP" >&2
  exit 1
fi

rm -rf "$TARGET_APP"
cp -R "$DIST_APP" "$TARGET_DIR/"
rm -rf "$DIST_APP"

echo "installed to $TARGET_APP"
