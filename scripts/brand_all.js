#!/usr/bin/env node
/**
 * 晓林技术服务 - 全套脚本自动化同步与品牌定制引擎
 * 覆盖：
 * 1. sb.sh (Sing-box 主脚本)
 * 2. acme.sh (Acme 域名证书管理脚本，菜单 11)
 * 3. warp.sh (WARP 管理与解锁检测脚本，菜单 12)
 */

const https = require('https');
const fs = require('fs');
const path = require('path');

const ROOT_DIR = path.join(__dirname, '..');

const XIAOLIN_HEADER = `# XIAOLIN TECHNICAL SERVICE
clear
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

async function fetchFromMirrors(upstreamPath) {
  const mirrors = [
    `https://raw.githubusercontent.com/${upstreamPath}`,
    `https://ghfast.top/https://raw.githubusercontent.com/${upstreamPath}`,
    `https://gh-proxy.com/https://raw.githubusercontent.com/${upstreamPath}`
  ];

  for (const url of mirrors) {
    try {
      console.log(`[+] 正在拉取: ${url}`);
      const content = await fetchUrl(url);
      if (content && content.length > 500) {
        console.log(`[✔] 成功拉取，长度: ${content.length} 字节`);
        return content;
      }
    } catch (e) {
      console.warn(`[-] 源 ${url} 拉取失败: ${e.message}`);
    }
  }
  throw new Error(`所有镜像均拉取失败: ${upstreamPath}`);
}

/* ========================================================================== */
/*                              1. 处理 sb.sh                                 */
/* ========================================================================== */
function transformSb(content) {
  content = content.replace(/\r\n/g, '\n');

  // 顶部插入命令行更新支持与快捷方式自动部署
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

  // 替换快捷命令生成 lnsb() 与 upsbyg()，注入安全自更新函数 upsb_xl()
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

  // 增强内核更新函数 upsbcroe()，添加选项 4：更新晓林脚本
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

  // 替换 sbsm 说明书函数
  const customSbsm = `sbsm(){
echo
green "欢迎关注：晓林技术服务 了解最新技术动态"
echo
blue "为您提供专业、稳定、高效的网络解决方案"
echo
}`;
  content = content.replace(/sbsm\(\)\{[\s\S]*?\n\}/, customSbsm);

  // 替换头部 ASCII Banner 和作者链接
  const headerPattern = /clear\s+white "~+"[\s\S]*?white "(?:甬哥YouTube频道|技术交流)[^\n]*\nwhite "~+"[^\n]*/;
  if (headerPattern.test(content)) {
    content = content.replace(headerPattern, XIAOLIN_HEADER);
  }

  // 替换客户端下载提示中残留的甬哥字样
  content = content.replace(/安卓SFA、苹果SFI，win电脑官方文件包SFW请到甬哥Github项目自行下载，/g, '安卓SFA、苹果SFI，win电脑客户端请到 GitHub 官方或发布页自行下载，');

  // 替换主菜单
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

  // 去掉原版版本提示与写入
  content = content.replace(/curl -sL https:\/\/raw\.githubusercontent\.com\/yonggekkk\/sing-box-yg\/main\/version[^\n]*\n?/g, '');
  content = content.replace(/insV=\$\(cat \/etc\/s-box\/v[\s\S]*?yellow "未安装 Sing-box-yg 脚本！请先选择 1 安装"\s+fi/, '');

  // 菜单底部输入与 case 路由
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

  // 核心：把子脚本 11 (acme) 和 12 (warp) 指向晓林仓库！
  content = content.replace(
    /bash <\(curl -Ls https:\/\/raw\.githubusercontent\.com\/yonggekkk\/acme-yg\/main\/acme\.sh\)/g,
    'bash <(curl -Ls https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/acme.sh 2>/dev/null || curl -Ls https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/acme.sh)'
  );
  content = content.replace(
    /bash <\(curl -Ls https:\/\/raw\.githubusercontent\.com\/yonggekkk\/warp-yg\/main\/CFwarp\.sh\)/g,
    'bash <(curl -Ls https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/warp.sh 2>/dev/null || curl -Ls https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/warp.sh)'
  );

  // 统一清理全局残留
  content = content.replace(/Sing-box-yg/g, 'Sing-box');
  content = content.replace(/Acme-yg/g, 'Acme');
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
  content = content.replace(/yg1\.ygkkk\.dpdns\.org/g, 'cdn1.cloudflare.170618.xyz');

  return content;
}

/* ========================================================================== */
/*                             2. 处理 acme.sh                                */
/* ========================================================================== */
function transformAcme(content) {
  content = content.replace(/\r\n/g, '\n');

  // 替换 Banner 与作者信息
  const acmeHeader = `${XIAOLIN_HEADER}
green "晓林技术服务 Acme 域名证书管理工具"`;

  const bannerRegex = /clear[\s\S]*?white\s+"(?:甬哥YouTube频道|甬哥blogger博客)[^\n]*\n(?:green|yellow|white)\s+"~+"[^\n]*(?:\ngreen "Acme-yg[^\n]*)?/;
  if (bannerRegex.test(content)) {
    content = content.replace(bannerRegex, acmeHeader);
  }

  // 提示语脱敏
  content = content.replace(/甬哥的Sing-box-yg脚本/g, '晓林技术服务Sing-box脚本');
  content = content.replace(/甬哥的Hysteria脚本/g, 'Hysteria脚本');
  content = content.replace(/甬哥的Naiveproxy-yg脚本/g, 'Naiveproxy脚本');
  content = content.replace(/甬哥的Tuic脚本/g, 'Tuic脚本');
  content = content.replace(/甬哥的x-ui-yg脚本/g, 'x-ui脚本');
  content = content.replace(/甬哥的Argosbx小钢炮脚本/g, 'Argosbx脚本');
  content = content.replace(/或者使用支持自动关闭与开启的甬哥WARP脚本/g, '或者使用晓林技术服务WARP管理工具');
  content = content.replace(/x\.ygkkk\.eu\.org 或 x\.ygkkk\.cf/g, 'x.example.com');
  content = content.replace(/Acme-yg/g, 'Acme');

  return content;
}

/* ========================================================================== */
/*                             3. 处理 warp.sh                                */
/* ========================================================================== */
function transformWarp(content) {
  content = content.replace(/\r\n/g, '\n');

  // 替换所有 Banner 块 (CFwarp 里有 3 处 Banner)
  const warpHeader = `${XIAOLIN_HEADER}
green "晓林技术服务 WARP 管理工具"`;
  const warpBannerRegex = /clear[\s\S]*?white\s+"(?:甬哥YouTube频道|甬哥Blogger博客)[^\n]*\n(?:green|yellow|white)\s+"~+"[^\n]*/g;
  content = content.replace(warpBannerRegex, warpHeader);

  // 快捷方式与自更新地址重定向到晓林仓库
  content = content.replace(
    /https:\/\/raw\.githubusercontent\.com\/yonggekkk\/warp-yg\/main\/CFwarp\.sh/g,
    'https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/warp.sh'
  );

  // 清除外部 version 请求
  content = content.replace(/curl -sL https:\/\/raw\.githubusercontent\.com\/yonggekkk\/warp-yg\/main\/version[^\n]*\n?/g, '');
  content = content.replace(/https:\/\/replit\.com\/@ygkkkk\/Warp/g, 'https://github.com/xiaolin1991/vps-tools');

  // 统一品牌名替换
  content = content.replace(/甬哥/g, '晓林');
  content = content.replace(/CFwarp/g, 'WARP');

  return content;
}

/* ========================================================================== */
/*                                   主流程                                   */
/* ========================================================================== */
async function main() {
  console.log('========================================================');
  console.log('   晓林技术服务 - 全套脚本自动化同步与品牌定制引擎启动   ');
  console.log('========================================================\n');

  // 1. 处理 sb.sh
  console.log('>>> [1/3] 同步并处理主管理脚本 sb.sh ...');
  const rawSb = await fetchFromMirrors('yonggekkk/sing-box-yg/main/sb.sh');
  const cleanSb = transformSb(rawSb);
  if (!cleanSb.includes('晓林技术服务')) throw new Error('sb.sh 缺少 晓林技术服务 标识！');
  if (cleanSb.includes('甬哥Github项目')) throw new Error('sb.sh 仍存在甬哥标识！');
  fs.writeFileSync(path.join(ROOT_DIR, 'sb.sh'), cleanSb, 'utf8');
  console.log('[✔] sb.sh 处理完成并写入成功！\n');

  // 2. 处理 acme.sh (选项 11)
  console.log('>>> [2/3] 同步并处理 Acme 域名证书脚本 acme.sh (选项 11) ...');
  const rawAcme = await fetchFromMirrors('yonggekkk/acme-yg/main/acme.sh');
  const cleanAcme = transformAcme(rawAcme);
  if (!cleanAcme.includes('晓林技术服务')) throw new Error('acme.sh 缺少 晓林技术服务 标识！');
  if (cleanAcme.includes('甬哥Github项目')) throw new Error('acme.sh 仍存在甬哥标识！');
  fs.writeFileSync(path.join(ROOT_DIR, 'acme.sh'), cleanAcme, 'utf8');
  console.log('[✔] acme.sh 处理完成并写入成功！\n');

  // 3. 处理 warp.sh (选项 12)
  console.log('>>> [3/3] 同步并处理 WARP 管理脚本 warp.sh (选项 12) ...');
  const rawWarp = await fetchFromMirrors('yonggekkk/warp-yg/main/CFwarp.sh');
  const cleanWarp = transformWarp(rawWarp);
  if (!cleanWarp.includes('晓林技术服务')) throw new Error('warp.sh 缺少 晓林技术服务 标识！');
  if (cleanWarp.includes('甬哥Github项目')) throw new Error('warp.sh 仍存在甬哥标识！');
  fs.writeFileSync(path.join(ROOT_DIR, 'warp.sh'), cleanWarp, 'utf8');
  console.log('[✔] warp.sh 处理完成并写入成功！\n');

  console.log('========================================================');
  console.log('🎉 恭喜！sb.sh / acme.sh / warp.sh 全部晓林定制完成！');
  console.log('   今后点击任何子选项，绝不会再出现勇哥标识！');
  console.log('========================================================');
}

main().catch(err => {
  console.error('[!] 处理发生错误:', err);
  process.exit(1);
});
