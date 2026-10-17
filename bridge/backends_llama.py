# -*- coding: utf-8 -*-
"""llama.cpp 统一管理器（独立模块，v2.0.0）

模型库任意切换、加载参数全可调、GPU 显存提示。
- 模型库：YOUR_MODEL_ROOT（放 .gguf 自动进库，主模型不包含 mmproj 视觉投影）
- 默认端口：8090（一次只加载一个模型，停旧起新）
"""
import json
import os
import subprocess
import time

LLAMA_CWD = r"YOUR_LLAMA_CPP_DIR"
LLAMA_MODEL_ROOT = r"YOUR_MODEL_ROOT"
LLAMA_DEFAULT_PORT = 8090
LLAMA_LLAMA_EXE = os.path.join(LLAMA_CWD, "llama-server.exe")


def gpu_mem():
    """nvidia-smi 返回当前 GPU 显存占用（MiB），失败返回空 dict。"""
    try:
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,memory.used,memory.free",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
            creationflags=(subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0),
            encoding="utf-8", errors="replace")
        line = (r.stdout or "").strip()
        if not line:
            return {}
        p = line.split(",")
        if len(p) >= 4:
            return {"name": p[0].strip(),
                    "total": int(p[1].strip()),
                    "used": int(p[2].strip()),
                    "free": int(p[3].strip())}
    except Exception:
        pass
    return {}


def scan_llama_models():
    """扫描 llama 备选库：递归找主 GGUF（排除 mmproj 视觉投影），含名称/路径/大小GB。"""
    out = []
    for dirpath, _, files in os.walk(LLAMA_MODEL_ROOT):
        for f in files:
            if f.lower().endswith(".gguf") and "mmproj" not in f.lower():
                p = os.path.join(dirpath, f)
                try:
                    sz = os.path.getsize(p)
                except Exception:
                    sz = 0
                out.append({"name": f, "path": p,
                            "size_gb": round(sz / 1e9, 1)})
    out.sort(key=lambda x: x["name"].lower())
    return out


def llama_pids_on_port(port):
    """找出监听指定端口的进程 PID 列表。"""
    pids = set()
    try:
        r = subprocess.run(["netstat", "-ano", "-p", "tcp"],
                           capture_output=True, text=True, timeout=10,
                           encoding="utf-8", errors="replace")
        for line in (r.stdout or "").splitlines():
            if "127.0.0.1:%d" % port in line and "LISTENING" in line:
                pid = line.split()[-1]
                if pid.isdigit():
                    pids.add(int(pid))
    except Exception:
        pass
    return list(pids)


def llama_stop_port(port):
    """停掉监听该端口的所有进程（回收显存）。"""
    killed = []
    for pid in llama_pids_on_port(port):
        try:
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                           capture_output=True, timeout=10)
            killed.append(pid)
        except Exception:
            pass
    return killed


def llama_start(model_path, port=LLAMA_DEFAULT_PORT, ctx=8192,
                ngl=99, threads=16, ctk="q8_0", ctv="q8_0"):
    """停旧 → 起新 llama-server，返回 {ok, message, gpu_before, gpu_after}。
    gpu_after 为加载后尽力取到的 GPU 显存占用提示（模型大加载慢时可能为首次采样值）。
    """
    before = gpu_mem()
    llama_stop_port(port)
    argv = [LLAMA_LLAMA_EXE, "-m", model_path, "-ngl", str(ngl),
            "--cpu-moe", "-c", str(int(ctx)), "-ctk", ctk, "-ctv", ctv,
            "-fa", "on", "--jinja", "-rea", "off", "-t", str(int(threads)),
            "--host", "127.0.0.1", "--port", str(port)]
    try:
        proc = subprocess.Popen(
            argv,
            creationflags=(subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # 等 2~8s 尽力取加载后的 GPU 显存做提示（不阻塞过久）
        after = {}
        for _ in range(4):
            time.sleep(2)
            g = gpu_mem()
            if g:
                after = g
                break
        return {"ok": True,
                "message": "llama-server 已启动 PID=%s 端口=%s" % (proc.pid, port),
                "gpu_before": before, "gpu_after": after}
    except Exception as e:
        return {"ok": False, "message": "启动失败: %s" % e,
                "gpu_before": before, "gpu_after": gpu_mem()}


def llama_status_all():
    """探测默认端口 8090 是否在跑 + 当前加载模型 + GPU 显存。"""
    gpu = gpu_mem()
    port = LLAMA_DEFAULT_PORT
    running = bool(llama_pids_on_port(port))
    model = ""
    if running:
        try:
            r = subprocess.run(
                ["curl", "-s", "--max-time", "3",
                 "http://127.0.0.1:%d/v1/models" % port],
                capture_output=True, text=True, timeout=6,
                creationflags=(subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0),
                encoding="utf-8", errors="replace")
            if r.stdout:
                j = json.loads(r.stdout)
                ids = (j.get("data") or [])
                if ids and ids[0].get("id"):
                    model = ids[0]["id"]
        except Exception:
            pass
    return {"port": port, "running": running, "model": model, "gpu": gpu}
