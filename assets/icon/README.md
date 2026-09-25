# 程序图标

<p align="center">
  <img src="app-256.png" width="128" alt="网文扫榜工具图标">
</p>

**三根递增柱（榜单）+ 一条带箭头的趋势折线（走势）**，压在圆角方块的对角渐变上 ——
这个工具干的就是"把榜存下来、看排名怎么走"，图标把这句话画出来了。

## 文件

| 文件 | 尺寸 | 用途 |
|---|---|---|
| `app.ico` | 16 / 24 / 32 / 48 / 64 / 128 / 256 七档 | **Windows 图标**，打包 exe 时嵌进去 |
| `app.png` | 512×512 | 主图：README、网页、文档用 |
| `app-256.png` … `app-16.png` | 各尺寸 | favicon、缩略图、示例（按需取用） |

## 重新生成

图标**没有手工图层**，全部由脚本算出来 —— 改配色 / 改柱子 / 改折线，改常量重跑即可：

```bash
python tool/make_icon.py
```

参数都在 `tool/make_icon.py` 顶部：

| 常量 | 管什么 | 默认值 |
|---|---|---|
| `RADIUS` | 底板圆角 | 116（512 坐标系，≈ iOS / Win11 观感） |
| `BAR_W` / `BAR_GAP` / `BAR_H` | 三根柱子的宽、间距、高度 | 66 / 34 / 112·178·250 |
| `BAR_ALPHA` | 柱子透明度（压在折线后面） | 0.46 / 0.58 / 0.72 |
| `LINE_PTS` / `LINE_W` | 趋势折线的拐点与线宽 | 四点折线 / 34 |
| `HEAD_LEN` / `HEAD_DEG` | 箭头两翼长度与张角 | 72 / 40° |
| `C_TL` / `C_BR` | 渐变两端颜色 | 见下 |

## 配色（跟 `lib/ui/theme.dart` 对齐）

| 用途 | 主题里的值 | 图标里的值 |
|---|---|---|
| 深色主题主色 | `rgb(88, 196, 250)` | 渐变亮端 `C_TL = (92, 200, 250)` |
| 浅色主题主色 | `rgb(11, 127, 212)` | 渐变暗端 `C_BR = (10, 92, 176)` |

改了主题主色，把这两个常量一起改了重跑，图标就跟着换肤。

## 16px 也认得出来

4 倍超采样画在 2048×2048 上，再 LANCZOS 降采样到各尺寸 ——
所以 **16px 下柱子和箭头仍然分得开**，浅底（#F5F6F8）和深底（#171C24）都试过。
ICO 里七档齐全，Windows 缩略图 / 任务栏 / 详细信息列表各取所需。

## 嵌进 exe

打包时 `build_exe.cmd` 的最后一步（`[5/5] 嵌图标`）会自动调 `tool/embed_icon.ps1`，
把 `app.ico` 写进 exe 的资源表（`RT_ICON` + `RT_GROUP_ICON`）。手动执行也行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tool/embed_icon.ps1 build/网文扫榜工具.exe assets/icon/app.ico
```

- **不依赖 SDK / rcedit**：直接调 Win32 的 `BeginUpdateResource` → `UpdateResource` → `EndUpdateResource`；
- **不删原有资源**：manifest、版本信息原样保留，只加图标；
- **原子**：先写临时文件，成功才改名覆盖（Defender / 索引器持有读句柄时也换得掉），
  中途失败就丢弃，不会留下半个 exe；
- 嵌完用 `System.Drawing.Icon.ExtractAssociatedIcon` 抽回来核对过，
  exe 的 `.text` / `.rdata` / `.data` 逐字节不变，只有 `.rsrc` 变大。
