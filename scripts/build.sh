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

# Remove submodule dev files from build
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/.git"*
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/.github"
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/tests"
rm -rf "$BUILD_DIR/${ADDON_NAME}/Libs/Ace3/.luacheckrc"

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
echo "Ready for CurseForge upload"
