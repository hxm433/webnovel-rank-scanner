<#
.SYNOPSIS
  给 exe 嵌入图标 —— 纯 Win32 资源 API，不依赖 rcedit / mt.exe / SDK。

.DESCRIPTION
  读一个 .ico（多尺寸），把每张图写成 RT_ICON(3)，
  再拼一份 RT_GROUP_ICON(14)，Explorer / 任务栏 / 快捷方式就都会用它。
  不 deleteExistingResources —— 只加图标，原有的清单(manifest)、版本信息一概保留。

  为什么先写临时文件再改名：README 里记的那个坑 ——
  Defender / 索引器可能持有 exe 的读句柄，直接覆盖会报 errno 32；
  改名替换不受读句柄阻挡。

.EXAMPLE
  pwsh tool/embed_icon.ps1 build\网文扫榜工具.exe assets/icon/app.ico
#>
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Exe,

  [Parameter(Mandatory = $true, Position = 1)]
  [string]$Ico,

  # 资源语言：0x0409 = en-US（Windows 自带图标都是这个，跟语言无关也能读）
  [int]$Language = 0x0409
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) { throw "找不到 exe: $Exe" }
if (-not (Test-Path -LiteralPath $Ico)) { throw "找不到 ico: $Ico" }

Add-Type -Namespace DshIcon -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources);

[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName,
                                         ushort wLanguage, byte[] lpData, int cb);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);

[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern int GetLastError();
'@

$RT_ICON = [IntPtr]3
$RT_GROUP_ICON = [IntPtr]14

function Get-LastErrorMsg {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return "Win32 错误 ${code} : " + (New-Object ComponentModel.Win32Exception($code)).Message
}

# ---------- 解析 .ico ----------
$bytes = [IO.File]::ReadAllBytes($Ico)
if ($bytes.Length -lt 6) { throw "ico 太小，不是有效文件" }

$icoType = [BitConverter]::ToUInt16($bytes, 2)
$count   = [BitConverter]::ToUInt16($bytes, 4)
if ($icoType -ne 1) { throw "这不是 icon（type=$icoType），PNG 改名的可不行" }
if ($count -lt 1 -or $count -gt 20) { throw "图层数 $count 不合理" }

# ---------- 临时副本上动刀 ----------
$dir = Split-Path -Parent $Exe
$tmp = Join-Path $dir (".icon_" + [IO.Path]::GetRandomFileName() + ".tmp")
Copy-Item -LiteralPath $Exe -Destination $tmp -Force

$h = [DshIcon.Native]::BeginUpdateResource($tmp, $false)
if ($h -eq [IntPtr]::Zero) { Remove-Item -LiteralPath $tmp -Force; throw "BeginUpdateResource 失败 —— " + (Get-LastErrorMsg) }

try {
    $grp = New-Object IO.MemoryStream
    $bw  = New-Object IO.BinaryWriter($grp)
    $bw.Write([UInt16]0)          # GRPCONDIR.wReserved
    $bw.Write([UInt16]1)          # GRPCONDIR.wType = 1 (icon)
    $bw.Write([UInt16]$count)     # GRPCONDIR.wCount

    $sizes = @()
    for ($i = 0; $i -lt $count; $i++) {
        $o = 6 + 16 * $i                       # ICONDIRENTRY 起点
        $w   = $bytes[$o]
        $hgt = $bytes[$o + 1]
        $cc  = $bytes[$o + 2]
        $rsv = $bytes[$o + 3]
        $pl  = [BitConverter]::ToUInt16($bytes, $o + 4)
        $bc  = [BitConverter]::ToUInt16($bytes, $o + 6)
        $len = [BitConverter]::ToUInt32($bytes, $o + 8)
        $off = [BitConverter]::ToUInt32($bytes, $o + 12)

        if (($off + $len) -gt $bytes.Length) { throw "第 $i 层越界（offset=$off len=$len）" }

        $img = New-Object byte[] $len
        [Array]::Copy($bytes, $off, $img, 0, $len)

        $id = [IntPtr]($i + 1)                 # RT_ICON 资源 ID 从 1 起
        if (-not [DshIcon.Native]::UpdateResource($h, $RT_ICON, $id, [UInt16]$Language, $img, $img.Length)) {
            throw "写 RT_ICON #$($i + 1) 失败 —— " + (Get-LastErrorMsg)
        }

        # GRPICONDIRENTRY：把 dwBytesInRes 后面换成 wID，其余照抄
        $bw.Write($w); $bw.Write($hgt); $bw.Write($cc); $bw.Write($rsv)
        $bw.Write($pl); $bw.Write($bc); $bw.Write($len); $bw.Write([UInt16]($i + 1))
        $sizes += ("{0}x{1}" -f ($(if ($w -eq 0) { 256 } else { $w })), $(if ($hgt -eq 0) { 256 } else { $hgt }))
    }
    $bw.Flush()
    $grpBytes = $grp.ToArray()
    $bw.Close()

    # 组 ID 用 1：exe 里通常就这一个组，同 ID 直接顶掉旧的
    if (-not [DshIcon.Native]::UpdateResource($h, $RT_GROUP_ICON, [IntPtr]1, [UInt16]$Language, $grpBytes, $grpBytes.Length)) {
        throw "写 RT_GROUP_ICON 失败 —— " + (Get-LastErrorMsg)
    }

    if (-not [DshIcon.Native]::EndUpdateResource($h, $false)) {
        throw "EndUpdateResource 失败（改动没落盘）—— " + (Get-LastErrorMsg)
    }
}
catch {
    [void][DshIcon.Native]::EndUpdateResource($h, $true)   # 出错就丢弃，别留下半个文件
    Remove-Item -LiteralPath $tmp -Force
    throw
}

# ---------- 改名覆盖（绕开读句柄） ----------
Move-Item -LiteralPath $tmp -Destination $Exe -Force

Write-Host "  [OK] 图标已嵌入: $Exe"
Write-Host ("       尺寸: " + ($sizes -join ' / '))
