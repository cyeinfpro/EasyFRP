#!/bin/bash
#
# EasyFRP - 一键安装配置脚本

# 注意：此脚本仅支持 Debian 或 Ubuntu 系统。

set -e

# ============================
# 颜色定义
# ============================
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# ============================
# 全局变量定义
# ============================
FRP_DIR="/usr/local/frp"
CONFIG_DIR="/etc/frp"

FRPS_CONF="${CONFIG_DIR}/frps.ini"
FRPC_CONF="${CONFIG_DIR}/frpc.ini"
PROXY_CONF="${CONFIG_DIR}/frp_proxy.conf"

LOG_DIR="/var/log/frp"
FRPS_LOG="${LOG_DIR}/frps.log"
FRPC_LOG="${LOG_DIR}/frpc.log"
HEALTH_LOG="${LOG_DIR}/health_check.log"
SOCAT_LOG="${LOG_DIR}/socat.log"

BACKUP_DIR="${CONFIG_DIR}/backup"

REGION=2         # 默认为海外；脚本交互时可选
FRP_VERSION=""   # 由 get_latest_frp_version() 赋值

# ============================
# 函数定义
# ============================

# 1) 检查是否以 root 用户运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以 root 用户运行此脚本。${NC}"
        exit 1
    fi
}

# 2) 检查操作系统是否为 Debian 或 Ubuntu
check_os() {
    if ! grep -qE "^ID=(debian|ubuntu)$" /etc/os-release; then
        echo -e "${RED}此脚本仅支持 Debian 或 Ubuntu 系统。${NC}"
        exit 1
    fi
}

# 3) 安装必要的软件包
install_dependencies() {
    echo -e "${GREEN}检查并安装必要的软件包...${NC}"
    local packages=("wget" "curl" "proxychains4" "socat" "sshpass" "unzip" "systemd" "cron")
    apt update
    apt install -y "${packages[@]}"
}

# 4) 自动检测最新的 frp 版本
get_latest_frp_version() {
    echo -e "${GREEN}正在获取最新的 frp 版本...${NC}"
    FRP_VERSION=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$FRP_VERSION" ]; then
        echo -e "${RED}无法获取最新的 frp 版本，请检查网络或 GitHub API 状态。${NC}"
        exit 1
    fi
    echo -e "${GREEN}检测到最新的 frp 版本是 v${FRP_VERSION}。${NC}"
}

# 5) 检测系统架构
detect_architecture() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|armv8*)
            ARCH="arm64"
            ;;
        armv7l|armv6l)
            ARCH="arm"
            ;;
        *)
            echo -e "${RED}不支持的架构：$ARCH${NC}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}检测到系统架构：$ARCH${NC}"
}

# 6) 备份配置文件
backup_configs() {
    mkdir -p "$BACKUP_DIR"
    cp -a "$FRPS_CONF" "$FRPC_CONF" "$BACKUP_DIR/" 2>/dev/null || true
    echo -e "${GREEN}配置文件已备份到 ${BACKUP_DIR}。${NC}"
}

# 7) 配置 SOCKS5 代理（仅限中国大陆服务器使用）
configure_proxy() {
    echo -e "${GREEN}配置 SOCKS5 代理...${NC}"
    
    mkdir -p "$CONFIG_DIR"

    while true; do
        read -rp "请输入 SOCKS5 代理的地址（IP 或域名）: " PROXY_ADDR
        if [[ "$PROXY_ADDR" =~ ^([a-zA-Z0-9.-]+)$ ]]; then
            break
        else
            echo -e "${RED}无效的地址，请重新输入。${NC}"
        fi
    done

    while true; do
        read -rp "请输入 SOCKS5 代理的端口: " PROXY_PORT
        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -gt 0 ] && [ "$PROXY_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}无效的端口号，请重新输入。${NC}"
        fi
    done

    while true; do
        read -rp "请输入 SOCKS5 代理的用户名: " PROXY_USER
        if [ -n "$PROXY_USER" ]; then
            break
        else
            echo -e "${RED}用户名不能为空，请重新输入。${NC}"
        fi
    done

    while true; do
        read -srp "请输入 SOCKS5 代理的密码: " PROXY_PASS
        echo
        if [ -n "$PROXY_PASS" ]; then
            break
        else
            echo -e "${RED}密码不能为空，请重新输入。${NC}"
        fi
    done

    cat > "$PROXY_CONF" <<EOF
PROXY_ADDR=${PROXY_ADDR}
PROXY_PORT=${PROXY_PORT}
PROXY_USER=${PROXY_USER}
PROXY_PASS=${PROXY_PASS}
EOF

    echo -e "${GREEN}SOCKS5 代理配置已保存到 ${PROXY_CONF}。${NC}"
}

# 8) 加载 SOCKS5 代理设置
load_proxy() {
    if [ -f "$PROXY_CONF" ]; then
        source "$PROXY_CONF"
        export http_proxy="socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_ADDR}:${PROXY_PORT}"
        export https_proxy="socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_ADDR}:${PROXY_PORT}"
        echo -e "${GREEN}已加载 SOCKS5 代理设置。${NC}"
    fi
}

# 9) 修改 SOCKS5 代理设置
modify_proxy() {
    if [ -f "$PROXY_CONF" ]; then
        echo -e "${GREEN}当前 SOCKS5 代理设置如下：${NC}"
        cat "$PROXY_CONF"
        echo -e "${GREEN}请重新输入新的 SOCKS5 代理设置：${NC}"
    else
        echo -e "${GREEN}当前没有 SOCKS5 代理设置。${NC}"
    fi
    configure_proxy
    load_proxy
}

# 10) 下载并安装 frp（修复 wget 不支持 socks5://）
install_frp() {
    echo -e "${GREEN}开始下载并安装 frp...${NC}"

    local ARCH
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64|armv8*) ARCH="arm64" ;;
        armv7l|armv6l) ARCH="arm" ;;
        *)
            echo -e "${RED}不支持的架构：$(uname -m)${NC}"
            exit 1
            ;;
    esac

    local download_url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
    local tarball="/tmp/frp.tar.gz"
    local frp_dir="/tmp/frp_${FRP_VERSION}_linux_${ARCH}"

    echo -e "${GREEN}准备下载 frp v${FRP_VERSION}，架构：${ARCH}...${NC}"

    if [ -f "$PROXY_CONF" ]; then
        source "$PROXY_CONF"
        echo -e "${GREEN}检测到 SOCKS5 代理配置，尝试通过代理下载 frp...${NC}"

        if command -v curl >/dev/null 2>&1; then
            echo -e "${GREEN}使用 \`curl --socks5\` 方式下载...${NC}"
            curl --socks5 "${PROXY_ADDR}:${PROXY_PORT}" \
                 --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
                 -L "$download_url" -o "$tarball"
        else
            if command -v proxychains4 >/dev/null 2>&1; then
                echo -e "${GREEN}系统中未检测到可用的 curl --socks5，改用 \`proxychains4 wget\` ...${NC}"
                proxychains4 wget "$download_url" -O "$tarball"
            else
                echo -e "${RED}系统无 \`curl --socks5\` 也无 \`proxychains4\` 命令，无法通过 socks5 下载。${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${GREEN}无需代理，直接下载 frp...${NC}"
        wget "$download_url" -O "$tarball"
    fi

    if [ ! -f "$tarball" ]; then
        echo -e "${RED}下载 frp 失败，未生成 ${tarball} 文件。${NC}"
        exit 1
    fi

    tar -xzf "$tarball" -C /tmp
    mkdir -p "$FRP_DIR"
    cp "${frp_dir}/frps" "${frp_dir}/frpc" "$FRP_DIR/"
    chmod +x "$FRP_DIR/frps" "$FRP_DIR/frpc"
    ln -sf "$FRP_DIR/frps" /usr/local/bin/frps
    ln -sf "$FRP_DIR/frpc" /usr/local/bin/frpc
    rm -rf "$tarball" "$frp_dir"

    mkdir -p "$LOG_DIR"
    touch "$FRPS_LOG" "$FRPC_LOG" "$SOCAT_LOG"

    echo -e "${GREEN}frp v${FRP_VERSION} 安装完成。日志文件位于 ${LOG_DIR}。${NC}"
}

# 11) 配置 frps（公网服务器） - 基础
configure_frps() {
    echo -e "${GREEN}配置 公网服务器的 frps（基础配置）...${NC}"

    while true; do
        read -rp "请输入用于 frp 的 token（建议使用强密码）: " FRP_TOKEN
        if [ -n "$FRP_TOKEN" ]; then
            break
        else
            echo -e "${RED}Token 不能为空，请重新输入。${NC}"
        fi
    done

    while true; do
        read -rp "请输入 frps dashboard 的用户名: " DASHBOARD_USER
        if [ -n "$DASHBOARD_USER" ]; then
            break
        else
            echo -e "${RED}用户名不能为空，请重新输入。${NC}"
        fi
    done

    while true; do
        read -srp "请输入 frps dashboard 的密码: " DASHBOARD_PWD
        echo
        if [ -n "$DASHBOARD_PWD" ]; then
            break
        else
            echo -e "${RED}密码不能为空，请重新输入。${NC}"
        fi
    done

    while true; do
        read -rp "请输入 frps 的监听端口（默认 11111）: " FRPS_BIND_PORT
        FRPS_BIND_PORT=${FRPS_BIND_PORT:-11111}
        if [[ "$FRPS_BIND_PORT" =~ ^[0-9]+$ ]] && [ "$FRPS_BIND_PORT" -gt 0 ] && [ "$FRPS_BIND_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}无效的端口号，请重新输入。${NC}"
        fi
    done

    while true; do
        read -rp "请输入 frps dashboard 的监听端口（默认 7000）: " DASHBOARD_PORT
        DASHBOARD_PORT=${DASHBOARD_PORT:-7000}
        if [[ "$DASHBOARD_PORT" =~ ^[0-9]+$ ]] && [ "$DASHBOARD_PORT" -gt 0 ] && [ "$DASHBOARD_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}无效的端口号，请重新输入。${NC}"
        fi
    done

    backup_configs

    cat > "$FRPS_CONF" <<EOF
[common]
bind_port = ${FRPS_BIND_PORT}
dashboard_port = ${DASHBOARD_PORT}
dashboard_user = ${DASHBOARD_USER}
dashboard_pwd = ${DASHBOARD_PWD}
token = ${FRP_TOKEN}
log_file = ${FRPS_LOG}
log_max_days = 3
enable_udp = true
EOF

    cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server (frps)
After=network.target

[Service]
Type=simple
ExecStart=$FRP_DIR/frps -c $FRPS_CONF
Restart=always
RestartSec=5s
StandardOutput=append:$FRPS_LOG
StandardError=append:$FRPS_LOG

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frps
    systemctl start frps

    echo -e "${GREEN}公网服务器的 frps 基础配置完成。${NC}"
    echo -e "${GREEN}frps dashboard 可通过 http://公网服务器_IP:${DASHBOARD_PORT} 访问。${NC}"
}

# 12) 修改已有 frps 的配置
modify_frps_common() {
    if [ ! -f "$FRPS_CONF" ]; then
        echo -e "${RED}frps 配置文件不存在，请先执行“配置 公网服务器”再使用此功能。${NC}"
        return
    fi

    echo -e "${GREEN}当前 frps.ini 的 [common] 配置如下：${NC}"
    grep -E '^(bind_port|dashboard_port|dashboard_user|dashboard_pwd|token)' "$FRPS_CONF" || echo -e "(未检测到相关字段)"

    backup_configs

    # 修改 token
    while true; do
        read -rp "是否修改 frps token？(y/n): " ANS
        case $ANS in
            [Yy]* )
                read -rp "请输入新的 token: " NEW_TOKEN
                sed -i "/^\[common\]/,/^\[.*\]/{s/^token\s*=.*/token = ${NEW_TOKEN}/}" "$FRPS_CONF"
                if ! grep -q "^token\s*=" "$FRPS_CONF"; then
                    sed -i "/^\[common\]/a token = ${NEW_TOKEN}" "$FRPS_CONF"
                fi
                ;;
            [Nn]* ) ;;
            * )
                echo -e "${RED}无效选项，请输入 y 或 n。${NC}"
                continue
                ;;
        esac
        break
    done

    # 修改 dashboard_user
    while true; do
        read -rp "是否修改 frps dashboard 用户名？(y/n): " ANS
        case $ANS in
            [Yy]* )
                read -rp "请输入新的 dashboard_user: " NEW_USER
                sed -i "/^\[common\]/,/^\[.*\]/{s/^dashboard_user\s*=.*/dashboard_user = ${NEW_USER}/}" "$FRPS_CONF"
                if ! grep -q "^dashboard_user\s*=" "$FRPS_CONF"; then
                    sed -i "/^\[common\]/a dashboard_user = ${NEW_USER}" "$FRPS_CONF"
                fi
                ;;
            [Nn]* ) ;;
            * )
                echo -e "${RED}无效选项，请输入 y 或 n。${NC}"
                continue
                ;;
        esac
        break
    done

    # 修改 dashboard_pwd
    while true; do
        read -rp "是否修改 frps dashboard 密码？(y/n): " ANS
        case $ANS in
            [Yy]* )
                read -srp "请输入新的 dashboard_pwd: " NEW_PWD
                echo
                sed -i "/^\[common\]/,/^\[.*\]/{s/^dashboard_pwd\s*=.*/dashboard_pwd = ${NEW_PWD}/}" "$FRPS_CONF"
                if ! grep -q "^dashboard_pwd\s*=" "$FRPS_CONF"; then
                    sed -i "/^\[common\]/a dashboard_pwd = ${NEW_PWD}" "$FRPS_CONF"
                fi
                ;;
            [Nn]* ) ;;
            * )
                echo -e "${RED}无效选项，请输入 y 或 n。${NC}"
                continue
                ;;
        esac
        break
    done

    # 修改 bind_port
    while true; do
        read -rp "是否修改 frps bind_port？(y/n): " ANS
        case $ANS in
            [Yy]* )
                local NEW_BIND_PORT
                while true; do
                    read -rp "请输入新的 frps 监听端口: " NEW_BIND_PORT
                    if [[ "$NEW_BIND_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_BIND_PORT" -gt 0 ] && [ "$NEW_BIND_PORT" -le 65535 ]; then
                        break
                    else
                        echo -e "${RED}无效的端口号，请重新输入。${NC}"
                    fi
                done
                sed -i "/^\[common\]/,/^\[.*\]/{s/^bind_port\s*=.*/bind_port = ${NEW_BIND_PORT}/}" "$FRPS_CONF"
                if ! grep -q "^bind_port\s*=" "$FRPS_CONF"; then
                    sed -i "/^\[common\]/a bind_port = ${NEW_BIND_PORT}" "$FRPS_CONF"
                fi
                ;;
            [Nn]* ) ;;
            * )
                echo -e "${RED}无效选项，请输入 y 或 n。${NC}"
                continue
                ;;
        esac
        break
    done

    # 修改 dashboard_port
    while true; do
        read -rp "是否修改 frps dashboard_port？(y/n): " ANS
        case $ANS in
            [Yy]* )
                local NEW_DASHBOARD_PORT
                while true; do
                    read -rp "请输入新的 dashboard 端口: " NEW_DASHBOARD_PORT
                    if [[ "$NEW_DASHBOARD_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_DASHBOARD_PORT" -gt 0 ] && [ "$NEW_DASHBOARD_PORT" -le 65535 ]; then
                        break
                    else
                        echo -e "${RED}无效的端口号，请重新输入。${NC}"
                    fi
                done
                sed -i "/^\[common\]/,/^\[.*\]/{s/^dashboard_port\s*=.*/dashboard_port = ${NEW_DASHBOARD_PORT}/}" "$FRPS_CONF"
                if ! grep -q "^dashboard_port\s*=" "$FRPS_CONF"; then
                    sed -i "/^\[common\]/a dashboard_port = ${NEW_DASHBOARD_PORT}" "$FRPS_CONF"
                fi
                ;;
            [Nn]* ) ;;
            * )
                echo -e "${RED}无效选项，请输入 y 或 n。${NC}"
                continue
                ;;
        esac
        break
    done

    echo -e "${GREEN}修改完毕，新的 frps.ini [common] 如下：${NC}"
    grep -E '^(bind_port|dashboard_port|dashboard_user|dashboard_pwd|token)' "$FRPS_CONF" || echo -e "(未检测到相关字段)"

    systemctl restart frps
    echo -e "${GREEN}frps 已重启，修改生效。${NC}"
}

# 13) 配置 frpc（内网服务器）
configure_frpc() {
    echo -e "${GREEN}配置 内网服务器的 frpc...${NC}"

    local PUBLIC_IP
    while true; do
        read -rp "请输入 公网服务器的地址（IP 或域名）: " PUBLIC_IP
        if [[ "$PUBLIC_IP" =~ ^([a-zA-Z0-9.-]+)$ ]]; then
            break
        else
            echo -e "${RED}无效的地址，请重新输入。${NC}"
        fi
    done

    local FRPS_BIND_PORT
    while true; do
        read -rp "请输入 公网服务器的 frps 监听端口: " FRPS_BIND_PORT
        if [[ "$FRPS_BIND_PORT" =~ ^[0-9]+$ ]] && [ "$FRPS_BIND_PORT" -gt 0 ] && [ "$FRPS_BIND_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}无效的端口号，请重新输入。${NC}"
        fi
    done

    local FRP_TOKEN
    while true; do
        read -rp "请输入用于 frp 的 token（与公网服务器保持一致）: " FRP_TOKEN
        if [ -n "$FRP_TOKEN" ]; then
            break
        else
            echo -e "${RED}Token 不能为空，请重新输入。${NC}"
        fi
    done

    backup_configs

    cat > "$FRPC_CONF" <<EOF
[common]
server_addr = ${PUBLIC_IP}
server_port = ${FRPS_BIND_PORT}
token = ${FRP_TOKEN}
log_file = ${FRPC_LOG}
log_max_days = 3

# 默认无转发规则，可通过脚本添加
EOF

    cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=frp client (frpc)
After=network.target

[Service]
Type=simple
ExecStart=$FRP_DIR/frpc -c $FRPC_CONF
Restart=always
RestartSec=5s
StandardOutput=append:$FRPC_LOG
StandardError=append:$FRPC_LOG

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frpc
    systemctl start frpc

    echo -e "${GREEN}内网服务器的 frpc 配置完成。${NC}"
}

# 14) 修改内网服务器 [common] 的 server_addr / server_port
modify_frpc_common() {
    if [ ! -f "$FRPC_CONF" ]; then
        echo -e "${RED}frpc 配置文件不存在，请先执行“配置 内网服务器”再使用此功能。${NC}"
        return
    fi

    echo -e "${GREEN}当前 frpc.ini 的 [common] 配置：${NC}"
    grep -E '^(server_addr|server_port)' "$FRPC_CONF" || echo -e "(未检测到 server_addr/server_port 行)"

    local NEW_SERVER_ADDR
    while true; do
        read -rp "请输入新的 公网服务器 IP 或域名: " NEW_SERVER_ADDR
        if [[ "$NEW_SERVER_ADDR" =~ ^([a-zA-Z0-9.-]+)$ ]]; then
            break
        else
            echo -e "${RED}无效的 IP/域名，请重新输入。${NC}"
        fi
    done

    local NEW_SERVER_PORT
    while true; do
        read -rp "请输入新的 公网服务器监听端口: " NEW_SERVER_PORT
        if [[ "$NEW_SERVER_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SERVER_PORT" -gt 0 ] && [ "$NEW_SERVER_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}无效的端口号，请重新输入。${NC}"
        fi
    done

    backup_configs

    sed -i "/^\[common\]/,/^\[.*\]/ {
        s/^server_addr\s*=.*/server_addr = ${NEW_SERVER_ADDR}/
        s/^server_port\s*=.*/server_port = ${NEW_SERVER_PORT}/
    }" "$FRPC_CONF"

    if ! grep -q "^server_addr\s*=" "$FRPC_CONF"; then
        sed -i "/^\[common\]/a server_addr = ${NEW_SERVER_ADDR}" "$FRPC_CONF"
    fi
    if ! grep -q "^server_port\s*=" "$FRPC_CONF"; then
        sed -i "/^\[common\]/a server_port = ${NEW_SERVER_PORT}" "$FRPC_CONF"
    fi

    echo -e "${GREEN}已更新 [common] 段的 server_addr/server_port，现配置：${NC}"
    grep -E '^(server_addr|server_port)' "$FRPC_CONF"

    systemctl restart frpc
    echo -e "${GREEN}frpc 已重启，原有端口转发规则已保留。${NC}"
}

# 15) 添加端口转发规则（内网服务器）
add_rule_frpc() {
    echo -e "${GREEN}添加端口转发规则到 内网服务器 (frpc)...${NC}"
    
    while true; do
        read -rp "请输入转发规则的名称（例如 http）: " RULE_NAME
        if [ -n "$RULE_NAME" ]; then
            if grep -q "^\[${RULE_NAME}_" "$FRPC_CONF"; then
                echo -e "${RED}规则名称已存在，请更换名称。${NC}"
            else
                break
            fi
        else
            echo -e "${RED}规则名称不能为空，请重新输入。${NC}"
        fi
    done

    local LOCAL_IP
    while true; do
        read -rp "请输入本地 IP（默认为 127.0.0.1）: " LOCAL_IP
        LOCAL_IP=${LOCAL_IP:-127.0.0.1}
        if [[ "$LOCAL_IP" =~ ^([a-zA-Z0-9.-]+)$ ]]; then
            break
        else
            echo -e "${RED}无效的 IP 或域名，请重新输入。${NC}"
        fi
    done

    local LOCAL_PORT
    while true; do
        read -rp "请输入本地端口（内网服务器上的端口）: " LOCAL_PORT
        if [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && [ "$LOCAL_PORT" -gt 0 ] && [ "$LOCAL_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口号无效，请重新输入。${NC}"
        fi
    done

    local REMOTE_PORT
    while true; do
        read -rp "请输入远程端口（公网服务器上的端口）: " REMOTE_PORT
        if [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] && [ "$REMOTE_PORT" -gt 0 ] && [ "$REMOTE_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口号无效，请重新输入。${NC}"
        fi
    done

    local TRANSFER_TYPES=()
    while true; do
        echo -e "\n请选择转发类型："
        echo -e "1. TCP"
        echo -e "2. UDP"
        echo -e "3. TCP + UDP"
        read -rp "请输入选项（1-3）: " TYPE_OPTION
        case $TYPE_OPTION in
            1)
                TRANSFER_TYPES=("tcp")
                break
                ;;
            2)
                TRANSFER_TYPES=("udp")
                break
                ;;
            3)
                TRANSFER_TYPES=("tcp" "udp")
                break
                ;;
            *)
                echo -e "${RED}无效的选项，请重新选择。${NC}"
                ;;
        esac
    done

    for TYPE in "${TRANSFER_TYPES[@]}"; do
        cat >> "$FRPC_CONF" <<EOF

[${RULE_NAME}_${TYPE}]
type = ${TYPE}
local_ip = ${LOCAL_IP}
local_port = ${LOCAL_PORT}
remote_port = ${REMOTE_PORT}
EOF
    done

    systemctl restart frpc
    echo -e "${GREEN}已在 内网服务器添加规则 [${RULE_NAME}]，${LOCAL_IP}:${LOCAL_PORT} => 公网端口 ${REMOTE_PORT}。${NC}"
}

# 16) 删除端口转发规则（内网服务器）
delete_rule_frpc() {
    echo -e "${GREEN}删除 内网服务器的端口转发规则...${NC}"
    local RULES
    RULES=$(grep "^\[" "$FRPC_CONF" | awk -F'[][]' '{print $2}' | grep -v "^common$")

    if [ -z "$RULES" ]; then
        echo -e "${GREEN}当前没有可删除的端口转发规则。${NC}"
        return
    fi

    echo -e "${GREEN}当前已有规则：${NC}"
    echo "$RULES"

    local RULE_NAME
    read -rp "请输入要删除的规则名称（不带 _tcp/_udp 后缀）: " RULE_NAME
    local MATCHED_RULES
    MATCHED_RULES=$(grep -E "^\[${RULE_NAME}_(tcp|udp)\]" "$FRPC_CONF" | awk -F'[][]' '{print $2}')

    if [ -z "$MATCHED_RULES" ]; then
        echo -e "${RED}规则名称不存在。${NC}"
        return
    fi

    for RULE in $MATCHED_RULES; do
        sed -i "/^\[${RULE}\]/,/^\[/!b;/^\[${RULE}\]/d" "$FRPC_CONF"
    done

    systemctl restart frpc
    echo -e "${GREEN}已删除规则 [${RULE_NAME}]。${NC}"
}

# 17) 列出端口转发规则（内网服务器）
list_rules_frpc() {
    echo -e "${GREEN}内网服务器的端口转发规则：${NC}"
    local RULES
    RULES=$(grep "^\[" "$FRPC_CONF" | awk -F'[][]' '{print $2}' | grep -v "^common$")
    if [ -z "$RULES" ]; then
        echo -e "${GREEN}当前没有端口转发规则。${NC}"
    else
        for rule in $RULES; do
            echo -e "${GREEN}规则名称：${NC}${rule}"
            grep -A10 "^\[${rule}\]" "$FRPC_CONF" | grep -v "^\["
            echo "----------------------------------------"
        done
    fi
}

# 18) 检查服务状态
check_service_status() {
    local SERVICE_TYPE=$1
    local SERVICE_LABEL
    if [ "$SERVICE_TYPE" == "public" ]; then
        SERVICE_LABEL="frps"
    else
        SERVICE_LABEL="frpc"
    fi

    echo -e "${GREEN}正在检查 ${SERVICE_LABEL} 服务状态...${NC}"
    systemctl status "${SERVICE_LABEL}" --no-pager || true
}

# 19) 重启服务
restart_service() {
    local SERVICE_TYPE=$1
    local SERVICE_LABEL
    if [ "$SERVICE_TYPE" == "public" ]; then
        SERVICE_LABEL="frps"
    else
        SERVICE_LABEL="frpc"
    fi

    echo -e "${GREEN}正在重启 ${SERVICE_LABEL} 服务...${NC}"
    systemctl restart "${SERVICE_LABEL}"
    echo -e "${GREEN}${SERVICE_LABEL} 服务已重启。${NC}"
}

# 20) 卸载 frp
uninstall_frp() {
    echo -e "\n请选择要卸载的服务："
    echo -e "1. 公网服务器的 frps"
    echo -e "2. 内网服务器的 frpc"
    echo -e "3. 同时卸载 公网服务器的 frps 和 内网服务器的 frpc"
    echo -e "4. 返回主菜单"
    read -rp "请输入选项（1-4）: " UNINSTALL_OPTION

    case $UNINSTALL_OPTION in
        1)
            echo -e "${GREEN}正在卸载 公网服务器的 frps...${NC}"
            systemctl stop frps || true
            systemctl disable frps || true
            rm -f /etc/systemd/system/frps.service
            systemctl daemon-reload
            rm -rf "$FRP_DIR"
            rm -f /usr/local/bin/frps /usr/local/bin/frpc
            rm -f "$FRPS_CONF"
            echo -e "${GREEN}公网服务器的 frps 已卸载。${NC}"
            ;;
        2)
            echo -e "${GREEN}正在卸载 内网服务器的 frpc...${NC}"
            systemctl stop frpc || true
            systemctl disable frpc || true
            rm -f /etc/systemd/system/frpc.service
            systemctl daemon-reload
            rm -rf "$FRP_DIR"
            rm -f /usr/local/bin/frps /usr/local/bin/frpc
            rm -f "$FRPC_CONF"
            echo -e "${GREEN}内网服务器的 frpc 已卸载。${NC}"
            ;;
        3)
            echo -e "${GREEN}正在卸载 公网服务器的 frps 和 内网服务器的 frpc...${NC}"
            # 卸载 frps
            systemctl stop frps || true
            systemctl disable frps || true
            rm -f /etc/systemd/system/frps.service
            # 卸载 frpc
            systemctl stop frpc || true
            systemctl disable frpc || true
            rm -f /etc/systemd/system/frpc.service
            # 清理文件
            systemctl daemon-reload
            rm -rf "$FRP_DIR"
            rm -f /usr/local/bin/frps /usr/local/bin/frpc
            rm -f "$FRPS_CONF" "$FRPC_CONF"
            # 清理代理配置
            if [ -f "$PROXY_CONF" ]; then
                rm -f "$PROXY_CONF"
                echo -e "${GREEN}已删除 SOCKS5 代理配置。${NC}"
            fi
            echo -e "${GREEN}frps 和 frpc 已卸载完成。${NC}"
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}无效的选项，请重新选择。${NC}"
            ;;
    esac
}

# 21) 自动更新 frp
auto_update_frp() {
    echo -e "${GREEN}检查 frp 是否有新版本...${NC}"
    local NEW_FRP_VERSION
    NEW_FRP_VERSION=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | \
        grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$NEW_FRP_VERSION" ]; then
        echo -e "${RED}无法获取最新的 frp 版本。${NC}"
        return
    fi

    if [ "$NEW_FRP_VERSION" != "$FRP_VERSION" ]; then
        echo -e "${GREEN}检测到新版本 frp v${NEW_FRP_VERSION}，正在更新...${NC}"
        FRP_VERSION="$NEW_FRP_VERSION"
        install_frp
        echo -e "${GREEN}frp 已更新到 v${FRP_VERSION}。${NC}"
    else
        echo -e "${GREEN}当前已是最新版本 frp v${FRP_VERSION}。${NC}"
    fi
}

# 22) 健康监测与自动恢复
setup_health_monitoring() {
    echo -e "${GREEN}设置健康监测与自动恢复...${NC}"
    
    local HEALTH_CHECK_SCRIPT="/usr/local/bin/frp_health_check.sh"
    mkdir -p "$(dirname "$HEALTH_LOG")"

    cat > "$HEALTH_CHECK_SCRIPT" <<EOF
#!/bin/bash
SERVICES=("frps" "frpc")

for SERVICE in "\${SERVICES[@]}"; do
    if ! systemctl is-active --quiet "\$SERVICE"; then
        echo "\$(date): \$SERVICE 不在运行，尝试重启。" >> "${HEALTH_LOG}"
        systemctl restart "\$SERVICE"
        if systemctl is-active --quiet "\$SERVICE"; then
            echo "\$(date): \$SERVICE 重启成功。" >> "${HEALTH_LOG}"
        else
            echo "\$(date): \$SERVICE 重启失败。" >> "${HEALTH_LOG}"
        fi
    fi
done
EOF

    chmod +x "$HEALTH_CHECK_SCRIPT"

    # 每5分钟执行一次
    (crontab -l 2>/dev/null | grep -v "$HEALTH_CHECK_SCRIPT"; echo "*/5 * * * * $HEALTH_CHECK_SCRIPT") | crontab -

    echo -e "${GREEN}健康监测与自动恢复设置完成。${NC}"
}

# 23) 查看日志
view_logs() {
    echo -e "\n请选择查看的日志类型："
    echo -e "1. frps 日志"
    echo -e "2. frpc 日志"
    echo -e "3. 健康监测日志"
    echo -e "4. Socat 日志"
    echo -e "5. 返回主菜单"
    read -rp "请输入选项（1-5）: " LOG_OPTION

    case $LOG_OPTION in
        1)
            if [ -f "$FRPS_LOG" ]; then
                echo -e "${GREEN}--- frps 日志 ---${NC}"
                tail -f "$FRPS_LOG"
            else
                echo -e "${RED}frps 日志文件不存在。${NC}"
            fi
            ;;
        2)
            if [ -f "$FRPC_LOG" ]; then
                echo -e "${GREEN}--- frpc 日志 ---${NC}"
                tail -f "$FRPC_LOG"
            else
                echo -e "${RED}frpc 日志文件不存在。${NC}"
            fi
            ;;
        3)
            if [ -f "$HEALTH_LOG" ]; then
                echo -e "${GREEN}--- 健康监测日志 ---${NC}"
                tail -f "$HEALTH_LOG"
            else
                echo -e "${RED}健康监测日志文件不存在。${NC}"
            fi
            ;;
        4)
            if [ -f "$SOCAT_LOG" ]; then
                echo -e "${GREEN}--- Socat 日志 ---${NC}"
                tail -f "$SOCAT_LOG"
            else
                echo -e "${RED}Socat 日志文件不存在。${NC}"
            fi
            ;;
        5)
            return
            ;;
        *)
            echo -e "${RED}无效的选项，请重新选择。${NC}"
            ;;
    esac
}

# 24) 主菜单
main_menu() {
    while true; do
        echo -e "\n=========================================="
        echo -e "   公网服务器/内网服务器 frp 设置脚本 "
        echo -e "=========================================="
        echo -e "1. 配置/修改 公网服务器（frps）"
        echo -e "2. 配置/修改 内网服务器（frpc）"
        echo -e "3. 监控服务状态"
        echo -e "4. 重启服务"
        echo -e "5. 查看日志"
        echo -e "6. 自动更新 frp"
        echo -e "7. 设置健康监测与自动恢复"
        echo -e "8. 卸载 frp"
        echo -e "9. 修改 SOCKS5 代理设置（仅限中国大陆服务器）"
        echo -e "10. 退出"
        read -rp "请输入选项（1-10）: " MAIN_OPTION

        case $MAIN_OPTION in
            1)
                manage_frps_menu
                ;;
            2)
                manage_frpc_menu
                ;;
            3)
                echo -e "\n请选择要监控的服务："
                echo -e "1. 公网服务器的 frps"
                echo -e "2. 内网服务器的 frpc"
                echo -e "3. 返回主菜单"
                read -rp "请输入选项（1-3）: " SERVICE_OPTION
                case $SERVICE_OPTION in
                    1)
                        check_service_status "public"
                        ;;
                    2)
                        check_service_status "private"
                        ;;
                    3)
                        ;;
                    *)
                        echo -e "${RED}无效的选项，请重新选择。${NC}"
                        ;;
                esac
                ;;
            4)
                echo -e "\n请选择要重启的服务："
                echo -e "1. 公网服务器的 frps"
                echo -e "2. 内网服务器的 frpc"
                echo -e "3. 返回主菜单"
                read -rp "请输入选项（1-3）: " RESTART_OPTION
                case $RESTART_OPTION in
                    1)
                        restart_service "public"
                        ;;
                    2)
                        restart_service "private"
                        ;;
                    3)
                        ;;
                    *)
                        echo -e "${RED}无效的选项，请重新选择。${NC}"
                        ;;
                esac
                ;;
            5)
                view_logs
                ;;
            6)
                auto_update_frp
                ;;
            7)
                setup_health_monitoring
                ;;
            8)
                uninstall_frp
                ;;
            9)
                if [ "$REGION" != "1" ]; then
                    echo -e "${RED}仅限中国大陆服务器可以修改 SOCKS5 代理设置。${NC}"
                else
                    modify_proxy
                    load_proxy
                fi
                ;;
            10)
                echo -e "${GREEN}退出脚本。${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选项，请重新选择。${NC}"
                ;;
        esac
    done
}

# -- 公网服务器管理菜单 --
manage_frps_menu() {
    while true; do
        echo -e "\n=========================================="
        echo -e "        公网服务器 (frps) 管理菜单         "
        echo -e "=========================================="
        echo -e "1. 安装并配置 frps（基础配置）"
        echo -e "2. 修改现有的 frps 配置"
        echo -e "3. 返回主菜单"
        read -rp "请输入选项（1-3）: " SUB_OPTION

        case $SUB_OPTION in
            1)
                install_frp
                configure_frps
                ;;
            2)
                modify_frps_common
                ;;
            3)
                break
                ;;
            *)
                echo -e "${RED}无效的选项，请重新选择。${NC}"
                ;;
        esac
    done
}

# -- 内网服务器管理菜单 --
manage_frpc_menu() {
    while true; do
        echo -e "\n=========================================="
        echo -e "        内网服务器 (frpc) 管理菜单         "
        echo -e "=========================================="
        echo -e "1. 安装并配置 frpc"
        echo -e "2. 修改 frpc 连接公网服务器的 IP/端口"
        echo -e "3. 管理端口转发规则"
        echo -e "4. 返回主菜单"
        read -rp "请输入选项（1-4）: " SUB_OPTION

        case $SUB_OPTION in
            1)
                install_frp
                configure_frpc
                ;;
            2)
                modify_frpc_common
                ;;
            3)
                manage_frpc_rules
                ;;
            4)
                break
                ;;
            *)
                echo -e "${RED}无效的选项，请重新选择。${NC}"
                ;;
        esac
    done
}

# -- 管理内网服务器的端口转发规则 --
manage_frpc_rules() {
    while true; do
        echo -e "\n=========================================="
        echo -e "        内网服务器 (frpc) 端口转发规则管理        "
        echo -e "=========================================="
        echo -e "1. 添加端口转发规则"
        echo -e "2. 删除端口转发规则"
        echo -e "3. 列出所有端口转发规则"
        echo -e "4. 返回内网服务器管理菜单"
        read -rp "请输入选项（1-4）: " RULE_OPTION

        case $RULE_OPTION in
            1)
                add_rule_frpc
                ;;
            2)
                delete_rule_frpc
                ;;
            3)
                list_rules_frpc
                ;;
            4)
                break
                ;;
            *)
                echo -e "${RED}无效的选项，请重新选择。${NC}"
                ;;
        esac
    done
}

# (入口) 初始化脚本
initialize() {
    echo -e "\n=========================================="
    echo -e "  公网服务器/内网服务器 frp 设置脚本 "
    echo -e "=========================================="

    check_root
    check_os
    install_dependencies
    detect_architecture

    # 选择服务器所在地区
    echo -e "\n请选择服务器所在地区："
    echo -e "1. 中国大陆"
    echo -e "2. 海外"
    while true; do
        read -rp "请输入选项（1或2）: " REGION
        case $REGION in
            1)
                if [ -f "$PROXY_CONF" ]; then
                    echo -e "${GREEN}检测到已配置的 SOCKS5 代理。${NC}"
                else
                    echo -e "${GREEN}您选择了中国大陆服务器，需要配置 SOCKS5 代理。${NC}"
                    configure_proxy
                fi
                load_proxy
                break
                ;;
            2)
                echo -e "${GREEN}您选择了海外服务器，无需配置 SOCKS5 代理。${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效的选项。请重新输入 1 或 2。${NC}"
                ;;
        esac
    done

    get_latest_frp_version
    main_menu
}

# === 执行初始化 ===
initialize

echo -e "${GREEN}frp 脚本执行完毕，可随时运行此脚本进行管理操作！${NC}"
