#!/bin/bash

# ==========================================
# 晓林技术 - 亚马逊 VPS 终极优化面板
# 集成: BBR+TFO+Socks5+DNS缓存优化
# ==========================================

# 定义颜色
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export NC='\033[0m'

# 面板主界面
main_menu() {
    clear
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${GREEN}       晓林技术 VPS 网络优化管理面板        ${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "1. ${GREEN}一键全自动部署 (BBR + TFO + Socks5)${NC}"
    echo -e "2. 修改 Socks5 端口/账号/密码"
    echo -e "3. 查看当前运行状态 (排查 Bug)"
    echo -e "4. 查看实时运行日志"
    echo -e "5. 停止 / 开启 / 重启服务"
    echo -e "6. 卸载服务 (彻底抹除记录)"
    echo -e "0. 退出面板"
    echo -e "${YELLOW}==========================================${NC}"
    read -p "请输入数字选择: " num

    case "$num" in
        1) install_all ;;
        2) modify_config ;;
        3) check_status ;;
        4) view_logs ;;
        5) manage_service ;;
        6) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误！${NC}" && sleep 2 && main_menu ;;
    esac
}

# 全自动安装逻辑
install_all() {
    echo -e "${YELLOW}正在进行深度内核优化...${NC}"
    
    # 1. 开启 BBR + TCP Fast Open (TFO)
    # TFO 可以让第二次连接时减少握手次数，图片加载更快
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
    sysctl -p

    # 2. 优化文件句柄限制 (防止连接过多导致卡顿)
    echo "* soft nofile 51200" >> /etc/security/limits.conf
    echo "* hard nofile 51200" >> /etc/security/limits.conf

    # 3. 安装 gost
    echo -e "${YELLOW}正在安装 Socks5 服务端...${NC}"
    wget -N --no-check-certificate https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
    gzip -d gost-linux-amd64-2.11.5.gz && mv gost-linux-amd64-2.11.5 /usr/bin/gost && chmod +x /usr/bin/gost
    
    modify_config # 进入配置引导
}

# 修改配置并写入服务
modify_config() {
    echo -e "${YELLOW}--- 配置信息设置 ---${NC}"
    read -p "请输入你要设置的端口 (默认 1080): " port
    port=${port:-1080}
    read -p "请输入你的账号: " user
    read -p "请输入你的密码: " pass

    # 4. 自动识别并放行防火墙
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $port/tcp
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port=$port/tcp --permanent
        firewall-cmd --reload
    fi
    iptables -I INPUT -p tcp --dport $port -j ACCEPT

    # 5. 写入 systemd 自启 (增加日志不落盘设置，保护隐私)
    cat <<EOF > /etc/systemd/system/gost.service
[Unit]
Description=Amazon Proxy Service
After=network.target

[Service]
Type=simple
# 增加 -V 参数可关闭详细日志，保护隐私
ExecStart=/usr/bin/gost -L=${user}:${pass}@:${port}
Restart=always
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost
    echo -e "${GREEN}全部优化已完成！${NC}"
    echo -e "当前配置：端口 ${port} | 账号 ${user}"
    sleep 3 && main_menu
}

# 检查状态
check_status() {
    clear
    echo "--- 当前系统状态 ---"
    echo -n "BBR 加速状态: "
    sysctl net.ipv4.tcp_congestion_control
    echo -n "TCP Fast Open: "
    sysctl net.ipv4.tcp_fastopen
    echo -n "Socks5 服务状态: "
    if systemctl is-active --quiet gost; then echo -e "${GREEN}运行中${NC}"; else echo -e "${RED}已停止${NC}"; fi
    echo "-------------------"
    read -p "按回车返回菜单"
    main_menu
}

# 卸载与清理
uninstall_all() {
    echo -e "${RED}正在彻底卸载并清理配置...${NC}"
    systemctl stop gost
    systemctl disable gost
    rm -rf /etc/systemd/system/gost.service
    rm -rf /usr/bin/gost
    echo -e "${GREEN}清理完成，所有代理记录已抹除。${NC}"
    sleep 2 && main_menu
}

# 运行日志
view_logs() {
    echo "正在查看实时日志 (按 Ctrl+C 退出查看):"
    journalctl -u gost -f
}

# 启动面板
main_menu
