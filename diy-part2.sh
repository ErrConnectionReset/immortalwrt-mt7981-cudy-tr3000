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
# LuCI mwan3 mode switch integration
#
# Adds:
#   Network -> MultiWAN Manager -> Mode Switch
#
# UI:
#   - Segmented Control
#   - Native LuCI Save & Apply / Force Apply / Reset
#   - Staged selection: selecting a mode does not apply it
#   - Inline operation status instead of modal notifications
#   - Success message survives the post-apply page reload
#   - Theme-independent alignment for Argon / Aurora / etc.
#   - Native LuCI i18n
# ============================================================

echo "============================================================"
echo " Installing LuCI mwan3 mode switch page"
echo "============================================================"

MWAN3_LUCI_DIR=""

for d in \
    "feeds/luci/applications/luci-app-mwan3" \
    "package/feeds/luci/luci-app-mwan3" \
    "package/luci-app-mwan3"
do
    if [ -d "$d" ]; then
        MWAN3_LUCI_DIR="$d"
        break
    fi
done

if [ -z "$MWAN3_LUCI_DIR" ]; then

    echo "WARNING: luci-app-mwan3 source not found;"
    echo "         LuCI mode switch page skipped"

else

    echo "Found luci-app-mwan3:"
    echo "  $MWAN3_LUCI_DIR"

    MWAN3_MODE_HELPER="$MWAN3_LUCI_DIR/root/usr/sbin/mwan3-mode"
    MWAN3_MODE_VIEW="$MWAN3_LUCI_DIR/htdocs/luci-static/resources/view/mwan3/network/mode.js"
    MWAN3_MODE_MENU="$MWAN3_LUCI_DIR/root/usr/share/luci/menu.d/luci-app-mwan3-mode.json"
    MWAN3_MODE_ACL="$MWAN3_LUCI_DIR/root/usr/share/rpcd/acl.d/luci-app-mwan3-mode.json"
    MWAN3_MODE_ZH="$MWAN3_LUCI_DIR/po/zh_Hans/mwan3.po"

    mkdir -p "$(dirname "$MWAN3_MODE_HELPER")"
    mkdir -p "$(dirname "$MWAN3_MODE_VIEW")"
    mkdir -p "$(dirname "$MWAN3_MODE_MENU")"
    mkdir -p "$(dirname "$MWAN3_MODE_ACL")"
    mkdir -p "$(dirname "$MWAN3_MODE_ZH")"

    # --------------------------------------------------------
    # Dedicated mwan3 mode switch helper
    #
    # Keep this inside luci-app-mwan3 instead of global files/
    # so package installation/removal controls its lifecycle.
    # --------------------------------------------------------


    cat > "$MWAN3_MODE_HELPER" <<'EOF_MWAN3_MODE'
#!/bin/sh

TAG='mwan3-mode'
INIT='/etc/init.d/mwan3'
CONFIG='/etc/config/mwan3'


log_msg() {
    logger -t "$TAG" "$*" 2>/dev/null || true
}


die() {
    log_msg "ERROR: $*"
    echo "ERROR: $*" >&2
    exit 1
}


uci_get() {
    uci -q get "$1" 2>/dev/null || true
}


list_sections() {
    TYPE="$1"

    uci -q show mwan3 2>/dev/null |
        sed -n "s/^mwan3\.\([^.=]*\)=${TYPE}$/\1/p"
}


# ============================================================
# Policy classifier
#
# Classification is based on actual mwan3 structure, not names.
#
# balance:
#   >= 2 members
#   all members have the same metric
#
# failover:
#   >= 2 members
#   multiple metrics
#   no metric level contains multiple members
#
# hybrid:
#   multiple metrics and at least one metric level has multiple
#   members
#
# unknown:
#   incomplete / mixed-family / invalid policy
#
# Globals returned:
#   POLICY_CLASS
#   POLICY_FAMILY
#   POLICY_SIGNATURE
# ============================================================

classify_policy() {
    POLICY="$1"

    POLICY_CLASS='unknown'
    POLICY_FAMILY=''
    POLICY_SIGNATURE=''

    [ "$(uci_get "mwan3.${POLICY}")" = "policy" ] ||
        return 0

    MEMBERS="$(uci_get "mwan3.${POLICY}.use_member")"

    [ -n "$MEMBERS" ] ||
        return 0

    MEMBER_COUNT=0
    METRIC_COUNT=0
    METRICS=''
    IFACES=''
    HAS_SHARED_METRIC=0

    for MEMBER in $MEMBERS; do

        [ "$(uci_get "mwan3.${MEMBER}")" = "member" ] ||
            return 0

        IFACE="$(uci_get "mwan3.${MEMBER}.interface")"

        [ -n "$IFACE" ] ||
            return 0

        FAMILY="$(uci_get "mwan3.${IFACE}.family")"

        case "$FAMILY" in
            ipv4|ipv6)
                ;;
            *)
                return 0
                ;;
        esac

        if [ -z "$POLICY_FAMILY" ]; then
            POLICY_FAMILY="$FAMILY"
        elif [ "$POLICY_FAMILY" != "$FAMILY" ]; then
            POLICY_FAMILY=''
            return 0
        fi

        METRIC="$(uci_get "mwan3.${MEMBER}.metric")"
        [ -n "$METRIC" ] || METRIC='1'

        case " $METRICS " in
            *" $METRIC "*)
                HAS_SHARED_METRIC=1
                ;;
            *)
                METRICS="$METRICS $METRIC"
                METRIC_COUNT=$((METRIC_COUNT + 1))
                ;;
        esac

        IFACES="$IFACES $IFACE"
        MEMBER_COUNT=$((MEMBER_COUNT + 1))
    done

    [ "$MEMBER_COUNT" -ge 2 ] ||
        return 0

    POLICY_SIGNATURE="$(
        printf '%s\n' $IFACES |
            sort -u |
            tr '\n' ',' |
            sed 's/,$//'
    )"

    if [ "$METRIC_COUNT" -eq 1 ]; then
        POLICY_CLASS='balance'

    elif [ "$METRIC_COUNT" -gt 1 ] &&
         [ "$HAS_SHARED_METRIC" -eq 0 ]; then
        POLICY_CLASS='failover'

    else
        POLICY_CLASS='hybrid'
    fi
}


# ============================================================
# Detect one unambiguous default rule for one address family.
#
# We deliberately do NOT rely on section names such as:
#   default_rule_v4
#   default_rule_v6
#
# Globals returned:
#   RULE_NAME
#   RULE_STATE
#
# States:
#   ready
#   no-rule
#   ambiguous-rule
# ============================================================

detect_default_rule() {
    WANT_FAMILY="$1"

    RULE_NAME=''
    RULE_STATE='no-rule'
    COUNT=0

    for RULE in $(list_sections rule); do

        FAMILY="$(uci_get "mwan3.${RULE}.family")"
        DEST="$(uci_get "mwan3.${RULE}.dest_ip")"

        case "$WANT_FAMILY" in
            ipv4)
                [ "$DEST" = "0.0.0.0/0" ] || continue

                case "$FAMILY" in
                    ''|ipv4)
                        ;;
                    *)
                        continue
                        ;;
                esac
                ;;

            ipv6)
                [ "$DEST" = "::/0" ] || continue

                case "$FAMILY" in
                    ''|ipv6)
                        ;;
                    *)
                        continue
                        ;;
                esac
                ;;

            *)
                return 0
                ;;
        esac

        COUNT=$((COUNT + 1))
        RULE_NAME="$RULE"
    done

    if [ "$COUNT" -eq 1 ]; then
        RULE_STATE='ready'

    elif [ "$COUNT" -gt 1 ]; then
        RULE_NAME=''
        RULE_STATE='ambiguous-rule'
    fi
}


# ============================================================
# Locate the unique opposite-mode policy sharing the same
# address family and interface set.
#
# Globals returned:
#   COUNTERPART_NAME
#   COUNTERPART_COUNT
# ============================================================

find_counterpart() {
    WANT_CLASS="$1"
    WANT_FAMILY="$2"
    WANT_SIGNATURE="$3"
    EXCLUDE="$4"

    COUNTERPART_NAME=''
    COUNTERPART_COUNT=0

    for POLICY in $(list_sections policy); do

        [ "$POLICY" != "$EXCLUDE" ] ||
            continue

        classify_policy "$POLICY"

        [ "$POLICY_CLASS" = "$WANT_CLASS" ] ||
            continue

        [ "$POLICY_FAMILY" = "$WANT_FAMILY" ] ||
            continue

        [ "$POLICY_SIGNATURE" = "$WANT_SIGNATURE" ] ||
            continue

        COUNTERPART_COUNT=$((COUNTERPART_COUNT + 1))
        COUNTERPART_NAME="$POLICY"
    done
}


# ============================================================
# Discover one failover/balance pair.
#
# Preference:
#
# 1. If the current default policy itself can be classified,
#    use it as an anchor and find its structural counterpart.
#
# 2. Otherwise scan all policies and require exactly one
#    structural pair.
#
# This lets arbitrary policy names work while refusing to guess
# when several equally valid pairs exist.
#
# Globals returned:
#   PAIR_FAILOVER
#   PAIR_BALANCE
#   PAIR_STATE
# ============================================================

discover_policy_pair() {
    WANT_FAMILY="$1"
    RULE="$2"

    PAIR_FAILOVER=''
    PAIR_BALANCE=''
    PAIR_STATE='no-pair'

    CURRENT_POLICY="$(uci_get "mwan3.${RULE}.use_policy")"

    if [ -n "$CURRENT_POLICY" ]; then

        classify_policy "$CURRENT_POLICY"

        CURRENT_CLASS="$POLICY_CLASS"
        CURRENT_FAMILY="$POLICY_FAMILY"
        CURRENT_SIGNATURE="$POLICY_SIGNATURE"

        if [ "$CURRENT_FAMILY" = "$WANT_FAMILY" ]; then

            case "$CURRENT_CLASS" in
                failover)
                    find_counterpart \
                        balance \
                        "$WANT_FAMILY" \
                        "$CURRENT_SIGNATURE" \
                        "$CURRENT_POLICY"

                    if [ "$COUNTERPART_COUNT" -eq 1 ]; then
                        PAIR_FAILOVER="$CURRENT_POLICY"
                        PAIR_BALANCE="$COUNTERPART_NAME"
                        PAIR_STATE='ready'
                        return 0
                    elif [ "$COUNTERPART_COUNT" -gt 1 ]; then
                        PAIR_STATE='ambiguous-pair'
                        return 0
                    fi
                    ;;

                balance)
                    find_counterpart \
                        failover \
                        "$WANT_FAMILY" \
                        "$CURRENT_SIGNATURE" \
                        "$CURRENT_POLICY"

                    if [ "$COUNTERPART_COUNT" -eq 1 ]; then
                        PAIR_FAILOVER="$COUNTERPART_NAME"
                        PAIR_BALANCE="$CURRENT_POLICY"
                        PAIR_STATE='ready'
                        return 0
                    elif [ "$COUNTERPART_COUNT" -gt 1 ]; then
                        PAIR_STATE='ambiguous-pair'
                        return 0
                    fi
                    ;;
            esac
        fi
    fi


    # --------------------------------------------------------
    # No usable current-policy anchor.
    # Search globally, but accept only one unambiguous pair.
    # --------------------------------------------------------

    PAIR_COUNT=0
    FOUND_FAIL=''
    FOUND_BAL=''

    for FAIL_POLICY in $(list_sections policy); do

        classify_policy "$FAIL_POLICY"

        [ "$POLICY_CLASS" = "failover" ] ||
            continue

        [ "$POLICY_FAMILY" = "$WANT_FAMILY" ] ||
            continue

        FAIL_SIGNATURE="$POLICY_SIGNATURE"

        for BAL_POLICY in $(list_sections policy); do

            [ "$BAL_POLICY" != "$FAIL_POLICY" ] ||
                continue

            classify_policy "$BAL_POLICY"

            [ "$POLICY_CLASS" = "balance" ] ||
                continue

            [ "$POLICY_FAMILY" = "$WANT_FAMILY" ] ||
                continue

            [ "$POLICY_SIGNATURE" = "$FAIL_SIGNATURE" ] ||
                continue

            PAIR_COUNT=$((PAIR_COUNT + 1))
            FOUND_FAIL="$FAIL_POLICY"
            FOUND_BAL="$BAL_POLICY"
        done
    done

    if [ "$PAIR_COUNT" -eq 1 ]; then
        PAIR_FAILOVER="$FOUND_FAIL"
        PAIR_BALANCE="$FOUND_BAL"
        PAIR_STATE='ready'

    elif [ "$PAIR_COUNT" -gt 1 ]; then
        PAIR_STATE='ambiguous-pair'
    fi
}


# ============================================================
# Count sticky rules which are currently coupled to the default
# rule's selected mode.
#
# This generalizes the old hard-coded "https" behavior:
#
#   - rule must be sticky
#   - rule must currently use the same mode policy as default
#   - unrelated custom rules remain untouched
# ============================================================

count_followers() {
    WANT_FAMILY="$1"
    DEFAULT_RULE="$2"
    FAIL_POLICY="$3"
    BAL_POLICY="$4"

    FOLLOWER_COUNT=0

    SOURCE_POLICY="$(
        uci_get "mwan3.${DEFAULT_RULE}.use_policy"
    )"

    case "$SOURCE_POLICY" in
        "$FAIL_POLICY"|"$BAL_POLICY")
            ;;
        *)
            echo 0
            return 0
            ;;
    esac

    for RULE in $(list_sections rule); do

        [ "$RULE" != "$DEFAULT_RULE" ] ||
            continue

        STICKY="$(uci_get "mwan3.${RULE}.sticky")"

        case "$STICKY" in
            1|yes|true)
                ;;
            *)
                continue
                ;;
        esac

        FAMILY="$(uci_get "mwan3.${RULE}.family")"

        if [ -n "$FAMILY" ] &&
           [ "$FAMILY" != "$WANT_FAMILY" ]; then
            continue
        fi

        RULE_POLICY="$(
            uci_get "mwan3.${RULE}.use_policy"
        )"

        [ "$RULE_POLICY" = "$SOURCE_POLICY" ] ||
            continue

        FOLLOWER_COUNT=$((FOLLOWER_COUNT + 1))
    done

    echo "$FOLLOWER_COUNT"
}


# ============================================================
# Full discovery
# ============================================================

discover_all() {
    AVAILABLE='no'
    SERVICE_STATE='unavailable'
    READY='no'
    PARTIAL='no'
    MODE='unconfigured'
    REASON=''

    V4_STATE='unavailable'
    V4_RULE=''
    V4_FAIL=''
    V4_BAL=''
    V4_FOLLOWERS='0'

    V6_STATE='unavailable'
    V6_RULE=''
    V6_FAIL=''
    V6_BAL=''
    V6_FOLLOWERS='0'


    command -v uci >/dev/null 2>&1 || {
        REASON='uci-missing'
        return 0
    }

    [ -f "$CONFIG" ] || {
        REASON='config-missing'
        return 0
    }

    [ -x "$INIT" ] || {
        REASON='backend-missing'
        return 0
    }

    AVAILABLE='yes'

    if "$INIT" running >/dev/null 2>&1; then
        SERVICE_STATE='running'
    else
        SERVICE_STATE='stopped'
    fi


    # IPv4 ---------------------------------------------------

    detect_default_rule ipv4

    V4_RULE="$RULE_NAME"
    V4_STATE="$RULE_STATE"

    if [ "$RULE_STATE" = "ready" ]; then

        discover_policy_pair ipv4 "$RULE_NAME"

        V4_FAIL="$PAIR_FAILOVER"
        V4_BAL="$PAIR_BALANCE"
        V4_STATE="$PAIR_STATE"

        if [ "$V4_STATE" = "ready" ]; then
            V4_FOLLOWERS="$(
                count_followers \
                    ipv4 \
                    "$V4_RULE" \
                    "$V4_FAIL" \
                    "$V4_BAL"
            )"
        fi
    fi


    # IPv6 ---------------------------------------------------

    detect_default_rule ipv6

    V6_RULE="$RULE_NAME"
    V6_STATE="$RULE_STATE"

    if [ "$RULE_STATE" = "ready" ]; then

        discover_policy_pair ipv6 "$RULE_NAME"

        V6_FAIL="$PAIR_FAILOVER"
        V6_BAL="$PAIR_BALANCE"
        V6_STATE="$PAIR_STATE"

        if [ "$V6_STATE" = "ready" ]; then
            V6_FOLLOWERS="$(
                count_followers \
                    ipv6 \
                    "$V6_RULE" \
                    "$V6_FAIL" \
                    "$V6_BAL"
            )"
        fi
    fi


    V4_READY=0
    V6_READY=0

    [ "$V4_STATE" = "ready" ] &&
        V4_READY=1

    [ "$V6_STATE" = "ready" ] &&
        V6_READY=1


    if [ "$V4_READY" -eq 0 ] &&
       [ "$V6_READY" -eq 0 ]; then

        READY='no'
        MODE='unconfigured'
        return 0
    fi


    READY='yes'

    if [ "$V4_READY" -ne "$V6_READY" ]; then
        PARTIAL='yes'
    fi


    V4_MODE=''
    V6_MODE=''

    if [ "$V4_READY" -eq 1 ]; then

        CURRENT="$(
            uci_get "mwan3.${V4_RULE}.use_policy"
        )"

        if [ "$CURRENT" = "$V4_FAIL" ]; then
            V4_MODE='failover'
        elif [ "$CURRENT" = "$V4_BAL" ]; then
            V4_MODE='balance'
        else
            V4_MODE='custom'
        fi
    fi


    if [ "$V6_READY" -eq 1 ]; then

        CURRENT="$(
            uci_get "mwan3.${V6_RULE}.use_policy"
        )"

        if [ "$CURRENT" = "$V6_FAIL" ]; then
            V6_MODE='failover'
        elif [ "$CURRENT" = "$V6_BAL" ]; then
            V6_MODE='balance'
        else
            V6_MODE='custom'
        fi
    fi


    if [ "$V4_READY" -eq 1 ] &&
       [ "$V6_READY" -eq 1 ]; then

        if [ "$V4_MODE" = "$V6_MODE" ] &&
           { [ "$V4_MODE" = "failover" ] ||
             [ "$V4_MODE" = "balance" ]; }; then

            MODE="$V4_MODE"

        else
            MODE='mixed'
        fi

    elif [ "$V4_READY" -eq 1 ]; then

        case "$V4_MODE" in
            failover|balance)
                MODE="$V4_MODE"
                ;;
            *)
                MODE='mixed'
                ;;
        esac

    else

        case "$V6_MODE" in
            failover|balance)
                MODE="$V6_MODE"
                ;;
            *)
                MODE='mixed'
                ;;
        esac
    fi
}


# ============================================================
# Stable machine-readable status protocol.
#
# Values here are UCI section identifiers / fixed enum values,
# so KEY=value is sufficient and avoids requiring jq/jsonfilter.
# ============================================================

show_status() {
    discover_all

    echo "Protocol=2"
    echo "Available=$AVAILABLE"
    echo "Ready=$READY"
    echo "Partial=$PARTIAL"
    echo "Service=$SERVICE_STATE"
    echo "Mode=$MODE"
    echo "Reason=$REASON"

    echo "IPv4State=$V4_STATE"
    echo "IPv4Rule=$V4_RULE"
    echo "IPv4Failover=$V4_FAIL"
    echo "IPv4Balance=$V4_BAL"
    echo "IPv4Followers=$V4_FOLLOWERS"

    echo "IPv6State=$V6_STATE"
    echo "IPv6Rule=$V6_RULE"
    echo "IPv6Failover=$V6_FAIL"
    echo "IPv6Balance=$V6_BAL"
    echo "IPv6Followers=$V6_FOLLOWERS"
}


# ============================================================
# Rollback support
# ============================================================

BACKUP_DATA=''


backup_rule() {
    RULE="$1"

    OLD_POLICY="$(
        uci_get "mwan3.${RULE}.use_policy"
    )"

    BACKUP_DATA="${BACKUP_DATA}${RULE}|${OLD_POLICY}
"
}


restore_backup() {
    printf '%s' "$BACKUP_DATA" |
    while IFS='|' read -r RULE OLD_POLICY; do

        [ -n "$RULE" ] ||
            continue

        if [ -n "$OLD_POLICY" ]; then
            uci set \
                "mwan3.${RULE}.use_policy=${OLD_POLICY}" \
                >/dev/null 2>&1 || true
        else
            uci -q delete \
                "mwan3.${RULE}.use_policy" \
                >/dev/null 2>&1 || true
        fi

    done

    uci commit mwan3 >/dev/null 2>&1
}


# ============================================================
# Apply sticky follower rules which are currently coupled to
# the source mode.
# ============================================================

apply_followers() {
    WANT_FAMILY="$1"
    DEFAULT_RULE="$2"
    SOURCE_POLICY="$3"
    TARGET_POLICY="$4"

    case "$SOURCE_POLICY" in
        '')
            return 0
            ;;
    esac

    for RULE in $(list_sections rule); do

        [ "$RULE" != "$DEFAULT_RULE" ] ||
            continue

        STICKY="$(uci_get "mwan3.${RULE}.sticky")"

        case "$STICKY" in
            1|yes|true)
                ;;
            *)
                continue
                ;;
        esac

        FAMILY="$(uci_get "mwan3.${RULE}.family")"

        if [ -n "$FAMILY" ] &&
           [ "$FAMILY" != "$WANT_FAMILY" ]; then
            continue
        fi

        CURRENT="$(
            uci_get "mwan3.${RULE}.use_policy"
        )"

        [ "$CURRENT" = "$SOURCE_POLICY" ] ||
            continue

        backup_rule "$RULE"

        uci set \
            "mwan3.${RULE}.use_policy=${TARGET_POLICY}" ||
            return 1
    done

    return 0
}


# ============================================================
# Apply mode
# ============================================================

apply_mode() {
    TARGET_MODE="$1"

    discover_all

    [ "$AVAILABLE" = "yes" ] ||
        die "mwan3 backend is not available"

    [ "$READY" = "yes" ] ||
        die "no safe failover/load-balancing mapping could be detected"

    case "$TARGET_MODE" in
        failover|balance)
            ;;
        *)
            die "invalid target mode: $TARGET_MODE"
            ;;
    esac


    BACKUP_DATA=''
    CHANGED=0


    # IPv4 ---------------------------------------------------

    if [ "$V4_STATE" = "ready" ]; then

        SOURCE="$(
            uci_get "mwan3.${V4_RULE}.use_policy"
        )"

        if [ "$TARGET_MODE" = "failover" ]; then
            TARGET="$V4_FAIL"
        else
            TARGET="$V4_BAL"
        fi

        [ "$(uci_get "mwan3.${TARGET}")" = "policy" ] ||
            die "IPv4 target policy disappeared during apply"

        backup_rule "$V4_RULE"

        if ! uci set \
            "mwan3.${V4_RULE}.use_policy=${TARGET}"; then

            uci revert mwan3 >/dev/null 2>&1 || true
            die "failed to update IPv4 default rule"
        fi

        if [ "$SOURCE" = "$V4_FAIL" ] ||
           [ "$SOURCE" = "$V4_BAL" ]; then

            if ! apply_followers \
                ipv4 \
                "$V4_RULE" \
                "$SOURCE" \
                "$TARGET"; then

                uci revert mwan3 >/dev/null 2>&1 || true
                die "failed to update IPv4 sticky follower rules"
            fi
        fi

        CHANGED=$((CHANGED + 1))
    fi


    # IPv6 ---------------------------------------------------

    if [ "$V6_STATE" = "ready" ]; then

        SOURCE="$(
            uci_get "mwan3.${V6_RULE}.use_policy"
        )"

        if [ "$TARGET_MODE" = "failover" ]; then
            TARGET="$V6_FAIL"
        else
            TARGET="$V6_BAL"
        fi

        [ "$(uci_get "mwan3.${TARGET}")" = "policy" ] ||
            die "IPv6 target policy disappeared during apply"

        backup_rule "$V6_RULE"

        if ! uci set \
            "mwan3.${V6_RULE}.use_policy=${TARGET}"; then

            uci revert mwan3 >/dev/null 2>&1 || true
            die "failed to update IPv6 default rule"
        fi

        if [ "$SOURCE" = "$V6_FAIL" ] ||
           [ "$SOURCE" = "$V6_BAL" ]; then

            if ! apply_followers \
                ipv6 \
                "$V6_RULE" \
                "$SOURCE" \
                "$TARGET"; then

                uci revert mwan3 >/dev/null 2>&1 || true
                die "failed to update IPv6 sticky follower rules"
            fi
        fi

        CHANGED=$((CHANGED + 1))
    fi


    [ "$CHANGED" -gt 0 ] ||
        die "nothing can be changed safely"


    SERVICE_WAS_RUNNING=0

    if "$INIT" running >/dev/null 2>&1; then
        SERVICE_WAS_RUNNING=1
    fi


    if ! uci commit mwan3; then

        uci revert mwan3 >/dev/null 2>&1 || true
        die "failed to commit mwan3 configuration"
    fi


    # --------------------------------------------------------
    # Verify committed default-rule mappings.
    # --------------------------------------------------------

    VERIFY_OK=1

    if [ "$V4_STATE" = "ready" ]; then

        if [ "$TARGET_MODE" = "failover" ]; then
            EXPECT="$V4_FAIL"
        else
            EXPECT="$V4_BAL"
        fi

        [ "$(uci_get "mwan3.${V4_RULE}.use_policy")" = "$EXPECT" ] ||
            VERIFY_OK=0
    fi

    if [ "$V6_STATE" = "ready" ]; then

        if [ "$TARGET_MODE" = "failover" ]; then
            EXPECT="$V6_FAIL"
        else
            EXPECT="$V6_BAL"
        fi

        [ "$(uci_get "mwan3.${V6_RULE}.use_policy")" = "$EXPECT" ] ||
            VERIFY_OK=0
    fi


    if [ "$VERIFY_OK" -ne 1 ]; then

        restore_backup || true

        if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
            "$INIT" restart >/dev/null 2>&1 || true
        fi

        die "verification failed; previous mwan3 configuration was restored"
    fi


    # --------------------------------------------------------
    # Preserve runtime state.
    #
    # If mwan3 was stopped before applying, do NOT start it.
    # --------------------------------------------------------

    if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then

        if ! "$INIT" restart; then

            if restore_backup; then
                "$INIT" restart >/dev/null 2>&1 || true
                die "mwan3 restart failed; previous configuration was restored"
            else
                die "mwan3 restart failed and automatic rollback also failed"
            fi
        fi

        echo "Result=success"
        echo "ServiceAction=restarted"

    else

        echo "Result=success"
        echo "ServiceAction=stopped-preserved"
    fi


    log_msg "switched to ${TARGET_MODE}"

    show_status
}


usage() {
    cat <<'EOF_USAGE'
Usage:
  mwan3-mode status
  mwan3-mode failover
  mwan3-mode balance

The helper automatically discovers:

  - IPv4 / IPv6 default rules
  - failover policies
  - load-balancing policies
  - structurally matching policy pairs
  - sticky rules coupled to the current default policy

It refuses to guess when the configuration is ambiguous.
EOF_USAGE
}


case "$1" in
    status)
        show_status
        ;;

    failover)
        apply_mode failover
        ;;

    balance)
        apply_mode balance
        ;;

    -h|--help|help|'')
        usage
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac

exit 0
EOF_MWAN3_MODE

    chmod 0755 "$MWAN3_MODE_HELPER"

    echo "mwan3 mode switch helper added to luci-app-mwan3 package:"
    echo "  /usr/sbin/mwan3-mode"

    # --------------------------------------------------------
    # LuCI menu
    # --------------------------------------------------------

    cat > "$MWAN3_MODE_MENU" <<'EOF_MWAN3_MODE_MENU'
{
    "admin/network/mwan3/mode": {
        "title": "Mode Switch",
        "order": 110,
        "action": {
            "type": "view",
            "path": "mwan3/network/mode"
        },
        "depends": {
            "acl": [
                "luci-app-mwan3-mode"
            ]
        }
    }
}
EOF_MWAN3_MODE_MENU

    # --------------------------------------------------------
    # RPC ACL
    #
    # Only expose the dedicated mwan3-mode helper.
    # Never expose /bin/sh or another general shell.
    # --------------------------------------------------------

    cat > "$MWAN3_MODE_ACL" <<'EOF_MWAN3_MODE_ACL'
{
    "luci-app-mwan3-mode": {
        "description": "Grant access to mwan3 mode switching",

        "read": {
            "file": {
                "/usr/sbin/mwan3-mode status": [
                    "exec"
                ]
            },

            "ubus": {
                "file": [
                    "exec"
                ]
            }
        },

        "write": {
            "file": {
                "/usr/sbin/mwan3-mode failover": [
                    "exec"
                ],

                "/usr/sbin/mwan3-mode balance": [
                    "exec"
                ]
            },

            "ubus": {
                "file": [
                    "exec"
                ]
            }
        }
    }
}
EOF_MWAN3_MODE_ACL

    # --------------------------------------------------------
    # LuCI JavaScript view
    # --------------------------------------------------------

    cat > "$MWAN3_MODE_VIEW" <<'EOF_MWAN3_MODE_VIEW'
'use strict';

'require view';
'require fs';
'require ui';


function parseStatus(output) {
    var data = {};

    (output || '')
        .split(/\r?\n/)
        .forEach(function(line) {
            var pos =
                line.indexOf('=');

            if (pos <= 0)
                return;

            data[line.substring(0, pos)] =
                line.substring(pos + 1);
        });

    return {
        available:
            data.Available === 'yes',

        ready:
            data.Ready === 'yes',

        partial:
            data.Partial === 'yes',

        service:
            data.Service || 'unavailable',

        mode:
            data.Mode || 'unconfigured',

        reason:
            data.Reason || '',

        ipv4: {
            state:
                data.IPv4State || 'unavailable',

            rule:
                data.IPv4Rule || '',

            failover:
                data.IPv4Failover || '',

            balance:
                data.IPv4Balance || '',

            followers:
                data.IPv4Followers || '0'
        },

        ipv6: {
            state:
                data.IPv6State || 'unavailable',

            rule:
                data.IPv6Rule || '',

            failover:
                data.IPv6Failover || '',

            balance:
                data.IPv6Balance || '',

            followers:
                data.IPv6Followers || '0'
        }
    };
}


function modeLabel(mode) {
    switch (mode) {
    case 'failover':
        return _('Failover');

    case 'balance':
        return _('Load Balancing');

    case 'mixed':
        return _('Mixed / Custom');

    case 'unconfigured':
        return _('Unconfigured');

    default:
        return _('Unknown');
    }
}


function stateLabel(state) {
    switch (state) {
    case 'ready':
        return _('Ready');

    case 'no-rule':
        return _('No default rule detected');

    case 'ambiguous-rule':
        return _('Multiple default rules detected');

    case 'no-pair':
        return _(
            'No compatible policy pair detected'
        );

    case 'ambiguous-pair':
        return _(
            'Multiple compatible policy pairs detected'
        );

    default:
        return _('Unavailable');
    }
}


function format1(text, value) {
    return text.replace('%s', value);
}


function setFeedback(kind, message, detail) {
    var box =
        document.getElementById(
            'mwan3-mode-feedback'
        );

    if (!box)
        return;

    while (box.firstChild)
        box.removeChild(box.firstChild);

    var labelText;
    var labelClass;

    switch (kind) {
    case 'success':
        labelText = _('Applied');
        labelClass = 'label success';
        break;

    case 'error':
        labelText = _('Error');
        labelClass = 'label warning';
        break;

    case 'working':
        labelText = _('Applying');
        labelClass = 'label';
        break;

    default:
        labelText = _('Notice');
        labelClass = 'label';
        break;
    }

    box.appendChild(
        E(
            'span',
            {
                'class':
                    labelClass
            },
            labelText
        )
    );

    box.appendChild(
        document.createTextNode(
            '  ' + message
        )
    );

    if (detail) {
        box.appendChild(
            E(
                'pre',
                {
                    'style':
                        'white-space:pre-wrap;' +
                        'margin:.75em 0 0 0;'
                },
                detail
            )
        );
    }

    box.style.display =
        'block';
}


function storeFeedback(message) {
    try {
        window.sessionStorage.setItem(
            'mwan3-mode-feedback',
            message
        );
    }
    catch (e) {
        /* Non-fatal. */
    }
}


function restoreFeedback() {
    var message = null;

    try {
        message =
            window.sessionStorage.getItem(
                'mwan3-mode-feedback'
            );

        window.sessionStorage.removeItem(
            'mwan3-mode-feedback'
        );
    }
    catch (e) {
        /* Non-fatal. */
    }

    if (message)
        setFeedback(
            'success',
            message
        );
}


function alignSegmentToContent() {
    var anchor =
        document.getElementById(
            'mwan3-mode-status-anchor'
        );

    var segment =
        document.getElementById(
            'mwan3-mode-segment'
        );

    if (!anchor || !segment)
        return;

    segment.style.marginInlineStart =
        '0px';

    window.requestAnimationFrame(
        function() {

            var targetLeft =
                anchor
                    .getBoundingClientRect()
                    .left;

            var currentLeft =
                segment
                    .getBoundingClientRect()
                    .left;

            var delta =
                Math.round(
                    targetLeft -
                    currentLeft
                );

            if (
                delta > 1 &&
                delta < 64
            ) {
                segment.style.marginInlineStart =
                    delta + 'px';
            }
        }
    );
}


function mappingDescription(
    family,
    info
) {
    if (info.state !== 'ready') {
        return E(
            'div',
            {
                'class':
                    'cbi-section-descr',

                'style':
                    'margin-bottom:.75em;'
            },
            [
                E(
                    'strong',
                    {},
                    family + ': '
                ),

                E(
                    'span',
                    {
                        'class':
                            'label warning'
                    },
                    stateLabel(
                        info.state
                    )
                )
            ]
        );
    }

    return E(
        'div',
        {
            'class':
                'cbi-section-descr',

            'style':
                'margin-bottom:.9em;'
        },
        [
            E(
                'p',
                {
                    'style':
                        'margin:.25em 0;'
                },
                [
                    E(
                        'strong',
                        {},
                        family
                    ),

                    document.createTextNode(
                        '  '
                    ),

                    E(
                        'span',
                        {
                            'class':
                                'label success'
                        },
                        _('Ready')
                    )
                ]
            ),

            E(
                'p',
                {
                    'style':
                        'margin:.25em 0;'
                },
                _(
                    'Default rule'
                ) +
                ': ' +
                info.rule
            ),

            E(
                'p',
                {
                    'style':
                        'margin:.25em 0;'
                },
                _(
                    'Failover policy'
                ) +
                ': ' +
                info.failover
            ),

            E(
                'p',
                {
                    'style':
                        'margin:.25em 0;'
                },
                _(
                    'Load-balancing policy'
                ) +
                ': ' +
                info.balance
            ),

            E(
                'p',
                {
                    'style':
                        'margin:.25em 0;'
                },
                _(
                    'Sticky follower rules'
                ) +
                ': ' +
                info.followers
            )
        ]
    );
}


return view.extend({
    actualMode:
        'unconfigured',

    pendingMode:
        'unconfigured',

    ready:
        false,

    available:
        false,

    serviceState:
        'unavailable',


    /*
     * No standalone Save button.
     *
     * LuCI provides:
     *
     *   Save & Apply
     *   Force Apply
     *   Reset
     */
    handleSave:
        null,


    load: function() {
        return fs.exec(
            '/usr/sbin/mwan3-mode',
            [ 'status' ]
        ).catch(
            function(err) {
                return {
                    code: 1,
                    stdout: '',
                    stderr:
                        String(err)
                };
            }
        );
    },


    updateSegment: function() {
        var failover =
            document.getElementById(
                'mwan3-mode-failover'
            );

        var balance =
            document.getElementById(
                'mwan3-mode-balance'
            );

        if (
            !failover ||
            !balance
        )
            return;

        var selected =
            this.pendingMode;


        failover.setAttribute(
            'aria-checked',
            selected === 'failover'
                ? 'true'
                : 'false'
        );

        balance.setAttribute(
            'aria-checked',
            selected === 'balance'
                ? 'true'
                : 'false'
        );


        failover.className =
            'btn ' +
            (
                selected === 'failover'
                    ? 'cbi-button-positive'
                    : 'cbi-button-neutral'
            );

        balance.className =
            'btn ' +
            (
                selected === 'balance'
                    ? 'cbi-button-positive'
                    : 'cbi-button-neutral'
            );


        failover.disabled =
            !this.ready;

        balance.disabled =
            !this.ready;
    },


    handleSelectMode:
        function(mode, ev) {

        if (ev)
            ev.preventDefault();

        if (!this.ready)
            return false;

        if (
            mode !== 'failover' &&
            mode !== 'balance'
        )
            return false;

        this.pendingMode =
            mode;

        this.updateSegment();

        var feedback =
            document.getElementById(
                'mwan3-mode-feedback'
            );

        if (feedback)
            feedback.style.display =
                'none';

        return false;
    },


    handleSaveApply:
        function(ev, applyMode) {

        var self =
            this;

        var target =
            this.pendingMode;

        var forceApply =
            String(applyMode) === '1';


        if (
            !this.available ||
            !this.ready
        ) {
            setFeedback(
                'error',
                _(
                    'Mode switching is unavailable until a safe mapping can be detected.'
                )
            );

            return Promise.resolve();
        }


        if (
            target !== 'failover' &&
            target !== 'balance'
        ) {
            setFeedback(
                'error',
                _(
                    'Select a target mode first.'
                )
            );

            return Promise.resolve();
        }


        if (
            !forceApply &&
            target ===
                this.actualMode
        ) {
            setFeedback(
                'info',
                _(
                    'No mode change to apply.'
                )
            );

            return Promise.resolve();
        }


        var label =
            modeLabel(target);


        setFeedback(
            'working',
            format1(
                _(
                    'Applying %s ...'
                ),
                label
            )
        );


        return fs.exec(
            '/usr/sbin/mwan3-mode',
            [ target ]
        ).then(
            function(res) {

                if (
                    !res ||
                    res.code !== 0
                ) {
                    var output =
                        (
                            res &&
                            (
                                res.stderr ||
                                res.stdout
                            )
                        ) ||
                        _(
                            'Unknown error'
                        );

                    setFeedback(
                        'error',
                        format1(
                            _(
                                'Failed to switch to %s.'
                            ),
                            label
                        ),
                        output
                    );

                    return;
                }


                self.actualMode =
                    target;

                self.pendingMode =
                    target;


                if (
                    /ServiceAction=stopped-preserved/
                        .test(
                            res.stdout || ''
                        )
                ) {
                    storeFeedback(
                        format1(
                            _(
                                'Switched to %s. mwan3 remains stopped.'
                            ),
                            label
                        )
                    );
                }
                else {
                    storeFeedback(
                        format1(
                            target ===
                                self.actualMode
                                ? _(
                                    'Switched to %s.'
                                  )
                                : _(
                                    'Switched to %s.'
                                  ),
                            label
                        )
                    );
                }


                window.location.reload();
            }
        ).catch(
            function(err) {

                setFeedback(
                    'error',
                    format1(
                        _(
                            'Failed to switch to %s.'
                        ),
                        label
                    ),
                    String(err)
                );
            }
        );
    },


    handleReset:
        function(ev) {

        if (ev)
            ev.preventDefault();

        this.pendingMode =
            this.actualMode;

        this.updateSegment();

        var feedback =
            document.getElementById(
                'mwan3-mode-feedback'
            );

        if (feedback)
            feedback.style.display =
                'none';

        return Promise.resolve();
    },


    render: function(status) {
        var parsed =
            parseStatus(
                status &&
                status.stdout
                    ? status.stdout
                    : ''
            );

        var self =
            this;


        this.available =
            parsed.available;

        this.ready =
            parsed.ready;

        this.serviceState =
            parsed.service;

        this.actualMode =
            parsed.mode;

        this.pendingMode =
            parsed.mode;


        window.setTimeout(
            function() {
                alignSegmentToContent();
                self.updateSegment();
                restoreFeedback();
            },
            0
        );


        function button(which) {
            var active =
                self.pendingMode ===
                which;

            return E(
                'button',
                {
                    'id':
                        'mwan3-mode-' +
                        which,

                    'type':
                        'button',

                    'role':
                        'radio',

                    'aria-checked':
                        active
                            ? 'true'
                            : 'false',

                    'disabled':
                        self.ready
                            ? null
                            : 'disabled',

                    'class':
                        'btn ' +
                        (
                            active
                                ? 'cbi-button-positive'
                                : 'cbi-button-neutral'
                        ),

                    'style':
                        which ===
                        'failover'
                            ? (
                                'margin:0;' +
                                'min-width:9em;' +
                                'border-radius:.375em 0 0 .375em;'
                              )
                            : (
                                'margin:0;' +
                                'margin-left:-1px;' +
                                'min-width:9em;' +
                                'border-radius:0 .375em .375em 0;'
                              ),

                    'click':
                        ui.createHandlerFn(
                            self,
                            'handleSelectMode',
                            which
                        )
                },

                modeLabel(which)
            );
        }


        var statusClass =
            parsed.mode ===
                'failover' ||
            parsed.mode ===
                'balance'
                ? 'label success'
                : 'label warning';


        var notices = [];


        if (!parsed.available) {
            notices.push(
                E(
                    'p',
                    {},
                    [
                        E(
                            'span',
                            {
                                'class':
                                    'label warning'
                            },
                            _('Unavailable')
                        ),

                        document.createTextNode(
                            '  ' +
                            _(
                                'The mwan3 backend is not available.'
                            )
                        )
                    ]
                )
            );
        }
        else if (!parsed.ready) {
            notices.push(
                E(
                    'p',
                    {},
                    [
                        E(
                            'span',
                            {
                                'class':
                                    'label warning'
                            },
                            _('Notice')
                        ),

                        document.createTextNode(
                            '  ' +
                            _(
                                'Mode switching is unavailable until a safe mapping can be detected.'
                            )
                        )
                    ]
                )
            );
        }


        if (
            parsed.ready &&
            parsed.partial
        ) {
            notices.push(
                E(
                    'p',
                    {},
                    [
                        E(
                            'span',
                            {
                                'class':
                                    'label warning'
                            },
                            _('Notice')
                        ),

                        document.createTextNode(
                            '  ' +
                            _(
                                'Only one address family has a safe mapping. The other family will be left unchanged.'
                            )
                        )
                    ]
                )
            );
        }


        if (
            parsed.available &&
            parsed.service ===
                'stopped'
        ) {
            notices.push(
                E(
                    'p',
                    {},
                    [
                        E(
                            'span',
                            {
                                'class':
                                    'label warning'
                            },
                            _('Notice')
                        ),

                        document.createTextNode(
                            '  ' +
                            _(
                                'mwan3 is stopped. Applying a mode will save the configuration without starting the service.'
                            )
                        )
                    ]
                )
            );
        }


        return E(
            'div',
            {
                'class':
                    'cbi-map'
            },
            [
                E(
                    'h2',
                    {},
                    _(
                        'MultiWAN Manager - Mode Switch'
                    )
                ),


                E(
                    'div',
                    {
                        'class':
                            'cbi-map-descr'
                    },
                    _(
                        'Automatically detect compatible failover and load-balancing policies and switch the default routing mode safely.'
                    )
                ),


                E(
                    'div',
                    {
                        'class':
                            'cbi-section'
                    },
                    [
                        E(
                            'h3',
                            {},
                            _(
                                'Current mode'
                            )
                        ),


                        E(
                            'p',
                            {},
                            E(
                                'span',
                                {
                                    'id':
                                        'mwan3-mode-status-anchor',

                                    'class':
                                        statusClass
                                },
                                modeLabel(
                                    parsed.mode
                                )
                            )
                        ),


                        E(
                            'div',
                            {
                                'id':
                                    'mwan3-mode-segment',

                                'role':
                                    'radiogroup',

                                'aria-label':
                                    _(
                                        'MultiWAN mode'
                                    ),

                                'style':
                                    'display:inline-flex;' +
                                    'align-items:stretch;' +
                                    'max-width:100%;' +
                                    'margin-top:.5em;' +
                                    'margin-bottom:.75em;'
                            },
                            [
                                button(
                                    'failover'
                                ),

                                button(
                                    'balance'
                                )
                            ]
                        ),


                        E(
                            'div',
                            {
                                'id':
                                    'mwan3-mode-feedback',

                                'class':
                                    'cbi-section-descr',

                                'style':
                                    'display:none;' +
                                    'margin-top:.25em;' +
                                    'margin-bottom:1.25em;'
                            }
                        ),


                        E(
                            'div',
                            {
                                'class':
                                    'cbi-section-descr'
                            },
                            notices
                        )
                    ]
                ),


                E(
                    'div',
                    {
                        'class':
                            'cbi-section'
                    },
                    [
                        E(
                            'h3',
                            {},
                            _(
                                'Detected mapping'
                            )
                        ),


                        mappingDescription(
                            'IPv4',
                            parsed.ipv4
                        ),


                        mappingDescription(
                            'IPv6',
                            parsed.ipv6
                        ),


                        E(
                            'div',
                            {
                                'class':
                                    'cbi-section-descr',

                                'style':
                                    'margin-top:1em;'
                            },
                            _(
                                'Only automatically detected default rules and coupled sticky rules are changed. Other custom rules are left untouched.'
                            )
                        )
                    ]
                )
            ]
        );
    }
});
EOF_MWAN3_MODE_VIEW

    chmod 0644 "$MWAN3_MODE_VIEW"
    chmod 0644 "$MWAN3_MODE_MENU"
    chmod 0644 "$MWAN3_MODE_ACL"

    # --------------------------------------------------------
    # Simplified Chinese translation
    #
    # English msgid values are the canonical source strings.
    # luci-i18n-mwan3-zh-cn will compile these PO entries into
    # the runtime LMO translation.
    # --------------------------------------------------------

    if [ ! -f "$MWAN3_MODE_ZH" ]; then

        cat > "$MWAN3_MODE_ZH" <<'EOF_MWAN3_PO_HEADER'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"
EOF_MWAN3_PO_HEADER

    fi


    add_mwan3_zh_translation() {
        MSGID="$1"
        MSGSTR="$2"

        if ! grep -Fqx \
            "msgid \"$MSGID\"" \
            "$MWAN3_MODE_ZH"; then

            printf \
                '\nmsgid "%s"\nmsgstr "%s"\n' \
                "$MSGID" \
                "$MSGSTR" \
                >> "$MWAN3_MODE_ZH"
        fi
    }


    add_mwan3_zh_translation \
        "Mode Switch" \
        "模式切换"

    add_mwan3_zh_translation \
        "MultiWAN Manager - Mode Switch" \
        "MultiWAN 管理器 - 模式切换"

    add_mwan3_zh_translation \
        "MultiWAN mode" \
        "MultiWAN 模式"

    add_mwan3_zh_translation \
        "Current mode" \
        "当前模式"

    add_mwan3_zh_translation \
        "Failover" \
        "故障转移"

    add_mwan3_zh_translation \
        "Load Balancing" \
        "负载均衡"

    add_mwan3_zh_translation \
        "Mixed / Custom" \
        "混合 / 自定义"

    add_mwan3_zh_translation \
        "Unknown" \
        "未知"

    add_mwan3_zh_translation \
        "Applying" \
        "正在应用"

    add_mwan3_zh_translation \
        "Applied" \
        "已应用"

    add_mwan3_zh_translation \
        "Notice" \
        "提示"

    add_mwan3_zh_translation \
        "Error" \
        "错误"

    add_mwan3_zh_translation \
        "Applying %s ..." \
        "正在应用 %s……"

    add_mwan3_zh_translation \
        "Switched to %s." \
        "已切换到 %s。"

    add_mwan3_zh_translation \
        "Re-applied %s." \
        "已重新应用 %s。"

    add_mwan3_zh_translation \
        "Failed to switch to %s." \
        "切换到 %s 失败。"

    add_mwan3_zh_translation \
        "No mode change to apply." \
        "没有需要应用的模式变更。"

    add_mwan3_zh_translation \
        "Unknown error" \
        "未知错误"

    add_mwan3_zh_translation \
        "Switch between the predefined failover and load-balancing policies." \
        "在预设的故障转移和负载均衡策略之间快速切换。"

    add_mwan3_zh_translation \
        "Wired WAN is preferred. USB WAN takes over when the wired WAN fails." \
        "优先使用有线 WAN；有线 WAN 故障后由 USB WAN 接管。"

    add_mwan3_zh_translation \
        "WAN and USB WAN are used together for connection distribution with the configured 3:1 weight." \
        "WAN 与 USB WAN 同时参与连接分流，并按照预设的 3:1 权重分配。"

    add_mwan3_zh_translation \
        "Applying updates the IPv4 default rule, HTTPS sticky rule and the configured IPv6 default rule." \
        "应用时会同时更新 IPv4 默认规则、HTTPS Sticky 规则以及已配置的 IPv6 默认规则。"

    add_mwan3_zh_translation \
        "Unconfigured" \
        "未配置"

    add_mwan3_zh_translation \
        "Ready" \
        "就绪"

    add_mwan3_zh_translation \
        "Unavailable" \
        "不可用"

    add_mwan3_zh_translation \
        "Detected mapping" \
        "检测到的模式映射"

    add_mwan3_zh_translation \
        "Default rule" \
        "默认规则"

    add_mwan3_zh_translation \
        "Failover policy" \
        "故障转移策略"

    add_mwan3_zh_translation \
        "Load-balancing policy" \
        "负载均衡策略"

    add_mwan3_zh_translation \
        "Sticky follower rules" \
        "联动 Sticky 规则"

    add_mwan3_zh_translation \
        "No default rule detected" \
        "未检测到默认规则"

    add_mwan3_zh_translation \
        "Multiple default rules detected" \
        "检测到多个默认规则"

    add_mwan3_zh_translation \
        "No compatible policy pair detected" \
        "未检测到兼容的策略组合"

    add_mwan3_zh_translation \
        "Multiple compatible policy pairs detected" \
        "检测到多个兼容的策略组合"

    add_mwan3_zh_translation \
        "The mwan3 backend is not available." \
        "mwan3 后端当前不可用。"

    add_mwan3_zh_translation \
        "Mode switching is unavailable until a safe mapping can be detected." \
        "在检测到安全且唯一的模式映射之前，模式切换不可用。"

    add_mwan3_zh_translation \
        "Only one address family has a safe mapping. The other family will be left unchanged." \
        "目前只有一种地址族具有安全的模式映射；另一种地址族将保持不变。"

    add_mwan3_zh_translation \
        "mwan3 is stopped. Applying a mode will save the configuration without starting the service." \
        "mwan3 当前已停止；应用模式只会保存配置，不会启动服务。"

    add_mwan3_zh_translation \
        "Automatically detect compatible failover and load-balancing policies and switch the default routing mode safely." \
        "自动检测兼容的故障转移与负载均衡策略，并安全切换默认路由模式。"

    add_mwan3_zh_translation \
        "Only automatically detected default rules and coupled sticky rules are changed. Other custom rules are left untouched." \
        "只修改自动识别出的默认规则及与其联动的 Sticky 规则；其他自定义规则保持不变。"

    add_mwan3_zh_translation \
        "Select a target mode first." \
        "请先选择目标模式。"

    add_mwan3_zh_translation \
        "Switched to %s. mwan3 remains stopped." \
        "已切换到 %s；mwan3 仍保持停止状态。"


    echo "OK: LuCI mwan3 mode switch page installed"
    echo "  Network -> MultiWAN Manager -> Mode Switch"
    echo "  Chinese UI -> 模式切换"

    # ========================================================
    # LuCI mwan3 service control integration
    #
    # Adds:
    #   Network -> MultiWAN Manager -> Service Control
    #
    # URL:
    #   /cgi-bin/luci/admin/network/mwan3/service
    #
    # Features:
    #   - Boot enable / disable as a staged selection
    #   - Native LuCI Save & Apply / Force Apply / Reset
    #   - Immediate Start / Stop / Restart controls
    #   - Boot state and runtime state are independent
    #   - Graceful handling if the mwan3 backend disappears
    #   - Theme-independent alignment for Argon / Aurora / etc.
    #   - Package-owned helper/menu/ACL/view:
    #       removing luci-app-mwan3 removes this enhancement too
    #   - Native LuCI i18n
    # ========================================================

    echo "============================================================"
    echo " Installing LuCI mwan3 service control page"
    echo "============================================================"

    MWAN3_SERVICE_HELPER="$MWAN3_LUCI_DIR/root/usr/sbin/mwan3-service-control"
    MWAN3_SERVICE_VIEW="$MWAN3_LUCI_DIR/htdocs/luci-static/resources/view/mwan3/network/service-control.js"
    MWAN3_SERVICE_MENU="$MWAN3_LUCI_DIR/root/usr/share/luci/menu.d/luci-app-mwan3-service.json"
    MWAN3_SERVICE_ACL="$MWAN3_LUCI_DIR/root/usr/share/rpcd/acl.d/luci-app-mwan3-service.json"

    mkdir -p "$(dirname "$MWAN3_SERVICE_HELPER")"
    mkdir -p "$(dirname "$MWAN3_SERVICE_VIEW")"
    mkdir -p "$(dirname "$MWAN3_SERVICE_MENU")"
    mkdir -p "$(dirname "$MWAN3_SERVICE_ACL")"

    # --------------------------------------------------------
    # Dedicated service helper
    #
    # Keep this inside luci-app-mwan3 instead of global files/
    # so package installation/removal controls its lifecycle.
    # --------------------------------------------------------

    cat > "$MWAN3_SERVICE_HELPER" <<'EOF_MWAN3_SERVICE_HELPER'
#!/bin/sh

INIT='/etc/init.d/mwan3'

die() {
    echo "ERROR: $*" >&2
    exit 1
}

available() {
    [ -x "$INIT" ]
}

show_status() {
    if ! available; then
        echo 'Available: no'
        echo 'Boot: unavailable'
        echo 'Runtime: unavailable'
        return 0
    fi

    echo 'Available: yes'

    if "$INIT" enabled >/dev/null 2>&1; then
        echo 'Boot: enabled'
    else
        echo 'Boot: disabled'
    fi

    if "$INIT" running >/dev/null 2>&1; then
        echo 'Runtime: running'
    else
        echo 'Runtime: stopped'
    fi
}

require_available() {
    available ||
        die "mwan3 init script is not available"
}

case "$1" in
    status)
        show_status
        ;;

    enable)
        require_available
        "$INIT" enable ||
            die "failed to enable mwan3 at boot"
        show_status
        ;;

    disable)
        require_available
        "$INIT" disable ||
            die "failed to disable mwan3 at boot"
        show_status
        ;;

    start)
        require_available
        "$INIT" start ||
            die "failed to start mwan3"
        show_status
        ;;

    stop)
        require_available
        "$INIT" stop ||
            die "failed to stop mwan3"
        show_status
        ;;

    restart)
        require_available
        "$INIT" restart ||
            die "failed to restart mwan3"
        show_status
        ;;

    *)
        echo "Usage: $0 {status|enable|disable|start|stop|restart}" >&2
        exit 2
        ;;
esac

exit 0
EOF_MWAN3_SERVICE_HELPER

    chmod 0755 "$MWAN3_SERVICE_HELPER"

    # --------------------------------------------------------
    # LuCI menu
    #
    # The visible URL remains:
    #
    #   /cgi-bin/luci/admin/network/mwan3/service
    #
    # while the actual JS filename deliberately uses
    # "service-control" to reduce the chance of colliding with
    # a future upstream service.js.
    # --------------------------------------------------------

    cat > "$MWAN3_SERVICE_MENU" <<'EOF_MWAN3_SERVICE_MENU'
{
    "admin/network/mwan3/service": {
        "title": "Service Control",
        "order": 120,
        "action": {
            "type": "view",
            "path": "mwan3/network/service-control"
        },
        "depends": {
            "acl": [
                "luci-app-mwan3-service"
            ]
        }
    }
}
EOF_MWAN3_SERVICE_MENU

    # --------------------------------------------------------
    # RPC ACL
    #
    # Expose only the dedicated helper.
    # Never expose /bin/sh or another general shell.
    # --------------------------------------------------------

    cat > "$MWAN3_SERVICE_ACL" <<'EOF_MWAN3_SERVICE_ACL'
{
    "luci-app-mwan3-service": {
        "description": "Grant access to mwan3 service control",

        "read": {
            "file": {
                "/usr/sbin/mwan3-service-control status": [
                    "exec"
                ]
            },

            "ubus": {
                "file": [
                    "exec"
                ]
            }
        },

        "write": {
            "file": {
                "/usr/sbin/mwan3-service-control enable": [
                    "exec"
                ],

                "/usr/sbin/mwan3-service-control disable": [
                    "exec"
                ],

                "/usr/sbin/mwan3-service-control start": [
                    "exec"
                ],

                "/usr/sbin/mwan3-service-control stop": [
                    "exec"
                ],

                "/usr/sbin/mwan3-service-control restart": [
                    "exec"
                ]
            },

            "ubus": {
                "file": [
                    "exec"
                ]
            }
        }
    }
}
EOF_MWAN3_SERVICE_ACL

    # --------------------------------------------------------
    # LuCI JavaScript view
    # --------------------------------------------------------

    cat > "$MWAN3_SERVICE_VIEW" <<'EOF_MWAN3_SERVICE_VIEW'
'use strict';

'require view';
'require fs';
'require ui';


function parseStatus(output) {
    output = output || '';

    return {
        available:
            /Available:\s*yes/i.test(output),

        boot:
            /Boot:\s*enabled/i.test(output)
                ? 'enabled'
                : /Boot:\s*disabled/i.test(output)
                    ? 'disabled'
                    : 'unavailable',

        runtime:
            /Runtime:\s*running/i.test(output)
                ? 'running'
                : /Runtime:\s*stopped/i.test(output)
                    ? 'stopped'
                    : 'unavailable'
    };
}


function setFeedback(kind, message, detail) {
    var box =
        document.getElementById(
            'mwan3-service-feedback'
        );

    if (!box)
        return;

    while (box.firstChild)
        box.removeChild(box.firstChild);

    var labelText;
    var labelClass;

    switch (kind) {
    case 'success':
        labelText = _('Applied');
        labelClass = 'label success';
        break;

    case 'error':
        labelText = _('Error');
        labelClass = 'label warning';
        break;

    case 'working':
        labelText = _('Applying');
        labelClass = 'label';
        break;

    default:
        labelText = _('Notice');
        labelClass = 'label';
        break;
    }

    box.appendChild(
        E(
            'span',
            {
                'class': labelClass
            },
            labelText
        )
    );

    box.appendChild(
        document.createTextNode(
            '  ' + message
        )
    );

    if (detail) {
        box.appendChild(
            E(
                'pre',
                {
                    'style':
                        'white-space:pre-wrap;' +
                        'margin:.75em 0 0 0;'
                },
                detail
            )
        );
    }

    box.style.display = 'block';
}


function storeFeedback(message) {
    try {
        window.sessionStorage.setItem(
            'mwan3-service-feedback',
            message
        );
    }
    catch (e) {
        /* Non-fatal. */
    }
}


function restoreFeedback() {
    var message = null;

    try {
        message =
            window.sessionStorage.getItem(
                'mwan3-service-feedback'
            );

        window.sessionStorage.removeItem(
            'mwan3-service-feedback'
        );
    }
    catch (e) {
        /* Non-fatal. */
    }

    if (message)
        setFeedback(
            'success',
            message
        );
}


/*
 * Align an interactive control to the actual rendered
 * content position of a span inside a LuCI paragraph.
 *
 * This avoids theme-specific hard-coded margins:
 *
 *   Argon
 *   Aurora
 *   Material
 *   OpenWrt themes
 *
 * can all have slightly different section / paragraph
 * padding and margins.
 */
function alignControlToAnchor(anchorId, controlId) {
    var anchor =
        document.getElementById(anchorId);

    var control =
        document.getElementById(controlId);

    if (!anchor || !control)
        return;

    control.style.marginInlineStart = '0px';

    window.requestAnimationFrame(function() {
        var targetLeft =
            anchor.getBoundingClientRect().left;

        var currentLeft =
            control.getBoundingClientRect().left;

        var delta =
            Math.round(
                targetLeft - currentLeft
            );

        /*
         * Only compensate plausible theme layout offsets.
         * Do not allow a future DOM/layout change to create
         * an unexpectedly huge margin.
         */
        if (delta > 1 && delta < 64)
            control.style.marginInlineStart =
                delta + 'px';
    });
}


function alignServiceControls() {
    alignControlToAnchor(
        'mwan3-service-boot-anchor',
        'mwan3-service-boot-segment'
    );

    alignControlToAnchor(
        'mwan3-service-runtime-anchor',
        'mwan3-service-runtime-actions'
    );
}


return view.extend({
    available: false,

    actualBoot: 'unavailable',
    pendingBoot: 'unavailable',

    runtime: 'unavailable',


    /*
     * No standalone Save button.
     *
     * Selecting boot enabled / disabled only stages the
     * desired value.
     *
     * LuCI provides its native:
     *
     *   Save & Apply
     *   Force / unchecked apply
     *   Reset
     */
    handleSave: null,


    load: function() {
        return fs.exec(
            '/usr/sbin/mwan3-service-control',
            [ 'status' ]
        ).catch(function(err) {
            return {
                code: 1,
                stdout: '',
                stderr: String(err)
            };
        });
    },


    updateBootSegment: function() {
        var enable =
            document.getElementById(
                'mwan3-service-enable'
            );

        var disable =
            document.getElementById(
                'mwan3-service-disable'
            );

        if (!enable || !disable)
            return;

        var selected =
            this.pendingBoot;

        enable.setAttribute(
            'aria-checked',
            selected === 'enabled'
                ? 'true'
                : 'false'
        );

        disable.setAttribute(
            'aria-checked',
            selected === 'disabled'
                ? 'true'
                : 'false'
        );

        enable.className =
            'btn ' +
            (
                selected === 'enabled'
                    ? 'cbi-button-positive'
                    : 'cbi-button-neutral'
            );

        disable.className =
            'btn ' +
            (
                selected === 'disabled'
                    ? 'cbi-button-positive'
                    : 'cbi-button-neutral'
            );
    },


    handleSelectBoot: function(which, ev) {
        if (ev)
            ev.preventDefault();

        if (!this.available)
            return false;

        if (
            which !== 'enabled' &&
            which !== 'disabled'
        )
            return false;

        /*
         * Stage only.
         * Do not change the init script yet.
         */
        this.pendingBoot =
            which;

        this.updateBootSegment();

        var feedback =
            document.getElementById(
                'mwan3-service-feedback'
            );

        if (feedback)
            feedback.style.display = 'none';

        return false;
    },


    /*
     * Native LuCI Save & Apply handler.
     *
     * This changes only boot-time autostart.
     * It deliberately does NOT start or stop the currently
     * running mwan3 service.
     */
    handleSaveApply: function(ev, applyMode) {
        var self =
            this;

        var target =
            this.pendingBoot;

        var forceApply =
            String(applyMode) === '1';

        if (!this.available) {
            setFeedback(
                'error',
                _('mwan3 is not available.')
            );

            return Promise.resolve();
        }

        if (
            target !== 'enabled' &&
            target !== 'disabled'
        ) {
            setFeedback(
                'error',
                _('Unknown boot state.')
            );

            return Promise.resolve();
        }

        if (
            !forceApply &&
            target === this.actualBoot
        ) {
            setFeedback(
                'info',
                _('No boot setting change to apply.')
            );

            return Promise.resolve();
        }

        var action =
            target === 'enabled'
                ? 'enable'
                : 'disable';

        var label =
            target === 'enabled'
                ? _('Enabled at boot')
                : _('Disabled at boot');

        setFeedback(
            'working',
            _('Applying boot setting...')
        );

        return fs.exec(
            '/usr/sbin/mwan3-service-control',
            [ action ]
        ).then(function(res) {

            if (
                !res ||
                res.code !== 0
            ) {
                setFeedback(
                    'error',
                    _('Failed to change the boot setting.'),
                    (
                        res &&
                        (
                            res.stderr ||
                            res.stdout
                        )
                    ) ||
                    _('Unknown error')
                );

                return;
            }

            self.actualBoot =
                target;

            self.pendingBoot =
                target;

            storeFeedback(
                _('Boot setting changed to ') +
                label +
                '.'
            );

            window.location.reload();

        }).catch(function(err) {

            setFeedback(
                'error',
                _('Failed to change the boot setting.'),
                String(err)
            );
        });
    },


    /*
     * Native LuCI Reset button.
     *
     * Discard only the staged boot setting.
     */
    handleReset: function(ev) {
        if (ev)
            ev.preventDefault();

        this.pendingBoot =
            this.actualBoot;

        this.updateBootSegment();

        var feedback =
            document.getElementById(
                'mwan3-service-feedback'
            );

        if (feedback)
            feedback.style.display = 'none';

        return Promise.resolve();
    },


    /*
     * Runtime actions are immediate.
     *
     * They do NOT modify the boot-time enable/disable state.
     */
    handleRuntimeAction: function(action, ev) {
        if (ev)
            ev.preventDefault();

        if (!this.available) {
            setFeedback(
                'error',
                _('mwan3 is not available.')
            );

            return Promise.resolve();
        }

        var actionLabel =
            action === 'start'
                ? _('Start')
                : action === 'stop'
                    ? _('Stop')
                    : _('Restart');

        setFeedback(
            'working',
            actionLabel +
                ' mwan3...'
        );

        return fs.exec(
            '/usr/sbin/mwan3-service-control',
            [ action ]
        ).then(function(res) {

            if (
                !res ||
                res.code !== 0
            ) {
                setFeedback(
                    'error',
                    actionLabel +
                        ' mwan3 ' +
                        _('failed.'),
                    (
                        res &&
                        (
                            res.stderr ||
                            res.stdout
                        )
                    ) ||
                    _('Unknown error')
                );

                return;
            }

            var resultText =
                action === 'start'
                    ? _('mwan3 started.')
                    : action === 'stop'
                        ? _('mwan3 stopped.')
                        : _('mwan3 restarted.');

            storeFeedback(
                resultText
            );

            window.location.reload();

        }).catch(function(err) {

            setFeedback(
                'error',
                actionLabel +
                    ' mwan3 ' +
                    _('failed.'),
                String(err)
            );
        });
    },


    render: function(status) {
        var parsed =
            parseStatus(
                status && status.stdout
                    ? status.stdout
                    : ''
            );

        var self =
            this;

        this.available =
            parsed.available;

        this.actualBoot =
            parsed.boot;

        this.pendingBoot =
            parsed.boot;

        this.runtime =
            parsed.runtime;

        /*
         * Run after LuCI has inserted the view into the DOM.
         */
        window.setTimeout(
            function() {
                alignServiceControls();
                restoreFeedback();
            },
            0
        );


        function bootButton(
            which,
            text,
            left
        ) {
            var active =
                self.pendingBoot === which;

            return E(
                'button',
                {
                    'id':
                        'mwan3-service-' +
                        (
                            which === 'enabled'
                                ? 'enable'
                                : 'disable'
                        ),

                    'type':
                        'button',

                    'role':
                        'radio',

                    'aria-checked':
                        active
                            ? 'true'
                            : 'false',

                    'disabled':
                        self.available
                            ? null
                            : 'disabled',

                    'class':
                        'btn ' +
                        (
                            active
                                ? 'cbi-button-positive'
                                : 'cbi-button-neutral'
                        ),

                    'style':
                        left
                            ? (
                                'margin:0;' +
                                'min-width:9em;' +
                                'border-radius:.375em 0 0 .375em;'
                              )
                            : (
                                'margin:0;' +
                                'margin-left:-1px;' +
                                'min-width:9em;' +
                                'border-radius:0 .375em .375em 0;'
                              ),

                    'click':
                        ui.createHandlerFn(
                            self,
                            'handleSelectBoot',
                            which
                        )
                },

                text
            );
        }


        function actionButton(
            action,
            text,
            positive,
            disabled
        ) {
            return E(
                'button',
                {
                    'type':
                        'button',

                    'class':
                        'cbi-button ' +
                        (
                            positive
                                ? 'cbi-button-positive'
                                : 'cbi-button-action'
                        ),

                    'disabled':
                        disabled
                            ? 'disabled'
                            : null,

                    'style':
                        'margin-right:.5em;',

                    'click':
                        ui.createHandlerFn(
                            self,
                            'handleRuntimeAction',
                            action
                        )
                },

                text
            );
        }


        var bootLabel =
            !parsed.available
                ? _('Unavailable')
                : parsed.boot === 'enabled'
                    ? _('Enabled')
                    : parsed.boot === 'disabled'
                        ? _('Disabled')
                        : _('Unknown');

        var bootClass =
            parsed.available &&
            parsed.boot === 'enabled'
                ? 'label success'
                : 'label warning';


        var runtimeLabel =
            !parsed.available
                ? _('Unavailable')
                : parsed.runtime === 'running'
                    ? _('Running')
                    : parsed.runtime === 'stopped'
                        ? _('Stopped')
                        : _('Unknown');

        var runtimeClass =
            parsed.available &&
            parsed.runtime === 'running'
                ? 'label success'
                : 'label warning';


        return E(
            'div',
            {
                'class':
                    'cbi-map'
            },
            [
                E(
                    'h2',
                    {},
                    _(
                        'MultiWAN Manager - Service Control'
                    )
                ),


                E(
                    'div',
                    {
                        'class':
                            'cbi-map-descr'
                    },
                    _(
                        'Control mwan3 boot-time autostart and its current runtime state. Boot settings are applied with Save & Apply; Start, Stop and Restart take effect immediately.'
                    )
                ),


                E(
                    'div',
                    {
                        'class':
                            'cbi-section'
                    },
                    [
                        E(
                            'h3',
                            {},
                            _('Boot autostart')
                        ),


                        E(
                            'p',
                            {},
                            E(
                                'span',
                                {
                                    'id':
                                        'mwan3-service-boot-anchor'
                                },
                                [
                                    document.createTextNode(
                                        _('Current status:') +
                                        ' '
                                    ),

                                    E(
                                        'span',
                                        {
                                            'class':
                                                bootClass
                                        },
                                        bootLabel
                                    )
                                ]
                            )
                        ),


                        E(
                            'div',
                            {
                                'id':
                                    'mwan3-service-boot-segment',

                                'role':
                                    'radiogroup',

                                'aria-label':
                                    _(
                                        'mwan3 boot autostart'
                                    ),

                                'style':
                                    'display:inline-flex;' +
                                    'align-items:stretch;' +
                                    'max-width:100%;' +
                                    'margin-top:.5em;' +
                                    'margin-bottom:.75em;'
                            },
                            [
                                bootButton(
                                    'enabled',
                                    _('Enable at boot'),
                                    true
                                ),

                                bootButton(
                                    'disabled',
                                    _('Disable at boot'),
                                    false
                                )
                            ]
                        ),


                        E(
                            'div',
                            {
                                'class':
                                    'cbi-section-descr'
                            },
                            _(
                                'This setting only controls whether mwan3 starts automatically on the next boot. It does not start or stop the service in the current session.'
                            )
                        )
                    ]
                ),


                E(
                    'div',
                    {
                        'class':
                            'cbi-section'
                    },
                    [
                        E(
                            'h3',
                            {},
                            _('Current runtime state')
                        ),


                        E(
                            'p',
                            {},
                            E(
                                'span',
                                {
                                    'id':
                                        'mwan3-service-runtime-anchor'
                                },
                                [
                                    document.createTextNode(
                                        _('Current status:') +
                                        ' '
                                    ),

                                    E(
                                        'span',
                                        {
                                            'class':
                                                runtimeClass
                                        },
                                        runtimeLabel
                                    )
                                ]
                            )
                        ),


                        /*
                         * Do not use a bare <p> for the action row.
                         *
                         * Argon / Aurora have different default
                         * paragraph margins. Explicit spacing here
                         * keeps the two themes visually consistent.
                         */
                        E(
                            'div',
                            {
                                'id':
                                    'mwan3-service-runtime-actions',

                                'style':
                                    'display:flex;' +
                                    'align-items:center;' +
                                    'flex-wrap:wrap;' +
                                    'margin-top:.75em;' +
                                    'margin-bottom:1em;'
                            },
                            [
                                actionButton(
                                    'start',
                                    _('Start'),
                                    true,
                                    !parsed.available ||
                                    parsed.runtime === 'running'
                                ),

                                actionButton(
                                    'stop',
                                    _('Stop'),
                                    false,
                                    !parsed.available ||
                                    parsed.runtime === 'stopped'
                                ),

                                actionButton(
                                    'restart',
                                    _('Restart'),
                                    false,
                                    !parsed.available
                                )
                            ]
                        ),


                        E(
                            'div',
                            {
                                'class':
                                    'cbi-section-descr'
                            },
                            _(
                                'Stop only affects the current session. If boot autostart remains enabled, mwan3 will start again after the router is rebooted.'
                            )
                        )
                    ]
                ),


                E(
                    'div',
                    {
                        'id':
                            'mwan3-service-feedback',

                        'class':
                            'cbi-section-descr',

                        'style':
                            'display:none;' +
                            'margin-top:.5em;' +
                            'margin-bottom:1.25em;'
                    }
                )
            ]
        );
    }
});
EOF_MWAN3_SERVICE_VIEW

    chmod 0644 "$MWAN3_SERVICE_VIEW"
    chmod 0644 "$MWAN3_SERVICE_MENU"
    chmod 0644 "$MWAN3_SERVICE_ACL"

    # Helper itself must remain executable.
    chmod 0755 "$MWAN3_SERVICE_HELPER"

    # --------------------------------------------------------
    # Simplified Chinese translations
    #
    # Reuse the translation helper and PO file already created
    # by the Mode Switch integration above.
    # --------------------------------------------------------

    add_mwan3_zh_translation \
        "Service Control" \
        "服务控制"

    add_mwan3_zh_translation \
        "MultiWAN Manager - Service Control" \
        "MultiWAN 管理器 - 服务控制"

    add_mwan3_zh_translation \
        "Boot autostart" \
        "开机自启动"

    add_mwan3_zh_translation \
        "Current runtime state" \
        "当前运行状态"

    add_mwan3_zh_translation \
        "Current status:" \
        "当前状态："

    add_mwan3_zh_translation \
        "mwan3 boot autostart" \
        "mwan3 开机自启动"

    add_mwan3_zh_translation \
        "Enable at boot" \
        "开机自启动"

    add_mwan3_zh_translation \
        "Disable at boot" \
        "不开机自启动"

    add_mwan3_zh_translation \
        "Enabled" \
        "已启用"

    add_mwan3_zh_translation \
        "Disabled" \
        "已禁用"

    add_mwan3_zh_translation \
        "Enabled at boot" \
        "开机自启动"

    add_mwan3_zh_translation \
        "Disabled at boot" \
        "不开机自启动"

    add_mwan3_zh_translation \
        "Running" \
        "运行中"

    add_mwan3_zh_translation \
        "Stopped" \
        "已停止"

    add_mwan3_zh_translation \
        "Unavailable" \
        "不可用"

    add_mwan3_zh_translation \
        "Start" \
        "启动"

    add_mwan3_zh_translation \
        "Stop" \
        "停止"

    add_mwan3_zh_translation \
        "Restart" \
        "重启"

    add_mwan3_zh_translation \
        "mwan3 is not available." \
        "mwan3 当前不可用。"

    add_mwan3_zh_translation \
        "Unknown boot state." \
        "无法确定目标启动状态。"

    add_mwan3_zh_translation \
        "No boot setting change to apply." \
        "开机自启动设置没有变化。"

    add_mwan3_zh_translation \
        "Applying boot setting..." \
        "正在应用开机自启动设置……"

    add_mwan3_zh_translation \
        "Failed to change the boot setting." \
        "修改开机自启动设置失败。"

    add_mwan3_zh_translation \
        "Boot setting changed to " \
        "已设置为"

    add_mwan3_zh_translation \
        "failed." \
        "失败。"

    add_mwan3_zh_translation \
        "mwan3 started." \
        "mwan3 已启动。"

    add_mwan3_zh_translation \
        "mwan3 stopped." \
        "mwan3 已停止。"

    add_mwan3_zh_translation \
        "mwan3 restarted." \
        "mwan3 已重启。"

    add_mwan3_zh_translation \
        "Control mwan3 boot-time autostart and its current runtime state. Boot settings are applied with Save & Apply; Start, Stop and Restart take effect immediately." \
        "控制 mwan3 的开机自启动与当前运行状态。开机自启动设置在“保存并应用”后生效；启动、停止、重启会立即执行。"

    add_mwan3_zh_translation \
        "This setting only controls whether mwan3 starts automatically on the next boot. It does not start or stop the service in the current session." \
        "这里只控制下一次开机是否自动启动 mwan3，不会自动停止或启动当前会话中的 mwan3。"

    add_mwan3_zh_translation \
        "Stop only affects the current session. If boot autostart remains enabled, mwan3 will start again after the router is rebooted." \
        "“停止”只影响本次运行；如果仍启用了开机自启动，下次重启路由器时 mwan3 仍会自动启动。"

    echo "OK: LuCI mwan3 service control page installed"
    echo "  Network -> MultiWAN Manager -> Service Control"
    echo "  Chinese UI -> 服务控制"

fi


# ============================================================
# First-boot USB tether WAN + optional IPv6 + mwan3
# failover / load-balancing configuration
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
        uci set mwan3.wan.track_method='ping'
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

    # USB member for load balancing.
    # Same metric as wan_m1_w3 => load balancing.
    # Weight 3:1 => WAN receives roughly 75% of new flows,
    # USB WAN roughly 25%.

    uci set mwan3.usbwan_m1_w1='member'
    uci set mwan3.usbwan_m1_w1.interface='usbwan'
    uci set mwan3.usbwan_m1_w1.metric='1'
    uci set mwan3.usbwan_m1_w1.weight='1'

    # --------------------------------------------------------
    # IPv4 primary / backup policy
    # --------------------------------------------------------

    uci set mwan3.wan_usb='policy'

    uci -q delete mwan3.wan_usb.use_member || true

    uci add_list mwan3.wan_usb.use_member='wan_m1_w3'
    uci add_list mwan3.wan_usb.use_member='usbwan_m2_w1'

    uci set mwan3.wan_usb.last_resort='default'

    # --------------------------------------------------------
    # IPv4 load-balancing policy
    #
    # Same member metric:
    #   WAN     metric 1, weight 3
    #   USB WAN metric 1, weight 1
    #
    # Approximate new-flow distribution:
    #   WAN : USB WAN = 3 : 1
    # --------------------------------------------------------

    uci set mwan3.wan_usb_bal='policy'

    uci -q delete mwan3.wan_usb_bal.use_member || true

    uci add_list mwan3.wan_usb_bal.use_member='wan_m1_w3'
    uci add_list mwan3.wan_usb_bal.use_member='usbwan_m1_w1'

    uci set mwan3.wan_usb_bal.last_resort='default'

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

        uci set mwan3.usbwan6_m1_w1='member'
        uci set mwan3.usbwan6_m1_w1.interface='usbwan6'
        uci set mwan3.usbwan6_m1_w1.metric='1'
        uci set mwan3.usbwan6_m1_w1.weight='1'

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

        # ----------------------------------------------------
        # IPv6 load-balancing policy
        # ----------------------------------------------------

        uci set mwan3.wan6_usb_bal='policy'

        uci -q delete mwan3.wan6_usb_bal.use_member || true

        if uci -q get network.wan6 >/dev/null 2>&1; then
            uci add_list mwan3.wan6_usb_bal.use_member='wan6_m1_w3'
        fi

        uci add_list mwan3.wan6_usb_bal.use_member='usbwan6_m1_w1'

        uci set mwan3.wan6_usb_bal.last_resort='default'

        # IPv6 default routing.

        uci set mwan3.default_rule_v6='rule'
        uci set mwan3.default_rule_v6.dest_ip='::/0'
        uci set mwan3.default_rule_v6.family='ipv6'
        uci set mwan3.default_rule_v6.use_policy='wan6_usb'

    fi

    uci commit mwan3 || exit 1

    # Enable mwan3 at boot.

    /etc/init.d/mwan3 enable >/dev/null 2>&1 || true

    log_msg "mwan3 WAN failover and load-balancing policies configured"

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
