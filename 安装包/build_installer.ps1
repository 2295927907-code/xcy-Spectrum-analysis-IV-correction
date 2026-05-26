param(
    [switch]$SkipInstaller,
    [switch]$SkipPyInstaller,
    [switch]$SkipPackagedTests
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$packageDir = Split-Path -Parent $PSCommandPath
$sourceDir = Join-Path $packageDir "源文件"
$configDir = Join-Path $packageDir "配置"
$outputDir = Join-Path $packageDir "输出"
$buildDir = Join-Path $packageDir "临时构建"
$venvDir = Join-Path $buildDir "venv"
$distDir = Join-Path $buildDir "dist"
$workDir = Join-Path $buildDir "pyinstaller-work"
$specPath = Join-Path $configDir "spectral_spd_gui.spec"
$issPath = Join-Path $configDir "installer.iss"
$appExe = Join-Path $distDir "SpectrumMatchAnalyzer\SpectrumMatchAnalyzer.exe"
$setupExe = Join-Path $outputDir "光谱匹配分析器_Setup.exe"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Assert-Path {
    param([string]$Path, [string]$Description)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "缺少 $Description：$Path"
    }
}

function Remove-BuildPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $resolved = Resolve-Path -LiteralPath $Path
    $buildRoot = Resolve-Path -LiteralPath $buildDir
    if (-not $resolved.Path.StartsWith($buildRoot.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理临时构建目录之外的路径：$($resolved.Path)"
    }
    Remove-Item -LiteralPath $resolved.Path -Recurse -Force
}

function Find-Python {
    $codexPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    if (Test-Path -LiteralPath $codexPython) {
        return $codexPython
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return $python.Source
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $candidate = & $pyLauncher.Source -3 -c "import sys; print(sys.executable)"
        if ($LASTEXITCODE -eq 0 -and $candidate) {
            return $candidate.Trim()
        }
    }

    throw "未找到 Python。请先安装 Python 3.10+，或在 Codex 环境中运行本脚本。"
}

function Find-Iscc {
    $command = Get-Command iscc -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $registryPaths = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($registryPath in $registryPaths) {
        $installations = Get-ItemProperty $registryPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "Inno Setup" -and $_.InstallLocation }
        foreach ($installation in $installations) {
            $candidate = Join-Path $installation.InstallLocation "ISCC.exe"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 5\ISCC.exe"),
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 5\ISCC.exe",
        "C:\Program Files\Inno Setup 5\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Test-PythonRuntimeDependencies {
    param([string]$PythonExe)
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $PythonExe -c "import numpy, pandas, openpyxl, PIL, xlrd" *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

New-Item -ItemType Directory -Path $sourceDir, $configDir, $outputDir, $buildDir -Force | Out-Null

Assert-Path (Join-Path $sourceDir "spectral_spd_gui.py") "主程序"
Assert-Path (Join-Path $sourceDir "requirements.txt") "依赖清单"
Assert-Path (Join-Path $sourceDir "AM1.5标准光谱数据280-4000nm.xlsx") "AM1.5 默认参考光谱"
Assert-Path (Join-Path $sourceDir "AM0标准光谱数据 120-4000nm.xlsx") "AM0 参考光谱"
Assert-Path (Join-Path $sourceDir "1027SR.xlsx") "默认 SR 文件"
Assert-Path (Join-Path $sourceDir "assets\spectrum-match-icon.ico") "程序图标"
Assert-Path $specPath "PyInstaller spec"
Assert-Path $issPath "Inno Setup 配置"

if ($SkipPyInstaller) {
    Write-Step "复用现有 PyInstaller 输出"
    Assert-Path $appExe "打包后的程序"
} else {
    Write-Step "准备本地构建 Python 环境"
    $pythonPath = Find-Python
    $usesCodexRuntime = $pythonPath -like "*\.cache\codex-runtimes\*"
    if (-not (Test-Path -LiteralPath (Join-Path $venvDir "Scripts\python.exe"))) {
        $venvArgs = @("-m", "venv")
        if ($usesCodexRuntime) {
            $venvArgs += "--system-site-packages"
        }
        $venvArgs += $venvDir
        & $pythonPath @venvArgs
    }
    $venvPython = Join-Path $venvDir "Scripts\python.exe"
    Assert-Path $venvPython "构建虚拟环境 Python"

    if ($usesCodexRuntime -and -not (Test-PythonRuntimeDependencies $venvPython)) {
        Write-Step "重建可复用 Codex runtime 依赖的构建环境"
        Remove-BuildPath $venvDir
        & $pythonPath -m venv --system-site-packages $venvDir
        Assert-Path $venvPython "构建虚拟环境 Python"
    }

    $pipBaseArgs = @("--default-timeout", "60", "--retries", "2", "--only-binary=:all:")
    & $venvPython -m pip install --upgrade pip
    if ($usesCodexRuntime -and (Test-PythonRuntimeDependencies $venvPython)) {
        & $venvPython -m pip install @pipBaseArgs pyinstaller
    } else {
        & $venvPython -m pip install @pipBaseArgs -r (Join-Path $sourceDir "requirements.txt") pyinstaller
    }

    Write-Step "运行 PyInstaller"
    Remove-BuildPath $distDir
    Remove-BuildPath $workDir
    & $venvPython -m PyInstaller --noconfirm --clean --distpath $distDir --workpath $workDir $specPath
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller 打包失败，退出码：$LASTEXITCODE"
    }
    Assert-Path $appExe "打包后的程序"
}

if (-not $SkipPackagedTests) {
    Write-Step "验证打包后的程序"
    & $appExe --self-test
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "打包程序核心自检失败，退出码：$LASTEXITCODE"
    }

    $previousSmoke = $env:SPD_GUI_SMOKE
    try {
        $env:SPD_GUI_SMOKE = "1"
        & $appExe
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "打包程序 GUI 冒烟检查失败，退出码：$LASTEXITCODE"
        }
    } finally {
        $env:SPD_GUI_SMOKE = $previousSmoke
    }
}

if ($SkipInstaller) {
    Write-Step "已跳过 Inno Setup 安装器生成"
    Write-Host "打包程序目录：$($appExe | Split-Path -Parent)"
    exit 0
}

Write-Step "运行 Inno Setup 生成安装器"
$iscc = Find-Iscc
if (-not $iscc) {
    Write-Warning "未找到 Inno Setup 编译器 ISCC.exe。"
    Write-Warning "请先安装 Inno Setup 6，然后重新运行本脚本。"
    Write-Host "PyInstaller 输出已生成：$($appExe | Split-Path -Parent)"
    exit 2
}

& $iscc $issPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup 生成安装器失败，退出码：$LASTEXITCODE"
}
Assert-Path $setupExe "最终安装包"

Write-Step "完成"
Write-Host "可外发安装包：$setupExe" -ForegroundColor Green
