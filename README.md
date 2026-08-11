# MiaoSpeed 部署与管理脚本

面向 Telegram 节点测速 Bot 的 [MiaoSpeed](https://github.com/airportr/miaospeed) 后端安装与管理脚本，支持在 Linux AMD64 / ARM64（含 OpenWrt）上完成安装、配置、更新、备份和卸载。

> [!NOTE]
> 本仓库维护的是部署与管理脚本，不包含 MiaoSpeed 核心。安装和更新时，脚本会从上游 `airportr/miaospeed` 的 GitHub Releases 下载核心程序。

## 快速开始

请使用 `root` 用户执行。

### Debian / Ubuntu 等 Linux

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/miaospeed.sh)
```

### OpenWrt

先安装基础依赖，再运行管理脚本：

```bash
opkg update && opkg install bash curl
bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/miaospeed.sh)
```

安装完成后，输入以下命令打开管理控制台：

```bash
miao
```

## 从旧版迁移

如果以前使用过 `InstallMiaoSpeed.sh`，请先通过旧脚本卸载，再安装当前的 `miaospeed.sh`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InstallMiaoSpeed.sh) --uninstall
bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/miaospeed.sh)
```

> [!WARNING]
> 旧版卸载会停止服务并删除 `/opt/miaospeed`，其中包括现有配置和运行数据。迁移前请自行备份需要保留的内容。

## 主要功能

- 自动生成监听端口、WebSocket 路径和连接 Token
- 支持 Linux AMD64 / ARM64，以及 Debian、Ubuntu、OpenWrt 等环境
- 自动识别 `systemd` 与 OpenWrt `procd`
- 通过 `miao` 查看状态、实时日志并修改连接与运行参数
- 管理 BotID 白名单及本地备注
- 更新 MiaoSpeed 核心和管理脚本
- 安装指定核心版本并支持版本锁定
- 可选的核心自动更新、脚本自动更新和定时重启
- 配置备份、恢复、清理，以及更新失败自动回滚
- 安装中断清理和完整卸载
- 可选下载并启用 GeoIP 数据库

## 管理命令

| 命令 | 作用 |
| --- | --- |
| `miao` | 打开管理控制台 |
| `bash /root/miaospeed.sh menu` | 打开管理控制台 |
| `bash /root/miaospeed.sh --self-update` | 更新本地管理脚本 |
| `bash /root/miaospeed.sh --uninstall` | 卸载服务并删除相关文件 |
| `bash /root/miaospeed.sh --help` | 查看命令帮助 |

管理控制台提供以下入口：

1. 查看状态配置
2. 查看实时日志
3. 修改连接参数
4. 修改访问控制
5. 修改运行参数
6. 检查 MiaoSpeed 更新
7. 更新管理脚本
8. 自动维护设置
9. 备份与清理
10. 卸载

## 安装内容

脚本会根据系统环境安装必要依赖，并创建或管理以下内容：

| 路径 | 用途 |
| --- | --- |
| `/opt/miaospeed/miaospeed` | MiaoSpeed 核心程序 |
| `/opt/miaospeed/miaospeed.conf` | 运行配置 |
| `/opt/miaospeed/log/` | 运行与更新日志 |
| `/opt/miaospeed/backup/` | 配置及核心备份 |
| `/root/miaospeed.sh` | 本地管理脚本 |
| `/usr/bin/miao` | 管理控制台快捷入口 |

根据安装时的选择，脚本还可能创建系统服务、`cron` 定时任务、日志轮转配置，并下载 GeoIP 数据库。

## 安全提示

- 脚本需要 `root` 权限，会安装依赖、创建系统服务并可能修改 `crontab`；运行前建议先审阅[当前脚本源码](InstallMiaoSpeed/miaospeed.sh)。
- BotID 白名单留空时表示允许所有 BotID 连接。公开部署时请配置访问控制，并同时使用复杂的 WebSocket 路径和 Token。
- Token 会在本机管理界面中显示。请妥善保护终端记录、`/opt/miaospeed/miaospeed.conf` 及其备份。
- 管理脚本自更新默认跟随本仓库 `main` 分支；核心程序则从上游 Releases 获取。

## 部署方式

当前推荐使用本仓库的二进制部署与管理脚本。若宿主机运行代理软件，二进制部署也更便于按 `PROCESS-NAME, miaospeed, DIRECT` 设置直连规则。

需要 Docker Compose 部署时，可参考 Telegram 频道的 [Docker 配置说明](https://t.me/i_chl/88)。

## 仓库文件

- [`InstallMiaoSpeed/miaospeed.sh`](InstallMiaoSpeed/miaospeed.sh)：当前推荐的安装与管理脚本
- [`InstallMiaoSpeed/InstallMiaoSpeed.sh`](InstallMiaoSpeed/InstallMiaoSpeed.sh)：旧版一键安装器，仅保留用于旧版迁移和卸载
- [`LICENSE`](LICENSE)：本仓库许可证

## 相关链接

- [当前推荐脚本说明](https://t.me/i_chl/353)
- [旧版二进制部署说明](https://t.me/i_chl/244)
- [Docker Compose 部署说明](https://t.me/i_chl/88)
- [MiaoSpeed 上游仓库](https://github.com/airportr/miaospeed)
- [Telegram 频道](https://t.me/i_chl)

## License

本仓库代码采用 [MIT License](LICENSE)。安装过程中下载的 MiaoSpeed 核心不包含在本仓库中，其授权以[上游项目](https://github.com/airportr/miaospeed)为准。
