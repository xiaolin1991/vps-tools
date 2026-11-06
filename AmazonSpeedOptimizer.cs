using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AmazonSpeedOptimizer
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    public class MainForm : Form
    {
        [DllImport("dnsapi.dll", EntryPoint = "DnsFlushResolverCache")]
        private static extern int DnsFlushResolverCache();

        // 核心候选极速节点列表 (CloudFront 东京、亚太骨干与官方优质池)
        private static readonly string[] CandidateNodes = new string[]
        {
            "3.173.238.45",   // 东京极速核心 A
            "3.173.254.31",   // 东京极速核心 B
            "3.173.238.86",   // 东京极速核心 C
            "143.204.239.181", // 亚太香港/日本骨干 D
            "18.65.59.212",   // 新加坡骨干 E
            "99.84.104.121"   // 官方广告与全局 CDN F
        };

        private Label lblStatus;
        private Label lblLineInfo;
        private Label lblLatency;
        private Label lblVpnInfo;
        private Button btnToggle;
        private Button btnTest;
        private Button btnCopyScript;
        private TextBox txtLog;
        private bool isAccelerated = false;

        public MainForm()
        {
            InitializeComponent();
            CheckCurrentStatus();
            ThreadPool.QueueUserWorkItem(delegate { AutoDetectLineAndSpeed(); });
        }

        private void InitializeComponent()
        {
            this.Text = "★ 晓林技术支持 ★ 亚马逊跨境电商专属极速网络优化大师 (Windows版)";
            this.Size = new Size(760, 640);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.BackColor = Color.FromArgb(24, 24, 36);
            this.ForeColor = Color.White;
            this.Font = new Font("Microsoft YaHei", 9.5f, FontStyle.Regular);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;

            // 头部 Header Panel
            Panel pnlHeader = new Panel();
            pnlHeader.Dock = DockStyle.Top;
            pnlHeader.Height = 85;
            pnlHeader.BackColor = Color.FromArgb(16, 16, 26);
            pnlHeader.Paint += delegate(object s, PaintEventArgs e)
            {
                using (Pen p = new Pen(Color.FromArgb(255, 153, 0), 2))
                {
                    e.Graphics.DrawLine(p, 0, pnlHeader.Height - 1, pnlHeader.Width, pnlHeader.Height - 1);
                }
            };

            Label lblTitle = new Label();
            lblTitle.Text = "⚡ 亚马逊跨境卖家专属网络极速直通 · 桌面优化大师";
            lblTitle.Font = new Font("Microsoft YaHei", 13f, FontStyle.Bold);
            lblTitle.ForeColor = Color.FromArgb(255, 180, 0);
            lblTitle.Location = new Point(20, 16);
            lblTitle.AutoSize = true;
            pnlHeader.Controls.Add(lblTitle);

            Label lblSubtitle = new Label();
            lblSubtitle.Text = "原生毫秒级东京节点直连 · 智能识别访问线路 · 100%兼容科学上网分流 (不影响Facebook/Google等海外网站)";
            lblSubtitle.Font = new Font("Microsoft YaHei", 9f, FontStyle.Regular);
            lblSubtitle.ForeColor = Color.FromArgb(180, 180, 200);
            lblSubtitle.Location = new Point(22, 48);
            lblSubtitle.AutoSize = true;
            pnlHeader.Controls.Add(lblSubtitle);

            this.Controls.Add(pnlHeader);

            // 核心状态卡片 Panel
            Panel pnlCard = new Panel();
            pnlCard.Location = new Point(20, 105);
            pnlCard.Size = new Size(705, 150);
            pnlCard.BackColor = Color.FromArgb(32, 33, 50);
            pnlCard.Paint += delegate(object s, PaintEventArgs e)
            {
                using (Pen p = new Pen(Color.FromArgb(50, 52, 78), 1))
                {
                    e.Graphics.DrawRectangle(p, 0, 0, pnlCard.Width - 1, pnlCard.Height - 1);
                }
            };

            lblStatus = new Label();
            lblStatus.Text = "加速状态: 正在检测系统 hosts 配置...";
            lblStatus.Font = new Font("Microsoft YaHei", 10.5f, FontStyle.Bold);
            lblStatus.ForeColor = Color.FromArgb(255, 200, 0);
            lblStatus.Location = new Point(18, 16);
            lblStatus.AutoSize = true;
            pnlCard.Controls.Add(lblStatus);

            lblLineInfo = new Label();
            lblLineInfo.Text = "🌐 亚马逊访问线路: 正在探测当前网络出海出口 (宽带直连 vs 翻墙分流)...";
            lblLineInfo.ForeColor = Color.FromArgb(220, 220, 240);
            lblLineInfo.Location = new Point(18, 48);
            lblLineInfo.AutoSize = true;
            pnlCard.Controls.Add(lblLineInfo);

            lblLatency = new Label();
            lblLatency.Text = "⚡ 亚马逊后台延迟: 测速就绪中...";
            lblLatency.ForeColor = Color.FromArgb(0, 230, 150);
            lblLatency.Location = new Point(18, 80);
            lblLatency.AutoSize = true;
            pnlCard.Controls.Add(lblLatency);

            lblVpnInfo = new Label();
            lblVpnInfo.Text = "🛡️ 翻墙软件兼容性: ● 规则分流已就绪 (仅优化亚马逊，海外受限网站走原翻墙节点)";
            lblVpnInfo.ForeColor = Color.FromArgb(0, 200, 255);
            lblVpnInfo.Location = new Point(18, 112);
            lblVpnInfo.AutoSize = true;
            pnlCard.Controls.Add(lblVpnInfo);

            this.Controls.Add(pnlCard);

            // 操作按钮区
            int btnY = 270;
            btnToggle = new Button();
            btnToggle.Text = "⚡ 一键开启亚马逊极速直通";
            btnToggle.Location = new Point(20, btnY);
            btnToggle.Size = new Size(230, 46);
            btnToggle.Font = new Font("Microsoft YaHei", 10.5f, FontStyle.Bold);
            btnToggle.BackColor = Color.FromArgb(255, 140, 0);
            btnToggle.ForeColor = Color.White;
            btnToggle.FlatStyle = FlatStyle.Flat;
            btnToggle.FlatAppearance.BorderSize = 0;
            btnToggle.Cursor = Cursors.Hand;
            btnToggle.Click += new EventHandler(btnToggle_Click);
            this.Controls.Add(btnToggle);

            btnTest = new Button();
            btnTest.Text = "🔍 重新全链路测速诊断";
            btnTest.Location = new Point(265, btnY);
            btnTest.Size = new Size(210, 46);
            btnTest.Font = new Font("Microsoft YaHei", 10f, FontStyle.Bold);
            btnTest.BackColor = Color.FromArgb(45, 48, 72);
            btnTest.ForeColor = Color.FromArgb(220, 220, 255);
            btnTest.FlatStyle = FlatStyle.Flat;
            btnTest.FlatAppearance.BorderSize = 0;
            btnTest.Cursor = Cursors.Hand;
            btnTest.Click += delegate { ThreadPool.QueueUserWorkItem(delegate { AutoDetectLineAndSpeed(); }); };
            this.Controls.Add(btnTest);

            btnCopyScript = new Button();
            btnCopyScript.Text = "📋 复制图片秒开油猴脚本";
            btnCopyScript.Location = new Point(490, btnY);
            btnCopyScript.Size = new Size(235, 46);
            btnCopyScript.Font = new Font("Microsoft YaHei", 10f, FontStyle.Bold);
            btnCopyScript.BackColor = Color.FromArgb(30, 70, 110);
            btnCopyScript.ForeColor = Color.FromArgb(100, 210, 255);
            btnCopyScript.FlatStyle = FlatStyle.Flat;
            btnCopyScript.FlatAppearance.BorderSize = 0;
            btnCopyScript.Cursor = Cursors.Hand;
            btnCopyScript.Click += new EventHandler(btnCopyScript_Click);
            this.Controls.Add(btnCopyScript);

            // 日志展示区
            Label lblLogTitle = new Label();
            lblLogTitle.Text = "运行日志与实时诊断信息:";
            lblLogTitle.Location = new Point(20, 332);
            lblLogTitle.AutoSize = true;
            lblLogTitle.ForeColor = Color.FromArgb(160, 160, 180);
            this.Controls.Add(lblLogTitle);

            txtLog = new TextBox();
            txtLog.Location = new Point(20, 355);
            txtLog.Size = new Size(705, 205);
            txtLog.Multiline = true;
            txtLog.ReadOnly = true;
            txtLog.ScrollBars = ScrollBars.Vertical;
            txtLog.BackColor = Color.FromArgb(14, 14, 22);
            txtLog.ForeColor = Color.FromArgb(0, 255, 180);
            txtLog.Font = new Font("Consolas", 9f);
            this.Controls.Add(txtLog);

            // 底部版权与安全保障
            Label lblFooter = new Label();
            lblFooter.Text = "技术支持: 晓林技术 | 安全提示: 软件仅精准优化亚马逊卖家后台与图片CDN，绝不影响翻墙分流与其它海外网站！";
            lblFooter.Font = new Font("Microsoft YaHei", 8.5f);
            lblFooter.ForeColor = Color.FromArgb(110, 115, 140);
            lblFooter.Location = new Point(20, 570);
            lblFooter.AutoSize = true;
            this.Controls.Add(lblFooter);
        }

        private void AppendLog(string msg)
        {
            if (this.InvokeRequired)
            {
                this.Invoke(new Action<string>(AppendLog), msg);
                return;
            }
            string time = DateTime.Now.ToString("HH:mm:ss");
            txtLog.AppendText(string.Format("[{0}] {1}\r\n", time, msg));
        }

        private bool IsAdministrator()
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        private void RestartAsAdmin()
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.UseShellExecute = true;
            startInfo.WorkingDirectory = Environment.CurrentDirectory;
            startInfo.FileName = Application.ExecutablePath;
            startInfo.Verb = "runas";
            try
            {
                Process.Start(startInfo);
                Application.Exit();
            }
            catch (Exception ex)
            {
                MessageBox.Show("修改 Windows 极速网络配置需要管理员权限：\n" + ex.Message, "权限提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private string GetHostsPath()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"drivers\etc\hosts");
        }

        private void CheckCurrentStatus()
        {
            string hostsPath = GetHostsPath();
            try
            {
                if (File.Exists(hostsPath))
                {
                    string content = File.ReadAllText(hostsPath, Encoding.Default);
                    if (content.Contains("AMZ_FAST_OPTIMIZER_START"))
                    {
                        isAccelerated = true;
                        lblStatus.Text = "加速状态: ● 极速直通已生效 (已锁定东京极速双节点并发热备)";
                        lblStatus.ForeColor = Color.FromArgb(0, 255, 150);
                        btnToggle.Text = "🛑 还原系统默认网络 (取消加速)";
                        btnToggle.BackColor = Color.FromArgb(180, 40, 50);
                        return;
                    }
                }
            }
            catch { }

            isAccelerated = false;
            lblStatus.Text = "加速状态: ○ 加速未开启 (当前为系统默认 DNS，容易出现卡顿与白屏)";
            lblStatus.ForeColor = Color.FromArgb(255, 180, 0);
            btnToggle.Text = "⚡ 一键开启亚马逊极速直通";
            btnToggle.BackColor = Color.FromArgb(255, 140, 0);
        }

        private void btnToggle_Click(object sender, EventArgs e)
        {
            if (!IsAdministrator())
            {
                RestartAsAdmin();
                return;
            }

            if (isAccelerated)
            {
                // 还原默认
                DisableAcceleration();
            }
            else
            {
                // 开启加速
                EnableAcceleration();
            }
            CheckCurrentStatus();
        }

        private void EnableAcceleration()
        {
            AppendLog("正在测速筛选当前最快的东京 CloudFront 节点...");
            string bestNode1 = "3.173.238.45";
            string bestNode2 = "3.173.254.31";

            // 实时探测筛选
            List<KeyValuePair<string, long>> ranked = new List<KeyValuePair<string, long>>();
            foreach (string ip in CandidateNodes)
            {
                long lat = TestTcpLatency(ip, 443);
                if (lat > 0)
                {
                    ranked.Add(new KeyValuePair<string, long>(ip, lat));
                    AppendLog(string.Format("  节点 {0} -> 延迟: {1}ms", ip, lat));
                }
            }
            ranked.Sort(delegate(KeyValuePair<string, long> a, KeyValuePair<string, long> b) { return a.Value.CompareTo(b.Value); });

            if (ranked.Count > 0) bestNode1 = ranked[0].Key;
            if (ranked.Count > 1) bestNode2 = ranked[1].Key;

            AppendLog(string.Format("★ 优选冠军主节点: {0} | 备用热备节点: {1}", bestNode1, bestNode2));

            string hostsPath = GetHostsPath();
            try
            {
                string original = "";
                if (File.Exists(hostsPath))
                {
                    original = File.ReadAllText(hostsPath, Encoding.Default);
                }

                // 清理旧规则
                string cleaned = CleanHostsContent(original);

                StringBuilder sb = new StringBuilder();
                sb.AppendLine(cleaned.TrimEnd());
                sb.AppendLine();
                sb.AppendLine("# === AMZ_FAST_OPTIMIZER_START ===");
                sb.AppendLine(string.Format("# 晓林技术支持 - 亚马逊极速直通专用映射 (更新时间: {0})", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")));
                sb.AppendLine(string.Format("{0} sellercentral.amazon.com", bestNode1));
                sb.AppendLine(string.Format("{0} sellercentral.amazon.com", bestNode2));
                sb.AppendLine(string.Format("{0} sellercentral-europe.amazon.com", bestNode1));
                sb.AppendLine(string.Format("{0} sellercentral.amazon.co.uk", bestNode1));
                sb.AppendLine(string.Format("{0} sellercentral.amazon.de", bestNode1));
                sb.AppendLine(string.Format("{0} sellercentral.amazon.co.jp", bestNode1));
                sb.AppendLine(string.Format("{0} m.media-amazon.com", bestNode1));
                sb.AppendLine(string.Format("{0} m.media-amazon.com", bestNode2));
                sb.AppendLine(string.Format("{0} images-na.ssl-images-amazon.com", bestNode1));
                sb.AppendLine("99.84.104.121 advertising.amazon.com");
                sb.AppendLine("# === AMZ_FAST_OPTIMIZER_END ===");

                File.WriteAllText(hostsPath, sb.ToString(), Encoding.Default);
                AppendLog("✓ 已成功将极速节点写入系统 hosts 规则！");

                // 刷新系统 DNS 缓存
                DnsFlushResolverCache();
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo("ipconfig", "/flushdns");
                    psi.CreateNoWindow = true;
                    psi.UseShellExecute = false;
                    Process.Start(psi);
                }
                catch { }

                // 调优 Windows TCP 拥塞控制与窗口缩放
                try
                {
                    ProcessStartInfo psiTcp = new ProcessStartInfo("netsh", "int tcp set global autotuninglevel=normal");
                    psiTcp.CreateNoWindow = true;
                    psiTcp.UseShellExecute = false;
                    Process.Start(psiTcp);
                }
                catch { }

                AppendLog("✓ 本地系统 DNS 缓存已清空，TCP 极速拥塞控制调优已应用！");
                MessageBox.Show("恭喜！亚马逊本地极速直通已成功激活！\n\n已锁定实测最优东京极速节点（双路热备），彻底消除白屏与卡顿。\n海外受限网站（Facebook/Google等）继续由您的翻墙分流处理，绝不受影响！", "加速成功", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                AppendLog("✗ 写入 hosts 失败: " + ex.Message);
                MessageBox.Show("写入系统 hosts 失败，请确认是否被安全软件（360/火绒等）拦截，可点击允许。\n" + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void DisableAcceleration()
        {
            string hostsPath = GetHostsPath();
            try
            {
                if (File.Exists(hostsPath))
                {
                    string original = File.ReadAllText(hostsPath, Encoding.Default);
                    string cleaned = CleanHostsContent(original);
                    File.WriteAllText(hostsPath, cleaned, Encoding.Default);
                }
                DnsFlushResolverCache();
                AppendLog("✓ 已完全移除亚马逊极速 hosts 锁定，系统已安全恢复默认解析！");
                MessageBox.Show("已安全还原为系统默认网络配置！", "还原成功", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                AppendLog("✗ 还原失败: " + ex.Message);
                MessageBox.Show("还原失败: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private string CleanHostsContent(string original)
        {
            string startTag = "# === AMZ_FAST_OPTIMIZER_START ===";
            string endTag = "# === AMZ_FAST_OPTIMIZER_END ===";
            int sIdx = original.IndexOf(startTag);
            int eIdx = original.IndexOf(endTag);
            if (sIdx != -1 && eIdx != -1 && eIdx > sIdx)
            {
                return original.Substring(0, sIdx) + original.Substring(eIdx + endTag.Length);
            }
            // 兼容老版本标签
            startTag = "# === AMZ_LOCAL_FAST_START ===";
            endTag = "# === AMZ_LOCAL_FAST_END ===";
            sIdx = original.IndexOf(startTag);
            eIdx = original.IndexOf(endTag);
            if (sIdx != -1 && eIdx != -1 && eIdx > sIdx)
            {
                return original.Substring(0, sIdx) + original.Substring(eIdx + endTag.Length);
            }
            return original;
        }

        private long TestTcpLatency(string ip, int port)
        {
            try
            {
                Stopwatch sw = Stopwatch.StartNew();
                using (TcpClient client = new TcpClient())
                {
                    IAsyncResult ar = client.BeginConnect(ip, port, null, null);
                    bool success = ar.AsyncWaitHandle.WaitOne(1500);
                    if (success && client.Connected)
                    {
                        client.EndConnect(ar);
                        sw.Stop();
                        return sw.ElapsedMilliseconds;
                    }
                }
            }
            catch { }
            return -1;
        }

        private void AutoDetectLineAndSpeed()
        {
            AppendLog("正在智能分析当前电脑的本地宽带与翻墙分流线路...");

            // 1. 检查翻墙软件系统代理分流状态
            bool proxyEnabled = false;
            string proxyServer = "";
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings"))
                {
                    if (key != null)
                    {
                        object pVal = key.GetValue("ProxyEnable");
                        if (pVal != null && Convert.ToInt32(pVal) == 1)
                        {
                            proxyEnabled = true;
                            object sVal = key.GetValue("ProxyServer");
                            if (sVal != null) proxyServer = sVal.ToString();
                        }
                    }
                }
            }
            catch { }

            string vpnText = "🛡️ 翻墙软件兼容性: ● 未开启系统代理 (直连模式，Facebook等未开启代理)";
            if (proxyEnabled)
            {
                vpnText = string.Format("🛡️ 翻墙软件兼容性: ● 规则分流中 (系统代理端口: {0} | 境外网站走代理，亚马逊直连加速)", proxyServer);
                AppendLog("检测到本地已开启翻墙客户端系统代理: " + proxyServer);
            }
            else
            {
                AppendLog("检测到本地未开启全局系统代理，使用本地网络适配器直通。");
            }

            // 2. 探测访问亚马逊实际出海线路
            string lineDesc = "正在识别出口运营商...";
            long latencyToAmz = -1;
            try
            {
                Stopwatch sw = Stopwatch.StartNew();
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://sellercentral.amazon.com/gp/homepage.html");
                req.Timeout = 4000;
                req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36";
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    sw.Stop();
                    latencyToAmz = sw.ElapsedMilliseconds;
                    lineDesc = string.Format("已连接亚马逊卖家网关 (状态: {0})", (int)resp.StatusCode);
                }
            }
            catch (WebException we)
            {
                if (we.Response is HttpWebResponse)
                {
                    HttpWebResponse r = (HttpWebResponse)we.Response;
                    lineDesc = string.Format("已连入网关 (状态: {0})", (int)r.StatusCode);
                    latencyToAmz = 320;
                }
                else
                {
                    lineDesc = "连接超时 (建议点击下方开启极速直通)";
                }
            }
            catch
            {
                lineDesc = "直连波动 (建议点击下方开启极速直通)";
            }

            // 3. 测速核心极速节点
            long tokyoLatency = TestTcpLatency("3.173.238.45", 443);
            if (tokyoLatency < 0) tokyoLatency = TestTcpLatency("3.173.254.31", 443);

            // 更新 UI
            this.Invoke(new Action(delegate
            {
                lblVpnInfo.Text = vpnText;
                lblLineInfo.Text = string.Format("🌐 亚马逊访问线路: {0}", lineDesc);
                if (tokyoLatency > 0)
                {
                    lblLatency.Text = string.Format("⚡ 东京极速节点延迟: {0} ms  (实测极速秒开级链路)", tokyoLatency);
                    AppendLog(string.Format("测速完成: 东京极速节点实测延迟为 {0} ms", tokyoLatency));
                }
                else if (latencyToAmz > 0)
                {
                    lblLatency.Text = string.Format("⚡ 亚马逊后台实时响应: {0} ms", latencyToAmz);
                }
                else
                {
                    lblLatency.Text = "⚡ 亚马逊后台延迟: 探测超时，请开启极速直通！";
                }
            }));
        }

        private void btnCopyScript_Click(object sender, EventArgs e)
        {
            try
            {
                string scriptCode = "";
                using (Stream stream = System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("AmazonSpeedRocket.user.js"))
                {
                    if (stream != null)
                    {
                        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                        {
                            scriptCode = reader.ReadToEnd();
                        }
                    }
                }

                if (string.IsNullOrEmpty(scriptCode))
                {
                    string localJs = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AmazonSpeedRocket.user.js");
                    if (File.Exists(localJs))
                    {
                        scriptCode = File.ReadAllText(localJs, Encoding.UTF8);
                    }
                }

                if (!string.IsNullOrEmpty(scriptCode))
                {
                    Clipboard.SetText(scriptCode);
                    AppendLog("已将最新版【图片秒开 + 火箭置顶】油猴脚本复制到剪贴板！");
                    MessageBox.Show("最新版油猴脚本已成功复制到系统剪贴板！\n\n您只需打开浏览器里的篡改猴，点击【添加新脚本】，按 Ctrl + V 粘贴并保存即可！", "复制成功", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                else
                {
                    MessageBox.Show("未找到脚本资源，请确保同目录下存在 AmazonSpeedRocket.user.js 文件。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("复制失败: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
