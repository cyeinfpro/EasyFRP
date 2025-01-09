# frp 一键安装配置脚本

# 一键运行
```
bash <(curl -Ls https://raw.githubusercontent.com/cyeinfpro/Shadowsocks-v4first/refs/heads/main/Shadowsocks-v4first.sh)
```
# 功能简介：
 1. 同一脚本可用于「公网服务器 (frps)」或「内网服务器 (frpc)」配置。
 2. 公网服务器只需基础配置 ([common])，并可在脚本菜单中修改 bind_port、dashboard_port、token 等。
 3. 内网服务器可配置并管理多条端口转发规则 (添加/删除/查看)，也可随时修改连接到公网的 IP/域名及端口。
 4. 解决 wget 不支持 socks5:// 的问题，自动通过 curl --socks5 或 proxychains4 wget 下载。
 5. 自动检测并安装最新版本的 frp (多架构支持)。
 6. 提供健康监测与自动恢复、查看日志、重启服务、自动更新、卸载等常见功能。

# 使用方式：
 1) 以 root 身份运行此脚本。
 2) 根据提示选择服务器所在地区（「中国大陆」或「海外」），如选择中国大陆则可配置 SOCKS5 代理下载。
 3) 在主菜单中根据需要配置/修改 公网服务器 (frps) 或内网服务器 (frpc)。
 4) 若要修改公网服务器或内网服务器的配置，进入对应的菜单即可；端口转发规则的添加/删除/查看只在内网服务器侧管理。

# 注意：需在 Debian/Ubuntu 系列系统使用，如需适配其他发行版请自行修改。
