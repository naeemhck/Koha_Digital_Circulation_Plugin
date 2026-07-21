#!/usr/bin/env python3
import pathlib, sys, zipfile
out=pathlib.Path(sys.argv[1]); manifest=pathlib.Path(sys.argv[2])
files=[line.strip() for line in manifest.read_text(encoding='utf-8').splitlines() if line.strip()]
with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
    for name in sorted(files):
        data=pathlib.Path(name).read_bytes(); info=zipfile.ZipInfo(name,date_time=(2026,7,21,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16;archive.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
