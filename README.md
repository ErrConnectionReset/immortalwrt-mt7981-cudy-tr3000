[定制教程](https://xiabee.eu.org/customize.html) | [刷写教程](https://xiabee.eu.org/install.html)

<div align=center>
<img src="tr3000.png" height=200px align="center">
</div>

---

## immortalwrt 源码

编译自 https://github.com/padavanonly/immortalwrt-mt798x-6.6 ，兼容 Cudy Tr3000 128M 新 flash

---

## 大分区 ubootmod 固件

本仓库默认编译的 ubootmod 固件为 112M 分区，若你想编译 122M 分区固件，请将 `diy-part2.sh` 中取消以下注释：

```sh
# set ubi to 122M
# sed -i 's/reg = <0x5c0000 0x7000000>;/reg = <0x5c0000 0x7a40000>;/' target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts
```

---

## DHCP uboot

编译自 https://github.com/weekdaycare/bl-mt798x-dhcpd 感谢大佬开源，兼容新 flash

![](/uboot.png)

128M uboot 为三分区 uboot 支持原厂 ubi 大小 64MB，扩容 ubi 分区 112MB，最大 ubi 分区 122MB

256M uboot 为单分区 uboot

---

## USB 供电控制

上游的最新源码已经打开了默认供电，具体可以见这条 [commit](https://github.com/padavanonly/immortalwrt-mt798x-6.6/commit/86356f8a2f796e5808fda25ce3e3bf6b3cc3278e)

若你想关闭 USB 供电执行命令

```bash
echo 0 > /sys/class/gpio/modem_power/value
```

恢复供电执行命令

```bash
echo 1 > /sys/class/gpio/modem_power/value
```

---

## 第三方软件包

- [OpenClash](https://github.com/vernesong/OpenClash)
- [Bandix](https://github.com/timsaya/luci-app-bandix)
- [luci-theme-aurora](https://github.com/eamonxg/luci-theme-aurora)
- [luci-app-aurora-config](https://github.com/eamonxg/luci-app-aurora-config)
- luci-app-ttyd
- luci-app-upnp
- kmod-usb-net-cdc-ether
- kmod-usb-net-rndis
- kmod-mtd-rw

---

## SSH 连接 Action

可以通过 SSH 连接到 GitHub Actions 工作流，在云端执行 `make menuconfig` 并修改当前设备的编译配置。

手动运行 `ImmortalWrt Builder` 时：

1. `编译设备型号` 选择单个设备，例如 `256M`、`128M` 或 `128M-Ubootmod`，不能选择 `all`。
2. 勾选 `SSH` 选项。
3. 启动工作流后，等待进入 `SSH connection to Menuconfig` 步骤。
4. 在该步骤日志中找到 Upterm 提供的 SSH 连接命令并连接。

工作流通过 Upterm 公共中继提供 SSH 会话，并限制为使用触发该工作流的 GitHub 账号中已配置的 SSH 公钥连接。

连接后执行：

```sh
cd /workdir/openwrt
make menuconfig
```

完成配置修改后，保存并退出 `menuconfig`。此时可以根据是否需要立即编译选择以下两种结束方式。

### 仅保存配置，不进行编译

直接退出 SSH：

```sh
exit
```

工作流随后会：

```text
保存当前 .config
→ 更新仓库中对应的 config/*.config
→ Push 到 main 分支
→ 跳过 Build Firmware
→ 正常结束工作流
```

因此，如果本次只是调整和保存 `menuconfig`，不需要再手动取消 Workflow。

### 保存配置并立即继续编译

执行：

```sh
touch "$GITHUB_WORKSPACE/continue"
```

请使用上面的完整命令，不建议只执行：

```sh
touch continue
```

因为后者会在当前所在目录创建文件，不一定是工作流监听的 `continue` 信号位置。

检测到 `continue` 后，SSH 调试阶段会结束，工作流随后会：

```text
保存当前 .config
→ 更新仓库中对应的 config/*.config
→ Push 到 main 分支
→ 将本次修改后的配置传递给 Build Firmware
→ 在同一次 Workflow 中继续编译
```

因此现在不再需要为了使用最新 `.config` 而先运行一次 Workflow 保存配置，再启动第二次 Workflow 编译。

### 关于取消 Workflow

如果需要中止整个运行，可以直接在 GitHub Actions 页面使用 `Cancel workflow`。

当前工作流已经对取消状态进行判断；Workflow 被取消后，尚未启动的 `Build Firmware` 不会因为 Menuconfig 阶段结束而继续启动。

### SSH 会话时间

`SSH connection to Menuconfig` 当前最长运行时间为 **360 分钟（6 小时）**。

建议在完成配置后主动使用：

```sh
exit
```

或：

```sh
touch "$GITHUB_WORKSPACE/continue"
```

结束 SSH 阶段，而不是依赖超时。

如果日志中没有显示 SSH 连接命令，可以在 GitHub 的 `Re-run jobs` 中勾选 `Enable debug logging`，然后检查 Upterm 启动日志以及到 `uptermd.upterm.dev` 的连接情况。

---

## 编译注意事项

GitHub Actions 存储有限，大型软件包（如 sing-box 或 alist）建议使用预编译方式，而不是源码编译，即在编译过程中加入已经编译好现成软件包。否则你应该会碰到超长编译时间 + 超出 Action 储存。示例：

```sh
# 创建存储二进制文件的目录
BIN_DIR="$GITHUB_WORKSPACE/openwrt/files/usr/bin"
mkdir -p "$BIN_DIR"

# -------- 下载并解压 xray-core ARM64 -------
echo "Downloading xray-core..."
curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-arm64-v8a.zip
unzip -o xray.zip -d "$BIN_DIR"
chmod +x "$BIN_DIR/xray"
rm xray.zip

# -------- 下载并解压 sing-box ARM64 -------
echo "Downloading sing-box..."
curl -L -o sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.12.12/sing-box-1.12.12-linux-arm64.tar.gz
TMP_DIR=$(mktemp -d)
tar -xzf sing-box.tar.gz -C "$TMP_DIR"
mv "$TMP_DIR"/sing-box-1.12.12-linux-arm64/sing-box "$BIN_DIR"/sing-box
chmod +x "$BIN_DIR/sing-box"
rm -rf "$TMP_DIR"
rm sing-box.tar.gz
```

---

## Credits

- [bl-mt798x-dhcpd](https://github.com/weekdaycare/bl-mt798x-dhcpd)
- [bl-mt798x](https://github.com/hanwckf/bl-mt798x)
- [immortalwrtwrt](https://github.com/padavanonly/immortalwrt-mt798x-6.6)
- [P3TERX](https://github.com/P3TERX)
- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [Mattraks/delete-workflow-runs](https://github.com/Mattraks/delete-workflow-runs)
- [dev-drprasad/delete-older-releases](https://github.com/dev-drprasad/delete-older-releases)
- [peter-evans/repository-dispatch](https://github.com/peter-evans/repository-dispatch)

---

## License

[MIT](https://github.com/P3TERX/Actions-OpenWrt/blob/main/LICENSE) © [**P3TERX**](https://p3terx.com)
