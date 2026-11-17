using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;

internal sealed class AdminForm : Form
{
    private readonly Label status = new Label();
    private readonly TextBox config = new TextBox();
    private readonly FlowLayoutPanel actions = new FlowLayoutPanel();
    private bool busy;

    internal AdminForm()
    {
        Text = "Codex · 管理员设备审批"; ClientSize = new Size(720, 360); MinimumSize = new Size(720, 360);
        Font = new Font("Microsoft YaHei UI", 10); StartPosition = FormStartPosition.CenterParent;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), ColumnCount = 1, RowCount = 5 };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 80));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 85)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.Controls.Add(new Label { Text = "管理员审批：选择申请 → 核对设备 → 导出批准", Dock = DockStyle.Fill, Font = new Font(Font, FontStyle.Bold) });
        layout.Controls.Add(new Label { Text = "仅在持有服务器管理员 SSH 身份的可信电脑操作。首次配置可选择已有连接文件作为服务器参数来源，再选择管理员私钥。程序不会复制私钥，也不会读取服务器 API Key。申请和批准文件需要由你传递。", Dock = DockStyle.Fill });
        config.Dock = DockStyle.Fill; config.ReadOnly = true; config.AccessibleName = "当前管理员配置";
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex-via-server", "config", "admin.json");
        if (File.Exists(path)) config.Text = path;
        layout.Controls.Add(config); actions.Dock = DockStyle.Fill; layout.Controls.Add(actions);
        Add("首次配置", async delegate { await Configure(); });
        Add("选择管理员配置", delegate {
            using (var dialog = new OpenFileDialog { Filter = "管理员配置 (*.json)|*.json", Title = "选择已配置的 admin.json（可沿用 Mac 配置并调整本机密钥路径）" })
                if (dialog.ShowDialog(this) == DialogResult.OK) { config.Text = dialog.FileName; status.Text = "配置已选择，尚未验证。请点击验证管理员连接。"; }
        });
        Add("验证管理员连接", async delegate { await Act("AdminCheck", null, null, null); });
        Add("选择申请并批准", async delegate { await Approve(); });
        status.Text = "尚未验证管理员权限。客户端受限密钥不能用于批准。"; status.Dock = DockStyle.Fill; status.AccessibleName = "管理员操作状态"; layout.Controls.Add(status);
        Controls.Add(layout);
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
    }

    private void Add(string title, EventHandler handler)
    {
        var button = new Button { Text = title, AutoSize = true, Height = 34 }; button.Click += handler; actions.Controls.Add(button);
    }

    private async Task<Dictionary<string, object>> Act(string action, string profile, string fingerprint, Dictionary<string, string> extra)
    {
        if (busy) return null;
        if (action != "AdminConfigure" && action != "AdminRequest" && String.IsNullOrEmpty(config.Text)) { status.Text = "请先配置管理员身份。"; return null; }
        var parameters = extra ?? new Dictionary<string, string>();
        if (!String.IsNullOrEmpty(config.Text)) parameters["AdminConfig"] = config.Text;
        busy = true; actions.Enabled = false; status.Text = "正在处理…";
        try
        {
            var result = await Task.Run(() => Program.RunAction(action, profile, fingerprint, parameters));
            string code = Convert.ToString(result["Code"]);
            switch (code)
            {
                case "admin_config_saved": config.Text = Convert.ToString(result["ConfigPath"]); status.Text = "配置已保存，尚未验证权限。请验证管理员连接。"; break;
                case "admin_connected": status.Text = "管理员身份与服务器设备管理命令验证通过，已有设备 " + result["DeviceCount"] + " 台。"; break;
                case "admin_request_valid": status.Text = "申请校验通过，等待你核对设备。"; break;
                case "admin_approved": status.Text = "服务器已批准。把此文件传回申请电脑，在主界面导入：\n" + result["OutputPath"]; break;
                case "admin_host_unverified": status.Text = "无法按已核实指纹验证服务器，未执行批准。检查网络和管理员配置。"; break;
                case "admin_command_failed": status.Text = "管理员连接或权限不足，或设备管理命令未部署。需要正确的管理员密钥；非 root 用户需已有免交互 sudo 权限。"; break;
                case "admin_result_unknown": status.Text = "服务器审批结果未确认。保留同一申请，恢复网络后再次批准；程序会核对是否已成功。不要重新生成设备身份。"; break;
                case "admin_device_conflict": status.Text = "设备名已被另一身份使用。未覆盖服务器记录。"; break;
                case "admin_request_changed": status.Text = "核对后申请发生变化，已拒绝批准。请重新选择。"; break;
                case "admin_output_exists": status.Text = "输出文件已存在或文件夹不存在，请选择新的保存位置。"; break;
                case "admin_endpoint_mismatch": status.Text = "当前入口要求管理员与隧道使用同一 SSH 地址和端口。不同入口需分别核实指纹，不能直接套用。"; break;
                default: status.Text = "未完成（" + code + "）。请核对申请、管理员配置和本机密钥路径。"; break;
            }
            return result;
        }
        catch { status.Text = "操作未完成。未确认服务器批准结果；请保留原申请重试。"; return null; }
        finally { busy = false; actions.Enabled = true; }
    }

    private async Task Configure()
    {
        string profile, identity, output, user;
        using (var dialog = new OpenFileDialog { Filter = "已有连接批准 (*.json)|*.json", Title = "选择已可信确认的 connection.json，读取服务器地址、指纹和端口" })
        { if (dialog.ShowDialog(this) != DialogResult.OK) return; profile = dialog.FileName; }
        using (var prompt = new Form { Text = "服务器管理员用户名", ClientSize = new Size(420, 135), StartPosition = FormStartPosition.CenterParent, Font = Font })
        {
            var label = new Label { Text = "输入有设备审批权限的 SSH 用户名", Left = 16, Top = 12, Width = 380 };
            var input = new TextBox { Left = 16, Top = 42, Width = 380, Text = "root", AccessibleName = "管理员 SSH 用户名" };
            var ok = new Button { Text = "继续", Left = 300, Top = 86, DialogResult = DialogResult.OK };
            prompt.Controls.AddRange(new Control[] { label, input, ok }); prompt.AcceptButton = ok;
            if (prompt.ShowDialog(this) != DialogResult.OK) return; user = input.Text.Trim();
        }
        using (var dialog = new OpenFileDialog { Filter = "管理员 SSH 私钥|*", Title = "选择本机已有管理员私钥（只保存路径，不复制文件）" })
        { if (dialog.ShowDialog(this) != DialogResult.OK) return; identity = dialog.FileName; }
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex-via-server", "config");
        using (var dialog = new SaveFileDialog { Filter = "管理员配置 (*.json)|*.json", FileName = "admin.json", InitialDirectory = Directory.Exists(directory) ? directory : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), Title = "保存仅供可信管理员使用的配置；不要分发给普通客户端", OverwritePrompt = true })
        { if (dialog.ShowDialog(this) != DialogResult.OK) return; output = dialog.FileName; }
        await Act("AdminConfigure", profile, null, new Dictionary<string, string> { { "AdminUser", user }, { "AdminIdentity", identity }, { "OutputPath", output } });
    }

    private async Task Approve()
    {
        string request, output;
        using (var dialog = new OpenFileDialog { Filter = "设备申请 (*.request.json)|*.request.json|JSON (*.json)|*.json", Title = "选择待批准电脑发送的申请" })
        { if (dialog.ShowDialog(this) != DialogResult.OK) return; request = dialog.FileName; }
        var device = await Act("AdminRequest", request, null, null);
        if (device == null || !Convert.ToBoolean(device["Ok"])) return;
        string fingerprint = Convert.ToString(device["Fingerprint"]);
        if (MessageBox.Show(this, "请通过可信渠道与申请人核对设备和公钥指纹：\n\n设备：" + device["DeviceId"] + "\n平台：" + device["Platform"] + "\n公钥指纹：" + fingerprint + "\n\n确认允许这台设备使用服务器 Codex？", "批准独立设备", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        using (var dialog = new SaveFileDialog { Filter = "连接批准 (*.connection.json)|*.connection.json", FileName = device["DeviceId"] + ".connection.json", OverwritePrompt = true })
        { if (dialog.ShowDialog(this) != DialogResult.OK) return; output = dialog.FileName; }
        await Act("AdminApprove", request, Convert.ToString(device["Confirmation"]), new Dictionary<string, string> { { "OutputPath", output } });
    }
}
