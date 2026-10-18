#!/usr/bin/env python3
"""登录米家（终端显示二维码，用米家 App 扫码确认），找到挂灯并把设备信息存到 ~/.config/mijia-lamp.json（权限 600）。

登录凭据由 mijiaAPI 存到 ~/.config/mijia-api/auth.json（权限 600）。令牌不会打印到屏幕。
默认按型号 xiaomi.light.bar2（米家显示器挂灯 2）查找；其他型号可用环境变量 LAMP_MODEL 指定，
账号下有多盏同型号灯时可用 LAMP_NAME 按名称区分。
"""
import json, os, stat, sys
from pathlib import Path
from mijiaAPI import mijiaAPI

AUTH = Path.home() / ".config" / "mijia-api" / "auth.json"
OUT = Path.home() / ".config" / "mijia-lamp.json"
MODEL = os.environ.get("LAMP_MODEL", "xiaomi.light.bar2")
NAME = os.environ.get("LAMP_NAME")

AUTH.parent.mkdir(parents=True, exist_ok=True)
api = mijiaAPI(str(AUTH))
api.login()  # 终端会出二维码（以及一个二维码图片链接），用米家 App 扫码并在手机上确认
if AUTH.exists():
    os.chmod(AUTH, stat.S_IRUSR | stat.S_IWUSR)

devices = api.get_devices_list()
print(f"账号下共 {len(devices)} 个设备：")
for d in devices:
    print(f"  {d.get('name')}  model={d.get('model')}")

cands = [d for d in devices if d.get("model") == MODEL and (not NAME or d.get("name") == NAME)]
if not cands:
    sys.exit(f"没有找到型号为 {MODEL} 的设备。可以用 LAMP_MODEL=<型号> 重试（上面列出了你账号下的设备型号）。")
if len(cands) > 1:
    names = "、".join(str(d.get("name")) for d in cands)
    sys.exit(f"找到多盏 {MODEL}：{names}。请用 LAMP_NAME=<名称> 指定一盏。")

lamp = cands[0]
OUT.write_text(json.dumps({k: lamp.get(k) for k in ("did", "name", "model")}, ensure_ascii=False))
os.chmod(OUT, stat.S_IRUSR | stat.S_IWUSR)
print(f"已找到「{lamp.get('name')}」，设备信息保存到 {OUT}（权限 600）")
