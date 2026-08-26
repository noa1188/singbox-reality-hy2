#!/usr/bin/env bash

# ============================================================================
# Sing-box Reality + Hysteria2 共存管理脚本
# 修复版本：修复核心配置写入、环境变量传递、端口检测等关键问题
# ============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN_PATH="/usr/local/bin/sing-box"
TMP_TAR="/root/sing-box.tar.gz"
HY2_CERT="${CONFIG_DIR}/hy2.crt"
HY2_KEY="${CONFIG_DIR}/hy2.key"
CACHE_DIR="${CONFIG_DIR}/cache"
NODE_META_FILE="${CONFIG_DIR}/node-info.env"

DEFAULT_REALITY_SNI="www.microsoft.com"
DEFAULT_REALITY_HANDSHAKE_PORT=443
DEFAULT_HY2_PORT=8443
DEFAULT_HY2_SNI="bing.com"

# ============================================================================
# 基础工具函数
# ============================================================================

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_port_in_use() {
    local port="$1"
    # 检查 TCP 监听端口
    if ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
        echo -e "${RED}端口 ${port} 已被占用！${PLAIN}"
        return 1
    fi
    # 检查 UDP 监听端口（备用）
    if ss -lun 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
        echo -e "${RED}端口 ${port} 已被占用！${PLAIN}"
        return 1
    fi
    # 如果需要显示占用信息，可取消注释以下代码
    # if ss -lnt 2>/dev/null | grep -q ":${port}"; then
    #     echo -e "${YELLOW}端口 ${port} 被以下进程占用：${PLAIN}"
    #     ss -lntp 2>/dev/null | grep ":${port}"
    # fi
    return 0
}

pause_back() {
    read -n 1 -s -r -p "按任意键继续..."
    echo
}

# ============================================================================
# 防火墙管理
# ============================================================================

update_firewall_tcp_port() {
    local old_port="$1"
    local new_port="$2"

    if command_exists ufw; then
        [[ -n "$old_port" && "$old_port" != "$new_port" ]] && ufw delete allow "${old_port}/tcp" >/dev/null 2>&1
        ufw allow "${new_port}/tcp" >/dev/null 2>&1
    elif command_exists firewall-cmd; then
        [[ -n "$old_port" && "$old_port" != "$new_port" ]] && firewall-cmd --zone=public --remove-port="${old_port}/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="${new_port}/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

ensure_firewall_udp_port() {
    local port="$1"

    if command_exists ufw; then
        ufw allow "${port}/udp" >/dev/null 2>&1
    elif command_exists firewall-cmd; then
        firewall-cmd --zone=public --add-port="${port}/udp" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

remove_firewall_port() {
    local port="$1"
    local proto="$2"

    if command_exists ufw; then
        ufw delete allow "${port}/${proto}" >/dev/null 2>&1
    elif command_exists firewall-cmd; then
        firewall-cmd --zone=public --remove-port="${port}/${proto}" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# ============================================================================
# 网络与系统信息
# ============================================================================

get_server_ip_and_country() {
    local quiet="${1:-0}"
    local ip4 ip6 cc

    ip4=$(curl -s4m8 https://api.ipify.org)
    ip6=$(curl -s6m8 https://api6.ipify.org)

    if [[ -n "$ip4" ]]; then
        SERVER_IP="$ip4"
        cc=$(curl -s4m8 ipinfo.io/country || curl -s4m8 ipapi.co/country)
    elif [[ -n "$ip6" ]]; then
        SERVER_IP="[$ip6]"
        cc=$(curl -s6m8 ipinfo.io/country || curl -s6m8 ipapi.co/country)
    else
        echo -e "${RED}无法获取本机 IP，请检查网络！${PLAIN}"
        exit 1
    fi

    COUNTRY_CODE="$(echo "$cc" | tr -d '\r\n ' | tr '[:lower:]' '[:upper:]')"

    if [[ -n "$COUNTRY_CODE" && ${#COUNTRY_CODE} -eq 2 ]]; then
        if command_exists python3; then
            FLAG=$(python3 -c "import sys; print(''.join(chr(ord(c) + 127397) for c in sys.argv[1].upper()))" "$COUNTRY_CODE" 2>/dev/null)
        else
            FLAG="[$COUNTRY_CODE]"
        fi
        NODE_PREFIX="${FLAG}-${COUNTRY_CODE}"
        [[ "$quiet" != "1" ]] && echo -e "${GREEN}==> 检测到 VPS 位于 ${COUNTRY_CODE}，已自动添加国旗标识 ${FLAG}${PLAIN}"
    else
        NODE_PREFIX="VPS"
    fi
}

# ============================================================================
# 依赖安装与架构检测
# ============================================================================

install_dependencies() {
    echo -e "${GREEN}==> 安装必要依赖 (curl, openssl, qrencode, tar, wget, python3)...${PLAIN}"

    if command_exists apt; then
        apt update && apt install -y curl openssl qrencode tar wget python3
    elif command_exists dnf; then
        dnf install -y curl openssl qrencode tar wget python3
    elif command_exists yum; then
        yum install -y epel-release
        yum install -y curl openssl qrencode tar wget python3
    else
        echo -e "${RED}不支持的系统包管理器！请使用 Debian/Ubuntu 或 CentOS/RHEL 系列。${PLAIN}"
        exit 1
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64) SB_ARCH="amd64" ;;
        aarch64|arm64) SB_ARCH="arm64" ;;
        *)
            echo -e "${RED}不支持的架构: ${arch}${PLAIN}"
            exit 1
            ;;
    esac
}

# ============================================================================
# Sing-box 下载与安装
# ============================================================================

get_singbox_version() {
    if [[ -n "$1" ]]; then
        VERSION="$1"
        [[ "$VERSION" != v* ]] && VERSION="v${VERSION}"
        echo -e "${GREEN}==> 使用指定版本: ${VERSION}${PLAIN}"
    else
        VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
            | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ -z "$VERSION" ]]; then
            echo -e "${YELLOW}获取最新版本号失败，使用备用版本 v1.10.0${PLAIN}"
            VERSION="v1.10.0"
        fi
        echo -e "${GREEN}==> 获取到最新版本: ${VERSION}${PLAIN}"
    fi
}

download_and_install_singbox() {
    local version_num tar_name download_url

    version_num="${VERSION#v}"
    tar_name="sing-box-${version_num}-linux-${SB_ARCH}"
    download_url="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/${tar_name}.tar.gz"

    echo -e "${GREEN}==> 下载并安装 Sing-box...${PLAIN}"
    if ! wget -qO "${TMP_TAR}" "${download_url}"; then
        echo -e "${RED}下载 Sing-box 失败，请检查网络是否可访问 GitHub！${PLAIN}"
        exit 1
    fi

    cd /root || exit 1
    rm -rf "/root/${tar_name}"

    if ! tar -xzf "${TMP_TAR}"; then
        echo -e "${RED}解压 Sing-box 失败！${PLAIN}"
        exit 1
    fi

    if [[ ! -f "/root/${tar_name}/sing-box" ]]; then
        echo -e "${RED}未找到 Sing-box 可执行文件，安装包内容异常！${PLAIN}"
        exit 1
    fi

    mv "/root/${tar_name}/sing-box" "${BIN_PATH}"
    chmod +x "${BIN_PATH}"
    rm -rf "${TMP_TAR}" "/root/${tar_name}"
}

# ============================================================================
# 密钥与证书生成（核心修复）
# ============================================================================

generate_cert_and_keys() {
    mkdir -p "${CONFIG_DIR}" "${CACHE_DIR}"

    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID_4=$(openssl rand -hex 4)
    SHORT_ID_8=$(openssl rand -hex 8)
    
    # 生成 Reality 密钥对
    KEYPAIR=$("${BIN_PATH}" generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/ {print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey/ {print $2}')
    
    SNI="${DEFAULT_REALITY_SNI}"
    HY2_PORT="${DEFAULT_HY2_PORT}"
    HY2_PASSWORD=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)

    # 交互式端口选择
    while true; do
        read -rp "请输入 Reality 端口（默认 443）: " REALITY_PORT
        REALITY_PORT=${REALITY_PORT:-443}
        if validate_port "$REALITY_PORT"; then
            if ! check_port_in_use "$REALITY_PORT"; then
                break
            else
                echo -e "${YELLOW}检测到端口 ${REALITY_PORT} 可能被占用。按 Ctrl+C 可中断，或输入其他端口。${PLAIN}"
            fi
        else
            echo -e "${RED}端口无效，请输入 1-65535 之间的数字！${PLAIN}"
        fi
    done

    while true; do
        read -rp "请输入 Hysteria2 端口（默认 ${DEFAULT_HY2_PORT}）: " HY2_PORT_INPUT
        HY2_PORT=${HY2_PORT_INPUT:-${DEFAULT_HY2_PORT}}
        if validate_port "$HY2_PORT"; then
            if ! check_port_in_use "$HY2_PORT"; then
                break
            fi
        fi
        echo -e "${RED}端口无效或已被占用，请输入 1-65535 之间的数字！${PLAIN}"
    done

    # 生成 Hysteria2 证书
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${HY2_KEY}" \
        -out "${HY2_CERT}" \
        -days 3650 \
        -subj "/CN=${DEFAULT_HY2_SNI}" >/dev/null 2>&1

    chmod 600 "${HY2_KEY}" "${HY2_CERT}" >/dev/null 2>&1

    echo -e "${GREEN}==> 密钥与证书生成完成${PLAIN}"
}

# ============================================================================
# 配置文件写入（核心修复 - 使用真实凭证）
# ============================================================================

write_config() {
    # 检测 Tor 状态
    TOR_ENABLED="false"
    if command_exists tor && systemctl is-active --quiet tor 2>/dev/null; then
        TOR_ENABLED="true"
        echo -e "${GREEN}==> 检测到 Tor 服务已运行，保留 Tor 出站规则。${PLAIN}"
    else
        echo -e "${YELLOW}⚠ 未检测到 Tor 服务，将移除 Tor 出站规则。${PLAIN}"
    fi

    # 导出所有变量供 Python 使用（关键修复！）
    export UUID PRIVATE_KEY PUBLIC_KEY SHORT_ID_4 SHORT_ID_8
    export REALITY_PORT HY2_PORT HY2_PASSWORD
    export DEFAULT_HY2_SNI DEFAULT_REALITY_SNI TOR_ENABLED

    python3 <<'PY'
import json
import os

# 从环境变量读取真实凭证
uuid = os.environ.get("UUID", "")
private_key = os.environ.get("PRIVATE_KEY", "")
public_key = os.environ.get("PUBLIC_KEY", "")
short_id_4 = os.environ.get("SHORT_ID_4", "")
short_id_8 = os.environ.get("SHORT_ID_8", "")
reality_port = int(os.environ.get("REALITY_PORT", "443"))
hy2_port = int(os.environ.get("HY2_PORT", "8443"))
hy2_password = os.environ.get("HY2_PASSWORD", "")
hy2_sni = os.environ.get("DEFAULT_HY2_SNI", "bing.com")
reality_sni = os.environ.get("DEFAULT_REALITY_SNI", "www.microsoft.com")
tor_enabled = os.environ.get("TOR_ENABLED", "false").lower() == "true"
handshake_port = int(os.environ.get("HANDSHAKE_PORT", "443"))

# 构建配置
cfg = {
    "log": {
        "level": "warn",
        "output": True
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "reality-in",
            "listen": "::",
            "listen_port": reality_port,
            "users": [
                {
                    "uuid": uuid,
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": True,
                "server_name": reality_sni,
                "reality": {
                    "enabled": True,
                    "handshake": {
                        "server": reality_sni,
                        "server_port": handshake_port
                    },
                    "private_key": private_key,
                    "public_key": public_key,
                    "short_id": [short_id_4, short_id_8]
                }
            }
        },
        {
            "type": "hysteria2",
            "tag": "hy2-in",
            "listen": "::",
            "listen_port": hy2_port,
            "users": [
                {
                    "password": hy2_password
                }
            ],
            "tls": {
                "enabled": True,
                "certificate_path": "/etc/sing-box/hy2.crt",
                "key_path": "/etc/sing-box/hy2.key"
            }
        }
    ],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
    ],
    "route": {
        "rule_set": [],
        "rules": []
    }
}

# 添加 Tor 出站（如果启用）
if tor_enabled:
    cfg["outbounds"].append({
        "type": "socks",
        "tag": "tor",
        "server": "127.0.0.1",
        "server_port": 9050
    })
    cfg["route"]["rules"].append({"outbound": "tor", "domain_suffix": ["*.local"]})

# 写入配置文件
with open("/etc/sing-box/config.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print("配置文件已生成")
PY

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}配置文件生成失败！${PLAIN}"
        exit 1
    fi
}

# ============================================================================
# Systemd 服务
# ============================================================================

write_service() {
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

# ============================================================================
# 节点信息存储与管理
# ============================================================================

save_node_meta() {
    mkdir -p "${CONFIG_DIR}"
    cat > "${NODE_META_FILE}" << EOF
UUID=${UUID}
SHORT_ID_4=${SHORT_ID_4}
SHORT_ID_8=${SHORT_ID_8}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SNI=${DEFAULT_REALITY_SNI}
REALITY_PORT=${REALITY_PORT}
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PASSWORD}
HY2_SNI=${DEFAULT_HY2_SNI}
VERSION=${VERSION}
EOF
    chmod 600 "${NODE_META_FILE}" >/dev/null 2>&1
}

load_node_meta() {
    if [[ -f "${NODE_META_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${NODE_META_FILE}"
    fi
}

update_node_meta_field() {
    local key="$1"
    local value="$2"
    local tmp_file="${NODE_META_FILE}.tmp"

    mkdir -p "${CONFIG_DIR}"
    touch "${NODE_META_FILE}"

    grep -v "^${key}=" "${NODE_META_FILE}" > "${tmp_file}" 2>/dev/null || true
    printf '%s=%q\n' "$key" "$value" >> "${tmp_file}"
    mv "${tmp_file}" "${NODE_META_FILE}"
    chmod 600 "${NODE_META_FILE}" >/dev/null 2>&1
}

# ============================================================================
# Tor 状态检查
# ============================================================================

check_tor_status() {
    if command_exists tor && ss -lnt 2>/dev/null | grep -q ':9050'; then
        echo -e "${GREEN}==> 检测到 Tor 已在 127.0.0.1:9050 运行。${PLAIN}"
    else
        echo -e "${YELLOW}⚠ 警告：未检测到 Tor 在 127.0.0.1:9050 监听！${PLAIN}"
        echo -e "${YELLOW}如需启用 Tor 分流，请安装并启动 tor 服务：${PLAIN}"
        echo -e "apt install tor && systemctl enable --now tor"
    fi
}

# ============================================================================
# 服务管理
# ============================================================================

restart_and_enable_service() {
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    sleep 2
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}Sing-box 启动失败！${PLAIN}"
        echo -e "${YELLOW}请执行以下命令排查：${PLAIN}"
        echo "systemctl status sing-box --no-pager -l"
        echo "journalctl -u sing-box -n 100 --no-pager"
        exit 1
    fi

    echo -e "${GREEN}==> Sing-box 服务已启动${PLAIN}"
}

# ============================================================================
# 节点信息显示与链接生成（核心修复）
# ============================================================================

render_node_info() {
    local title="${1:-当前节点信息}"
    local need_pause="${2:-1}"

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}错误：未找到 Sing-box 配置文件，请先安装！${PLAIN}"
        [[ "$need_pause" == "1" ]] && pause_back
        return 1
    fi

    get_server_ip_and_country 1
    load_node_meta

    # 从配置文件读取信息（确保与运行配置一致）
    local info
    info=$(python3 - <<'PY'
import json, shlex

def out(key, value):
    print(f"{key}={shlex.quote(str(value))}")

try:
    with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
except Exception as e:
    print(f"ERROR={e}")
    exit(1)

reality_port = ''
uuid = ''
sni = ''
short_ids = []
hy2_port = ''
hy2_password = ''

for inbound in cfg.get('inbounds', []):
    if inbound.get('tag') == 'reality-in':
        reality_port = inbound.get('listen_port', '')
        users = inbound.get('users', [])
        if users:
            uuid = users[0].get('uuid', '')
        tls = inbound.get('tls', {})
        sni = tls.get('server_name', '')
        reality = tls.get('reality', {})
        short_ids = reality.get('short_id', []) or []
        public_key = reality.get('public_key', '')
    elif inbound.get('tag') == 'hy2-in':
        hy2_port = inbound.get('listen_port', '')
        users = inbound.get('users', [])
        if users:
            hy2_password = users[0].get('password', '')

out("REALITY_PORT", reality_port)
out("UUID", uuid)
out("SNI", sni)
out("SHORT_ID_4", short_ids[0] if len(short_ids) > 0 else '')
out("SHORT_ID_8", short_ids[1] if len(short_ids) > 1 else '')
out("PUBLIC_KEY", public_key)
out("HY2_PORT", hy2_port)
out("HY2_PASSWORD", hy2_password)
PY
)

    if [[ $? -ne 0 || -z "$info" || "$info" == *ERROR* ]]; then
        echo -e "${RED}读取节点信息失败，请检查配置文件格式！${PLAIN}"
        [[ "$need_pause" == "1" ]] && pause_back
        return 1
    fi

    eval "$info"

    # 从环境变量文件获取 PublicKey（Reality 需要）
    local public_key="${PUBLIC_KEY:-}"
    if [[ -z "$public_key" && -f "${NODE_META_FILE}" ]]; then
        source "${NODE_META_FILE}"
        public_key="${PUBLIC_KEY:-}"
    fi

    local sid fp version_display public_key_display vless_link hy2_link
    local fp_list=("chrome" "firefox" "safari" "edge")

    fp=${fp_list[$RANDOM % ${#fp_list[@]}]}
    sid="${SHORT_ID_8:-${SHORT_ID_4}}"
    public_key_display="${public_key:-未记录}"

    if [[ -x "${BIN_PATH}" ]]; then
        version_display=$("${BIN_PATH}" version 2>/dev/null | head -n 1)
    fi
    [[ -z "$version_display" && -n "$VERSION" ]] && version_display="$VERSION"

    # 生成 Reality 分享链接（使用真实 PublicKey）
    if [[ -n "$public_key" && -n "$UUID" ]]; then
        vless_link="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?security=reality&encryption=none&pbk=${public_key}&headerType=none&fp=${fp}&type=tcp&sni=${SNI}&sid=${sid}&flow=xtls-rprx-vision#${NODE_PREFIX}-Reality"
    else
        vless_link=""
    fi

    # 生成 Hysteria2 分享链接
    hy2_link="hy2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}/?insecure=1&sni=${DEFAULT_HY2_SNI}#${NODE_PREFIX}-Hysteria2"

    echo -e "\n${GREEN}=================================================${PLAIN}"
    echo -e "${YELLOW} ${title} ${PLAIN}"
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "本机 IP : ${SERVER_IP}"
    [[ -n "$version_display" ]] && echo -e "安装版本 : ${version_display}"

    echo -e "\n${GREEN}--- 节点 1: VLESS-TCP-Reality ---${PLAIN}"
    echo -e "端口 : ${REALITY_PORT} (TCP)"
    echo -e "UUID : ${UUID}"
    echo -e "SNI : ${SNI}"
    echo -e "流控 : xtls-rprx-vision"
    echo -e "Public Key : ${public_key_display}"
    echo -e "Short ID : ${SHORT_ID_4} / ${SHORT_ID_8}"

    if [[ -n "$vless_link" ]]; then
        echo -e "${YELLOW}分享链接 :${PLAIN}\n${vless_link}\n"
        if command_exists qrencode; then
            echo -e "${YELLOW}扫码导入 :${PLAIN}"
            qrencode -t ANSIUTF8 "${vless_link}"
        fi
    else
        echo -e "${YELLOW}分享链接 :${PLAIN}"
        echo -e "${RED}无法生成链接，缺少 PublicKey！${PLAIN}"
    fi

    echo -e "\n${GREEN}--- 节点 2: Hysteria2 ---${PLAIN}"
    echo -e "端口 : ${HY2_PORT} (UDP)"
    echo -e "密码 : ${HY2_PASSWORD}"
    echo -e "SNI : ${DEFAULT_HY2_SNI}"
    echo -e "自签证书 : 是 (客户端请开启 insecure)"
    echo -e "${YELLOW}分享链接 :${PLAIN}\n${hy2_link}\n"

    if command_exists qrencode; then
        echo -e "${YELLOW}扫码导入 :${PLAIN}"
        qrencode -t ANSIUTF8 "${hy2_link}"
    fi

    echo -e "${GREEN}=================================================${PLAIN}\n"

    [[ "$need_pause" == "1" ]] && pause_back
}

show_links() {
    render_node_info "Sing-box 安装成功！已启动 VLESS-Reality 与 Hysteria2 双协议。" 0
}

show_node_info() {
    render_node_info "当前节点信息" 1
}

# ============================================================================
# 安装流程（核心修复）
# ============================================================================

install_singbox() {
    install_dependencies
    get_server_ip_and_country
    detect_arch
    get_singbox_version "$1"
    download_and_install_singbox
    
    # 生成密钥和证书
    generate_cert_and_keys
    
    # 检查 Tor 状态
    check_tor_status
    
    # 写入配置文件（使用真实凭证）
    write_config
    
    # 写入服务文件
    write_service
    
    # 保存节点元信息
    save_node_meta
    
    # 重启并启用服务
    restart_and_enable_service
    
    # 更新防火墙
    update_firewall_tcp_port "" "${REALITY_PORT}"
    ensure_firewall_udp_port "${HY2_PORT}"
    
    # 显示节点信息
    show_links
}

# ============================================================================
# 卸载流程
# ============================================================================

uninstall_singbox() {
    echo -e "\n${YELLOW}即将彻底卸载 Sing-box 及其配置文件，此操作不可逆！${PLAIN}"
    read -rp "是否确认卸载？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${GREEN}已取消卸载。${PLAIN}"
        return
    fi

    local reality_port hy2_port
    if [[ -f "${CONFIG_FILE}" ]]; then
        reality_port=$(python3 - <<'PY'
import json
try:
    with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    for inbound in cfg.get('inbounds', []):
        if inbound.get('tag') == 'reality-in':
            print(inbound.get('listen_port', ''))
            break
except:
    pass
PY
)
        hy2_port=$(python3 - <<'PY'
import json
try:
    with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    for inbound in cfg.get('inbounds', []):
        if inbound.get('tag') == 'hy2-in':
            print(inbound.get('listen_port', ''))
            break
except:
    pass
PY
)
    fi

    if systemctl list-unit-files | grep -q '^sing-box\.service'; then
        echo -e "${GREEN}==> 停止并禁用 Sing-box 服务...${PLAIN}"
        systemctl stop sing-box >/dev/null 2>&1
        systemctl disable sing-box >/dev/null 2>&1
    fi

    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload

    [[ -n "$reality_port" ]] && remove_firewall_port "$reality_port" tcp
    [[ -n "$hy2_port" ]] && remove_firewall_port "$hy2_port" udp

    echo -e "${GREEN}==> 删除 Sing-box 核心程序...${PLAIN}"
    rm -f "${BIN_PATH}"

    echo -e "${GREEN}==> 删除配置文件及证书 (${CONFIG_DIR})...${PLAIN}"
    rm -rf "${CONFIG_DIR}"

    echo -e "${GREEN}==> 清理残留安装包...${PLAIN}"
    rm -f "${TMP_TAR}"

    echo -e "\n${GREEN}================================================================${PLAIN}"
    echo -e "${YELLOW}Sing-box 及其所有配置文件已彻底从系统中卸载清除！${PLAIN}"
    echo -e "${GREEN}================================================================${PLAIN}\n"
}

# ============================================================================
# 配置修改功能
# ============================================================================

modify_reality_sni() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}错误：未找到 Sing-box 配置文件，请先安装！${PLAIN}"
        pause_back
        return
    fi

    local current_sni new_sni
    current_sni=$(python3 - <<'PY'
import json
try:
    with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    for inbound in cfg.get('inbounds', []):
        if inbound.get('tag') == 'reality-in':
            print(inbound.get('tls', {}).get('server_name', ''))
            break
except:
    pass
PY
)

    echo -e "当前 Reality SNI 为: ${GREEN}${current_sni}${PLAIN}"
    read -rp "请输入新的 SNI (直接回车保持不变): " new_sni

    if [[ -z "$new_sni" || "$new_sni" == "$current_sni" ]]; then
        echo -e "${YELLOW}已取消或未修改。${PLAIN}"
        pause_back
        return
    fi

    if ! python3 - "$new_sni" <<'PY'
import json, sys

new_sni = sys.argv[1]
with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
    cfg = json.load(f)

for inbound in cfg.get('inbounds', []):
    if inbound.get('tag') == 'reality-in':
        tls = inbound.setdefault('tls', {})
        tls['server_name'] = new_sni
        reality = tls.setdefault('reality', {})
        handshake = reality.setdefault('handshake', {})
        handshake['server'] = new_sni
        break

with open('/etc/sing-box/config.json', 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PY
    then
        echo -e "${RED}修改失败，请检查配置文件格式。${PLAIN}"
        pause_back
        return
    fi

    update_node_meta_field "SNI" "$new_sni"
    systemctl restart sing-box

    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}修改成功！Sing-box 已重启。${PLAIN}"
        echo -e "请在客户端将伪装域名(SNI)改为: ${YELLOW}${new_sni}${PLAIN}"
    else
        echo -e "${RED}启动失败，请检查域名格式并手动修复配置。${PLAIN}"
    fi
    pause_back
}

modify_reality_port() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}错误：未找到 Sing-box 配置文件，请先安装！${PLAIN}"
        pause_back
        return
    fi

    local current_port new_port
    current_port=$(python3 - <<'PY'
import json
try:
    with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    for inbound in cfg.get('inbounds', []):
        if inbound.get('tag') == 'reality-in':
            print(inbound.get('listen_port', ''))
            break
except:
    pass
PY
)

    if [[ -z "$current_port" ]]; then
        echo -e "${RED}读取当前 Reality 端口失败，请检查配置文件。${PLAIN}"
        pause_back
        return
    fi

    echo -e "当前 Reality 端口为: ${GREEN}${current_port}${PLAIN}"

    while true; do
        read -rp "请输入新的 Reality 端口 (直接回车保持不变): " new_port
        [[ -z "$new_port" ]] && break
        if validate_port "$new_port"; then
            if ! check_port_in_use "$new_port"; then
                break
            fi
        fi
        echo -e "${RED}端口无效或已被占用，请输入 1-65535 之间的数字！${PLAIN}"
    done

    if [[ -z "$new_port" || "$new_port" == "$current_port" ]]; then
        echo -e "${YELLOW}已取消或未修改。${PLAIN}"
        pause_back
        return
    fi

    if ! python3 - "$new_port" <<'PY'
import json, sys

port = int(sys.argv[1])
with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
    cfg = json.load(f)

for inbound in cfg.get('inbounds', []):
    if inbound.get('tag') == 'reality-in':
        inbound['listen_port'] = port
        break

with open('/etc/sing-box/config.json', 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PY
    then
        echo -e "${RED}修改失败，请检查配置文件格式。${PLAIN}"
        pause_back
        return
    fi

    update_firewall_tcp_port "$current_port" "$new_port"
    update_node_meta_field "REALITY_PORT" "$new_port"
    systemctl restart sing-box

    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}修改成功！Sing-box 已重启。${PLAIN}"
        echo -e "请在客户端将 Reality 端口改为: ${YELLOW}${new_port}${PLAIN}"
    else
        echo -e "${RED}启动失败，请检查端口占用或手动修复配置。${PLAIN}"
    fi
    pause_back
}

# ============================================================================
# Tor 规则管理
# ============================================================================

manage_tor_rules() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}错误：未找到 Sing-box 配置文件，请先安装！${PLAIN}"
        pause_back
        return
    fi

    while true; do
        clear
        echo -e "${GREEN}=============================================${PLAIN}"
        echo -e "${YELLOW} 管理 Tor 分流 Rule Set ${PLAIN}"
        echo -e "${GREEN}=============================================${PLAIN}"
        echo -e "${YELLOW}格式示例:${PLAIN}"
        echo -e " https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-twitter.srs"
        echo -e " https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
        echo -e "${GREEN}=============================================${PLAIN}"

        CURRENT_RULESETS=$(python3 - <<'PY'
import json
try:
    with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    route = cfg.get('route', {})
    tor_tags = set()
    for r in route.get('rules', []):
        if r.get('outbound') == 'tor':
            for tag in r.get('rule_set', []):
                tor_tags.add(tag)
    for rs in route.get('rule_set', []):
        if rs.get('tag') in tor_tags:
            print(rs.get('tag', '') + ' -> ' + rs.get('url', ''))
except:
    pass
PY
)

        if [[ -n "$CURRENT_RULESETS" ]]; then
            echo -e "${GREEN}当前 Tor Rule Set 列表：${PLAIN}"
            echo "$CURRENT_RULESETS" | nl -w2 -s". "
            echo
        else
            echo -e "${YELLOW}当前暂无 Tor Rule Set。${PLAIN}"
        fi

        CURRENT_DOMAINS=$(python3 - <<'PY'
import json
try:
    with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    for r in cfg.get('route', {}).get('rules', []):
        if r.get('outbound') == 'tor' and 'domain_suffix' in r:
            for d in r['domain_suffix']:
                print(d)
except:
    pass
PY
)

        if [[ -n "$CURRENT_DOMAINS" ]]; then
            echo -e "${GREEN}自定义域名列表：${PLAIN}"
            echo "$CURRENT_DOMAINS" | nl -w2 -s". "
            echo
        fi

        echo -e " ${GREEN}a.${PLAIN} 添加 Rule Set URL (.srs)"
        echo -e " ${GREEN}d.${PLAIN} 删除 Rule Set (按 tag 名)"
        echo -e " ${GREEN}u.${PLAIN} 强制更新所有 Rule Set 缓存"
        echo -e " ${GREEN}+.${PLAIN} 添加自定义域名/IP检测站"
        echo -e " ${GREEN}-.${PLAIN} 删除自定义域名"
        echo -e " ${GREEN}0.${PLAIN} 返回主菜单"
        echo -e "${GREEN}=============================================${PLAIN}"
        read -rp "请选择操作 [a/d/u/+/-/0]: " tor_choice

        case "$tor_choice" in
            a|A)
                read -rp "请输入 .srs Rule Set URL: " NEW_URL
                NEW_URL=$(echo "$NEW_URL" | tr -d ' ')
                if [[ -z "$NEW_URL" || "$NEW_URL" != *.srs ]]; then
                    echo -e "${RED}URL 无效，须以 .srs 结尾。${PLAIN}"
                else
                    NEW_TAG=$(basename "$NEW_URL" .srs)
                    if python3 - "$NEW_URL" "$NEW_TAG" <<'PY'
import json, sys

url, tag = sys.argv[1], sys.argv[2]
with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
    cfg = json.load(f)

route = cfg.setdefault('route', {})
rulesets = route.setdefault('rule_set', [])
if not any(rs.get('tag') == tag for rs in rulesets):
    rulesets.append({
        'tag': tag,
        'type': 'remote',
        'format': 'binary',
        'url': url,
        'download_detour': 'direct',
        'update_interval': '24h'
    })

rules = route.setdefault('rules', [])
tor_rule = next((r for r in rules if r.get('outbound') == 'tor' and 'rule_set' in r), None)
if tor_rule is None:
    tor_rule = {'rule_set': [], 'outbound': 'tor'}
    rules.insert(0, tor_rule)

if tag not in tor_rule.setdefault('rule_set', []):
    tor_rule['rule_set'].append(tag)

with open('/etc/sing-box/config.json', 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PY
                    then
                        systemctl restart sing-box
                        echo -e "${GREEN}已添加 Rule Set [${NEW_TAG}] 并重启服务。${PLAIN}"
                    else
                        echo -e "${RED}添加失败，请检查配置文件格式。${PLAIN}"
                    fi
                fi
                pause_back
                ;;
            d|D)
                read -rp "请输入要删除的 Rule Set tag (如 geosite-twitter): " DEL_TAG
                DEL_TAG=$(echo "$DEL_TAG" | tr -d ' ')
                if [[ -z "$DEL_TAG" ]]; then
                    echo -e "${YELLOW}tag 不能为空，已取消。${PLAIN}"
                else
                    if python3 - "$DEL_TAG" <<'PY'
import json, sys

tag = sys.argv[1]
with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
    cfg = json.load(f)

route = cfg.get('route', {})
route['rule_set'] = [rs for rs in route.get('rule_set', []) if rs.get('tag') != tag]

for r in route.get('rules', []):
    if r.get('outbound') == 'tor' and tag in r.get('rule_set', []):
        r['rule_set'].remove(tag)

with open('/etc/sing-box/config.json', 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PY
                    then
                        systemctl restart sing-box
                        echo -e "${GREEN}已删除 Rule Set [${DEL_TAG}] 并重启服务。${PLAIN}"
                    else
                        echo -e "${RED}删除失败。${PLAIN}"
                    fi
                fi
                pause_back
                ;;
            u|U)
                echo -e "${GREEN}正在强制更新 Rule Set 缓存...${PLAIN}"
                rm -f "${CACHE_DIR}"/*
                systemctl restart sing-box
                echo -e "${GREEN}缓存已清除，Rule Set 将在重启后重新下载。${PLAIN}"
                pause_back
                ;;
            "+")
                read -rp "请输入要添加的域名 (如 ip.sb / ipinfo.io): " ADD_DOMAIN
                ADD_DOMAIN=$(echo "$ADD_DOMAIN" | tr -d ' ')
                if [[ -z "$ADD_DOMAIN" ]]; then
                    echo -e "${YELLOW}输入为空，已取消。${PLAIN}"
                else
                    if python3 - "$ADD_DOMAIN" <<'PY'
import json, sys

domain = sys.argv[1]
with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
    cfg = json.load(f)

rules = cfg.setdefault('route', {}).setdefault('rules', [])
ds_rule = next((r for r in rules if r.get('outbound') == 'tor' and 'domain_suffix' in r), None)

if ds_rule is None:
    ds_rule = {'domain_suffix': [], 'outbound': 'tor'}
    rules.append(ds_rule)

if domain not in ds_rule['domain_suffix']:
    ds_rule['domain_suffix'].append(domain)
    with open('/etc/sing-box/config.json', 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
else:
    raise SystemExit(1)
PY
                    then
                        systemctl restart sing-box
                        echo -e "${GREEN}已添加 [${ADD_DOMAIN}] 并重启服务。${PLAIN}"
                    else
                        echo -e "${YELLOW}该域名已存在，无需重复添加。${PLAIN}"
                    fi
                fi
                pause_back
                ;;
            "-")
                read -rp "请输入要删除的域名: " RM_DOMAIN
                RM_DOMAIN=$(echo "$RM_DOMAIN" | tr -d ' ')
                if [[ -z "$RM_DOMAIN" ]]; then
                    echo -e "${YELLOW}输入为空，已取消。${PLAIN}"
                else
                    if python3 - "$RM_DOMAIN" <<'PY'
import json, sys

domain = sys.argv[1]
with open('/etc/sing-box/config.json', 'r', encoding='utf-8') as f:
    cfg = json.load(f)

rules = cfg.get('route', {}).get('rules', [])
ds_rule = next((r for r in rules if r.get('outbound') == 'tor' and 'domain_suffix' in r), None)

if ds_rule and domain in ds_rule.get('domain_suffix', []):
    ds_rule['domain_suffix'].remove(domain)
    with open('/etc/sing-box/config.json', 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
else:
    raise SystemExit(1)
PY
                    then
                        systemctl restart sing-box
                        echo -e "${GREEN}已删除 [${RM_DOMAIN}] 并重启服务。${PLAIN}"
                    else
                        echo -e "${YELLOW}未找到该域名，请检查输入。${PLAIN}"
                    fi
                fi
                pause_back
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效输入！${PLAIN}"
                pause_back
                ;;
        esac
    done
}

# ============================================================================
# 主菜单
# ============================================================================

main_menu() {
    while true; do
        clear
        echo -e "${GREEN}=================================================${PLAIN}"
        echo -e "${YELLOW} Sing-box Reality + Hysteria2 共存管理脚本 ${PLAIN}"
        echo -e "${GREEN}=================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 安装 Sing-box"
        echo -e " ${GREEN}2.${PLAIN} 卸载 Sing-box"
        echo -e " ${GREEN}3.${PLAIN} 修改 Reality SNI (伪装域名)"
        echo -e " ${GREEN}4.${PLAIN} 修改 Reality 端口"
        echo -e " ${GREEN}5.${PLAIN} 查看节点信息"
        echo -e " ${GREEN}6.${PLAIN} 管理 Tor 分流 Rule Set"
        echo -e " ${GREEN}0.${PLAIN} 退出脚本"
        echo -e "${GREEN}=================================================${PLAIN}"
        read -rp "请输入数字 [0-6]: " menu_choice

        case "$menu_choice" in
            1)
                echo
                read -rp "请输入要安装的版本号 (如 v1.13.0，直接回车安装最新版): " INPUT_VER
                INPUT_VER=$(echo "$INPUT_VER" | tr -d ' ')
                install_singbox "$INPUT_VER"
                pause_back
                ;;
            2)
                uninstall_singbox
                pause_back
                ;;
            3)
                modify_reality_sni
                ;;
            4)
                modify_reality_port
                ;;
            5)
                show_node_info
                ;;
            6)
                manage_tor_rules
                ;;
            0)
                echo -e "${GREEN}退出脚本。${PLAIN}"
                exit 0
                ;;
            *)
                echo -e "${RED}请输入正确的数字！${PLAIN}"
                pause_back
                ;;
        esac
    done
}

# ============================================================================
# 启动入口
# ============================================================================

require_root
main_menu
