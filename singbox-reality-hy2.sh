#!/bin/bash
# Sing-box Reality + Hysteria2 极简一键安装与卸载管理脚本

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# --- 卸载函数 ---
uninstall_singbox() {
    echo -e "\n${YELLOW}即将彻底卸载 Sing-box 及其配置文件，此操作不可逆！${PLAIN}"
    read -rp "是否确认卸载？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${GREEN}已取消卸载。${PLAIN}"
        exit 0
    fi

    # 1. 停止并禁用 systemd 服务
    if systemctl list-unit-files | grep -q sing-box.service; then
        echo -e "${GREEN}==> 停止并禁用 Sing-box 服务...${PLAIN}"
        systemctl stop sing-box >/dev/null 2>&1
        systemctl disable sing-box >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi

    # 2. 删除核心文件和配置
    echo -e "${GREEN}==> 删除 Sing-box 核心程序...${PLAIN}"
    rm -f /usr/local/bin/sing-box
    echo -e "${GREEN}==> 删除配置文件及证书 (/etc/sing-box)...${PLAIN}"
    rm -rf /etc/sing-box
    echo -e "${GREEN}==> 清理残留安装包...${PLAIN}"
    rm -f /root/sing-box.tar.gz

    echo -e "\n${GREEN}================================================================${PLAIN}"
    echo -e "${YELLOW}Sing-box 及其所有配置文件已彻底从系统中卸载清除！${PLAIN}"
    echo -e "${GREEN}================================================================${PLAIN}\n"
}

# --- 安装函数 ---
install_singbox() {
    # 2. 安装依赖
    echo -e "${GREEN}==> 安装必要依赖 (curl, openssl, qrencode, tar, wget)...${PLAIN}"
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y curl openssl qrencode tar wget
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release
        yum install -y curl openssl qrencode tar wget
    else
        echo -e "${RED}不支持的系统包管理器！请使用 Debian/Ubuntu 或 CentOS 系列。${PLAIN}"
        exit 1
    fi

    # 3. 获取本机 IP 及国家代码
    echo -e "${GREEN}==> 获取本机 IP 及国家地理位置信息...${PLAIN}"
    IP4=$(curl -s4m8 https://api.ipify.org)
    IP6=$(curl -s6m8 https://api6.ipify.org)
    if [[ -n "$IP4" ]]; then
        SERVER_IP="$IP4"
        COUNTRY_CODE=$(curl -s4m8 ipinfo.io/country || curl -s4m8 ipapi.co/country)
    elif [[ -n "$IP6" ]]; then
        SERVER_IP="[$IP6]"
        COUNTRY_CODE=$(curl -s6m8 ipinfo.io/country || curl -s6m8 ipapi.co/country)
    else
        echo -e "${RED}无法获取本机 IP，请检查网络！${PLAIN}"
        exit 1
    fi

    # 转换国家代码为 Emoji 国旗
    if [[ -n "$COUNTRY_CODE" && ${#COUNTRY_CODE} -eq 2 ]]; then
        if command -v python3 >/dev/null 2>&1; then
            FLAG=$(python3 -c "import sys; print(''.join(chr(ord(c) + 127397) for c in sys.argv[1].upper()))" "$COUNTRY_CODE" 2>/dev/null)
        else
            FLAG="[$COUNTRY_CODE]"
        fi
        NODE_PREFIX="${FLAG}-${COUNTRY_CODE}"
        echo -e "${GREEN}==> 检测到 VPS 位于 ${COUNTRY_CODE}，已自动添加国旗标识 ${FLAG}${PLAIN}"
    else
        NODE_PREFIX="VPS"
    fi

    # 4. 下载并安装 Sing-box
    echo -e "${GREEN}==> 获取并安装最新版 Sing-box...${PLAIN}"
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64) SB_ARCH="amd64" ;;
      aarch64) SB_ARCH="arm64" ;;
      *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$VERSION" ]]; then
        echo -e "${RED}获取最新版本号失败，尝试使用备用兜底版本...${PLAIN}"
        VERSION="v1.8.11"
    fi
    VERSION_NUM=${VERSION#v}
    TAR_NAME="sing-box-${VERSION_NUM}-linux-${SB_ARCH}"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/${TAR_NAME}.tar.gz"

    wget -qO sing-box.tar.gz "${DOWNLOAD_URL}"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载 Sing-box 失败，请检查网络环境是否能访问 GitHub！${PLAIN}"
        exit 1
    fi

    tar -xzf sing-box.tar.gz
    mv ${TAR_NAME}/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz ${TAR_NAME}

    # 5. 生成必要参数
    echo -e "${GREEN}==> 生成 Reality 和 Hysteria2 节点参数...${PLAIN}"
    mkdir -p /etc/sing-box

    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)
    KEYPAIR=$(/usr/local/bin/sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep PublicKey | awk '{print $2}')
    SNI="www.cisco.com"
    REALITY_PORT=443

    HY2_PORT=8443
    HY2_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt -days 3650 -subj "/CN=bing.com" >/dev/null 2>&1

    # 6. 生成 Sing-box 配置
    cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "tag": "dns",
        "type": "h3",
        "server": "8.8.8.8",
        "server_port": 443,
        "path": "/dns-query"
      },
      {
        "tag": "local",
        "address": "local"
      }
    ],
    "final": "dns",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/hy2.crt",
        "key_path": "/etc/sing-box/hy2.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

    # 7. 配置 systemd
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    # 8. 防火墙放行
    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${REALITY_PORT}/tcp >/dev/null 2>&1
        ufw allow ${HY2_PORT}/udp >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port=${REALITY_PORT}/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=${HY2_PORT}/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    # 9. 输出信息和二维码
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#${NODE_PREFIX}-Reality"
    HY2_LINK="hy2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}/?insecure=1&sni=bing.com#${NODE_PREFIX}-Hysteria2"

    echo -e "\n${GREEN}================================================================${PLAIN}"
    echo -e "${YELLOW}Sing-box 安装成功！已启动 VLESS-Reality 与 Hysteria2 双协议。${PLAIN}"
    echo -e "${GREEN}================================================================${PLAIN}"
    echo -e "本机 IP: ${SERVER_IP}"

    echo -e "\n${GREEN}--- 节点 1: VLESS-TCP-Reality ---${PLAIN}"
    echo -e "端口: ${REALITY_PORT} (TCP)"
    echo -e "UUID: ${UUID}"
    echo -e "伪装域名(SNI): ${SNI}"
    echo -e "流控: xtls-rprx-vision"
    echo -e "${YELLOW}分享链接:${PLAIN} \n${VLESS_LINK}\n"
    echo -e "${YELLOW}扫码导入:${PLAIN}"
    qrencode -t ANSIUTF8 "$VLESS_LINK"

    echo -e "\n${GREEN}--- 节点 2: Hysteria2 ---${PLAIN}"
    echo -e "端口: ${HY2_PORT} (UDP)"
    echo -e "密码: ${HY2_PASSWORD}"
    echo -e "自签证书: 是 (客户端请开启 insecure / 允许不安全)"
    echo -e "${YELLOW}分享链接:${PLAIN} \n${HY2_LINK}\n"
    echo -e "${YELLOW}扫码导入:${PLAIN}"
    qrencode -t ANSIUTF8 "$HY2_LINK"
    echo -e "${GREEN}================================================================${PLAIN}\n"
}

# --- 菜单界面 ---
clear
echo -e "${GREEN}================================================================${PLAIN}"
echo -e "${YELLOW}       Sing-box 极简管理脚本 (Reality + Hysteria2)              ${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e "  ${GREEN}1.${PLAIN} 全新安装 Sing-box"
echo -e "  ${GREEN}2.${PLAIN} 彻底卸载 Sing-box"
echo -e "  ${GREEN}0.${PLAIN} 退出脚本"
echo -e "${GREEN}================================================================${PLAIN}"
read -rp "请输入数字 [0-2]: " menu_choice

case "$menu_choice" in
    1)
        install_singbox
        ;;
    2)
        uninstall_singbox
        ;;
    0)
        echo -e "${GREEN}已退出。${PLAIN}"
        exit 0
        ;;
    *)
        echo -e "${RED}输入错误，请输入正确的数字。${PLAIN}"
        exit 1
        ;;
esac
