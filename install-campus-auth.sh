#!/bin/sh
# ImmortalWrt campus-auth LuCI first-time installer
# Run as root on the router. Refuses to overwrite an existing plugin. Does not manage/change NPS.
set -eu

# First-time installer: do not overwrite an existing installation.
if [ -e /etc/config/campus-auth ] || [ -e /etc/init.d/campus-auth ] || [ -e /usr/lib/campus-auth/control.sh ]; then
  echo "检测到已有校园网认证插件文件。为避免覆盖现有配置，请使用升级脚本，而不是首次安装脚本。" >&2
  exit 1
fi
echo "开始首次安装校园网认证插件；自动认证默认关闭。"

mkdir -p /usr/lib/campus-auth /www/luci-static/resources/view \
  /usr/share/luci/menu.d /usr/share/rpcd/acl.d

# Common logging. Never log credentials, cookies, auth URLs, or server response bodies.
cat > /usr/lib/campus-auth/common.sh <<'EOF'
#!/bin/sh
TAG=campus-auth
LOG=/tmp/campus-auth.log
log_msg() {
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    logger -t "$TAG" "$*"
    printf '%s\n' "$line" >> "$LOG"
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 65536 ]; then
        tail -n 300 "$LOG" > "${LOG}.new" && mv "${LOG}.new" "$LOG"
    fi
}
EOF
chmod 644 /usr/lib/campus-auth/common.sh

# One-shot adapter based on the existing known Portal flow.
# Credentials remain in /home/lognet.conf; this adapter never runs an infinite loop.
cat > /usr/lib/campus-auth/login.sh <<'EOF'
#!/bin/bash
set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
. /usr/lib/campus-auth/common.sh

CHECK_URL="$(uci -q get campus-auth.main.check_url)"
[ -n "$CHECK_URL" ] || CHECK_URL='http://www.msftconnecttest.com/connecttest.txt'
LOGIN_URL="$(uci -q get campus-auth.main.login_url)"
[ -n "$LOGIN_URL" ] || LOGIN_URL='http://10.130.128.9/eportal/InterFace.do?method=login'
PORTAL_ORIGIN="$(uci -q get campus-auth.main.portal_origin)"
[ -n "$PORTAL_ORIGIN" ] || PORTAL_ORIGIN='http://10.130.128.9'
SERVICE_NAME="$(uci -q get campus-auth.main.service_name)"
[ -n "$SERVICE_NAME" ] || SERVICE_NAME='中国电信'
USER_ID="$(uci -q get campus-auth.main.username)"
PASSWORD="$(uci -q get campus-auth.main.password)"
BARK_KEY="$(uci -q get campus-auth.main.bark_key)"
BARK_ON_SUCCESS="$(uci -q get campus-auth.main.bark_on_success)"
BARK_ON_FAILURE="$(uci -q get campus-auth.main.bark_on_failure)"
BARK_TITLE="$(uci -q get campus-auth.main.bark_title)"
[ -n "$BARK_TITLE" ] || BARK_TITLE='校园网通知'
PORTAL_URL_FILE=/tmp/campus-auth-portal-url
COOKIE_JAR=/tmp/campus-auth-cookie
LOCK_DIR=/tmp/campus-auth-login.lock

# Backward compatibility: use the old local config only when UI credentials are empty.
if [ -z "$USER_ID" ] || [ -z "$PASSWORD" ]; then
    if [ -r /home/lognet.conf ]; then
        LEGACY_USER_ID=''
        LEGACY_PASSWORD=''
        LEGACY_BARK_KEY=''
        # Read legacy settings in an isolated shell so they cannot overwrite UCI values.
        eval "$(/bin/bash -c '. /home/lognet.conf; printf "LEGACY_USER_ID=%q\\nLEGACY_PASSWORD=%q\\nLEGACY_BARK_KEY=%q\\n" "${USER_ID:-}" "${PASSWORD:-}" "${BARK_KEY:-}"' 2>/dev/null)" || true
        [ -n "$USER_ID" ] || USER_ID="${LEGACY_USER_ID:-}"
        [ -n "$PASSWORD" ] || PASSWORD="${LEGACY_PASSWORD:-}"
        [ -n "$BARK_KEY" ] || BARK_KEY="${LEGACY_BARK_KEY:-}"
    fi
fi
if [ -z "${USER_ID:-}" ] || [ -z "${PASSWORD:-}" ]; then
    log_msg '请先在校园网认证页面配置账号和密码'
    exit 1
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log_msg '已有认证任务正在执行，本次跳过'
    exit 1
fi
cleanup() {
    rm -rf "$LOCK_DIR"
    rm -f "$PORTAL_URL_FILE" "$COOKIE_JAR"
}
trap cleanup EXIT HUP INT TERM

send_bark() {
    [ -n "${BARK_KEY:-}" ] || return 0
    title="${BARK_TITLE:-校园网通知}"
    body_text="$1"
    curl -sS --connect-timeout 8 --max-time 15 -X POST \
        "https://api.day.app/${BARK_KEY}" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=utf-8' \
        --data-urlencode "title=${title}" \
        --data-urlencode "body=${body_text}" >/dev/null 2>&1 || true
}
notify_success() {
    [ "${BARK_ON_SUCCESS:-0}" = 1 ] && send_bark 'ImmortalWrt 已连接校园网'
}
notify_failure() {
    [ "${BARK_ON_FAILURE:-1}" = 1 ] && send_bark 'ImmortalWrt 校园网认证失败'
}

body="$(curl -sS --connect-timeout 5 --max-time 8 "$CHECK_URL" 2>/dev/null || true)"
if [ "$body" = 'Microsoft Connect Test' ]; then
    log_msg '网络已正常，无需重新认证'
    exit 0
fi

log_msg '开始获取校园网 Portal 参数'
body="$(curl -sS --connect-timeout 8 --max-time 12 "$CHECK_URL" 2>/dev/null || true)"
portal_url="$(printf '%s' "$body" |
    sed -n "s/.*location\.href=['\"]\([^'\"]*\/eportal\/index\.jsp[^'\"]*\)['\"].*/\1/p" |
    head -n 1)"
if [ -z "$portal_url" ]; then
    log_msg '未能获取 Portal URL，请检查校园网重定向'
    notify_failure
    exit 1
fi

query_string="${portal_url#*\?}"
if [ "$query_string" = "$portal_url" ]; then
    log_msg 'Portal URL 缺少查询参数'
    notify_failure
    exit 1
fi

if ! curl -sS --connect-timeout 8 --max-time 12 \
    -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$portal_url" \
    -o /dev/null 2>/dev/null; then
    log_msg '访问 Portal 页面失败'
    notify_failure
    exit 1
fi

log_msg '已获取 Portal 参数，正在提交认证请求'
response="$(curl -sS --connect-timeout 8 --max-time 12 \
    "$LOGIN_URL" \
    -H 'Accept: */*' \
    -H 'Accept-Language: zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7' \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
    -H "Origin: ${PORTAL_ORIGIN}" \
    -H "Referer: $portal_url" \
    -H 'User-Agent: Mozilla/5.0' \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    --data-urlencode "userId=${USER_ID}" \
    --data-urlencode "password=${PASSWORD}" \
    --data-urlencode "service=${SERVICE_NAME}" \
    --data-urlencode "queryString=${query_string}" \
    --data-urlencode 'operatorPwd=' \
    --data-urlencode 'operatorUserId=' \
    --data-urlencode 'validcode=' \
    --data-urlencode 'passwordEncrypt=true' \
    2>/dev/null)" || {
        log_msg '认证 HTTP 请求失败'
        exit 1
    }

# Do not write the response body to logs; it may contain sensitive data.
if printf '%s' "$response" | grep -q '"result"[[:space:]]*:[[:space:]]*"success"'; then
    log_msg '校园网认证接口返回成功'
    notify_success
    exit 0
fi
log_msg '校园网认证接口未报告成功'
notify_failure
exit 1
EOF
chmod 700 /usr/lib/campus-auth/login.sh

# Unified control entrypoint. No NPS actions or service references.
cat > /usr/lib/campus-auth/control.sh <<'EOF'
#!/bin/sh
. /usr/lib/campus-auth/common.sh
action="${1:-status}"

network_check() {
    url="$(uci -q get campus-auth.main.check_url)"
    timeout="$(uci -q get campus-auth.main.timeout)"
    [ -n "$url" ] || url='http://www.msftconnecttest.com/connecttest.txt'
    case "$timeout" in ''|*[!0-9]*) timeout=8 ;; esac
    tmp="/tmp/campus-auth-check.$$"
    if command -v curl >/dev/null 2>&1; then
        code="$(curl -L -sS --max-time "$timeout" -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code=''
        if [ "$code" = 200 ] && grep -q 'Microsoft Connect Test' "$tmp" 2>/dev/null; then
            rm -f "$tmp"; return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -T "$timeout" -O "$tmp" "$url" >/dev/null 2>&1 &&
            grep -q 'Microsoft Connect Test' "$tmp" 2>/dev/null; then
            rm -f "$tmp"; return 0
        fi
    else
        rm -f "$tmp"; log_msg '系统找不到 curl 或 wget'; return 2
    fi
    rm -f "$tmp"
    return 1
}

case "$action" in
    check)
        if network_check; then
            echo 'internet=online'
            exit 0
        fi
        echo 'internet=offline_or_portal'
        exit 1
        ;;
    connect)
        if network_check; then
            log_msg '网络已正常，无需重新认证'
            echo '网络已连接'
            exit 0
        fi
        log_msg '正在执行校园网认证'
        /usr/lib/campus-auth/login.sh >> /tmp/campus-auth-adapter.log 2>&1 || {
            rc=$?
            log_msg "校园网认证失败，退出码 $rc"
            echo '校园网认证失败，请查看日志'
            exit "$rc"
        }
        sleep 2
        if network_check; then
            log_msg '认证后互联网检测成功'
            echo '校园网认证成功，网络正常'
            exit 0
        fi
        log_msg '认证接口报告成功，但互联网检测仍未通过'
        echo '认证接口报告成功，但网络检测未通过'
        exit 1
        ;;
    logout)
        logout_url="$(uci -q get campus-auth.main.logout_url)"
        logout_user_index="$(uci -q get campus-auth.main.logout_user_index)"
        portal_origin="$(uci -q get campus-auth.main.portal_origin)"
        [ -n "$logout_url" ] || logout_url='http://10.130.128.9/eportal/InterFace.do?method=logout'
        [ -n "$portal_origin" ] || portal_origin='http://10.130.128.9'
        if [ -z "$logout_user_index" ]; then
            echo '请先在页面填写当前会话的 userIndex。该值可能随每次认证或 IP 变化，请从 Portal 成功页面/注销请求中获取最新值。' >&2
            exit 2
        fi
        log_msg '正在向校园网提交注销请求'
        code="$(curl -sS --connect-timeout 8 --max-time 15 -o /tmp/campus-auth-logout-response -w '%{http_code}' \
            -X POST "$logout_url" \
            -H 'Accept: */*' \
            -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
            -H "Origin: ${portal_origin}" \
            -H "Referer: ${portal_origin}/eportal/success.jsp?userIndex=${logout_user_index}&keepaliveInterval=0" \
            -H 'User-Agent: Mozilla/5.0' \
            --data-urlencode "userIndex=${logout_user_index}" 2>/dev/null)" || code=''
        # Do not log or display the response body; it may contain session data.
        rm -f /tmp/campus-auth-logout-response
        case "$code" in
            2??|3??)
                log_msg "注销请求已发送，HTTP 状态码：$code；尚需确认账号是否真正下线"
                echo "已提交校园网注销请求（HTTP $code）。请点击“检测网络”确认是否已下线。"
                ;;
            *)
                log_msg '校园网注销请求失败或接口无响应'
                echo '注销请求失败。请确认 Portal 地址、当前 userIndex 和网络状态。' >&2
                exit 1
                ;;
        esac
        ;;
    wan-down)
        log_msg '通过 ifdown 断开 WAN 接口'
        ifdown wan && { echo '已请求断开 WAN 接口。当前管理连接可能中断。'; exit 0; }
        echo '断开 WAN 失败，请检查 WAN 接口名称和网络配置。' >&2
        exit 1
        ;;
    wan-up)
        log_msg '通过 ifup 恢复 WAN 接口'
        ifup wan && { echo '已请求恢复 WAN 接口。'; exit 0; }
        echo '恢复 WAN 失败，请检查 WAN 接口名称和网络配置。' >&2
        exit 1
        ;;
    status)
        if network_check; then
            echo 'internet=online'
        else
            echo 'internet=offline_or_portal'
        fi
        if ps | grep -q '[w]orker.sh'; then
            echo 'auto_auth=running'
        else
            echo 'auto_auth=stopped_or_disabled'
        fi
        ;;
    *)
        echo 'Usage: control.sh {check|connect|logout|wan-down|wan-up|status}' >&2
        exit 2
        ;;
esac
EOF
chmod 755 /usr/lib/campus-auth/control.sh

# Background worker: only network checks and campus authentication.
cat > /usr/lib/campus-auth/worker.sh <<'EOF'
#!/bin/sh
. /usr/lib/campus-auth/common.sh
STATE=/tmp/campus-auth-netstate

while :; do
    if /usr/lib/campus-auth/control.sh check >/dev/null 2>&1; then
        echo online > "$STATE"
    else
        echo offline > "$STATE"
        log_msg '检测到网络不可用，尝试校园网认证'
        /usr/lib/campus-auth/control.sh connect >/dev/null 2>&1 || true
    fi
    interval="$(uci -q get campus-auth.main.interval)"
    case "$interval" in ''|*[!0-9]*) interval=600 ;; esac
    [ "$interval" -lt 60 ] && interval=60
    [ "$interval" -gt 86400 ] && interval=86400
    sleep "$interval"
done
EOF
chmod 755 /usr/lib/campus-auth/worker.sh

# procd service only manages the campus-auth worker.
cat > /etc/init.d/campus-auth <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

start_service() {
    [ "$(uci -q get campus-auth.main.enabled)" = "1" ] || return 0
    procd_open_instance
    procd_set_param command /usr/lib/campus-auth/worker.sh
    procd_set_param respawn 3600 5 5
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger campus-auth
}
EOF
chmod 755 /etc/init.d/campus-auth

# Initialize first-install settings. NPS is not managed or changed.
uci -q set campus-auth.main='campus-auth'
uci -q set campus-auth.main.check_url='http://www.msftconnecttest.com/connecttest.txt'
uci -q set campus-auth.main.interval='600'
uci -q set campus-auth.main.timeout='8'
uci -q set campus-auth.main.enabled='0'
uci -q set campus-auth.main.login_url='http://10.130.128.9/eportal/InterFace.do?method=login'
uci -q set campus-auth.main.logout_url='http://10.130.128.9/eportal/InterFace.do?method=logout'
uci -q set campus-auth.main.logout_user_index=''
uci -q set campus-auth.main.portal_origin='http://10.130.128.9'
uci -q set campus-auth.main.service_name='中国电信'
uci -q set campus-auth.main.username=''
uci -q set campus-auth.main.password=''
uci -q set campus-auth.main.bark_key=''
uci -q set campus-auth.main.bark_title='校园网通知'
uci -q set campus-auth.main.bark_on_success='1'
uci -q set campus-auth.main.bark_on_failure='1'
# Random bearer token for iPhone Shortcuts / URL API.
API_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
[ -n "$API_TOKEN" ] || { echo '无法生成 URL API 令牌' >&2; exit 1; }
uci -q set campus-auth.main.api_token="$API_TOKEN"
uci -q delete campus-auth.main.npc_bin 2>/dev/null || true
uci -q delete campus-auth.main.npc_config 2>/dev/null || true
uci -q delete campus-auth.main.npc_mode 2>/dev/null || true
uci -q delete campus-auth.main.npc_service 2>/dev/null || true
uci commit campus-auth

# Token-protected CGI endpoint for iPhone Shortcuts. Do not expose on WAN.
mkdir -p /www/cgi-bin
cat > /www/cgi-bin/campus-auth-api <<'EOF'
#!/bin/sh
printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\n'
query="${QUERY_STRING:-}"
action=''
token=''
oldifs=$IFS
IFS='&'
for pair in $query; do
    key=${pair%%=*}
    val=${pair#*=}
    case "$key" in action) action=$val ;; token) token=$val ;; esac
done
IFS=$oldifs
expected="$(uci -q get campus-auth.main.api_token)"
if [ -z "$expected" ] || [ "$token" != "$expected" ]; then
    echo 'ERROR: unauthorized'; exit 0
fi
case "$action" in status|check|connect|logout|wan-down|wan-up) ;; *) echo 'ERROR: invalid action'; exit 0 ;; esac
remote="${REMOTE_ADDR:-}"
case "$remote" in
    192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.*|::1|fc*|fd*) ;;
    *) echo 'ERROR: LAN access only'; exit 0 ;;
esac
/usr/lib/campus-auth/control.sh "$action" 2>&1 | sed -E 's/(token|password|cookie|userIndex)=?[^ &]*/\1=[redacted]/Ig'
EOF
chmod 700 /www/cgi-bin/campus-auth-api

# LuCI page: status, manual actions, auto-auth settings and logs.
cat > /www/luci-static/resources/view/campus-auth.js <<'EOF'
'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

function run(action) {
    return fs.exec('/usr/lib/campus-auth/control.sh', [action]).then(function (r) {
        var msg = (r.stdout || '').trim() || ('命令结束，退出码 ' + r.code);
        ui.addNotification(null, E('p', msg));
        refreshStatus();
        refreshLogs();
    }).catch(function (e) {
        ui.addNotification(null, E('p', _('执行失败：') + e));
    });
}

function refreshStatus() {
    var el = document.getElementById('campus-auth-status');
    if (!el) return;
    fs.exec('/usr/lib/campus-auth/control.sh', ['status']).then(function (r) {
        el.textContent = (r.stdout || r.stderr || '状态暂不可用').trim();
    }).catch(function () {
        el.textContent = '状态暂不可用';
    });
}

function refreshLogs() {
    var el = document.getElementById('campus-auth-log');
    if (!el) return;
    Promise.all([
        fs.read('/tmp/campus-auth.log').catch(function () { return ''; }),
        fs.read('/tmp/campus-auth-adapter.log').catch(function () { return ''; })
    ]).then(function (parts) {
        el.textContent = '=== 插件日志 ===\n' + (parts[0] || '暂无日志') +
            '\n\n=== 认证日志 ===\n' + (parts[1] || '暂无日志');
        el.scrollTop = el.scrollHeight;
    });
}

return view.extend({
    load: function () {
        return uci.load('campus-auth');
    },
    render: function () {
        var m = new form.Map('campus-auth', _('校园网认证控制台'),
            _('集中管理校园网认证、自动重连、校园网注销、WAN 断开/恢复、检测参数和日志。校园网注销接口需由你确认并配置。'));
        var s = m.section(form.NamedSection, 'main', 'campus-auth');
        s.addremove = false;

        var o = s.option(form.Flag, 'enabled', _('启用自动认证'));
        o.rmempty = false;
        o.default = '0';
        o.description = _('启用后后台定时检查网络；检测失败时尝试认证。');

        o = s.option(form.Value, 'check_url', _('连通性检测 URL'));
        o.default = 'http://www.msftconnecttest.com/connecttest.txt';
        o.rmempty = false;

        o = s.option(form.Value, 'interval', _('检测间隔（秒）'));
        o.datatype = 'range(60,86400)';
        o.default = '600';
        o.rmempty = false;

        o = s.option(form.Value, 'timeout', _('请求超时（秒）'));
        o.datatype = 'range(2,60)';
        o.default = '8';
        o.rmempty = false;

        o = s.option(form.Value, 'username', _('校园网账号'));
        o.rmempty = false;
        o.description = _('保存在路由器本地配置中，不会显示在日志里。');

        o = s.option(form.Value, 'password', _('校园网密码'));
        o.password = true;
        o.rmempty = false;
        o.description = _('保存后不会在页面中明文回显；如需更换，请重新输入。');

        o = s.option(form.Value, 'service_name', _('运营商 / 认证服务名'));
        o.default = '中国电信';
        o.rmempty = false;

        o = s.option(form.Value, 'login_url', _('校园网登录接口 URL'));
        o.default = 'http://10.130.128.9/eportal/InterFace.do?method=login';
        o.rmempty = false;

        o = s.option(form.Value, 'logout_url', _('校园网注销接口 URL'));
        o.default = 'http://10.130.128.9/eportal/InterFace.do?method=logout';
        o.rmempty = false;
        o.description = _('根据你提供的抓包设置为 POST 注销接口。');

        o = s.option(form.Value, 'logout_user_index', _('当前会话 userIndex'));
        o.rmempty = true;
        o.description = _('从 Portal 成功页面 URL 或注销请求正文中复制 userIndex；它可能随会话/IP 变化，请使用最新值。该字段按敏感会话信息处理，不会写入日志。');

        o = s.option(form.Value, 'portal_origin', _('Portal Origin'));
        o.default = 'http://10.130.128.9';
        o.rmempty = false;

        o = s.option(form.Value, 'bark_key', _('Bark Key'));
        o.password = true;
        o.rmempty = true;
        o.description = _('可留空以关闭 Bark 通知。');

        o = s.option(form.Value, 'bark_title', _('Bark 通知标题'));
        o.default = '校园网通知';
        o.rmempty = false;

        o = s.option(form.Flag, 'bark_on_success', _('认证成功时发送 Bark'));
        o.rmempty = false;
        o.default = '1';

        o = s.option(form.Flag, 'bark_on_failure', _('认证失败时发送 Bark'));
        o.rmempty = false;
        o.default = '1';

        o = s.option(form.Value, 'api_token', _('iPhone 快捷指令 URL API 令牌'));
        o.password = false;
        o.rmempty = false;
        o.description = _('首次安装时随机生成。页面会显示令牌以便复制到快捷指令；仅在可信 LAN 使用，令牌相当于控制密码。可通过 SSH 使用 uci set campus-auth.main.api_token=新令牌 && uci commit campus-auth 更换。');

        return m.render().then(function (mapEl) {
            var page = E('div', {}, [
                mapEl,
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', _('网络状态')),
                    E('pre', { 'id': 'campus-auth-status',
                        'style': 'white-space:pre-wrap' }, _('正在检测…')),
                    E('button', { 'class': 'btn cbi-button',
                        'click': function () { refreshStatus(); return run('check'); } }, _('检测网络')),
                    ' ',
                    E('button', { 'class': 'btn cbi-button cbi-button-action',
                        'click': function () { return run('connect'); } }, _('连接 / 重新认证')),
                    ' ',
                    E('button', { 'class': 'btn cbi-button-negative',
                        'click': function () {
                            if (!window.confirm(_('确定向已配置的校园网注销接口发送请求？此操作不保证所有校园网都支持。'))) return;
                            return run('logout');
                        } }, _('校园网账号注销下线')),
                    ' ',
                    E('button', { 'class': 'btn cbi-button-negative',
                        'click': function () {
                            if (!window.confirm(_('确定断开 WAN 接口？互联网连接会中断，当前远程管理连接也可能断开。'))) return;
                            return run('wan-down');
                        } }, _('断开 WAN 网络')),
                    ' ',
                    E('button', { 'class': 'btn cbi-button-action',
                        'click': function () {
                            if (!window.confirm(_('尝试重新启用 WAN 接口？'))) return;
                            return run('wan-up');
                        } }, _('恢复 WAN 网络')),
                    ' ',
                    E('button', { 'class': 'btn cbi-button',
                        'click': function () {
                            return fs.exec('/etc/init.d/campus-auth', ['enable']).then(function () {
                                return fs.exec('/etc/init.d/campus-auth', ['restart']);
                            }).then(function () {
                                ui.addNotification(null, E('p', _('已启用并重启认证插件服务；请确认已保存页面配置。')));
                                refreshStatus();
                            }).catch(function (e) {
                                ui.addNotification(null, E('p', _('服务操作失败：') + e));
                            });
                        } }, _('启用 / 应用配置并重启')),
                    ' ',
                    E('button', { 'class': 'btn cbi-button',
                        'click': function () {
                            return fs.exec('/etc/init.d/campus-auth', ['stop']).then(function () {
                                return fs.exec('/etc/init.d/campus-auth', ['disable']);
                            }).then(function () {
                                ui.addNotification(null, E('p', _('自动认证服务已停止并禁用')));
                                refreshStatus();
                            }).catch(function (e) {
                                ui.addNotification(null, E('p', _('停止服务失败：') + e));
                            });
                        } }, _('停止自动认证'))
                ]),
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', _('运行日志')),
                    E('p', _('日志不会主动记录账号密码、Cookie 或认证响应正文。')),
                    E('pre', { 'id': 'campus-auth-log',
                        'style': 'max-height:28rem;overflow:auto;white-space:pre-wrap' }, _('正在读取日志…')),
                    E('button', { 'class': 'btn cbi-button',
                        'click': function () { refreshLogs(); } }, _('刷新日志'))
                ])
            ]);
            window.setInterval(refreshStatus, 10000);
            window.setInterval(refreshLogs, 5000);
            window.setTimeout(function () { refreshStatus(); refreshLogs(); }, 100);
            return page;
        });
    },
    handleSaveApply: null
});
EOF

cat > /usr/share/luci/menu.d/luci-app-campus-auth.json <<'EOF'
{
  "admin/services/campus-auth": {
    "title": "校园网认证",
    "order": 65,
    "action": { "type": "view", "path": "campus-auth" },
    "depends": { "acl": [ "luci-app-campus-auth" ] }
  }
}
EOF

# Minimal ACL for this plugin. Keep config and service control within LuCI.
cat > /usr/share/rpcd/acl.d/luci-app-campus-auth.json <<'EOF'
{
  "luci-app-campus-auth": {
    "description": "Manage campus network authentication",
    "read": {
      "ubus": {
        "uci": [ "get" ]
      },
      "file": {
        "/etc/config/campus-auth": [ "read" ],
        "/tmp/campus-auth.log": [ "read" ],
        "/tmp/campus-auth-adapter.log": [ "read" ]
      }
    },
    "write": {
      "ubus": {
        "uci": [ "set", "commit", "delete" ]
      },
      "file": {
        "/etc/config/campus-auth": [ "write" ],
        "/usr/lib/campus-auth/control.sh": [ "exec" ],
        "/etc/init.d/campus-auth": [ "exec" ]
      }
    }
  }
}
EOF

# Validate shell syntax and JSON before service restart.
sh -n /usr/lib/campus-auth/common.sh
sh -n /usr/lib/campus-auth/control.sh
sh -n /usr/lib/campus-auth/worker.sh
sh -n /etc/init.d/campus-auth
/bin/bash -n /usr/lib/campus-auth/login.sh
if command -v jsonfilter >/dev/null 2>&1; then
  jsonfilter -i /usr/share/luci/menu.d/luci-app-campus-auth.json -e '@' >/dev/null
  jsonfilter -i /usr/share/rpcd/acl.d/luci-app-campus-auth.json -e '@' >/dev/null
fi

# Ensure service is disabled by default. Do not restart or touch NPS.
/etc/init.d/campus-auth stop >/dev/null 2>&1 || true
/etc/init.d/campus-auth disable >/dev/null 2>&1 || true
rm -f /tmp/campus-auth-netstate

echo
echo '首次安装完成。自动认证仍保持关闭。'
echo '账号、密码、登录/注销接口、检测参数和 Bark 参数可在 LuCI 页面配置。'
echo '新增 WAN 断开/恢复按钮；远程操作请谨慎，WAN 断开可能导致管理连接中断。'
echo 'Next: open LuCI > 服务 > 校园网认证, configure settings, save, then enable the service.'
