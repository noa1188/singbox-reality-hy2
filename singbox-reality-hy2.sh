#!/bin/bash
# Sing-box Reality + Hysteria2 极简一键安装与卸载管理脚本

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

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
	if systemctl list-unit-files | grep -q sing-box.service; then
		echo -e "${GREEN}==> 停止并禁用 Sing-box 服务...${PLAIN}"
		systemctl stop sing-box >/dev/null 2>&1
		systemctl disable sing-box >/dev/null 2>&1
		rm -f /etc/systemd/system/sing-box.service
		systemctl daemon-reload
	fi
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

	echo -e "${GREEN}==> 获取并安装 Sing-box...${PLAIN}"
	ARCH=$(uname -m)
	case "$ARCH" in
	x86_64) SB_ARCH="amd64" ;;
	aarch64) SB_ARCH="arm64" ;;
	*)
		echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
		exit 1
		;;
	esac

	# 支持传入指定版本号，格式 v1.x.x 或 1.x.x
	if [[ -n "$1" ]]; then
		VERSION="$1"
		[[ "$VERSION" != v* ]] && VERSION="v${VERSION}"
		echo -e "${GREEN}==> 使用指定版本: ${VERSION}${PLAIN}"
	else
		VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
		if [[ -z "$VERSION" ]]; then
			echo -e "${RED}获取最新版本号失败，尝试使用备用兜底版本...${PLAIN}"
			VERSION="v1.10.0"
		fi
		echo -e "${GREEN}==> 获取到最新版本: ${VERSION}${PLAIN}"
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

	echo -e "${GREEN}==> 生成 Reality 和 Hysteria2 节点参数...${PLAIN}"
	mkdir -p /etc/sing-box

	UUID=$(cat /proc/sys/kernel/random/uuid)
	SHORT_ID_4=$(openssl rand -hex 4)
	SHORT_ID_8=$(openssl rand -hex 8)
	KEYPAIR=$(/usr/local/bin/sing-box generate reality-keypair)
	PRIVATE_KEY=$(echo "$KEYPAIR" | grep PrivateKey | awk '{print $2}')
	PUBLIC_KEY=$(echo "$KEYPAIR" | grep PublicKey | awk '{print $2}')
	SNI="www.microsoft.com"
	REALITY_PORT=443
	HY2_PORT=8443
	HY2_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
	openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt -days 3650 -subj "/CN=bing.com" >/dev/null 2>&1

	cat >/etc/sing-box/config.json <<CONFIG_EOF
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "tag": "dns", "type": "h3", "server": "8.8.8.8", "server_port": 443, "path": "/dns-query" },
      { "tag": "local", "type": "local" }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "tcp_fast_open": true,
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "min_version": "1.3",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["", "${SHORT_ID_4}", "${SHORT_ID_8}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${HY2_PASSWORD}" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/hy2.crt",
        "key_path": "/etc/sing-box/hy2.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "socks", "tag": "tor", "server": "127.0.0.1", "server_port": 9050, "version": "5" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "default_domain_resolver": "dns",
    "rules": [
      { "action": "sniff" },
      { "rule_set": ["geosite-twitter"], "outbound": "tor" },
      { "domain_suffix": ["ip.sb", "ifconfig.me", "ipinfo.io", "check.torproject.org"], "outbound": "tor" }
    ],
    "rule_set": [
      {
        "tag": "geosite-twitter",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-twitter.srs",
        "download_detour": "direct",
        "update_interval": "24h"
      }
    ],
    "final": "direct"
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "/etc/sing-box/cache.db" }
  }
}
CONFIG_EOF

	# 检测 Tor SOCKS5 是否可用
	if ! ss -tlnp 2>/dev/null | grep -q ':9050' && ! netstat -tlnp 2>/dev/null | grep -q ':9050'; then
		echo -e "${YELLOW}⚠  警告：未检测到 Tor 在 127.0.0.1:9050 监听！${PLAIN}"
		echo -e "${YELLOW}    请确保已安装并启动 tor 服务：${PLAIN}"
		echo -e "    apt install tor && systemctl enable --now tor"
	else
		echo -e "${GREEN}==> 检测到 Tor 已在 127.0.0.1:9050 运行。${PLAIN}"
	fi

	cat >/etc/systemd/system/sing-box.service <<SVC_EOF
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
SVC_EOF

	systemctl daemon-reload
	systemctl enable sing-box >/dev/null 2>&1
	systemctl restart sing-box

	if command -v ufw >/dev/null 2>&1; then
		ufw allow ${REALITY_PORT}/tcp >/dev/null 2>&1
		ufw allow ${HY2_PORT}/udp >/dev/null 2>&1
	elif command -v firewall-cmd >/dev/null 2>&1; then
		firewall-cmd --zone=public --add-port=${REALITY_PORT}/tcp --permanent >/dev/null 2>&1
		firewall-cmd --zone=public --add-port=${HY2_PORT}/udp --permanent >/dev/null 2>&1
		firewall-cmd --reload >/dev/null 2>&1
	fi

	FP_LIST=("chrome" "firefox" "safari" "edge")
	FP=${FP_LIST[$RANDOM % ${#FP_LIST[@]}]}
	VLESS_LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=${FP}&type=tcp&sni=${SNI}&sid=${SHORT_ID_8}&flow=xtls-rprx-vision#${NODE_PREFIX}-Reality"
	HY2_LINK="hy2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}/?insecure=1&sni=bing.com#${NODE_PREFIX}-Hysteria2"

	echo -e "\n${GREEN}================================================================${PLAIN}"
	echo -e "${YELLOW}Sing-box 安装成功！已启动 VLESS-Reality 与 Hysteria2 双协议。${PLAIN}"
	echo -e "${GREEN}================================================================${PLAIN}"
	echo -e "本机 IP  : ${SERVER_IP}"
	echo -e "安装版本 : ${VERSION}"
	echo -e "\n${GREEN}--- 节点 1: VLESS-TCP-Reality ---${PLAIN}"
	echo -e "端口     : ${REALITY_PORT} (TCP)"
	echo -e "UUID     : ${UUID}"
	echo -e "SNI      : ${SNI}"
	echo -e "流控     : xtls-rprx-vision"
	echo -e "Short ID : ${SHORT_ID_4} / ${SHORT_ID_8}"
	echo -e "${YELLOW}分享链接 :${PLAIN}\n${VLESS_LINK}\n"
	echo -e "${YELLOW}扫码导入 :${PLAIN}"
	qrencode -t ANSIUTF8 "$VLESS_LINK"
	echo -e "\n${GREEN}--- 节点 2: Hysteria2 ---${PLAIN}"
	echo -e "端口     : ${HY2_PORT} (UDP)"
	echo -e "密码     : ${HY2_PASSWORD}"
	echo -e "自签证书 : 是 (客户端请开启 insecure)"
	echo -e "${YELLOW}分享链接 :${PLAIN}\n${HY2_LINK}\n"
	echo -e "${YELLOW}扫码导入 :${PLAIN}"
	qrencode -t ANSIUTF8 "$HY2_LINK"
	echo -e "${GREEN}================================================================${PLAIN}\n"
}

# --- 菜单界面 ---
while true; do
	clear
	echo -e "${GREEN}=================================================${PLAIN}"
	echo -e "${YELLOW} Sing-box Reality + Hysteria2 共存管理脚本 ${PLAIN}"
	echo -e "${GREEN}=================================================${PLAIN}"
	echo -e "  ${GREEN}1.${PLAIN} 安装 Sing-box"
	echo -e "  ${GREEN}2.${PLAIN} 卸载 Sing-box"
	echo -e "  ${GREEN}3.${PLAIN} 修改 Reality SNI (伪装域名)"
	echo -e "  ${GREEN}4.${PLAIN} 管理 Tor 分流 Rule Set"
	echo -e "  ${GREEN}0.${PLAIN} 退出脚本"
	echo -e "${GREEN}=================================================${PLAIN}"
	read -rp "请输入数字 [0-4]: " menu_choice

	case "$menu_choice" in
	1)
		echo -e ""
		read -rp "请输入要安装的版本号 (如 v1.13.0，直接回车安装最新版): " INPUT_VER
		INPUT_VER=$(echo "$INPUT_VER" | tr -d ' ')
		install_singbox "$INPUT_VER"
		exit 0
		;;
	2)
		uninstall_singbox
		exit 0
		;;
	3)
		if [[ ! -f "/etc/sing-box/config.json" ]]; then
			echo -e "${RED}错误：未找到 Sing-box 配置文件，请先安装！${PLAIN}"
			read -n 1 -s -r -p "按任意键返回菜单..."
			continue
		fi
		CURRENT_SNI=$(grep -m 1 '"server_name"' /etc/sing-box/config.json | awk -F'"' '{print $4}')
		echo -e "当前 Reality SNI 为: ${GREEN}${CURRENT_SNI}${PLAIN}"
		read -rp "请输入新的 SNI (直接回车保持不变): " NEW_SNI
		if [[ -n "$NEW_SNI" && "$NEW_SNI" != "$CURRENT_SNI" ]]; then
			sed -i "s/\"server_name\": \"${CURRENT_SNI}\"/\"server_name\": \"${NEW_SNI}\"/g" /etc/sing-box/config.json
			sed -i "s/\"server\": \"${CURRENT_SNI}\"/\"server\": \"${NEW_SNI}\"/g" /etc/sing-box/config.json
			systemctl restart sing-box
			if systemctl is-active --quiet sing-box; then
				echo -e "${GREEN}修改成功！Sing-box 已重启。${PLAIN}"
				echo -e "请在客户端将伪装域名(SNI)改为: ${YELLOW}${NEW_SNI}${PLAIN}"
			else
				echo -e "${RED}启动失败，请检查域名格式并手动修复配置。${PLAIN}"
			fi
		else
			echo -e "${YELLOW}已取消或未修改。${PLAIN}"
		fi
		read -n 1 -s -r -p "按任意键返回菜单..."
		;;
	4)
		if [[ ! -f "/etc/sing-box/config.json" ]]; then
			echo -e "${RED}错误：未找到 Sing-box 配置文件，请先安装！${PLAIN}"
			read -n 1 -s -r -p "按任意键返回菜单..."
			continue
		fi
		while true; do
			clear
			echo -e "${GREEN}=============================================${PLAIN}"
			echo -e "${YELLOW}      管理 Tor 分流 Rule Set               ${PLAIN}"
			echo -e "${GREEN}=============================================${PLAIN}"
			echo -e "${YELLOW}格式示例:${PLAIN}"
			echo -e "  https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-twitter.srs"
			echo -e "  https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
			echo -e "${GREEN}=============================================${PLAIN}"
			CURRENT_RULESETS=$(python3 -c "
import json
try:
    with open('/etc/sing-box/config.json') as f:
        cfg = json.load(f)
    route = cfg.get('route', {})
    tor_tags = set()
    for r in route.get('rules', []):
        if r.get('outbound') == 'tor':
            for tag in r.get('rule_set', []):
                tor_tags.add(tag)
    for rs in route.get('rule_set', []):
        if rs.get('tag') in tor_tags:
            print(rs.get('tag') + '  ->  ' + rs.get('url', ''))
except: pass
" 2>/dev/null)
			if [[ -n "$CURRENT_RULESETS" ]]; then
				echo -e "${GREEN}当前 Tor Rule Set 列表：${PLAIN}"
				echo "$CURRENT_RULESETS" | nl -w2 -s". "
				echo -e ""
			else
				echo -e "${YELLOW}当前暂无 Tor Rule Set。${PLAIN}"
			fi
			CURRENT_DOMAINS=$(python3 -c "
import json
try:
    with open('/etc/sing-box/config.json') as f:
        cfg = json.load(f)
    for r in cfg.get('route', {}).get('rules', []):
        if r.get('outbound') == 'tor' and 'domain_suffix' in r:
            for d in r['domain_suffix']:
                print(d)
except: pass
" 2>/dev/null)
			if [[ -n "$CURRENT_DOMAINS" ]]; then
				echo -e "${GREEN}自定义域名列表：${PLAIN}"
				echo "$CURRENT_DOMAINS" | nl -w2 -s". "
				echo -e ""
			fi
			echo -e "  ${GREEN}a.${PLAIN} 添加 Rule Set URL (.srs)"
			echo -e "  ${GREEN}d.${PLAIN} 删除 Rule Set (按 tag 名)"
			echo -e "  ${GREEN}u.${PLAIN} 强制更新所有 Rule Set 缓存"
			echo -e "  ${GREEN}+.${PLAIN} 添加自定义域名/IP检测站"
			echo -e "  ${GREEN}-.${PLAIN} 删除自定义域名"
			echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
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
					python3 -c "
import json
url, tag = '$NEW_URL', '$NEW_TAG'
with open('/etc/sing-box/config.json') as f:
    cfg = json.load(f)
route = cfg.setdefault('route', {})
rulesets = route.setdefault('rule_set', [])
if not any(rs.get('tag') == tag for rs in rulesets):
    rulesets.append({'tag': tag, 'type': 'remote', 'format': 'binary', 'url': url, 'download_detour': 'direct', 'update_interval': '24h'})
rules = route.setdefault('rules', [])
tor_rule = next((r for r in rules if r.get('outbound') == 'tor' and 'rule_set' in r), None)
if tor_rule is None:
    tor_rule = {'rule_set': [], 'outbound': 'tor'}
    rules.insert(0, tor_rule)
if tag not in tor_rule.setdefault('rule_set', []):
    tor_rule['rule_set'].append(tag)
with open('/etc/sing-box/config.json', 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print('OK')
" 2>/dev/null | grep -q OK && {
						systemctl restart sing-box
						echo -e "${GREEN}已添加 Rule Set [${NEW_TAG}] 并重启服务。${PLAIN}"
					} || echo -e "${RED}添加失败，请检查配置文件格式。${PLAIN}"
				fi
				read -n 1 -s -r -p "按任意键继续..."
				;;
			d|D)
				read -rp "请输入要删除的 Rule Set tag (如 geosite-twitter): " DEL_TAG
				DEL_TAG=$(echo "$DEL_TAG" | tr -d ' ')
				if [[ -z "$DEL_TAG" ]]; then
					echo -e "${YELLOW}tag 不能为空，已取消。${PLAIN}"
				else
					python3 -c "
import json
tag = '$DEL_TAG'
with open('/etc/sing-box/config.json') as f:
    cfg = json.load(f)
route = cfg.get('route', {})
route['rule_set'] = [rs for rs in route.get('rule_set', []) if rs.get('tag') != tag]
for r in route.get('rules', []):
    if r.get('outbound') == 'tor' and tag in r.get('rule_set', []):
        r['rule_set'].remove(tag)
with open('/etc/sing-box/config.json', 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print('OK')
" 2>/dev/null | grep -q OK && {
						systemctl restart sing-box
						echo -e "${GREEN}已删除 Rule Set [${DEL_TAG}] 并重启服务。${PLAIN}"
					} || echo -e "${RED}删除失败。${PLAIN}"
				fi
				read -n 1 -s -r -p "按任意键继续..."
				;;
			u|U)
				echo -e "${GREEN}正在强制更新 Rule Set 缓存...${PLAIN}"
				rm -f /etc/sing-box/cache.db
				systemctl restart sing-box
				echo -e "${GREEN}缓存已清除，Rule Set 将在重启后重新下载。${PLAIN}"
				read -n 1 -s -r -p "按任意键继续..."
				;;
			"+")
				read -rp "请输入要添加的域名 (如 ip.sb / ipinfo.io): " ADD_DOMAIN
				ADD_DOMAIN=$(echo "$ADD_DOMAIN" | tr -d ' ')
				if [[ -z "$ADD_DOMAIN" ]]; then
					echo -e "${YELLOW}输入为空，已取消。${PLAIN}"
				else
					python3 -c "
import json
domain = '$ADD_DOMAIN'
with open('/etc/sing-box/config.json') as f:
    cfg = json.load(f)
rules = cfg.setdefault('route', {}).setdefault('rules', [])
ds_rule = next((r for r in rules if r.get('outbound') == 'tor' and 'domain_suffix' in r), None)
if ds_rule is None:
    ds_rule = {'domain_suffix': [], 'outbound': 'tor'}
    rules.append(ds_rule)
if domain not in ds_rule['domain_suffix']:
    ds_rule['domain_suffix'].append(domain)
    with open('/etc/sing-box/config.json', 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print('OK')
else:
    print('EXISTS')
" 2>/dev/null | grep -q OK && {
						systemctl restart sing-box
						echo -e "${GREEN}已添加 [${ADD_DOMAIN}] 并重启服务。${PLAIN}"
					} || echo -e "${YELLOW}该域名已存在，无需重复添加。${PLAIN}"
				fi
				read -n 1 -s -r -p "按任意键继续..."
				;;
			"-")
				read -rp "请输入要删除的域名: " RM_DOMAIN
				RM_DOMAIN=$(echo "$RM_DOMAIN" | tr -d ' ')
				if [[ -z "$RM_DOMAIN" ]]; then
					echo -e "${YELLOW}输入为空，已取消。${PLAIN}"
				else
					python3 -c "
import json
domain = '$RM_DOMAIN'
with open('/etc/sing-box/config.json') as f:
    cfg = json.load(f)
rules = cfg.get('route', {}).get('rules', [])
ds_rule = next((r for r in rules if r.get('outbound') == 'tor' and 'domain_suffix' in r), None)
if ds_rule and domain in ds_rule.get('domain_suffix', []):
    ds_rule['domain_suffix'].remove(domain)
    with open('/etc/sing-box/config.json', 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print('OK')
else:
    print('NOT_FOUND')
" 2>/dev/null | grep -q OK && {
						systemctl restart sing-box
						echo -e "${GREEN}已删除 [${RM_DOMAIN}] 并重启服务。${PLAIN}"
					} || echo -e "${YELLOW}未找到该域名，请检查输入。${PLAIN}"
				fi
				read -n 1 -s -r -p "按任意键继续..."
				;;
			0)
				break
				;;
			*)
				echo -e "${RED}无效输入！${PLAIN}"
				read -n 1 -s -r -p "按任意键继续..."
				;;
			esac
		done
		;;
	0)
		echo -e "${GREEN}退出脚本。${PLAIN}"
		exit 0
		;;
	*)
		echo -e "${RED}请输入正确的数字！${PLAIN}"
		read -n 1 -s -r -p "按任意键继续..."
		;;
	esac
done
