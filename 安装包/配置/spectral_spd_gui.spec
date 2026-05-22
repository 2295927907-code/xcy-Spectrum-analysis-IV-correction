# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path


package_dir = Path(SPECPATH).resolve().parent
source_dir = package_dir / "源文件"

datas = [
    (str(source_dir / "AM1.5标准光谱数据280-4000nm.xlsx"), "."),
    (str(source_dir / "AM0标准光谱数据 120-4000nm.xlsx"), "."),
    (str(source_dir / "1027SR.xlsx"), "."),
    (str(source_dir / "assets"), "assets"),
]

hiddenimports = [
    "openpyxl",
    "openpyxl.cell._writer",
    "PIL",
    "PIL._tkinter_finder",
    "xlrd",
]

a = Analysis(
    [str(source_dir / "spectral_spd_gui.py")],
    pathex=[str(source_dir)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="光谱匹配分析器",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=str(source_dir / "assets" / "spectrum-match-icon.ico"),
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="光谱匹配分析器",
)
