#!/bin/sh
#
# update.sh
#
# Uppdaterar kärna/boot-filer och Raspberry Pi-firmware på Alpine Linux
# för Raspberry Pi.
#
#   1. Hämtar senaste alpine-rpi-*.tar.gz och verifierar sha256
#   2. Byter ut boot-filerna (config.txt, cmdline.txt och usercfg.txt behålls)
#   3. Installerar raspberrypi-bootloader-cutdown (RPi-firmware)
#
# Kör som root, helst från /root (inte från boot-partitionen):
#   ./update.sh
#
# Detta är en sammanslagning av update.sh + linuxver.sh.
# Gamla update.sh ligger kvar som update.sh.orig.
#

set -e

[ "$(id -u)" -eq 0 ] || { echo "Kör som root." >&2; exit 1; }

# Hitta boot-partitionen via lbu-konfigurationen
if [ -f /etc/lbu/lbu.conf ]; then
    . /etc/lbu/lbu.conf
fi
LBU_MEDIA="${LBU_MEDIA:-mmcblk0p1}"
BOOT_DIR="/media/$LBU_MEDIA"

ARCH="$(cat /etc/apk/arch)"
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable"

[ -d "$BOOT_DIR" ] || { echo "Hittar inte $BOOT_DIR" >&2; exit 1; }
cd "$BOOT_DIR"

echo "==> Boot-partition: $BOOT_DIR ($ARCH)"
mount -oremount,rw "$BOOT_DIR"
lbu ci

# --- Ladda ner och verifiera innan vi rör något -----------------------------

echo "==> Hämtar release-information..."
wget -q "$BASE_URL/releases/$ARCH/latest-releases.yaml" -O latest-releases.yaml

TAR="$(grep 'alpine-rpi-' latest-releases.yaml | sed -n 's/^ *file: *\(.*\.tar\.gz\)$/\1/p' | head -n 1)"
[ -n "$TAR" ] || { echo "Kunde inte hitta tar-filen i YAML." >&2; exit 1; }

echo "==> Laddar ner $TAR..."
wget "$BASE_URL/releases/$ARCH/$TAR"
wget -q "$BASE_URL/releases/$ARCH/$TAR.sha256"
sha256sum -c "$TAR.sha256"

# --- Byt ut boot-filerna ----------------------------------------------------

for f in config.txt cmdline.txt usercfg.txt; do
    [ -f "$f" ] && cp "$f" "$f.bak"
done

echo "==> Rensar gamla boot-filer..."
for f in *; do
    case "$f" in
        cache|*.apkovl.tar.gz|config.txt|cmdline.txt|usercfg.txt|*.bak|"$TAR"|"$TAR.sha256"|latest-releases.yaml)
            ;;
        *)
            echo "    tar bort: $f"
            rm -rf "$f"
            ;;
    esac
done

echo "==> Packar upp $TAR..."
tar zxf "$TAR"
rm -f "$TAR" "$TAR.sha256" latest-releases.yaml

for f in config.txt cmdline.txt usercfg.txt; do
    [ -f "$f.bak" ] && mv "$f.bak" "$f"
done

# --- Raspberry Pi-firmware --------------------------------------------------

# Paketet installerar i /boot, så boot-partitionen monteras där.
echo "==> Installerar firmware..."
umount /boot 2>/dev/null || true
mkdir -p /boot
mount --bind "$BOOT_DIR" /boot
apk add raspberrypi-bootloader-cutdown
umount /boot
rmdir /boot 2>/dev/null || true

# Låt inte paketet ligga kvar i world (skulle installeras om vid varje uppstart).
sed -i '/^raspberrypi-bootloader/d' /etc/apk/world

lbu ci -dv
sync

echo
echo "Klart! Starta om med: reboot"
