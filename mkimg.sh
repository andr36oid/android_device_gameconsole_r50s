#!/bin/bash
set -euo pipefail

LINEAGEVERSION=lineage-18.1
DATE=$(date -u +%Y%m%d)
TIME=$(date -u +%H%M)
DEVICE=r50s-android
IMGNAME=$LINEAGEVERSION-$DATE-$TIME-$DEVICE.img
IMGSIZE=3    # GiB
OUTDIR=${ANDROID_PRODUCT_OUT:="../../../out/target/product/r50s"}
TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

if [ "$(id -u)" != 0 ]; then
    echo "Must be root to run script!"
    exit 1
fi

if [ -f "$IMGNAME" ]; then
    echo "File $IMGNAME already exists!"
    exit 1
fi

echo "Copying over kernel files"
cp "$OUTDIR/obj/KERNEL_OBJ/arch/arm64/boot/Image" BOOT/ || true
cp ../common/resizing/prebuilt/Image-resizing BOOT/ || true
cp ../common/resizing/prebuilt/Image-recovery BOOT/ || true
cp "$OUTDIR/obj/KERNEL_OBJ/arch/arm64/boot/dts/rockchip/rk3326-$DEVICE.dtb" BOOT/rk3326-r50s-android.dtb || true

echo "Creating image file $IMGNAME..."
truncate -s "${IMGSIZE}G" "$IMGNAME"
sync

echo "Creating partitions (GPT) on $IMGNAME..."
parted -s "$IMGNAME" mktable gpt
parted -s "$IMGNAME" mkpart BOOT fat32 32768s 1081343s
parted -s "$IMGNAME" mkpart system ext4 1081344s 5701008s
parted -s "$IMGNAME" mkpart idbloader 64s 16383s
parted -s "$IMGNAME" mkpart uboot 16384s 24575s
parted -s "$IMGNAME" mkpart trust 24576s 32767s

dd if=bootloader/idbloader.img of="$IMGNAME" conv=fsync,notrunc bs=512 seek=64
dd if=bootloader/uboot.img of="$IMGNAME" conv=fsync,notrunc bs=512 seek=16384
dd if=bootloader/trust.img of="$IMGNAME" conv=fsync,notrunc bs=512 seek=24576

echo "Partition table:"
parted -s "$IMGNAME" unit s print
sync

p1_start=$(parted -s "$IMGNAME" unit s print | awk '/^ *1[[:space:]]/{gsub(/s/,"",$2); print $2}')
p1_end=$(parted -s "$IMGNAME" unit s print | awk '/^ *1[[:space:]]/{gsub(/s/,"",$3); print $3}')
p2_start=$(parted -s "$IMGNAME" unit s print | awk '/^ *2[[:space:]]/{gsub(/s/,"",$2); print $2}')
p2_end=$(parted -s "$IMGNAME" unit s print | awk '/^ *2[[:space:]]/{gsub(/s/,"",$3); print $3}')

if [ -z "$p1_start" ] || [ -z "$p2_start" ]; then
    echo "Failed to read partition start sectors."
    exit 1
fi

p1_sectors=$((p1_end - p1_start + 1))
p2_sectors=$((p2_end - p2_start + 1))

echo "p1 start: $p1_start sectors ($p1_sectors), p2 start: $p2_start sectors ($p2_sectors)"

BOOT_IMG="$TMPDIR/boot.img"
echo "Creating BOOT filesystem image ($p1_sectors sectors)..."
dd if=/dev/zero of="$BOOT_IMG" bs=512 count="$p1_sectors" status=none

if command -v mkfs.fat >/dev/null 2>&1; then
    MKFS_FAT=mkfs.fat
elif command -v mkfs.vfat >/dev/null 2>&1; then
    MKFS_FAT=mkfs.vfat
elif command -v mkdosfs >/dev/null 2>&1; then
    MKFS_FAT=mkdosfs
else
    echo "No FAT mkfs tool found (mkfs.fat|mkfs.vfat|mkdosfs)."
    exit 1
fi
$MKFS_FAT -F 32 -n BOOT "$BOOT_IMG"

BOOT_TMP="$TMPDIR/BOOT_COPY"
mkdir -p "$BOOT_TMP"
cp -a BOOT/* "$BOOT_TMP"/ || true

if ! command -v mcopy >/dev/null 2>&1; then
    echo "mtools (mcopy) not found. Install mtools."
    exit 1
fi
export MTOOLS_SKIP_CHECK=1

# copy files one-by-one to avoid trying to create '.' or '..' entries
cd "$BOOT_TMP"
shopt -s dotglob nullglob
for f in * .*; do
    [ "$f" = "." ] && continue
    [ "$f" = ".." ] && continue
    # if it's a directory, mcopy -s will copy recursively
    mcopy -s -i "$BOOT_IMG" "$f" ::/ || {
        # fallback: create directory then copy contents
        if [ -d "$f" ]; then
            mmd -i "$BOOT_IMG" ::/"$f" || true
            (cd "$f" && for sub in * .*; do
                [ "$sub" = "." ] && continue
                [ "$sub" = ".." ] && continue
                mcopy -s -i "$BOOT_IMG" "$f/$sub" ::/"$f"/ || true
            done)
        fi
    }
done
cd - >/dev/null

echo "Embedding BOOT filesystem into $IMGNAME at sector $p1_start..."
dd if="$BOOT_IMG" of="$IMGNAME" bs=512 seek="$p1_start" conv=notrunc,fsync status=none

echo "Copying system image into partition 2..."
SYS_SRC="$OUTDIR/system.img"
SYS_RAW="$TMPDIR/system.raw.img"

if [ ! -f "$SYS_SRC" ]; then
    echo "System image not found at $SYS_SRC"
    exit 1
fi

if file "$SYS_SRC" | grep -qi "Android sparse image"; then
    if command -v simg2img >/dev/null 2>&1; then
        simg2img "$SYS_SRC" "$SYS_RAW"
        dd if="$SYS_RAW" of="$IMGNAME" bs=512 seek="$p2_start" conv=notrunc,fsync status=none
    else
        echo "System image is Android sparse and simg2img is not installed."
        exit 1
    fi
else
    dd if="$SYS_SRC" of="$IMGNAME" bs=512 seek="$p2_start" conv=notrunc,fsync status=none
fi

sync
parted -s "$IMGNAME" unit s print

echo "Done, created $IMGNAME!"
rm -rf "$BOOT_IMG" "$BOOT_TMP" "$SYS_RAW"
zip -r -q "$IMGNAME.zip" "$IMGNAME"
echo "Packaged $IMGNAME.zip"
