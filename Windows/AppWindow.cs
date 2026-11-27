using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Forms;
using static AskAI.UI;

namespace AskAI {
    internal sealed class AppWindow : Form {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr window, int id);

        private readonly TextBox input = new TextBox { Multiline = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical };
        private readonly TextBox output = new TextBox { Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical };
        private readonly Button ask = new Button { Text = L("解释", "Explain"), AutoSize = true };
        private readonly Label status = new Label { AutoSize = true, Anchor = AnchorStyles.Left };
        private readonly Catalog catalog;
        private Preferences settings;
        private readonly NotifyIcon tray;
        private CancellationTokenSource active;
        private bool capturing, quitting, registered;

        internal AppWindow(Preferences settings, Catalog catalog) {
            this.settings = settings;
            this.catalog = catalog;
            Text = "AskAI";
            Size = new Size(640, 440);
            MinimumSize = new Size(420, 260);
            var grid = new TableLayoutPanel { ColumnCount = 1, RowCount = 4, Dock = DockStyle.Fill, Padding = new Padding(10) };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 30));
            grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 70));
            grid.Controls.Add(new Label { Text = L("选中文字后按 Ctrl+Shift+E，或在此输入", "Select text and press Ctrl+Shift+E, or type here"), AutoSize = true }, 0, 0);
            grid.Controls.Add(input, 0, 1);
            var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
            var configure = new Button { Text = L("设置", "Settings"), AutoSize = true };
            configure.Click += (sender, args) => {
                using (var dialog = new SettingsWindow(this.settings, catalog))
                    if (dialog.ShowDialog(this) == DialogResult.OK) this.settings = dialog.Saved;
            };
            ask.Click += async (sender, args) => {
                if (active != null) active.Cancel();
                else await Explain();
            };
            actions.Controls.AddRange(new Control[] { ask, configure, status });
            grid.Controls.Add(actions, 0, 2);
            grid.Controls.Add(output, 0, 3);
            Controls.Add(grid);
            var menu = new ContextMenuStrip();
            menu.Items.Add(L("打开 AskAI", "Open AskAI"), null, (s, e) => Reveal());
            menu.Items.Add(L("退出", "Quit"), null, (s, e) => { quitting = true; Close(); });
            tray = new NotifyIcon { Text = "AskAI", Icon = SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
            tray.DoubleClick += (s, e) => Reveal();
            Shown += (s, e) => {
                registered = RegisterHotKey(Handle, 1, 0x4006, (uint)Keys.E); // Ctrl + Shift, suppress repeats
                if (!registered) status.Text = L("快捷键已占用，可手动输入。", "Hotkey unavailable. Type or paste text.");
            };
        }

        private void Reveal() {
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
        }

        protected override void WndProc(ref Message message) {
            if (message.Msg == 0x0312 && message.WParam.ToInt32() == 1) {
                if (!capturing && active == null && Enabled) CaptureSelection();
                return;
            }
            base.WndProc(ref message);
        }

        private static string SelectedText() {
            var element = AutomationElement.FocusedElement;
            object value;
            if (element == null || element.Current.IsPassword ||
                !element.TryGetCurrentPattern(TextPattern.Pattern, out value)) return "";
            var ranges = ((TextPattern)value).GetSelection();
            return ranges.Length == 0 ? "" : ranges[0].GetText(-1);
        }

        private async void CaptureSelection() {
            capturing = true;
            try {
                string selection;
                try { selection = await Task.Run(() => SelectedText()); }
                catch (Exception) { selection = ""; } // Providers can disappear with their source window.
                if (quitting || IsDisposed || active != null) return;
                Reveal();
                input.Text = selection;
                if (String.IsNullOrWhiteSpace(selection)) {
                    status.Text = L("未读取到选区，请粘贴文字。", "No readable selection. Paste the text here.");
                    input.Focus();
                } else await Explain();
            } finally { capturing = false; }
        }

        private async Task Explain() {
            if (active != null || String.IsNullOrWhiteSpace(input.Text)) return;
            using (var cancel = new CancellationTokenSource(TimeSpan.FromMinutes(3))) {
                active = cancel;
                ask.Text = L("停止", "Stop");
                output.Clear();
                status.Text = L("正在请求…", "Requesting…");
                try {
                    await ChatClient.Stream(settings, catalog.Prompt(settings.Background, settings.Language),
                        input.Text, text => output.AppendText(text), cancel.Token);
                    status.Text = "";
                } catch (Exception error) {
                    if (!quitting) status.Text = cancel.IsCancellationRequested ? L("已停止", "Stopped") : error.Message;
                } finally {
                    active = null;
                    if (!quitting) ask.Text = L("解释", "Explain");
                }
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e) {
            if (!quitting && e.CloseReason == CloseReason.UserClosing) {
                e.Cancel = true;
                Hide();
            } else {
                quitting = true;
                active?.Cancel();
                if (registered) UnregisterHotKey(Handle, 1);
                tray.Dispose();
            }
            base.OnFormClosing(e);
        }
    }

    internal static class Program {
        [STAThread]
        private static void Main() {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try { Application.Run(new AppWindow(Preferences.Load(), Catalog.Load())); }
            catch (Exception error) { MessageBox.Show(error.Message, "AskAI"); }
        }
    }
}
