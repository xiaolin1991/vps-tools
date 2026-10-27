# 📦 亚马逊中国本土卖家 VPS 加速与防关联管理面板 (v7.3 旗舰版)

这个脚本专为亚马逊卖家（尤其是浙江杭州、广东深圳等使用国内同城 IP 运营以防触发视频验证的卖家）设计，集成了 **亚马逊本家权威 DNS (AWS Route53) + 15 大跨国骨干 DNS 直采**、**页面刷不出 3 秒内自动换节点的实时故障自愈守护 (`amazon-failover`)**、**7 大核心站点（含商品图片 CDN）100% 全绿极速锁定**、**BBR + 64MB 极限缓冲**、**Socks5/HTTP 双协议代理（内置防失联双保险内核）** 以及 **面板内一键在线更新最新版本（菜单 `[14]`）**。

### 🚀 国内 VPS 一键安装 / 强制刷新命令（自带 DNS 自愈 + 防缓存时间戳，快捷呼出命令：`vps`）

请在你的 VPS 终端（SSH）直接复制粘贴以下整行命令回车：

#### 通道一：2026 国内极速镜像版（`ghfast.top`，最推荐）
```bash
rm -f /etc/resolv.conf && printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf && wget -4 -O /usr/bin/vps "https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh?t=$(date +%s)" && chmod +x /usr/bin/vps && vps
```

#### 通道二：国内备用镜像版（`gh-proxy.com`）
```bash
rm -f /etc/resolv.conf && printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf && wget -4 -O /usr/bin/vps "https://gh-proxy.com/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh?t=$(date +%s)" && chmod +x /usr/bin/vps && vps
```

#### 通道三：海外 VPS 直连版（`raw.githubusercontent.com`）
```bash
wget -4 -O /usr/bin/vps "https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh?t=$(date +%s)" && chmod +x /usr/bin/vps && vps
```

### VPS 专用 `sb` 一键脚本（快捷方式：`sb`）
```bash
bash <(curl -4 -Ls https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh)
```