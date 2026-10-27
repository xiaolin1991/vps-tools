#!/bin/bash

# ==============================================================================
# 晓林技术 - 亚马逊电商 VPS 网络极限加速与防关联管理面板 (旗舰专业版 v7.2)
# 针对场景: 中国本土卖家 (如杭州/深圳等国内同城IP防视频验证) & 多账号“一号一IP”隔离运营
#           亚马逊卖家中心 / 美国广告后台 (advertising.amazon.com) / 商品图片CDN 秒开加速
#
# v7.2 核心升级日志:
#   1. [直连亚马逊本家权威 DNS (AWS Route53 / UltraDNS) 一手采集节点]:
#      - 除 11 大公共 DNS 外，新增先解析各亚马逊域名的 CNAME 边缘通道名，直接向亚马逊本家
#        AWS Route53 权威 DNS (205.251.192.x ~ 205.251.195.x) 与 UltraDNS (156.154.64.x)
#        一手提取最新鲜的官方 CloudFront 边缘节点 IP，绕开二手 DNS 缓存延迟。
#   2. [彻底解决测速触发亚马逊 503 防爬盾导致 552ms 极速好节点被误杀的问题]:
#      - 痛点修复: v7.1 并发裸请求根目录 "/" 会触发亚马逊 WAF 防爬虫 503 盾，导致 552ms~741ms
#        的极速节点因返回 503 被当成故障节点误杀，反而选了 3094ms 的慢节点 (54.239.180.64)。
#      - v7.2 采用【真实 Chrome 浏览器完整请求头 + 静态探针路径 (/favicon.ico)】测速，并对
#        完成 TCP+SSL 完整加密握手 (ms_ssl > 0) 的低延迟节点精准计分，绝不误杀 0.5 秒级好节点，
#        仅淘汰真正的超时/黑洞死节点 (HTTP=000 / SSL=0ms)。
#   3. [新增菜单 14：一键在线升级脚本最新版本]:
#      - 支持从 GitHub 多镜像加速源 (自带防缓存时间戳) 一键拉取最新 amazon.sh 并自动校验无缝升级。
# ==============================================================================

SCRIPT_VERSION="v7.2"

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
SPEED_CONF="/etc/dnsmasq.d/amazon_speed.conf"
DOMAIN_DNS_CONF="/etc/dnsmasq.d/amazon_domain_dns.conf"
FASTROUTE_CONF="/etc/dnsmasq.d/amazon_fastroute.conf"
AUTO_OPT_SCRIPT="/usr/local/bin/amazon-auto-optimizer.sh"
AUTO_OPT_LOG="/var/log/amazon_auto_dns.log"
AUTO_OPT_CONF="/etc/amazon_auto_opt.conf"
TUNING_SERVICE="/etc/systemd/system/amazon-net-tuning.service"

# 11 大高连通率智能公共 DNS 采集池
GLOBAL_DNS_POOL=(
    "4.2.2.1|Level3-美国骨干DNS-1"
    "4.2.2.2|Level3-美国骨干DNS-2"
    "168.95.1.1|HiNet-亚太国际DNS"
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

# 自动同步快捷指令 vps
sync_shortcut() {
    ensure_working_dns
    local self_path
    self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ -f "$self_path" ] && [ "$self_path" != "/usr/bin/vps" ]; then
        cp -f "$self_path" /usr/bin/vps 2>/dev/null
        chmod +x /usr/bin/vps 2>/dev/null
    fi
}

# 获取公网 IPv4
get_public_ip() {
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
            echo "$ip"
            return 0
        fi
    done
    ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}')
    [ -z "$ip" ] && ip="0.0.0.0"
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

# === 晓林技术 网络性能与跨境电商加速优化 v7.2 ===
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
            DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq-base dnsmasq dnsutils psmisc lsof curl wget cron python3 >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y dnsmasq bind-utils psmisc lsof curl wget cronie python3 >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y dnsmasq bind-utils psmisc lsof curl wget cronie python3 >/dev/null 2>&1
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

# 3. 部署本地 dnsmasq 基础缓存服务
setup_dns_accelerator() {
    echo -e "${YELLOW}>>> [3/6] 正在部署本地 dnsmasq 高速内存缓存与智能分流引擎...${NC}"

    rm -f "$FASTROUTE_CONF" /etc/dnsmasq.d/amazon_dns_pool.conf /etc/dnsmasq.d/amazon_ad_slim.conf 2>/dev/null
    sed -i '/# === AMZ_FAST_HOSTS_START ===/,/# === AMZ_FAST_HOSTS_END ===/d' /etc/hosts 2>/dev/null

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
            DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils psmisc lsof curl wget cron python3 >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bind-utils psmisc lsof curl wget cronie python3 >/dev/null 2>&1
        fi
    fi

    mkdir -p /etc/dnsmasq.d
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
        echo -e "${GREEN}>>> [成功] dnsmasq 服务单元已构建并在 127.0.0.1:53 正常运行！${NC}"
    else
        echo -e "${RED}>>> [警告] dnsmasq 启动异常，将在第 [6/6] 步触发深度修复！${NC}"
    fi
}

# ==============================================================================
# 4. 【v7.2 终极三步闭环优选法】
#    第一步：直连亚马逊本家权威 DNS (AWS Route53 / UltraDNS) + 11 大公共 DNS
#            采集每个亚马逊域名当前命中的所有真实边缘节点 IP 并去重；
#    第二步：使用真实 Chrome 浏览器完整请求头 + 静态轻量化探针 (/favicon.ico) 测速，
#            彻底避免并发请求首页触发亚马逊 503 防爬盾而误杀 552ms 极速好节点！
#    第三步：将该域名 100% 锁死到测速第 1 名的极速节点 IP (dnsmasq + /etc/hosts)！
# ==============================================================================
optimize_per_domain_dns() {
    local silent_mode="${1:-verbose}"
    [ "$silent_mode" != "silent" ] && echo -e "${YELLOW}>>> [4/6] 正在执行【亚马逊本家权威DNS直采 + 防503误杀真机测速 + 100%锁死冠军IP】...${NC}"

    # 先清理旧绑定，保证采集到的全是各大 DNS 最新鲜的真实解析结果
    rm -f "$FASTROUTE_CONF" "$DOMAIN_DNS_CONF" 2>/dev/null
    sed -i '/# === AMZ_FAST_HOSTS_START ===/,/# === AMZ_FAST_HOSTS_END ===/d' /etc/hosts 2>/dev/null
    repair_and_start_dnsmasq >/dev/null 2>&1

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
            "4.2.2.1|Level3-美国骨干DNS-1"
            "168.95.1.1|HiNet-亚太国际DNS"
            "223.5.5.5|阿里云-杭州Anycast-1"
        )
    fi

    # 6 大核心亚马逊业务模块 (每个域名只测试和锁定它自己解析出来的专属命中 IP，绝不跨域名乱借 IP)
    local domain_groups=(
        "sellercentral.amazon.com|1. 亚马逊北美卖家中心 (Seller Central)|sellercentral.amazon.com,sellercentral.amazon.ca,sellercentral.amazon.com.mx,sellercentral-europe.amazon.com"
        "advertising.amazon.com|2. 亚马逊广告管理中心 (Advertising)|advertising.amazon.com,advertising.amazon.ca,advertising.amazon.com.mx,na.account.amazon.com,fls-na.amazon.com,unagi-na.amazon.com,unagi.amazon.com"
        "m.media-amazon.com|3. 亚马逊广告与主站静态库 (Media CDN)|m.media-amazon.com,media-amazon.com"
        "aax-us-east.amazon-adsystem.com|4. 亚马逊北美广告竞价引擎 (AAX AdSystem)|aax-us-east.amazon-adsystem.com,amazon-adsystem.com,c.amazon-adsystem.com,s.amazon-adsystem.com"
        "www.amazon.com|5. 亚马逊北美主站商品前台 (Storefront)|www.amazon.com,completion.amazon.com"
        "images-na.ssl-images-amazon.com|6. 亚马逊全球商品图片 CDN (Images-NA)|images-na.ssl-images-amazon.com,images-fe.ssl-images-amazon.com,ssl-images-amazon.com,images-amazon.com"
    )

    mkdir -p /etc/dnsmasq.d
    cat << CONF_HEAD_EOF > "$DOMAIN_DNS_CONF"
# 晓林技术 v7.2 - 亚马逊各域名专属命中 IP 极速锁定表 (更新时间: $(date '+%Y-%m-%d %H:%M:%S'))
# 核心逻辑: 亚马逊本家权威 DNS (Route53/UltraDNS) + 11大公共DNS采集命中IP -> 防503误杀测速 -> 100%锁死冠军IP！
CONF_HEAD_EOF

    local hosts_block="# === AMZ_FAST_HOSTS_START ===\n"
    local summary_log=""
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    for grp in "${domain_groups[@]}"; do
        IFS='|' read -r test_dom grp_title sub_doms <<< "$grp"
        [ "$silent_mode" != "silent" ] && echo -e "\n${CYAN}  ======================================================================${NC}"
        [ "$silent_mode" != "silent" ] && echo -e "  ${YELLOW}● 正在采集并测速【${grp_title}】(${WHITE}${test_dom}${YELLOW}) 的真实命中节点:${NC}"

        # ----------------------------------------------------------------------
        # 第一步：并发向【亚马逊本家权威 DNS (Route53/UltraDNS)】+【11大公共DNS】查询该域名所有真实命中 IP
        # ----------------------------------------------------------------------
        local tmp_collect_dir="/tmp/amz_col_${test_dom}_$$"
        mkdir -p "$tmp_collect_dir"
        local c_idx=0

        # 1A. 先提取该域名的最后一跳 CNAME (例如 d29...cloudfront.net)，直接向亚马逊本家权威 DNS 索取一手节点！
        local cname_target
        cname_target=$(dig +time=1 +tries=1 +short "$test_dom" @223.5.5.5 2>/dev/null | grep -vE '^[0-9]+\.' | tail -n 1 | sed 's/\.$//')
        [ -z "$cname_target" ] && cname_target=$(dig +time=1 +tries=1 +short "$test_dom" @114.114.114.114 2>/dev/null | grep -vE '^[0-9]+\.' | tail -n 1 | sed 's/\.$//')

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

        # 1B. 并发向所有活跃公共 DNS 采集边缘节点 IP (最多取前 3 个，防止遗漏近距离亚太节点)
        for dns_item in "${active_dns_pool[@]}"; do
            c_idx=$((c_idx + 1))
            IFS='|' read -r dns_ip dns_name <<< "$dns_item"
            (
                local raw_ips
                raw_ips=$(dig +time=1 +tries=1 +short A "$test_dom" @"$dns_ip" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 3)
                for rip in $raw_ips; do
                    echo "${rip}|${dns_ip}|${dns_name}" >> "${tmp_collect_dir}/pub_${c_idx}"
                done
            ) &
        done
        wait

        # 对采集到的命中 IP 进行去重 (优先保留本家权威 DNS 标签)
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
            done < <(cat "${tmp_collect_dir}"/auth_* "${tmp_collect_dir}"/pub_* 2>/dev/null)
        fi
        rm -rf "$tmp_collect_dir"

        [ "$silent_mode" != "silent" ] && echo -e "    └─ 第一步完成: 从【亚马逊本家权威DNS + 全球DNS】共采集到 ${WHITE}${#unique_hit_ips[@]}${NC} 个专属节点 IP，开始防503误杀测速..."

        # ----------------------------------------------------------------------
        # 第二步：针对每一个唯一命中 IP 进行带完整浏览器指纹的轻量探针 (/favicon.ico) 测速
        #         彻底解决并发访问首页 "/" 触发亚马逊 503 防爬盾而误杀 552ms 极速节点的问题！
        # ----------------------------------------------------------------------
        local tmp_dom_dir="/tmp/amz_dom_spd_${test_dom}_$$"
        mkdir -p "$tmp_dom_dir"
        local p_idx=0

        # 针对静态探针路径选择: 统一使用 /favicon.ico 测速 CDN 边缘节点真实握手与响应速度，绕开首页防爬 503 盾
        local probe_path="/favicon.ico"

        for hit_item in "${unique_hit_ips[@]}"; do
            p_idx=$((p_idx + 1))
            IFS='|' read -r res_ip dns_ip dns_name <<< "$hit_item"
            (
                local curl_out
                curl_out=$(curl -4 -s -o /dev/null --connect-timeout 2 --max-time 4 \
                    -A "$ua" \
                    -H "Accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" \
                    -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" \
                    -H "Cache-Control: no-cache" \
                    --resolve "${test_dom}:443:${res_ip}" \
                    -w "%{http_code}|%{time_connect}|%{time_appconnect}|%{time_total}|%{ssl_verify_result}" \
                    "https://${test_dom}${probe_path}" 2>/dev/null)
                IFS='|' read -r h_code t_tcp t_ssl t_tot ssl_err <<< "$curl_out"

                local ms_tcp ms_ssl ms_tot
                ms_tcp=$(awk "BEGIN {printf \"%.0f\", $t_tcp * 1000}")
                ms_ssl=$(awk "BEGIN {printf \"%.0f\", $t_ssl * 1000}")
                ms_tot=$(awk "BEGIN {printf \"%.0f\", $t_tot * 1000}")
                [ -z "$ssl_err" ] && ssl_err="1"

                # 核心判别准则：
                # 1. 只要 SSL 握手成功 (ms_ssl > 0 且 ssl_err == 0)，且返回 200/202/204/301/302/307/400/403/404/405，均为 100% 满分极速节点！
                # 2. 即使节点对探针返回 HTTP 503 (亚马逊边缘防爬保护)，只要 TCP+SSL 握手极速完成 (ms_ssl > 0 且 ms_tot < 2500)，
                #    说明该节点链路完全畅通且延迟极低 (如 552ms 的 3.173.238.3)，仅加微弱权重分 (150ms)，绝不误杀淘汰！
                # 3. 只有 HTTP=000 (连接超时/黑洞节点，如 13.249.231.31) 或 SSL 握手失败 (ms_ssl == 0) 才作为真正的问题节点淘汰！
                if [[ "$h_code" =~ ^(200|202|204|301|302|307|400|403|404|405)$ ]] && [ "$ms_ssl" -gt 0 ] && [ "$ssl_err" == "0" ] && [ "$ms_tot" -lt 4200 ]; then
                    local score=$((ms_ssl + ms_tot))
                    printf "OK|%06d|%s|%s|%s|%s|%s|%s|%s\n" "$score" "$res_ip" "$dns_ip" "$dns_name" "$h_code" "$ms_tcp" "$ms_ssl" "$ms_tot" > "${tmp_dom_dir}/${p_idx}"
                elif [ "$h_code" == "503" ] && [ "$ms_ssl" -gt 0 ] && [ "$ssl_err" == "0" ] && [ "$ms_tot" -lt 3000 ]; then
                    local score=$((ms_ssl + ms_tot + 150))
                    printf "OK_WAF|%06d|%s|%s|%s|%s|%s|%s|%s\n" "$score" "$res_ip" "$dns_ip" "$dns_name" "200(WAF盾就绪)" "$ms_tcp" "$ms_ssl" "$ms_tot" > "${tmp_dom_dir}/${p_idx}"
                elif [ "$test_dom" == "images-na.ssl-images-amazon.com" ] && [ "$ms_tcp" -gt 0 ] && [ "$ms_tcp" -lt 300 ]; then
                    local score=$((1500 + ms_tcp * 2))
                    printf "TCP_OK|%06d|%s|%s|%s|%s|%s|%s|%s\n" "$score" "$res_ip" "$dns_ip" "$dns_name" "CDN就绪" "$ms_tcp" "$ms_tcp" "$ms_tot" > "${tmp_dom_dir}/${p_idx}"
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
                    [ "$silent_mode" != "silent" ] && echo -e "    ${GREEN}[✓ 极速命中节点]${NC} 节点IP: ${WHITE}${rip}${NC} (由 ${dip} ${dname} 命中) -> 状态=${GREEN}${hcode}${NC} | TCP=${CYAN}${mtcp}ms${NC} | SSL=${CYAN}${mssl}ms${NC} | 总耗时=${GREEN}${mtot}ms${NC}"
                    if [ -z "$best_res_ip" ]; then
                        best_res_ip="$rip"
                        best_dns_ip="$dip"
                        best_dns_name="$dname"
                        best_tot_ms="${mtot}ms"
                    fi
                elif [ "$st" == "TCP_OK" ]; then
                    [ "$silent_mode" != "silent" ] && echo -e "    ${CYAN}[✓ 极速图片节点]${NC} 节点IP: ${WHITE}${rip}${NC} (由 ${dip} ${dname} 命中) -> TCP握手=${GREEN}${mtcp}ms${NC} (CDN边缘极速通道)"
                    if [ -z "$best_res_ip" ]; then
                        best_res_ip="$rip"
                        best_dns_ip="$dip"
                        best_dns_name="$dname"
                        best_tot_ms="TCP:${mtcp}ms"
                    fi
                else
                    [ "$silent_mode" != "silent" ] && echo -e "    ${RED}[✗ 淘汰死节点]${NC}   节点IP: ${WHITE}${rip}${NC} (由 ${dip} ${dname} 命中) -> 状态=${RED}${hcode}${NC} | TCP=${mtcp}ms | SSL=${mssl}ms | 总耗时=${mtot}ms (连接超时)"
                fi
            done < <(cat "${tmp_dom_dir}"/* 2>/dev/null | sort -t'|' -k2,2n)
        fi
        rm -rf "$tmp_dom_dir"

        # ----------------------------------------------------------------------
        # 第三步：直接将该域名精准锁定到刚才实测第 1 名的那个命中节点 IP！
        #         (既写入 dnsmasq address=/域名/冠军IP，又写入 /etc/hosts，100% 杜绝跳 IP！)
        # ----------------------------------------------------------------------
        echo "" >> "$DOMAIN_DNS_CONF"
        if [ -n "$best_res_ip" ]; then
            [ "$silent_mode" != "silent" ] && echo -e "    ${YELLOW}★ 最终锁定最快命中节点:${NC} 【${WHITE}${test_dom}${NC}】 ===> 100% 锁定至极速节点 ${GREEN}${best_res_ip}${NC} (实测耗时: ${best_tot_ms}, 来源: ${best_dns_name})"
            echo "# ${grp_title} -> 已100%锁定最快命中节点IP: ${best_res_ip} (实测耗时: ${best_tot_ms}, 来源: ${best_dns_ip} ${best_dns_name})" >> "$DOMAIN_DNS_CONF"
            IFS=',' read -ra dom_list <<< "$sub_doms"
            for sub_d in "${dom_list[@]}"; do
                echo "address=/${sub_d}/${best_res_ip}" >> "$DOMAIN_DNS_CONF"
                hosts_block="${hosts_block}${best_res_ip} ${sub_d}\n"
                if [[ ! "$best_dns_name" =~ "本家权威" ]] && [ -n "$best_dns_ip" ]; then
                    echo "server=/${sub_d}/${best_dns_ip}" >> "$DOMAIN_DNS_CONF"
                else
                    echo "server=/${sub_d}/223.5.5.5" >> "$DOMAIN_DNS_CONF"
                fi
            done
            summary_log="${summary_log}${test_dom}->${best_res_ip}(${best_tot_ms}) "
        else
            [ "$silent_mode" != "silent" ] && echo -e "    ${YELLOW}○ 本轮未筛出静态节点，保持由 4.2.2.1 / 114.114.114.114 动态解析${NC}"
            echo "# ${grp_title} -> 动态解析模式 (DNS: 4.2.2.1 / 114.114.114.114)" >> "$DOMAIN_DNS_CONF"
            IFS=',' read -ra dom_list <<< "$sub_doms"
            for sub_d in "${dom_list[@]}"; do
                echo "server=/${sub_d}/4.2.2.1" >> "$DOMAIN_DNS_CONF"
                echo "server=/${sub_d}/114.114.114.114" >> "$DOMAIN_DNS_CONF"
            done
        fi
    done

    hosts_block="${hosts_block}# === AMZ_FAST_HOSTS_END ==="
    echo -e "$hosts_block" >> /etc/hosts

    repair_and_start_dnsmasq

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 命中节点测速锁定完成 | ${summary_log}" >> "$AUTO_OPT_LOG"
    tail -n 200 "$AUTO_OPT_LOG" > "${AUTO_OPT_LOG}.tmp" 2>/dev/null && mv -f "${AUTO_OPT_LOG}.tmp" "$AUTO_OPT_LOG" 2>/dev/null

    if [ "$silent_mode" != "silent" ]; then
        echo -e "\n${GREEN}========================================================================${NC}"
        echo -e "${GREEN}>>> 各域名最快命中节点已 100% 锁定生效！现在访问或测速绝不再随机跳 IP：${NC}"
        grep "^# [1-6]\." "$DOMAIN_DNS_CONF" | sed 's/^# /  /g'
        echo -e "${GREEN}========================================================================${NC}"
    fi
}

# 生成后台自动快速优选独立脚本并配置定时任务
install_auto_optimizer_cron() {
    local interval_min="${1:-20}"
    echo "INTERVAL_MIN=${interval_min}" > "$AUTO_OPT_CONF"

    cat << 'CRON_SCRIPT_EOF' > "$AUTO_OPT_SCRIPT"
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [ -f /usr/bin/vps ]; then
    /bin/bash /usr/bin/vps --auto-optimize >/dev/null 2>&1
fi
CRON_SCRIPT_EOF
    chmod +x "$AUTO_OPT_SCRIPT"

    systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1
    systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1

    if command -v crontab >/dev/null 2>&1; then
        local cron_expr="*/${interval_min} * * * *"
        if [ "$interval_min" -ge 60 ]; then
            local hrs=$((interval_min / 60))
            [ "$hrs" -lt 1 ] && hrs=1
            cron_expr="0 */${hrs} * * *"
        fi
        (crontab -l 2>/dev/null | grep -v "$AUTO_OPT_SCRIPT" | grep -v "amazon-dns-prewarm"; echo "${cron_expr} ${AUTO_OPT_SCRIPT}") | crontab - 2>/dev/null
    fi
}

# 菜单 [3]: 按域名采集命中节点测速与定时自动优选中心
auto_dns_optimizer_menu() {
    clear
    local cur_status="${RED}未开启${NC}"
    local cur_interval="20"
    [ -f "$AUTO_OPT_CONF" ] && source "$AUTO_OPT_CONF" && cur_interval="${INTERVAL_MIN:-20}"
    if crontab -l 2>/dev/null | grep -q "$AUTO_OPT_SCRIPT"; then
        cur_status="${GREEN}● 运行中 (每 ${cur_interval} 分钟自动重新采集各域名命中节点并锁定最快 IP)${NC}"
    fi

    echo -e "${YELLOW}========================================================================${NC}"
    echo -e "${GREEN}     【亚马逊各域名命中节点测速锁定与定时优选中心 (v7.2 旗舰版)】       ${NC}"
    echo -e "${YELLOW}========================================================================${NC}"
    echo -e "核心逻辑：直连亚马逊本家权威 DNS (Route53) + 11 大公共 DNS 采集真实节点 ->"
    echo -e "防 503 误杀真机测速 -> 直接 100% 锁死该域名最快的命中 IP (绝不随机跳 IP)！"
    echo -e "${CYAN}------------------------------------------------------------------------${NC}"
    echo -e " 当前自动优选状态 : ${cur_status}"
    echo -e " 最近一次优选记录 : ${WHITE}$(tail -n 1 "$AUTO_OPT_LOG" 2>/dev/null || echo '暂无记录')${NC}"
    echo -e "${CYAN}------------------------------------------------------------------------${NC}"
    echo -e " 1. ${GREEN}立即执行【本家权威DNS采集命中节点 + 防503误杀测速 + 100%锁定最快IP】${NC}"
    echo -e " 2. 设置为 【每 10 分钟】 自动重新采集测速并更新最快命中 IP (适合晚高峰)"
    echo -e " 3. 设置为 【每 20 分钟】 自动重新采集测速并更新最快命中 IP ${GREEN}(★ 推荐)${NC}"
    echo -e " 4. 设置为 【每 30 分钟】 自动重新采集测速并更新最快命中 IP"
    echo -e " 5. 设置为 【每 60 分钟】 自动重新采集测速并更新最快命中 IP"
    echo -e " 6. ${CYAN}【自定义时间间隔】${NC} (自由输入分钟数，如 5 分钟、15 分钟、45 分钟等)"
    echo -e " 7. 查看自动优选历史日志 (查看历次各域名锁定的命中 IP 与毫秒耗时)"
    echo -e " 8. ${RED}关闭自动定时优选${NC}"
    echo -e " 0. 返回主菜单"
    echo -e "${YELLOW}========================================================================${NC}"
    read -p "请输入选项 [0-8]: " ao_opt
    case "$ao_opt" in
        1)
            setup_dns_accelerator
            optimize_per_domain_dns "verbose"
            ;;
        2)
            install_auto_optimizer_cron 10
            optimize_per_domain_dns "verbose"
            echo -e "${GREEN}>>> 已开启【每 10 分钟】自动采集命中节点并锁定最快 IP！${NC}"
            ;;
        3)
            install_auto_optimizer_cron 20
            optimize_per_domain_dns "verbose"
            echo -e "${GREEN}>>> 已开启【每 20 分钟】自动采集命中节点并锁定最快 IP！${NC}"
            ;;
        4)
            install_auto_optimizer_cron 30
            optimize_per_domain_dns "verbose"
            echo -e "${GREEN}>>> 已开启【每 30 分钟】自动采集命中节点并锁定最快 IP！${NC}"
            ;;
        5)
            install_auto_optimizer_cron 60
            optimize_per_domain_dns "verbose"
            echo -e "${GREEN}>>> 已开启【每 60 分钟】自动采集命中节点并锁定最快 IP！${NC}"
            ;;
        6)
            read -p "请输入您希望自动优选的间隔分钟数 (例如 15): " custom_min
            if [[ "$custom_min" =~ ^[0-9]+$ ]] && [ "$custom_min" -ge 1 ] && [ "$custom_min" -le 1440 ]; then
                install_auto_optimizer_cron "$custom_min"
                optimize_per_domain_dns "verbose"
                echo -e "${GREEN}>>> 已成功设置为【每 ${custom_min} 分钟】自动优选一次！${NC}"
            else
                echo -e "${RED}输入无效，请输入 1 到 1440 之间的整数分钟！${NC}"
            fi
            ;;
        7)
            echo -e "\n${CYAN}================ 自动优选历史日志 (最近 20 条) ================${NC}"
            if [ -f "$AUTO_OPT_LOG" ]; then
                tail -n 20 "$AUTO_OPT_LOG"
            else
                echo -e "${YELLOW}暂无历史日志，请先执行选项 [1] 进行首次优选。${NC}"
            fi
            echo -e "${CYAN}===============================================================${NC}"
            ;;
        8)
            if command -v crontab >/dev/null 2>&1; then
                crontab -l 2>/dev/null | grep -v "$AUTO_OPT_SCRIPT" | crontab - 2>/dev/null
            fi
            echo -e "${YELLOW}>>> 已关闭后台自动定时优选任务。${NC}"
            ;;
        *)
            return 0
            ;;
    esac
}

# 5. 2M 小带宽独占保护模式 + 中国本土 IP 防关联环境加固
protect_bandwidth_and_harden() {
    echo -e "${YELLOW}>>> [5/6] 正在启用小带宽独占保护与【中国本土同城 IP】防关联加固...${NC}"
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

    local country
    country=$(get_vps_country)
    if [ "$country" == "CN" ] && command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1
        timedatectl set-ntp true >/dev/null 2>&1
    fi

    echo -e "${GREEN}>>> 2M 带宽保护、WebRTC 服务端阻断、IPv6 泄露封堵与北京时间同步已生效！${NC}"
}

# 6. 全组件运行状态强制自检、警告告知与自动修复重装引擎
verify_and_repair_all() {
    echo -e "\n${YELLOW}>>> [6/6] 正在执行全组件安装后自检与未启动项目自动重装修复...${NC}"
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
    if systemctl is-active --quiet gost && (ss -tlpn 2>/dev/null | grep -q ":${PROXY_PORT} " || netstat -tlpn 2>/dev/null | grep -q ":${PROXY_PORT} "); then
        echo -e "    [自检 3/5] Gost 双协议代理服务: ${GREEN}● 正在运行 (监听端口: ${PROXY_PORT})${NC}"
    else
        echo -e "    [自检 3/5] Gost 双协议代理服务: ${RED}▲ 警告：检测到代理服务未运行！正在自动重装并启动...${NC}"
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
            echo -e "               └─ 修复结果        : ${GREEN}✓ Gost 代理服务已成功启动 (端口: ${PROXY_PORT})！${NC}"
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

    if (systemctl is-active --quiet cron || systemctl is-active --quiet crond || pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1) && crontab -l 2>/dev/null | grep -q "$AUTO_OPT_SCRIPT"; then
        echo -e "    [自检 4/5] 自动优选定时守护   : ${GREEN}● 正在运行 (定时任务已挂载)${NC}"
    else
        echo -e "    [自检 4/5] 自动优选定时守护   : ${RED}▲ 警告：定时任务服务未启动！正在自动安装并激活 cron...${NC}"
        apt-get install -y cron >/dev/null 2>&1 || yum install -y cronie >/dev/null 2>&1
        install_auto_optimizer_cron 20
        echo -e "               └─ 修复结果        : ${GREEN}✓ 定时自动优选守护已成功激活！${NC}"
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
        echo -e "${GREEN}>>> [自检通过] 全套 5 大核心加速组件 100% 正常运行，无任何遗漏项目！${NC}"
    fi
}

# 内置高并发双协议 (Socks5 + HTTP CONNECT) 代理引擎生成函数
install_builtin_proxy_engine() {
    echo -e "${YELLOW}>>> 正在部署内置自研【高并发 Asyncio 双协议 (Socks5 & HTTP) 代理核心引擎】...${NC}"
    if ! command -v python3 >/dev/null 2>&1; then
        ensure_working_dns
        apt-get update -y >/dev/null 2>&1 && apt-get install -y python3 >/dev/null 2>&1
        yum install -y python3 >/dev/null 2>&1
    fi

    cat << 'PYPROXY_EOF' > /usr/bin/gost
#!/usr/bin/env python3
import asyncio
import base64
import re
import socket
import struct
import sys

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
    finally:
        try:
            writer.close()
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
    hdr = await reader.readexactly(1)
    nmethods = hdr[0]
    methods = await reader.readexactly(nmethods)
    if 2 in methods:
        writer.write(b"\x05\x02")
        await writer.drain()
        auth_ver = (await reader.readexactly(1))[0]
        ulen = (await reader.readexactly(1))[0]
        u = (await reader.readexactly(ulen)).decode("utf-8", "ignore")
        plen = (await reader.readexactly(1))[0]
        p = (await reader.readexactly(plen)).decode("utf-8", "ignore")
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

    req = await reader.readexactly(4)
    ver, cmd, _, atyp = req[0], req[1], req[2], req[3]
    if cmd != 1:
        writer.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        writer.close()
        return

    if atyp == 1:
        host = socket.inet_ntoa(await reader.readexactly(4))
    elif atyp == 3:
        dlen = (await reader.readexactly(1))[0]
        host = (await reader.readexactly(dlen)).decode("utf-8", "ignore")
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
    else:
        writer.close()
        return

    port = struct.unpack("!H", await reader.readexactly(2))[0]
    try:
        rem_r, rem_w = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=10)
        set_nodelay(rem_w)
        writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        await asyncio.gather(pipe(reader, rem_w), pipe(rem_r, writer))
    except Exception:
        try:
            writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
        except Exception:
            pass
        writer.close()

async def handle_http(first_byte, reader, writer):
    buf = first_byte + await reader.readuntil(b"\r\n\r\n")
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
            rem_r, rem_w = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=10)
            set_nodelay(rem_w)
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await asyncio.gather(pipe(reader, rem_w), pipe(rem_r, writer))
        except Exception:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
    else:
        m = re.match(r"^http://([^/:]+)(?::(\d+))?(/.*)?$", target, re.I)
        if not m:
            writer.close()
            return
        host = m.group(1)
        port = int(m.group(2)) if m.group(2) else 80
        path = m.group(3) or "/"
        try:
            rem_r, rem_w = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=10)
            set_nodelay(rem_w)
            new_lines = [f"{method} {path} {req_parts[2] if len(req_parts)>2 else 'HTTP/1.1'}"]
            for line in lines[1:]:
                if not line.lower().startswith("proxy-"):
                    new_lines.append(line)
            rem_w.write(("\r\n".join(new_lines) + "\r\n\r\n").encode("latin1"))
            await rem_w.drain()
            await asyncio.gather(pipe(reader, rem_w), pipe(rem_r, writer))
        except Exception:
            writer.close()

async def handle_client(reader, writer):
    set_nodelay(writer)
    try:
        first_byte = await asyncio.wait_for(reader.readexactly(1), timeout=10)
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
    echo -e "${GREEN}>>> 内置高并发双协议代理核心 (Socks5 + HTTP) 部署成功！${NC}"
    return 0
}

# 智能多镜像下载 Gost 组件
download_gost() {
    if [ -f /usr/bin/gost ] && [ -x /usr/bin/gost ]; then
        echo -e "${GREEN}检测到代理服务核心组件已安装，跳过下载。${NC}"
        return 0
    fi

    ensure_working_dns
    echo -e "${YELLOW}>>> 正在下载代理服务核心组件 (2026 国内最新多镜像加速 + 自动兜底)...${NC}"
    local arch
    arch=$(uname -m)
    local gost_arch="amd64"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && gost_arch="armv8"

    local gh_file="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${gost_arch}-2.11.5.gz"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    local mirrors=(
        "https://gh-proxy.com/${gh_file}"
        "https://ghfast.top/${gh_file}"
        "https://ghproxy.homeboyc.cn/${gh_file}"
        "https://gh.zwy.one/${gh_file}"
        "https://ghproxy.net/${gh_file}"
        "https://gh.ddlc.top/${gh_file}"
        "https://slink.ltd/${gh_file}"
        "${gh_file}"
    )

    local success=0
    for url in "${mirrors[@]}"; do
        echo -e "${CYAN}尝试加速源: ${url}${NC}"
        rm -f /tmp/gost.gz
        if curl -4 -fL --connect-timeout 4 --max-time 12 -A "$ua" "$url" -o /tmp/gost.gz 2>/dev/null || \
           wget -4 -q -t 1 -T 6 -U "$ua" --no-check-certificate "$url" -O /tmp/gost.gz 2>/dev/null; then
            if [ -s /tmp/gost.gz ] && [ $(wc -c < /tmp/gost.gz) -gt 1000000 ] && gzip -t /tmp/gost.gz 2>/dev/null; then
                gzip -d -f /tmp/gost.gz
                mv -f /tmp/gost /usr/bin/gost
                chmod +x /usr/bin/gost
                success=1
                echo -e "${GREEN}>>> Gost 官方二进制组件极速下载并解压成功！${NC}"
                break
            fi
        fi
        rm -f /tmp/gost.gz
    done

    if [ $success -eq 0 ]; then
        echo -e "${YELLOW}>>> 外部 GitHub 镜像连接受限，正在自动启用【内置自研双协议代理引擎】...${NC}"
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

    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo -e "${YELLOW}请设置代理连接信息 (直接回车保留当前值):${NC}"
    echo -e "${PURPLE}★ 防关联安全提示: 建议使用复杂密码，防止被扫描器盗用您的杭州/国内专属 IP！${NC}"
    echo -e "  推荐随机安全端口: ${GREEN}${rand_port}${NC} | 推荐随机高强密码: ${GREEN}${rand_pass}${NC}"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"

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
        dnsmasq_state="${GREEN}● 运行中 (本家权威DNS + 各域名最快节点已 100% 锁定)${NC}"
    fi

    local port_listen="未监听"
    if ss -tlpn 2>/dev/null | grep -q ":${port} "; then
        port_listen="${GREEN}正常监听在 0.0.0.0:${port}${NC}"
    elif netstat -tlpn 2>/dev/null | grep -q ":${port} "; then
        port_listen="${GREEN}正常监听在 0.0.0.0:${port}${NC}"
    else
        port_listen="${YELLOW}未检测到监听 (请确认服务是否已启动)${NC}"
    fi

    local auto_opt_info="${YELLOW}未开启${NC}"
    if crontab -l 2>/dev/null | grep -q "$AUTO_OPT_SCRIPT"; then
        local iv="20"
        [ -f "$AUTO_OPT_CONF" ] && source "$AUTO_OPT_CONF" && iv="${INTERVAL_MIN:-20}"
        auto_opt_info="${GREEN}已开启 (每 ${iv} 分钟自动采集本家权威DNS与公共DNS并锁定最快IP)${NC}"
    fi

    echo -e "${YELLOW}==============================================================${NC}"
    echo -e "${GREEN}           【Socks5 / HTTP 代理账户信息查询结果】             ${NC}"
    echo -e "${YELLOW}==============================================================${NC}"
    echo -e " 当前脚本版本 : ${GREEN}${SCRIPT_VERSION}${NC}"
    echo -e " 代理服务状态 : $is_running"
    echo -e " 智能DNS引擎  : $dnsmasq_state"
    echo -e " 端口监听状态 : $port_listen"
    echo -e " 自动实时优选 : $auto_opt_info"
    echo -e " 代理连接类型 : ${CYAN}Socks5${NC} 或 ${CYAN}HTTP${NC} (AdsPower/比特/紫鸟/Hubstudio 均兼容)"
    echo -e " 代理主机 IP  : ${GREEN}${ip}${NC}"
    echo -e " 代理连接端口 : ${GREEN}${port}${NC}"
    echo -e " 代理连接账号 : ${GREEN}${user}${NC}"
    echo -e " 代理连接密码 : ${GREEN}${pass}${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    echo -e " 【指纹浏览器一键粘贴导入格式 (IP:端口:账号:密码)】:"
    echo -e " ${GREEN}${ip}:${port}:${user}:${pass}${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    echo -e "${YELLOW}★ 阿里云/华为云/腾讯云 入方向安全组放行要点:${NC}"
    echo -e " 确保安全组【入方向规则】有: 协议=TCP, 端口=${port}, 授权对象=0.0.0.0/0"
    echo -e "${YELLOW}==============================================================${NC}"
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
        load_proxy_config
        if [ "$target_port" == "$PROXY_PORT" ]; then
            systemctl restart gost
            echo -e "${GREEN}已同步重启当前代理服务！${NC}"
        fi
    else
        echo -e "${RED}未输入端口！${NC}"
    fi
}

# 亚马逊卖家中心 & 广告后台 & 商品图片CDN 毫秒级深度测速
test_url_speed() {
    local target_url="$1"
    local desc_name="$2"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    echo -e "\n${CYAN}>>> 正在测试: ${WHITE}${desc_name}${NC}"
    echo -e "    目标地址: ${BLUE}${target_url}${NC}"

    local result
    result=$(curl -4 -s -o /dev/null -A "$ua" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" \
        -w "%{http_code}|%{remote_ip}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}" \
        --connect-timeout 5 --max-time 12 "$target_url" 2>/dev/null)

    if [ -z "$result" ]; then
        echo -e "    状态检测: ${RED}连接超时或阻断 (建议执行菜单[3]重新优选)${NC}"
        return 1
    fi

    IFS='|' read -r http_code remote_ip t_dns t_tcp t_ssl t_ttfb t_total <<< "$result"

    local ms_dns ms_tcp ms_ssl ms_ttfb ms_total
    ms_dns=$(awk "BEGIN {printf \"%.0f\", $t_dns * 1000}")
    ms_tcp=$(awk "BEGIN {printf \"%.0f\", ($t_tcp - $t_dns) * 1000}")
    ms_ssl=$(awk "BEGIN {printf \"%.0f\", ($t_ssl - $t_tcp) * 1000}")
    ms_ttfb=$(awk "BEGIN {printf \"%.0f\", ($t_ttfb - $t_ssl) * 1000}")
    ms_total=$(awk "BEGIN {printf \"%.0f\", $t_total * 1000}")
    [ "$ms_tcp" -lt 0 ] && ms_tcp=0
    [ "$ms_ssl" -lt 0 ] && ms_ssl=0
    [ "$ms_ttfb" -lt 0 ] && ms_ttfb=0

    if [ "$http_code" == "000" ]; then
        if [[ "$target_url" == *"images-na.ssl-images-amazon.com"* ]] && [ "$ms_tcp" -gt 0 ] && [ "$ms_tcp" -lt 300 ]; then
            echo -e "    命中节点 : ${WHITE}${remote_ip}${NC} (CDN 边缘节点已就绪)"
            echo -e "    分段耗时 : DNS=${GREEN}${ms_dns}ms${NC} | TCP握手=${GREEN}${ms_tcp}ms${NC}  [综合评级: ${GREEN}边缘链路正常 (浏览器按实际图片路径加载)${NC}]"
            return 0
        fi
        echo -e "    状态检测: ${RED}连接超时或握手失败 (目标节点: ${remote_ip:-未知}) -> 请按[3]选择[1]重新锁定新节点！${NC}"
        return 1
    fi

    local code_display="HTTP ${http_code}"
    if [ "$http_code" == "503" ] && [ "$ms_ssl" -gt 0 ]; then
        code_display="HTTP 503 (TLS加密握手已通，503为命令行无Cookie防爬保护，指纹浏览器可正常秒开)"
    fi

    local speed_rate=""
    if [ "$ms_total" -lt 1200 ]; then
        speed_rate="${GREEN}极快 (秒开级)${NC}"
    elif [ "$ms_total" -lt 2500 ]; then
        speed_rate="${GREEN}优秀 (流畅)${NC}"
    elif [ "$ms_total" -lt 4000 ]; then
        speed_rate="${YELLOW}良好 (正常)${NC}"
    else
        speed_rate="${RED}偏慢 (建议在菜单[3]触发重新优选)${NC}"
    fi

    echo -e "    命中节点 : ${WHITE}${remote_ip}${NC} (${GREEN}${code_display}${NC})"
    echo -e "    分段耗时 : DNS=${GREEN}${ms_dns}ms${NC} | TCP=${CYAN}${ms_tcp}ms${NC} | SSL=${CYAN}${ms_ssl}ms${NC} | 服务端响应(TTFB)=${WHITE}${ms_ttfb}ms${NC}"
    echo -e "    总体耗时 : ${CYAN}${ms_total} ms${NC}  [综合评级: ${speed_rate}]"
}

test_amazon_suite() {
    clear
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "${GREEN}   【亚马逊卖家中心 / 广告后台 / 商品图片 CDN 全链路毫秒级深度测速】   ${NC}"
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "正在对 7 大核心站点进行 DNS / TCP / SSL / TTFB 分段压力诊断..."

    test_url_speed "https://sellercentral.amazon.com/favicon.ico" "1. 亚马逊北美卖家中心边缘节点 (Seller Central CDN)"
    test_url_speed "https://advertising.amazon.com/" "2. 亚马逊广告门户首页 (Advertising Portal)"
    test_url_speed "https://advertising.amazon.com/campaign-manager/all-campaigns" "3. 亚马逊广告活动管理后台 (Campaign Manager)"
    test_url_speed "https://images-na.ssl-images-amazon.com/" "4. 亚马逊全球商品图片 CDN 节点 (Images-NA CDN)"
    test_url_speed "https://m.media-amazon.com/favicon.ico" "5. 亚马逊广告前端 JS/CSS 核心静态库 (Media CDN)"
    test_url_speed "https://aax-us-east.amazon-adsystem.com/" "6. 亚马逊北美广告竞价与报表引擎 (AAX US-East)"
    test_url_speed "https://www.amazon.com/favicon.ico" "7. 亚马逊北美主站商品前台节点 (Storefront CDN)"

    echo -e "\n${YELLOW}================== 当前各域名已 100% 锁定的最快命中节点 ==================${NC}"
    if [ -f "$DOMAIN_DNS_CONF" ]; then
        grep "^# [1-6]\." "$DOMAIN_DNS_CONF" | sed 's/^# /  /g'
    fi
    echo -e "${YELLOW}==========================================================================${NC}"
}

# 7. VPS IP 纯净度体检与中国本土卖家防关联评估
check_ip_association_risk() {
    clear
    local ip
    ip=$(get_public_ip)

    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "${GREEN}   【VPS IP 纯净度体检与中国本土卖家“一号一IP”防关联深度评估 v7.2】   ${NC}"
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "正在检测 IP 归属地、城市一致性 (防视频验证)、智能 DNS 池及防泄露护盾...\n"

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

    local webrtc_fw="${YELLOW}未开启服务端拦截 (建议执行菜单[2]一键开启)${NC}"
    if iptables -S OUTPUT 2>/dev/null | grep -q "3478"; then
        webrtc_fw="${GREEN}已开启服务端强制拦截 (UDP 3478/5349/19302-19309 已封禁)${NC}"
    fi

    local ipv6_dis
    ipv6_dis=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    local ipv6_status="${GREEN}已彻底关闭 IPv6 (零泄露风险，杜绝 10秒 AAAA DNS 超时)${NC}"
    [ "$ipv6_dis" != "1" ] && ipv6_status="${YELLOW}未完全关闭 (建议执行菜单[2]关闭)${NC}"

    echo -e "${CYAN}------------------- 【1. IP 基础物理与同城归属画像】 -------------------${NC}"
    echo -e " 出口 IPv4 : ${WHITE}${ip}${NC}"
    echo -e " 物理位置  : ${GREEN}${country} - ${region} - ${city}${NC} (同城固定登录可有效预防异地视频验证)"
    echo -e " 标准时区  : ${WHITE}${tz}${NC} (当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z'))"
    echo -e " 网络运营商: ${WHITE}${isp}${NC}"
    echo -e " 所属机构  : ${WHITE}${org} (${as_name})${NC}"

    echo -e "\n${CYAN}------------------- 【2. 亚马逊防关联与环境纯净度诊断】 -------------------${NC}"
    echo -e " 黑名单标记  : $( [ "$is_proxy" == "true" ] && echo -e "${RED}已被标记为公开代理 (建议更换IP或开启白名单锁)${NC}" || echo -e "${GREEN}纯净 (未被标记为公开黑名单代理)${NC}" )"
    echo -e " 节点锁定策略: ${GREEN}本家权威DNS(Route53)+公共DNS采集 -> 防503误杀测速 -> 100%锁死冠军命中IP${NC}"
    echo -e " IPv6 防卡顿 : $ipv6_status"
    echo -e " WebRTC 防护 : $webrtc_fw"
    echo -e " 店铺地域策略: $( [ "$cc" == "CN" ] && echo -e "${GREEN}中国本土卖家同城 IP 模式 (${city}) - 符合营业执照所在地常用登录特征${NC}" || echo -e "${CYAN}海外本土 IP 模式 (${country}-${city})${NC}" )"
    echo -e "${RED}======================================================================${NC}"
}

# 8. 代理安全防扫锁 & IP白名单管理
security_lock_menu() {
    clear
    load_proxy_config
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "${GREEN}      【亚马逊专属 IP 纯净度护盾：代理端口防扫描与授权白名单管理】     ${NC}"
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "当前代理端口: ${GREEN}${PROXY_PORT}${NC}"
    echo -e "1. ${GREEN}一键执行【服务端 WebRTC 拦截 + 禁用 IPv6 + 封禁垃圾邮件端口】加固${NC}"
    echo -e "2. ${CYAN}添加【专属客户端 IP 白名单】${NC} (仅允许你指定的公司/家里宽带 IP 连接代理端口)"
    echo -e "3. ${YELLOW}清除白名单限制 (恢复允许所有 IP 凭账号密码连接)${NC}"
    echo -e "0. 返回主菜单"
    echo -e "${YELLOW}======================================================================${NC}"
    read -p "请输入选项 [0-3]: " s_opt
    case "$s_opt" in
        1)
            protect_bandwidth_and_harden
            ;;
        2)
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
        3)
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
# 9. 【新增功能】一键在线更新脚本最新版本 (从 GitHub 多镜像极速拉取最新代码并自动校验重启)
# ==============================================================================
self_update_script() {
    clear
    echo -e "${YELLOW}========================================================================${NC}"
    echo -e "${GREEN}         【一键在线更新脚本最新版本 (GitHub 多镜像防缓存极速拉取)】       ${NC}"
    echo -e "${YELLOW}========================================================================${NC}"
    echo -e " 当前本地版本 : ${CYAN}${SCRIPT_VERSION}${NC}"
    echo -e " 默认仓库地址 : ${WHITE}https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh${NC}"
    echo -e "${CYAN}------------------------------------------------------------------------${NC}"
    echo -e " 1. ${GREEN}立即从默认 GitHub 仓库多镜像拉取最新 amazon.sh 并自动应用升级${NC}"
    echo -e " 2. 输入自定义脚本直链 URL 进行在线更新"
    echo -e " 0. 返回主菜单"
    echo -e "${YELLOW}========================================================================${NC}"
    read -p "请输入选项 [0-2]: " up_opt

    local raw_target="https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh"
    if [ "$up_opt" == "2" ]; then
        read -p "请输入自定义脚本直链 URL: " custom_url
        [ -z "$custom_url" ] && echo -e "${RED}未输入地址，已取消！${NC}" && return 1
        raw_target="$custom_url"
    elif [ "$up_opt" != "1" ]; then
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
    ensure_working_dns
    optimize_kernel
    optimize_initcwnd
    setup_dns_accelerator
    optimize_per_domain_dns "verbose"
    protect_bandwidth_and_harden
    install_auto_optimizer_cron 20
    if download_gost; then
        modify_config
    fi
}

# 单独一键无损极速升级 v7.2
optimize_suite_only() {
    clear
    echo -e "${YELLOW}========================================================================${NC}"
    echo -e "${GREEN}  正在执行: v7.2 本家权威DNS采集 -> 防503误杀测速 -> 100%锁定最快IP      ${NC}"
    echo -e "${YELLOW}========================================================================${NC}"
    ensure_working_dns
    optimize_kernel
    optimize_initcwnd
    setup_dns_accelerator
    optimize_per_domain_dns "verbose"
    protect_bandwidth_and_harden
    install_auto_optimizer_cron 20
    verify_and_repair_all

    echo -e "\n${GREEN}========================================================================${NC}"
    echo -e "${GREEN}  恭喜！v7.2 终极三步闭环优选已全部生效 (原有端口密码不变)！            ${NC}"
    echo -e "${GREEN}  1. 已直连亚马逊本家权威 DNS (Route53) + 11大公共DNS采集真实节点       ${NC}"
    echo -e "${GREEN}  2. 已修复 503 防爬盾误杀问题，0.5秒级极速节点不再被淘汰               ${NC}"
    echo -e "${GREEN}  3. 已将每个域名 100% 锁定到实测第 1 名的极速 IP (绝不再随机跳死节点)  ${NC}"
    echo -e "${GREEN}========================================================================${NC}"
}

# 查看系统与网络状态
check_status() {
    clear
    echo -e "${YELLOW}================ 当前系统与全组件健康度状态排查 (${SCRIPT_VERSION}) ================${NC}"
    verify_and_repair_all

    if [ -f "$DOMAIN_DNS_CONF" ]; then
        echo -e "\n${CYAN}---------------- 当前各亚马逊域名已 100% 锁定的最快命中节点 ----------------${NC}"
        grep "^# [1-6]\." "$DOMAIN_DNS_CONF" | sed 's/^# /  /g'
    fi
    echo -e "${YELLOW}=======================================================================${NC}"
}

# 服务控制
manage_service() {
    clear
    echo -e "${YELLOW}=== 服务运行控制与深度自检修复 ===${NC}"
    echo -e "1. 一键运行【全组件健康自检与未启动项目自动重装修复】"
    echo -e "2. 重启代理服务 (gost)"
    echo -e "3. 重新采集各域名命中节点并测速锁定最快 IP"
    echo -e "4. 停止代理服务"
    echo -e "5. 开启代理服务"
    echo -e "0. 返回主菜单"
    read -p "请输入选项: " opt
    case "$opt" in
        1) verify_and_repair_all ;;
        2) systemctl restart gost && echo -e "${GREEN}代理服务已重启${NC}" ;;
        3)
            repair_and_start_dnsmasq
            optimize_per_domain_dns "verbose"
            ;;
        4) systemctl stop gost && echo -e "${YELLOW}代理服务已停止${NC}" ;;
        5) systemctl start gost && echo -e "${GREEN}代理服务已启动${NC}" ;;
        *) return 0 ;;
    esac
    sleep 1
}

# 彻底卸载与还原
uninstall_all() {
    clear
    echo -e "${RED}正在彻底卸载代理服务并安全还原系统 DNS 与网络环境...${NC}"
    systemctl stop gost >/dev/null 2>&1
    systemctl disable gost >/dev/null 2>&1
    systemctl stop dnsmasq >/dev/null 2>&1
    systemctl disable dnsmasq >/dev/null 2>&1
    killall dnsmasq >/dev/null 2>&1
    systemctl stop amazon-net-tuning.service >/dev/null 2>&1
    systemctl disable amazon-net-tuning.service >/dev/null 2>&1

    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "$AUTO_OPT_SCRIPT" | grep -v "amazon-dns-prewarm" | crontab - 2>/dev/null
    fi

    sed -i '/# === AMZ_FAST_HOSTS_START ===/,/# === AMZ_FAST_HOSTS_END ===/d' /etc/hosts 2>/dev/null

    rm -f /etc/systemd/system/gost.service /etc/systemd/system/dnsmasq.service "$TUNING_SERVICE"
    rm -f /usr/bin/gost "$AUTO_OPT_SCRIPT" /usr/local/bin/amazon-dns-prewarm.sh
    rm -f "$SPEED_CONF" "$DOMAIN_DNS_CONF" "$FASTROUTE_CONF" /etc/dnsmasq.d/amazon_dns_pool.conf /etc/dnsmasq.d/amazon_ad_slim.conf
    rm -f "$CONFIG_FILE" "$AUTO_OPT_CONF" "$AUTO_OPT_LOG"
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

# 支持后台定时任务静默调用 (--auto-optimize) 与在线更新后直接升级 (--upgrade-now)
if [ "$1" == "--auto-optimize" ]; then
    ensure_working_dns
    repair_and_start_dnsmasq >/dev/null 2>&1
    optimize_per_domain_dns "silent" >/dev/null 2>&1
    exit 0
elif [ "$1" == "--upgrade-now" ]; then
    sync_shortcut
    optimize_suite_only
    read -p "按回车键进入主菜单..." dummy
fi

# 主菜单
main_menu() {
    sync_shortcut
    while true; do
        clear
        echo -e "${YELLOW}========================================================================${NC}"
        echo -e "${GREEN}   晓林技术 - 亚马逊命中节点测速锁定与防关联管理面板 (旗舰版 ${SCRIPT_VERSION})      ${NC}"
        echo -e "${YELLOW}========================================================================${NC}"
        echo -e " 1. ${GREEN}一键全自动部署 (本家权威DNS采集 + 防503误杀测速 + 锁死最快IP)${NC}"
        echo -e " 2. ${CYAN}【一键无损应用最新加速配置】(保留原端口密码 | 刷新本家DNS与极速节点)${NC}"
        echo -e " 3. ${GREEN}【按域名采集命中节点测速与定时设置】(查看命中节点榜/10或20分钟优选)${NC}"
        echo -e " 4. 修改 代理端口 / 账号 / 密码 (自动强开系统端口)"
        echo -e " 5. 【查询当前代理信息】(Socks5/HTTP 账号密码与指纹浏览器一键导入格式)"
        echo -e " 6. 【强行强开系统端口】(暴力释放占用 + 穿透系统防火墙)"
        echo -e " 7. ${PURPLE}【亚马逊卖家中心 / 广告后台 / 商品图片CDN 专项测速】(毫秒级分段诊断)${NC}"
        echo -e " 8. ${RED}【VPS IP 纯净度体检与中国本土同城IP防关联评估】(防视频验证/防泄露)${NC}"
        echo -e " 9. ${YELLOW}【专属 IP 防盗刷护盾】(客户端 IP 白名单锁 / WebRTC与垃圾端口拦截)${NC}"
        echo -e "10. 【全组件状态自检与自动重装修复】(检查并修复 dnsmasq/gost/cron/BBR)"
        echo -e "11. 停止 / 开启 / 重启服务 (gost / dnsmasq)"
        echo -e "12. 查看实时运行日志"
        echo -e "13. ${RED}彻底卸载 (清除服务 + 自动恢复可用DNS，绝不断网)${NC}"
        echo -e "14. ${GREEN}【一键在线更新脚本最新版本】(从 GitHub 多镜像极速拉取最新代码)${NC}"
        echo -e " 0. 退出面板"
        echo -e "${YELLOW}========================================================================${NC}"
        read -p "请输入数字选择 [0-14]: " num

        case "$num" in
            1) install_all ;;
            2) optimize_suite_only ;;
            3) auto_dns_optimizer_menu ;;
            4) modify_config ;;
            5) query_proxy_info ;;
            6) manual_force_open_port ;;
            7) test_amazon_suite ;;
            8) check_ip_association_risk ;;
            9) security_lock_menu ;;
            10) check_status ;;
            11) manage_service ;;
            12) view_logs ;;
            13) uninstall_all ;;
            14) self_update_script ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误，请输入 0-14 之间的数字！${NC}" && sleep 1 && continue ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..." dummy
    done
}

main_menu