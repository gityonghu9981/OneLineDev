# -*- coding: utf-8 -*-
"""Strata 统一管理器（独立模块，v2.0.0）

Strata 是 orca 专用引擎（pack 绑定模型架构），加载 YOUR_STRATA_MODEL_DIR 目录下的模型。
- 显存控制：--expert-cache（GPU 专家驻留数，越大越占显存）+ --kv 量化(int8/q4_0) + --max-context
- 层数由模型固定（48 层），不可调；若需更省显存可用低显存模式(--mmap-experts/--resident-experts)
- 默认端口：8080（strata serve/server.py 桥接 HTTP，一次一模型，停旧起新）
"""
import json
import os
import re
import subprocess
import sys
import time

STRATA_EXE = r"YOUR_STRATA_EXE"
STRATA_CWD = r"YOUR_STRATA_REPO"
STRATA_MODEL_DIR = r"YOUR_STRATA_MODEL_DIR"
STRATA_PACK = "packs/orca-iq3_xxs"
STRATA_PORT = 8080  # strata.exe --serve 原生默认端口
STRATA_EXPERT_PROFILE = "data/expert-profile.bin"
STRATA_LOG = "strata-run.log"


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


def _split_shard_num(fname):
    """从文件名提取 shard 序号，如 Qwen3.8-...-00001-of-00002.gguf → (1, 2)。"""
    m = re.search(r'-(\d{5})-of-(\d{5})\.gguf$', fname)
    if m:
        return int(m.group(1)), int(m.group(2))
    return 0, 0


def scan_strata_models():
    """扫描 orca 目录，按主模型名归组（多 shard 合并），含 shard 数与总大小GB。"""
    groups = {}
    for f in sorted(os.listdir(STRATA_MODEL_DIR)):
        if not f.lower().endswith(".gguf"):
            continue
        base = re.sub(r'-\d{5}-of-\d{5}', '', f)
        p = os.path.join(STRATA_MODEL_DIR, f)
        try:
            sz = os.path.getsize(p)
        except Exception:
            sz = 0
        if base not in groups:
            groups[base] = {"name": base, "shards": [], "size_gb": 0.0}
        groups[base]["shards"].append(f)
        groups[base]["size_gb"] += sz / 1e9
    out = []
    for base, g in groups.items():
        g["shards"].sort()
        g["size_gb"] = round(g["size_gb"], 1)
        out.append(g)
    out.sort(key=lambda x: x["name"].lower())
    return out


def strata_pids_on_port(port):
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


def strata_stop_port(port):
    """停掉监听该端口的所有进程（回收显存）。"""
    killed = []
    for pid in strata_pids_on_port(port):
        try:
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                           capture_output=True, timeout=10)
            killed.append(pid)
        except Exception:
            pass
    # 兜底：按 strata.exe 进程名结束（端口探测不到的）
    try:
        r = subprocess.run(["taskkill", "/IM", "strata.exe", "/F"],
                           capture_output=True, timeout=10)
    except Exception:
        pass
    return killed


def strata_start(model_base, port=STRATA_PORT, max_context=32768,
                 kv="int8", expert_cache=0, low_vram=False):
    """停旧 → 起新 Strata serve，返回 {ok, message, gpu_before, gpu_after}。
    Strata 引擎(strata.exe --serve)本身不提供 HTTP；OpenAI API 由 YOUR_STRATA_REPO\serve\server.py
    提供，它拉起 strata.exe 引擎并桥接出 http://127.0.0.1:<port>/v1。本管理器动态生成引擎 config
    再启动 serve 层（系统 python 运行，serve 依赖已装）。
    - model_base：模型主名（scan_strata_models 的 name）
    - max_context：KV/上下文容量（越大越占显存）
    - kv：KV 量化 int8 / q4_0（int8 省一半显存、q4_0 更省）
    - expert_cache：GPU 专家驻留数（0=auto，越大越占显存；调小省显存）
    - low_vram：低显存模式（--resident-experts），建议显存吃紧时开
    """
    before = gpu_mem()
    models = scan_strata_models()
    m = next((x for x in models if x["name"] == model_base), None)
    if not m:
        return {"ok": False, "message": "Strata 模型库中未找到: %s" % model_base,
                "gpu_before": before, "gpu_after": {}}
    shards = [os.path.join(STRATA_MODEL_DIR, f) for f in m["shards"]]
    native = shards[0]
    # 跟原始 strata config：native 与 ple 用同一文件（Strata 自动处理多 shard 切分）
    ple = shards[0]

    strata_stop_port(port)
    # 引擎参数（serve 层负责拉起引擎；args 不含 --serve，与原始 strata-orca-iq3_xxs.json 一致）
    args = ["--pack", STRATA_PACK, "--native", native, "--ple-gguf", ple,
            "--expert-profile", STRATA_EXPERT_PROFILE,
            "--expert-cache", ("auto" if expert_cache == 0 else str(expert_cache)),
            "--prefill", "512", "--spec", "4", "--spec-min-p", "0.5",
            "--max-context", str(max_context), "--kv", kv]
    if low_vram:
        args.append("--resident-experts")
    # 动态生成 serve 层要的引擎 config（与 strata-orca-iq3_xxs.json 同构）
    cfg = {"exe": STRATA_EXE, "args": args, "cwd": STRATA_CWD,
           "tokenizer": "packs/orca-iq3_xxs/tokenizer",
           "model_name": m["name"], "log": STRATA_LOG,
           "host": "127.0.0.1", "port": port}
    cfg_path = os.path.join(STRATA_CWD, "strata-live-config.json")
    try:
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
    except Exception as e:
        return {"ok": False, "message": "写 Strata config 失败: %s" % e,
                "gpu_before": before, "gpu_after": {}}
    # 用系统 python 启动 serve/server.py（拉起 strata.exe 引擎并桥接 HTTP）
    python = sys.executable
    argv = [python, "-m", "serve.server", "--engine", "strata",
            "--config", cfg_path, "--port", str(port)]
    try:
        proc = subprocess.Popen(
            argv, cwd=STRATA_CWD,
            creationflags=(subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        after = {}
        for _ in range(4):
            time.sleep(2)
            g = gpu_mem()
            if g:
                after = g
                break
        return {"ok": True,
                "message": "Strata serve 已启动 PID=%s 端口=%s 模型=%s" % (proc.pid, port, model_base),
                "gpu_before": before, "gpu_after": after}
    except Exception as e:
        return {"ok": False, "message": "Strata serve 启动失败: %s" % e,
                "gpu_before": before, "gpu_after": gpu_mem()}


def strata_status(port=STRATA_PORT):
    """探测 18081 是否在跑 + GPU 显存。"""
    gpu = gpu_mem()
    running = bool(strata_pids_on_port(port))
    return {"port": port, "running": running, "gpu": gpu}
