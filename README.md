# lecture-live-translate

Real-time English→Chinese captions for lectures, on macOS.
English speech is transcribed on-device with Whisper (whisper.cpp + Silero VAD). Claude, DeepSeek, or any OpenAI-compatible model translates it live. Every sentence is saved to a Markdown transcript with timestamps.
It was built for following English-taught university courses. Per-course glossaries keep technical terms right.

- Requirements: Apple Silicon Mac, macOS 26+, Xcode Command Line Tools, Homebrew, and your own API key for translation: Claude, DeepSeek, or any OpenAI-compatible endpoint
- Setup: `./setup.sh` installs whisper.cpp, downloads the models (~575 MB) and builds `./livetrans`
- Run: `export ANTHROPIC_API_KEY=...` then `./livetrans --vocab polymer`

---

在 Mac 上实时把英文讲课转成文字，并翻译成中文。适合听英文授课的中国学生：边听边看中文字幕，下课后留下一份中英对照的课堂记录。

## 效果

```
[00:00:21] So the critical extent of reaction for gelation is just this sort of square root
           object or inverse square root object that relates to r, rho, and N.
所以凝胶化的临界反应程度，就是这样一个平方根式，或者说倒平方根式，它与 r、ρ 和 N 有关。

▍ So we will go through some examples. I see that we are just about out of…     ← 正在说的话
▍ 我们会讲一些例子。我看到时间差不多…                                          ← 实时中文
```

- **识别**：Whisper large-v3-turbo 在本机运行（GPU），音频不会上传。对远场收音、专业术语都比系统自带的听写强很多。
- **切句**：Silero VAD 判断老师什么时候停顿，按句切开。老师一直不停顿时，最长 12 秒切一段。
- **边听边翻**：底部实时显示正在说的这句（每秒更新一次），下面是 Claude 流式翻译的中文。
- **定稿精翻**：每句定稿后交给 Claude，结合课程主题、术语表和上下文纠正识别错误，翻成地道的中文，然后固定到窗口上方，可以随时往回翻。
- **记录**：同时写进 `transcripts/<日期_时间>.md`，每句英文配中文，带时间戳。

## 安装

需要：Apple Silicon 的 Mac、macOS 26 或更新、Xcode 命令行工具（`xcode-select --install`）、[Homebrew](https://brew.sh)。

```bash
git clone https://github.com/wyj113/lecture-live-translate.git
cd lecture-live-translate
./setup.sh
```

`setup.sh` 会做三件事：用 Homebrew 装 whisper-cpp；下载两个模型到 `models/`，Whisper 约 574 MB、VAD 约 0.9 MB；编译出 `./livetrans`。
第一次运行时 GPU 要编译一次，会慢十几秒，之后就快了。

想在任何文件夹直接输入 `livetrans`，可以装成全局命令：

```bash
ln -sf "$(pwd)/livetrans" "$(brew --prefix)/bin/livetrans"
```

## 翻译用的 AI（API key 需要自己申请）

翻译需要一个 AI 的 API key，费用走你自己的账户。支持三种：

| | 怎么用 | 说明 |
|---|---|---|
| **Claude**（默认） | 设置 `ANTHROPIC_API_KEY`，在 [console.anthropic.com](https://console.anthropic.com) 申请 | 默认模型 `claude-sonnet-5`，一节 75 分钟的课约 $4–5；`--model claude-opus-5` 更强，约 $8–12 |
| **DeepSeek** | 设置 `DEEPSEEK_API_KEY`，在 [platform.deepseek.com](https://platform.deepseek.com) 申请 | 默认模型 `deepseek-flash`，便宜很多，一节课一般不到 $1；中文很好 |
| **其他兼容 OpenAI 格式的接口** | `--provider openai --api-base <地址> --model <模型名> --api-key-env <key 的环境变量名>` | 通义千问、Kimi、智谱，或者本机的 Ollama 都能接 |

设置方法：在 `~/.zshrc` 里加一行，比如 `export ANTHROPIC_API_KEY="你的 key"`，然后开一个新的终端窗口，运行 `livetrans --check` 确认。
不加 `--provider` 时会自动选：有 `ANTHROPIC_API_KEY` 用 Claude，否则有 `DEEPSEEK_API_KEY` 用 DeepSeek。

接其他平台的例子（地址和模型名以各平台文档为准）：

```bash
# 通义千问（阿里云百炼）
livetrans --vocab thermo --provider openai --api-base https://dashscope.aliyuncs.com/compatible-mode/v1 --model qwen-plus --api-key-env DASHSCOPE_API_KEY
# 本机 Ollama（不需要 key）
livetrans --vocab thermo --provider openai --api-base http://localhost:11434/v1 --model qwen3:8b --no-preview
```

本机跑的小模型会和 Whisper 抢 GPU，翻译质量也差一截，建议加 `--no-preview`，只让它翻定稿的句子。

**没有任何 API key 也能跑**：这时会用 macOS 自带的本地翻译，只翻译定稿的句子。但**效果差很多**：术语经常译错，也没有边听边翻，只适合临时应急。

加 `--no-preview` 关掉边听边翻，API 费用大约省一半。只有识别出的文字会发给 AI 服务，音频不会上传。

## 用法

```bash
livetrans --vocab polymer              # 实时：麦克风 → 英文 → 中文，Ctrl-C 结束
livetrans --vocab thermo               # 换一门课，换一个术语表
livetrans 录音.m4a --vocab thermo       # 处理录音文件，比如从 Notability 导出的音频
livetrans --check                      # 检查模型、麦克风、API key，并发一个很小的请求测试连接
livetrans --help                       # 全部选项
```

记录会存到**当前文件夹**的 `transcripts/` 里，所以在哪门课的文件夹运行，记录就存在哪门课下面。
可以和 Notability 同时录音：Notability 负责录音和笔记，livetrans 负责出双语字幕。

第一次使用麦克风时，macOS 会请求权限。如果 MacBook 是合盖接外接显示器的状态，内置麦克风会被关掉，要换成别的输入设备（程序检测到完全没声音时会提示）。

## 术语表（每门课一份）

`vocab/` 里每门课一个文件，`--vocab 名字` 就会用 `vocab/名字.txt`：

```
# topic: chemical engineering thermodynamics (Koretsky)
shaft work = 轴功
monatomic gas = 单原子气体
fugacity = 逸度
Koretsky
```

- 第一行 `# topic:` 告诉 Whisper 和 Claude 这是什么课。
- 之后一行一个术语，可以写成 `英文 = 中文`。英文部分会提示 Whisper 怎么拼写，整行交给 Claude 统一译名。
- 课上发现哪个词总被听错，就把正确的词加进去。

自带两个例子：`polymer`（高分子化学）和 `thermo`（化工热力学）。新增一门课：照格式另建一个 `vocab/课程名.txt` 就行。

## 其他选项

- `--provider <claude|deepseek|openai>`、`--model <名字>`：换 AI 服务和模型（见上文）。
- `--no-preview`：不边听边翻，只翻译定稿的句子。
- `--no-ai`：完全不用 API，只用本地翻译（效果差）。
- `--to zh-Hant`：翻成繁体中文。
- `--engine apple`：改用 macOS 自带的听写识别。准确率差很多，只用来应急。

## 调试

- `LIVETRANS_DEBUG=debug.log`：记录每一步的时间点。
- `LIVETRANS_SIMULATE_MIC=某个音频文件`：把这个文件按真实时间当成麦克风输入，不用外放就能测实时模式。

## 许可证

MIT
