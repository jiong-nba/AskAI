using System;
using System.Drawing;
using System.Windows.Forms;
using static AskAI.UI;

namespace AskAI {
    internal sealed class SettingsWindow : Form {
        internal Preferences Saved { get; private set; }

        internal SettingsWindow(Preferences current, Catalog catalog) {
            Text = L("AskAI 设置", "AskAI Settings");
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = MaximizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            var grid = new TableLayoutPanel { AutoSize = true, Padding = new Padding(12), ColumnCount = 2 };
            Controls.Add(grid);

            var endpoint = new TextBox { Text = current.Endpoint };
            var model = new TextBox { Text = current.Model };
            var key = new TextBox { UseSystemPasswordChar = true, Text = current.SavedKey() };
            var language = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
            language.Items.AddRange(new object[] { "English", "简体中文" });
            language.SelectedIndex = current.Language == "zh" ? 1 : 0;
            var background = new ComboBox { Text = current.Background };
            foreach (var profile in catalog.profiles) background.Items.Add(L(profile.zh, profile.en));
            AddRow(grid, L("接口地址", "Endpoint"), endpoint);
            AddRow(grid, L("模型", "Model"), model);
            AddRow(grid, "API Key", key);
            AddRow(grid, L("回答语言", "Answer language"), language);
            AddRow(grid, L("读者背景（可留空）", "Reader background (optional)"), background);

            var save = new Button { Text = L("保存", "Save"), AutoSize = true, Anchor = AnchorStyles.Right };
            grid.Controls.Add(save, 1, grid.RowCount++);
            AcceptButton = save;
            save.Click += (sender, args) => {
                try {
                    var next = new Preferences { Endpoint = endpoint.Text.Trim(), Model = model.Text.Trim(),
                        Language = language.SelectedIndex == 1 ? "zh" : "en", Background = background.Text.Trim() };
                    next.SetKey(key.Text.Trim());
                    next.Save();
                    Saved = next;
                    DialogResult = DialogResult.OK;
                } catch (Exception error) { MessageBox.Show(this, error.Message, Text); }
            };
        }

        private static void AddRow(TableLayoutPanel grid, string label, Control control) {
            int row = grid.RowCount++;
            grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left }, 0, row);
            control.Width = 330;
            grid.Controls.Add(control, 1, row);
        }
    }
}
