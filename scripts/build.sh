#!/bin/bash
# Build script for LazyProf CurseForge release

set -e

# Get version from TOC file
VERSION=$(grep '## Version:' LazyProf.toc | sed 's/## Version: //' | tr -d '\r')
if [ -z "$VERSION" ]; then
    echo "Error: Could not read version from LazyProf.toc"
    exit 1
fi

ADDON_NAME="LazyProf"
ZIP_NAME="${ADDON_NAME}-${VERSION}.zip"
BUILD_DIR="/tmp/claude/${ADDON_NAME}-build"

echo "Building ${ADDON_NAME} v${VERSION}..."

# Ensure submodules are initialized
git submodule update --init --recursive

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/${ADDON_NAME}"

# Copy addon files (only game-relevant directories)
cp -r LazyProf.toc "$BUILD_DIR/${ADDON_NAME}/"
cp -r Core "$BUILD_DIR/${ADDON_NAME}/"
cp -r Modules "$BUILD_DIR/${ADDON_NAME}/"
cp -r Professions "$BUILD_DIR/${ADDON_NAME}/"
cp -r Libs "$BUILD_DIR/${ADDON_NAME}/"
cp icon.tga "$BUILD_DIR/${ADDON_NAME}/"

# Remove submodule dev files from build
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/.git"*
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/.github"
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/tests"
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/.luacheckrc"

rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/CraftLib/.git"*
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/CraftLib/.github"
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/CraftLib/.claude"
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/CraftLib/docs"
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/CraftLib/.luacheckrc"
rm -f "$BUILD_DIR/${ADDON_NAME}/Libs/CraftLib/CLAUDE.md"

# Remove CLAUDE.md from all locations
find "$BUILD_DIR/${ADDON_NAME}" -name "CLAUDE.md" -delete
find "$BUILD_DIR/${ADDON_NAME}" -name ".claude" -type d -exec rm -rf {} + 2>/dev/null || true

# Exclude development files that should never be in release
# (Makefile, README.md, scripts/, docs/, .claude/, .git/, .gitignore are already
# excluded by only copying specific directories above)

# Create zip
cd "$BUILD_DIR"
rm -f "${ZIP_NAME}"
zip -r "${ZIP_NAME}" "${ADDON_NAME}"

# Move to releases folder
cd - > /dev/null
mkdir -p releases
mv "$BUILD_DIR/${ZIP_NAME}" releases/

# Cleanup
rm -rf "$BUILD_DIR"

echo "Created: releases/${ZIP_NAME}"
echo ""
echo "=== Changelog for v${VERSION} ==="
echo ""
# Extract changelog section for this version
awk "/^## \[${VERSION}\]/{found=1; next} /^## \[/{if(found) exit} found{print}" CHANGELOG.md
echo ""
echo "Ready for CurseForge/Wago.io upload"
