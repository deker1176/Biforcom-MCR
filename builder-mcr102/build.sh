#!/usr/bin/env bash
set -euo pipefail

OPENWRT_TAG="v25.12.5"
MODEM_FEED_COMMIT="f24a7deea1e627e5a1f176ca8d6c47b6f4bf4a56"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.work}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output}"
JOBS="${JOBS:-$(nproc)}"

rm -rf "$WORK_DIR/openwrt" "$OUT_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

git clone --depth 1 --branch "$OPENWRT_TAG" https://github.com/openwrt/openwrt.git "$WORK_DIR/openwrt"
cd "$WORK_DIR/openwrt"

cp feeds.conf.default feeds.conf
printf '\nsrc-git modem https://github.com/fildunsky/luci-app-5gmodem.git^%s\n' "$MODEM_FEED_COMMIT" >> feeds.conf

./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -f luci-app-5gmodem

# The external 5gmodem repository is only a build-time source. The package is
# now installed as package/feeds/modem/luci-app-5gmodem, so remove the feed
# from feeds.conf before the firmware's APK repository list is generated.
# Otherwise OpenWrt creates an invalid runtime URL such as:
#   .../packages/arm_cortex-a7_neon-vfpv4/modem/packages.adb
sed -i '\|^src-git modem |d' feeds.conf

# The MCR-102 carrier has the onboard Ethernet plus two LAN9514 USB NICs.
python3 - <<'PY'
from pathlib import Path

p = Path('target/linux/sunxi/base-files/etc/board.d/02_network')
s = p.read_text()
needle = '\txunlong,orangepi-r1)\n'
replacement = ('\txunlong,orangepi-zero)\n'
               '\t\tucidef_set_interface_lan "eth0 eth1 eth2"\n'
               '\t\t;;\n' + needle)
if s.count(needle) != 1:
    raise SystemExit('Cannot patch sunxi 02_network: expected Orange Pi context')
p.write_text(s.replace(needle, replacement, 1))
PY

install -m 0644 "$ROOT_DIR/builder-mcr102/kernel/999-mcr102-usb-hosts.patch" \
    target/linux/sunxi/patches-6.12/999-mcr102-usb-hosts.patch

mkdir -p files
cp -a "$ROOT_DIR/builder-mcr102/files/." files/
chmod 0755 files/etc/init.d/mcr102-modems files/etc/uci-defaults/99-mcr102-defaults

cp "$ROOT_DIR/builder-mcr102/config.seed" .config
make defconfig

# Fail early if required packages were not selected.
grep -q '^CONFIG_PACKAGE_luci-app-5gmodem=y$' .config || {
    echo 'ERROR: luci-app-5gmodem was not selected after make defconfig' >&2
    exit 1
}
grep -q '^CONFIG_PACKAGE_openvpn-openssl=y$' .config || {
    echo 'ERROR: openvpn-openssl was not selected after make defconfig' >&2
    exit 1
}
grep -q '^CONFIG_PACKAGE_kmod-tun=y$' .config || {
    echo 'ERROR: kmod-tun was not selected after make defconfig' >&2
    exit 1
}
grep -q '^CONFIG_PACKAGE_kmod-ovpn-backports=y$' .config || {
    echo 'ERROR: kmod-ovpn-backports was not selected after make defconfig' >&2
    exit 1
}

for package in kmod-inet-diag kmod-nft-tproxy; do
    grep -q "^CONFIG_PACKAGE_${package}=y$" .config || {
        echo "ERROR: $package (Podkop dependency) was not selected after make defconfig" >&2
        exit 1
    }
done

make download -j"$JOBS"
make -j"$JOBS" || make -j1 V=s

TARGET_DIR="bin/targets/sunxi/cortexa7"
IMAGE="$(find "$TARGET_DIR" -maxdepth 1 -type f -name '*xunlong_orangepi-zero-squashfs-sdcard.img.gz' | head -n1)"
[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || {
    echo 'ERROR: final Orange Pi Zero sdcard image not found' >&2
    exit 1
}

OUT_IMAGE="$OUT_DIR/openwrt-25.12.5-biforcom-mcr102-squashfs-sdcard.img.gz"
cp "$IMAGE" "$OUT_IMAGE"
sha256sum "$OUT_IMAGE" | tee "$OUT_DIR/SHA256SUMS"
cp .config "$OUT_DIR/openwrt-25.12.5-mcr102.config"

printf '\nBuilt: %s\n' "$OUT_IMAGE"
