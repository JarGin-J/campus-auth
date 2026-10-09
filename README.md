# ImmortalWrt 校园网认证 LuCI 插件

为 ImmortalWrt / OpenWrt 提供一个 LuCI 校园网认证控制台，支持手动认证、自动重连、校园网账号注销、WAN 接口断开/恢复、Bark 通知和日志查看。

> 当前仓库提供首次安装脚本。脚本尚未在所有设备/固件组合上完成实机测试；建议先备份路由器配置，并在本地网络可恢复的情况下安装。

## 功能

- LuCI 页面配置账号、密码、连通性检测 URL、检测间隔、请求超时、登录接口、注销接口、Portal Origin、运营商服务名及 Bark 参数。
- 手动检测网络、立即认证/重新认证。
- 定时检测网络；检测失败时尝试校园网认证（默认关闭，需手动启用）。
- 根据用户配置的 `userIndex` 发送校园网注销 POST 请求。
- 在页面中断开 WAN（`ifdown wan`）及恢复 WAN（`ifup wan`）。
- 查看运行日志。日志设计上避免记录账号密码、Cookie 和 HTTP 响应正文。
- 提供令牌保护的 URL API，可通过 iPhone「快捷指令」执行检测、认证、注销及 WAN 断开/恢复。
- 不启动、停止、重启或修改 NPS。

## iPhone 快捷指令 URL 控制

首次安装会随机生成 `api_token`，LuCI 页面中以密码字段显示。API 要求令牌匹配，并限制为私有/LAN 来源。请不要在路由器上配置 WAN 端口转发到 LuCI/uhttpd，也不要把令牌分享给他人。

假设路由器 LAN 地址为 `192.168.10.1`。在 iPhone「快捷指令」中新建快捷指令，添加「URL」动作，再添加「获取 URL 内容」动作（GET）。把 `<令牌>` 替换为实际令牌：

| 功能 | URL 参数 |
|---|---|
| 查看状态 | `action=status` |
| 检测网络 | `action=check` |
| 立即认证 | `action=connect` |
| 校园网注销 | `action=logout` |
| 断开 WAN | `action=wan-down` |
| 恢复 WAN | `action=wan-up` |

完整示例：`http://192.168.10.1/cgi-bin/campus-auth-api?action=connect&token=<令牌>`。建议再添加「显示结果」动作查看返回文字。

URL 中的令牌可能出现在快捷指令内容、浏览器历史或服务日志中，仅在可信 LAN 使用；不要通过公网暴露此接口。WAN 断开会中断互联网，建议另做「恢复 WAN」快捷指令。注销请求是否真正下线，仍需通过检测确认。

## 适用环境

- 面向 ImmortalWrt / OpenWrt，具有 LuCI、`uci`、`procd`、`curl` 和 Bash 的环境。
- 此项目当前按以下校园网 Portal 流程提供默认值，其他校园网需要自行调整接口参数：
  - 登录：`http://10.130.128.9/eportal/InterFace.do?method=login`
  - 注销：`http://10.130.128.9/eportal/InterFace.do?method=logout`
  - Portal Origin：`http://10.130.128.9`
  - 服务名：`中国电信`
- 默认检测地址：`http://www.msftconnecttest.com/connecttest.txt`

## 首次安装

1. 从 GitHub 下载本仓库，或下载仓库中的 `install-campus-auth.sh`。
2. 将脚本上传到路由器，例如 `/tmp/install-campus-auth.sh`。
3. SSH 登录路由器，以 root 执行：

   ```sh
   chmod +x /tmp/install-campus-auth.sh
   sh /tmp/install-campus-auth.sh
   ```

4. 刷新 LuCI，打开 **服务 → 校园网认证**。
5. 填写账号、密码及校园网参数，保存后先点“检测网络”和“连接 / 重新认证”进行手动测试。
6. 确认手动认证正常后，再启用自动认证。

安装脚本会在检测到 `/etc/config/campus-auth`、`/etc/init.d/campus-auth` 或现有控制脚本时拒绝继续，以免覆盖已有安装。此时请使用单独的升级流程，不要把首次安装脚本当升级脚本使用。

## 页面功能说明

### 校园网账号注销下线

- 默认使用 POST `/eportal/InterFace.do?method=logout`。
- 在页面填写当前会话的 `userIndex`。此值可能随认证会话或 IP 变化，应从当前 Portal 成功页面或注销请求中获取最新值。
- 点击注销按钮后，再使用“检测网络”确认是否确实下线。HTTP 2xx/3xx 只表示请求已响应，不保证认证系统一定完成注销。

### WAN 断开 / 恢复

- “断开 WAN 网络”调用 `ifdown wan`。
- “恢复 WAN 网络”调用 `ifup wan`。
- 断开 WAN 会导致互联网中断，远程管理连接也可能掉线。建议只在本地 LAN 管理连接下操作，并提前确认可恢复的方式。

### Bark 通知

- `Bark Key` 可留空关闭通知。
- 不要将真实 Bark Key、校园网密码、Cookie 或 `userIndex` 提交到公开 issue、截图或日志。
- 若凭据曾经公开，建议轮换相应密钥并重新登录校园网。

## 卸载

当前版本没有提供自动卸载脚本。若需卸载，请先在 LuCI 中停止自动认证，再自行备份配置后删除本插件创建的文件。不要删除或修改任何 NPS 配置/服务文件。

## 安全与限制

- 登录和注销接口默认使用 HTTP，这是该 Portal 地址的协议要求；流量在本地网络中不具备 HTTPS 的传输加密保护。
- `userIndex` 属于会话相关数据，应按敏感信息处理。
- 此版本按给定 Portal 请求结构提交认证/注销，不保证适用于所有学校或运营商。
- WAN 接口名默认是 `wan`；如路由器实际接口名称不同，需要修改脚本中的接口名或增加页面配置后再使用。
- 请先在测试环境验证。作者/分发者不对网络中断、认证失败或校园网策略变化承担保证责任。

## 目录结构

```text
.
├── install-campus-auth.sh  # 首次安装脚本
├── README.md               # 项目说明与安装文档
├── LICENSE                 # MIT License
├── .gitignore
└── docs/
    └── troubleshooting.md  # 常见问题
```

## 贡献

欢迎提交问题与改进建议。提交前请移除账号、密码、Bark Key、Cookie、`userIndex`、校园网个人信息和可识别的公网/内网会话数据。
