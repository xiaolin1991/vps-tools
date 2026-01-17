#!/bin/bash

# ==========================================
# 晓林技术 - 亚马逊 VPS 优化面板 (彻底卸载版)
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
    echo -e "6. ${RED}彻底卸载 (清除服务+删除面板命令)${NC}"
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
    echo -e "${YELLOW}正在进行内核深度优化 (BBR + TFO)...${NC}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
    sysctl -p

    echo -e "${YELLOW}正在下载服务组件...${NC}"
    wget -N --no-check-certificate https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
    gzip -d gost-linux-amd64-2.11.5.gz && mv gost-linux-amd64-2.11.5 /usr/bin/gost && chmod +x /usr/bin/gost
    
    modify_config
}

# 修改配置
modify_config() {
    read -p "请输入设置端口 (默认 1080): " port
    port=${port:-1080}
    read -p "请输入账号: " user
    read -p "请输入密码: " pass

    if command -v ufw >/dev/null 2>&1; then ufw allow $port/tcp; fi
    iptables -I INPUT -p tcp --dport $port -j ACCEPT

    cat <<EOF > /etc/systemd/system/gost.service
[Unit]
Description=Amazon Proxy Service
After=network.target
[Service]
Type=simple
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
    echo -e "${GREEN}加速部署成功！${NC}"
    sleep 3 && main_menu
}

# 彻底卸载与清理
uninstall_all() {
    echo -e "${RED}正在清理所有加速服务与配置...${NC}"
    # 1. 停止并删除 Socks5 服务
    systemctl stop gost >/dev/null 2>&1
    systemctl disable gost >/dev/null 2>&1
    rm -rf /etc/systemd/system/gost.service
    rm -rf /usr/bin/gost
    
    # 2. 解锁并恢复可能被改动的 DNS 状态
    chattr -i /etc/resolv.conf >/dev/null 2>&1
    
    # 3. 提示删除面板入口
    echo -e "${YELLOW}服务已停止。正在尝试自毁面板命令...${NC}"
    rm -f /usr/bin/vps
    
    echo -e "${GREEN}卸载完成！'vps' 命令已移除。${NC}"
    echo -e "如果以后还需要使用，请重新运行 wget 安装命令。"
    exit 0
}

# 其他功能省略 (保持原样即可)
manage_service() { systemctl restart gost; main_menu; }
check_status() { clear; sysctl net.ipv4.tcp_congestion_control; sysctl net.ipv4.tcp_fastopen; read -p "回车返回"; main_menu; }
view_logs() { journalctl -u gost -f; }

# 启动面板
main_menu
