using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Program
{
    internal static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    internal static string Package;
    internal static string TestRoot;

    [STAThread]
    private static int Main(string[] args)
    {
        bool testing = args.Length == 2 && args[0] == "--self-test";
        bool admin = args.Length == 1 && args[0] == "--admin";
        if (args.Length != 0 && !testing && !admin) return 2;
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool owner;
        using (var mutex = new Mutex(true, @"Local\CodexViaServerSetup-" + WindowsIdentity.GetCurrent().User.Value + (testing ? "-test" : ""), out owner))
        {
            if (!owner) { if (!testing) MessageBox.Show("安装程序已在运行，请回到已打开的窗口。", "Codex 服务器连接"); return 2; }
            try
            {
                if (testing)
                {
                    TestRoot = Path.GetFullPath(args[1]);
                    if (Directory.Exists(TestRoot) || File.Exists(TestRoot)) return 2;
                    EnsureSafePath(TestRoot);
                    Directory.CreateDirectory(TestRoot); Protect(TestRoot);
                    Package = Extract(TestRoot);
                    SelfChecks();
                    var result = RunAction("SelfTest", null, null);
                    File.WriteAllText(Path.Combine(TestRoot, "self-test.json"), Json.Serialize(result), Encoding.UTF8);
                    return Convert.ToBoolean(result["Ok"]) ? 0 : 1;
                }
                if (admin)
                {
                    Package = Extract(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexViaServer"));
                    Application.Run(new AdminForm());
                }
                else Application.Run(new SetupForm());
                return 0;
            }
            catch
            {
                if (testing) File.WriteAllText(Path.Combine(TestRoot, "self-test.json"), "{\"Ok\":false,\"Code\":\"bootstrap_failed\"}");
                else MessageBox.Show("安装包无法准备。请检查磁盘空间、文件是否完整及当前用户的写入权限。", "Codex 服务器连接", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }

    internal static void EnsureSafePath(string path)
    {
        for (string cursor = Path.GetFullPath(path); !String.IsNullOrEmpty(cursor); cursor = Path.GetDirectoryName(cursor))
            if ((File.Exists(cursor) || Directory.Exists(cursor)) && (File.GetAttributes(cursor) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("unsafe_path");
    }

    internal static void Protect(string path)
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.SetAccessControl(path, security);
    }

    internal static string Hash(Stream stream)
    {
        using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    internal static string EntryPath(string root, string name)
    {
        if (String.IsNullOrEmpty(name) || name.Contains(":") || name.Contains("\\") || name.StartsWith("/")) throw new IOException("unsafe_entry");
        foreach (string part in name.Split('/')) if (part == ".." || part == "." || part.EndsWith(".") || part.EndsWith(" ")) throw new IOException("unsafe_entry");
        string target = Path.GetFullPath(Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar)));
        if (!target.StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("unsafe_entry");
        return target;
    }

    internal static string Extract(string root)
    {
        var assembly = Assembly.GetExecutingAssembly();
        string digest;
        using (var reader = new StreamReader(assembly.GetManifestResourceStream("payload.sha256"))) digest = reader.ReadToEnd().Trim();
        string directory = Path.Combine(root, "packages", digest.Substring(0, 20));
        EnsureSafePath(directory);
        if (File.Exists(Path.Combine(directory, ".complete")))
        {
            using (var reader = new StreamReader(assembly.GetManifestResourceStream("payload.manifest")))
                while (!reader.EndOfStream)
                {
                    string[] parts = reader.ReadLine().Split('\t');
                    string file = EntryPath(directory, parts[0]); EnsureSafePath(file);
                    using (var input = File.OpenRead(file)) if (Hash(input) != parts[1]) throw new IOException("installed_hash_mismatch");
                }
            return directory;
        }
        Directory.CreateDirectory(root); Protect(root);
        string staging = Path.Combine(root, "stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging); Protect(staging);
        try
        {
            using (var resource = assembly.GetManifestResourceStream("payload.zip"))
                if (Hash(resource) != digest) throw new IOException("payload_hash_mismatch");
            var manifest = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using (var reader = new StreamReader(assembly.GetManifestResourceStream("payload.manifest")))
                while (!reader.EndOfStream)
                {
                    string[] parts = reader.ReadLine().Split('\t');
                    manifest.Add(parts[0], parts[1]);
                }
            using (var resource = assembly.GetManifestResourceStream("payload.zip"))
            using (var zip = new ZipArchive(resource, ZipArchiveMode.Read))
                foreach (var entry in zip.Entries)
                {
                    string target = EntryPath(staging, entry.FullName);
                    string expected;
                    if (!manifest.TryGetValue(entry.FullName, out expected)) throw new IOException("unknown_entry");
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (var input = entry.Open())
                    using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write)) input.CopyTo(output);
                    using (var input = File.OpenRead(target)) if (Hash(input) != expected) throw new IOException("file_hash_mismatch");
                    manifest.Remove(entry.FullName);
                }
            if (manifest.Count != 0) throw new IOException("incomplete_payload");
            File.Copy(assembly.Location, Path.Combine(staging, "Setup.exe"));
            File.WriteAllText(Path.Combine(staging, ".complete"), digest);
            Directory.CreateDirectory(Path.GetDirectoryName(directory));
            Directory.Move(staging, directory);
            return directory;
        }
        finally
        {
            // Only this invocation's new staging directory may be removed.
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
        }
    }

    internal static string Quote(string value)
    {
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
            result.Append(c); slashes = 0;
        }
        result.Append('\\', slashes * 2); return result.Append('"').ToString();
    }

    internal static Dictionary<string, object> RunAction(string action, string profile, string model, Dictionary<string, string> extra = null)
    {
        var arguments = new List<string> { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(Package, "setup", "Actions.ps1"), "-Action", action };
        if (profile != null) { arguments.Add("-ProfilePath"); arguments.Add(profile); }
        if (model != null) { arguments.Add("-Model"); arguments.Add(model); }
        if (extra != null) foreach (var pair in extra) { arguments.Add("-" + pair.Key); arguments.Add(pair.Value); }
        if (TestRoot != null)
        {
            arguments.Add("-ClientHome"); arguments.Add(Path.Combine(TestRoot, "client"));
            arguments.Add("-CodexHome"); arguments.Add(Path.Combine(TestRoot, "codex"));
        }
        var info = new ProcessStartInfo(Path.Combine(Package, "runtime", "pwsh", "pwsh.exe"));
        info.Arguments = String.Join(" ", arguments.ConvertAll(Quote));
        info.UseShellExecute = false; info.CreateNoWindow = true;
        info.RedirectStandardOutput = true; info.RedirectStandardError = true;
        info.StandardOutputEncoding = Encoding.UTF8;
        var keys = new List<string>();
        foreach (string key in info.EnvironmentVariables.Keys) if (key.StartsWith("CODEX_", StringComparison.OrdinalIgnoreCase) || key == "OPENAI_API_KEY" || key == "CLIPROXY_API_KEY" || key == "SERVER_CODEX_API_KEY" || key == "PSModulePath") keys.Add(key);
        foreach (string key in keys) info.EnvironmentVariables.Remove(key);
        using (var process = Process.Start(info))
        {
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            // Vendor Store installation can need user interaction; other actions are bounded by their native calls.
            process.WaitForExit();
            string output = stdout.Result.Trim();
            if (!output.StartsWith("{")) throw new IOException("action_protocol_failed");
            return Json.Deserialize<Dictionary<string, object>>(output);
        }
    }

    private static void SelfChecks()
    {
        foreach (string name in new[] { "../escape", "/escape", "C:/escape", "x/../../escape", "x\\escape", "x./bad" })
        {
            bool rejected = false;
            try { EntryPath(TestRoot, name); } catch (IOException) { rejected = true; }
            if (!rejected) throw new Exception("unsafe_entry_accepted");
        }
        if (Quote("a b\\") != "\"a b\\\\\"" || Quote("a\"b") != "\"a\\\"b\"") throw new Exception("argument_quoting_failed");
        using (var form = new SetupForm(true))
        {
            form.StartPosition = FormStartPosition.Manual; form.Location = new Point(-30000, -30000);
            form.ShowInTaskbar = false; form.Opacity = 0; form.Show(); form.PerformLayout();
            using (var preview = new Bitmap(form.Width, form.Height))
            {
                form.DrawToBitmap(preview, new Rectangle(0, 0, preview.Width, preview.Height));
                preview.Save(Path.Combine(TestRoot, "setup-preview.png"), System.Drawing.Imaging.ImageFormat.Png);
            }
        }
        using (var form = new AdminForm())
        {
            form.StartPosition = FormStartPosition.Manual; form.Location = new Point(-30000, -30000);
            form.ShowInTaskbar = false; form.Opacity = 0; form.Show(); form.PerformLayout();
            using (var preview = new Bitmap(form.Width, form.Height))
            {
                form.DrawToBitmap(preview, new Rectangle(0, 0, preview.Width, preview.Height));
                preview.Save(Path.Combine(TestRoot, "admin-preview.png"), System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }
}

internal sealed class SetupForm : Form
{
    private readonly Label state = new Label();
    private readonly TextBox log = new TextBox();
    private readonly FlowLayoutPanel actions = new FlowLayoutPanel();
    private readonly ComboBox models = new ComboBox();
    private string request;
    private bool busy;

    internal SetupForm(bool preview = false)
    {
        Text = "Codex 服务器连接 · Windows 安装助手";
        ClientSize = new Size(780, 560); MinimumSize = new Size(700, 560);
        Font = new Font("Microsoft YaHei UI", 10); StartPosition = FormStartPosition.CenterScreen;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), RowCount = 6, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 60));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        layout.Controls.Add(new Label { Text = "把这台电脑连接到服务器上的 Codex", Dock = DockStyle.Fill, Font = new Font(Font, FontStyle.Bold) });
        layout.Controls.Add(new Label { Text = "先安装并登录 Tailscale。程序会生成本机独立申请；取得管理员批准文件后，一次完成隧道和登录自启动配置。", Dock = DockStyle.Fill });
        state.Text = "正在准备安装环境，首次解包可能需要一两分钟…"; state.Dock = DockStyle.Fill; state.AccessibleName = "当前安装状态"; layout.Controls.Add(state);
        actions.Dock = DockStyle.Fill; layout.Controls.Add(actions);
        AddButton("生成 / 查看设备申请", async delegate { await Act("Prepare", null, null); });
        AddButton("管理员审批", delegate { if (Program.Package != null) using (var form = new AdminForm()) form.ShowDialog(this); });
        AddButton("打开申请文件夹", delegate { if (request != null) Process.Start("explorer.exe", "/select," + Program.Quote(request)); });
        AddButton("导入批准并配置", async delegate {
            using (var dialog = new OpenFileDialog { Filter = "连接批准文件 (*.json)|*.json", Title = "选择管理员返回的 connection.json" })
                if (dialog.ShowDialog(this) == DialogResult.OK && MessageBox.Show(this, "将配置当前用户的 Codex，注册登录自启动任务。请先关闭其他 Codex 窗口；原配置会备份。是否继续？", "完成配置", MessageBoxButtons.OKCancel) == DialogResult.OK)
                    await Act("Enroll", dialog.FileName, null);
        });
        AddButton("安装官方桌面端", async delegate { await Act("Desktop", null, null); });
        AddButton("检查连接", async delegate { await Act("Check", null, null); });
        AddButton("启动", async delegate { await Act("Start", null, null); });
        AddButton("重启隧道", async delegate {
            if (MessageBox.Show(this, "重启会中断当前通过隧道的请求。继续？", "重启隧道", MessageBoxButtons.OKCancel) == DialogResult.OK) await Act("Restart", null, null);
        });
        AddButton("停止", async delegate {
            if (MessageBox.Show(this, "停止后 Codex 将无法通过隧道连接服务器。继续？", "停止隧道", MessageBoxButtons.OKCancel) == DialogResult.OK) await Act("Stop", null, null);
        });
        AddButton("移除自启动", async delegate {
            if (MessageBox.Show(this, "移除隧道任务并恢复安装前 Codex 配置。保留设备密钥和运行环境。继续？", "移除自启动", MessageBoxButtons.OKCancel) == DialogResult.OK) await Act("Uninstall", null, null);
        });
        log.Multiline = true; log.ReadOnly = true; log.ScrollBars = ScrollBars.Vertical; log.Dock = DockStyle.Fill; log.AccessibleName = "操作结果"; layout.Controls.Add(log);
        var live = new FlowLayoutPanel { Dock = DockStyle.Fill };
        models.Width = 275; models.AccessibleName = "真实测试模型"; models.DropDownStyle = ComboBoxStyle.DropDownList; live.Controls.Add(models);
        var test = new Button { Text = "低用量真实测试", AutoSize = true };
        test.Click += async delegate {
            if (models.SelectedItem == null) { Append("请先检查连接以读取可用模型。"); return; }
            if (MessageBox.Show(this, "将向所选模型发送一次“Reply only OK.”请求，产生少量用量。继续？", "真实请求测试", MessageBoxButtons.OKCancel) == DialogResult.OK) await Act("Live", null, models.Text);
        };
        live.Controls.Add(test); layout.Controls.Add(live); Controls.Add(layout);
        if (!preview) Shown += async delegate {
            busy = true; actions.Enabled = false;
            try { Program.Package = await Task.Run(() => Program.Extract(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexViaServer"))); }
            catch { state.Text = "解包失败。请检查可用空间和文件完整性。"; busy = false; return; }
            busy = false; actions.Enabled = true; await Act("Prepare", null, null);
        };
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) { e.Cancel = true; Append("请等待当前操作完成后关闭。"); } };
    }

    private void AddButton(string title, EventHandler click)
    {
        var button = new Button { Text = title, AutoSize = true, Height = 34 };
        button.Click += click; actions.Controls.Add(button);
    }

    private void Append(string message) { log.AppendText(message + Environment.NewLine); }

    private async Task Act(string action, string profile, string model)
    {
        if (busy || Program.Package == null) return;
        busy = true; actions.Enabled = false; state.Text = "正在处理，请稍候…";
        try
        {
            var result = await Task.Run(() => Program.RunAction(action, profile, model));
            string code = Convert.ToString(result["Code"]);
            state.Text = Describe(code); Append(state.Text);
            if (result.ContainsKey("RequestPath")) { request = Convert.ToString(result["RequestPath"]); Append("只发送此申请文件给管理员：" + request); }
            if (result.ContainsKey("DeviceFingerprint")) Append("与管理员核对设备：" + result["DeviceId"] + "；设备公钥指纹：" + result["DeviceFingerprint"]);
            if (result.ContainsKey("Models"))
            {
                models.Items.Clear(); foreach (object item in (System.Collections.IEnumerable)result["Models"]) models.Items.Add(item);
                if (models.Items.Count > 0) models.SelectedIndex = 0;
            }
            if (result.ContainsKey("DesktopInstalled") && !Convert.ToBoolean(result["DesktopInstalled"])) Append("桌面端尚未安装，可点击“安装官方桌面端”；CLI 已随程序提供。");
            if (code == "configured") Append("请重新打开 Codex Desktop 以加载配置和本机代理绕过设置，再执行一次真实测试。");
        }
        catch { state.Text = "操作未完成。检查软件限制、磁盘空间后重试。详细日志只记录脱敏状态码。"; Append(state.Text); }
        finally { busy = false; actions.Enabled = true; }
    }

    private static string Describe(string code)
    {
        switch (code)
        {
            case "awaiting_approval": return "设备申请已生成。发给管理员批准，再导入返回的连接文件。";
            case "existing_profile": return "发现已有连接配置，已保留。可点击“检查连接”；不会自动重装或重启。";
            case "configured": return "隧道、登录自启动和 Codex 配置已完成，模型列表检查通过。";
            case "healthy": return "隧道和模型列表可用；请用下方真实测试验证模型请求。";
            case "started": return "隧道已启动，健康检查通过。";
            case "restarted": return "隧道已重启，健康检查通过。";
            case "stopped": return "隧道已停止。下次登录仍会启动；永久关闭请移除自启动。";
            case "uninstalled": return "已移除自启动并恢复原 Codex 配置；保留设备身份和便携运行环境。";
            case "desktop_installed": return "检测到官方 Codex Desktop 已安装。";
            case "desktop_install_pending": return "桌面端安装尚未完成。请在官方安装器中完成操作后重试。";
            case "live_passed": return "官方 Codex CLI 真实模型请求完成，返回 OK。";
            case "tailscale_not_ready": return "Tailscale 未就绪。请安装、登录同一网络，再点击生成申请。";
            case "existing_task": return "已有隧道任务，未覆盖。请先检查连接；迁移安装需先从原入口移除自启动。";
            case "profile_rejected": return "批准文件不合法或与本机设备密钥不匹配。请使用这台电脑申请对应的批准文件。";
            case "tunnel_install_failed": return "常驻隧道安装未通过；已尝试回退 Codex 配置。请确认 Tailscale 和管理员批准后重试。";
            case "gateway_unavailable": return "配置存在，但接口暂不可用。请检查 Tailscale，再检查或重启隧道。";
            case "live_failed": return "真实请求失败或未在 90 秒内完成。请换可用模型，检查连接后重试。";
            default: return "操作未完成（" + code + "）。请检查连接和软件权限后重试。";
        }
    }
}
