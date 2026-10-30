# dsh-rvc-cover

面向 Windows 的 DSH 插件：用本机已有的 RVC 模型翻唱，并让说话走同一个模型。

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11%20x64-0078D4)](https://github.com/SB-TDM/dsh-rvc-cover)
[![License](https://img.shields.io/github/license/SB-TDM/dsh-rvc-cover)](LICENSE)

它不自带引擎，也不自带音色。插件注册一个 `rvc-cover` 技能，把分离、试听、换嗓、说话和混音的顺序、参数和失败判据交给 agent；真正出声靠本机的 Applio 或 RVC、ffmpeg，以及你自己的 `.pth`。

> 还没有在目标机器上跑通整首歌。脚本接口和 dry-run 核对过，安装、显卡推理和听感验收都还没做。不要把它当成已经能交付成品的工具。

## 核心特色：同一个模型，先听 10 秒

选好 Applio 目录和一份推理用的 `.pth` 之后，按这个顺序走，不要一上来转完整首歌：

1. **先体检**：确认目录是 Applio 还是 RVC 2.3、解释器、ffmpeg 和模型在不在。
2. **先听 10 秒**：第一次变调用 0。基频脚本只给两个片段的音高差，不直接当最佳调。
3. **再换嗓**：Applio 走 `core.py infer`。RVC 2.3 没有这条命令行，只能开 WebUI。
4. **用同一份模型说话**：Edge TTS 先合成，再交给同一个 `.pth`。这一步要联网，而且不能代替试听。
5. **最后混音**：伴奏跟着移调，编码后回读响度。人声加的 2 dB 只是轨增益，不是测出来的相对伴奏电平。

> 文件生成了不算完成。说话、低音和高音要放在一起听，像不像同一个人只能用人耳判断。

## 功能

- **技能，不是一层会失败的按钮**：引擎没装时不包 Host 工具，避免一调用就报错。
- **两种引擎布局**：根目录有 `core.py` 认作 Applio，有 `webui.py` 认作 RVC 2.3。
- **换嗓脚本**：`convert.ps1` 传当前 Applio 的 `--volume-envelope`；没有 `.index` 时仍传空的 `--index-path`，并把检索强度降到 0。
- **说话脚本**：`speak.ps1` 走官方的 TTS 再 RVC 路径。默认源语音是 `zh-CN-XiaoxiaoNeural`，目标音色来自你的模型。
- **混音脚本**：`mix.ps1` 优先用 rubberband 移调伴奏，没有就退回 ffmpeg。传入 `-Source` 才和原曲比时长。
- **参数说明**：`assets/references/parameters.md` 写每个起点值是什么意思，以及哪些只是试听起点。

## 它挂在哪里

这是一个 bundle，不是 profile。`package.json` 的 `dsh.bundle.patch` 指向 `cordis.patch.yml`，补丁把插件插进行列；`lib/index.js` 只在 `ctx.skills` 上注册技能 `rvc-cover`。不注册工具、命令或模型适配器。卸载时 Cordis 会撤销这次注册。

## 安装

在要使用的 profile 里安装。本地目录和 GitHub 都可以：

```powershell
dsh plugin --profile web add C:\path\to\dsh-rvc-cover
dsh plugin --profile web add github:SB-TDM/dsh-rvc-cover
```

装完后重启该 profile。插件列表里应显示「RVC 翻唱」。这一步还没有在本机验证。仓库已加 `dsh-plugin` 话题，方便在插件列表里被找到。

## 使用前要有

插件不带引擎、模型和 ffmpeg。下面都要自己装。脚本认的是根目录有 `core.py` 的 Applio，只装 Applio Desktop 安装包过不了体检。

| 依赖 | 干什么 | 在哪下 |
|---|---|---|
| 本插件 | 技能和脚本 | https://github.com/SB-TDM/dsh-rvc-cover |
| DeepSeek Harness 命令行 | 执行 `dsh plugin` | https://www.npmjs.com/package/@deepseek-ai/dsh ，需要 Node.js。桌面客户端是另一条渠道：https://deepseekharness.online/download.html |
| PowerShell 7 | 跑 `.ps1` | https://github.com/PowerShell/PowerShell/releases |
| Applio 源码或 Windows 编译包 | 换音色、说话 | 源码 https://github.com/IAHispano/Applio ，进目录运行 `run-install.bat`。编译包 https://huggingface.co/IAHispano/Applio/tree/main/Compiled/Windows |
| 推理 `.pth` | 目标音色 | https://applio.org/search 。放到 `models\名字.pth`，有同名 `.index` 就放一起。不要用 `G_*.pth` |
| ffmpeg、ffprobe | 读音频、移调、混音 | https://ffmpeg.org/download.html ，Windows 选 gyan.dev 的 release essentials，把 `bin` 加进 PATH |
| NVIDIA 驱动 | 体检和推理 | https://www.nvidia.com/Download/index.aspx |

说话要能联网，Edge TTS 在 Applio 里，不用另装。定调脚本在 Applio 的 Python 里装两个包：

```powershell
& "$env:DSH_RVC_HOME\env\Scripts\python.exe" -m pip install librosa soundfile
```

不用 Applio、改用 RVC 2.3 时，仓库在 https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI ，需要 Python 3.12。它没有命令行推理，本插件的 `convert.ps1` 用不上。

环境变量：

| 变量 | 含义 |
|---|---|
| `DSH_RVC_HOME` | Applio 或 RVC 的根目录 |
| `DSH_RVC_MODEL` | 模型文件名，不带 `.pth` |

没设置 `DSH_RVC_HOME` 时先问路径，不要猜，也不要自己 `pip install`。

## 脚本

在仓库里这样体检：

```powershell
pwsh -File assets/scripts/preflight.ps1 -Root $env:DSH_RVC_HOME -ModelName $env:DSH_RVC_MODEL
```

换嗓、说话和混音分别是：

```powershell
pwsh -File assets/scripts/convert.ps1 -InputPath vocals.wav -Out vocals_conv.wav -Model models\target.pth -Pitch 0
pwsh -File assets/scripts/speak.ps1 -Text "今天晚上见。" -Out speech.wav -Model models\target.pth
pwsh -File assets/scripts/mix.ps1 -Vocal vocals_conv.wav -Instrumental instrumental.wav -Source source.mp3 -ShiftSemitones 0 -Out cover.mp3
```

三条命令都假设当前目录能找到引擎、模型和音频。`convert.ps1` 与 `speak.ps1` 也可以用 `-ApplioRoot` 指定引擎。加 `-DryRun` 只打印命令。

## 技术栈

- DSH bundle：`cordis.patch.yml` 注册插件，`lib/index.js` 注册技能
- PowerShell 7 脚本与一个 Python 定调脚本
- Applio `core.py` 的 `infer` / `tts`，或 RVC WebUI
- ffmpeg 做移调、混音和响度回读

## 许可证

MIT，详见 [LICENSE](LICENSE)。

本仓库不包含 RVC、Applio、Demucs、GPT-SoVITS 或任何音色权重。它们的许可证以各自项目为准。用真人声音翻唱时，公开分发前需要自行处理声音权和词曲授权。
