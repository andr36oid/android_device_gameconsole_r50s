#!/bin/bash

# Define paths
SOURCE_ZIP="../../../out/target/product/r50s/lineage_r50s-ota-eng.root.zip"
TEMP_DIR="./temp"
OUT_ZIP="lineage_r50s-ota-modified.zip"
UPDATER_SCRIPT="./META-INF/com/google/android/updater-script"

# 1. Clean up and create temp directory
echo "Cleaning up old files and creating $TEMP_DIR..."
rm -rf "$TEMP_DIR"
rm -f "$OUT_ZIP"
mkdir -p "$TEMP_DIR"

# 2. Copy and Unzip
if [ -f "$SOURCE_ZIP" ]; then
    echo "Copying OTA zip..."
    cp "$SOURCE_ZIP" "$TEMP_DIR/"
    cd "$TEMP_DIR"
    unzip -q "$(basename "$SOURCE_ZIP")"
    rm "$(basename "$SOURCE_ZIP")"
else
    echo "Error: Source zip not found at $SOURCE_ZIP"
    exit 1
fi

# 3. Edit updater-script
if [ -f "$UPDATER_SCRIPT" ]; then
    echo "Removing boot.img extraction line from updater-script..."
    # Uses sed to delete any line containing the boot.img package_extract_file command
    sed -i '/package_extract_file("boot.img"/d' "$UPDATER_SCRIPT"
else
    echo "Error: updater-script not found!"
    exit 1
fi

# 4. Remove boot.img
if [ -f "boot.img" ]; then
    echo "Removing boot.img from root..."
    rm boot.img
else
    echo "Warning: boot.img not found in zip root."
fi

# 5. Repackage
echo "Repackaging into $OUT_ZIP..."
# -r for recursive, -y to preserve symbols/links
zip -ry "../$OUT_ZIP" .

cd ..
rm -rf $TEMP_DIR
echo "Done! Modified OTA is at ./$OUT_ZIP"