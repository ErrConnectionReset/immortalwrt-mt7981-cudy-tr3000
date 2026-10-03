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

# Kernel 6.6.113+ changed nft_expr_ops.validate() from 3 args to 2 args.
# The current PadavanOnly kernel is 6.6.133, so apply compatibility patch.
mkdir -p package/network/utils/fullconenat-nft/patches

wget -qO \
  package/network/utils/fullconenat-nft/patches/010-fix-build-with-kernel-6.12.patch \
  https://raw.githubusercontent.com/chasey-dev/immortalwrt-mt798x-rebase/master/package/network/utils/fullconenat-nft/patches/010-fix-build-with-kernel-6.12.patch

if [ ! -s package/network/utils/fullconenat-nft/Makefile ]; then
    echo "ERROR: fullconenat-nft Makefile import failed"
    exit 1
fi

if [ ! -s package/network/utils/fullconenat-nft/patches/010-fix-build-with-kernel-6.12.patch ]; then
    echo "ERROR: fullconenat-nft kernel compatibility patch download failed"
    exit 1
fi

echo "fullconenat-nft package imported successfully."

git clone https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora
git clone https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config
git clone https://github.com/timsaya/luci-app-bandix package/luci-app-bandix
git clone https://github.com/timsaya/openwrt-bandix package/openwrt-bandix
