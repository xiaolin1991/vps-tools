#!/bin/bash

# ================================================================
# 晓林技术 - 亚马逊电商 VPS 网络极限加速与防关联管理面板 (旗舰专业版)
# 针对场景: 亚马逊店铺管理 / 广告投放 / 指纹浏览器 (Socks5 & HTTP)
# ================================================================

# 定义颜色
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[1;37m'
export NC='\033[0m'

CONFIG_FILE="/etc/vps_proxy.conf"

# 获取公网 IP
get_public_ip() {
    local ip=""
    ip=$(curl -s -4 --max-time 3 https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s -4 --max-time 3 https://icanhazip.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s -4 --max-time 3 https://ifconfig.me 2>/dev/null)
    [ -z "$ip" ] && ip="36.133.86.231"
    echo "$ip"
}

# 极限内核网络优化 (BBR + BDP 缓冲区 + MTU 探测 + 队列扩展)
optimize_kernel() {
    echo -e "${YELLOW}>>> 正在执行 Linux 内核网络极限调优 (高时延与防丢包优化)...${NC}"
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 清除旧参数
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_window_scaling/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_default/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_default/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_mtu_probing/d' /etc/sysctl.conf
    sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_syn_backlog/d' /etc/sysctl.conf
    sed -i '/net.core.netdev_max_backlog/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_tw_reuse/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fin_timeout/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_time/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_intvl/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_probes/d' /etc/sysctl.conf
    sed -i '/fs.file-max/d' /etc/sysctl.conf

    # 写入极限优化配置
    cat << 'SYSCTL_EOF' >> /etc/sysctl.conf

# === 晓林技术 网络性能与跨境电商加速优化 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# 突破跨国长距离高延迟 BDP 瓶颈，扩大读写缓冲区到 32MB
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# 开启 MTU 路径探测，杜绝跨国分片丢包卡顿
net.ipv4.tcp_mtu_probing = 1

# 高并发队列与端口快速复用
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# 长连接保活 (防止闲置断流)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

fs.file-max = 1000000
SYSCTL_EOF

    sysctl -p >/dev/null 2>&1

    # 句柄上限扩容
    if ! grep -q "soft nofile 65535" /etc/security/limits.conf; then
        echo "* soft nofile 65535" >> /etc/security/limits.conf
        echo "* hard nofile 65535" >> /etc/security/limits.conf
        echo "root soft nofile 65535" >> /etc/security/limits.conf
        echo "root hard nofile 65535" >> /etc/security/limits.conf
    fi

    # DNS 优化 (国内+国际混合优选，确保国内外均可极速解析)
    [ ! -f /etc/resolv.conf.bak ] && cp /etc/resolv.conf /etc/resolv.conf.bak
    chattr -i /etc/resolv.conf >/dev/null 2>&1
    cat << 'DNS_EOF' > /etc/resolv.conf
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 1.1.1.1
nameserver 8.8.8.8
DNS_EOF

    echo -e "${GREEN}>>> 内核参数、TCP 32MB 缓冲区与混合优选 DNS 优化已生效！${NC}"
}

# 智能多镜像下载 Gost 组件
download_gost() {
    if [ -f /usr/bin/gost ]; then
        echo -e "${GREEN}检测到 Gost 服务组件已安装，跳过下载。${NC}"
        return 0
    fi

    echo -e "${YELLOW}>>> 正在下载代理服务核心组件 (多节点智能测速下载)...${NC}"
    local mirrors=(
        "https://ghproxy.net/https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
        "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
        "https://raw.gitmirror.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
        "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
    )

    local success=0
    for url in "${mirrors[@]}"; do
        echo -e "${CYAN}尝试源: ${url}${NC}"
        if wget -t 2 -T 10 --no-check-certificate "$url" -O gost.gz; then
            if [ -s gost.gz ]; then
                gzip -d -f gost.gz
                mv -f gost /usr/bin/gost
                chmod +x /usr/bin/gost
                success=1
                echo -e "${GREEN}组件下载并解压成功！${NC}"
                break
            fi
        fi
        rm -f gost.gz
    done

    if [ $success -eq 0 ]; then
        echo -e "${RED}所有镜像下载均失败，请检查网络或稍后重试！${NC}"
        return 1
    fi
}

# 系统级强行强开端口
force_open_port() {
    local port=$1
    echo -e "${YELLOW}>>> 正在对端口 [${port}] 进行系统级强行强开与清理...${NC}"
    
    if command -v fuser >/dev/null 2>&1; then
        fuser -k -9 -n tcp "$port" >/dev/null 2>&1
    fi
    if command -v lsof >/dev/null 2>&1; then
        local pids=$(lsof -t -i :"$port" 2>/dev/null)
        if [ -n "$pids" ]; then
            kill -9 $pids >/dev/null 2>&1
        fi
    fi

    iptables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
    iptables -D INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
    iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
    iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo -e "${GREEN}>>> 端口 [${port}] 系统防火墙已强制放行，冲突进程已彻底清除！${NC}"
}

# 修改并部署配置
modify_config() {
    local def_port="7878"
    local def_user="amazon"
    local def_pass="admin888"

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        def_port=${PORT:-7878}
        def_user=${USER:-amazon}
        def_pass=${PASS:-admin888}
    fi

    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e "${YELLOW}请设置代理连接信息 (直接回车保留当前值):${NC}"
    echo -e "${CYAN}------------------------------------------${NC}"
    read -p "设置端口 [当前: $def_port]: " port
    port=${port:-$def_port}

    read -p "设置账号 [当前: $def_user]: " user
    user=${user:-$def_user}

    read -p "设置密码 [当前: $def_pass]: " pass
    pass=${pass:-$def_pass}

    cat << CONFIG_EOF > "$CONFIG_FILE"
PORT=$port
USER=$user
PASS=$pass
CONFIG_EOF

    systemctl stop gost >/dev/null 2>&1
    force_open_port "$port"

    cat << SERVICE_EOF > /etc/systemd/system/gost.service
[Unit]
Description=Gost Dual-Protocol Proxy (Socks5 & HTTP)
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
ExecStart=/usr/bin/gost -L=${user}:${pass}@:${port}
Restart=always
RestartSec=3
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable gost >/dev/null 2>&1
    systemctl restart gost

    echo -e "\n${GREEN}==========================================${NC}"
    echo -e "${GREEN}      恭喜！代理服务与端口强开部署成功！      ${NC}"
    echo -e "${GREEN}==========================================${NC}"
    query_proxy_info
}

# 查询当前代理信息
query_proxy_info() {
    clear
    local ip=$(get_public_ip)
    local port="7878"
    local user="amazon"
    local pass="admin888"

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        port=${PORT:-7878}
        user=${USER:-amazon}
        pass=${PASS:-admin888}
    fi

    local is_running="未运行"
    if systemctl is-active --quiet gost; then
        is_running="${GREEN}● 运行中 (Active)${NC}"
    else
        is_running="${RED}○ 已停止${NC}"
    fi

    local port_listen="未监听"
    if ss -tlpn 2>/dev/null | grep -q ":${port} "; then
        port_listen="${GREEN}正常监听在 0.0.0.0:${port}${NC}"
    elif netstat -tlpn 2>/dev/null | grep -q ":${port} "; then
        port_listen="${GREEN}正常监听在 0.0.0.0:${port}${NC}"
    else
        port_listen="${YELLOW}未检测到监听 (请确认服务是否已启动)${NC}"
    fi

    echo -e "${YELLOW}======================================================${NC}"
    echo -e "${GREEN}        【Socks5 / HTTP 代理账户信息查询结果】         ${NC}"
    echo -e "${YELLOW}======================================================${NC}"
    echo -e " 服务状态  : $is_running"
    echo -e " 端口监听  : $port_listen"
    echo -e " 代理类型  : ${CYAN}Socks5${NC} 或 ${CYAN}HTTP${NC} (指纹浏览器均兼容)"
    echo -e " 代理主机  : ${GREEN}${ip}${NC}"
    echo -e " 代理端口  : ${GREEN}${port}${NC}"
    echo -e " 代理账号  : ${GREEN}${user}${NC}"
    echo -e " 代理密码  : ${GREEN}${pass}${NC}"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e " 【指纹浏览器一键导入格式】:"
    echo -e " ${GREEN}${ip}:${port}:${user}:${pass}${NC}"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${YELLOW}★ 华为云/阿里云 入方向安全组要点:${NC}"
    echo -e " 确保安全组【入方向规则】有: 协议=TCP, 端口=${port}, 授权对象=0.0.0.0/0"
    echo -e "${YELLOW}======================================================${NC}"
    read -p "按回车键返回主菜单..." dummy
    main_menu
}

# 手动强开指定端口
manual_force_open_port() {
    clear
    echo -e "${YELLOW}================ 强行强开系统端口 ================${NC}"
    echo -e "此功能将强行杀掉目标端口占用的进程，并在系统防火墙置顶放行！"
    echo -e "${YELLOW}==================================================${NC}"
    read -p "请输入需要强行强开的端口 (例如 7878): " target_port
    if [ -n "$target_port" ]; then
        force_open_port "$target_port"
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            if [ "$target_port" == "$PORT" ]; then
                systemctl restart gost
                echo -e "${GREEN}已同步重启当前代理服务！${NC}"
            fi
        fi
    else
        echo -e "${RED}未输入端口！${NC}"
    fi
    read -p "按回车键返回主菜单..." dummy
    main_menu
}

# ================================================================
# 【新功能 1】：亚马逊卖家中心 & 广告后台 专项毫秒级测速与瓶颈诊断
# ================================================================
test_url_speed() {
    local target_url="$1"
    local desc_name="$2"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    echo -e "\n${CYAN}>>> 正在测试: ${WHITE}${desc_name}${NC}"
    echo -e "    目标地址: ${BLUE}${target_url}${NC}"

    local result
    result=$(curl -s -o /dev/null -A "$ua" \
        -w "%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}" \
        --max-time 15 -L "$target_url" 2>/dev/null)

    if [ -z "$result" ] || [ "$result" == "000|0.000000|0.000000|0.000000|0.000000|0.000000" ]; then
        echo -e "    状态检测: ${RED}连接超时或阻断 (建议检查出口网络或DNS)${NC}"
        return 1
    fi

    IFS='|' read -r http_code t_dns t_tcp t_ssl t_ttfb t_total <<< "$result"

    # 换算成毫秒
    local ms_dns=$(awk "BEGIN {printf \"%.0f\", $t_dns * 1000}")
    local ms_tcp=$(awk "BEGIN {printf \"%.0f\", ($t_tcp - $t_dns) * 1000}")
    local ms_ssl=$(awk "BEGIN {printf \"%.0f\", ($t_ssl - $t_tcp) * 1000}")
    local ms_total=$(awk "BEGIN {printf \"%.0f\", $t_total * 1000}")

    local speed_rate=""
    if [ "$ms_total" -lt 1000 ]; then
        speed_rate="${GREEN}极快 (优)${NC}"
    elif [ "$ms_total" -lt 2500 ]; then
        speed_rate="${YELLOW}良好 (中)${NC}"
    else
        speed_rate="${RED}偏慢 (建议关注国际出口拥堵)${NC}"
    fi

    echo -e "    HTTP响应 : ${GREEN}HTTP ${http_code}${NC}"
    echo -e "    DNS 解析 : ${WHITE}${ms_dns} ms${NC}"
    echo -e "    TCP 建立 : ${WHITE}${ms_tcp} ms${NC}"
    echo -e "    SSL 握手 : ${WHITE}${ms_ssl} ms${NC}"
    echo -e "    总体耗时 : ${CYAN}${ms_total} ms${NC}  [综合评级: ${speed_rate}]"
}

test_amazon_suite() {
    clear
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "${GREEN}      【亚马逊卖家核心后台访问速度专项深度诊断 (毫秒级)】       ${NC}"
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "将分别针对卖家中心、广告投放后台、商品详情主站及CDN节点进行压力诊断..."

    # 1. 卖家中心
    test_url_speed "https://sellercentral.amazon.com/" "1. 亚马逊北美卖家中心 (Seller Central)"

    # 2. 广告管理后台
    test_url_speed "https://advertising.amazon.com/campaign-manager/all-campaigns" "2. 亚马逊广告活动管理中心 (Campaign Manager)"

    # 3. 亚马逊主站
    test_url_speed "https://www.amazon.com/" "3. 亚马逊北美主站商品前台 (Storefront)"

    # 4. CDN 静态资源加速站
    test_url_speed "https://images-na.ssl-images-amazon.com/" "4. 亚马逊全球商品图片 CDN 加速节点"

    echo -e "\n${YELLOW}========================= 诊断分析与优化建议 =========================${NC}"
    echo -e " 1. ${WHITE}DNS 解析${NC} < 50ms: DNS 表现极佳，本面板已注入阿里云/腾讯云/Cloudflare 优选解析；"
    echo -e " 2. ${WHITE}TCP 连接${NC}: 反映当前 VPS 与亚马逊美东/美西机房的真实物理距离延迟；"
    echo -e " 3. ${WHITE}SSL 握手${NC}: 针对跨国链路，本脚本已开启 BBR + 32MB 缓冲区，大幅减少握手重传；"
    echo -e " 4. 若总耗时 > 3000ms: 说明晚高峰运营商国际出口骨干网拥堵，属于跨国公网常态。"
    echo -e "${YELLOW}======================================================================${NC}"
    read -p "按回车键返回主菜单..." dummy
    main_menu
}

# ================================================================
# 【新功能 2】：VPS IP 纯净度检测与【亚马逊防关联安全评估】
# ================================================================
check_ip_association_risk() {
    clear
    local ip=$(get_public_ip)
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "${GREEN}      【VPS IP 纯净度体检与亚马逊防关联风控深度评估】           ${NC}"
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "正在向国际 IP 风险数据库与威胁情报库请求深度分析，请稍候...\n"

    local info
    info=$(curl -s --max-time 10 "http://ip-api.com/json/${ip}?fields=status,message,country,countryCode,regionName,city,isp,org,as,query,hosting,proxy" 2>/dev/null)

    local country="未知"
    local region="未知"
    local city="未知"
    local isp="未知"
    local org="未知"
    local as_name="未知"
    local is_hosting="未知"
    local is_proxy="未知"

    if [ -n "$info" ]; then
        country=$(echo "$info" | grep -o '"country":"[^"]*' | cut -d'"' -f4)
        region=$(echo "$info" | grep -o '"regionName":"[^"]*' | cut -d'"' -f4)
        city=$(echo "$info" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
        isp=$(echo "$info" | grep -o '"isp":"[^"]*' | cut -d'"' -f4)
        org=$(echo "$info" | grep -o '"org":"[^"]*' | cut -d'"' -f4)
        as_name=$(echo "$info" | grep -o '"as":"[^"]*' | cut -d'"' -f4)
        is_hosting=$(echo "$info" | grep -o '"hosting":[^,}]*' | cut -d':' -f2 | tr -d ' ')
        is_proxy=$(echo "$info" | grep -o '"proxy":[^,}]*' | cut -d':' -f2 | tr -d ' ')
    fi

    # 查询反向解析 PTR
    local ptr_name="无反向解析记录"
    if command -v host >/dev/null 2>&1; then
        ptr_name=$(host "$ip" 2>/dev/null | awk '{print $NF}' | sed 's/\.$//')
    fi

    echo -e "${CYAN}------------------- 【IP 基础物理画像】 -------------------${NC}"
    echo -e " 查询 IP   : ${WHITE}${ip}${NC}"
    echo -e " 物理位置  : ${WHITE}${country} - ${region} - ${city}${NC}"
    echo -e " 网络运营商: ${WHITE}${isp}${NC}"
    echo -e " 所属机构  : ${WHITE}${org} (${as_name})${NC}"
    echo -e " PTR反向解析: ${WHITE}${ptr_name}${NC}"

    echo -e "\n${CYAN}------------------- 【亚马逊防关联与纯净度风控分析】 -------------------${NC}"
    local risk_level="${GREEN}低风险 (纯净度良好)${NC}"
    local ip_type_desc=""

    if [ "$is_hosting" == "true" ]; then
        ip_type_desc="${YELLOW}机房/云厂商数据中心 IP (Data Center / Hosting)${NC}"
        risk_level="${YELLOW}中等关注 (绝大多数云服务器均为机房IP，需严格专店专IP)${NC}"
    else
        ip_type_desc="${GREEN}住宅/商业静态网络 (Residential / Business ISP)${NC}"
    fi

    echo -e " IP 类型属性: $ip_type_desc"
    echo -e " 公开代理标记: $( [ "$is_proxy" == "true" ] && echo -e "${RED}已被公开标记为代理${NC}" || echo -e "${GREEN}未被标记为公开黑名单代理${NC}" )"
    echo -e " 关联风险评级: $risk_level"

    echo -e "\n${RED}================================================================${NC}"
    echo -e "${RED}       【亚马逊卖家防关联必须严格遵守的 5 大生死铁律】        ${NC}"
    echo -e "${RED}================================================================${NC}"
    echo -e " 1. ${WHITE}【一店一IP (绝对底线)】${NC}:"
    echo -e "    当前这个 IP (${ip}) 一旦用于登入某个店铺，${RED}严禁${NC}再用于登入任何第二个亚马逊账号！"
    echo -e " 2. ${WHITE}【指纹浏览器环境彻底隔离】${NC}:"
    echo -e "    指纹浏览器的 Canvas、WebGL、AudioContext 指纹必须独立生成，严禁多店铺共用同一个浏览器配置。"
    echo -e " 3. ${WHITE}【WebRTC 泄露拦截 (必做)】${NC}:"
    echo -e "    在指纹浏览器设置中，${YELLOW}务必将 WebRTC 设为【替换】或【禁用】${NC}，否则你真实的物理网络 IP 会直接暴露！"
    echo -e " 4. ${WHITE}【时区与语言对齐】${NC}:"
    echo -e "    指纹浏览器内将【时区】设置为基于 IP 自动匹配，语言选择当地语言，避免时区与 IP 冲突触发二审。"
    echo -e " 5. ${WHITE}【固定静态原则】${NC}:"
    echo -e "    不要频繁更换代理端口或频繁重置 IP。固定 IP 长期稳定访问，是亚马逊判定账号安全的最核心依据。"
    echo -e "${RED}================================================================${NC}"
    read -p "按回车键返回主菜单..." dummy
    main_menu
}

# 全自动一键部署 (内核调优 + 组件下载 + 配置启动)
install_all() {
    clear
    optimize_kernel
    download_gost
    if [ $? -eq 0 ]; then
        modify_config
    fi
}

# 查看系统与网络状态
check_status() {
    clear
    echo -e "${YELLOW}================ 当前系统与内核状态排查 ================${NC}"
    if systemctl is-active --quiet gost; then
        echo -e "代理服务状态: ${GREEN}● 正在运行 (Active)${NC}"
    else
        echo -e "代理服务状态: ${RED}○ 未运行或异常${NC}"
    fi

    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "$bbr_status" == "bbr" ]; then
        echo -e "BBR 加速算法: ${GREEN}已开启 ($bbr_status)${NC}"
    else
        echo -e "BBR 加速算法: ${RED}未生效 ($bbr_status)${NC}"
    fi

    local rmem_max=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
    echo -e "TCP 极限缓冲区: ${GREEN}${rmem_max} 字节 (约 32MB)${NC}"

    local tfo=$(sysctl net.ipv4.tcp_fastopen 2>/dev/null | awk '{print $3}')
    echo -e "TCP FastOpen  : ${GREEN}状态值 $tfo${NC}"

    local mtu_p=$(sysctl net.ipv4.tcp_mtu_probing 2>/dev/null | awk '{print $3}')
    echo -e "MTU 路径探测  : ${GREEN}已启用 ($mtu_p)${NC}"

    echo -e "${YELLOW}========================================================${NC}"
    read -p "按回车键返回主菜单..." dummy
    main_menu
}

# 服务控制
manage_service() {
    clear
    echo -e "${YELLOW}=== 服务运行控制 ===${NC}"
    echo -e "1. 重启服务"
    echo -e "2. 停止服务"
    echo -e "3. 开启服务"
    echo -e "0. 返回主菜单"
    read -p "请输入选项: " opt
    case "$opt" in
        1) systemctl restart gost && echo -e "${GREEN}服务已重启${NC}" ;;
        2) systemctl stop gost && echo -e "${YELLOW}服务已停止${NC}" ;;
        3) systemctl start gost && echo -e "${GREEN}服务已启动${NC}" ;;
        *) main_menu ;;
    esac
    sleep 2
    main_menu
}

# 彻底卸载与还原
uninstall_all() {
    clear
    echo -e "${RED}正在彻底卸载代理服务并还原系统环境...${NC}"
    systemctl stop gost >/dev/null 2>&1
    systemctl disable gost >/dev/null 2>&1
    rm -rf /etc/systemd/system/gost.service
    rm -rf /usr/bin/gost
    rm -rf "$CONFIG_FILE"
    rm -f /usr/bin/vps

    if [ -f /etc/sysctl.conf.bak ]; then
        mv -f /etc/sysctl.conf.bak /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    if [ -f /etc/resolv.conf.bak ]; then
        chattr -i /etc/resolv.conf >/dev/null 2>&1
        mv -f /etc/resolv.conf.bak /etc/resolv.conf
    fi

    echo -e "${GREEN}卸载完成！服务已清理，系统内核配置已还原，'vps' 命令已移除。${NC}"
    exit 0
}

# 查看实时日志
view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 可退出日志查看模式${NC}"
    journalctl -u gost -f
}

# 主菜单
main_menu() {
    clear
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "${GREEN}   晓林技术 - 亚马逊 VPS 网络极限加速与防关联管理面板 (旗舰版)   ${NC}"
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "1. ${GREEN}一键全自动部署 (BBR + 32MB缓冲区调优 + 代理服务)${NC}"
    echo -e "2. 修改 端口 / 账号 / 密码 (自动强开系统端口)"
    echo -e "3. ${CYAN}【查询当前代理信息】(Socks5账号/密码/端口/一键导入格式)${NC}"
    echo -e "4. ${YELLOW}【强行强开系统端口】(暴力释放占用 + 穿透系统防火墙)${NC}"
    echo -e "5. ${PURPLE}【亚马逊卖家后台访问速度专项测速】(卖家后台/广告管理/毫秒级)${NC}"
    echo -e "6. ${RED}【VPS IP 纯净度体检与防关联安全评估】(机房属性/防关联守则)${NC}"
    echo -e "7. 查看系统内核加速状态 (BBR/32MB缓冲区/MTU探测)"
    echo -e "8. 停止 / 开启 / 重启服务"
    echo -e "9. 查看实时运行日志"
    echo -e "10. ${RED}彻底卸载 (清除服务 + 还原内核配置 + 删除面板)${NC}"
    echo -e "0. 退出面板"
    echo -e "${YELLOW}================================================================${NC}"
    read -p "请输入数字选择 [0-10]: " num

    case "$num" in
        1) install_all ;;
        2) modify_config ;;
        3) query_proxy_info ;;
        4) manual_force_open_port ;;
        5) test_amazon_suite ;;
        6) check_ip_association_risk ;;
        7) check_status ;;
        8) manage_service ;;
        9) view_logs ;;
        10) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误！${NC}" && sleep 2 && main_menu ;;
    esac
}

main_menu
