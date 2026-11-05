#!/usr/bin/env python3
"""Собирает .lproj из Localization/source и проверяет, что в переводах ничего не потеряно."""
import json, re, sys, pathlib
root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
keys = json.load(open(root / "keys.json", encoding="utf-8"))
spec = re.compile(r"%(?:lld|@|%)")
esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
failed = False
for src in sorted((root / "source").glob("*.txt")):
    lines = src.read_text(encoding="utf-8").splitlines()
    if len(lines) != len(keys):
        print(f"{src.name}: {len(lines)} строк вместо {len(keys)}"); failed = True; continue
    for i, (k, v) in enumerate(zip(keys, lines)):
        if sorted(spec.findall(k)) != sorted(spec.findall(v)):
            print(f"{src.name}:{i+1}: не совпали подстановки: {k!r} / {v!r}"); failed = True
    d = out / f"{src.stem}.lproj"; d.mkdir(parents=True, exist_ok=True)
    (d / "Localizable.strings").write_text("".join(f'"{esc(k)}" = "{esc(v)}";\n' for k, v in zip(keys, lines)), encoding="utf-8")
ru = out / "ru.lproj"; ru.mkdir(parents=True, exist_ok=True)
(ru / "Localizable.strings").write_text("", encoding="utf-8")
sys.exit(1 if failed else 0)
