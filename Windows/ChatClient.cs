using System;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace AskAI {
    internal sealed class Delta { public string content { get; set; } }
    internal sealed class Choice {
        public Delta delta { get; set; }
        public string finish_reason { get; set; }
    }
    internal sealed class Chunk { public Choice[] choices { get; set; } }

    internal static class ChatClient {
        private static readonly HttpClient http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });

        internal static async Task Stream(Preferences settings, string prompt, string input,
                                         Action<string> append, CancellationToken token) {
            settings.Validate();
            var json = new JavaScriptSerializer();
            var body = new {
                model = settings.Model,
                stream = true,
                messages = new[] { new { role = "system", content = prompt }, new { role = "user", content = input } }
            };
            using (var request = new HttpRequestMessage(HttpMethod.Post, settings.Endpoint)) {
                var key = settings.EffectiveKey();
                if (key.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
                request.Content = new StringContent(json.Serialize(body), Encoding.UTF8, "application/json");
                using (var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token)) {
                    response.EnsureSuccessStatusCode();
                    using (var stream = await response.Content.ReadAsStreamAsync())
                    using (token.Register(stream.Dispose))
                    using (var reader = new StreamReader(stream)) {
                        bool received = false, finished = false;
                        string line;
                        while ((line = await reader.ReadLineAsync()) != null) {
                            token.ThrowIfCancellationRequested();
                            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
                            var data = line.Substring(5).Trim();
                            if (data == "[DONE]") { finished = true; break; }
                            var chunk = json.Deserialize<Chunk>(data);
                            if (chunk?.choices == null) throw new InvalidDataException(UI.L("服务返回无效数据。", "Invalid response from provider."));
                            if (chunk.choices.Length == 0) continue;
                            var choice = chunk.choices[0];
                            if (!String.IsNullOrEmpty(choice.delta?.content)) {
                                received = true;
                                append(choice.delta.content);
                            }
                            if (!String.IsNullOrEmpty(choice.finish_reason)) finished = true;
                        }
                        token.ThrowIfCancellationRequested();
                        if (!received || !finished)
                            throw new EndOfStreamException(UI.L("未收到完整回答。", "The response was incomplete."));
                    }
                }
            }
        }
    }
}
