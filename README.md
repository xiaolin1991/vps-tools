# 📦 VPS 加速管理面板

这个项目集成了 **亚马逊卖家专属加速面板** 与 **Sing-box 多协议管理面板**，旨在为跨境与网络技术支持提供一站式高效解决方案。

---

### 一、亚马逊本土卖家 VPS 加速管理面板（快捷方式：`vps`）

专为亚马逊本土店铺、跨境多账号隔离与后台秒开加速设计。

##### 🚀 一键安装命令（任选一条执行）：
```bash
# 国际源
wget -O /usr/bin/vps https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh && chmod +x /usr/bin/vps && vps
```

##### 🇨🇳 国内镜像极速通道（推荐国内 VPS，任选其一）：

### 通道一（推荐）
```
wget -4 -O /usr/bin/vps https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh && chmod +x /usr/bin/vps && vps
```
### 通道二
```
wget -4 -O /usr/bin/vps https://gh-proxy.com/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh && chmod +x /usr/bin/vps && vps
```
### 通道三
```
wget -O /usr/bin/vps https://ghproxy.net/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/amazon.sh && chmod +x /usr/bin/vps && vps
```

---

### 二、Sing-box 晓林技术服务多协议管理面板（快捷方式：`sb`）

支持 Vless-reality、Vmess+Argo、Hysteria2、Tuic、Anytls 等多协议共存管理。

##### 🚀 一键安装命令（任选一条执行）：
```bash
# 国际直接源
---
bash <(curl -Ls https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh)

# 国内极速镜像源
---
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/xiaolin1991/vps-tools/main/sb.sh)
```

##### 🔄 一键安全更新命令保持晓林品牌 ：
```bash
sb update
```
或者在 VPS 终端输入 `sb` 调出主菜单后，选择 `16. 更新 晓林技术服务 管理脚本`（或在选项 `7` 中选择 `4` 更新管理脚本）。

---

### 三、GitHub Actions 自动化保障机制

本仓库配置了 **GitHub Actions 全自动同步与去水印工作流**：
1. **全套生态覆盖**：
   - `sb.sh`：主控制管理脚本
   - `acme.sh`：菜单 `11` 域名证书管理工具
   - `warp.sh`：菜单 `12` WARP 解锁与分流管理工具
2. **自动同步与品牌注入**：每天定时拉取官方最新功能，全自动注入 `XIAOLIN` 字符画及“晓林技术服务”专属标题与说明书，彻底去除所有第三方标识。
3. **安全更新源**：所有 VPS 内部调用与更新均锁定为本仓库，确保无论在主菜单还是点击进入子选项（如 Acme 证书申请、WARP 管理），VPS 永远 100% 保持晓林定制，绝不反弹！
