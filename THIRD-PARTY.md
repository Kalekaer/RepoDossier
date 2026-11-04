# THIRD-PARTY NOTICES · 第三方许可

本项目生成的 `overview.html` **内嵌**了 Anton 字体（base64 data URI）；日报 C 版通过 `@font-face` 引用**本地** `assets/anton-latin.woff2` 与 `assets/fonts/BebasNeue-Regular.ttf` → **运行期外部请求 = 0** ✓。
按各自许可的要求，此处保留**版权声明**与**许可全文**。

## 1. Anton（拉丁刊头体）

| 项 | 值 |
|---|---|
| 文件 | `assets/anton-latin.woff2`（Google Fonts 提供的 **latin 子集**，18612 B） |
| 来源 | <https://fonts.google.com/specimen/Anton> ｜ `google/fonts` 仓库 `ofl/anton/` |
| 版权 | Copyright 2020 The Anton Project Authors (<https://github.com/googlefonts/AntonFont.git>) |
| 许可 | **SIL Open Font License 1.1**（OFL **条件 2**：随附版权声明与许可文本 → 就是本文件） |
| 内嵌位置 | `tools/build-overview.ps1` 生成的 `@font-face`（CSS 变量 `--font-display`） |
| 用途 | **只用于拉丁**刊头/标签；中文一律系统字体栈 —— **不内嵌任何 CJK 子集** ✗ |

> 复现：`assets/anton-latin.woff2` 取自 Google Fonts CSS API（Chrome UA）返回的 `latin` 子集 URL；
> 同一批次的原始响应留档为 `assets/anton.css`（CSS）与 `assets/anton-OFL.txt`（许可全文），便于核对。
> 复采命令见 `素材清单.md`。

## 2. Bebas Neue（拉丁数字/编号）

| 项 | 值 |
|---|---|
| 文件 | `assets/fonts/BebasNeue-Regular.ttf`（61,400 B） |
| 来源 | `google/fonts` 仓库 `ofl/bebasneue/` |
| 版权 | Copyright 2010 The Bebas Neue Project Authors |
| 许可 | **SIL Open Font License 1.1**（全文 `assets/fonts/OFL-BebasNeue.txt`） |
| 用途 | 日报 C 版的结构编号、版号、小数字；拉丁 only |

## 3. NASA 结构摄影（公有领域）

日报 C 版的结构图版使用 NASA 自有摄影，**只做灰度 + 半调 + 压暗处理**，不改原意。
依据 [NASA Media Usage Guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/)：NASA 自有素材一般不受版权保护、可商用；画面不含 NASA 徽标/标识。

| 文件 | NASA ID | 内容 | 摄影师 | 尺寸 | 字节 |
|---|---|---|---|---|---|
| `assets/bg/nasa-vab-highbay.jpg` | KSC-20180620-PH_GEB01_0004 | Vehicle Assembly Building High Bay 3 work platforms | NASA/Glenn Benson | 1920×1279 | 528,420 |
| `assets/bg/nasa-pad39b-steel.jpg` | KSC-2010-4941 | Launch Pad 39B rotating service structure dismantling | NASA/Jim Grossmann | 1920×1285 | 388,569 |
| `assets/bg/nasa-mobile-launcher.jpg` | KSC-20180314-PH_JBS01_0013 | Mobile Launcher steel structure before sunrise | NASA/Ben Smegelsky | 1280×1920 | 104,286 |
| `assets/bg/nasa-engine-test.jpg` | 6778720 | Saturn Apollo Program engine test | NASA | 1920×1536 | 200,990 |

> 原始直链与 SHA256 见 `assets/bg/SOURCES.md`；页面引用**本地文件**，运行期外部请求 = 0。

## 4. 其他第三方素材

**无** —— 页面不使用任何图表库 / 图标库 / 前端框架；网格、斜线、半调与噪点纹理为 CSS/SVG 自制。
中文与等宽字体使用**系统字体栈**（随系统授权，不随本项目分发）✓

## 5. Special Elite（草稿 02「影印拼贴」使用）

| 项 | 值 |
|---|---|
| 文件 | `assets/fonts/SpecialElite-Regular.ttf`（166,180 B） |
| 来源 | `google/fonts` 仓库 `apache/specialelite/` |
| 许可 | **Apache License 2.0**（全文 `assets/fonts/SpecialElite-LICENSE.txt`） |
| 用途 | 影印草稿的打字机标注；可商用、可嵌入，保留许可与版权声明 |

## 6. 2026-10-20 日报样张图版（NASA PD + Poly Haven CC0）

`设计样张/样张-0*.html` 使用 6 张 NASA/NACA 自有摄影（公有领域）+ 2 张 Poly Haven 纹理（CC0 1.0）。

- NASA 依据 [NASA Media Usage Guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/)：NASA 自有素材一般不受版权保护、可商用；图中 **NASA 徽标与官方字幕已裁掉**，只做灰度 / 对比 / 半调处理。
- Poly Haven 依据 **CC0 1.0**（<https://creativecommons.org/publicdomain/zero/1.0/>）：可商用、免署名；本项目仍登记作者与来源。
- **未采用** `PIA19405`（Insight 降落伞测试）：署名含 Lockheed Martin，第三方权利不确定；按“可商用、零版权争议”标准剔除。
- 页面引用**本地文件**，运行期外部请求 = 0；完整来源、尺寸、字节与 SHA256 见 `assets/bg/SOURCES.md`。

| 文件 | 来源 | 作者 / 机构 | 许可 |
|---|---|---|---|
| `assets/bg/proof-awt-tunnel.jpg` | NASA LRC-1957-B701_P-00959 | NACA / NASA Langley | PD (NASA) |
| `assets/bg/proof-vacuum-tunnel.jpg` | NASA GRC-1961-C-57748 | NASA Lewis | PD (NASA) |
| `assets/bg/proof-awt-bore.jpg` | NASA GRC-2007-C-00381 | NASA GRC | PD (NASA) |
| `assets/bg/proof-awt-chamber.jpg` | NASA GRC-2007-C-00378 | NASA GRC | PD (NASA) |
| `assets/bg/proof-pressure-chamber.jpg` | NASA ARC-1995-AC95-0203-39 | Dominic Hart / NASA Ames | PD (NASA) |
| `assets/bg/proof-pad-night.jpg` | NASA KSC-81PC-0136 | NASA | PD (NASA) |
| `assets/bg/proof-concrete.jpg` | Poly Haven `concrete` | Rob Tuytel | CC0 1.0 |
| `assets/bg/proof-concrete-worn.jpg` | Poly Haven `concrete_floor_worn_001` | Dimitrios Savva / Rico Cilliers | CC0 1.0 |

---

## SIL Open Font License 1.1（全文）

Copyright 2020 The Anton Project Authors (https://github.com/googlefonts/AntonFont.git)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
## 7. 2026-10-20 周报样张图版（NASA PD + Poly Haven CC0）

`设计样张/周报样张.html` 使用 3 张 NASA 自有摄影（公有领域）+ 2 张 Poly Haven 纹理（CC0 1.0）。页面只引用本地文件，运行期外部请求 = 0。

- NASA 依据 [NASA Media Usage Guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/)：NASA 自有素材一般不受版权保护、可商用；未使用第三方署名素材。
- Poly Haven 依据 **CC0 1.0**（<https://creativecommons.org/publicdomain/zero/1.0/>）：可商用、免署名；本项目仍登记作者与来源。

| 文件 | 来源 / ID | 作者 / 机构 | 许可 |
|---|---|---|---|
| `assets/bg/weekly-control-1.jpg` | NASA S69-59525 | NASA / JSC | PD (NASA) |
| `assets/bg/weekly-control-2.jpg` | NASA S69-26301 | NASA / JSC | PD (NASA) |
| `assets/bg/weekly-control-3.jpg` | NASA 6901509 | NASA / MSFC | PD (NASA) |
| `assets/bg/weekly-plaster.jpg` | Poly Haven `grey_plaster` | Rob Tuytel | CC0 1.0 |
| `assets/bg/weekly-plaster-worn.jpg` | Poly Haven `worn_plaster_wall` | Dimitrios Savva | CC0 1.0 |

## 6. 全站动效素材（2026-10-20）

| 文件 | 来源 | 许可 | 说明 |
|---|---|---|---|
| `assets/bg/archive-awt-00386-plate.jpg` | NASA GRC-2007-C-00386 | NASA PD | 已裁掉 NASA 徽标与字幕；无人物 |
| `assets/bg/archive-awt-00387-plate.jpg` | NASA GRC-2007-C-00387 | NASA PD | 已裁掉 NASA 徽标与字幕；无人物 |
| `assets/bg/archive-ribbed-concrete.jpg` | Poly Haven `ribbed_concrete_wall` | CC0 1.0 | Charlotte Baglioni |
| `assets/bg/archive-rebar-concrete.jpg` | Poly Haven `rebar_reinforced_concrete` | CC0 1.0 | Amal Kumar |

> NASA 依据 [NASA Media Usage Guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/)；Poly Haven 依据 [CC0 1.0](https://polyhaven.com/license)。页面运行期不请求外部地址。

## 2026-10-22 生成素材（日报 01 空态样张）

- `assets/bg/cat-nun-01.jpg`：本机 AI 生成（智谱 glm-image，免费渠道），原创，无第三方版权；平台水印已裁除。
- 用途：`设计样张/样张-07-头条空态-暗色.html` 的右栏胸像。**未接入生产页面。**
- 许可：生成物无第三方版权主张；不包含任何既有作品角色、商标或真人肖像。

## 2026-10-22 样张-08 主视觉（自绘 SVG，无第三方素材）

`设计样张/样张-08A-信号中断.html`、`样张-08B-结构剖面.html` 的主视觉为 **本项目自绘的猫耳少女剪影**（`assets/bg/vacant-catgirl.svg`，SVG path，2026-10-22 逐版校正）。

- 来源：本工作区原创绘制；不引用任何第三方图像、动漫/游戏角色、真人肖像或商标。
- 许可：本项目原创，可商用；随项目 `LICENSE` 发布（无额外署名要求）。
- 字体：只使用本仓库已登记的 OFL 字体（Anton、Bebas Neue）与系统字体；字体许可见本文档「字体」章节。
- 动效/纹理：扫描线、颗粒（`feTurbulence` 的 `data:` URI）、网格、HUD 均为 CSS/SVG 代码生成，不引入外部文件。
- **本轮未使用 AI 生成图**：`generate_image` 对智谱 `glm-image` / `cogview-3-flash` 两次尝试均 `fetch failed`（上游不可达），未产生新图；上一轮的 `cat-nun-01.jpg` 未复用。
- 运行期外部请求 = 0。

## 2026-10-24 统一皮肤素材（NASA PD + Poly Haven CC0）

| 文件 | 来源 / ID | 作者 / 机构 | 许可 |
|---|---|---|---|
| `assets/bg/archive-steel-interior.jpg` | NASA KSC-2010-4437 | NASA/Kim Shiflett | PD (NASA) |
| `assets/bg/archive-brushed-concrete.jpg` | Poly Haven `brushed_concrete` | Dario Barresi / Dimitrios Savva | CC0 1.0 |
| `assets/bg/archive-pitted-concrete.jpg` | Poly Haven `anti_slip_concrete` | Charlotte Baglioni | CC0 1.0 |

- 依据：[NASA Media Usage Guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/) / [Poly Haven License](https://polyhaven.com/license)（CC0 1.0）。
- 用途：`设计样张/unified/` 两版统一皮肤样张的图版与纸纹；裁掉徽标/字幕、无人物，只做灰度/半调/压暗，不改原意。
- 完整来源、尺寸、字节、SHA256 见 `assets/bg/SOURCES.md`；页面运行期外部请求 = 0。
