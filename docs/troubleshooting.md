# 常见问题

## LuCI 页面没有出现

- 确认脚本以 root 权限运行且没有报错退出。
- 重新登录 LuCI 或清除浏览器缓存。
- 检查菜单文件 `/usr/share/luci/menu.d/luci-app-campus-auth.json` 和 ACL 文件 `/usr/share/rpcd/acl.d/luci-app-campus-auth.json` 是否存在。

## 手动认证失败

- 先点“检测网络”，确认检测 URL 是否能访问。
- 确认账号、密码、服务名和登录 URL 正确。
- 查看页面运行日志及 `/tmp/campus-auth-adapter.log`。分享日志前先检查并删除个人信息。
- Portal 页面结构或接口字段变化时，需要根据当前校园网抓包更新登录适配逻辑。

## 注销没有下线

- 更新当前会话的 `userIndex`，不要沿用过期值。
- 核对注销 URL、Portal Origin 及网络可达性。
- HTTP 状态码只能说明 HTTP 请求得到响应，不能单独证明账号已注销；再次检测网络并在校园网 Portal 上确认。

## 点击断开 WAN 后网页断开

这是预期现象。通过 LAN 侧地址重新访问路由器，或使用本地 SSH 执行 `ifup wan` 恢复 WAN。不要在没有备用管理路径的远程会话中随意断开 WAN。

## 自动认证没有运行

- 自动认证默认关闭。先在页面保存配置，再点“启用 / 应用配置并重启”。
- 查看页面状态和日志。
- 确认系统存在 Bash、curl、LuCI、procd，并确保检测 URL 对当前网络环境适用。
