#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default

# Copy custom local packages into OpenWrt tree so they are available during build
if [ -d "$GITHUB_WORKSPACE/package/luci-compat-keep" ]; then
  mkdir -p package
  cp -r "$GITHUB_WORKSPACE/package/luci-compat-keep" package/
fi

# ============================================================
# Add kmod-nft-fullcone from official ImmortalWrt 24.10
# PadavanOnly MT798x tree already contains nftables/libnftnl/fw4
# fullcone support, but lacks package/network/utils/fullconenat-nft
# ============================================================

echo "============================================================"
echo " Importing official ImmortalWrt fullconenat-nft package"
echo "============================================================"

FULLCONE_TMP="$(mktemp -d)"

git clone \
  --depth 1 \
  --filter=blob:none \
  --sparse \
  -b openwrt-24.10 \
  https://github.com/immortalwrt/immortalwrt.git \
  "$FULLCONE_TMP"

git -C "$FULLCONE_TMP" sparse-checkout set \
  package/network/utils/fullconenat-nft

rm -rf package/network/utils/fullconenat-nft
mkdir -p package/network/utils

cp -a \
  "$FULLCONE_TMP/package/network/utils/fullconenat-nft" \
  package/network/utils/

rm -rf "$FULLCONE_TMP"

if [ ! -s package/network/utils/fullconenat-nft/Makefile ]; then
    echo "ERROR: fullconenat-nft Makefile import failed"
    exit 1
fi

echo "fullconenat-nft package imported successfully."

echo "Included patches:"
find package/network/utils/fullconenat-nft/patches \
  -maxdepth 1 -type f -print 2>/dev/null || true

# ============================================================
# Import minimal official LinkEase QuickStart dependency chain
#
# Only import the packages required by official QuickStart.
# DO NOT add istore / nas / nas_luci as full feeds.
#
# Sources:
#   quickstart:
#     https://github.com/linkease/nas-packages
#
#   luci-app-quickstart:
#     https://github.com/linkease/nas-packages-luci
#
#   iStore dependencies:
#     https://github.com/linkease/istore
# ============================================================

echo "============================================================"
echo " Importing minimal official LinkEase QuickStart packages"
echo "============================================================"

QUICKSTART_DST="package/custom/linkease-quickstart"

# ------------------------------------------------------------
# Safety check:
# Refuse to continue if the upstream tree already contains one
# of these package directories. This avoids silently creating
# duplicate package definitions if PadavanOnly adds them later.
# ------------------------------------------------------------

for pkg in \
  quickstart \
  luci-app-quickstart \
  luci-app-store \
  luci-lib-taskd \
  luci-lib-xterm \
  taskd
do
  EXISTING="$(
    find package \
      -type d \
      -name "$pkg" \
      ! -path "${QUICKSTART_DST}/*" \
      -print -quit 2>/dev/null || true
  )"

  if [ -n "$EXISTING" ]; then
    echo "ERROR: package '$pkg' already exists:"
    echo "  $EXISTING"
    echo "Refusing to import another copy."
    exit 1
  fi
done

rm -rf "$QUICKSTART_DST"
mkdir -p "$QUICKSTART_DST"

# ============================================================
# 1. quickstart backend
#    Source: linkease/nas-packages
# ============================================================

QUICKSTART_CORE_TMP="$(mktemp -d)"

git clone \
  --depth 1 \
  --filter=blob:none \
  --sparse \
  -b master \
  https://github.com/linkease/nas-packages.git \
  "$QUICKSTART_CORE_TMP"

git -C "$QUICKSTART_CORE_TMP" sparse-checkout set \
  network/services/quickstart

if [ ! -s "$QUICKSTART_CORE_TMP/network/services/quickstart/Makefile" ]; then
  echo "ERROR: official quickstart backend import failed"
  rm -rf "$QUICKSTART_CORE_TMP"
  exit 1
fi

cp -a \
  "$QUICKSTART_CORE_TMP/network/services/quickstart" \
  "$QUICKSTART_DST/quickstart"

rm -rf "$QUICKSTART_CORE_TMP"

# ============================================================
# 2. LuCI QuickStart frontend
#    Source: linkease/nas-packages-luci
# ============================================================

QUICKSTART_LUCI_TMP="$(mktemp -d)"

git clone \
  --depth 1 \
  --filter=blob:none \
  --sparse \
  -b main \
  https://github.com/linkease/nas-packages-luci.git \
  "$QUICKSTART_LUCI_TMP"

git -C "$QUICKSTART_LUCI_TMP" sparse-checkout set \
  luci/luci-app-quickstart

if [ ! -s "$QUICKSTART_LUCI_TMP/luci/luci-app-quickstart/Makefile" ]; then
  echo "ERROR: official luci-app-quickstart import failed"
  rm -rf "$QUICKSTART_LUCI_TMP"
  exit 1
fi

cp -a \
  "$QUICKSTART_LUCI_TMP/luci/luci-app-quickstart" \
  "$QUICKSTART_DST/luci-app-quickstart"

rm -rf "$QUICKSTART_LUCI_TMP"

# ============================================================
# 3. Minimal iStore dependency chain required by QuickStart
#    Source: linkease/istore
#
#    luci-app-store
#      -> luci-lib-taskd
#           -> luci-lib-xterm
#           -> taskd
# ============================================================

QUICKSTART_ISTORE_TMP="$(mktemp -d)"

git clone \
  --depth 1 \
  --filter=blob:none \
  --sparse \
  -b main \
  https://github.com/linkease/istore.git \
  "$QUICKSTART_ISTORE_TMP"

git -C "$QUICKSTART_ISTORE_TMP" sparse-checkout set \
  luci/luci-app-store \
  luci/luci-lib-taskd \
  luci/luci-lib-xterm \
  luci/taskd

for pkg in \
  luci-app-store \
  luci-lib-taskd \
  luci-lib-xterm \
  taskd
do
  if [ ! -s "$QUICKSTART_ISTORE_TMP/luci/$pkg/Makefile" ]; then
    echo "ERROR: official iStore dependency '$pkg' import failed"
    rm -rf "$QUICKSTART_ISTORE_TMP"
    exit 1
  fi

  cp -a \
    "$QUICKSTART_ISTORE_TMP/luci/$pkg" \
    "$QUICKSTART_DST/$pkg"
done

rm -rf "$QUICKSTART_ISTORE_TMP"

# ============================================================
# Final verification
# ============================================================

echo
echo "QuickStart package sources imported:"

for pkg in \
  quickstart \
  luci-app-quickstart \
  luci-app-store \
  luci-lib-taskd \
  luci-lib-xterm \
  taskd
do
  if [ ! -s "$QUICKSTART_DST/$pkg/Makefile" ]; then
    echo "ERROR: missing Makefile for '$pkg'"
    exit 1
  fi

  echo "  OK: $QUICKSTART_DST/$pkg"
done

echo
echo "Minimal LinkEase QuickStart import completed successfully."
echo "No LinkEase feed was added to feeds.conf.default."

# ============================================================
# Import selected third-party LuCI applications
#
# Minimal source import only.
# No additional full feeds are added to feeds.conf.default.
#
#   PartExp:
#     https://github.com/sirpdboy/luci-app-partexp
#
#   SMART Info:
#     https://github.com/huajijam/luci-app-smartinfo
#
#   File Transfer:
#     https://github.com/DustReliant/luci-app-filetransfer
# ============================================================

echo "============================================================"
echo " Importing selected third-party LuCI applications"
echo "============================================================"

THIRDPARTY_DST="package/custom/thirdparty-luci"

mkdir -p "$THIRDPARTY_DST"

# ============================================================
# Helper: refuse to silently overwrite an existing package
# ============================================================

check_package_conflict() {
    local pkg="$1"
    local expected="$2"
    local existing

    existing="$(
        find package \
            -type f \
            -name Makefile \
            ! -path "${expected}/*" \
            -exec grep -l -E \
                "(PKG_NAME[[:space:]]*:?=[[:space:]]*${pkg}|Package/${pkg}([[:space:]]|$))" \
                {} + 2>/dev/null \
            | head -n 1 || true
    )"

    if [ -n "$existing" ]; then
        echo "ERROR: package '$pkg' already exists:"
        echo "  $existing"
        echo "Refusing to import another copy."
        exit 1
    fi
}

# ============================================================
# 1. luci-app-partexp
#
# The sirpdboy repository contains the actual OpenWrt package
# inside the nested luci-app-partexp/ directory, so import only
# that directory instead of the complete repository.
# ============================================================

PARTEXP_DST="$THIRDPARTY_DST/luci-app-partexp"

check_package_conflict \
    "luci-app-partexp" \
    "$PARTEXP_DST"

PARTEXP_TMP="$(mktemp -d)"

git clone \
    --depth 1 \
    --filter=blob:none \
    --sparse \
    -b main \
    https://github.com/sirpdboy/luci-app-partexp.git \
    "$PARTEXP_TMP"

git -C "$PARTEXP_TMP" sparse-checkout set \
    luci-app-partexp

if [ ! -s "$PARTEXP_TMP/luci-app-partexp/Makefile" ]; then
    echo "ERROR: luci-app-partexp Makefile import failed"
    rm -rf "$PARTEXP_TMP"
    exit 1
fi

rm -rf "$PARTEXP_DST"
cp -a \
    "$PARTEXP_TMP/luci-app-partexp" \
    "$PARTEXP_DST"

rm -rf "$PARTEXP_TMP"

echo "OK: luci-app-partexp imported"


# ============================================================
# 2. luci-app-smartinfo
#
# Upstream repository itself is already an OpenWrt package.
# Only dependency: smartmontools.
# ============================================================

SMARTINFO_DST="$THIRDPARTY_DST/luci-app-smartinfo"

check_package_conflict \
    "luci-app-smartinfo" \
    "$SMARTINFO_DST"

SMARTINFO_TMP="$(mktemp -d)"

git clone \
    --depth 1 \
    --filter=blob:none \
    -b main \
    https://github.com/huajijam/luci-app-smartinfo.git \
    "$SMARTINFO_TMP"

if [ ! -s "$SMARTINFO_TMP/Makefile" ]; then
    echo "ERROR: luci-app-smartinfo Makefile import failed"
    rm -rf "$SMARTINFO_TMP"
    exit 1
fi

rm -rf "$SMARTINFO_DST"
mkdir -p "$SMARTINFO_DST"

rm -rf "$SMARTINFO_TMP/.git"

cp -a \
    "$SMARTINFO_TMP/." \
    "$SMARTINFO_DST/"

rm -rf "$SMARTINFO_TMP"

echo "OK: luci-app-smartinfo imported"


# ============================================================
# 3. luci-app-filetransfer
#
# Use the maintained standalone version instead of the old
# luci-lib-fs based implementation.
#
# Dependencies:
#   luci-base
#   luci-lib-jsonc
#   luci-lib-nixio
# ============================================================

FILETRANSFER_DST="$THIRDPARTY_DST/luci-app-filetransfer"

check_package_conflict \
    "luci-app-filetransfer" \
    "$FILETRANSFER_DST"

FILETRANSFER_TMP="$(mktemp -d)"

git clone \
    --depth 1 \
    --filter=blob:none \
    -b master \
    https://github.com/DustReliant/luci-app-filetransfer.git \
    "$FILETRANSFER_TMP"

if [ ! -s "$FILETRANSFER_TMP/Makefile" ]; then
    echo "ERROR: luci-app-filetransfer Makefile import failed"
    rm -rf "$FILETRANSFER_TMP"
    exit 1
fi

rm -rf "$FILETRANSFER_DST"
mkdir -p "$FILETRANSFER_DST"

rm -rf "$FILETRANSFER_TMP/.git"

cp -a \
    "$FILETRANSFER_TMP/." \
    "$FILETRANSFER_DST/"

rm -rf "$FILETRANSFER_TMP"

echo "OK: luci-app-filetransfer imported"


# ============================================================
# Final verification
# ============================================================

echo
echo "Third-party LuCI package verification:"

for pkg in \
    luci-app-partexp \
    luci-app-smartinfo \
    luci-app-filetransfer
do
    if [ ! -s "$THIRDPARTY_DST/$pkg/Makefile" ]; then
        echo "ERROR: missing Makefile for '$pkg'"
        exit 1
    fi

    echo "  OK: $THIRDPARTY_DST/$pkg"
done

echo
echo "Selected third-party LuCI applications imported successfully."
echo "No additional feed was added."

git clone https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora
git clone https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config
git clone https://github.com/timsaya/luci-app-bandix package/luci-app-bandix
git clone https://github.com/timsaya/openwrt-bandix package/openwrt-bandix
