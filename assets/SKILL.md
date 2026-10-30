# RVC 翻唱与统一音色

把一首歌的人声换成目标音色，并让「说话」和「唱歌」听起来是同一个人。

## 什么时候用

- 用户说「翻唱」「换音色」「让某个角色/歌手唱这首歌」「这首歌换成 XX 的声音」
- 用户要求「说话和唱歌是同一个人」
- 用户抱怨自己的歌声「塑料感 / 发薄 / 不像真人」

## 什么时候不用

- 用户要**从零生成一首新歌**（文生歌）→ 用 ACE-Step 1.5，不是本技能的 SVC 流程
- 用户要**按谱唱**（给定旋律 + 歌词，没有源人声）→ 那是 SVS（DiffSinger/OpenUtau），本技能不适用
- 用户没有源人声、也不接受「换掉别人的原唱」→ 先澄清需求，不要硬跑

## 核心判断：这是 SVC，不是 SVS

SVC 保留原唱的音高、节奏、咬字、气口，只换音色，所以真人感来自**源人声**。
SVS 是凭空造发声，上限由数据集和声码器决定，这就是「塑料感」的根因。
用户若在 SVS 上加参数想救音质，明确告诉他们这是方向错误，不是参数问题。

## 前提（缺一不可）

| 项 | 要求 | 检查方式 |
|---|---|---|
| RVC | 2.3.260718 或更新 | 项目根目录有 `webui.py`、`configs/config.py` |
| Python | **3.12 x64**（该版本只支持 3.12） | `py -3.12 --version` |
| 预训练 | `assets/hubert_base/`、`assets/rmvpe/rmvpe.pt` | 目录存在 |
| 模型 | `assets/weights/<名>.pth`（**v2 + 带 f0**） | 文件存在 |
| index | `assets/indices/<同名>.index` | 可选，有则更像 |
| ffmpeg | 在 PATH，或放在 RVC 根目录 | `ffmpeg -version` |
| 显卡 | ≥4GB 可推理；分离另算 | `nvidia-smi` |

引擎位置由环境变量 `DSH_RVC_HOME` 给出。**没设置就先问用户**，不要猜路径、不要自行 pip install。

先跑体检，它一屏给全结论：

```powershell
pwsh -File "<base dir>/scripts/preflight.ps1" -Root $env:DSH_RVC_HOME
```

任何 `FAIL` 行都要先解决，不要带着失败继续跑。

## 四条红线

1. **不先跑通 10 秒，不许上整首。** 变调量错了，整首歌白跑。
2. **没试听、没量时长，不许说「完成」。** 成功标准是能听，不是文件存在。
3. **不编造分数。** 声纹相似度只能测「像不像」，测不出「好不好听」；量不出来就说量不出来。
4. **分离和换嗓可能不是同一个 Python 环境。** 报 `No module named 'av'` 就是拿错了环境。

## 工作区约定

```
cover/<歌曲slug>/
  source.mp3        原始歌曲（用户提供）
  vocals.wav        分离出的人声
  instrumental.wav  分离出的伴奏
  vocals_conv.wav   换嗓后的人声
  instrumental_shifted.wav
  mix.wav           混音中间产物
  cover.mp3         成品 ← 最终 present 这个
```

不要覆盖用户的源文件。中间产物默认保留到验收通过。

## 第一步：分离人声

优先 RVC 内置的 PyMSS（2026 版的后端），其次是 `audio-separator`。

```powershell
# 方案 A：audio-separator（独立包，参数可控）
audio-separator source.mp3 --output_dir cover/<slug> --model_filename <模型yaml>
# 方案 B：RVC 的 pymss CLI（在 RVC 根目录下）
```

6GB 上的降档：`--mdx_segment_size 128`、开 fp16、chunk 调小。

**判据**：伴奏里听不到人声残留，人声里听不到乐器。
**不过**：先调 segment/chunk；仍不过就换更高质量模型，或把分离丢到云上跑（单曲成本很低）。

## 第二步：定调

```powershell
py -3.12 "<base dir>/scripts/pitch-match.py" --source cover/<slug>/vocals.wav --reference <目标音色参考.wav>
```

输出 JSON 的 `semitones` 只是两个片段的中位音高差，不是模型的最佳调。**第一次转换用 `shift=0`。** 读这些字段：

- `warnings` 非空 → 按提示复核，不要当噪声
- `ratio` 接近 **0.5 / 1.5 / 2.0** → 可能是谐波锁定，也可能两段本来音高就不同；必须试听，不能单靠比值下结论
- `semitones` 很大 → 先怀疑参考片段选错，不要直接拿去转整首

**判据**：跟着伴奏唱不跑调。数字对上了仍然跑调，就是参考量错了。
**没有参考音频时**：不要瞎猜变调量。先问用户目标音色的音域，或让他给一段参考。

## 第三步：换嗓

先确认引擎是哪一种，`preflight.ps1` 的 `layout` 行会直接给答案：

| 布局 | 判据 | 能否自动化 |
|---|---|---|
| **Applio** | 根目录有 `core.py` | **能**，有完整 CLI |
| RVC 2.3 | 根目录有 `webui.py` | 不能，只能 WebUI 或内部 API |

### 路线 A：Applio（可自动化，优先）

```powershell
pwsh -File "<base dir>/scripts/convert.ps1" `
  -Input cover/<slug>/vocals.wav `
  -Out cover/<slug>/vocals_conv.wav `
  -Model <ApplioRoot>/models/<名>.pth `
  -Index <ApplioRoot>/models/<名>.index `
  -Pitch <semitones> -F0Method rmvpe
```

脚本封装 `core.py infer`，参数与下面这张表一致，并在产物不存在时失败。

没有 `.index` 时，脚本仍传 `--index-path ""`，并把 `index-rate` 置 0。先用这份 Applio 的 `infer --help` 核对；App adapter 里该参数是可选的，standalone CLI 里它是必填。

### 路线 B：RVC 2.3 WebUI（人工）

`python webui.py` → 端口 7865 → 模型推理页。RVC 2.3 **没有** `infer_cli.py` 这类命令行入口，所以要自动化必须先读 `infer/modules/vc/modules.py`，确认 `VC` 的构造签名与 `pipeline` 参数——签名跨版本会变，不要凭记忆写。

### 参数（6GB，两条路线通用）

| 参数 | 值 | 说明 |
|---|---|---|
| 变调 | 第二步的 `semitones` | — |
| 音高算法 | `rmvpe`，备选 `fcpe` | 复调音乐里的演唱专门设计，别用 crepe/harvest |
| **index_rate** | **0.3~0.5** | 检索占比。低了细节少，高了不自动更好；听同一段再动 |
| volume_envelope | 0.25 | 当前 Applio：0 更接近原音量包络，1 保留转换后的包络。旧名 `rms_mix_rate` |
| protect | 0.33 | 当前引擎里低于 0.5 才启用清音保护，0.5 关闭；数值越低保护越强 |
| filter_radius | 3 | 平滑 f0 抖动 |
| resample | 0 | 保持原采样率 |

输出存成 `vocals_conv.wav`。

**判据**：不跑调、不电、咬字不掉。
**不过**：先换 f0 算法 → 再调 index_rate → 最后才怀疑模型质量。

## 第四步：伴奏跟调 + 混音

人声对了但整首歌跑调，是最常见的翻车点：**伴奏必须跟着变调**。

```powershell
pwsh -File "<base dir>/scripts/mix.ps1" `
  -Vocal cover/<slug>/vocals_conv.wav `
  -Instrumental cover/<slug>/instrumental.wav `
  -ShiftSemitones <semitones> `
  -Source cover/<slug>/source.mp3 `
  -Out cover/<slug>/cover.mp3
```

脚本会做：伴奏移调（rubberband，缺失时回退 asetrate+atempo）→ 给人声轨 +2dB → `loudnorm` → 回读成品响度 → 报时长差。+2dB 不是测出来的「人声比伴奏高 2dB」。不传 `-Source` 时，时长只和伴奏比。

**判据**：成品时长与源差 < 1 秒；回读响度接近 −14 LUFS / −1 dBTP。人声是否压过伴奏仍要听。
**不过**：时长差过大说明中间产物串了或分离吃掉了尾巴。

## 第五步：验收并交付

逐条过，缺一条都不算完：

| 项 | 判据 |
|---|---|
| 像不像 | 盲听；不像先查参考素材，别先改参数 |
| 跑不跑调 | 跟伴奏对 |
| 电音 | 人声发沙/金属感 → 变调降太多或源质量差 |
| 时长 | 与源差 < 1 秒 |
| 响度 | −14 LUFS / −1 dBTP |

然后 `present` 成品 mp3，并在回复里说明：用了哪个模型、变调多少、分离方案、以及**哪些是机器量的、哪些必须人耳判断**。

## 失败矩阵

| 症状 | 先查 | 再查 | 最后 |
|---|---|---|---|
| 人声发沙/金属感 | 变调是否降太多 | f0 换 fcpe | 换模型 |
| 咬字含糊 | 分离是否干净 | index_rate 是否偏离 0.3~0.5 | protect 是否过强（数值过低） |
| 整首跑调 | **伴奏有没有跟着移调** | 变调是否量错 | 手工在 DAW 对 |
| 伴奏有人声残留 | 分离模型档位 | 换高质量分离模型 | 上云分离 |
| 报 `No module named 'av'` | 分离用了换嗓的 Python | 指到装了分离依赖的解释器 | — |
| 显存不足 | 先确认是分离还是换嗓 | 缩短片段或打开分段 | 关掉其他占显存程序；分离可改走 CPU 或云 |

## 说话侧：先用同一个 RVC 模型

第一次验证不要同时上两个音色模型。Applio 的 TTS 是先合成，再用 RVC 转换：

```powershell
pwsh -File "<base dir>/scripts/speak.ps1" `
  -Text "今天晚上见。" `
  -Out cover/<slug>/speech.wav `
  -Model <ApplioRoot>/models/<名>.pth `
  -Index <ApplioRoot>/models/<名>.index
```

同一份 `.pth` 也用于唱歌。默认源语音是 `zh-CN-XiaoxiaoNeural`，只提供语言和说法，目标音色来自 RVC 模型。Edge TTS 需要联网。

通过听感之前，不要加匹配 EQ，也不要把 GPT-SoVITS 当成必经步骤。同一模型只说明路线通了，不能代替「说话、低音、高音像同一个人」的试听。

## 相关资源

- `scripts/preflight.ps1` — 环境体检，自动识别 Applio / RVC 两种布局
- `scripts/pitch-match.py` — 量基频、算变调半音
- `scripts/convert.ps1` — 封装 Applio `core.py infer`，带守卫与产物校验
- `scripts/speak.ps1` — Edge TTS 后用同一个 RVC 模型转换说话
- `scripts/mix.ps1` — 伴奏移调 + 混音 + 响度测量
- `references/parameters.md` — 参数与判据的完整说明

## 这条链之外的判断

社区里有现成的 DSH 翻唱插件（`dsh-voice-studio`、`dsh-cover-pipeline`）。要用它们之前先看三件事：

1. **它有没有改写别人的插件源码**——有的话，你的 profile 里就有一个插件在静默改另一个插件。
2. **引擎路线是 Applio 还是 RVC WebUI**——决定能不能无人值守。
3. **目录布局是硬编码某套还是可配置**——硬编码的那套换台机器就跑不起来。

这三条与"插件本身好不好用"无关，但决定出了问题时你能不能修。
