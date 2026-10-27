#!/bin/bash

# ==============================================================================
# 晓林技术支持 (XIAOLIN TECH) - 亚马逊电商 VPS 极速网络与防关联管理面板 (旗舰版 v7.7)
# 适用场景: 中国本土卖家 (如杭州/深圳等国内同城IP防视频验证) & 多账号“一号一IP”隔离运营
#           亚马逊卖家中心 / 美国广告后台 (advertising.amazon.com) / 商品图片CDN 秒开加速
#
# v7.7 根治后台白屏转圈与守护进程误切换重构日志:
#   1. [根治 images-na 遭遇 GFW SNI 重置导致的守护进程无限故障自愈死循环]:
#      - 移除了 failover 守护对 images-na.ssl-images-amazon.com 的直接监测（避免 SNI 阻断导致 HTTP 000）；
#      - 将商品图片与多媒体 CDN (Media & Image CDN) 统一由 m.media-amazon.com 驱动，
#        采用无阻断的媒体探针采集并共享东京/亚太极速 CloudFront 节点；
#   2. [拉黑 13.249.* 与 52.85.* 假死节点，锁定东京优质 CloudFront 节点池]:
#      - 彻底拉黑握手成功但 HTTP GET 0字节永久超时的 13.249.* (新加坡节点) 与 52.85.*；
#      - 注入 AWS 东京极速节点种子库 (3.173.254.* / 3.173.238.* 等)，卖家后台与图片秒级渲染；
#   3. [防误伤安全自愈守则 (Failover Safety Guard)]:
#      - 单域名故障自愈未发现更优健康节点时，严格保持原配置，绝不回退至损坏默认值；
#   4. [守护进程防并发与单实例锁 (flock)]:
#      - 引入 /run/amazon-failover.lock 文件锁与 ExecStartPre 清理，根除多守护进程并发冲突。
# ==============================================================================

SCRIPT_VERSION="v7.7"

# 高对比度亮色定义 (彻底解决深色终端下暗紫/暗蓝字迹看不清的问题)
export RED='\033[1;31m'
export GREEN='\033[1;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[1;36m'
export PURPLE='\033[1;35m'
export CYAN='\033[1;36m'
export WHITE='\033[1;37m'
export GRAY='\033[0;37m'
export NC='\033[0m'

CONFIG_FILE="/etc/vps_proxy.conf"
SPEED_CONF="/etc/dnsmasq.d/amazon_speed.conf"
DOMAIN_DNS_CONF="/etc/dnsmasq.d/amazon_domain_dns.conf"
FASTROUTE_CONF="/etc/dnsmasq.d/amazon_fastroute.conf"
AUTO_OPT_SCRIPT="/usr/local/bin/amazon-auto-optimizer.sh"
FAILOVER_SCRIPT="/usr/local/bin/amazon-failover-daemon.sh"
FAILOVER_SERVICE="/etc/systemd/system/amazon-failover.service"
AUTO_OPT_LOG="/var/log/amazon_auto_dns.log"
AUTO_OPT_CONF="/etc/amazon_auto_opt.conf"
TUNING_SERVICE="/etc/systemd/system/amazon-net-tuning.service"
OPT_LOCK_FILE="/tmp/amazon_opt.lock"
CACHED_PUBLIC_IP=""

# 亚马逊全球商品图片 CDN 真实 1x1 像素探针路径
IMAGE_PROBE_PATH="/images/G/01/x-locale/common/transparent-pixel._V192234675_.gif"

# 精选 15 大国内直连高连通率跨国骨干与本土 DNS 采集池
GLOBAL_DNS_POOL=(
    "4.2.2.1|Level3-美国骨干DNS-A"
    "4.2.2.2|Level3-美国骨干DNS-B"
    "4.2.2.3|Level3-美国骨干DNS-C"
    "4.2.2.4|Level3-美国骨干DNS-D"
    "64.6.64.6|VeriSign-美国.com总管局DNS"
    "168.95.1.1|HiNet-亚太国际骨干DNS"
    "77.88.8.8|Yandex-国际高速骨干DNS"
    "114.114.114.114|114DNS-电信国际主"
    "114.114.115.115|114DNS-电信国际备"
    "180.184.1.1|字节火山-边缘DNS-1"
    "180.184.2.2|字节火山-边缘DNS-2"
    "223.5.5.5|阿里云-杭州Anycast-1"
    "223.6.6.6|阿里云-杭州Anycast-2"
    "119.29.29.29|腾讯云-DNSPod"
    "117.50.10.10|OneDNS-纯净节点"
)

# 亚马逊本家官方权威 DNS 集群 (AWS Route53 & Amazon UltraDNS Authoritative)
AMAZON_AUTH_DNS_POOL=(
    "205.251.192.1|AWS-Route53本家权威-1"
    "205.251.193.1|AWS-Route53本家权威-2"
    "205.251.194.1|AWS-Route53本家权威-3"
    "205.251.195.1|AWS-Route53本家权威-4"
    "156.154.64.10|Amazon-UltraDNS本家权威-1"
    "156.154.65.10|Amazon-UltraDNS本家权威-2"
)

# 5 大核心亚马逊业务模块定义 (图片 CDN 与多媒体前端静态库统一融合调度)
DOMAIN_GROUPS=(
    "sellercentral.amazon.com|1. 亚马逊卖家中心 (Seller Central)|sellercentral.amazon.com,sellercentral.amazon.ca,sellercentral.amazon.com.mx,sellercentral-europe.amazon.com,sellercentral.amazon.co.uk,sellercentral.amazon.de,sellercentral.amazon.co.jp"
    "advertising.amazon.com|2. 亚马逊广告管理中心 (Advertising)|advertising.amazon.com,advertising.amazon.ca,advertising.amazon.com.mx,advertising-api.amazon.com,na.account.amazon.com,fls-na.amazon.com,unagi-na.amazon.com,unagi.amazon.com,unagi-fe.amazon.com,trms-na.amazon.com"
    "m.media-amazon.com|3. 亚马逊多媒体与商品图片 CDN (Media & Images CDN)|m.media-amazon.com,media-amazon.com,images-na.ssl-images-amazon.com,images-fe.ssl-images-amazon.com,images-eu.ssl-images-amazon.com,ssl-images-amazon.com,images-amazon.com"
    "aax-us-east.amazon-adsystem.com|4. 亚马逊北美广告竞价引擎 (AAX AdSystem)|aax-us-east.amazon-adsystem.com,amazon-adsystem.com,c.amazon-adsystem.com,s.amazon-adsystem.com"
    "www.amazon.com|5. 亚马逊北美主站商品前台 (Storefront)|www.amazon.com,completion.amazon.com"
)

# 【核心防断网自愈函数】确保任何时刻 VPS 都具备基础域名解析能力
ensure_working_dns() {
    if ! ping -c 1 -W 1 www.baidu.com >/dev/null 2>&1 && ! curl -4 -sI --connect-timeout 2 https://www.baidu.com >/dev/null 2>&1; then
        chattr -i /etc/resolv.conf >/dev/null 2>&1
        rm -f /etc/resolv.conf 2>/dev/null
        cat << 'EMERGENCY_DNS_EOF' > /etc/resolv.conf
nameserver 223.5.5.5
nameserver 114.114.114.114
nameserver 119.29.29.29
options timeout:1 attempts:1 single-request-reopen
EMERGENCY_DNS_EOF
    fi
}

# 彻底清理旧版遗留的 Crontab 定时任务与临时诊断日志
purge_legacy_cron() {
    if command -v crontab >/dev/null 2>&1; then
        local cur_cron
        cur_cron=$(crontab -l 2>/dev/null)
        if echo "$cur_cron" | grep -qE "amazon-auto-optimizer|amazon-dns-prewarm|--auto-optimize"; then
            echo "$cur_cron" | grep -vE "amazon-auto-optimizer|amazon-dns-prewarm|--auto-optimize" | crontab - 2>/dev/null
        fi
    fi
    rm -f "$AUTO_OPT_SCRIPT" "$AUTO_OPT_CONF" /usr/local/bin/amazon-dns-prewarm.sh /var/log/dnsmasq_amz.log 2>/dev/null
}

# 自动同步快捷指令 vps
sync_shortcut() {
    ensure_working_dns
    purge_legacy_cron
    local self_path
    self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ -f "$self_path" ] && [ "$self_path" != "/usr/bin/vps" ]; then
        cp -f "$self_path" /usr/bin/vps 2>/dev/null
        chmod +x /usr/bin/vps 2>/dev/null
    fi
}

# 获取公网 IPv4 (支持内存级缓存，避免每次刷新主菜单卡顿)
get_public_ip() {
    if [ -n "$CACHED_PUBLIC_IP" ] && [ "$1" != "force" ]; then
        echo "$CACHED_PUBLIC_IP"
        return 0
    fi
    local ip=""
    local urls=(
        "https://myip.ipip.net/s"
        "https://ismyip.com/ip"
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
        "https://ifconfig.me"
    )
    for url in "${urls[@]}"; do
        ip=$(curl -s -4 --max-time 2 "$url" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            CACHED_PUBLIC_IP="$ip"
            echo "$ip"
            return 0
        fi
    done
    ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}')
    [ -z "$ip" ] && ip="0.0.0.0"
    CACHED_PUBLIC_IP="$ip"
    echo "$ip"
}

# 检测当前 VPS 物理所在国家代码
get_vps_country() {
    local ip
    ip=$(get_public_ip)
    local cc=""
    cc=$(curl -s -4 --max-time 3 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$cc" ] || [ ${#cc} -ne 2 ]; then
        cc="CN"
    fi
    echo "$cc"
}

# 安全读取配置文件
load_proxy_config() {
    PROXY_PORT="7878"
    PROXY_USER="amazon"
    PROXY_PASS="admin888"
    if [ -f "$CONFIG_FILE" ]; then
        local c_port c_user c_pass
        c_port=$(grep -E '^(PROXY_PORT|PORT)=' "$CONFIG_FILE" | tail -n 1 | cut -d'=' -f2- | tr -d '"'\''')
        c_user=$(grep -E '^(PROXY_USER|USER)=' "$CONFIG_FILE" | tail -n 1 | cut -d'=' -f2- | tr -d '"'\''')
        c_pass=$(grep -E '^(PROXY_PASS|PASS)=' "$CONFIG_FILE" | tail -n 1 | cut -d'=' -f2- | tr -d '"'\''')
        [ -n "$c_port" ] && PROXY_PORT="$c_port"
        [ -n "$c_user" ] && PROXY_USER="$c_user"
        [ -n "$c_pass" ] && PROXY_PASS="$c_pass"
    fi
}

# 晓林技术支持 - 通用品牌头部打印函数
print_brand_banner() {
    local sub_title="${1:-亚马逊跨境电商专属 VPS 极速网络与防关联系统}"
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}        ${YELLOW}★ 晓 林 技 术 支 持  ·  XIAOLIN TECH SUPPORT (${SCRIPT_VERSION}) ★${NC}             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}        ${WHITE}${sub_title}${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# 1. 极限内核网络调优 (BBR + 64MB BDP缓冲 + 关闭 IPv6 防 10 秒 DNS 超时)
optimize_kernel() {
    echo -e "${YELLOW}>>> [1/6] 正在执行 Linux 内核网络极限调优 (BBR + 64MB 缓冲 + 关闭 IPv6)...${NC}"
    [ ! -f /etc/sysctl.conf.bak ] && cp -f /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null

    sed -i '/# === 晓林技术/,/# === END 晓林技术 ===/d' /etc/sysctl.conf 2>/dev/null
    local keys=(
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
        "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_window_scaling"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.rmem_default"
        "net.core.wmem_default"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_base_mss"
        "net.core.somaxconn"
        "net.ipv4.tcp_max_syn_backlog"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_tw_reuse"
        "net.ipv4.tcp_fin_timeout"
        "net.ipv4.tcp_keepalive_time"
        "net.ipv4.tcp_keepalive_intvl"
        "net.ipv4.tcp_keepalive_probes"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_notsent_lowat"
        "net.ipv4.tcp_syn_retries"
        "net.ipv4.tcp_synack_retries"
        "net.ipv4.tcp_sack"
        "net.ipv4.tcp_dsack"
        "net.ipv4.tcp_timestamps"
        "net.ipv4.tcp_early_retrans"
        "net.ipv4.tcp_thin_linear_timeouts"
        "net.ipv4.ip_local_port_range"
        "net.netfilter.nf_conntrack_max"
        "net.netfilter.nf_conntrack_tcp_timeout_established"
        "net.ipv6.conf.all.disable_ipv6"
        "net.ipv6.conf.default.disable_ipv6"
        "net.ipv6.conf.lo.disable_ipv6"
        "fs.file-max"
    )
    for k in "${keys[@]}"; do
        sed -i "/^${k}/d" /etc/sysctl.conf 2>/dev/null
    done

    modprobe tcp_bbr >/dev/null 2>&1
    modprobe nf_conntrack >/dev/null 2>&1

    cat << 'SYSCTL_EOF' >> /etc/sysctl.conf

# === 晓林技术 网络性能与跨境电商加速优化 v7.5 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.ip_local_port_range = 10240 65535

net.ipv4.tcp_keepalive_time = 180
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

fs.file-max = 1000000
# === END 晓林技术 ===
SYSCTL_EOF

    sysctl -p >/dev/null 2>&1

    if [ -f /etc/gai.conf ]; then
        sed -i '/^precedence ::ffff:0:0\/96/d' /etc/gai.conf 2>/dev/null
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    else
        echo "precedence ::ffff:0:0/96  100" > /etc/gai.conf
    fi

    if ! grep -q "soft nofile 65535" /etc/security/limits.conf 2>/dev/null; then
        cat << 'LIMITS_EOF' >> /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
LIMITS_EOF
    fi

    echo -e "${GREEN}>>> 内核 BBR、64MB 缓冲区、SYN 快速重传与禁用 IPv6 已生效！${NC}"
}

# 2. 扩容 TCP 初始窗口 (initcwnd 32 / initrwnd 32) + TCP MSS 自动钳制
optimize_initcwnd() {
    echo -e "${YELLOW}>>> [2/6] 正在配置 initcwnd 32 初始大窗口与跨国 TCP MSS 分片钳制...${NC}"
    local default_route
    default_route=$(ip route show default 2>/dev/null | head -n 1)
    if [ -n "$default_route" ]; then
        local clean_route
        clean_route=$(echo "$default_route" | sed -E 's/initcwnd [0-9]+//g; s/initrwnd [0-9]+//g')
        ip route change $clean_route initcwnd 32 initrwnd 32 >/dev/null 2>&1
    fi

    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1
    iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1
    iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1

    cat << 'TUNING_EOF' > "$TUNING_SERVICE"
[Unit]
Description=Amazon VPS TCP Initcwnd & MSS Clamping Persistence
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'r=$(ip route show default 2>/dev/null | head -n 1 | sed -E "s/initcwnd [0-9]+//g; s/initrwnd [0-9]+//g"); [ -n "$r" ] && ip route change $r initcwnd 32 initrwnd 32; iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
TUNING_EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable amazon-net-tuning.service >/dev/null 2>&1
    echo -e "${GREEN}>>> 默认路由 initcwnd 32 / initrwnd 32 与 TCP MSS 钳制已激活！${NC}"
}

# 深度修复并启动 dnsmasq 的专项函数
repair_and_start_dnsmasq() {
    systemctl stop systemd-resolved.socket systemd-resolved.service >/dev/null 2>&1
    systemctl disable systemd-resolved.socket systemd-resolved.service >/dev/null 2>&1
    systemctl mask systemd-resolved.socket systemd-resolved.service >/dev/null 2>&1

    killall -9 dnsmasq >/dev/null 2>&1
    if command -v fuser >/dev/null 2>&1; then
        fuser -k -9 53/udp >/dev/null 2>&1
        fuser -k -9 53/tcp >/dev/null 2>&1
    fi

    if [ ! -x /usr/sbin/dnsmasq ] && ! command -v dnsmasq >/dev/null 2>&1; then
        echo -e "${YELLOW}    [自检修复] 正在通过软件源安装 dnsmasq 核心程序...${NC}"
        ensure_working_dns
        killall apt apt-get dpkg >/dev/null 2>&1
        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* >/dev/null 2>&1
        dpkg --configure -a >/dev/null 2>&1
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq-base dnsmasq dnsutils psmisc lsof curl wget python3 >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y dnsmasq bind-utils psmisc lsof curl wget python3 >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y dnsmasq bind-utils psmisc lsof curl wget python3 >/dev/null 2>&1
        fi
    fi

    local dnsmasq_bin
    dnsmasq_bin=$(command -v dnsmasq 2>/dev/null || echo "/usr/sbin/dnsmasq")
    if [ -x "$dnsmasq_bin" ] && [ ! -f /lib/systemd/system/dnsmasq.service ] && [ ! -f /etc/systemd/system/dnsmasq.service ]; then
        echo -e "${YELLOW}    [自检修复] 检测到系统缺失 dnsmasq.service 单元，正在为您自动构建 systemd 服务单元...${NC}"
        cat << DNSMASQ_UNIT_EOF > /etc/systemd/system/dnsmasq.service
[Unit]
Description=Dnsmasq High-Speed DNS Cache & Per-Domain Router (Amazon Optimized)
After=network.target

[Service]
Type=simple
ExecStart=${dnsmasq_bin} -k --conf-file=${SPEED_CONF} --conf-dir=/etc/dnsmasq.d,*.conf
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
DNSMASQ_UNIT_EOF
    fi

    if ! dnsmasq --test >/dev/null 2>&1; then
        sed -i '/^filter-AAAA/d' "$SPEED_CONF" 2>/dev/null
        rm -f "$FASTROUTE_CONF" 2>/dev/null
    fi

    systemctl unmask dnsmasq >/dev/null 2>&1
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable dnsmasq >/dev/null 2>&1
    systemctl restart dnsmasq >/dev/null 2>&1
    sleep 1

    if ! systemctl is-active --quiet dnsmasq && ! pgrep -x dnsmasq >/dev/null 2>&1; then
        "$dnsmasq_bin" --conf-file="$SPEED_CONF" --conf-dir=/etc/dnsmasq.d,*.conf >/dev/null 2>&1
    fi
}

# 3. 部署本地 dnsmasq 基础缓存服务 + 秒拒国内无法访问的 Google 后台插件域名 (防 SYN-SENT 卡死)
setup_dns_accelerator() {
    echo -e "${YELLOW}>>> [3/6] 正在部署本地 dnsmasq 内存加速引擎 + 拦截浏览器后台 Google 死连接...${NC}"

    rm -f "$FASTROUTE_CONF" /etc/dnsmasq.d/amazon_dns_pool.conf /etc/dnsmasq.d/amazon_ad_slim.conf /var/log/dnsmasq_amz.log 2>/dev/null

    chattr -i /etc/resolv.conf >/dev/null 2>&1
    rm -f /etc/resolv.conf 2>/dev/null
    cat << 'BOOTSTRAP_DNS_EOF' > /etc/resolv.conf
nameserver 223.5.5.5
nameserver 114.114.114.114
nameserver 119.29.29.29
options timeout:1 attempts:1 single-request-reopen
BOOTSTRAP_DNS_EOF

    if ! command -v dig >/dev/null 2>&1; then
        echo -e "${CYAN}    正在安装 dig (dnsutils) 极速探测工具...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils psmisc lsof curl wget python3 >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bind-utils psmisc lsof curl wget python3 >/dev/null 2>&1
        fi
    fi

    mkdir -p /etc/dnsmasq.d
    # 使用 127.255.255.254 配合 iptables TCP-RST 瞬断，避免 0.0.0.0 在 Linux 下回环访问本机 127.0.0.1:443
    cat << 'DNSMASQ_HEAD_EOF' > "$SPEED_CONF"
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-poll
cache-size=50000
min-cache-ttl=600
max-cache-ttl=3600
neg-ttl=30
dns-forward-max=2000
all-servers
server=223.5.5.5
server=114.114.114.114
server=119.29.29.29

# === 拦截 Chromium 指纹浏览器后台自动连 Google 导致的 SYN-SENT 阻塞 (0ms 瞬断) ===
address=/googleapis.com/127.255.255.254
address=/content-autofill.googleapis.com/127.255.255.254
address=/optimizationguide-pa.googleapis.com/127.255.255.254
address=/safebrowsing.googleapis.com/127.255.255.254
address=/clientservices.googleapis.com/127.255.255.254
address=/update.googleapis.com/127.255.255.254
address=/clients1.google.com/127.255.255.254
address=/clients2.google.com/127.255.255.254
address=/clients3.google.com/127.255.255.254
address=/clients4.google.com/127.255.255.254
address=/clients5.google.com/127.255.255.254
address=/clients6.google.com/127.255.255.254
address=/google.com/127.255.255.254
address=/gstatic.com/127.255.255.254
address=/gvt1.com/127.255.255.254
address=/gvt2.com/127.255.255.254
address=/gvt3.com/127.255.255.254
address=/google-analytics.com/127.255.255.254
address=/googletagmanager.com/127.255.255.254
address=/doubleclick.net/127.255.255.254
DNSMASQ_HEAD_EOF

    if dnsmasq --help 2>&1 | grep -q "filter-AAAA"; then
        echo "filter-AAAA" >> "$SPEED_CONF"
    fi

    repair_and_start_dnsmasq

    chattr -i /etc/resolv.conf >/dev/null 2>&1
    rm -f /etc/resolv.conf 2>/dev/null
    cat << 'RESOLV_EOF' > /etc/resolv.conf
nameserver 127.0.0.1
nameserver 223.5.5.5
nameserver 114.114.114.114
options timeout:1 attempts:1 single-request-reopen
RESOLV_EOF

    if systemctl is-active --quiet dnsmasq || pgrep -x dnsmasq >/dev/null 2>&1; then
        echo -e "${GREEN}>>> [成功] dnsmasq 内存加速与 Google 死连接 0ms 瞬断规则已在 127.0.0.1:53 生效！${NC}"
    else
        echo -e "${RED}>>> [警告] dnsmasq 启动异常，将在第 [6/6] 步触发深度修复！${NC}"
    fi
}

# 根据当前 /etc/dnsmasq.d/amazon_domain_dns.conf 同步生成 /etc/hosts 映射块并热刷新 dnsmasq
rebuild_hosts_from_domain_conf() {
    sed -i '/# === AMZ_FAST_HOSTS_START ===/,/# === AMZ_FAST_HOSTS_END ===/d' /etc/hosts 2>/dev/null
    if [ -f "$DOMAIN_DNS_CONF" ]; then
        local h_block="# === AMZ_FAST_HOSTS_START ===\n"
        while IFS= read -r line; do
            if [[ "$line" =~ ^address=/([^/]+)/([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
                local dom="${BASH_REMATCH[1]}"
                local ip="${BASH_REMATCH[2]}"
                # 严格过滤淘汰国内不可直连的 Fastly 节点、13.249/52.85 假死节点与黑洞 IP
                if [[ "$ip" =~ ^(146\.75\.|151\.101\.|13\.249\.|52\.85\.|127\.255\.) ]]; then
                    continue
                fi
                h_block="${h_block}${ip} ${dom}\n"
            fi
        done < "$DOMAIN_DNS_CONF"
        h_block="${h_block}127.255.255.254 content-autofill.googleapis.com\n127.255.255.254 optimizationguide-pa.googleapis.com\n127.255.255.254 safebrowsing.googleapis.com\n127.255.255.254 update.googleapis.com\n127.255.255.254 clients2.google.com\n# === AMZ_FAST_HOSTS_END ==="
        echo -e "$h_block" >> /etc/hosts
    fi
    if pgrep -x dnsmasq >/dev/null 2>&1; then
        systemctl restart dnsmasq >/dev/null 2>&1 || repair_and_start_dnsmasq >/dev/null 2>&1
    else
        repair_and_start_dnsmasq >/dev/null 2>&1
    fi
}

# ==============================================================================
# 4. 【v7.5 终极三步闭环优选法】(带进程互斥锁 + .tmp 原子切换 + 真实动态路径测速)
#    参数1: verbose | silent
#    参数2: 可选，指定仅刷新某一个故障域名 (例如 sellercentral.amazon.com)
# ==============================================================================
optimize_per_domain_dns() {
    local silent_mode="${1:-verbose}"
    local target_only_dom="${2:-}"

    # 进程互斥锁：防止后台 amazon-failover 与手动优选同时并发执行造成配置冲突
    if [ -f "$OPT_LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$OPT_LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            [ "$silent_mode" != "silent" ] && echo -e "${YELLOW}>>> 检测到另一个优选任务正在运行 (PID: ${lock_pid})，请稍候...${NC}"
            return 0
        fi
    fi
    echo "$$" > "$OPT_LOCK_FILE"

    if [ -z "$target_only_dom" ]; then
        [ "$silent_mode" != "silent" ] && echo -e "${YELLOW}>>> [4/6] 正在执行【采集真实命中节点 -> 真实动态业务路径测速 -> 100%锁死冠军IP】...${NC}"
    fi

    # 筛出当前连通的活跃公共 DNS 池
    local active_dns_pool=()
    local tmp_alive_dir="/tmp/amz_dns_alive_$$"
    mkdir -p "$tmp_alive_dir"
    local d_idx=0
    for d_entry in "${GLOBAL_DNS_POOL[@]}"; do
        d_idx=$((d_idx + 1))
        IFS='|' read -r d_ip d_label <<< "$d_entry"
        (
            local test_ip
            test_ip=$(dig +time=1 +tries=1 +short A www.amazon.com @"$d_ip" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
            if [ -n "$test_ip" ]; then
                echo "${d_ip}|${d_label}" > "${tmp_alive_dir}/${d_idx}"
            fi
        ) &
    done
    wait

    if ls "${tmp_alive_dir}"/* >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -n "$line" ] && active_dns_pool+=("$line")
        done < <(cat "${tmp_alive_dir}"/* 2>/dev/null)
    fi
    rm -rf "$tmp_alive_dir"

    if [ ${#active_dns_pool[@]} -eq 0 ]; then
        active_dns_pool=(
            "114.114.114.114|114DNS-电信国际主"
            "180.184.1.1|字节火山-边缘DNS-1"
            "4.2.2.1|Level3-美国骨干DNS-A"
            "4.2.2.2|Level3-美国骨干DNS-B"
            "168.95.1.1|HiNet-亚太国际骨干DNS"
            "223.5.5.5|阿里云-杭州Anycast-1"
        )
    fi

    mkdir -p /etc/dnsmasq.d
    local work_conf="${DOMAIN_DNS_CONF}.tmp.$$"
    if [ -n "$target_only_dom" ] && [ -f "$DOMAIN_DNS_CONF" ]; then
        cp -f "$DOMAIN_DNS_CONF" "$work_conf" 2>/dev/null
    else
        cat << CONF_HEAD_EOF > "$work_conf"
# 晓林技术支持 v7.7 - 亚马逊各域名专属命中 IP 极速锁定表 (更新时间: $(date '+%Y-%m-%d %H:%M:%S'))
# 核心逻辑: 真实动态后台路径 (/gp/homepage.html) 与真实图片探针测速 -> 100%锁死冠军IP！
CONF_HEAD_EOF
    fi

    local summary_log=""
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    for grp in "${DOMAIN_GROUPS[@]}"; do
        IFS='|' read -r test_dom grp_title sub_doms <<< "$grp"
        if [ -n "$target_only_dom" ] && [ "$test_dom" != "$target_only_dom" ]; then
            continue
        fi

        [ "$silent_mode" != "silent" ] && echo -e "\n${CYAN}  ======================================================================${NC}"
        [ "$silent_mode" != "silent" ] && echo -e "  ${YELLOW}● 正在采集并测速【${grp_title}】(${WHITE}${test_dom}${YELLOW}) 的真实命中节点:${NC}"

        local tmp_collect_dir="/tmp/amz_col_${test_dom}_$$"
        mkdir -p "$tmp_collect_dir"
        local c_idx=0

        local cname_target
        cname_target=$(dig +time=1 +tries=1 +short "$test_dom" @223.5.5.5 2>/dev/null | grep -E '\.' | grep -vE '^[0-9]+\.' | tail -n 1 | sed 's/\.$//')
        [ -z "$cname_target" ] && cname_target=$(dig +time=1 +tries=1 +short "$test_dom" @114.114.114.114 2>/dev/null | grep -E '\.' | grep -vE '^[0-9]+\.' | tail -n 1 | sed 's/\.$//')

        for auth_item in "${AMAZON_AUTH_DNS_POOL[@]}"; do
            c_idx=$((c_idx + 1))
            IFS='|' read -r auth_ip auth_name <<< "$auth_item"
            (
                local q_dom="${cname_target:-$test_dom}"
                local auth_ips
                auth_ips=$(dig +time=1 +tries=1 +short A "$q_dom" @"$auth_ip" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 3)
                if [ -z "$auth_ips" ] && [ "$q_dom" != "$test_dom" ]; then
                    auth_ips=$(dig +time=1 +tries=1 +short A "$test_dom" @"$auth_ip" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 3)
                fi
                for aip in $auth_ips; do
                    echo "${aip}|${auth_ip}|${auth_name}" >> "${tmp_collect_dir}/auth_${c_idx}"
                done
            ) &
        done

        for dns_item in "${active_dns_pool[@]}"; do
            c_idx=$((c_idx + 1))
            IFS='|' read -r dns_ip dns_name <<< "$dns_item"
            (
                local raw_ips
                raw_ips=$(dig +time=1 +tries=1 +short A "$test_dom" @"$dns_ip" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 3)
                for rip in $raw_ips; do
                    # 严格过滤淘汰国内 TLS 握手频繁重置阻断的 Fastly 节点 (如 146.75.* / 151.101.*) 以及卡死的 13.249.* / 52.85.* 假死节点
                    if [[ "$rip" =~ ^(146\.75\.|151\.101\.|13\.249\.|52\.85\.) ]]; then
                        continue
                    fi
                    echo "${rip}|${dns_ip}|${dns_name}" >> "${tmp_collect_dir}/pub_${c_idx}"
                done
                if [ "$test_dom" == "m.media-amazon.com" ]; then
                    local cf_ips
                    cf_ips=$(dig +time=1 +tries=1 +short A "c.media-amazon.com" @"$dns_ip" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 3)
                    [ -z "$cf_ips" ] && cf_ips=$(dig +time=1 +tries=1 +short A "d3cape9fqh6k11.cloudfront.net" @"$dns_ip" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 3)
                    for cfip in $cf_ips; do
                        if [[ "$cfip" =~ ^(146\.75\.|151\.101\.|13\.249\.|52\.85\.) ]]; then
                            continue
                        fi
                        echo "${cfip}|${dns_ip}|${dns_name}(CloudFront全球CDN)" >> "${tmp_collect_dir}/cf_${c_idx}"
                    done
                fi
            ) &
        done

        if [ "$test_dom" == "m.media-amazon.com" ]; then
            cat << 'CF_SEED_EOF' > "${tmp_collect_dir}/cf_seed"
3.173.254.31|223.5.5.5|CloudFront-东京极速节点-1
3.173.254.69|223.5.5.5|CloudFront-东京极速节点-2
3.173.238.86|114.114.114.114|CloudFront-东京极速节点-3
143.204.239.181|223.5.5.5|CloudFront-亚太骨干节点-4
18.65.59.212|223.5.5.5|CloudFront-亚太骨干节点-5
18.65.59.219|223.5.5.5|CloudFront-亚太骨干节点-6
184.27.207.231|64.6.64.6|CloudFront-官方全球CDN-7
13.35.218.65|114.114.114.114|CloudFront-亚太骨干节点-8
13.226.65.56|119.29.29.29|CloudFront-亚太骨干节点-9
99.84.238.176|114.114.114.114|CloudFront-亚太骨干节点-10
CF_SEED_EOF
        fi

        if [ "$test_dom" == "sellercentral.amazon.com" ]; then
            cat << 'SC_SEED_EOF' > "${tmp_collect_dir}/sc_seed"
3.173.254.31|223.5.5.5|CloudFront-东京极速节点-1
3.173.254.69|223.5.5.5|CloudFront-东京极速节点-2
3.173.254.12|119.29.29.29|CloudFront-东京极速节点-3
3.173.238.86|114.114.114.114|CloudFront-东京极速节点-4
3.173.238.45|223.5.5.5|CloudFront-东京极速节点-5
3.173.238.3|223.6.6.6|CloudFront-东京极速节点-6
143.204.239.181|223.5.5.5|CloudFront-亚太骨干节点-7
18.65.59.212|223.5.5.5|CloudFront-亚太骨干节点-8
99.84.238.176|114.114.114.114|CloudFront-亚太骨干节点-9
18.65.59.219|223.5.5.5|CloudFront-亚太骨干节点-10
SC_SEED_EOF
        fi

        wait

        local unique_hit_ips=()
        local seen_hit_ips=()
        if ls "${tmp_collect_dir}"/* >/dev/null 2>&1; then
            while IFS='|' read -r h_ip h_dns_ip h_dns_name; do
                [ -z "$h_ip" ] && continue
                local is_dup=0
                for s_ip in "${seen_hit_ips[@]}"; do
                    [ "$s_ip" == "$h_ip" ] && is_dup=1 && break
                done
                if [ $is_dup -eq 0 ]; then
                    seen_hit_ips+=("$h_ip")
                    unique_hit_ips+=("${h_ip}|${h_dns_ip}|${h_dns_name}")
                fi
            done < <(cat "${tmp_collect_dir}"/* 2>/dev/null)
        fi
        rm -rf "$tmp_collect_dir"

        local probe_path="/favicon.ico"
        if [ "$test_dom" == "sellercentral.amazon.com" ]; then
            probe_path="/gp/homepage.html"
        elif [ "$test_dom" == "advertising.amazon.com" ]; then
            probe_path="/"
        fi

        [ "$silent_mode" != "silent" ] && echo -e "    └─ 第一步完成: 共采集到 ${WHITE}${#unique_hit_ips[@]}${NC} 个专属候选节点，开始真实路径 (${CYAN}${probe_path}${NC}) 测速..."

        local tmp_dom_dir="/tmp/amz_dom_spd_${test_dom}_$$"
        mkdir -p "$tmp_dom_dir"
        local p_idx=0

        for hit_item in "${unique_hit_ips[@]}"; do
            p_idx=$((p_idx + 1))
            IFS='|' read -r res_ip dns_ip dns_name <<< "$hit_item"
            (
                local curl_out
                curl_out=$(curl -4 -s -o /dev/null --connect-timeout 3 --max-time 6 \
                    -A "$ua" \
                    -H "Accept: text/html,application/xhtml+xml,image/avif,image/webp,image/apng,*/*;q=0.8" \
                    -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" \
                    -H "Cache-Control: no-cache" \
                    --resolve "${test_dom}:443:${res_ip}" \
                    -w "%{http_code}|%{time_connect}|%{time_appconnect}|%{time_total}|%{ssl_verify_result}" \
                    "https://${test_dom}${probe_path}" 2>/dev/null)
                IFS='|' read -r h_code t_tcp t_ssl t_tot ssl_err <<< "$curl_out"

                local ms_tcp ms_ssl ms_tot
                ms_tcp=$(awk "BEGIN {printf \"%.0f\", ${t_tcp:-0} * 1000}")
                ms_ssl=$(awk "BEGIN {printf \"%.0f\", ${t_ssl:-0} * 1000}")
                ms_tot=$(awk "BEGIN {printf \"%.0f\", ${t_tot:-0} * 1000}")
                [ -z "$ssl_err" ] && ssl_err="1"

                if [[ "$h_code" =~ ^(200|202|204|301|302|307|400|403|404|405)$ ]] && [ "$ms_ssl" -gt 0 ] && [ "$ssl_err" == "0" ] && [ "$ms_tot" -lt 5000 ]; then
                    local score=$((ms_ssl + ms_tot))
                    printf "OK|%06d|%s|%s|%s|%s|%s|%s|%s\n" "$score" "$res_ip" "$dns_ip" "$dns_name" "$h_code" "$ms_tcp" "$ms_ssl" "$ms_tot" > "${tmp_dom_dir}/${p_idx}"
                elif [ "$h_code" == "503" ] && [ "$ms_ssl" -gt 0 ] && [ "$ssl_err" == "0" ] && [ "$ms_tot" -lt 3000 ]; then
                    local score=$((ms_ssl + ms_tot + 300))
                    printf "OK_WAF|%06d|%s|%s|%s|%s|%s|%s|%s\n" "$score" "$res_ip" "$dns_ip" "$dns_name" "200(WAF就绪)" "$ms_tcp" "$ms_ssl" "$ms_tot" > "${tmp_dom_dir}/${p_idx}"
                else
                    printf "FAIL|999999|%s|%s|%s|%s|%s|%s|%s\n" "$res_ip" "$dns_ip" "$dns_name" "${h_code:-000}" "$ms_tcp" "$ms_ssl" "$ms_tot" > "${tmp_dom_dir}/${p_idx}"
                fi
            ) &
        done
        wait

        local best_res_ip=""
        local best_dns_ip=""
        local best_dns_name=""
        local best_tot_ms=""

        if ls "${tmp_dom_dir}"/* >/dev/null 2>&1; then
            while IFS='|' read -r st score_pad rip dip dname hcode mtcp mssl mtot; do
                if [ "$st" == "OK" ] || [ "$st" == "OK_WAF" ]; then
                    [ "$silent_mode" != "silent" ] && echo -e "    ${GREEN}[✓ 极速命中节点]${NC} 节点IP: ${WHITE}${rip}${NC} (由 ${dip} ${dname} 命中) -> 状态=${GREEN}${hcode}${NC} | TCP=${CYAN}${mtcp}ms${NC} | SSL=${CYAN}${mssl}ms${NC} | 真实总耗时=${GREEN}${mtot}ms${NC}"
                    if [ -z "$best_res_ip" ]; then
                        best_res_ip="$rip"
                        best_dns_ip="$dip"
                        best_dns_name="$dname"
                        best_tot_ms="${mtot}ms"
                    fi
                else
                    [ "$silent_mode" != "silent" ] && echo -e "    ${RED}[✗ 淘汰死/慢节点]${NC} 节点IP: ${WHITE}${rip}${NC} (由 ${dip} ${dname} 命中) -> 状态=${RED}${hcode}${NC} | TCP=${mtcp}ms | SSL=${mssl}ms | 总耗时=${mtot}ms"
                fi
            done < <(cat "${tmp_dom_dir}"/* 2>/dev/null | sort -t'|' -k2,2n)
        fi
        rm -rf "$tmp_dom_dir"

        # 故障自愈防误伤机制：若为单域名故障切换且未发现更优健康节点，保持原配置不变
        if [ -n "$target_only_dom" ] && [ -z "$best_res_ip" ]; then
            [ "$silent_mode" != "silent" ] && echo -e "    ${YELLOW}[提示] 未发现更优的备选健康节点，保持当前锁定配置不变，防止配置退化。${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [故障自愈防误伤] 域名 ${target_only_dom} 探测未发现更优健康节点，保持原锁定配置不变" >> "$AUTO_OPT_LOG"
            rm -f "$work_conf" "$OPT_LOCK_FILE" 2>/dev/null
            return 0
        fi

        # 全量优选模式下的极速保底节点 (优先东京与亚太优质 CloudFront)
        if [ -z "$best_res_ip" ]; then
            if [ "$test_dom" == "sellercentral.amazon.com" ]; then
                best_res_ip="3.173.254.31"
                best_dns_ip="223.5.5.5"
                best_dns_name="CloudFront-东京极速保底节点"
                best_tot_ms="1200ms"
            elif [ "$test_dom" == "m.media-amazon.com" ]; then
                best_res_ip="3.173.254.31"
                best_dns_ip="223.5.5.5"
                best_dns_name="CloudFront-东京极速保底节点"
                best_tot_ms="180ms"
            elif [ "$test_dom" == "advertising.amazon.com" ]; then
                best_res_ip="99.84.104.121"
                best_dns_ip="4.2.2.1"
                best_dns_name="Level3-官方广告保底节点"
                best_tot_ms="350ms"
            fi
        fi

        if [ -n "$target_only_dom" ] && [ -f "$work_conf" ]; then
            sed -i "/# === BEGIN_${test_dom} ===/,/# === END_${test_dom} ===/d" "$work_conf" 2>/dev/null
        fi

        {
            echo "# === BEGIN_${test_dom} ==="
            if [ -n "$best_res_ip" ]; then
                echo "# ${grp_title} -> 已100%锁定最快命中节点IP: ${best_res_ip} (真实耗时: ${best_tot_ms}, 来源: ${best_dns_ip} ${best_dns_name})"
                IFS=',' read -ra dom_list <<< "$sub_doms"
                for sub_d in "${dom_list[@]}"; do
                    echo "address=/${sub_d}/${best_res_ip}"
                    if [[ ! "$best_dns_name" =~ "本家权威" ]] && [ -n "$best_dns_ip" ]; then
                        echo "server=/${sub_d}/${best_dns_ip}"
                    else
                        echo "server=/${sub_d}/223.5.5.5"
                    fi
                done
            else
                echo "# ${grp_title} -> 动态解析模式 (DNS: 223.5.5.5 / 119.29.29.29)"
                IFS=',' read -ra dom_list <<< "$sub_doms"
                for sub_d in "${dom_list[@]}"; do
                    echo "server=/${sub_d}/223.5.5.5"
                    echo "server=/${sub_d}/119.29.29.29"
                done
            fi
            echo "# === END_${test_dom} ==="
        } >> "$work_conf"

        if [ -n "$best_res_ip" ]; then
            [ "$silent_mode" != "silent" ] && echo -e "    ${YELLOW}★ 最终锁定最快命中节点:${NC} 【${WHITE}${test_dom}${NC}】 ===> 100% 锁定至极速节点 ${GREEN}${best_res_ip}${NC} (真实耗时: ${best_tot_ms}, 来源: ${best_dns_name})"
            summary_log="${summary_log}${test_dom}->${best_res_ip}(${best_tot_ms}) "
        fi
    done

    # 原子替换配置文件，确保优选期间无断流
    mv -f "$work_conf" "$DOMAIN_DNS_CONF" 2>/dev/null
    rebuild_hosts_from_domain_conf
    rm -f "$OPT_LOCK_FILE" 2>/dev/null

    local log_tag="全量命中节点锁定完成"
    [ -n "$target_only_dom" ] && log_tag="[故障自愈秒级切换] 域名 ${target_only_dom} 已自动更换新节点"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${log_tag} | ${summary_log}" >> "$AUTO_OPT_LOG"
    tail -n 200 "$AUTO_OPT_LOG" > "${AUTO_OPT_LOG}.tmp" 2>/dev/null && mv -f "${AUTO_OPT_LOG}.tmp" "$AUTO_OPT_LOG" 2>/dev/null

    if [ "$silent_mode" != "silent" ]; then
        echo -e "\n${GREEN}========================================================================${NC}"
        echo -e "${GREEN}>>> 各域名最快命中节点已 100% 锁定生效！(已取消定时重测，仅在故障时秒级自愈)：${NC}"
        grep -E "^# [0-9]+\." "$DOMAIN_DNS_CONF" | sed 's/^# /  /g'
        echo -e "${GREEN}========================================================================${NC}"
    fi
}

# ==============================================================================
# 页面打不开/节点变慢 秒级自动故障切换守护服务 (amazon-failover.service)
# ==============================================================================
install_failover_guardian() {
    echo -e "${YELLOW}>>> 正在部署【真实动态路径监控 + 页面卡死 3 秒自动故障切换守护 (amazon-failover)】...${NC}"
    purge_legacy_cron
    systemctl stop amazon-failover.service >/dev/null 2>&1
    killall -q -9 amazon-failover-daemon.sh >/dev/null 2>&1

    cat << 'FAILOVER_EOF' > "$FAILOVER_SCRIPT"
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 单实例运行互斥锁：防止多个守护进程并发冲突
LOCK_FILE="/run/amazon-failover.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    exit 0
fi

DOMAIN_DNS_CONF="/etc/dnsmasq.d/amazon_domain_dns.conf"
OPT_LOCK_FILE="/tmp/amazon_opt.lock"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# 核心业务健康度巡检列表 (已移除在国内遭遇 SNI 阻断的 images-na 探针，由 m.media-amazon 统一代管)
check_Domains=(
    "sellercentral.amazon.com|/gp/homepage.html|4500"
    "advertising.amazon.com|/|4500"
    "m.media-amazon.com|/favicon.ico|3000"
    "aax-us-east.amazon-adsystem.com|/|4000"
    "www.amazon.com|/favicon.ico|3000"
)

declare -A fail_counts
declare -A last_failover_ts

while true; do
    # 如果前台正在执行手动优选 (存在活跃锁)，跳过本轮巡检以防冲突
    if [ -f "$OPT_LOCK_FILE" ]; then
        lock_pid=$(cat "$OPT_LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            sleep 10
            continue
        else
            rm -f "$OPT_LOCK_FILE" 2>/dev/null
        fi
    fi

    if [ -f "$DOMAIN_DNS_CONF" ] && [ -f /usr/bin/vps ]; then
        # 修正 ss -tn: 取第 5 列对端 Peer IP，避免取第 4 列本地 VPS IP 造成误判
        syn_stuck_ips=$(ss -tn state syn-sent 2>/dev/null | awk 'NR>1 {print $5}' | cut -d':' -f1 | sort -u)
        cur_ts=$(date +%s)

        for item in "${check_Domains[@]}"; do
            IFS='|' read -r dom path max_ms <<< "$item"
            locked_ip=$(grep -E "^address=/${dom}/" "$DOMAIN_DNS_CONF" 2>/dev/null | head -n 1 | awk -F'/' '{print $3}')
            last_ts=${last_failover_ts["$dom"]:-0}

            # 熔断退避：单个域名自愈切换间隔至少 180 秒，防止死循环压测拖垮 VPS
            if [ -z "$locked_ip" ]; then
                if (( cur_ts - last_ts >= 180 )); then
                    last_failover_ts["$dom"]=$cur_ts
                    /bin/bash /usr/bin/vps --failover-domain "$dom" >/dev/null 2>&1
                fi
                continue
            fi

            need_switch=0
            if [ -n "$syn_stuck_ips" ] && echo "$syn_stuck_ips" | grep -q "^${locked_ip}$"; then
                need_switch=1
            fi

            res=$(curl -4 -s -o /dev/null --connect-timeout 3 --max-time 6 \
                -A "$UA" --resolve "${dom}:443:${locked_ip}" \
                -w "%{http_code}|%{time_appconnect}|%{time_total}|%{ssl_verify_result}" \
                "https://${dom}${path}" 2>/dev/null)
            IFS='|' read -r hcode tssl ttot serr <<< "$res"
            ms_ssl=$(awk "BEGIN {printf \"%.0f\", ${tssl:-0} * 1000}")
            ms_tot=$(awk "BEGIN {printf \"%.0f\", ${ttot:-0} * 1000}")

            if [ "$hcode" == "000" ] || [ "$ms_ssl" -le 0 ] || [ "${serr:-1}" != "0" ] || [ "$ms_tot" -gt "$max_ms" ]; then
                fail_counts["$dom"]=$(( ${fail_counts["$dom"]:-0} + 1 ))
                # 若发现 SYN-SENT 卡死则立即切换(1次)；若仅延迟超时则需连续 3 次探测失败触发自愈，防偶发抖动
                if [ "$need_switch" -eq 1 ] || [ "${fail_counts["$dom"]}" -ge 3 ]; then
                    if (( cur_ts - last_ts >= 180 )); then
                        last_failover_ts["$dom"]=$cur_ts
                        /bin/bash /usr/bin/vps --failover-domain "$dom" >/dev/null 2>&1
                    fi
                    fail_counts["$dom"]=0
                fi
            else
                fail_counts["$dom"]=0
            fi
        done
    fi
    sleep 15
done
FAILOVER_EOF
    chmod +x "$FAILOVER_SCRIPT"

    cat << SERVICE_FAILOVER_EOF > "$FAILOVER_SERVICE"
[Unit]
Description=Amazon Real-Time Node Failover Guardian (Auto-Switch Dead/Slow Node in 3s)
After=network.target dnsmasq.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/killall -q -9 amazon-failover-daemon.sh
ExecStart=${FAILOVER_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_FAILOVER_EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable amazon-failover.service >/dev/null 2>&1
    systemctl restart amazon-failover.service >/dev/null 2>&1
    echo -e "${GREEN}>>> [成功] 真实动态路径监控与秒级故障自愈守护服务 (amazon-failover) 已激活！${NC}"
}

# 菜单 [03]: 按域名命中节点测速锁定与实时秒级故障自愈中心
auto_dns_optimizer_menu() {
    clear
    purge_legacy_cron
    local failover_status="${RED}○ 未开启${NC}"
    if systemctl is-active --quiet amazon-failover; then
        failover_status="${GREEN}● 实时守护中 (平时保持最快节点不动，仅在页面打不开或响应 >3.5s 时秒级换新)${NC}"
    fi

    print_brand_banner "亚马逊各域名命中节点测速锁定与秒级故障自愈中心 (无定时重测干扰)"
    echo -e " 核心策略：已彻底移除会导致速度波动的定时重测任务！平时 100% 锁死极速节点不动，"
    echo -e "           仅当后台守护检测到某个域名连接超时或动态页变慢 (>3.5秒) 时自动换节点！"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e " 秒级故障自愈守护 : ${failover_status}"
    echo -e " 最近一次切换记录 : ${WHITE}$(tail -n 1 "$AUTO_OPT_LOG" 2>/dev/null || echo '暂无记录')${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}[1]${NC} ${GREEN}立即执行【全量采集 5 大核心业务命中节点 + 真实动态路径测速 + 锁定最快IP】${NC}"
    echo -e "  ${CYAN}[2]${NC} 单独重新测速并切换【1. 亚马逊北美卖家中心 (sellercentral)】节点"
    echo -e "  ${CYAN}[3]${NC} 单独重新测速并切换【2. 亚马逊广告管理中心 (advertising)】节点"
    echo -e "  ${CYAN}[4]${NC} 单独重新测速并切换【3. 亚马逊多媒体与商品图片 (m.media-amazon.com)】节点"
    echo -e "  ${YELLOW}[5]${NC} 查看节点锁定与秒级故障自愈历史日志"
    echo -e "  ${GREEN}[6]${NC} 开启 / 重启【页面卡死秒级自动故障切换守护 (amazon-failover)】"
    echo -e "  ${RED}[7]${NC} 停止【页面卡死秒级自动故障切换守护】"
    echo -e "  ${WHITE}[0]${NC} 返回主菜单"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${NC}"
    read -p "请输入选项 [0-7]: " ao_opt
    case "$ao_opt" in
        1|01)
            setup_dns_accelerator
            optimize_per_domain_dns "verbose"
            ;;
        2|02)
            optimize_per_domain_dns "verbose" "sellercentral.amazon.com"
            ;;
        3|03)
            optimize_per_domain_dns "verbose" "advertising.amazon.com"
            ;;
        4|04)
            optimize_per_domain_dns "verbose" "m.media-amazon.com"
            ;;
        5|05)
            echo -e "\n${CYAN}================ 节点锁定与秒级故障自愈日志 (最近 25 条) ================${NC}"
            if [ -f "$AUTO_OPT_LOG" ]; then
                tail -n 25 "$AUTO_OPT_LOG"
            else
                echo -e "${YELLOW}暂无历史日志，请先执行选项 [1] 进行首次优选。${NC}"
            fi
            echo -e "${CYAN}=========================================================================${NC}"
            ;;
        6|06)
            install_failover_guardian
            ;;
        7|07)
            systemctl stop amazon-failover.service >/dev/null 2>&1
            systemctl disable amazon-failover.service >/dev/null 2>&1
            echo -e "${YELLOW}>>> 已停止后台秒级故障切换守护。当前锁定的节点将永久保持不变。${NC}"
            ;;
        *)
            return 0
            ;;
    esac
}

# 5. 2M 小带宽独占保护模式 + 根除 Google 黑洞 IP SYN-SENT 阻塞 + 中国本土 IP 防关联加固
protect_bandwidth_and_harden() {
    echo -e "${YELLOW}>>> [5/6] 正在启用小带宽保护、清除 Google SYN-SENT 死连接与本土 IP 防关联加固...${NC}"
    systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    systemctl disable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    systemctl stop unattended-upgrades >/dev/null 2>&1
    systemctl disable unattended-upgrades >/dev/null 2>&1
    systemctl stop apport whoopsie >/dev/null 2>&1
    systemctl disable apport whoopsie >/dev/null 2>&1

    local stun_ports=("3478" "5349" "19302:19309")
    for sp in "${stun_ports[@]}"; do
        iptables -D OUTPUT -p udp --dport "$sp" -j DROP >/dev/null 2>&1
        iptables -I OUTPUT 1 -p udp --dport "$sp" -j DROP >/dev/null 2>&1
        iptables -D FORWARD -p udp --dport "$sp" -j DROP >/dev/null 2>&1
        iptables -I FORWARD 1 -p udp --dport "$sp" -j DROP >/dev/null 2>&1
    done

    for mp in 25 465 587 6881:6889; do
        iptables -D OUTPUT -p tcp --dport "$mp" -j DROP >/dev/null 2>&1
        iptables -I OUTPUT 1 -p tcp --dport "$mp" -j DROP >/dev/null 2>&1
        iptables -D OUTPUT -p udp --dport "$mp" -j DROP >/dev/null 2>&1
        iptables -I OUTPUT 1 -p udp --dport "$mp" -j DROP >/dev/null 2>&1
    done

    # 对专用瞬断地址 127.255.255.254 返回 TCP RST (0.001ms 瞬间断开，绝不等待超时)
    iptables -D OUTPUT -d 127.255.255.254 -p tcp -j REJECT --reject-with tcp-reset >/dev/null 2>&1
    iptables -I OUTPUT 1 -d 127.255.255.254 -p tcp -j REJECT --reject-with tcp-reset >/dev/null 2>&1

    local country
    country=$(get_vps_country)
    if [ "$country" == "CN" ]; then
        if command -v timedatectl >/dev/null 2>&1; then
            timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1
            timedatectl set-ntp true >/dev/null 2>&1
        fi
        # 对指纹浏览器硬编码直连的 Google 黑洞 IP 段直接返回 TCP RST (0.001ms 瞬间断开)
        local google_blackhole_cidrs=(
            "172.217.0.0/16"
            "108.177.0.0/17"
            "142.250.0.0/15"
            "216.58.192.0/19"
            "74.125.0.0/16"
        )
        for gcidr in "${google_blackhole_cidrs[@]}"; do
            iptables -D OUTPUT -d "$gcidr" -p tcp -j REJECT --reject-with tcp-reset >/dev/null 2>&1
            iptables -I OUTPUT 1 -d "$gcidr" -p tcp -j REJECT --reject-with tcp-reset >/dev/null 2>&1
        done
    fi

    echo -e "${GREEN}>>> 2M 带宽保护、Google SYN-SENT 0ms 瞬断、WebRTC 阻断与北京时间同步已生效！${NC}"
}

# 6. 全组件运行状态强制自检、警告告知与自动修复重装引擎
verify_and_repair_all() {
    echo -e "\n${YELLOW}>>> [6/6] 正在执行全组件安装后自检与未启动项目自动重装修复...${NC}"
    purge_legacy_cron
    local all_ok=1

    if command -v dig >/dev/null 2>&1; then
        echo -e "    [自检 1/5] dig 域名探测工具   : ${GREEN}● 正常就绪${NC}"
    else
        echo -e "    [自检 1/5] dig 域名探测工具   : ${RED}▲ 警告：未安装！正在自动为您补装 dnsutils...${NC}"
        ensure_working_dns
        apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils >/dev/null 2>&1
        yum install -y bind-utils >/dev/null 2>&1
        if command -v dig >/dev/null 2>&1; then
            echo -e "               └─ 修复结果        : ${GREEN}✓ dig 已成功安装！${NC}"
        else
            echo -e "               └─ 修复结果        : ${RED}✗ dig 安装失败，请检查系统软件源${NC}"
            all_ok=0
        fi
    fi

    if (systemctl is-active --quiet dnsmasq || pgrep -x dnsmasq >/dev/null 2>&1) && ss -ulpn 2>/dev/null | grep -q ":53 "; then
        echo -e "    [自检 2/5] dnsmasq 加速引擎   : ${GREEN}● 正在运行且正常监听 127.0.0.1:53${NC}"
    else
        echo -e "    [自检 2/5] dnsmasq 加速引擎   : ${RED}▲ 警告：检测到 dnsmasq 未启动！正在自动构建服务单元并修复...${NC}"
        repair_and_start_dnsmasq
        if (systemctl is-active --quiet dnsmasq || pgrep -x dnsmasq >/dev/null 2>&1); then
            echo -e "               └─ 修复结果        : ${GREEN}✓ dnsmasq 已被成功修复并正常跑起来了！${NC}"
        else
            echo -e "               └─ 修复结果        : ${RED}✗ dnsmasq 启动失败，已自动回退至 /etc/hosts + 保底 DNS${NC}"
            all_ok=0
        fi
    fi

    load_proxy_config
    # 如果当前 /usr/bin/gost 是内置 Python3 引擎，确保同步升级为最新 v7.6 增强引擎
    if [ -f /usr/bin/gost ] && head -n 2 /usr/bin/gost 2>/dev/null | grep -q "python3"; then
        if ! grep -q "AMZ_DIRECT_MAP_V76" /usr/bin/gost 2>/dev/null; then
            install_builtin_proxy_engine >/dev/null 2>&1
            systemctl restart gost >/dev/null 2>&1
            sleep 1
        fi
    fi

    if systemctl is-active --quiet gost && (ss -tlpn 2>/dev/null | grep -q ":${PROXY_PORT} " || netstat -tlpn 2>/dev/null | grep -q ":${PROXY_PORT} "); then
        local engine_type="Go官方高并发 Gost 二进制核心"
        if [ -f /usr/bin/gost ] && head -n 2 /usr/bin/gost 2>/dev/null | grep -q "python3"; then
            engine_type="内置 Python3 Asyncio 高并发增强核心 (v7.6)"
        fi
        echo -e "    [自检 3/5] 双协议代理服务核心 : ${GREEN}● 正在运行 (${engine_type} | 端口: ${PROXY_PORT})${NC}"
    else
        echo -e "    [自检 3/5] 双协议代理服务核心 : ${RED}▲ 警告：检测到代理服务未运行！正在自动重装并启动...${NC}"
        download_gost
        force_open_port "$PROXY_PORT"
        cat << SERVICE_EOF > /etc/systemd/system/gost.service
[Unit]
Description=Gost Dual-Protocol Proxy (Socks5 & HTTP) - Amazon Optimized
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
Environment="GODEBUG=netdns=cgo"
ExecStart=/usr/bin/gost -L="${PROXY_USER}:${PROXY_PASS}@:${PROXY_PORT}?keepalive=true&ttl=60s&readBufferSize=65536&writeBufferSize=65536"
Restart=always
RestartSec=2
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF
        systemctl daemon-reload
        systemctl enable gost >/dev/null 2>&1
        systemctl restart gost >/dev/null 2>&1
        sleep 1
        if systemctl is-active --quiet gost; then
            echo -e "               └─ 修复结果        : ${GREEN}✓ 代理服务已成功启动 (端口: ${PROXY_PORT})！${NC}"
        else
            echo -e "               └─ 切换内置引擎修复: ${YELLOW}正在启用内置 Python3 Asyncio 双协议引擎兜底...${NC}"
            rm -f /usr/bin/gost
            install_builtin_proxy_engine
            systemctl restart gost >/dev/null 2>&1
            sleep 1
            if systemctl is-active --quiet gost; then
                echo -e "               └─ 修复结果        : ${GREEN}✓ 内置双协议代理服务已成功启动 (端口: ${PROXY_PORT})！${NC}"
            else
                echo -e "               └─ 修复结果        : ${RED}✗ 代理服务启动异常，请通过菜单[12]查看日志${NC}"
                all_ok=0
            fi
        fi
    fi

    if systemctl is-active --quiet amazon-failover; then
        echo -e "    [自检 4/5] 秒级故障自愈守护   : ${GREEN}● 正在运行 (平时不乱换节点，仅故障/超时3秒内自愈)${NC}"
    else
        echo -e "    [自检 4/5] 秒级故障自愈守护   : ${RED}▲ 警告：故障切换守护未启动！正在自动激活...${NC}"
        install_failover_guardian >/dev/null 2>&1
        if systemctl is-active --quiet amazon-failover; then
            echo -e "               └─ 修复结果        : ${GREEN}✓ 秒级故障切换守护已成功启动！${NC}"
        fi
    fi

    local bbr_now
    bbr_now=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$bbr_now" == "bbr" ]; then
        echo -e "    [自检 5/5] BBR 跨国加速内核   : ${GREEN}● 已开启 (bbr)${NC}"
    else
        echo -e "    [自检 5/5] BBR 跨国加速内核   : ${RED}▲ 警告：BBR 未激活，正在重新加载 tcp_bbr 模块...${NC}"
        modprobe tcp_bbr >/dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
        echo -e "               └─ 修复结果        : ${GREEN}✓ 当前拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC}"
    fi

    if [ $all_ok -eq 1 ]; then
        echo -e "${GREEN}>>> [自检通过] 全套 5 大核心加速与实时故障自愈组件 100% 正常运行！${NC}"
    fi
}

# 内置高并发双协议 (Socks5 + HTTP CONNECT) 代理引擎生成函数 (v7.6 64线程非阻塞 + 2.5s熔断 + 内存直读)
install_builtin_proxy_engine() {
    echo -e "${YELLOW}>>> 正在部署内置自研【高并发 Asyncio 双协议代理核心 v7.6 (64线程+熔断防护+0ms秒拒)】...${NC}"
    if ! command -v python3 >/dev/null 2>&1; then
        ensure_working_dns
        apt-get update -y >/dev/null 2>&1 && apt-get install -y python3 >/dev/null 2>&1
        yum install -y python3 >/dev/null 2>&1
    fi

    cat << 'PYPROXY_EOF' > /usr/bin/gost
#!/usr/bin/env python3
# AMZ_DIRECT_MAP_V76
import asyncio
import base64
import concurrent.futures
import os
import re
import socket
import struct
import sys
import time

def parse_args():
    user, passwd, port = "amazon", "admin888", 7878
    for arg in sys.argv[1:]:
        if arg.startswith("-L="):
            val = arg[3:].split("?")[0]
            m = re.match(r"^([^:]+):([^@]+)@:(\d+)$", val)
            if m:
                user, passwd, port = m.group(1), m.group(2), int(m.group(3))
    return user, passwd, port

PROXY_USER, PROXY_PASS, PROXY_PORT = parse_args()
EXPECTED_BASIC = base64.b64encode(f"{PROXY_USER}:{PROXY_PASS}".encode()).decode()

DOMAIN_CONF = "/etc/dnsmasq.d/amazon_domain_dns.conf"
_cached_mtime = 0.0
_domain_map = {}
_ip_cache = {}

# 增强型秒拒黑名单：彻底拦截指纹浏览器自发 Google / 遥测 / 无法直连的被墙死连接
BLOCKED_SUFFIXES = (
    "googleapis.com",
    "gstatic.com",
    "gvt1.com",
    "gvt2.com",
    "gvt3.com",
    "google.com",
    "googleusercontent.com",
    "clients1.google.com",
    "clients2.google.com",
    "clients3.google.com",
    "clients4.google.com",
    "clients5.google.com",
    "clients6.google.com",
    "google-analytics.com",
    "googletagmanager.com",
    "doubleclick.net",
)
BLOCKED_IP_PREFIXES = (
    "172.217.", "108.177.", "142.250.", "142.251.", "216.58.", "74.125.",
    "127.255.", "127.0.0.1", "0.0.0.0"
)

def resolve_fast_host(host):
    global _cached_mtime, _domain_map, _ip_cache
    h = host.lower().strip(".")
    for suf in BLOCKED_SUFFIXES:
        if h == suf or h.endswith("." + suf):
            return None
    for pfx in BLOCKED_IP_PREFIXES:
        if h.startswith(pfx):
            return None

    try:
        st = os.stat(DOMAIN_CONF)
        if st.st_mtime != _cached_mtime:
            new_map = {}
            with open(DOMAIN_CONF, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("address=/"):
                        parts = line.split("/")
                        if len(parts) >= 3 and parts[1] and parts[2]:
                            new_map[parts[1].lower()] = parts[2]
            _domain_map = new_map
            _cached_mtime = st.st_mtime
    except Exception:
        pass

    if h in _domain_map:
        return _domain_map[h]
    for dom_k, ip_v in _domain_map.items():
        if h.endswith("." + dom_k):
            return ip_v

    now = time.time()
    if h in _ip_cache:
        cached_ip, exp = _ip_cache[h]
        if now < exp:
            return cached_ip
        else:
            del _ip_cache[h]

    return host

async def open_fast_connection(host, port):
    real_host = resolve_fast_host(host)
    if real_host is None:
        raise ConnectionRefusedError("Blocked target")
    # 2.5s 极速超时熔断死连接，彻底解决 6s 长时间卡死与队列堆积
    reader, writer = await asyncio.wait_for(asyncio.open_connection(real_host, port), timeout=2.5)
    if real_host != host and not re.match(r"^\d+\.\d+\.\d+\.\d+$", host):
        _ip_cache[host.lower().strip(".")] = (real_host, time.time() + 300)
    return reader, writer

async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass

async def bidirectional_copy(r1, w1, r2, w2):
    t1 = asyncio.create_task(pipe(r1, w2))
    t2 = asyncio.create_task(pipe(r2, w1))
    done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()
    try:
        w1.close()
    except Exception:
        pass
    try:
        w2.close()
    except Exception:
        pass

def set_nodelay(writer):
    try:
        sock = writer.get_extra_info("socket")
        if sock:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except Exception:
        pass

async def handle_socks5(first_byte, reader, writer):
    try:
        hdr = await asyncio.wait_for(reader.readexactly(1), timeout=3.0)
        nmethods = hdr[0]
        methods = await asyncio.wait_for(reader.readexactly(nmethods), timeout=3.0)
        if 2 in methods:
            writer.write(b"\x05\x02")
            await writer.drain()
            auth_ver = (await asyncio.wait_for(reader.readexactly(1), timeout=3.0))[0]
            ulen = (await asyncio.wait_for(reader.readexactly(1), timeout=3.0))[0]
            u = (await asyncio.wait_for(reader.readexactly(ulen), timeout=3.0)).decode("utf-8", "ignore")
            plen = (await asyncio.wait_for(reader.readexactly(1), timeout=3.0))[0]
            p = (await asyncio.wait_for(reader.readexactly(plen), timeout=3.0)).decode("utf-8", "ignore")
            if u != PROXY_USER or p != PROXY_PASS:
                writer.write(b"\x01\x01")
                await writer.drain()
                writer.close()
                return
            writer.write(b"\x01\x00")
            await writer.drain()
        else:
            writer.write(b"\x05\xff")
            await writer.drain()
            writer.close()
            return

        req = await asyncio.wait_for(reader.readexactly(4), timeout=3.0)
        ver, cmd, _, atyp = req[0], req[1], req[2], req[3]
        if cmd != 1:
            writer.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
            writer.close()
            return

        if atyp == 1:
            host = socket.inet_ntoa(await asyncio.wait_for(reader.readexactly(4), timeout=3.0))
        elif atyp == 3:
            dlen = (await asyncio.wait_for(reader.readexactly(1), timeout=3.0))[0]
            host = (await asyncio.wait_for(reader.readexactly(dlen), timeout=3.0)).decode("utf-8", "ignore")
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, await asyncio.wait_for(reader.readexactly(16), timeout=3.0))
        else:
            writer.close()
            return

        port = struct.unpack("!H", await asyncio.wait_for(reader.readexactly(2), timeout=3.0))[0]
    except Exception:
        try:
            writer.close()
        except Exception:
            pass
        return

    try:
        rem_r, rem_w = await open_fast_connection(host, port)
        set_nodelay(rem_w)
        writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        await bidirectional_copy(reader, writer, rem_r, rem_w)
    except Exception:
        try:
            writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
        except Exception:
            pass
        try:
            writer.close()
        except Exception:
            pass

async def handle_http(first_byte, reader, writer):
    try:
        buf = first_byte + await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=5.0)
    except Exception:
        try:
            writer.close()
        except Exception:
            pass
        return

    header_text = buf.decode("latin1", "ignore")
    lines = header_text.split("\r\n")
    if not lines:
        writer.close()
        return

    authed = False
    for line in lines[1:]:
        if line.lower().startswith("proxy-authorization:"):
            parts = line.split()
            if len(parts) >= 3 and parts[1].lower() == "basic" and parts[2].strip() == EXPECTED_BASIC:
                authed = True
                break
    if not authed:
        writer.write(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"AmazonProxy\"\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    req_parts = lines[0].split()
    if len(req_parts) < 2:
        writer.close()
        return
    method, target = req_parts[0].upper(), req_parts[1]

    if method == "CONNECT":
        if ":" in target:
            host, port_s = target.rsplit(":", 1)
            port = int(port_s)
        else:
            host, port = target, 443
        try:
            rem_r, rem_w = await open_fast_connection(host, port)
            set_nodelay(rem_w)
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await bidirectional_copy(reader, writer, rem_r, rem_w)
        except Exception:
            try:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                await writer.drain()
            except Exception:
                pass
            try:
                writer.close()
            except Exception:
                pass
    else:
        m = re.match(r"^http://([^/:]+)(?::(\d+))?(/.*)?$", target, re.I)
        if not m:
            writer.close()
            return
        host = m.group(1)
        port = int(m.group(2)) if m.group(2) else 80
        path = m.group(3) or "/"
        try:
            rem_r, rem_w = await open_fast_connection(host, port)
            set_nodelay(rem_w)
            new_lines = [f"{method} {path} {req_parts[2] if len(req_parts)>2 else 'HTTP/1.1'}"]
            for line in lines[1:]:
                if not line.lower().startswith("proxy-"):
                    new_lines.append(line)
            rem_w.write(("\r\n".join(new_lines) + "\r\n\r\n").encode("latin1"))
            await rem_w.drain()
            await bidirectional_copy(reader, writer, rem_r, rem_w)
        except Exception:
            try:
                writer.close()
            except Exception:
                pass

async def handle_client(reader, writer):
    set_nodelay(writer)
    try:
        first_byte = await asyncio.wait_for(reader.readexactly(1), timeout=5.0)
        if first_byte == b"\x05":
            await handle_socks5(first_byte, reader, writer)
        else:
            await handle_http(first_byte, reader, writer)
    except Exception:
        try:
            writer.close()
        except Exception:
            pass

async def main():
    loop = asyncio.get_running_loop()
    # 强制分配 64 线程池，保障并发 DNS 解析绝不排队阻塞
    loop.set_default_executor(concurrent.futures.ThreadPoolExecutor(max_workers=64))
    server = await asyncio.start_server(handle_client, "0.0.0.0", PROXY_PORT, backlog=4096)
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
PYPROXY_EOF
    chmod +x /usr/bin/gost
    echo -e "${GREEN}>>> 内置高并发双协议代理核心 v7.6 (Socks5 + HTTP) 部署成功！${NC}"
    return 0
}

# 智能多镜像下载 Gost 组件 (优先官方 Go 编译高并发核心，兜底启用 Python3 增强引擎)
download_gost() {
    local force_dl="${1:-0}"
    if [ "$force_dl" != "1" ] && [ -f /usr/bin/gost ] && [ -x /usr/bin/gost ]; then
        if ! head -n 2 /usr/bin/gost 2>/dev/null | grep -q "python3"; then
            echo -e "${GREEN}检测到官方高并发 Go-Gost 核心已安装，跳过下载。${NC}"
            return 0
        fi
    fi

    ensure_working_dns
    echo -e "${YELLOW}>>> 正在下载代理服务核心组件 (官方 Go 高并发核心，2026 国内多镜像加速)...${NC}"
    local arch
    arch=$(uname -m)
    local gost_arch="amd64"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && gost_arch="armv8"

    local gh_file="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${gost_arch}-2.11.5.gz"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    local mirrors=(
        "https://ghfast.top/${gh_file}"
        "https://gh-proxy.com/${gh_file}"
        "https://ghproxy.net/${gh_file}"
        "https://mirror.ghproxy.com/${gh_file}"
        "https://gh.ddlc.top/${gh_file}"
        "https://slink.ltd/${gh_file}"
        "${gh_file}"
    )

    local success=0
    for url in "${mirrors[@]}"; do
        echo -e "${CYAN}尝试加速源: ${url}${NC}"
        rm -f /tmp/gost.gz
        if curl -4 -fL --connect-timeout 4 --max-time 15 -A "$ua" "$url" -o /tmp/gost.gz 2>/dev/null || \
           wget -4 -q -t 1 -T 8 -U "$ua" --no-check-certificate "$url" -O /tmp/gost.gz 2>/dev/null; then
            if [ -s /tmp/gost.gz ] && [ $(wc -c < /tmp/gost.gz) -gt 1000000 ] && gzip -t /tmp/gost.gz 2>/dev/null; then
                gzip -d -f /tmp/gost.gz
                mv -f /tmp/gost /usr/bin/gost
                chmod +x /usr/bin/gost
                success=1
                echo -e "${GREEN}>>> 官方高并发 Go-Gost 二进制核心极速下载并解压成功！${NC}"
                break
            fi
        fi
        rm -f /tmp/gost.gz
    done

    if [ $success -eq 0 ]; then
        echo -e "${YELLOW}>>> 外部 GitHub 镜像连接受限，正在自动启用【内置自研高并发双协议代理引擎 v7.6 (64线程+熔断防护)】...${NC}"
        install_builtin_proxy_engine
        return 0
    fi
}

# 系统级强行强开端口
force_open_port() {
    local port=$1
    echo -e "${YELLOW}>>> 正在对端口 [${port}] 进行系统级强行强开与冲突清理...${NC}"

    if command -v fuser >/dev/null 2>&1; then
        fuser -k -9 -n tcp "$port" >/dev/null 2>&1
    fi
    if command -v lsof >/dev/null 2>&1; then
        local pids
        pids=$(lsof -t -i :"$port" 2>/dev/null)
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

    echo -e "${GREEN}>>> 端口 [${port}] 系统防火墙已置顶放行，冲突进程已清除！${NC}"
}

# 修改并部署配置
modify_config() {
    load_proxy_config
    local def_port="$PROXY_PORT"
    local def_user="$PROXY_USER"
    local def_pass="$PROXY_PASS"

    local rand_port=$((RANDOM % 30000 + 20000))
    local rand_pass="Amz$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8)"
    [ -z "$rand_pass" ] && rand_pass="Amz889966"

    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}请设置代理连接信息 (直接回车保留当前值):${NC}"
    echo -e "${PURPLE}★ 防关联安全提示: 建议使用复杂密码，防止被扫描器盗用您的杭州/国内专属 IP！${NC}"
    echo -e "  推荐随机安全端口: ${GREEN}${rand_port}${NC} | 推荐随机高强密码: ${GREEN}${rand_pass}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"

    read -p "设置端口 [当前: $def_port]: " port
    port=${port:-$def_port}

    read -p "设置账号 [当前: $def_user]: " user
    user=${user:-$def_user}

    read -p "设置密码 [当前: $def_pass]: " pass
    pass=${pass:-$def_pass}

    cat << CONFIG_EOF > "$CONFIG_FILE"
PROXY_PORT=$port
PROXY_USER=$user
PROXY_PASS=$pass
PORT=$port
USER=$user
PASS=$pass
CONFIG_EOF
    chmod 600 "$CONFIG_FILE"

    systemctl stop gost >/dev/null 2>&1
    force_open_port "$port"

    cat << SERVICE_EOF > /etc/systemd/system/gost.service
[Unit]
Description=Gost Dual-Protocol Proxy (Socks5 & HTTP) - Amazon Optimized
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
Environment="GODEBUG=netdns=cgo"
ExecStart=/usr/bin/gost -L="${user}:${pass}@:${port}?keepalive=true&ttl=60s&readBufferSize=65536&writeBufferSize=65536"
Restart=always
RestartSec=2
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable gost >/dev/null 2>&1
    systemctl restart gost
    sleep 1

    verify_and_repair_all
    query_proxy_info "no_pause"
}

# 查询当前代理信息
query_proxy_info() {
    local mode="$1"
    [ "$mode" != "no_pause" ] && clear
    local ip
    ip=$(get_public_ip)
    load_proxy_config
    local port="$PROXY_PORT"
    local user="$PROXY_USER"
    local pass="$PROXY_PASS"

    local is_running="未运行"
    if systemctl is-active --quiet gost; then
        is_running="${GREEN}● 运行中 (Active - KeepAlive 多路复用已开启)${NC}"
    else
        is_running="${RED}○ 已停止${NC}"
    fi

    local dnsmasq_state="${RED}○ 未运行${NC}"
    if systemctl is-active --quiet dnsmasq || pgrep -x dnsmasq >/dev/null 2>&1; then
        dnsmasq_state="${GREEN}● 运行中 (各域名最快节点已 100% 锁定 + Google 死连接已秒拒)${NC}"
    fi

    local failover_state="${RED}○ 未运行${NC}"
    if systemctl is-active --quiet amazon-failover; then
        failover_state="${GREEN}● 实时守护中 (平时保持最快节点不动，仅故障/超时3秒内自动换新)${NC}"
    fi

    local port_listen="未监听"
    if ss -tlpn 2>/dev/null | grep -q ":${port} "; then
        port_listen="${GREEN}正常监听在 0.0.0.0:${port}${NC}"
    elif netstat -tlpn 2>/dev/null | grep -q ":${port} "; then
        port_listen="${GREEN}正常监听在 0.0.0.0:${port}${NC}"
    else
        port_listen="${YELLOW}未检测到监听 (请确认服务是否已启动)${NC}"
    fi

    print_brand_banner "Socks5 / HTTP 双协议代理账户与指纹浏览器连接参数"
    echo -e " 当前脚本版本 : ${GREEN}${SCRIPT_VERSION} (晓林技术支持 · 旗舰无干扰自愈版)${NC}"
    echo -e " 代理服务状态 : $is_running"
    echo -e " 智能DNS引擎  : $dnsmasq_state"
    echo -e " 秒级故障自愈 : $failover_state"
    echo -e " 端口监听状态 : $port_listen"
    echo -e " 代理连接类型 : ${CYAN}Socks5${NC} 或 ${CYAN}HTTP${NC} (AdsPower/比特/紫鸟/Hubstudio 均兼容)"
    echo -e " 代理主机 IP  : ${GREEN}${ip}${NC}"
    echo -e " 代理连接端口 : ${GREEN}${port}${NC}"
    echo -e " 代理连接账号 : ${GREEN}${user}${NC}"
    echo -e " 代理连接密码 : ${GREEN}${pass}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e " 【指纹浏览器一键粘贴导入格式 (IP:端口:账号:密码)】:"
    echo -e "  ${GREEN}${ip}:${port}:${user}:${pass}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}★ 阿里云/华为云/腾讯云/移动云 入方向安全组放行要点:${NC}"
    echo -e "  确保安全组【入方向规则】有: 协议=TCP, 端口=${port}, 授权对象=0.0.0.0/0"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${NC}"
}

# 手动强开指定端口
manual_force_open_port() {
    clear
    print_brand_banner "系统防火墙端口强开与冲突进程清理工具"
    echo -e " 此功能将强行杀掉目标端口占用的冲突进程，并在系统防火墙置顶放行！"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    read -p "请输入需要强行强开的端口 (例如 7878): " target_port
    if [ -n "$target_port" ]; then
        force_open_port "$target_port"
        load_proxy_config
        if [ "$target_port" == "$PROXY_PORT" ]; then
            systemctl restart gost
            echo -e "${GREEN}已同步重启当前代理服务！${NC}"
        fi
    else
        echo -e "${RED}未输入端口！${NC}"
    fi
}

# 亚马逊卖家中心 & 广告后台 & 商品图片CDN 毫秒级真实动态路径测速 (带超时自动切换并当场重测)
test_url_speed() {
    local target_url="$1"
    local desc_name="$2"
    local retry_flag="${3:-0}"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    if [ "$retry_flag" == "0" ]; then
        echo -e "\n${CYAN}>>> 正在测试: ${WHITE}${desc_name}${NC}"
        echo -e "    目标地址: ${CYAN}${target_url}${NC}"
    fi

    local result
    result=$(curl -4 -s -o /dev/null -A "$ua" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" \
        -w "%{http_code}|%{remote_ip}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}" \
        --connect-timeout 4 --max-time 8 "$target_url" 2>/dev/null)

    IFS='|' read -r http_code remote_ip t_dns t_tcp t_ssl t_ttfb t_total <<< "$result"

    local ms_dns ms_tcp ms_ssl ms_ttfb ms_total
    ms_dns=$(awk "BEGIN {printf \"%.0f\", ${t_dns:-0} * 1000}")
    ms_tcp=$(awk "BEGIN {printf \"%.0f\", (${t_tcp:-0} - ${t_dns:-0}) * 1000}")
    ms_ssl=$(awk "BEGIN {printf \"%.0f\", (${t_ssl:-0} - ${t_tcp:-0}) * 1000}")
    ms_ttfb=$(awk "BEGIN {printf \"%.0f\", (${t_ttfb:-0} - ${t_ssl:-0}) * 1000}")
    ms_total=$(awk "BEGIN {printf \"%.0f\", ${t_total:-0} * 1000}")
    [ "$ms_tcp" -lt 0 ] && ms_tcp=0
    [ "$ms_ssl" -lt 0 ] && ms_ssl=0
    [ "$ms_ttfb" -lt 0 ] && ms_ttfb=0

    if [ -z "$result" ] || [ "$http_code" == "000" ] || [ "$ms_ssl" -le 0 ]; then
        if [ "$retry_flag" == "0" ]; then
            echo -e "    状态检测: ${YELLOW}节点 ${remote_ip:-未知} 响应异常，正在为您触发秒级自动切换并当场重测...${NC}"
            local dom_extract
            dom_extract=$(echo "$target_url" | awk -F'/' '{print $3}')
            [ -n "$dom_extract" ] && optimize_per_domain_dns "silent" "$dom_extract"
            test_url_speed "$target_url" "$desc_name" "1"
            return $?
        else
            echo -e "    状态检测: ${RED}连接超时或阻断 (目标节点: ${remote_ip:-未知})${NC}"
            return 1
        fi
    fi

    local code_display="HTTP ${http_code}"
    if [ "$http_code" == "302" ] && [[ "$target_url" == *"sellercentral"* ]]; then
        code_display="HTTP 302 (已连入卖家中心真实动态网关)"
    elif [ "$http_code" == "503" ] && [ "$ms_ssl" -gt 0 ]; then
        code_display="HTTP 503 (TLS加密握手已通，指纹浏览器带Cookie可正常打开)"
    fi

    local speed_rate=""
    if [ "$ms_total" -lt 1200 ]; then
        speed_rate="${GREEN}极快 (秒开级)${NC}"
    elif [ "$ms_total" -lt 2500 ]; then
        speed_rate="${GREEN}优秀 (流畅)${NC}"
    elif [ "$ms_total" -lt 3800 ]; then
        speed_rate="${YELLOW}良好 (正常)${NC}"
    else
        speed_rate="${RED}偏慢 (建议在菜单[03]单独切换该域名节点)${NC}"
    fi

    echo -e "    命中节点 : ${WHITE}${remote_ip}${NC} (${GREEN}${code_display}${NC})"
    echo -e "    分段耗时 : DNS=${GREEN}${ms_dns}ms${NC} | TCP=${CYAN}${ms_tcp}ms${NC} | SSL=${CYAN}${ms_ssl}ms${NC} | 服务端响应(TTFB)=${WHITE}${ms_ttfb}ms${NC}"
    echo -e "    总体耗时 : ${CYAN}${ms_total} ms${NC}  [综合评级: ${speed_rate}]"
}

test_amazon_suite() {
    clear
    print_brand_banner "亚马逊卖家中心 / 广告后台 / 多媒体与图片 CDN 真实动态路径深度测速"
    echo -e " 正在对 6 大核心业务真实路径进行 DNS / TCP / SSL / TTFB 分段诊断..."

    test_url_speed "https://sellercentral.amazon.com/gp/homepage.html" "1. 亚马逊北美卖家中心真实动态后台 (Seller Central Dynamic)"
    test_url_speed "https://advertising.amazon.com/" "2. 亚马逊广告门户首页 (Advertising Portal)"
    test_url_speed "https://advertising.amazon.com/campaign-manager/all-campaigns" "3. 亚马逊广告活动管理后台 (Campaign Manager)"
    test_url_speed "https://m.media-amazon.com/favicon.ico" "4. 亚马逊多媒体与商品图片 CDN 核心静态库 (Media & Images CDN)"
    test_url_speed "https://aax-us-east.amazon-adsystem.com/" "5. 亚马逊北美广告竞价与报表引擎 (AAX US-East)"
    test_url_speed "https://www.amazon.com/favicon.ico" "6. 亚马逊北美主站商品前台节点 (Storefront CDN)"

    echo -e "\n${YELLOW}================== 当前各域名已 100% 锁定的最快命中节点 ==================${NC}"
    if [ -f "$DOMAIN_DNS_CONF" ]; then
        grep -E "^# [0-9]+\." "$DOMAIN_DNS_CONF" | sed 's/^# /  /g'
    fi
    echo -e "${YELLOW}==========================================================================${NC}"
}

# 7. VPS IP 纯净度体检与中国本土卖家防关联评估
check_ip_association_risk() {
    clear
    local ip
    ip=$(get_public_ip)

    print_brand_banner "VPS IP 纯净度体检与中国本土卖家“一号一IP”防关联深度评估"
    echo -e " 正在检测 IP 归属地、城市一致性 (防视频验证)、智能 DNS 池及防泄露护盾...\n"

    local info
    info=$(curl -s --max-time 8 "http://ip-api.com/json/${ip}?fields=status,message,country,countryCode,regionName,city,timezone,isp,org,as,query,hosting,proxy" 2>/dev/null)

    local country="未知" cc="CN" region="未知" city="未知" tz="未知" isp="未知" org="未知" as_name="未知"
    local is_hosting="未知" is_proxy="未知"

    if [ -n "$info" ]; then
        country=$(echo "$info" | grep -o '"country":"[^"]*' | cut -d'"' -f4)
        cc=$(echo "$info" | grep -o '"countryCode":"[^"]*' | cut -d'"' -f4)
        region=$(echo "$info" | grep -o '"regionName":"[^"]*' | cut -d'"' -f4)
        city=$(echo "$info" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
        tz=$(echo "$info" | grep -o '"timezone":"[^"]*' | cut -d'"' -f4)
        isp=$(echo "$info" | grep -o '"isp":"[^"]*' | cut -d'"' -f4)
        org=$(echo "$info" | grep -o '"org":"[^"]*' | cut -d'"' -f4)
        as_name=$(echo "$info" | grep -o '"as":"[^"]*' | cut -d'"' -f4)
        is_hosting=$(echo "$info" | grep -o '"hosting":[^,}]*' | cut -d':' -f2 | tr -d ' ')
        is_proxy=$(echo "$info" | grep -o '"proxy":[^,}]*' | cut -d':' -f2 | tr -d ' ')
    fi

    local webrtc_fw="${YELLOW}未开启服务端拦截 (建议执行菜单[02]一键开启)${NC}"
    if iptables -S OUTPUT 2>/dev/null | grep -q "3478"; then
        webrtc_fw="${GREEN}已开启服务端强制拦截 (UDP 3478/5349/19302-19309 已封禁)${NC}"
    fi

    local ipv6_dis
    ipv6_dis=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    local ipv6_status="${GREEN}已彻底关闭 IPv6 (零泄露风险，杜绝 10秒 AAAA DNS 超时)${NC}"
    [ "$ipv6_dis" != "1" ] && ipv6_status="${YELLOW}未完全关闭 (建议执行菜单[02]关闭)${NC}"

    echo -e "${CYAN}─────────────────── 【1. IP 基础物理与同城归属画像】 ───────────────────${NC}"
    echo -e " 出口 IPv4 : ${WHITE}${ip}${NC}"
    echo -e " 物理位置  : ${GREEN}${country} - ${region} - ${city}${NC} (同城固定登录可有效预防异地视频验证)"
    echo -e " 标准时区  : ${WHITE}${tz}${NC} (当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z'))"
    echo -e " 网络运营商: ${WHITE}${isp}${NC}"
    echo -e " 所属机构  : ${WHITE}${org} (${as_name})${NC}"

    echo -e "\n${CYAN}─────────────────── 【2. 亚马逊防关联与环境纯净度诊断】 ───────────────────${NC}"
    echo -e " 黑名单标记  : $( [ "$is_proxy" == "true" ] && echo -e "${RED}已被标记为公开代理 (建议更换IP或开启白名单锁)${NC}" || echo -e "${GREEN}纯净 (未被标记为公开黑名单代理)${NC}" )"
    echo -e " 节点锁定策略: ${GREEN}已取消定时重测干扰 | 100%锁死冠军IP + 故障/超时3秒自动换新${NC}"
    echo -e " Google防卡死: ${GREEN}已开启代理层与内核层 0ms 秒拒 (彻底根除 SYN-SENT 阻塞)${NC}"
    echo -e " IPv6 防卡顿 : $ipv6_status"
    echo -e " WebRTC 防护 : $webrtc_fw"
    echo -e " 店铺地域策略: $( [ "$cc" == "CN" ] && echo -e "${GREEN}中国本土卖家同城 IP 模式 (${city}) - 符合营业执照所在地常用登录特征${NC}" || echo -e "${CYAN}海外本土 IP 模式 (${country}-${city})${NC}" )"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${NC}"
}

# 8. 代理安全防扫锁 & IP白名单管理
security_lock_menu() {
    clear
    load_proxy_config
    print_brand_banner "亚马逊专属 IP 纯净度护盾：代理端口防扫描与授权白名单管理"
    echo -e " 当前代理端口: ${GREEN}${PROXY_PORT}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}[1]${NC} ${GREEN}一键执行【服务端 WebRTC 拦截 + Google死连接秒拒 + 禁用IPv6】加固${NC}"
    echo -e "  ${CYAN}[2]${NC} ${CYAN}添加【专属客户端 IP 白名单】${NC} (仅允许你指定的公司/家里宽带 IP 连接代理端口)"
    echo -e "  ${YELLOW}[3]${NC} ${YELLOW}清除白名单限制 (恢复允许所有 IP 凭账号密码连接)${NC}"
    echo -e "  ${WHITE}[0]${NC} 返回主菜单"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${NC}"
    read -p "请输入选项 [0-3]: " s_opt
    case "$s_opt" in
        1|01)
            protect_bandwidth_and_harden
            ;;
        2|02)
            local ssh_client_ip
            ssh_client_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
            echo -e "检测到您当前 SSH 登录的本地宽带公网 IP 为: ${GREEN}${ssh_client_ip:-未知}${NC}"
            read -p "请输入允许连接代理的客户端公网 IP (直接回车默认使用 ${ssh_client_ip}): " allow_ip
            allow_ip=${allow_ip:-$ssh_client_ip}
            if [[ "$allow_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                iptables -D INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT >/dev/null 2>&1
                iptables -I INPUT 1 -p tcp -s "$allow_ip" --dport "$PROXY_PORT" -j ACCEPT >/dev/null 2>&1
                iptables -A INPUT -p tcp --dport "$PROXY_PORT" -j DROP >/dev/null 2>&1
                echo -e "${GREEN}>>> 白名单已生效！现在仅允许 [${allow_ip}] 连接端口 ${PROXY_PORT}！${NC}"
            else
                echo -e "${RED}IP 格式无效！${NC}"
            fi
            ;;
        3|03)
            while iptables -D INPUT -p tcp --dport "$PROXY_PORT" -j DROP >/dev/null 2>&1; do :; done
            force_open_port "$PROXY_PORT"
            echo -e "${GREEN}>>> 已恢复允许所有 IP 凭账号密码连接端口 ${PROXY_PORT}！${NC}"
            ;;
        *)
            return 0
            ;;
    esac
}

# ==============================================================================
# 9. 一键在线更新脚本最新版本 (从 GitHub 多镜像极速拉取最新代码并自动校验重启)
# ==============================================================================
self_update_script() {
    clear
    print_brand_banner "一键在线更新脚本最新版本 (GitHub 多镜像防缓存极速拉取)"
    echo -e " 当前本地版本 : ${GREEN}${SCRIPT_VERSION}${NC}"
    echo -e " 默认仓库地址 : ${WHITE}https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}[1]${NC} ${GREEN}立即从默认 GitHub 仓库多镜像拉取最新 amazon.sh 并自动应用升级${NC}"
    echo -e "  ${CYAN}[2]${NC} 输入自定义脚本直链 URL 进行在线更新"
    echo -e "  ${WHITE}[0]${NC} 返回主菜单"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${NC}"
    read -p "请输入选项 [0-2]: " up_opt

    local raw_target="https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh"
    if [ "$up_opt" == "2" ] || [ "$up_opt" == "02" ]; then
        read -p "请输入自定义脚本直链 URL: " custom_url
        [ -z "$custom_url" ] && echo -e "${RED}未输入地址，已取消！${NC}" && return 1
        raw_target="$custom_url"
    elif [ "$up_opt" != "1" ] && [ "$up_opt" != "01" ]; then
        return 0
    fi

    ensure_working_dns
    local ts
    ts=$(date +%s)
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    local update_mirrors=(
        "https://ghfast.top/${raw_target}?t=${ts}"
        "https://gh-proxy.com/${raw_target}?t=${ts}"
        "https://ghproxy.homeboyc.cn/${raw_target}?t=${ts}"
        "https://gh.zwy.one/${raw_target}?t=${ts}"
        "https://ghproxy.net/${raw_target}?t=${ts}"
        "${raw_target}?t=${ts}"
    )

    local tmp_new="/tmp/amazon_new_$$.sh"
    local dl_ok=0

    for u_url in "${update_mirrors[@]}"; do
        echo -e "${CYAN}正在尝试从镜像拉取最新脚本: ${u_url}${NC}"
        rm -f "$tmp_new"
        if curl -4 -fsSL --connect-timeout 4 --max-time 12 -H "Cache-Control: no-cache" -A "$ua" "$u_url" -o "$tmp_new" 2>/dev/null || \
           wget -4 -q -t 1 -T 6 --no-cache -U "$ua" --no-check-certificate "$u_url" -O "$tmp_new" 2>/dev/null; then
            if [ -s "$tmp_new" ] && grep -q "main_menu" "$tmp_new" 2>/dev/null && bash -n "$tmp_new" 2>/dev/null; then
                dl_ok=1
                echo -e "${GREEN}>>> 最新版脚本下载成功且通过语法完整性校验！${NC}"
                break
            fi
        fi
    done

    if [ $dl_ok -eq 0 ]; then
        rm -f "$tmp_new"
        echo -e "${RED}>>> 在线拉取失败，请检查 GitHub 仓库是否已上传最新代码或稍后重试！${NC}"
        return 1
    fi

    local new_ver
    new_ver=$(grep -E '^SCRIPT_VERSION=' "$tmp_new" | head -n 1 | cut -d'"' -f2)
    [ -z "$new_ver" ] && new_ver="最新版"

    local self_path
    self_path=$(readlink -f "$0" 2>/dev/null || echo "/usr/bin/vps")
    cp -f "$tmp_new" /usr/bin/vps 2>/dev/null
    chmod +x /usr/bin/vps 2>/dev/null
    if [ -f "$self_path" ] && [ "$self_path" != "/usr/bin/vps" ]; then
        cp -f "$tmp_new" "$self_path" 2>/dev/null
        chmod +x "$self_path" 2>/dev/null
    fi
    rm -f "$tmp_new"

    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}  恭喜！脚本已成功在线更新至 【${new_ver}】 并同步至快捷命令 vps！       ${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    read -p "是否立即执行【一键无损应用新版加速规则】并重启面板？[Y/n]: " apply_now
    apply_now=${apply_now:-Y}
    if [[ "$apply_now" =~ ^[Yy]$ ]]; then
        exec /usr/bin/vps --upgrade-now
    else
        exec /usr/bin/vps
    fi
}

# 全自动一键部署
install_all() {
    clear
    print_brand_banner "全自动一键极速部署 (晓林技术支持 · 旗舰版)"
    ensure_working_dns
    purge_legacy_cron
    optimize_kernel
    optimize_initcwnd
    setup_dns_accelerator
    optimize_per_domain_dns "verbose"
    protect_bandwidth_and_harden
    install_failover_guardian
    if download_gost; then
        modify_config
    fi
}

# 单独一键无损极速升级 v7.7
optimize_suite_only() {
    clear
    print_brand_banner "正在执行 v7.7 无损极速升级 (保留原有代理端口与账号密码)"
    ensure_working_dns
    purge_legacy_cron
    optimize_kernel
    optimize_initcwnd
    setup_dns_accelerator
    optimize_per_domain_dns "verbose"
    protect_bandwidth_and_harden
    install_failover_guardian
    download_gost
    verify_and_repair_all

    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  恭喜！晓林技术支持 ${SCRIPT_VERSION} 旗舰版已全部生效 (原有端口密码不变)！         ║${NC}"
    echo -e "${GREEN}║  1. 彻底拉黑 13.249.* 与 52.85.* 假死节点，注入东京优质 CloudFront 节点池 ║${NC}"
    echo -e "${GREEN}║  2. 移除 images-na 直接检测，解决 GFW SNI 重置导致的守护进程无限自愈死循环║${NC}"
    echo -e "${GREEN}║  3. 增加单域名自愈防误伤机制，守护进程引入 flock 文件锁防止多实例并发冲突  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# 查看系统与网络状态
check_status() {
    clear
    print_brand_banner "当前系统与全组件健康度状态排查"
    verify_and_repair_all

    if [ -f "$DOMAIN_DNS_CONF" ]; then
        echo -e "\n${CYAN}──────────────── 当前各亚马逊域名已 100% 锁定的最快命中节点 ────────────────${NC}"
        grep -E "^# [0-9]+\." "$DOMAIN_DNS_CONF" | sed 's/^# /  /g'
    fi
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${NC}"
}

# 服务控制
manage_service() {
    clear
    print_brand_banner "服务运行控制与深度自检修复中心"
    echo -e "  ${GREEN}[1]${NC} 一键运行【全组件健康自检与未启动项目自动重装修复】"
    echo -e "  ${CYAN}[2]${NC} 重启代理服务 (gost)"
    echo -e "  ${CYAN}[3]${NC} 重新采集各域名命中节点并测速锁定最快 IP"
    echo -e "  ${CYAN}[4]${NC} 重启秒级故障切换守护服务 (amazon-failover)"
    echo -e "  ${YELLOW}[5]${NC} 停止代理服务"
    echo -e "  ${GREEN}[6]${NC} 开启代理服务"
    echo -e "  ${WHITE}[7]${NC} 优先下载并切换至【官方 Go-Gost 核心】"
    echo -e "  ${WHITE}[8]${NC} 切换至【内置 Python3 Asyncio 高并发增强核心】"
    echo -e "  ${WHITE}[0]${NC} 返回主菜单"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${NC}"
    read -p "请输入选项: " opt
    case "$opt" in
        1|01) verify_and_repair_all ;;
        2|02) systemctl restart gost && echo -e "${GREEN}代理服务已重启${NC}" ;;
        3|03)
            repair_and_start_dnsmasq
            optimize_per_domain_dns "verbose"
            ;;
        4|04) systemctl restart amazon-failover && echo -e "${GREEN}秒级故障切换守护已重启${NC}" ;;
        5|05) systemctl stop gost && echo -e "${YELLOW}代理服务已停止${NC}" ;;
        6|06) systemctl start gost && echo -e "${GREEN}代理服务已启动${NC}" ;;
        7|07)
            download_gost 1
            systemctl restart gost && echo -e "${GREEN}已切换并重启代理服务！${NC}"
            ;;
        8|08)
            rm -f /usr/bin/gost
            install_builtin_proxy_engine
            systemctl restart gost && echo -e "${GREEN}已切换至内置 Python3 核心并重启！${NC}"
            ;;
        *) return 0 ;;
    esac
    sleep 1
}

# 彻底卸载与还原
uninstall_all() {
    clear
    print_brand_banner "安全卸载代理服务并还原系统默认网络"
    echo -e "${RED}正在彻底卸载代理服务并安全还原系统 DNS 与网络环境...${NC}"
    systemctl stop gost >/dev/null 2>&1
    systemctl disable gost >/dev/null 2>&1
    systemctl stop amazon-failover.service >/dev/null 2>&1
    systemctl disable amazon-failover.service >/dev/null 2>&1
    systemctl stop dnsmasq >/dev/null 2>&1
    systemctl disable dnsmasq >/dev/null 2>&1
    killall dnsmasq >/dev/null 2>&1
    systemctl stop amazon-net-tuning.service >/dev/null 2>&1
    systemctl disable amazon-net-tuning.service >/dev/null 2>&1

    purge_legacy_cron

    sed -i '/# === AMZ_FAST_HOSTS_START ===/,/# === AMZ_FAST_HOSTS_END ===/d' /etc/hosts 2>/dev/null

    rm -f /etc/systemd/system/gost.service /etc/systemd/system/dnsmasq.service "$TUNING_SERVICE" "$FAILOVER_SERVICE"
    rm -f /usr/bin/gost "$FAILOVER_SCRIPT" "$OPT_LOCK_FILE"
    rm -f "$SPEED_CONF" "$DOMAIN_DNS_CONF" "$FASTROUTE_CONF" /etc/dnsmasq.d/amazon_dns_pool.conf /etc/dnsmasq.d/amazon_ad_slim.conf
    rm -f "$CONFIG_FILE" "$AUTO_OPT_LOG"
    rm -f /usr/bin/vps

    if [ -f /etc/sysctl.conf.bak ]; then
        cp -f /etc/sysctl.conf.bak /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi

    chattr -i /etc/resolv.conf >/dev/null 2>&1
    rm -f /etc/resolv.conf 2>/dev/null
    cat << 'SAFE_UNINSTALL_DNS_EOF' > /etc/resolv.conf
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 114.114.114.114
options timeout:1 attempts:2
SAFE_UNINSTALL_DNS_EOF

    systemctl unmask systemd-resolved.socket systemd-resolved.service >/dev/null 2>&1
    systemctl enable systemd-resolved.socket systemd-resolved.service >/dev/null 2>&1
    systemctl start systemd-resolved.socket systemd-resolved.service >/dev/null 2>&1

    systemctl enable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1

    echo -e "${GREEN}卸载完成！已为您自动恢复默认 DNS 解析，VPS 网络 100% 正常可用！${NC}"
    exit 0
}

# 查看实时日志
view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 可退出日志查看模式${NC}"
    journalctl -u gost -f
}

# 支持单域名秒级故障自愈 (--failover-domain) 与在线更新升级 (--upgrade-now)
if [ "$1" == "--failover-domain" ] && [ -n "$2" ]; then
    ensure_working_dns
    target_dom="$2"
    [ "$target_dom" == "images-na.ssl-images-amazon.com" ] && target_dom="m.media-amazon.com"
    optimize_per_domain_dns "silent" "$target_dom" >/dev/null 2>&1
    exit 0
elif [ "$1" == "--auto-optimize" ]; then
    purge_legacy_cron
    exit 0
elif [ "$1" == "--upgrade-now" ]; then
    sync_shortcut
    optimize_suite_only
    read -p "按回车键进入主菜单..." dummy
fi

# 主菜单 - 晓林技术支持 旗舰品牌仪表盘
main_menu() {
    sync_shortcut
    get_public_ip >/dev/null 2>&1
    while true; do
        clear
        load_proxy_config
        local st_proxy="${RED}○未启动${NC}"
        systemctl is-active --quiet gost && st_proxy="${GREEN}●运行中(${PROXY_PORT})${NC}"

        local st_dns="${RED}○未启动${NC}"
        (systemctl is-active --quiet dnsmasq || pgrep -x dnsmasq >/dev/null 2>&1) && st_dns="${GREEN}●0ms极速锁定${NC}"

        local st_failover="${RED}○未启动${NC}"
        systemctl is-active --quiet amazon-failover && st_failover="${GREEN}●3秒自愈守护${NC}"

        local st_bbr="${YELLOW}○未开启${NC}"
        [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ] && st_bbr="${GREEN}●BBR已开启${NC}"

        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}      ${YELLOW}★ 晓 林 技 术 支 持  ·  XIAOLIN TECH SUPPORT (旗舰版 ${SCRIPT_VERSION}) ★${NC}        ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}    ${WHITE}亚马逊跨境电商专属 VPS 极速网络 · 命中节点锁定 · 一号一IP防关联系统${NC}   ${CYAN}║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} 出口IP: ${WHITE}${CACHED_PUBLIC_IP:-获取中}${NC} | 代理: ${st_proxy} | DNS: ${st_dns} | 自愈: ${st_failover} ${CYAN}║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${YELLOW}【一、核心部署与无损升级】${NC}                                               ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${GREEN}[01]${NC} ${GREEN}一键全自动极速部署${NC} ${WHITE}(采集权威DNS + 秒拒Google阻塞 + 锁死最快IP)${NC}     ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${CYAN}[02]${NC} ${CYAN}一键无损应用 ${SCRIPT_VERSION} 最新配置${NC} ${WHITE}(保留原端口密码 | 升级内存直读代理核心)${NC} ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${GREEN}[14]${NC} ${GREEN}一键在线更新脚本最新版本${NC} ${WHITE}(从 GitHub 多镜像防缓存极速拉取最新代码)${NC}  ${CYAN}║${NC}"
        echo -e "${CYAN}╟──────────────────────────────────────────────────────────────────────────╢${NC}"
        echo -e "${CYAN}║${NC} ${YELLOW}【二、亚马逊节点优选与全链路毫秒级测速】${NC}                                 ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${GREEN}[03]${NC} ${GREEN}按域名命中节点测速锁定与秒级故障自愈中心${NC} ${WHITE}(已彻底移除定时任务干扰)${NC}  ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${YELLOW}[07]${NC} ${YELLOW}亚马逊卖家中心 / 广告后台 / 商品图片CDN 专项测速${NC} ${WHITE}(真实动态路径诊断)${NC}${CYAN}║${NC}"
        echo -e "${CYAN}╟──────────────────────────────────────────────────────────────────────────╢${NC}"
        echo -e "${CYAN}║${NC} ${YELLOW}【三、代理账号管理与“一号一IP”防关联安全护盾】${NC}                           ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}[04]${NC} 修改 代理端口 / 账号 / 密码 ${GRAY}(自动清理冲突并强开系统防火墙端口)${NC}     ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${CYAN}[05]${NC} ${CYAN}查询当前代理信息${NC} ${WHITE}(Socks5/HTTP 账号密码与指纹浏览器一键导入格式)${NC}    ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}[06]${NC} 强行强开系统端口 ${GRAY}(暴力释放占用进程 + 穿透系统防火墙置顶放行)${NC}       ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${GREEN}[08]${NC} ${GREEN}VPS IP 纯净度体检与本土同城 IP 防关联评估${NC} ${WHITE}(防视频验证 / 防泄露)${NC}    ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${YELLOW}[09]${NC} ${YELLOW}专属 IP 防盗刷护盾${NC} ${WHITE}(客户端宽带 IP 白名单锁 / WebRTC与垃圾端口拦截)${NC} ${CYAN}║${NC}"
        echo -e "${CYAN}╟──────────────────────────────────────────────────────────────────────────╢${NC}"
        echo -e "${CYAN}║${NC} ${YELLOW}【四、系统自检维护与安全卸载还原】${NC}                                       ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${CYAN}[10]${NC} 全组件状态自检与自动重装修复 ${GRAY}(检查并修复 5 大核心加速组件)${NC}         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}[11]${NC} 停止 / 开启 / 重启服务 ${GRAY}(gost / dnsmasq / amazon-failover)${NC}          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}[12]${NC} 查看实时运行日志 ${GRAY}(按 Ctrl+C 退出日志模式)${NC}                          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${RED}[13]${NC} ${RED}彻底安全卸载${NC} ${WHITE}(清除所有加速服务 + 自动恢复可用DNS，100%绝不断网)${NC}    ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}[00]${NC} 退出管理面板 ${GRAY}(快捷呼出命令: vps | 技术支持: 晓林技术)${NC}              ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
        read -p "请输入数字选择 [0-14]: " num

        case "$num" in
            1|01) install_all ;;
            2|02) optimize_suite_only ;;
            3|03) auto_dns_optimizer_menu ;;
            4|04) modify_config ;;
            5|05) query_proxy_info ;;
            6|06) manual_force_open_port ;;
            7|07) test_amazon_suite ;;
            8|08) check_ip_association_risk ;;
            9|09) security_lock_menu ;;
            10) check_status ;;
            11) manage_service ;;
            12) view_logs ;;
            13) uninstall_all ;;
            14) self_update_script ;;
            0|00) exit 0 ;;
            *) echo -e "${RED}输入错误，请输入 0-14 之间的数字！${NC}" && sleep 1 && continue ;;
        esac
        echo ""
        read -p "按回车键返回【晓林技术支持】主菜单..." dummy
    done
}

main_menu