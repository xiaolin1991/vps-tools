#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
晓林技术服务 - Sing-box 脚本自动化同步与去水印品牌定制引擎
功能：
1. 抓取甬哥 upstream (yonggekkk/sing-box-yg) 最新 sb.sh
2. 注入 XIAOLIN 字符画与晓林技术服务专属抬头
3. 注入安全自更新函数 upsb_xl()，并指向 xiaolin1991/vps-tools
4. 修复菜单编号为 1-16 (15说明书，16更新脚本，7内包含快捷更新)
5. 替换所有勇哥相关品牌标识，实现全自动化同步与终生防反弹
"""

import sys
import os
import re
import urllib.request

UPSTREAM_URLS = [
    "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh",
    "https://ghfast.top/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh",
    "https://gh-proxy.com/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TARGET_FILE = os.path.join(SCRIPT_DIR, "..", "sb.sh")

def fetch_upstream():
    for url in UPSTREAM_URLS:
        try:
            print(f"[+] 正在拉取上游官方脚本: {url}")
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                content = resp.read().decode("utf-8")
                if content and "instsllsingbox" in content:
                    print(f"[✔] 成功拉取上游脚本，长度: {len(content)} 字节")
                    return content
        except Exception as e:
            print(f"[-] 源 {url} 请求失败: {e}")
    raise RuntimeError("所有上游源均拉取失败，请检查网络！")

def transform(content: str) -> str:
    content = content.replace("\r\n", "\n")

    # 1. 顶部插入命令行更新支持与快捷方式自动部署
    root_check = '[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit'
    auto_deploy = f'''{root_check}

# 晓林技术服务专属：命令行一键更新支持 (sb update 或 sb -u)
if [[ "$1" == "update" || "$1" == "-u" ]]; then
    upsb_xl
    exit 0
fi

# 晓林技术服务专属：自动将当前脚本写入 /usr/bin/sb 快捷方式，避免手动执行后丢失快捷命令
if [[ -f "${{BASH_SOURCE[0]}}" && "$(readlink -f "${{BASH_SOURCE[0]}}")" != "/usr/bin/sb" ]]; then
    cp -f "${{BASH_SOURCE[0]}}" /usr/bin/sb 2>/dev/null
    chmod +x /usr/bin/sb 2>/dev/null
elif [[ -f "$0" && "$(readlink -f "$0")" != "/usr/bin/sb" ]]; then
    cp -f "$0" /usr/bin/sb 2>/dev/null
    chmod +x /usr/bin/sb 2>/dev/null
fi'''

    if root_check in content and "# 晓林技术服务专属：命令行一键更新支持" not in content:
        content = content.replace(root_check, auto_deploy)

    # 2. 替换快捷命令生成 lnsb() 与 upsbyg()，注入安全自更新函数 upsb_xl()
    custom_lnsb_and_update = '''lnsb(){
local spath
if [[ -f "${BASH_SOURCE[0]}" ]]; then
    spath="${BASH_SOURCE[0]}"
elif [[ -f "$0" ]]; then
    spath="$0"
elif [[ -f "./sb.sh" ]]; then
    spath="./sb.sh"
fi
if [[ -n "$spath" && -f "$spath" && "$(readlink -f "$spath")" != "/usr/bin/sb" ]]; then
    cp -f "$spath" /usr/bin/sb 2>/dev/null
    chmod +x /usr/bin/sb 2>/dev/null
else
    # 兜底：如果是直接网络管道执行，拉取晓林仓库版本
    if [[ ! -f /usr/bin/sb || ! -s /usr/bin/sb ]]; then
        curl -L -o /usr/bin/sb -# --retry 2 "https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh" 2>/dev/null || curl -L -o /usr/bin/sb -# --retry 2 "https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh" 2>/dev/null
        chmod +x /usr/bin/sb 2>/dev/null
    fi
fi
}

upsb_xl(){
green "正在从晓林官方仓库获取最新管理脚本……"
local tmp_sb="/tmp/sb_new.sh"
rm -f "$tmp_sb"
if curl -sL -m 10 --retry 2 "https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh" -o "$tmp_sb" && grep -q "XIAOLIN" "$tmp_sb"; then
    mv -f "$tmp_sb" /usr/bin/sb
    chmod +x /usr/bin/sb
    green "升级成功！已无缝更新至晓林技术服务最新管理脚本！" && sleep 2 && sb
elif curl -sL -m 10 --retry 2 "https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh" -o "$tmp_sb" && grep -q "XIAOLIN" "$tmp_sb"; then
    mv -f "$tmp_sb" /usr/bin/sb
    chmod +x /usr/bin/sb
    green "升级成功（国内极速源）！已更新至晓林技术服务最新管理脚本！" && sleep 2 && sb
else
    rm -f "$tmp_sb"
    red "更新失败！无法连接到更新源或内容校验未通过，已为您保留当前版本。" && sleep 3 && sb
fi
}'''

    # 如果存在原版的 lnsb 和 upsbyg，替换为新版
    pattern_lnsb_orig = re.compile(
        r'lnsb\(\)\{[\s\S]*?upsbyg\(\)\{[\s\S]*?green "Sing-box-yg安装脚本升级成功"[^\n]*\n\}'
    )
    if pattern_lnsb_orig.search(content):
        content = pattern_lnsb_orig.sub(custom_lnsb_and_update, content)
    elif "upsb_xl()" not in content:
        # 单独替换 lnsb
        content = re.sub(r'lnsb\(\)\{[\s\S]*?\n\}', custom_lnsb_and_update, content, count=1)

    # 3. 增强内核更新函数 upsbcroe()，在里面添加选项 4：更新晓林脚本
    if "upsbcroe(){" in content and "更新 晓林技术服务 管理脚本" not in content:
        content = content.replace(
            'green "3：切换Sing-box某个正式版或测试版，需指定版本号 (建议1.10.0以上版本)"',
            'green "3：切换Sing-box某个正式版或测试版，需指定版本号 (建议1.10.0以上版本)"\ngreen "4：更新 晓林技术服务 管理脚本 (从 xiaolin1991 官方源)"'
        )
        content = content.replace(
            'readp "请选择【0-3】：" menu',
            'readp "请选择【0-4】：" menu'
        )
        content = content.replace(
            'readp "请输入Sing-box版本号：" upcore\nelse\nsb\nfi',
            'readp "请输入Sing-box版本号：" upcore\nelif [ "$menu" = "4" ]; then\nupsb_xl\nelse\nsb\nfi'
        )

    # 4. 替换 sbsm 说明书函数
    custom_sbsm = '''sbsm(){
echo
green "欢迎关注：晓林技术服务 了解最新技术动态"
echo
blue "为您提供专业、稳定、高效的网络解决方案"
echo
}'''
    content = re.sub(r'sbsm\(\)\{[\s\S]*?\n\}', custom_sbsm, content, count=1)

    # 5. 替换头部 ASCII Banner 和作者链接
    xiaolin_header = '''clear
white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
echo -e "${bblue} ░██   ░██ ░██  ░█████  ░██████  ${red}░██       ░██ ░███   ░██ ${plain}"
echo -e "${bblue}  ░██ ░██  ░██ ░██   ░██░██   ░██${red}░██       ░██ ░██░██ ░██ ${plain}"
echo -e "${bblue}   ░███    ░██ ░███████ ░██   ░██${red}░██       ░██ ░██ ░██░██ ${plain}"
echo -e "${bblue}  ░██ ░██  ░██ ░██   ░██░██   ░██${red}░██       ░██ ░██  ░████ ${plain}"
echo -e "${bblue} ░██   ░██ ░██ ░██   ░██░██████  ${red}░████████ ░██ ░██   ░███ ${plain}"
white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
white "服务提供 ：晓林技术服务"
white "业务范围 ：专业/稳定/高效的技术支持"
white "技术交流 ：欢迎联系晓林获取最新资讯"
white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"'''

    header_pattern = re.compile(
        r'clear\s+white "~+"[\s\S]*?white "(?:甬哥YouTube频道|技术交流)[^\n]*\nwhite "~+"[^\n]*'
    )
    if header_pattern.search(content):
        content = header_pattern.sub(xiaolin_header, content, count=1)

    # 5.1 替换客户端下载提示中残留的甬哥字样
    content = content.replace("安卓SFA、苹果SFI，win电脑官方文件包SFW请到甬哥Github项目自行下载，", "安卓SFA、苹果SFI，win电脑客户端请到 GitHub 官方或发布页自行下载，")

    # 6. 替换主菜单
    xiaolin_menu = '''white "Vless-reality-vision、Vmess-ws(tls)+Argo、Hy2、Tuic、Anytls 五协议共存脚本"
white "脚本快捷方式：sb"
red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
green " 1. 一键安装 Sing-box" 
green " 2. 删除卸载 Sing-box"
white "----------------------------------------------------------------------------------"
green " 3. 变更配置 【双证书TLS/UUID路径/Argo/IP优先/TG通知/Warp/订阅/CDN优选】" 
green " 4. 更改主端口/添加多端口跳跃复用" 
green " 5. 三通道域名分流"
green " 6. 关闭/重启 Sing-box"   
green " 7. 更新/切换/指定 Sing-box 内核版本"
white "----------------------------------------------------------------------------------"
green " 8. 刷新并查看节点 【Mihomo/SFA+SFI+SFW三合一配置/订阅链接/推送TG通知】"
green " 9. 查看 Sing-box 运行日志"
green "10. 一键原版BBR+FQ加速"
green "11. 管理 Acme 申请域名证书"
green "12. 管理 Warp 查看Netflix/ChatGPT解锁情况"
green "13. 添加 WARP-plus-Socks5 代理模式 【本地Warp/多地区Psiphon-VPN】"
green "14. 刷新本地IP、调整IPV4/IPV6配置输出"
white "----------------------------------------------------------------------------------"
green "15. 晓林技术服务脚本使用说明书"
green "16. 更新 晓林技术服务 管理脚本"
white "----------------------------------------------------------------------------------"
green " 0. 退出脚本"
red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"'''

    content = re.sub(
        r'white "Vless-reality-vision[\s\S]*?green "\s*0\.\s*退出脚本"\s+red "~+"',
        xiaolin_menu,
        content,
        count=1
    )

    # 7. 去掉原版版本提示
    content = re.sub(
        r'insV=\$\(cat /etc/s-box/v[\s\S]*?yellow "未安装 Sing-box-yg 脚本！请先选择 1 安装"\s+fi',
        '',
        content,
        count=1
    )

    # 8. 菜单底部输入与 case 路由
    custom_case = '''readp "请输入数字【0-16】:" Input
case "$Input" in  
 1 ) instsllsingbox;;
 2 ) unins;;
 3 ) changeserv;;
 4 ) changeport;;
 5 ) changefl;;
 6 ) stclre;;
 7 ) upsbcroe;;
 8 ) clash_sb_share;;
 9 ) sblog;;
10 ) bbr;;
11 ) acme;;
12 ) cfwarp;;
13 ) inssbwpph;;
14 ) wgcfgo && sbshare;;
15 ) sbsm;;
16 ) upsb_xl;;
 * ) exit 
esac'''

    content = re.sub(
        r'readp "请输入数字【0-1[56]】:" Input\s+case "\$Input" in[\s\S]*?esac',
        custom_case,
        content,
        count=1
    )

    # 9. 统一清理全局残留
    content = content.replace("Sing-box-yg", "Sing-box")
    content = content.replace(
        "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh",
        "https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh"
    )
    content = re.sub(
        r'欢迎继续使用.*管理脚本[^\n]*',
        '欢迎继续使用晓林技术服务管理脚本：bash <(curl -Ls https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh)',
        content
    )
    content = content.replace("可选择9，刷新并显示所有协议配置及分享链接", "可选择8，刷新并显示所有协议配置及分享链接")
    content = content.replace("选择10查看日志并反馈", "选择9查看日志并反馈")
    content = content.replace("未正常启动Sing-box，请卸载重装或者选择10查看运行日志", "未正常启动Sing-box，请卸载重装或者选择9查看运行日志")

    return content

def main():
    source_file = None
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        source_file = sys.argv[1]
        print(f"[+] 使用本地输入文件: {source_file}")
        with open(source_file, "r", encoding="utf-8") as f:
            raw = f.read()
    else:
        raw = fetch_upstream()

    print("[+] 正在执行晓林专属品牌注入与脱敏……")
    result = transform(raw)

    # 校验
    assert "XIAOLIN" in result, "校验失败: 缺少 XIAOLIN 字符画！"
    assert "晓林技术服务" in result, "校验失败: 缺少 晓林技术服务 标识！"
    assert "upsb_xl" in result, "校验失败: 缺少 upsb_xl 自更新函数！"
    assert "yonggekkk/sing-box-yg/main/sb.sh" not in result, "校验失败: 仍存在 yonggekkk 脚本拉取链接！"
    assert "甬哥Github项目" not in result and "Sing-box-yg脚本使用说明书" not in result, "校验失败: 仍存在甬哥专属菜单或标题！"

    with open(TARGET_FILE, "w", encoding="utf-8", newline="\n") as f:
        f.write(result)

    print(f"[✔] 处理完成！已成功写入: {TARGET_FILE}")

if __name__ == "__main__":
    main()
