using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using AskAI;

internal static class Program {
    [STAThread]
    static int Main(string[] args) {
        var catalog = Catalog.Load();
        foreach (var profile in catalog.profiles) {
            if (!catalog.Prompt(profile.en, "zh").Contains(profile.hintZh) ||
                !catalog.Prompt(profile.zh, "en").Contains(profile.hintEn)) return 1;
        }
        if (!catalog.Prompt("  ", "en").Contains(catalog.general["en"]) ||
            !catalog.Prompt("Astronomy", "zh").Contains("Astronomy")) return 1;
        var settings = new Preferences { Endpoint = args[0], Model = "fixture", Language = "en", Background = "设计" };
        settings.SetKey("fixture-key");
        if (settings.SavedKey() != "fixture-key" || settings.ProtectedKey.Contains("fixture-key")) return 1;

        // Exercise the ordinary Explain button and Windows message loop against the local HTTP fixture.
        using (var window = new AppWindow(settings, catalog))
        using (var timer = new System.Windows.Forms.Timer { Interval = 100 }) {
            var grid = window.Controls.OfType<TableLayoutPanel>().Single();
            var input = (TextBox)grid.GetControlFromPosition(0, 1);
            var output = (TextBox)grid.GetControlFromPosition(0, 3);
            var actions = grid.GetControlFromPosition(0, 2);
            var button = actions.Controls.OfType<Button>().First();
            var deadline = DateTime.UtcNow.AddSeconds(15);
            var passed = false;
            window.Shown += (s, e) => {
                input.Text = "kerning";
                button.PerformClick();
                timer.Start();
            };
            timer.Tick += (s, e) => {
                passed = output.Text == "fixture answer" && actions.Controls.OfType<Label>().Single().Text == "";
                if (passed || DateTime.UtcNow > deadline) Application.Exit();
            };
            Application.Run(window);
            if (!passed) return 1;
        }
        return 0;
    }
}
