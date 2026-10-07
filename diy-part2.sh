#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# 临时解决Rust问题
sed -i 's/ci-llvm=true/ci-llvm=false/g' feeds/packages/lang/rust/Makefile

# add date in output file name
# sed -i -e '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' \
#        -e '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' include/image.mk

# Add Asia/Shanghai build timestamp to output file name
# Format: YYYYMMDDHHMM
sed -i -e '/^IMG_PREFIX:=/i BUILD_DATE := $(shell TZ=Asia/Shanghai date +%Y%m%d%H%M)' \
       -e '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' include/image.mk

# set ubi to 122M
# sed -i 's/reg = <0x5c0000 0x7000000>;/reg = <0x5c0000 0x7a40000>;/' target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts

# ============================================================
# Set default LuCI theme with runtime fallback
#
# Priority:
#   Argon
#   -> Aurora
#   -> Material
#   -> OpenWrt 2020
#   -> OpenWrt classic
#   -> Bootstrap
#
# The actual theme files are checked on first boot, so missing
# themes are skipped automatically instead of leaving LuCI
# pointing to a non-existent theme.
# ============================================================

DEFAULT_THEME_SCRIPT="package/base-files/files/etc/uci-defaults/99-z-default-luci-theme"

mkdir -p "$(dirname "$DEFAULT_THEME_SCRIPT")"

cat > "$DEFAULT_THEME_SCRIPT" <<'EOF'
#!/bin/sh

TAG="default-luci-theme"

log_info() {
    logger -t "$TAG" "$*" 2>/dev/null || true
}

# If UCI or LuCI is unavailable, do nothing.
command -v uci >/dev/null 2>&1 || exit 0
uci -q get luci.main >/dev/null 2>&1 || exit 0

select_theme() {
    theme_path="$1"
    theme_name="$2"

    # Check the actual files in the finished root filesystem,
    # rather than trusting package/UCI registration alone.
    if [ -d "/www${theme_path}" ]; then
        if uci -q set "luci.main.mediaurlbase=${theme_path}" &&
           uci -q commit luci; then
            log_info "Selected LuCI theme: ${theme_name} (${theme_path})"
            return 0
        fi

        log_info "Failed to set LuCI theme: ${theme_name} (${theme_path})"
    fi

    return 1
}

# Preferred theme
select_theme "/luci-static/argon" "Argon" && exit 0

# First fallback
select_theme "/luci-static/aurora" "Aurora" && exit 0

# Second fallback
select_theme "/luci-static/material" "Material" && exit 0

# Additional official fallback
select_theme "/luci-static/openwrt2020" "OpenWrt 2020" && exit 0

# Classic OpenWrt theme
select_theme "/luci-static/openwrt.org" "OpenWrt" && exit 0

# Final stock fallback
select_theme "/luci-static/bootstrap" "Bootstrap" && exit 0

# Extremely defensive fallback:
# if none of the known themes exist, preserve the current LuCI setting
# instead of writing an invalid path.
CURRENT_THEME="$(uci -q get luci.main.mediaurlbase 2>/dev/null || true)"

if [ -n "$CURRENT_THEME" ] && [ -d "/www${CURRENT_THEME}" ]; then
    log_info "No preferred theme found; preserving current valid theme: ${CURRENT_THEME}"
else
    log_info "WARNING: no known usable LuCI theme was found"
fi

exit 0
EOF

chmod 0755 "$DEFAULT_THEME_SCRIPT"

echo "Default LuCI theme fallback script installed:"
echo "  Argon -> Aurora -> Material -> OpenWrt 2020 -> OpenWrt -> Bootstrap"

# ============================================================
# libxcrypt 4.4.36 / fortify-headers compatibility
# Avoid -Werror=format-nonliteral breaking the build.
# ============================================================

LIBXCRYPT_MK="feeds/packages/libs/libxcrypt/Makefile"

if [ -f "$LIBXCRYPT_MK" ]; then
    if grep -q -- '--disable-werror' "$LIBXCRYPT_MK"; then
        echo "OK: libxcrypt already has --disable-werror"
    else
        sed -i \
            '/^include .*package\.mk$/a CONFIGURE_ARGS += --disable-werror' \
            "$LIBXCRYPT_MK"

        echo "OK: libxcrypt compatibility applied: --disable-werror"
    fi
else
    echo "INFO: libxcrypt Makefile not found, compatibility patch skipped"
fi

# ============================================================
# smartmontools local drive database
#
# KIOXIA EXCERIA PLUS Portable SSD
# USB bridge ID:
#   30de:1000
#
# Force smartmontools to use the JMicron NVMe bridge backend:
#   -d sntjmicron
#
# This allows:
#   smartctl -a /dev/sda
#
# instead of requiring:
#   smartctl -a -d sntjmicron /dev/sda
#
# Use /etc/smart_drivedb.h instead of modifying the packaged
# /usr/share/smartmontools/drivedb.h, so package/database
# updates do not overwrite the local device mapping.
# ============================================================

SMART_DRIVEDB="files/etc/smart_drivedb.h"

mkdir -p "$(dirname "$SMART_DRIVEDB")"

if [ ! -f "$SMART_DRIVEDB" ]; then
    touch "$SMART_DRIVEDB"
fi

if ! grep -qF '"0x30de:0x1000"' "$SMART_DRIVEDB"; then
    cat >> "$SMART_DRIVEDB" <<'EOF'

{
  "USB: KIOXIA EXCERIA PLUS; ",
  "0x30de:0x1000",
  "",
  "",
  "-d sntjmicron"
},
EOF

    echo "OK: KIOXIA EXCERIA PLUS SMART USB bridge mapping added"
else
    echo "OK: KIOXIA EXCERIA PLUS SMART USB bridge mapping already exists"
fi

# ============================================================
# OpenClash DNS restore compatibility fix
#
# Upstream issue:
# https://github.com/vernesong/OpenClash/issues/5321
#
# Fixes:
# 1. Do not discard WAN DNS merely because it equals WAN gateway.
# 2. Append WAN6 DNS instead of overwriting already-written WAN DNS.
#
# Compatibility behavior:
# - OpenClash not present        -> skip safely
# - Old affected code present   -> patch it
# - Upstream already fixed      -> leave it untouched
# - Unknown future code layout  -> warn and leave untouched
# ============================================================

echo "============================================================"
echo " Checking OpenClash DNS restore compatibility"
echo "============================================================"

OPENCLASH_HELPER_OLD='if rv.wan[o].dns[i] ~= rv.wan[o].gwaddr and rv.wan[o].dns[i] ~= rv.wan[o].ipaddr then'
OPENCLASH_HELPER_NEW='if rv.wan[o].dns[i] ~= rv.wan[o].ipaddr then'

OPENCLASH_INIT_OLD='echo "# Interface LAN6" > "$resolv_file"'
OPENCLASH_INIT_NEW='echo "# Interface LAN6" >> "$resolv_file"'

# OpenClash may come from a feed or from package/, so search both.
mapfile -t OPENCLASH_HELPERS < <(
    find package feeds \
        -type f \
        -path '*/luci-app-openclash/root/usr/share/openclash/openclash_get_network.lua' \
        -print 2>/dev/null
)

mapfile -t OPENCLASH_INITS < <(
    find package feeds \
        -type f \
        -path '*/luci-app-openclash/root/etc/init.d/openclash' \
        -print 2>/dev/null
)

# ------------------------------------------------------------
# Fix 1:
# WAN DNS == WAN gateway is valid and common on DHCP networks.
# The affected OpenClash code incorrectly filters that DNS out.
# ------------------------------------------------------------

if [ "${#OPENCLASH_HELPERS[@]}" -eq 0 ]; then
    echo "INFO: OpenClash network helper not found; DNS helper fix skipped"
else
    for OPENCLASH_HELPER in "${OPENCLASH_HELPERS[@]}"; do
        echo "Checking: $OPENCLASH_HELPER"

        if grep -Fq "$OPENCLASH_HELPER_OLD" "$OPENCLASH_HELPER"; then
            sed -i \
                's/if rv\.wan\[o\]\.dns\[i\] ~= rv\.wan\[o\]\.gwaddr and rv\.wan\[o\]\.dns\[i\] ~= rv\.wan\[o\]\.ipaddr then/if rv.wan[o].dns[i] ~= rv.wan[o].ipaddr then/' \
                "$OPENCLASH_HELPER"

            if grep -Fq "$OPENCLASH_HELPER_NEW" "$OPENCLASH_HELPER"; then
                echo "OK: OpenClash WAN DNS == gateway filter bug patched"
            else
                echo "ERROR: OpenClash WAN DNS helper patch verification failed"
                exit 1
            fi

        elif grep -Fq "$OPENCLASH_HELPER_NEW" "$OPENCLASH_HELPER"; then
            echo "OK: OpenClash WAN DNS helper is already fixed; no patch needed"

        else
            echo "WARNING: OpenClash WAN DNS helper layout is unknown; leaving untouched"
        fi
    done
fi

# ------------------------------------------------------------
# Fix 2:
# WAN6 DNS must append to the resolver file, not overwrite the
# IPv4 WAN DNS that was written immediately before it.
# ------------------------------------------------------------

if [ "${#OPENCLASH_INITS[@]}" -eq 0 ]; then
    echo "INFO: OpenClash init script not found; WAN6 resolver fix skipped"
else
    for OPENCLASH_INIT in "${OPENCLASH_INITS[@]}"; do
        echo "Checking: $OPENCLASH_INIT"

        if grep -Fq "$OPENCLASH_INIT_OLD" "$OPENCLASH_INIT"; then
            sed -i \
                's|echo "# Interface LAN6" > "\$resolv_file"|echo "# Interface LAN6" >> "$resolv_file"|' \
                "$OPENCLASH_INIT"

            if grep -Fq "$OPENCLASH_INIT_NEW" "$OPENCLASH_INIT"; then
                echo "OK: OpenClash WAN6 DNS overwrite bug patched"
            else
                echo "ERROR: OpenClash WAN6 resolver patch verification failed"
                exit 1
            fi

        elif grep -Fq "$OPENCLASH_INIT_NEW" "$OPENCLASH_INIT"; then
            echo "OK: OpenClash WAN6 resolver handling is already fixed; no patch needed"

        else
            echo "WARNING: OpenClash init DNS layout is unknown; leaving untouched"
        fi
    done
fi

echo "OpenClash DNS compatibility check finished"
