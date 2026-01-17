#!/bin/bash

# 定义颜色
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export NC='\033[0m'

# 面板主界面
main_menu() {
    clear
    echo -e "${YELLOW}=========================================="
    echo -e "      亚马逊卖家 VPS 网络优化管理面板      "
    echo -e "==========================================${NC}"
    echo -e "1. ${GREEN}一键全自动部署 (BBR + Socks5)${NC}"
    echo -e "2. 修改 Socks5 端口/账号/密码"
    echo -e "3. 查看当前运行状态 (排查 Bug)"
    echo -e "4. 查看实时运行日志"
    echo -e "5. 停止 / 开启 / 重启服务"
    echo -e "6. 卸载服务"
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
    echo -e "${YELLOW}正在配置环境...${NC}"
    # 开启 BBR
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    
    # 安装 gost
    wget -N --no-check-certificate https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
    gzip -d gost-linux-amd64-2.11.5.gz && mv gost-linux-amd64-2.11.5 /usr/bin/gost && chmod +x /usr/bin/gost
    
    modify_config # 进入配置引导
}

# 修改配置并写入服务
modify_config() {
    read -p "请输入你要设置的端口 (默认 1080): " port
    port=${port:-1080}
    read -p "请输入你的账号: " user
    read -p "请输入你的密码: " pass

    # 放行端口
    iptables -I INPUT -p tcp --dport $port -j ACCEPT
    if command -v ufw >/dev/null 2>&1; then ufw allow $port/tcp; fi

    # 写入 systemd 自启
    cat <<EOF > /etc/systemd/system/gost.service
[Unit]
Description=Amazon Proxy Service
After=network.target
[Service]
ExecStart=/usr/bin/gost -L=${user}:${pass}@:${port}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost
    echo -e "${GREEN}部署成功！请在 Hubstudio 使用 Socks5 协议连接。${NC}"
    sleep 3 && main_menu
}

# 检查状态
check_status() {
    clear
    echo "--- 当前系统状态 ---"
    echo -n "BBR 加速状态: "
    sysctl net.ipv4.tcp_congestion_control
    echo -n "Socks5 服务状态: "
    if systemctl is-active --quiet gost; then echo -e "${GREEN}运行中${NC}"; else echo -e "${RED}已停止${NC}"; fi
    echo "-------------------"
    read -p "按回车返回菜单"
    main_menu
}

# 查看日志
view_logs() {
    echo "正在查看实时日志 (按 Ctrl+C 退出查看):"
    journalctl -u gost -f
}

# 运行主菜单
main_menu