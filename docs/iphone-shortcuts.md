# iPhone 快捷指令 URL 控制

1. 在 LuCI「服务 → 校园网认证」确认 `iPhone 快捷指令 URL API 令牌` 已设置。
2. iPhone 打开「快捷指令」并新建快捷指令。
3. 添加「URL」动作，填入例如：
   `http://192.168.10.1/cgi-bin/campus-auth-api?action=connect&token=你的令牌`
4. 添加「获取 URL 内容」动作，方法选 GET。
5. 可在末尾添加「显示结果」动作。

将示例中的路由器 IP 和令牌替换为自己的值。以下操作可分别制作独立快捷指令：

- 检测：`action=check`
- 认证：`action=connect`
- 注销：`action=logout`
- 断开 WAN：`action=wan-down`
- 恢复 WAN：`action=wan-up`
- 状态：`action=status`

## 安全提醒

- 令牌相当于控制密码；不要截图分享、不要放入公开仓库。
- 仅从可信 LAN 访问，禁止 WAN 端口转发到该接口。
- 如果令牌泄露，请 SSH 执行 `uci set campus-auth.main.api_token='新的随机长令牌' && uci commit campus-auth`。
- `wan-down` 会立即断开 WAN；确保有 `wan-up` 快捷指令或本地管理恢复手段。
