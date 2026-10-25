#!/usr/bin/env node
/**
 * 晓林技术服务 - Sing-box 脚本自动化同步与去水印品牌定制引擎 (Node.js 版)
 */

const https = require('https');
const fs = require('fs');
const path = require('path');

const UPSTREAM_URLS = [
  'https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh',
  'https://ghfast.top/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh',
  'https://gh-proxy.com/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh'
];

const SCRIPT_DIR = __dirname;
const TARGET_FILE = path.join(SCRIPT_DIR, '..', 'sb.sh');

function fetchUrl(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { timeout: 15000 }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return resolve(fetchUrl(res.headers.location));
      }
      if (res.statusCode !== 200) {
        return reject(new Error(`HTTP Status ${res.statusCode}`));
      }
      let chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

async function fetchUpstream() {
  for (const url of UPSTREAM_URLS) {
    try {
      console.log(`[+] 正在拉取上游官方脚本: ${url}`);
      const content = await fetchUrl(url);
      if (content && content.includes('instsllsingbox')) {
        console.log(`[✔] 成功拉取上游脚本，长度: ${content.length} 字节`);
        return content;
      }
    } catch (e) {
      console.warn(`[-] 源 ${url} 请求失败: ${e.message}`);
    }
  }
  throw new Error('所有上游源均拉取失败，请检查网络！');
}

function transform(content) {
  content = content.replace(/\r\n/g, '\n');

  // 1. 顶部插入命令行更新支持与快捷方式自动部署
  const rootCheck = '[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit';
  const autoDeploy = `${rootCheck}

# 晓林技术服务专属：命令行一键更新支持 (sb update 或 sb -u)
if [[ "$1" == "update" || "$1" == "-u" ]]; then
    upsb_xl
    exit 0
fi

# 晓林技术服务专属：自动将当前脚本写入 /usr/bin/sb 快捷方式，避免手动执行后丢失快捷命令
if [[ -f "\${BASH_SOURCE[0]}" && "$(readlink -f "\${BASH_SOURCE[0]}")" != "/usr/bin/sb" ]]; then
    cp -f "\${BASH_SOURCE[0]}" /usr/bin/sb 2>/dev/null
    chmod +x /usr/bin/sb 2>/dev/null
elif [[ -f "$0" && "$(readlink -f "$0")" != "/usr/bin/sb" ]]; then
    cp -f "$0" /usr/bin/sb 2>/dev/null
    chmod +x /usr/bin/sb 2>/dev/null
fi`;

  if (content.includes(rootCheck) && !content.includes('# 晓林技术服务专属：命令行一键更新支持')) {
    content = content.replace(rootCheck, autoDeploy);
  }

  // 2. 替换快捷命令生成 lnsb() 与 upsbyg()，注入安全自更新函数 upsb_xl()
  const customLnsbAndUpdate = `lnsb(){
local spath
if [[ -f "\${BASH_SOURCE[0]}" ]]; then
    spath="\${BASH_SOURCE[0]}"
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
}`;

  const patternOrig = /lnsb\(\)\{[\s\S]*?upsbyg\(\)\{[\s\S]*?green "Sing-box-yg安装脚本升级成功"[^\n]*\n\}/;
  if (patternOrig.test(content)) {
    content = content.replace(patternOrig, customLnsbAndUpdate);
  } else if (!content.includes('upsb_xl()')) {
    content = content.replace(/lnsb\(\)\{[\s\S]*?\n\}/, customLnsbAndUpdate);
  }

  // 3. 增强内核更新函数 upsbcroe()，添加选项 4：更新晓林脚本
  if (content.includes('upsbcroe(){') && !content.includes('更新 晓林技术服务 管理脚本')) {
    content = content.replace(
      'green "3：切换Sing-box某个正式版或测试版，需指定版本号 (建议1.10.0以上版本)"',
      'green "3：切换Sing-box某个正式版或测试版，需指定版本号 (建议1.10.0以上版本)"\ngreen "4：更新 晓林技术服务 管理脚本 (从 xiaolin1991 官方源)"'
    );
    content = content.replace(
      'readp "请选择【0-3】：" menu',
      'readp "请选择【0-4】：" menu'
    );
    content = content.replace(
      'readp "请输入Sing-box版本号：" upcore\nelse\nsb\nfi',
      'readp "请输入Sing-box版本号：" upcore\nelif [ "$menu" = "4" ]; then\nupsb_xl\nelse\nsb\nfi'
    );
  }

  // 4. 替换 sbsm 说明书函数
  const customSbsm = `sbsm(){
echo
green "欢迎关注：晓林技术服务 了解最新技术动态"
echo
blue "为您提供专业、稳定、高效的网络解决方案"
echo
}`;
  content = content.replace(/sbsm\(\)\{[\s\S]*?\n\}/, customSbsm);

  // 5. 替换头部 ASCII Banner 和作者链接
  const xiaolinHeader = `clear
white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
echo -e "\${bblue} ░██   ░██ ░██  ░█████  ░██████  \${red}░██       ░██ ░███   ░██ \${plain}"
echo -e "\${bblue}  ░██ ░██  ░██ ░██   ░██░██   ░██\${red}░██       ░██ ░██░██ ░██ \${plain}"
echo -e "\${bblue}   ░███    ░██ ░███████ ░██   ░██\${red}░██       ░██ ░██ ░██░██ \${plain}"
echo -e "\${bblue}  ░██ ░██  ░██ ░██   ░██░██   ░██\${red}░██       ░██ ░██  ░████ \${plain}"
echo -e "\${bblue} ░██   ░██ ░██ ░██   ░██░██████  \${red}░████████ ░██ ░██   ░███ \${plain}"
white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
white "服务提供 ：晓林技术服务"
white "业务范围 ：专业/稳定/高效的技术支持"
white "技术交流 ：欢迎联系晓林获取最新资讯"
white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"`;

  const headerPattern = /clear\s+white "~+"[\s\S]*?white "(?:甬哥YouTube频道|技术交流)[^\n]*\nwhite "~+"[^\n]*/;
  if (headerPattern.test(content)) {
    content = content.replace(headerPattern, xiaolinHeader);
  }

  // 5.1 替换客户端下载提示中残留的甬哥字样
  content = content.replace(/安卓SFA、苹果SFI，win电脑官方文件包SFW请到甬哥Github项目自行下载，/g, '安卓SFA、苹果SFI，win电脑客户端请到 GitHub 官方或发布页自行下载，');

  // 6. 替换主菜单
  const xiaolinMenu = `white "Vless-reality-vision、Vmess-ws(tls)+Argo、Hy2、Tuic、Anytls 五协议共存脚本"
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
red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"`;

  content = content.replace(/white "Vless-reality-vision[\s\S]*?green "\s*0\.\s*退出脚本"\s+red "~+"/, xiaolinMenu);

  // 7. 去掉原版版本提示与写入
  content = content.replace(/curl -sL https:\/\/raw\.githubusercontent\.com\/yonggekkk\/sing-box-yg\/main\/version[^\n]*\n?/g, '');
  content = content.replace(/insV=\$\(cat \/etc\/s-box\/v[\s\S]*?yellow "未安装 Sing-box-yg 脚本！请先选择 1 安装"\s+fi/, '');

  // 8. 菜单底部输入与 case 路由
  const customCase = `readp "请输入数字【0-16】:" Input
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
esac`;

  content = content.replace(/readp "请输入数字【0-1[56]】:" Input\s+case "\$Input" in[\s\S]*?esac/, customCase);

  // 9. 统一清理全局残留
  content = content.replace(/Sing-box-yg/g, 'Sing-box');
  content = content.replace(
    /https:\/\/raw\.githubusercontent\.com\/yonggekkk\/sing-box-yg\/main\/sb\.sh/g,
    'https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh'
  );
  content = content.replace(
    /欢迎继续使用.*管理脚本[^\n]*/g,
    '欢迎继续使用晓林技术服务管理脚本：bash <(curl -Ls https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh)'
  );
  content = content.replace(/可选择9，刷新并显示所有协议配置及分享链接/g, '可选择8，刷新并显示所有协议配置及分享链接');
  content = content.replace(/选择10查看日志并反馈/g, '选择9查看日志并反馈');
  content = content.replace(/未正常启动Sing-box，请卸载重装或者选择10查看运行日志/g, '未正常启动Sing-box，请卸载重装或者选择9查看运行日志');

  return content;
}

async function main() {
  let raw;
  const args = process.argv.slice(2);
  if (args.length > 0 && fs.existsSync(args[0])) {
    console.log(`[+] 使用本地输入文件: ${args[0]}`);
    raw = fs.readFileSync(args[0], 'utf8');
  } else {
    raw = await fetchUpstream();
  }

  console.log('[+] 正在执行晓林专属品牌注入与脱敏……');
  const result = transform(raw);

  if (!result.includes('XIAOLIN')) throw new Error('校验失败: 缺少 XIAOLIN 字符画！');
  if (!result.includes('晓林技术服务')) throw new Error('校验失败: 缺少 晓林技术服务 标识！');
  if (result.includes('甬哥Github项目')) console.log('Match: 甬哥Github项目');
  if (result.includes('Sing-box-yg脚本使用说明书')) console.log('Match: Sing-box-yg脚本使用说明书');
  if (!result.includes('upsb_xl')) throw new Error('校验失败: 缺少 upsb_xl 自更新函数！');
  if (result.includes('yonggekkk/sing-box-yg/main/sb.sh')) throw new Error('校验失败: 仍存在 yonggekkk 脚本拉取链接！');
  if (result.includes('甬哥Github项目') || result.includes('Sing-box-yg脚本使用说明书')) throw new Error('校验失败: 仍存在甬哥专属菜单或标题！');

  fs.writeFileSync(TARGET_FILE, result, { encoding: 'utf8' });
  console.log(`[✔] 处理完成！已成功写入: ${TARGET_FILE}`);
}

main().catch(err => {
  console.error('[!] 错误:', err);
  process.exit(1);
});
