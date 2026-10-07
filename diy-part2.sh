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

# ============================================================
# USB tether IPv6 NAT66 fallback for firewall4
#
# Only forwarded IPv6 traffic leaving through usb0 is
# masqueraded.
#
# This intentionally does NOT enable zone-wide masq6:
#   - native wired WAN6 IPv6 remains untouched
#   - LAN ULA can use USB WAN6
#   - LAN GUA learned from wired WAN6 can still survive
#     failover to USB WAN6
# ============================================================

USBWAN6_NAT66_FILE="files/etc/usbwan6-nat66.nft"

mkdir -p "$(dirname "$USBWAN6_NAT66_FILE")"

cat > "$USBWAN6_NAT66_FILE" <<'EOF_USBWAN6_NAT66'
meta nfproto ipv6 iifname "br-lan" oifname "usb0" counter masquerade comment "USB tether IPv6 NAT66 failover"
EOF_USBWAN6_NAT66

chmod 0644 "$USBWAN6_NAT66_FILE"

echo "USB tether IPv6 NAT66 nftables snippet installed:"
echo "  $USBWAN6_NAT66_FILE"

# ============================================================
# First-boot USB tether WAN + optional IPv6 + mwan3 failover
#
# Wired WAN:
#   wan      -> eth0
#   wan6     -> eth0
#
# USB tether WAN:
#   usbwan   -> usb0   (DHCPv4)
#   usbwan6  -> usb0   (DHCPv6 / SLAAC)
#
# Priority:
#   Wired WAN = 10
#   USB WAN   = 20
#
# Compatibility:
#   Missing USB network drivers -> skip safely
#   Missing odhcp6c             -> IPv4 only
#   Missing mwan3               -> normal routing metrics
#   USB cable not connected     -> interfaces remain configured
# ============================================================

echo "============================================================"
echo " Installing USB tether WAN first-boot configuration"
echo "============================================================"

USB_TETHER_DEFAULTS="files/etc/uci-defaults/98-usb-tether-failover"

mkdir -p "$(dirname "$USB_TETHER_DEFAULTS")"

cat > "$USB_TETHER_DEFAULTS" <<'EOF_USB_TETHER'
#!/bin/sh

TAG='usb-tether-firstboot'

log_msg() {
    logger -t "$TAG" "$*" 2>/dev/null || true
    echo "$TAG: $*"
}

# ------------------------------------------------------------
# 1. Detect installed USB tethering drivers
#
# Do not require usb0 to exist during first boot.
# The phone may not be connected yet.
# ------------------------------------------------------------

has_usb_driver() {
    for mod in rndis_host cdc_ncm cdc_ether cdc_eem ipheth; do
        [ -d "/sys/module/$mod" ] && return 0
    done

    if command -v opkg >/dev/null 2>&1; then
        for pkg in \
            kmod-usb-net-rndis \
            kmod-usb-net-cdc-ncm \
            kmod-usb-net-cdc-ether \
            kmod-usb-net-cdc-eem \
            kmod-usb-net-ipheth
        do
            opkg status "$pkg" 2>/dev/null |
                grep -q 'Status: install ok installed' &&
                return 0
        done
    fi

    return 1
}

command -v uci >/dev/null 2>&1 || exit 0

if ! has_usb_driver; then
    log_msg "USB tether driver not installed; skipping"
    exit 0
fi

if ! uci -q get network.wan >/dev/null 2>&1; then
    log_msg "Network WAN interface missing; skipping"
    exit 0
fi

# Protect an existing interface with a different configuration.

if uci -q get network.usbwan >/dev/null 2>&1; then
    OLD_PROTO="$(uci -q get network.usbwan.proto)"
    OLD_DEVICE="$(uci -q get network.usbwan.device)"

    if [ "$OLD_PROTO" != "dhcp" ] ||
       [ "$OLD_DEVICE" != "usb0" ]; then
        log_msg "Existing usbwan differs; preserving configuration"
        exit 0
    fi
fi

# ------------------------------------------------------------
# 2. Locate existing WAN firewall zone
# ------------------------------------------------------------

WAN_ZONE=''

for sec in $(uci -q show firewall |
    sed -n 's/^firewall\.\(.*\)=zone$/\1/p')
do
    if [ "$(uci -q get "firewall.$sec.name")" = "wan" ]; then
        WAN_ZONE="$sec"
        break
    fi
done

if [ -z "$WAN_ZONE" ]; then
    log_msg "WAN firewall zone missing; skipping"
    exit 0
fi

has_list_item() {
    case " $(uci -q get "$1" 2>/dev/null) " in
        *" $2 "*) return 0 ;;
    esac

    return 1
}

# ------------------------------------------------------------
# 3. Configure IPv4 USB WAN
# ------------------------------------------------------------

uci set network.usbwan='interface'
uci set network.usbwan.proto='dhcp'
uci set network.usbwan.device='usb0'

# Main routing table priorities.

uci set network.wan.metric='10'
uci set network.usbwan.metric='20'

log_msg "USB IPv4 WAN configured"

# ------------------------------------------------------------
# 4. Configure optional IPv6 USB WAN
#
# The DHCPv6 client also supports IPv6 RA/SLAAC.
# IPv6 prefix delegation depends on the upstream phone.
# ------------------------------------------------------------

V6_READY=0

if command -v odhcp6c >/dev/null 2>&1 &&
   [ -f /lib/netifd/proto/dhcpv6.sh ]; then

    V6_READY=1

    if uci -q get network.usbwan6 >/dev/null 2>&1; then

        V6_PROTO="$(uci -q get network.usbwan6.proto)"
        V6_DEVICE="$(uci -q get network.usbwan6.device)"

        case "$V6_PROTO/$V6_DEVICE" in
            dhcpv6/@usbwan|dhcpv6/usb0)
                ;;
            *)
                log_msg "Existing usbwan6 differs; preserving it"
                V6_READY=0
                ;;
        esac
    fi

    if [ "$V6_READY" -eq 1 ]; then

        uci set network.usbwan6='interface'
        uci set network.usbwan6.proto='dhcpv6'

       # Bind directly to the physical USB tether device.
       # This form has been verified on the target router.
       uci set network.usbwan6.device='usb0'

        uci set network.usbwan6.reqaddress='try'
        uci set network.usbwan6.reqprefix='auto'
        uci set network.usbwan6.norelease='1'
        uci set network.usbwan6.metric='20'

        if uci -q get network.wan6 >/dev/null 2>&1; then
            uci set network.wan6.metric='10'
        fi

        log_msg "USB IPv6 WAN configured"
    fi

else
    log_msg "DHCPv6 client missing; IPv6 configuration skipped"
fi

# ------------------------------------------------------------
# 5. Firewall
#
# Use the existing WAN zone.
# Keep IPv4 NAT and MTU fixing enabled.
#
# Do NOT enable zone-wide masq6.
# USB-only IPv6 NAT66 is installed separately through
# a firewall4 nftables include, so wired WAN6 can retain
# native end-to-end IPv6.
# ------------------------------------------------------------

if ! has_list_item "firewall.$WAN_ZONE.network" usbwan; then
    uci add_list "firewall.$WAN_ZONE.network=usbwan"
fi

if [ "$V6_READY" -eq 1 ]; then
    if ! has_list_item "firewall.$WAN_ZONE.network" usbwan6; then
        uci add_list "firewall.$WAN_ZONE.network=usbwan6"
    fi
fi

uci set "firewall.$WAN_ZONE.masq=1"
uci set "firewall.$WAN_ZONE.mtu_fix=1"

# ------------------------------------------------------------
# USB-only IPv6 NAT66
#
# Do not use firewall.$WAN_ZONE.masq6=1 because the WAN zone
# also contains wired wan6.
#
# The nftables rule only matches forwarded IPv6 traffic:
#
#   br-lan -> usb0
#
# Therefore:
#   wired WAN6 -> native IPv6
#   USB WAN6   -> NAT66
# ------------------------------------------------------------

if [ "$V6_READY" -eq 1 ] &&
   command -v fw4 >/dev/null 2>&1 &&
   [ -f /etc/usbwan6-nat66.nft ]; then

    uci set firewall.usbwan6_nat66='include'
    uci set firewall.usbwan6_nat66.enabled='1'
    uci set firewall.usbwan6_nat66.type='nftables'
    uci set firewall.usbwan6_nat66.path='/etc/usbwan6-nat66.nft'
    uci set firewall.usbwan6_nat66.position='chain-pre'
    uci set firewall.usbwan6_nat66.chain='srcnat'

    log_msg "USB-only IPv6 NAT66 firewall4 include configured"

else

    log_msg "firewall4/NAT66 snippet unavailable; USB IPv6 NAT66 skipped"

fi

# Ensure LAN -> WAN forwarding exists without duplicating it.

HAS_FORWARD=0

for sec in $(uci -q show firewall |
    sed -n 's/^firewall\.\(.*\)=forwarding$/\1/p')
do
    if [ "$(uci -q get "firewall.$sec.src")" = "lan" ] &&
       [ "$(uci -q get "firewall.$sec.dest")" = "wan" ]; then

        HAS_FORWARD=1
        break
    fi
done

if [ "$HAS_FORWARD" -eq 0 ]; then

    FWD_SEC="$(uci add firewall forwarding)"

    uci set "firewall.$FWD_SEC.src=lan"
    uci set "firewall.$FWD_SEC.dest=wan"

fi

# ------------------------------------------------------------
# 6. Optional mwan3 configuration
#
# IPv4:
#   wan     metric 1
#   usbwan  metric 2
#
# IPv6:
#   wan6     metric 1
#   usbwan6  metric 2
#
# Keep existing unrelated mwan3 policies untouched.
# ------------------------------------------------------------

if [ -x /etc/init.d/mwan3 ] &&
   [ -f /etc/config/mwan3 ]; then

    # --------------------------------------------------------
    # IPv4 wired WAN tracking
    # --------------------------------------------------------

    if uci -q get mwan3.wan >/dev/null 2>&1; then

        uci set mwan3.wan.enabled='1'
        uci set mwan3.wan.family='ipv4'
        uci set mwan3.wan.reliability='1'

        uci -q delete mwan3.wan.track_ip || true

        uci add_list mwan3.wan.track_ip='223.5.5.5'
        uci add_list mwan3.wan.track_ip='119.29.29.29'

    fi

    # --------------------------------------------------------
    # IPv4 USB WAN tracking
    # --------------------------------------------------------

    uci set mwan3.usbwan='interface'
    uci set mwan3.usbwan.enabled='1'
    uci set mwan3.usbwan.family='ipv4'
    uci set mwan3.usbwan.track_method='ping'
    uci set mwan3.usbwan.reliability='1'

    uci -q delete mwan3.usbwan.track_ip || true

    uci add_list mwan3.usbwan.track_ip='223.5.5.5'
    uci add_list mwan3.usbwan.track_ip='119.29.29.29'

    # --------------------------------------------------------
    # IPv4 members
    # --------------------------------------------------------

    uci set mwan3.wan_m1_w3='member'
    uci set mwan3.wan_m1_w3.interface='wan'
    uci set mwan3.wan_m1_w3.metric='1'
    uci set mwan3.wan_m1_w3.weight='3'

    uci set mwan3.usbwan_m2_w1='member'
    uci set mwan3.usbwan_m2_w1.interface='usbwan'
    uci set mwan3.usbwan_m2_w1.metric='2'
    uci set mwan3.usbwan_m2_w1.weight='1'

    # --------------------------------------------------------
    # IPv4 primary / backup policy
    # --------------------------------------------------------

    uci set mwan3.wan_usb='policy'

    uci -q delete mwan3.wan_usb.use_member || true

    uci add_list mwan3.wan_usb.use_member='wan_m1_w3'
    uci add_list mwan3.wan_usb.use_member='usbwan_m2_w1'

    uci set mwan3.wan_usb.last_resort='default'

    # IPv4 default routing.

    uci set mwan3.default_rule_v4='rule'
    uci set mwan3.default_rule_v4.dest_ip='0.0.0.0/0'
    uci set mwan3.default_rule_v4.family='ipv4'
    uci set mwan3.default_rule_v4.use_policy='wan_usb'

    # Preserve HTTPS sticky settings where present.

    if uci -q get mwan3.https >/dev/null 2>&1; then

        uci set mwan3.https.use_policy='wan_usb'
        uci set mwan3.https.family='ipv4'

    fi

    # --------------------------------------------------------
    # Optional IPv6 mwan3 failover
    # --------------------------------------------------------

    if [ "$V6_READY" -eq 1 ]; then

        # USB IPv6 interface monitoring.

        uci set mwan3.usbwan6='interface'
        uci set mwan3.usbwan6.enabled='1'
        uci set mwan3.usbwan6.family='ipv6'
        uci set mwan3.usbwan6.track_method='ping'
        uci set mwan3.usbwan6.reliability='1'

        uci -q delete mwan3.usbwan6.track_ip || true

        uci add_list mwan3.usbwan6.track_ip='2606:4700:4700::1111'
        uci add_list mwan3.usbwan6.track_ip='2001:4860:4860::8888'

        # USB IPv6 member.

        uci set mwan3.usbwan6_m2_w1='member'
        uci set mwan3.usbwan6_m2_w1.interface='usbwan6'
        uci set mwan3.usbwan6_m2_w1.metric='2'
        uci set mwan3.usbwan6_m2_w1.weight='1'

        # IPv6 failover policy.

        uci set mwan3.wan6_usb='policy'

        uci -q delete mwan3.wan6_usb.use_member || true

        # Wired IPv6 is preferred if configured.

        if uci -q get network.wan6 >/dev/null 2>&1; then

            uci set mwan3.wan6='interface'
            uci set mwan3.wan6.enabled='1'
            uci set mwan3.wan6.family='ipv6'
            uci set mwan3.wan6.track_method='ping'
            uci set mwan3.wan6.reliability='1'
              
            uci -q delete mwan3.wan6.track_ip || true
              
            uci add_list mwan3.wan6.track_ip='2606:4700:4700::1111'
            uci add_list mwan3.wan6.track_ip='2001:4860:4860::8888'
              
            uci set mwan3.wan6_m1_w3='member'
            uci set mwan3.wan6_m1_w3.interface='wan6'
            uci set mwan3.wan6_m1_w3.metric='1'
            uci set mwan3.wan6_m1_w3.weight='3'

            uci add_list mwan3.wan6_usb.use_member='wan6_m1_w3'

        fi

        uci add_list mwan3.wan6_usb.use_member='usbwan6_m2_w1'

        uci set mwan3.wan6_usb.last_resort='default'

        # IPv6 default routing.

        uci set mwan3.default_rule_v6='rule'
        uci set mwan3.default_rule_v6.dest_ip='::/0'
        uci set mwan3.default_rule_v6.family='ipv6'
        uci set mwan3.default_rule_v6.use_policy='wan6_usb'

    fi

    uci commit mwan3 || exit 1

    # Enable mwan3 at boot.

    /etc/init.d/mwan3 enable >/dev/null 2>&1 || true

    log_msg "mwan3 WAN failover configured"

else

    log_msg "mwan3 not installed; using normal route metrics"

fi

# ------------------------------------------------------------
# 7. Save configuration
# ------------------------------------------------------------

uci commit network || exit 1
uci commit firewall || exit 1

# ------------------------------------------------------------
# 8. Apply configuration without requiring a reboot
#
# If services are not yet ready, normal system startup
# will subsequently load the committed configuration.
# ------------------------------------------------------------

if [ -x /etc/init.d/network ]; then
    /etc/init.d/network reload >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/firewall ]; then
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/mwan3 ]; then
    /etc/init.d/mwan3 restart >/dev/null 2>&1 || true
fi

log_msg "USB tether WAN initialization completed"

exit 0

EOF_USB_TETHER

chmod 0644 "$USB_TETHER_DEFAULTS"

echo "USB tether WAN first-boot script installed:"
echo "  $USB_TETHER_DEFAULTS"
