# 指定内置软件的 IPK 导出

`common.list` 是所有设备共用的导出候选清单。构建时与当前设备的
`256m.list`、`128m.list` 或 `128muboot.list` 合并、去重。

每行填写一个实际软件包名，例如 `mwan3`，不填写源码目录名、
`CONFIG_PACKAGE_` 前缀或 `=y`。支持空行、整行 `#` 注释及 Windows 换行。
设备清单可以为空或不存在；设备清单只增加候选，不覆盖 common。

导出依据是 `make defconfig` 后的实际 `.config`，清单不会修改固件选包：

- `y`：导出本次构建对应的 IPK。
- `m`：记录跳过，仍由原有 `module-packages-*` 流程处理。
- 未启用：记录跳过。
- 包名无效、不是可打包软件，或 `y` 包缺失、版本/架构不匹配、候选内容冲突：
  导出失败，阻止本次发布。

每个设备输出 `selected-packages-<设备>.tar.gz`，包含 IPK、
`export-report.tsv`、`sha256sums`、实际 `build.config` 和使用的清单。
即使没有可导出的包，也生成含报告的归档。校验和覆盖归档中的 IPK。
另有 `package-export-summary-<设备>.md`，同时上传到 Actions 制品与
Release，并追加到 Release 说明。

匹配使用当前源码生成的 `tmp/.packageinfo` 中的版本、ABI 和仓库信息，
以及当前配置的架构、目标和子目标。同名文件若出现在多个输出位置，
只在内容完全相同时去重；不同内容直接失败。

第一版仅导出清单列出的包，不递归导出依赖，不收集运行时下载的资源。
这些 IPK 用于与本次固件配套保存，不保证可安装到其他固件。
原有固件输出、`m` 包收集、Release 配置快照与配置差异逻辑保持不变。

本地验证：`python -m unittest discover -s tests -p test_package_export.py`。
