using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace AskAI {
    internal static class UI {
        internal static readonly bool Chinese = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";
        internal static string L(string zh, string en) => Chinese ? zh : en;
    }

    internal sealed class Profile {
        public string en { get; set; }
        public string zh { get; set; }
        public string hintEn { get; set; }
        public string hintZh { get; set; }
    }

    internal sealed class Catalog {
        public Dictionary<string, string> @base { get; set; }
        public Dictionary<string, string> general { get; set; }
        public Dictionary<string, string> custom { get; set; }
        public Profile[] profiles { get; set; }

        internal static Catalog Load() {
            using (var stream = typeof(Catalog).Assembly.GetManifestResourceStream("AskAI.Explain.json"))
            using (var reader = new StreamReader(stream))
                return new JavaScriptSerializer().Deserialize<Catalog>(reader.ReadToEnd());
        }

        internal string Prompt(string background, string language) {
            var reader = background.Trim();
            var profile = profiles.FirstOrDefault(p => p.en == reader || p.zh == reader);
            string guidance;
            if (reader.Length == 0) guidance = general[language];
            else if (profile != null) guidance = language == "zh" ? profile.hintZh : profile.hintEn;
            else guidance = custom[language] + " · " + reader;
            return guidance + "\n" + @base[language];
        }
    }

    internal sealed class Preferences {
        public string Endpoint { get; set; } = "https://api.deepseek.com/v1/chat/completions";
        public string Model { get; set; } = "deepseek-chat";
        public string ProtectedKey { get; set; } = "";
        public string Background { get; set; } = "";
        public string Language { get; set; } = UI.Chinese ? "zh" : "en";

        internal string SavedKey() {
            if (String.IsNullOrEmpty(ProtectedKey)) return "";
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(ProtectedKey),
                null, DataProtectionScope.CurrentUser));
        }

        internal string EffectiveKey() {
            var env = Environment.GetEnvironmentVariable("ASKAI_KEY");
            return String.IsNullOrWhiteSpace(env) ? SavedKey() : env.Trim();
        }

        internal void SetKey(string value) {
            ProtectedKey = value.Length == 0 ? "" : Convert.ToBase64String(
                ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
        }

        internal void Validate() {
            Uri uri;
            if (!Uri.TryCreate(Endpoint, UriKind.Absolute, out uri) ||
                !(uri.Scheme == "https" || (uri.Scheme == "http" && uri.IsLoopback)))
                throw new ArgumentException(UI.L("请输入 HTTPS 或本机 HTTP 接口地址。", "Enter an HTTPS or localhost HTTP endpoint."));
            if (String.IsNullOrWhiteSpace(Model) || (!uri.IsLoopback && EffectiveKey().Length == 0))
                throw new ArgumentException(UI.L("请填写模型和 API Key（本机接口可以留空）。", "Enter a model and API key (optional for localhost)."));
        }

        internal static Preferences Load() {
            var json = Registry.GetValue(@"HKEY_CURRENT_USER\Software\AskAI", "Settings", null) as string;
            return json == null ? new Preferences() : new JavaScriptSerializer().Deserialize<Preferences>(json);
        }

        internal void Save() {
            Validate();
            Registry.SetValue(@"HKEY_CURRENT_USER\Software\AskAI", "Settings", new JavaScriptSerializer().Serialize(this));
        }
    }
}
