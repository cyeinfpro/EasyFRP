#!/usr/bin/env bash
#
# EasyFRP 一键安装配置脚本
# 用法：直接执行 bash 脚本即可
#

set -euo pipefail
umask 077

##################################
#      全局变量/默认路径         #
##################################
FRP_DIR="/usr/local/frp"
FRPS_CONF="/etc/frp/frps.ini"
FRPC_CONF="/etc/frp/frpc.ini"
FRPS_LOG="/var/log/frp/frps.log"
FRPC_LOG="/var/log/frp/frpc.log"
LOG_DIR="/var/log/frp"
CONFIG_DIR="/etc/frp"
BACKUP_DIR="/etc/frp/backup"
PROXY_CONF="/etc/frp/proxy.conf"
HEALTH_LOG="/var/log/frp/health_check.log"
FRP_VERSION=""   # 动态获取最新版本后赋值
LANG_CHOICE=""   # 语言选择
REGION=""        # 服务器地区 (1=中国大陆, 2=海外)
LANGUAGE="zh"    # 脚本当前语言, 默认中文

##################################
#          函数区 (顶部)         #
##################################

log_init() {
  mkdir -p "${LOG_DIR}"
  touch "${LOG_DIR}/info.log" "${LOG_DIR}/error.log" "${LOG_DIR}/warning.log"
  chmod 700 "${LOG_DIR}"
}

info() {
  echo -e "\033[0;32m$1\033[0m"
  echo "$(date): INFO: $1" >> "${LOG_DIR}/info.log"
}

warn() {
  echo -e "\033[0;31m$1\033[0m"
  echo "$(date): WARNING: $1" >> "${LOG_DIR}/warning.log"
}

error_exit() {
  echo -e "\033[0;31m$1\033[0m" >&2
  echo "$(date): ERROR: $1" >> "${LOG_DIR}/error.log"
  exit 1
}

validate_address() { [[ "$1" =~ ^[a-zA-Z0-9.-]+$ ]]; }
validate_port()    { [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 && "$1" -le 65535 ]]; }
validate_non_empty(){ [[ -n "$1" ]]; }

generate_random_token() {
  local length="${1:-32}"
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length" ; echo
}

get_public_ip() {
  local IP=""
  for api in \
    "https://api.ipify.org" \
    "https://ipinfo.io/ip" \
    "http://ifconfig.me" \
    "https://ipv4.icanhazip.com" \
    "https://api.my-ip.io/ip"
  do
    IP=$(curl -4 -s "$api" || true); IP=$(echo "$IP" | xargs)
    [ -n "$IP" ] && break
  done
  if [ -z "$IP" ]; then
    for api6 in "https://api6.ipify.org" "https://ifconfig.co" "https://ipv6.icanhazip.com"
    do
      IP=$(curl -6 -s "$api6" || true); IP=$(echo "$IP" | xargs)
      [ -n "$IP" ] && break
    done
  fi
  [ -z "$IP" ] && echo "无法获取公网IP" || echo "$IP"
}

configure_proxy() {
  info "配置 SOCKS5 代理..."
  local a p u pw
  while true; do
    read -rp "代理地址(IP或域名): " a
    validate_address "$a" && break || warn "地址无效"
  done
  while true; do
    read -rp "代理端口: " p
    validate_port "$p" && break || warn "端口无效"
  done
  while true; do
    read -rp "代理用户名: " u
    validate_non_empty "$u" && break || warn "用户名不能为空"
  done
  while true; do
    read -srp "代理密码: " pw; echo
    validate_non_empty "$pw" && break || warn "密码不能为空"
  done

  cat > "$PROXY_CONF" <<EOF
PROXY_ADDR=$a
PROXY_PORT=$p
PROXY_USER=$u
PROXY_PASS=$pw
EOF
  chmod 600 "$PROXY_CONF"
  info "已保存代理到 $PROXY_CONF"
}

load_proxy() {
  [ -f "$PROXY_CONF" ] || return
  source "$PROXY_CONF"
  export FRP_SOCKS5_ADDR="$PROXY_ADDR"
  export FRP_SOCKS5_PORT="$PROXY_PORT"
  export FRP_SOCKS5_USER="$PROXY_USER"
  export FRP_SOCKS5_PASS="$PROXY_PASS"
  info "已加载 Socks5 代理配置"
}

modify_proxy() {
  [ -f "$PROXY_CONF" ] && cat "$PROXY_CONF" || info "当前无代理配置"
  configure_proxy
  load_proxy
}

detect_architecture() {
  case "$(uname -m)" in
    x86_64)            echo "amd64" ;;
    aarch64|armv8*)    echo "arm64" ;;
    armv7l|armv6l)     echo "arm" ;;
    *) error_exit "不支持的架构: $(uname -m)" ;;
  esac
}

download_frp_tarball() {
  local url="$1" dest="$2"
  if [ -n "${FRP_SOCKS5_ADDR:-}" ] && [ -n "${FRP_SOCKS5_PORT:-}" ] && \
     [ -n "${FRP_SOCKS5_USER:-}" ] && [ -n "${FRP_SOCKS5_PASS:-}" ]; then
    if command -v curl &>/dev/null; then
      info "使用 curl --socks5 代理下载: $url"
      if ! curl --socks5 "${FRP_SOCKS5_ADDR}:${FRP_SOCKS5_PORT}" \
                --proxy-user "${FRP_SOCKS5_USER}:${FRP_SOCKS5_PASS}" \
                -L "$url" -o "$dest" --retry 3; then
        warn "代理下载失败,重试..."
        curl --socks5 "${FRP_SOCKS5_ADDR}:${FRP_SOCKS5_PORT}" \
             --proxy-user "${FRP_SOCKS5_USER}:${FRP_SOCKS5_PASS}" \
             -L "$url" -o "$dest" --retry 3 || error_exit "代理下载仍失败"
      fi
    elif command -v proxychains4 &>/dev/null; then
      info "使用 proxychains4 + wget 代理下载: $url"
      if ! proxychains4 wget "$url" -O "$dest" --tries=3; then
        warn "proxychains4下载失败,重试..."
        proxychains4 wget "$url" -O "$dest" --tries=3 || error_exit "proxychains4下载仍失败"
      fi
    else
      error_exit "无 curl --socks5或proxychains4,无法 socks5 代理下载."
    fi
  else
    info "无代理,用wget直接下载: $url"
    if ! wget "$url" -O "$dest" --tries=3; then
      warn "下载失败,重试..."
      wget "$url" -O "$dest" --tries=3 || error_exit "直接下载失败"
    fi
  fi
}

get_latest_frp_version() {
  info "获取 frp 最新版本..."
  FRP_VERSION="$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest \
    | grep '\"tag_name\":' | sed -E 's/.*\"v([^"]+)\".*/\1/')"
  [ -n "$FRP_VERSION" ] || error_exit "无法获取 frp 最新版本."
  info "最新版本: v$FRP_VERSION"
}

install_frp_binary_only() {
  local MODE="$1"
  info "仅安装 $MODE 二进制,不覆盖另一个组件"
  local ARCH; ARCH="$(detect_architecture)"
  local tarball="/tmp/$MODE-only.tar.gz"
  local url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"

  download_frp_tarball "$url" "$tarball"
  local frp_dir="/tmp/frp_${FRP_VERSION}_linux_${ARCH}"
  tar -xzf "$tarball" -C /tmp
  mkdir -p "$FRP_DIR"
  cp -f "${frp_dir}/${MODE}" "$FRP_DIR/${MODE}"
  chmod +x "$FRP_DIR/${MODE}"
  ln -sf "$FRP_DIR/${MODE}" "/usr/local/bin/${MODE}"
  rm -rf "$tarball" "$frp_dir"
  info "$MODE 安装完成"
}

create_service_file() {
  local svc="$1" bin="$2" conf="$3" logf="$4"
  cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=FRP service (${svc})
After=network.target

[Service]
Type=simple
ExecStart=${bin} -c ${conf}
Restart=always
RestartSec=5s
StandardOutput=append:${logf}
StandardError=append:${logf}

[Install]
WantedBy=multi-user.target
EOF
}

start_and_enable_service() {
  systemctl daemon-reload
  systemctl enable "$1"
  systemctl restart "$1"
  info "$1 已启动并开机自启."
}

open_firewall_port() {
  local port="$1"
  if command -v ufw &>/dev/null; then
    ufw allow "$port" || warn "ufw 放行 $port 失败"
    info "ufw 已放行 $port"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --add-port="${port}/tcp" --permanent || true
    firewall-cmd --add-port="${port}/udp" --permanent || true
    firewall-cmd --reload || warn "firewalld reload失败"
    info "firewalld 已放行 $port"
  elif command -v iptables &>/dev/null; then
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    info "iptables 放行 $port(未持久化)"
  else
    warn "无 ufw/firewalld/iptables,跳过放行 $port"
  fi
}

backup_configs() {
  mkdir -p "$BACKUP_DIR"
  cp -a "$FRPS_CONF" "$FRPC_CONF" "$BACKUP_DIR"/ 2>/dev/null || true
  info "配置已备份到 $BACKUP_DIR"
}

configure_frps() {
  info "配置 frps..."
  local token dash_user dash_pwd bind_port dash_port auto_token
  while true; do
    read -rp "自动生成 Token?(y/n): " auto_token
    case "$auto_token" in
      [Yy]*) token=$(generate_random_token 32); info "随机 Token: $token"; break ;;
      [Nn]*) 
        read -rp "请输入 frps Token(建议强密码): " token
        validate_non_empty "$token" || { warn "Token 不能为空"; continue; }
        break
        ;;
      *) warn "无效选项" ;;
    esac
  done
  while true; do
    read -rp "frps dashboard 用户名: " dash_user
    validate_non_empty "$dash_user" && break || warn "不能为空"
  done
  while true; do
    read -srp "frps dashboard 密码: " dash_pwd; echo
    validate_non_empty "$dash_pwd" && break || warn "不能为空"
  done
  read -rp "frps 监听端口(默认11111): " bind_port
  bind_port=${bind_port:-11111}
  validate_port "$bind_port" || error_exit "端口无效"
  read -rp "frps dashboard端口(默认7000): " dash_port
  dash_port=${dash_port:-7000}
  validate_port "$dash_port" || error_exit "端口无效"

  backup_configs
  cat > "$FRPS_CONF" <<EOF
[common]
bind_port = ${bind_port}
dashboard_port = ${dash_port}
dashboard_user = ${dash_user}
dashboard_pwd  = ${dash_pwd}
token = ${token}
log_file = ${FRPS_LOG}
log_max_days = 3
enable_udp = true
EOF
  chmod 600 "$FRPS_CONF"

  get_latest_frp_version
  install_frp_binary_only frps
  create_service_file "frps" "$FRP_DIR/frps" "$FRPS_CONF" "$FRPS_LOG"
  start_and_enable_service "frps"
  open_firewall_port "$bind_port"
  open_firewall_port "$dash_port"

  local pubip; pubip=$(get_public_ip)
  info "frps 配置完成."
  info "公网IP: $pubip"
  info "bind_port: $bind_port"
  info "dashboard_port: $dash_port"
  info "token: $token"
}

configure_frpc() {
  info "配置 frpc..."
  local server_ip server_port token auto_token
  while true; do
    read -rp "公网服务器地址(IP/域名)(默认127.0.0.1): " server_ip
    server_ip=${server_ip:-127.0.0.1}
    validate_address "$server_ip" && break || warn "无效地址"
  done
  while true; do
    read -rp "公网服务器 frps 端口(默认11111): " server_port
    server_port=${server_port:-11111}
    validate_port "$server_port" && break || warn "端口无效"
  done
  while true; do
    read -rp "自动生成 Token?(y/n): " auto_token
    case "$auto_token" in
      [Yy]*) token=$(generate_random_token 32); info "随机 Token: $token"; break ;;
      [Nn]*) 
        read -rp "请输入 frp Token(与frps一致): " token
        validate_non_empty "$token" || { warn "Token不能为空"; continue; }
        break
        ;;
      *) warn "无效选项." ;;
    esac
  done

  backup_configs
  cat > "$FRPC_CONF" <<EOF
[common]
server_addr = ${server_ip}
server_port = ${server_port}
token = ${token}
log_file = ${FRPC_LOG}
log_max_days = 3
EOF
  chmod 600 "$FRPC_CONF"

  get_latest_frp_version
  install_frp_binary_only frpc
  create_service_file "frpc" "$FRP_DIR/frpc" "$FRPC_CONF" "$FRPC_LOG"
  start_and_enable_service "frpc"
  info "frpc 配置完成"
}

modify_frp_common() {
  local type="$1" conf_file svc
  [ "$type" = "frps" ] && conf_file="$FRPS_CONF" svc="frps" || conf_file="$FRPC_CONF" svc="frpc"
  [ -f "$conf_file" ] || { warn "$type 配置文件不存在."; return; }

  info "当前 $type [common] 配置:"
  grep -E '^(bind_port|dashboard_port|dashboard_user|dashboard_pwd|token|server_addr|server_port)' "$conf_file" || echo "(无)"

  backup_configs

  modify_param() {
    local param="$1" prompt="$2" newv
    while true; do
      read -rp "$prompt (y/n): " ans
      case "$ans" in
        [Yy]*)
          if [ "$param" = "token" ]; then
            read -rp "是否自动生成随机 Token(y/n)? " auto_t
            if [[ "$auto_t" =~ ^[Yy]$ ]]; then
              newv=$(generate_random_token 32)
              info "生成随机 Token: $newv"
            else
              read -rp "请输入新的 Token: " newv
              validate_non_empty "$newv" || { warn "不能为空"; continue; }
            fi
          else
            read -rp "请输入新的 $param: " newv
          fi

          if [[ "$param" =~ (bind_port|dashboard_port|server_port) ]]; then
            validate_port "$newv" || { warn "端口无效"; continue; }
          elif [[ "$param" =~ (dashboard_user|dashboard_pwd|server_addr|token) ]]; then
            validate_non_empty "$newv" || { warn "不能为空"; continue; }
          fi

          sed -i "/^\[common\]/,/^\[.*\]/{s/^${param}\s*=.*/${param} = ${newv}/}" "$conf_file"
          grep -q "^${param}\s*=" "$conf_file" || \
            sed -i "/^\[common\]/a ${param} = ${newv}" "$conf_file"
          break
          ;;
        [Nn]*) break ;;
        *) warn "无效选项." ;;
      esac
    done
  }

  if [ "$type" = "frps" ]; then
    modify_param "token"          "修改 frps token？"
    modify_param "dashboard_user" "修改 frps dashboard 用户名？"
    modify_param "dashboard_pwd"  "修改 frps dashboard 密码？"
    modify_param "bind_port"      "修改 frps bind_port？"
    modify_param "dashboard_port" "修改 frps dashboard_port？"
  else
    modify_param "server_addr"    "修改 frpc server_addr？"
    modify_param "server_port"    "修改 frpc server_port？"
    modify_param "token"          "修改 frpc token？"
  fi

  info "新的 [common] 配置:"
  grep -E '^(bind_port|dashboard_port|dashboard_user|dashboard_pwd|token|server_addr|server_port)' "$conf_file" || echo "(无)"
  systemctl restart "$svc"
  info "$svc 已重启,修改生效"
}

add_rule_frpc() {
  info "添加 frpc 转发规则..."
  local RULE_NAME LOCAL_IP LOCAL_PORT REMOTE_PORT
  local -a TRANS_TYPES=() existing=()

  mapfile -t existing < <(grep "^\[" "$FRPC_CONF" | awk -F'[][]' '{print $2}'|grep -v "^common$")
  while true; do
    read -rp "请输入转发规则名称: " RULE_NAME
    [[ -n "$RULE_NAME" ]] || { warn "规则名不能为空"; continue; }
    if [[ " ${existing[*]} " =~ " ${RULE_NAME}_tcp " || " ${existing[*]} " =~ " ${RULE_NAME}_udp " ]]; then
      warn "规则名已存在"
    else
      break
    fi
  done

  read -rp "本地 IP(默认127.0.0.1): " LOCAL_IP
  LOCAL_IP=${LOCAL_IP:-127.0.0.1}
  validate_address "$LOCAL_IP" || error_exit "无效 IP"

  while true; do
    read -rp "本地端口: " LOCAL_PORT
    validate_port "$LOCAL_PORT" && break || warn "端口无效"
  done
  while true; do
    read -rp "远程端口(服务器上): " REMOTE_PORT
    validate_port "$REMOTE_PORT" && break || warn "端口无效"
  done

  while true; do
    echo -e "\n请选择转发类型: 1.TCP 2.UDP 3.TCP+UDP"
    read -rp "选(1-3): " ans
    case "$ans" in
      1) TRANS_TYPES=("tcp"); break ;;
      2) TRANS_TYPES=("udp"); break ;;
      3) TRANS_TYPES=("tcp" "udp"); break ;;
      *) warn "无效选项." ;;
    esac
  done

  for t in "${TRANS_TYPES[@]}"; do
    cat >> "$FRPC_CONF" <<EOF

[${RULE_NAME}_${t}]
type = ${t}
local_ip = ${LOCAL_IP}
local_port = ${LOCAL_PORT}
remote_port = ${REMOTE_PORT}
EOF
  done

  chmod 600 "$FRPC_CONF"
  systemctl restart frpc
  info "已添加转发规则[$RULE_NAME], $LOCAL_IP:$LOCAL_PORT => 远程端口 $REMOTE_PORT"
}

delete_rule_frpc() {
  info "删除 frpc 规则..."
  local -a RULES=() SELS=() final=()
  declare -A rule_map

  mapfile -t RULES < <(grep "^\[" "$FRPC_CONF" | awk -F'[][]' '{print $2}'|grep -v "^common$")
  [ ${#RULES[@]} -eq 0 ] && { info "暂无可删除规则"; return; }

  info "现有规则:"
  printf "%-4s %-20s %-10s %-10s\n" "序" "名称" "local_port" "remote_port"
  local idx=1
  for r in "${RULES[@]}"; do
    local lp rp
    lp=$(grep -A5 "^\[$r\]" "$FRPC_CONF" | grep "^local_port" | awk -F'=' '{print $2}'|xargs)
    rp=$(grep -A5 "^\[$r\]" "$FRPC_CONF" | grep "^remote_port"| awk -F'=' '{print $2}'|xargs)
    printf "%-4d %-20s %-10s %-10s\n" "$idx" "$r" "$lp" "$rp"
    rule_map["$idx"]="$r"
    ((idx++))
  done

  while true; do
    read -rp "输入要删除的规则序号(空格分隔,0取消): " -a SELS
    local valid=true
    for i in "${SELS[@]}"; do
      if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#RULES[@]}" ]; then
        final+=("${rule_map[$i]}")
      elif [ "$i" -eq 0 ]; then
        info "取消删除"
        return
      else
        warn "无效序号: $i"
        valid=false
        break
      fi
    done
    [ "$valid" = true ] && break
  done

  for r in "${final[@]}"; do
    sed -i "/^\[$r\]/,/^\[/d" "$FRPC_CONF"
  done

  chmod 600 "$FRPC_CONF"
  systemctl restart frpc
  info "所选规则已删除."
}

list_rules_frpc() {
  info "当前 frpc 规则列表..."
  local -a RULES=()
  mapfile -t RULES < <(grep "^\[" "$FRPC_CONF" | awk -F'[][]' '{print $2}' | grep -v "^common$")
  [ ${#RULES[@]} -eq 0 ] && { info "暂无规则"; return; }

  printf "%-4s %-20s %-10s %-10s\n" "序" "名称" "local_port" "remote_port"
  local idx=1
  for r in "${RULES[@]}"; do
    local lp rp
    lp=$(grep -A5 "^\[$r\]" "$FRPC_CONF"| grep "^local_port"| awk -F'=' '{print $2}'| xargs)
    rp=$(grep -A5 "^\[$r\]" "$FRPC_CONF"| grep "^remote_port"|awk -F'=' '{print $2}'| xargs)
    printf "%-4d %-20s %-10s %-10s\n" "$idx" "$r" "$lp" "$rp"
    ((idx++))
  done
}

manage_frpc_rules() {
  while true; do
    echo -e "\n==== 内网服务器 (frpc) 规则管理 ===="
    echo "1. 添加规则"
    echo "2. 删除规则"
    echo "3. 列出规则"
    echo "4. 返回"
    read -rp "选(1-4): " sub
    case "$sub" in
      1) add_rule_frpc ;;
      2) delete_rule_frpc ;;
      3) list_rules_frpc ;;
      4) break ;;
      *) warn "无效选项." ;;
    esac
  done
}

enhanced_health_check() {
  local services=("frps" "frpc")
  for s in "${services[@]}"; do
    if systemctl is-active --quiet "$s"; then
      echo "$(date): $s 正常运行。" >> "$HEALTH_LOG"
    else
      echo "$(date): $s 未运行,尝试重启..." >> "$HEALTH_LOG"
      systemctl restart "$s"
      if systemctl is-active --quiet "$s"; then
        echo "$(date): $s 重启成功。" >> "$HEALTH_LOG"
      else
        echo "$(date): $s 重启失败。" >> "$HEALTH_LOG"
      fi
    fi
  done
}

setup_health_monitoring() {
  info "设置健康监测(正常也写日志)..."
  local script="/usr/local/bin/frp_health_check.sh"
  cat > "$script" <<EOF
#!/bin/bash
$(declare -f enhanced_health_check)
enhanced_health_check
EOF
  chmod +x "$script"
  if ! crontab -l 2>/dev/null | grep -q "$script"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * $script") | crontab -
    info "已添加健康监测(每5分钟)"
  fi
  info "健康监测配置完成"
}

setup_logrotate() {
  info "配置 frps/frpc 日志切割..."
  cat > /etc/logrotate.d/frp <<EOF
${FRPS_LOG} ${FRPC_LOG} {
    daily
    rotate 7
    compress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload frps >/dev/null 2>&1 || true
        systemctl reload frpc >/dev/null 2>&1 || true
    endscript
}
EOF
  info "已创建 /etc/logrotate.d/frp,默认每日切割,保留7天"
}

apply_performance_tuning() {
  info "开始应用性能调优(BBR / TCP)..."
  cat > /etc/sysctl.d/99-frp-performance.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=1024
net.core.netdev_max_backlog=250000
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
EOF
  sysctl --system || sysctl -p /etc/sysctl.d/99-frp-performance.conf || true
  local cc; cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true)
  info "当前拥塞控制算法: $cc"
  info "性能调优完成"
}

uninstall_frp() {
  echo -e "\n==== 卸载选项 ===="
  echo "1. 卸载 frps"
  echo "2. 卸载 frpc"
  echo "3. 同时卸载 frps + frpc"
  echo "4. 返回"
  read -rp "选(1-4): " op
  case "$op" in
    1)
      info "卸载 frps..."
      systemctl stop frps || true
      systemctl disable frps || true
      rm -f /etc/systemd/system/frps.service
      systemctl daemon-reload
      rm -f "$FRPS_CONF" /usr/local/bin/frps
      [ -d "$FRP_DIR" ] && rm -rf "$FRP_DIR"
      info "frps 卸载完成."
      ;;
    2)
      info "卸载 frpc..."
      systemctl stop frpc || true
      systemctl disable frpc || true
      rm -f /etc/systemd/system/frpc.service
      systemctl daemon-reload
      rm -f "$FRPC_CONF" /usr/local/bin/frpc
      [ -d "$FRP_DIR" ] && rm -rf "$FRP_DIR"
      info "frpc 卸载完成."
      ;;
    3)
      info "卸载 frps+frpc..."
      systemctl stop frps || true
      systemctl stop frpc || true
      systemctl disable frps || true
      systemctl disable frpc || true
      rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
      systemctl daemon-reload
      rm -f /usr/local/bin/frps /usr/local/bin/frpc "$FRPS_CONF" "$FRPC_CONF"
      rm -rf "$FRP_DIR"
      [ -f "$PROXY_CONF" ] && rm -f "$PROXY_CONF"
      info "frps+frpc 卸载完成."
      ;;
    4) return ;;
    *) warn "无效选项" ;;
  esac
}

auto_update_frp() {
  info "检查 frp 新版本..."
  local newver
  newver=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest \
    | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
  [ -z "$newver" ] && { warn "无法获取最新版本"; return; }
  [ -z "$FRP_VERSION" ] && { warn "未知本地版本,直接更新为 v$newver."; FRP_VERSION="$newver"; }
  if [ "$newver" != "$FRP_VERSION" ]; then
    info "检测到新版本 v$newver,开始更新..."
    FRP_VERSION="$newver"
    systemctl stop frps || true
    systemctl stop frpc || true

    local ARCH="$(detect_architecture)"
    local tarball="/tmp/frp-update.tar.gz"
    local frp_dir="/tmp/frp_${FRP_VERSION}_linux_${ARCH}"
    local url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"

    download_frp_tarball "$url" "$tarball"
    tar -xzf "$tarball" -C /tmp
    mkdir -p "$FRP_DIR"
    cp -f "${frp_dir}/frps" "$FRP_DIR/frps"
    cp -f "${frp_dir}/frpc" "$FRP_DIR/frpc"
    chmod +x "$FRP_DIR/frps" "$FRP_DIR/frpc"
    ln -sf "$FRP_DIR/frps" /usr/local/bin/frps
    ln -sf "$FRP_DIR/frpc" /usr/local/bin/frpc
    rm -rf "$tarball" "$frp_dir"

    systemctl start frps || true
    systemctl start frpc || true
    info "frp 已更新到 v$FRP_VERSION"
  else
    info "当前已是最新版本 v$FRP_VERSION."
  fi
}

check_service_status() {
  local mode="$1" svc="frpc"
  [ "$mode" = "public" ] && svc="frps"
  if systemctl is-active --quiet "$svc"; then
    info "$svc 正在运行"
  else
    warn "$svc 未运行"
  fi
}

restart_service() {
  local mode="$1" svc="frpc"
  [ "$mode" = "public" ] && svc="frps"
  systemctl restart "$svc" && info "$svc 已重启" || warn "$svc 重启失败"
}

##################################
#    补充的功能函数 (菜单等)     #
##################################
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error_exit "本脚本必须以 root 权限运行 (sudo -i 后再执行)。"
  fi
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "当前系统: $NAME $VERSION"
  else
    warn "未知系统, 可能不兼容。"
  fi
}

install_dependencies() {
  if command -v apt-get &>/dev/null; then
    apt-get update -y
    apt-get install -y curl wget
  elif command -v yum &>/dev/null; then
    yum install -y curl wget
  else
    warn "无法自动安装依赖，请手动安装：curl、wget 等。"
  fi
}

check_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    warn "命令 $cmd 不存在，请自行安装。"
  fi
}

manage_frps_menu() {
  while true; do
    echo -e "\n===== FRPS 管理菜单 ====="
    echo "1. 安装或配置 FRPS"
    echo "2. 修改 FRPS 配置"
    echo "3. 返回上级"
    read -rp "请选择(1-3): " choice
    case "$choice" in
      1) configure_frps ;;
      2) modify_frp_common "frps" ;;
      3) break ;;
      *) warn "无效选择." ;;
    esac
  done
}

manage_frpc_menu() {
  while true; do
    echo -e "\n===== FRPC 管理菜单 ====="
    echo "1. 安装或配置 FRPC"
    echo "2. 修改 FRPC 配置"
    echo "3. 管理 FRPC 转发规则"
    echo "4. 返回上级"
    read -rp "请选择(1-4): " choice
    case "$choice" in
      1) configure_frpc ;;
      2) modify_frp_common "frpc" ;;
      3) manage_frpc_rules ;;
      4) break ;;
      *) warn "无效选择." ;;
    esac
  done
}

view_logs() {
  echo -e "\n===== 查看日志 ====="
  echo "1. 查看 FRPS 日志"
  echo "2. 查看 FRPC 日志"
  echo "3. 返回"
  read -rp "请选择(1-3): " choice
  case "$choice" in
    1) [ -f "$FRPS_LOG" ] && less "$FRPS_LOG" || warn "FRPS 日志不存在" ;;
    2) [ -f "$FRPC_LOG" ] && less "$FRPC_LOG" || warn "FRPC 日志不存在" ;;
    3) ;;
    *) warn "无效选择." ;;
  esac
}

##################################
#       主流程 (后面)            #
##################################
init_dirs_logs() {
  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  chmod 700 "$CONFIG_DIR"
  log_init
}

initialize() {
  check_root
  init_dirs_logs
  echo -e "\n===== EasyFRP 一键安装配置脚本 ====="
  detect_os
  install_dependencies
  check_command "curl"
  check_command "wget"
  check_command "proxychains4"

  echo -e "\n请选择语言 / Please select language:"
  echo "1. 中文"
  echo "2. English"
  read -rp "选(1/2): " LANG_CHOICE
  [ "$LANG_CHOICE" = "2" ] && LANGUAGE="en" || LANGUAGE="zh"
  echo "LANGUAGE=${LANGUAGE}" > "${CONFIG_DIR}/language.conf"

  echo -e "\n请选择服务器所在地区:"
  echo "1. 中国大陆"
  echo "2. 海外"
  while true; do
    read -rp "选(1/2): " REGION
    case "$REGION" in
      1)
        [ -f "$PROXY_CONF" ] && info "检测到已有 Socks5 代理配置." || {
          info "需要配置 Socks5 代理(国内环境下载 GitHub 可能更稳定)..."
          configure_proxy
        }
        load_proxy
        break
        ;;
      2)
        info "海外服务器, 无需代理"
        break
        ;;
      *)
        warn "无效选项."
        ;;
    esac
  done
  main_menu
}

main_menu() {
  while true; do
    echo -e "\n========== 主菜单 =========="
    echo "1. 公网服务器 (frps)"
    echo "2. 内网服务器 (frpc)"
    echo "3. 监控服务状态"
    echo "4. 重启服务"
    echo "5. 查看日志"
    echo "6. 自动更新 frp"
    echo "7. 健康监测与自动恢复"
    echo "8. 日志切割配置"
    echo "9. 卸载 frp"
    echo "10. 修改 SOCKS5 代理(仅中国大陆)"
    echo "11. 性能调优 (BBR / TCP 优化)"
    echo "12. 退出"
    read -rp "选(1-12): " sel
    case "$sel" in
      1) manage_frps_menu ;;
      2) manage_frpc_menu ;;
      3)
        echo "1. frps  2. frpc  3. 返回"
        read -rp "选: " svc
        case "$svc" in
          1) check_service_status "public" ;;
          2) check_service_status "private" ;;
          3) ;;
          *) warn "无效选项." ;;
        esac
        ;;
      4)
        echo "1. frps  2. frpc  3. 返回"
        read -rp "选: " rsvc
        case "$rsvc" in
          1) restart_service "public" ;;
          2) restart_service "private" ;;
          3) ;;
          *) warn "无效选项." ;;
        esac
        ;;
      5) view_logs ;;
      6) auto_update_frp ;;
      7) setup_health_monitoring ;;
      8) setup_logrotate ;;
      9) uninstall_frp ;;
      10)
        if [ "$REGION" != "1" ]; then
          warn "仅中国大陆服务器可修改代理."
        else
          modify_proxy
          load_proxy
        fi
        ;;
      11) apply_performance_tuning ;;
      12)
        info "退出脚本."
        exit 0
        ;;
      *) warn "无效选项, 重试." ;;
    esac
  done
}

initialize
info "脚本执行完毕,可随时重新运行本脚本管理 FRP."
