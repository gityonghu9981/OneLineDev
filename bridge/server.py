# -*- coding: utf-8 -*-
"""
本地AI中转服务 (LocalAI Bridge) v2.0.1 —— 多后端版
作用：手机端「窗口」APP  <->  本地电脑 模型/TTS 的统一入口。
- WebSocket 服务：手机端连接（默认端口 8765）
- 多后端：lm_studio / llama.cpp 统一管理器 / Strata 统一管理器 (OpenAI 兼容) + openclaw + qwenpaw
- 语音：对接 GPT-SoVITS v2pro（POST /tts，默认 127.0.0.1:9880）
- 设置：后端切换、模型选择、上下文/温度、启停可控后端

启动：python server.py
"""
import asyncio
import glob
import json
import os
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlparse

import requests
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

# 多模态模块（图片/文件→模型输入），独立拆分便于扩展
from multimodal import build_user_content, extract_text, count_chars

# 独立后端模块（分级分功能）——llama.cpp 统一管理器
from backends_llama import (scan_llama_models, llama_start, llama_stop_port,
                            llama_status_all, gpu_mem, LLAMA_DEFAULT_PORT,
                            LLAMA_MODEL_ROOT, LLAMA_LLAMA_EXE)
from backends_strata import (scan_strata_models, strata_start, strata_stop_port,
                             strata_status, STRATA_PORT)

# ============ 配置 ============
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
OPENCLAW_JSON = r"YOUR_OPENCLAW_HOME\openclaw.json"
LLAMA_CWD = r"YOUR_LLAMA_CPP_DIR"
OPENCLAW_CHAT_MODEL = "clawdbot:main"

DEFAULT_BACKENDS = {
    "lm_studio": {
        "name": "LM Studio", "type": "openai",
        "base_url": "http://127.0.0.1:1234/v1",
        "enabled": True, "controllable": False,
        "settings": {"context": 8192, "temperature": 0.7, "max_tokens": 1024},
        "model": "",
    },
    "llama": {
        "name": "llama.cpp 统一管理器", "type": "openai",
        "base_url": "http://127.0.0.1:8090/v1",
        "enabled": True, "controllable": True, "port": 8090,
        "settings": {"context": 8192, "temperature": 0.7, "max_tokens": 1024},
        "model": "",
    },
    "strata": {
        "name": "Strata 统一管理器", "type": "openai",
        "base_url": "http://127.0.0.1:8080/v1",
        "enabled": True, "controllable": True, "port": 8080,
        "settings": {"context": 8192, "temperature": 0.7, "max_tokens": 1024},
        "model": "",
    },
    "openclaw": {
        "name": "OpenClaw", "type": "openclaw",
        "base_url": "http://127.0.0.1:18789",
        "token": "YOUR_OPENCLAW_TOKEN",
        "enabled": True, "controllable": True, "port": 18789,
        "executable": r"YOUR_NODE_EXE",
        "cwd": r"YOUR_OPENCLAW_HOME",
        "args": [r"YOUR_NPM_ROOT\node_modules\openclaw-cn\dist\entry.js",
                 "gateway", "--port", "18789"],
        "settings": {"context": 0, "temperature": 0.7, "max_tokens": 1024},
        "model": OPENCLAW_CHAT_MODEL,
    },
    "qwenpaw": {
        "name": "QwenPaw", "type": "qwenpaw",
        "base_url": "http://127.0.0.1:8088",
        "enabled": True, "controllable": True, "port": 8088,
        "executable": r"YOUR_QWENPAW_ENV\Scripts\qwenpaw.exe",
        "cwd": r"YOUR_QWENPAW_ENV",
        "args": ["app", "--host", "0.0.0.0", "--port", "8088"],
        "settings": {"context": 0, "temperature": 0.7, "max_tokens": 1024},
        "model": "",
    },
}

DEFAULT_CONFIG = {
    "lm_studio_url": "http://127.0.0.1:1234/v1",
    "tts_url": "http://127.0.0.1:9880/tts",
    "tts_ref_audio": "YOUR_GPT_SOVITS_DIR/voice-rosmontis/ref-8s.wav",
    "tts_prompt_lang": "zh",
    "default_model": "",
    "context_length": 4096,
    "tts_text_lang": "zh",
    "tts_media_type": "wav",
    "history_max": 20,
    "host": "0.0.0.0",
    "port": 8765,
    "active_backend": None,
    "backends": json.loads(json.dumps(DEFAULT_BACKENDS)),  # deep copy
}


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                loaded = json.load(f)
            cfg.update(loaded)
        except Exception:
            pass
    # 兜底：backends / active_backend 缺失时用默认
    if not cfg.get("backends"):
        cfg["backends"] = json.loads(json.dumps(DEFAULT_BACKENDS))
    # 不默认任何后端（用户手动选择，避免每次自动选中 LM Studio）；无效值清空
    if cfg.get("active_backend") and cfg["active_backend"] not in cfg["backends"]:
        cfg["active_backend"] = None
    return cfg


def save_config(c):
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(c, f, ensure_ascii=False, indent=2)


cfg = load_config()
app = FastAPI(title="LocalAI Bridge")


# ============ 小工具 ============
def active_bid():
    """当前对话后端；不默认任何后端（用户手动选择，避免每次自动选中 LM Studio）。"""
    return cfg.get("active_backend") or None


def active_be():
    bid = active_bid()
    if not bid or bid not in cfg["backends"]:
        return None, None
    return bid, cfg["backends"][bid]


def pick_be(data):
    """优先取消息显式携带的 backend_id（会话绑定后端），否则用全局 active。"""
    bid = (data.get("backend_id") or "").strip()
    be = cfg["backends"].get(bid)
    if be is not None:
        return bid, be
    return active_be()


def ns_positions(hist):
    """历史中非 system 消息（user/assistant）的下标序列。"""
    return [i for i, m in enumerate(hist) if m.get("role") != "system"]


def tcp_open(host, port, timeout=1.5):
    try:
        s = socket.socket()
        s.settimeout(timeout)
        ok = s.connect_ex((host, int(port))) == 0
        s.close()
        return ok
    except Exception:
        return False


def host_port(url):
    try:
        p = urlparse(url)
        return p.hostname or "127.0.0.1", p.port
    except Exception:
        return "127.0.0.1", None


# ============ 后端状态 / 模型列表 ============
def backend_status(be):
    if not be.get("enabled", True):
        return "disabled"
    t = be["type"]
    try:
        if t == "openai":
            r = requests.get(be["base_url"] + "/models", timeout=(0.5, 1.0))
            return "running" if r.status_code == 200 else "stopped"
        if t == "openclaw":
            h, p = host_port(be["base_url"])
            return "running" if tcp_open(h, p) else "stopped"
        if t == "qwenpaw":
            r = requests.get(be["base_url"] + "/api/healthz", timeout=(0.5, 1.0))
            return "running" if r.status_code == 200 else "stopped"
    except Exception:
        return "stopped"
    return "unknown"


def openclaw_models():
    try:
        with open(OPENCLAW_JSON, encoding="utf-8") as f:
            j = json.load(f)
        models = (j.get("agents", {}).get("defaults", {})
                    .get("models", {}))
        return list(models.keys())
    except Exception:
        return []


def qwenpaw_models(base):
    try:
        r = requests.get(base + "/api/models", timeout=6)
        providers = r.json()
        out = []
        for p in providers:
            ms = p.get("models") or []
            if not ms:
                continue
            pid = p.get("id", "")
            for m in ms:
                mid = m.get("id") if isinstance(m, dict) else str(m)
                if mid:
                    out.append("%s::%s" % (pid, mid))
        return out
    except Exception:
        return []


def backend_models(be):
    t = be["type"]
    try:
        if t == "openai":
            r = requests.get(be["base_url"] + "/models", timeout=5)
            data = r.json()
            out = []
            for m in data.get("data", []):
                mid = m.get("id", "")
                if not mid:
                    continue
                if mid.endswith(".gguf"):
                    disp = os.path.basename(mid)
                    if disp.lower().endswith(".gguf"):
                        disp = disp[:-5]
                    out.append(disp)
                else:
                    out.append(mid)
            if out:
                return out
            return _llama_fallback_models(be)
        if t == "openclaw":
            return openclaw_models()
        if t == "qwenpaw":
            return qwenpaw_models(be["base_url"])
    except Exception:
        if t == "openai":
            return _llama_fallback_models(be)
        return []
    return []


def _llama_fallback_models(be):
    """后端未运行时，从 args 的 -m 参数回推出模型显示名（文件名去 .gguf）。"""
    args = be.get("args") or []
    for i, a in enumerate(args):
        if a == "-m" and i + 1 < len(args):
            disp = os.path.basename(args[i + 1])
            if disp.lower().endswith(".gguf"):
                disp = disp[:-5]
            return [disp] if disp else []
    return []


# ============ 后端 chat ============
def chat_openai(be, hist):
    """OpenAI 兼容后端：流式生成器，逐块 yield (evt, payload)。
    evt: 'delta'文本增量 / 'reasoning'思考增量 / 'done'结束(带完整元数据)"""
    st = be.get("settings", {})
    # P1-4：注入 system prompt 解决中英混杂；与用户历史分离，不反复叠加
    messages = []
    sys_prompt = be.get("system_prompt") or cfg.get(
        "system_prompt", "始终使用简体中文回复，代码、命令与专有名词除外。")
    if sys_prompt:
        messages.append({"role": "system", "content": sys_prompt})
    messages.extend(hist)
    body = {
        "messages": messages,
        "max_tokens": st.get("max_tokens", 1024),
        "temperature": st.get("temperature", 0.7),
        "stream": True,
    }
    model = be.get("model")
    if not model:
        # 未指定模型时自动取后端模型列表第一个。
        try:
            r = requests.get(be["base_url"] + "/models", timeout=5)
            ids = [m.get("id") for m in r.json().get("data", []) if m.get("id")]
            if ids:
                model = ids[0]
        except Exception:
            model = None
    if model:
        body["model"] = model
    t0 = time.time()
    r = requests.post(be["base_url"] + "/chat/completions",
                      json=body, stream=True, timeout=180)
    r.raise_for_status()
    r.encoding = 'utf-8'  # 修复：流式响应无 charset 时 requests 默认 latin-1 解码致中文乱码
    content_parts = []
    reasoning_parts = []
    usage = {}
    for line in r.iter_lines(decode_unicode=True):
        if not line:
            continue
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload in ("[DONE]", "[DONE"):
            break
        try:
            obj = json.loads(payload)
        except Exception:
            continue
        choices = obj.get("choices") or []
        if choices:
            delta = choices[0].get("delta") or {}
            c = delta.get("content")
            if c:
                content_parts.append(c)
                yield ("delta", c)
            rc = delta.get("reasoning_content") or delta.get("reasoning") or ""
            if rc:
                reasoning_parts.append(rc)
                yield ("reasoning", rc)
        if obj.get("usage"):
            usage = obj.get("usage") or {}
    content = "".join(content_parts)
    reasoning = "".join(reasoning_parts)
    # 兼容：部分推理模型流式时把回答全放 reasoning_content 而 content 一直为空。
    if not content and reasoning:
        content = reasoning
        reasoning = ""
    prompt = usage.get("prompt_tokens", 0) or 0
    completion = usage.get("completion_tokens", 0) or 0
    total = usage.get("total_tokens", 0) or 0
    cached = 0
    ptd = usage.get("prompt_tokens_details", None)
    if isinstance(ptd, dict):
        cached = ptd.get("cached_tokens", 0) or 0
    elif isinstance(ptd, list):
        cached = sum(x.get("cached_tokens", 0) or 0 for x in ptd if isinstance(x, dict))
    yield ("done", {
        "text": content,
        "reasoning": reasoning,
        "usage": {
            "prompt": int(prompt),
            "completion": int(completion),
            "total": int(total),
            "cached": int(cached),
        },
        "duration_ms": int((time.time() - t0) * 1000),
        "chars": len(content),
    })


# ============ 智能上下文压缩（把最旧对话压成摘要，避免无限累积） ============
def _est_tokens(messages):
    """粗略估算消息占用 token：中文对话为主，1 个字符≈1 token（略偏紧以便更早触发压缩）。"""
    total = 0
    for m in messages:
        total += count_chars(m.get("content"))  # 兼容多模态数组
    return total


def _summarize(be, old_hist):
    """尝试用后端模型生成中文语义摘要（只收 content；推理模型的英文 reasoning 不用）。
    失败或 content 为空返回空串。"""
    try:
        messages = [{
            "role": "system",
            "content": "请把下面这段历史对话压缩成简明中文摘要，保留关键问题、结论、"
                       "用户的偏好与要求、重要事实。控制在250字内，直接输出摘要正文，"
                       "不要任何前缀或解释。"
        }]
        messages.extend(old_hist)
        body = {
            "messages": messages,
            "max_tokens": 512,
            "temperature": 0.4,
            "stream": True,
        }
        model = be.get("model")
        if model:
            body["model"] = model
        r = requests.post(be["base_url"] + "/chat/completions",
                          json=body, stream=True, timeout=60)
        r.raise_for_status()
        r.encoding = 'utf-8'
        parts = []
        for line in r.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload in ("[DONE]", "[DONE"):
                break
            try:
                obj = json.loads(payload)
                for ch in (obj.get("choices") or []):
                    c = (ch.get("delta") or {}).get("content")
                    if c:
                        parts.append(c)
            except Exception:
                continue
        return "".join(parts).strip()
    except Exception:
        return ""


def _compact_summary(old_hist):
    """确定性概要（模型摘要不可用时的兜底）：提取各条用户消息的前40字要点拼接。"""
    points = []
    for m in old_hist:
        if m.get("role") == "user":
            c = extract_text(m.get("content")).strip()
            if c:
                points.append(c[:40])
    if not points:
        return ""
    return "；".join(points)[:500]


def _maybe_compress(be, hist, context):
    """检查历史是否接近 context 上限，若是则把最旧一小批对话压成摘要并替换。"""
    cc = cfg.get("context_compress") or {}
    if not cc.get("enabled", True):
        return 0, 0
    if be["type"] != "openai":
        return 0, 0
    if context <= 0 or len(hist) < 8:
        return 0, 0
    trigger = cc.get("trigger_ratio", 0.7)
    used = _est_tokens(hist)
    budget = int(context * trigger)
    if used <= budget:
        return 0, 0
    batch = int(cc.get("batch_messages", 10))
    if len(hist) <= batch:
        return 0, 0
    old, rest = hist[:batch], hist[batch:]
    summary = _summarize(be, old)
    if not summary:
        summary = _compact_summary(old)
    if not summary:
        return 0, 0
    new_hist = [{"role": "system", "content": "[前文概要] " + summary}] + rest
    hist.clear()
    hist.extend(new_hist)
    ns_removed = sum(1 for m in old if m.get("role") != "system")
    return len(old) // 2, ns_removed


def chat_openclaw(be, user_text, sid):
    """OpenClaw 网关：流式生成器，逐块 yield。"""
    url = be["base_url"] + "/v1/chat/completions"
    headers = {"Authorization": "Bearer " + be.get("token", "")}
    sys_prompt = be.get("system_prompt") or cfg.get(
        "system_prompt", "始终使用简体中文回复，代码、命令与专有名词除外。")
    messages = [{"role": "system", "content": sys_prompt}] if sys_prompt else []
    messages.append({"role": "user", "content": user_text})
    body = {
        "model": "clawdbot:main",
        "messages": messages,
        "user": "bridge-session-%s" % sid,
        "stream": True,
    }
    t0 = time.time()
    r = requests.post(url, headers=headers, json=body, stream=True, timeout=600)
    r.raise_for_status()
    r.encoding = 'utf-8'
    out = []
    for line in r.iter_lines(decode_unicode=True):
        if not line:
            continue
        if line.startswith("data:"):
            payload = line[5:].strip()
            if payload in ("[DONE", "[DONE]"):
                break
            try:
                obj = json.loads(payload)
            except Exception:
                continue
            try:
                c = obj["choices"][0]["delta"].get("content")
                if c:
                    out.append(c)
                    yield ("delta", c)
            except Exception:
                pass
    content = "".join(out)
    yield ("done", {
        "text": content, "reasoning": "",
        "usage": {"prompt": 0, "completion": 0, "total": 0, "cached": 0},
        "duration_ms": int((time.time() - t0) * 1000),
        "chars": len(content),
    })


def chat_qwenpaw(be, user_text, sid):
    """QwenPaw 后端：流式生成器，逐块 yield。"""
    url = be["base_url"] + "/api/console/chat"
    body = {
        "channel": "console",
        "user_id": "bridge",
        "session_id": "bridge-%s" % sid,
        "input": [{"content": [{"type": "text", "text": user_text}]}],
    }
    sel = be.get("model") or ""
    if "::" in sel:
        pid, mid = sel.split("::", 1)
        body["model_slot_override"] = {"provider_id": pid, "model": mid}
    t0 = time.time()
    r = requests.post(url, json=body, stream=True, timeout=600)
    r.raise_for_status()
    r.encoding = 'utf-8'
    chunks = []
    for line in r.iter_lines(decode_unicode=True):
        if not line:
            continue
        if line.startswith("data:"):
            payload = line[5:].strip()
            try:
                obj = json.loads(payload)
            except Exception:
                continue
            if obj.get("type") == "heartbeat":
                continue
            if obj.get("type") == "text" and obj.get("delta"):
                chunks.append(obj.get("text", ""))
                yield ("delta", obj.get("text", ""))
    content = "".join(chunks)
    yield ("done", {
        "text": content, "reasoning": "",
        "usage": {"prompt": 0, "completion": 0, "total": 0, "cached": 0},
        "duration_ms": int((time.time() - t0) * 1000),
        "chars": len(content),
    })


def stream_backend(be, hist, sid):
    """按后端类型路由的流式生成器。openai 发整段历史；openclaw/qwenpaw 只发最新用户消息。"""
    t = be["type"]
    if t == "openai":
        yield from chat_openai(be, hist)
        return
    last_user = extract_text(hist[-1]["content"])
    if t == "openclaw":
        yield from chat_openclaw(be, last_user, sid)
    elif t == "qwenpaw":
        yield from chat_qwenpaw(be, last_user, sid)
    else:
        raise RuntimeError("未知后端类型: %s" % t)


def backend_chat(be, hist, sid):
    """非流式聚合版（兼容保留，供脚本/其他调用）。"""
    final = {}
    for evt, payload in stream_backend(be, hist, sid):
        if evt == "done":
            final = payload
    return final


# ============ 后端启停（仅可控后端） ============
backend_procs = {}


def _tail(path, n=40):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except Exception:
        return ""


def _pid_on_port(port):
    try:
        out = subprocess.check_output(["netstat", "-ano", "-p", "TCP"],
                                      text=True, errors="replace")
        for ln in out.splitlines():
            if "LISTENING" not in ln.upper():
                continue
            parts = ln.split()
            if len(parts) < 5:
                continue
            local = parts[1]
            if local.endswith(":%s" % port):
                try:
                    return int(parts[-1])
                except Exception:
                    continue
    except Exception:
        pass
    return None


def do_start_backend(bid, be):
    if not be.get("controllable"):
        return {"status": "error", "message": "该后端不可由中转服务启停"}
    port = be.get("port")
    if tcp_open("127.0.0.1", port):
        return {"status": "started", "message": "端口 %s 已在监听" % port}
    # 统一管理器（llama.cpp / Strata）没有独立 executable，走管理器加载模型
    if not be.get("executable"):
        return {"status": "error",
                "message": "该后端由统一管理器加载，请在 llama.cpp / Strata 管理器中选择模型并加载"}
    exe = be["executable"]
    cwd = be.get("cwd") or os.path.dirname(exe)
    argv = [exe] + list(be.get("args", []))
    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    try:
        os.makedirs(log_dir, exist_ok=True)
    except Exception:
        pass
    logp = os.path.join(log_dir, "server_%s.log" % bid)
    errp = os.path.join(log_dir, "server_%s.err" % bid)
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    penv = None
    if be.get("env"):
        penv = dict(os.environ)
        penv.update(be["env"])
    with open(logp, "ab") as lf, open(errp, "ab") as ef:
        proc = subprocess.Popen(argv, cwd=cwd, stdout=lf, stderr=ef,
                                env=penv, creationflags=flags)
    backend_procs[bid] = proc
    deadline = time.time() + 120
    while time.time() < deadline:
        time.sleep(1.5)
        if proc.poll() is not None:
            tail = _tail(errp) or _tail(logp)
            return {"status": "error",
                    "message": "进程提前退出 code=%s。日志尾部:\n%s"
                               % (proc.returncode, tail)}
        if tcp_open("127.0.0.1", port):
            return {"status": "started"}
    return {"status": "error",
            "message": "启动超时(120s)，日志尾部:\n%s" % (_tail(errp) or _tail(logp))}


def do_stop_backend(bid, be):
    if not be.get("controllable"):
        return {"status": "error", "message": "该后端不可由中转服务启停"}
    port = be.get("port")
    pids = []
    pyp = backend_procs.pop(bid, None)
    if pyp is not None:
        pids.append(pyp.pid)
    pid = _pid_on_port(port)
    if pid:
        pids.append(pid)
    pids = list(dict.fromkeys(pids))
    for pid in pids:
        try:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                           capture_output=True)
        except Exception:
            pass
    deadline = time.time() + 15
    while time.time() < deadline:
        if not tcp_open("127.0.0.1", port):
            break
        time.sleep(0.8)
    return {"status": "stopped"}


# ============ LM Studio 本地模型管理（lms CLI，供 APP 控制加载/卸载/显存） ============
LMS_EXE = os.environ.get("LMS_EXE") or r"YOUR_LMS_EXE"


def _lms_ls():
    """lms ls 列出本地全部模型（含未加载），返回 [{id,size,loaded}]。"""
    try:
        r = subprocess.run([LMS_EXE, "ls"], capture_output=True, text=True,
                           timeout=30, creationflags=(subprocess.CREATE_NO_WINDOW
                           if os.name == "nt" else 0), encoding="utf-8",
                           errors="replace")
        text = r.stdout or ""
        models = []
        for line in text.splitlines():
            s = line.strip()
            if not s or s.startswith(("LLM", "PARAMS", "EMBEDDING", "You have")):
                continue
            parts = s.split()
            if len(parts) < 2:
                continue
            name = parts[0]
            size = ""
            for i, p in enumerate(parts):
                if p in ("GB", "MB") and i > 0:
                    size = parts[i - 1] + " " + p
                    break
            models.append({"id": name, "size": size, "loaded": "LOADED" in s})
        return models
    except Exception as e:
        return [{"id": "__error__", "size": "", "loaded": False,
                 "msg": "lms ls 失败: %s" % e}]


def _lms_load(model, gpu="max", context=8192):
    argv = [LMS_EXE, "load", model]
    gpu = str(gpu or "max")
    if gpu and gpu != "off":
        argv += ["--gpu", gpu]
    argv += ["-c", str(int(context)), "-y"]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=240,
                           creationflags=(subprocess.CREATE_NO_WINDOW
                           if os.name == "nt" else 0), encoding="utf-8",
                           errors="replace")
        text = (r.stdout or "") + (r.stderr or "")
        ok = "loaded successfully" in text.lower() or "✓ LOADED" in text
        return {"ok": ok, "message": text[-600:].strip()}
    except subprocess.TimeoutExpired:
        return {"ok": False, "message": "加载超时(240s)"}
    except Exception as e:
        return {"ok": False, "message": "加载失败: %s" % e}


def _lms_unload(model):
    try:
        r = subprocess.run([LMS_EXE, "unload", model], capture_output=True,
                           text=True, timeout=120,
                           creationflags=(subprocess.CREATE_NO_WINDOW
                           if os.name == "nt" else 0), encoding="utf-8",
                           errors="replace")
        text = (r.stdout or "") + (r.stderr or "")
        ok = "unloaded" in text.lower()
        return {"ok": ok, "message": text[-400:].strip()}
    except Exception as e:
        return {"ok": False, "message": "卸载失败: %s" % e}


# ============ 统一 llama.cpp 管理器（模型库随便切） ============
# 全部函数已迁移至独立模块 backends_llama.py（scan_llama_models/llama_start/
# llama_stop_port/llama_status_all/gpu_mem），此处不再重复定义。


# ============ openclaw 模型选择（写网关配置） ============
def openclaw_set_model(model_id):
    ts = time.strftime("%Y%m%d-%H%M%S")
    shutil.copy(OPENCLAW_JSON, OPENCLAW_JSON + ".bak-select-%s" % ts)
    with open(OPENCLAW_JSON, encoding="utf-8") as f:
        j = json.load(f)
    node = j.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
    node["primary"] = model_id
    fbs = node.get("fallbacks") or []
    if fbs:
        fbs[0] = model_id
    else:
        fbs = [model_id]
    node["fallbacks"] = fbs
    with open(OPENCLAW_JSON, "w", encoding="utf-8") as f:
        json.dump(j, f, ensure_ascii=False, indent=2)


# ============ GPT-SoVITS TTS ============
def tts_synthesize(text):
    body = {
        "text": text,
        "text_lang": cfg.get("tts_text_lang", "zh"),
        "ref_audio_path": cfg.get("tts_ref_audio", ""),
        "prompt_lang": cfg.get("tts_prompt_lang", "zh"),
        "media_type": cfg.get("tts_media_type", "wav"),
        "streaming_mode": True,
    }
    r = requests.post(cfg["tts_url"], json=body, timeout=180, stream=True)
    r.raise_for_status()
    return r


# ============ Whisper STT ============
_whisper_model = None
WHISPER_DIR = r"YOUR_WHISPER_DIR"


def get_whisper():
    global _whisper_model
    if _whisper_model is None:
        from faster_whisper import WhisperModel
        _whisper_model = WhisperModel(
            WHISPER_DIR, device="cuda", compute_type="int8_float16")
    return _whisper_model


def whisper_transcribe(audio_bytes):
    tmp = os.path.join(tempfile.gettempdir(), "localai_stt.wav")
    with open(tmp, "wb") as f:
        f.write(audio_bytes)
    model = get_whisper()
    segments, _ = model.transcribe(tmp, language="zh", beam_size=5, vad_filter=True)
    return "".join(s.text for s in segments).strip()


async def handle_stt(ws, audio):
    if not audio:
        await ws.send_text(json.dumps(
            {"type": "error", "message": "没有收到录音数据"}, ensure_ascii=False))
        return
    try:
        text = await asyncio.to_thread(whisper_transcribe, audio)
        await ws.send_text(json.dumps(
            {"type": "stt_result", "text": text}, ensure_ascii=False))
    except Exception as e:
        await ws.send_text(json.dumps(
            {"type": "error", "message": "STT 识别失败: %s" % e}, ensure_ascii=False))


def list_voices():
    voices = []
    base = r"YOUR_GPT_SOVITS_DIR"
    try:
        for d in os.listdir(base):
            if not d.startswith("voice-"):
                continue
            voice_dir = os.path.join(base, d)
            if not os.path.isdir(voice_dir):
                continue
            wavs = glob.glob(os.path.join(voice_dir, "*.wav"))
            if not wavs:
                continue
            wavs.sort(key=lambda p: (0 if os.path.basename(p).lower().startswith("ref") else 1))
            ref = wavs[0].replace("\\", "/")
            voices.append({"name": d.replace("voice-", ""), "label": d, "ref": ref})
    except Exception:
        pass
    return voices


# ============ 会话（历史全局按 conversation_id 持久化，跨连接/跨重启保留） ============
HIST_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "conversations.json")
GLOBAL_HIST = {}


def _load_hist(conv_id, bid):
    return GLOBAL_HIST.setdefault("%s::%s" % (conv_id, bid), [])


def _save_hist():
    try:
        with open(HIST_FILE, "w", encoding="utf-8") as f:
            json.dump(GLOBAL_HIST, f, ensure_ascii=False)
    except Exception:
        pass


def _init_hist():
    global GLOBAL_HIST
    try:
        with open(HIST_FILE, "r", encoding="utf-8") as f:
            GLOBAL_HIST = json.load(f)
    except Exception:
        GLOBAL_HIST = {}


class Session:
    def __init__(self):
        pass
    def hist(self, conv_id, bid):
        return _load_hist(conv_id, bid)


sessions = {}


# ============ 后端快照 ============
def build_backends_snapshot(overrides=None):
    out = []
    for bid, be in cfg["backends"].items():
        if be["type"] == "openclaw":
            models = openclaw_models()
        else:
            models = backend_models(be)
        status = backend_status(be)
        if overrides and bid in overrides:
            status = overrides[bid]
        out.append({
            "id": bid,
            "name": be.get("name", bid),
            "type": be["type"],
            "status": status,
            "controllable": bool(be.get("controllable")),
            "port": be.get("port", ""),
            "models": models,
            "model": be.get("model", ""),
            "settings": be.get("settings", {}),
        })
    return {"type": "backends", "active": active_bid(), "backends": out}


# ============ WebSocket 处理 ============
@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    sid = id(ws)
    print("[WS] accept sid=%s" % sid, flush=True)
    sessions[sid] = Session()
    stt_buf = bytearray()
    stt_active = False
    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            if msg.get("bytes"):
                if stt_active:
                    stt_buf.extend(msg["bytes"])
                continue
            raw = msg.get("text")
            if not raw:
                continue
            try:
                data = json.loads(raw)
            except Exception:
                await ws.send_text(json.dumps(
                    {"type": "error", "message": "JSON 解析失败"}, ensure_ascii=False))
                continue

            mtype = data.get("type", "")

            if mtype == "ping":
                await ws.send_text(json.dumps({"type": "pong"}))

            elif mtype == "list_backends":
                snap = await asyncio.to_thread(build_backends_snapshot)
                await ws.send_text(json.dumps(snap, ensure_ascii=False))

            elif mtype == "set_backend":
                bid = data.get("backend_id", "")
                if bid in cfg["backends"]:
                    cfg["active_backend"] = bid
                    save_config(cfg)
                    await ws.send_text(json.dumps(
                        {"type": "backend_changed", "backend": bid},
                        ensure_ascii=False))
                    snap = await asyncio.to_thread(build_backends_snapshot)
                    await ws.send_text(json.dumps(snap, ensure_ascii=False))
                else:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未知后端: %s" % bid},
                        ensure_ascii=False))

            elif mtype == "set_backend_model":
                bid = data.get("backend_id", "")
                model = data.get("model", "")
                be = cfg["backends"].get(bid)
                if not be:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未知后端: %s" % bid},
                        ensure_ascii=False))
                    continue
                resp = {"type": "settings_ok", "backend_id": bid, "model": model}
                if be["type"] == "openclaw":
                    try:
                        openclaw_set_model(model)
                        resp["message"] = "已写入网关配置，网关重启后生效"
                    except Exception as e:
                        resp["type"] = "error"
                        resp["message"] = "写入 openclaw.json 失败: %s" % e
                else:
                    be["model"] = model
                    save_config(cfg)
                await ws.send_text(json.dumps(resp, ensure_ascii=False))

            elif mtype == "set_backend_setting":
                bid = data.get("backend_id", "")
                key = data.get("key", "")
                value = data.get("value")
                be = cfg["backends"].get(bid)
                if not be:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未知后端: %s" % bid},
                        ensure_ascii=False))
                    continue
                if key not in ("context", "temperature", "max_tokens"):
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "不支持的设置项: %s" % key},
                        ensure_ascii=False))
                    continue
                be.setdefault("settings", {})[key] = value
                save_config(cfg)
                await ws.send_text(json.dumps(
                    {"type": "settings_ok", "backend_id": bid,
                     "key": key, "value": value}, ensure_ascii=False))

            elif mtype == "start_backend":
                bid = data.get("backend_id", "")
                be = cfg["backends"].get(bid)
                if not be:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未知后端: %s" % bid},
                        ensure_ascii=False))
                    continue
                res = await asyncio.to_thread(do_start_backend, bid, be)
                res2 = {"type": "backend_status", "backend_id": bid}
                res2.update(res)
                await ws.send_text(json.dumps(res2, ensure_ascii=False))
                try:
                    snap = await asyncio.to_thread(
                        build_backends_snapshot, {bid: "running"})
                    await ws.send_text(json.dumps(snap, ensure_ascii=False))
                except Exception:
                    pass

            elif mtype == "stop_backend":
                bid = data.get("backend_id", "")
                be = cfg["backends"].get(bid)
                if not be:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未知后端: %s" % bid},
                        ensure_ascii=False))
                    continue
                res = await asyncio.to_thread(do_stop_backend, bid, be)
                res2 = {"type": "backend_status", "backend_id": bid}
                res2.update(res)
                await ws.send_text(json.dumps(res2, ensure_ascii=False))
                try:
                    snap = await asyncio.to_thread(
                        build_backends_snapshot, {bid: "stopped"})
                    await ws.send_text(json.dumps(snap, ensure_ascii=False))
                except Exception:
                    pass

            elif mtype == "lm_list_local":
                models = await asyncio.to_thread(_lms_ls)
                gpu = await asyncio.to_thread(gpu_mem)
                print("[LM] list_local models=%d gpu=%s" % (len(models), gpu))
                await ws.send_text(json.dumps(
                    {"type": "lm_local_models", "models": models, "gpu": gpu},
                    ensure_ascii=False))

            elif mtype == "lm_load":
                model = (data.get("model") or "").strip()
                if not model:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "缺少模型名"},
                        ensure_ascii=False))
                    continue
                gpu = data.get("gpu", "max")
                try:
                    ctx = int(data.get("context", 8192))
                except Exception:
                    ctx = 8192
                loaded = await asyncio.to_thread(_lms_ls)
                for m in loaded:
                    if m.get("loaded") and (m.get("id") or "").strip() != model:
                        await asyncio.to_thread(_lms_unload, m.get("id"))
                res = await asyncio.to_thread(_lms_load, model, gpu, ctx)
                res = {"type": "lm_load_result", "model": model, **res}
                await ws.send_text(json.dumps(res, ensure_ascii=False))

            elif mtype == "lm_unload":
                model = (data.get("model") or "").strip()
                if not model:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "缺少模型名"},
                        ensure_ascii=False))
                    continue
                res = await asyncio.to_thread(_lms_unload, model)
                res = {"type": "lm_unload_result", "model": model, **res}
                await ws.send_text(json.dumps(res, ensure_ascii=False))

            elif mtype == "llama_list_models":
                models = await asyncio.to_thread(scan_llama_models)
                await ws.send_text(json.dumps(
                    {"type": "llama_models", "models": models},
                    ensure_ascii=False))

            elif mtype == "llama_status":
                st = await asyncio.to_thread(llama_status_all)
                await ws.send_text(json.dumps(
                    {"type": "llama_status", "servers": st},
                    ensure_ascii=False))

            elif mtype == "llama_load":
                name = (data.get("model") or "").strip()
                if not name:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "缺少模型名"},
                        ensure_ascii=False))
                    continue
                try:
                    port = int(data.get("port", LLAMA_DEFAULT_PORT))
                    ctx = int(data.get("context", 8192))
                    ngl = int(data.get("gpu_layers", 99))
                    threads = int(data.get("threads", 16))
                except Exception:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "参数错误"},
                        ensure_ascii=False))
                    continue
                ctk = data.get("ctk", "q8_0")
                ctv = data.get("ctv", "q8_0")
                model_path = None
                for m in await asyncio.to_thread(scan_llama_models):
                    if m["name"] == name or m["path"].endswith(name):
                        model_path = m["path"]
                        break
                if not model_path:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "模型库中未找到: %s" % name},
                        ensure_ascii=False))
                    continue
                res = await asyncio.to_thread(
                    llama_start, model_path, port, ctx, ngl, threads, ctk, ctv)
                res = {"type": "llama_load_result", "model": name,
                       "port": port, **res}
                await ws.send_text(json.dumps(res, ensure_ascii=False))

            elif mtype == "llama_unload":
                try:
                    port = int(data.get("port", LLAMA_DEFAULT_PORT))
                except Exception:
                    port = LLAMA_DEFAULT_PORT
                killed = await asyncio.to_thread(llama_stop_port, port)
                await ws.send_text(json.dumps(
                    {"type": "llama_unload_result", "port": port,
                     "killed": killed}, ensure_ascii=False))

            elif mtype == "strata_list_models":
                models = await asyncio.to_thread(scan_strata_models)
                await ws.send_text(json.dumps(
                    {"type": "strata_models", "models": models},
                    ensure_ascii=False))

            elif mtype == "strata_status":
                st = await asyncio.to_thread(strata_status)
                await ws.send_text(json.dumps(
                    {"type": "strata_status", "server": st},
                    ensure_ascii=False))

            elif mtype == "strata_load":
                name = (data.get("model") or "").strip()
                if not name:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "缺少模型名"},
                        ensure_ascii=False))
                    continue
                try:
                    port = int(data.get("port", STRATA_PORT))
                    max_context = int(data.get("max_context", 32768))
                    expert_cache = int(data.get("expert_cache", 0))
                except Exception:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "参数错误"},
                        ensure_ascii=False))
                    continue
                kv = data.get("kv", "int8")
                low_vram = bool(data.get("low_vram", False))
                res = await asyncio.to_thread(
                    strata_start, name, port, max_context, kv, expert_cache, low_vram)
                res = {"type": "strata_load_result", "model": name,
                       "port": port, **res}
                await ws.send_text(json.dumps(res, ensure_ascii=False))

            elif mtype == "strata_unload":
                try:
                    port = int(data.get("port", STRATA_PORT))
                except Exception:
                    port = STRATA_PORT
                killed = await asyncio.to_thread(strata_stop_port, port)
                await ws.send_text(json.dumps(
                    {"type": "strata_unload_result", "port": port,
                     "killed": killed}, ensure_ascii=False))

            elif mtype == "list_models":
                bid, be = active_be()
                if be is None:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未选择后端"},
                        ensure_ascii=False))
                    continue
                ms = await asyncio.to_thread(backend_models, be)
                await ws.send_text(json.dumps(
                    {"type": "models", "models": ms}, ensure_ascii=False))

            elif mtype == "list_voices":
                await ws.send_text(json.dumps(
                    {"type": "voices", "voices": list_voices()},
                    ensure_ascii=False))

            elif mtype == "get_settings":
                bid, be = active_be()
                if be is None:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未选择后端"},
                        ensure_ascii=False))
                    continue
                st = be.get("settings", {})
                cc = cfg.get("context_compress") or {}
                await ws.send_text(json.dumps({
                    "type": "settings",
                    "model": be.get("model", ""),
                    "context": st.get("context", 4096),
                    "temperature": st.get("temperature", 0.7),
                    "max_tokens": st.get("max_tokens", 1024),
                    "tts_ref_audio": cfg.get("tts_ref_audio", ""),
                    "compress_enabled": cc.get("enabled", True),
                    "compress_ratio": cc.get("trigger_ratio", 0.7),
                    "compress_batch": cc.get("batch_messages", 10),
                }, ensure_ascii=False))

            elif mtype == "set_model":
                bid, be = active_be()
                if be is None:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未选择后端"},
                        ensure_ascii=False))
                    continue
                m = (data.get("model") or "").strip()
                if m:
                    be["model"] = m
                    save_config(cfg)
                await ws.send_text(json.dumps(
                    {"type": "settings_ok", "model": be.get("model", "")},
                    ensure_ascii=False))

            elif mtype == "set_context":
                bid, be = active_be()
                if be is None:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未选择后端"},
                        ensure_ascii=False))
                    continue
                try:
                    ctx = int(data.get("context", 4096))
                    ctx = max(256, min(ctx, 131072))
                    be.setdefault("settings", {})["context"] = ctx
                    save_config(cfg)
                except Exception:
                    pass
                await ws.send_text(json.dumps(
                    {"type": "settings_ok",
                     "context": be.get("settings", {}).get("context", 4096)},
                    ensure_ascii=False))

            elif mtype == "set_voice":
                voice = (data.get("voice") or "").strip()
                if voice:
                    cfg["tts_ref_audio"] = voice
                    save_config(cfg)
                await ws.send_text(json.dumps(
                    {"type": "settings_ok", "voice": cfg.get("tts_ref_audio", "")},
                    ensure_ascii=False))

            elif mtype == "save_settings":
                bid, be = active_be()
                if be is None:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "未选择后端"},
                        ensure_ascii=False))
                    continue
                m = (data.get("model") or "").strip()
                if m:
                    be["model"] = m
                try:
                    ctx = int(data.get("context",
                                       be.get("settings", {}).get("context", 4096)))
                    be.setdefault("settings", {})["context"] = max(256, min(ctx, 131072))
                except Exception:
                    pass
                v = (data.get("voice") or "").strip()
                if v:
                    cfg["tts_ref_audio"] = v
                cc = cfg.setdefault("context_compress", {})
                cc.setdefault("enabled", True)
                cc.setdefault("trigger_ratio", 0.7)
                cc.setdefault("batch_messages", 10)
                if "compress_enabled" in data:
                    cc["enabled"] = bool(data.get("compress_enabled"))
                try:
                    if "compress_ratio" in data:
                        r = float(data.get("compress_ratio"))
                        cc["trigger_ratio"] = max(0.3, min(0.95, r))
                except Exception:
                    pass
                try:
                    if "compress_batch" in data:
                        cc["batch_messages"] = max(4, min(50, int(data.get("compress_batch"))))
                except Exception:
                    pass
                save_config(cfg)
                await ws.send_text(json.dumps({
                    "type": "settings_saved",
                    "model": be.get("model", ""),
                    "context": be.get("settings", {}).get("context", 4096),
                    "voice": cfg.get("tts_ref_audio", ""),
                }, ensure_ascii=False))

            elif mtype == "sync_history":
                conv_id = (data.get("conversation_id") or "").strip() or "default"
                bid, _be = pick_be(data)
                s = sessions[sid]
                hist = s.hist(conv_id, bid)
                hist.clear()
                for m in (data.get("messages") or []):
                    if not isinstance(m, dict):
                        continue
                    role = m.get("role")
                    content = m.get("content")
                    if role in ("user", "assistant") and isinstance(content, str) and content:
                        hist.append({"role": role, "content": content})
                _save_hist()
                await ws.send_text(json.dumps({
                    "type": "history_synced", "len": len(hist),
                    "conversation_id": conv_id, "backend_id": bid},
                    ensure_ascii=False))

            elif mtype == "delete_conversation":
                conv_id = (data.get("conversation_id") or "").strip()
                if conv_id:
                    prefix = "%s::" % conv_id
                    gone = [k for k in GLOBAL_HIST if k.startswith(prefix)]
                    for k in gone:
                        GLOBAL_HIST.pop(k, None)
                    if gone:
                        _save_hist()
                await ws.send_text(json.dumps(
                    {"type": "conversation_deleted",
                     "conversation_id": conv_id}, ensure_ascii=False))

            elif mtype == "clear_history":
                conv_id = (data.get("conversation_id") or "").strip() or "default"
                bid, _be = pick_be(data)
                s = sessions[sid]
                s.hist(conv_id, bid).clear()
                _save_hist()
                await ws.send_text(json.dumps({"type": "history_cleared"}))

            elif mtype == "truncate_history":
                conv_id = (data.get("conversation_id") or "").strip() or "default"
                bid, _be = pick_be(data)
                try:
                    keep_ns = int(data.get("keep", 0))
                except Exception:
                    keep_ns = 0
                s = sessions[sid]
                hist = s.hist(conv_id, bid)
                if keep_ns <= 0:
                    hist.clear()
                else:
                    npos = ns_positions(hist)
                    drop_at = (npos[keep_ns - 1] + 1
                               if keep_ns <= len(npos) else len(hist))
                    del hist[drop_at:]
                _save_hist()
                await ws.send_text(json.dumps(
                    {"type": "history_truncated", "keep": len(hist)}))

            elif mtype == "compress_context":
                conv_id = (data.get("conversation_id") or "").strip() or "default"
                bid, be = pick_be(data)
                s = sessions[sid]
                hist = s.hist(conv_id, bid)
                be_ctx = be.get("settings", {}).get("context") or cfg.get(
                    "context_length", 4096)
                n, ns_removed = await asyncio.to_thread(
                    _maybe_compress, be, hist, int(be_ctx))
                _save_hist()
                await ws.send_text(json.dumps({
                    "type": "context_compressed",
                    "rounds": n,
                    "ns_removed": ns_removed,
                    "remaining": len(hist),
                    "conversation_id": conv_id}, ensure_ascii=False))

            elif mtype == "delete_message":
                conv_id = (data.get("conversation_id") or "").strip() or "default"
                bid, _be = pick_be(data)
                try:
                    ns_idx = int(data.get("index", -1))
                except Exception:
                    ns_idx = -1
                s = sessions[sid]
                hist = s.hist(conv_id, bid)
                npos = ns_positions(hist)
                if 0 <= ns_idx < len(npos):
                    del hist[npos[ns_idx]]
                _save_hist()
                await ws.send_text(json.dumps(
                    {"type": "history_updated", "len": len(hist)}))

            elif mtype == "regenerate":
                await handle_regenerate(ws, sid, data)

            elif mtype == "tts_speak":
                text = (data.get("text") or "").strip()
                if text:
                    await send_voice(ws, text, True)
                else:
                    await ws.send_text(json.dumps(
                        {"type": "error", "message": "无文本可播报"},
                        ensure_ascii=False))

            elif mtype == "stt_start":
                stt_buf.clear()
                stt_active = True
                await ws.send_text(json.dumps({"type": "stt_ack"}))

            elif mtype == "stt_end":
                stt_active = False
                audio = bytes(stt_buf)
                stt_buf.clear()
                await handle_stt(ws, audio)

            elif mtype == "chat":
                print("[WS] chat sid=%s msg=%s" % (sid, str(data)[:120]), flush=True)
                await handle_chat(ws, sid, data)

            elif mtype == "agent":
                await handle_agent(ws, sid, data)

            else:
                await ws.send_text(json.dumps(
                    {"type": "error", "message": "未知消息类型: " + str(mtype)},
                    ensure_ascii=False))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await ws.send_text(json.dumps(
                {"type": "error", "message": "服务异常: " + str(e)}, ensure_ascii=False))
        except Exception:
            pass
    finally:
        sessions.pop(sid, None)


async def send_voice(ws, reply, want_voice):
    if not want_voice:
        return
    try:
        resp = await asyncio.to_thread(tts_synthesize, reply)
        await ws.send_text(json.dumps(
            {"type": "audio_start", "format": cfg.get("tts_media_type", "wav")},
            ensure_ascii=False))
        for chunk in resp.iter_content(8192):
            if not chunk:
                continue
            await ws.send_bytes(chunk)
        await ws.send_text(json.dumps({"type": "audio_end"}))
    except Exception as e:
        await ws.send_text(json.dumps(
            {"type": "error", "message": "TTS 失败: %s" % e}, ensure_ascii=False))


def _text_payload(reply, bid, be, conv_id=""):
    return json.dumps({
        "type": "text",
        "text": reply["text"],
        "reasoning": reply.get("reasoning", ""),
        "usage": reply.get("usage", {}),
        "duration_ms": reply.get("duration_ms", 0),
        "chars": reply.get("chars", 0),
        "model": be.get("model", ""),
        "backend": bid,
        "conversation_id": conv_id,
    }, ensure_ascii=False)


async def _stream_to_ws(ws, sid, conv_id, bid, be, hist, want_voice):
    q = queue.Queue()

    def _produce():
        for attempt in range(2):
            try:
                for evt, payload in stream_backend(be, hist, sid):
                    q.put((evt, payload))
                break
            except (requests.exceptions.ConnectionError,
                    requests.exceptions.Timeout,
                    requests.exceptions.ReadTimeout) as e:
                if attempt == 0:
                    time.sleep(1)
                    continue
                q.put(("error", str(e)))
                return
            except Exception as e:
                q.put(("error", str(e)))
                return
        q.put((None, None))

    threading.Thread(target=_produce, daemon=True).start()
    reply = None
    while True:
        evt, payload = await asyncio.to_thread(q.get)
        if evt is None:
            break
        if evt == "error":
            await ws.send_text(json.dumps(
                {"type": "error", "message": "模型调用失败: %s" % payload,
                 "conversation_id": conv_id, "backend_id": bid,
                 "recoverable": True}, ensure_ascii=False))
            return None
        if evt == "delta":
            await ws.send_text(json.dumps({
                "type": "text_delta", "delta": payload,
                "conversation_id": conv_id}, ensure_ascii=False))
        elif evt == "reasoning":
            await ws.send_text(json.dumps({
                "type": "reasoning_delta", "delta": payload,
                "conversation_id": conv_id}, ensure_ascii=False))
        elif evt == "done":
            reply = payload
            await ws.send_text(_text_payload(reply, bid, be, conv_id))
            await send_voice(ws, reply["text"], want_voice)
    return reply


async def handle_chat(ws, sid, data):
    text = (data.get("text") or "").strip()
    attachments = data.get("attachments") or []
    want_voice = data.get("voice", True)
    conv_id = (data.get("conversation_id") or "").strip() or "default"
    if not text and not attachments:
        await ws.send_text(json.dumps(
            {"type": "error", "message": "空消息"}, ensure_ascii=False))
        return
    bid, be = pick_be(data)
    if be is None:
        await ws.send_text(json.dumps(
            {"type": "error", "message": "请先在设置中选择对话后端"},
            ensure_ascii=False))
        return
    if be.get("controllable") and backend_status(be) != "running":
        await ws.send_text(json.dumps({
            "type": "error",
            "message": "后端「%s」未运行/未加载，请先在对应管理器加载模型后再聊"
                       % be.get("name", bid),
        }, ensure_ascii=False))
        return
    s = sessions[sid]
    hist = s.hist(conv_id, bid)
    if data.get("resend") and hist and hist[-1]["role"] == "user":
        hist.pop()
    hist.append({"role": "user",
                 "content": build_user_content(text, attachments)})
    be_ctx = be.get("settings", {}).get("context") or cfg.get("context_length", 4096)
    n_compressed, ns_removed = await asyncio.to_thread(
        _maybe_compress, be, hist, int(be_ctx))
    if n_compressed:
        await ws.send_text(json.dumps({
            "type": "context_compressed",
            "rounds": n_compressed,
            "ns_removed": ns_removed,
            "remaining": len(hist),
            "conversation_id": conv_id}, ensure_ascii=False))
    hmax = cfg.get("history_max", 20) * 2
    try:
        reply = await _stream_to_ws(ws, sid, conv_id, bid, be, hist[-hmax:], want_voice)
    except Exception as e:
        _save_hist()
        print("[WS] chat 异常 sid=%s: %s" % (sid, e), flush=True)
        return
    if reply is None:
        _save_hist()
        return
    hist.append({"role": "assistant", "content": reply["text"]})
    _save_hist()


async def handle_regenerate(ws, sid, data):
    want_voice = data.get("voice", True)
    conv_id = (data.get("conversation_id") or "").strip() or "default"
    bid, be = pick_be(data)
    if be is None:
        await ws.send_text(json.dumps(
            {"type": "error", "message": "请先在设置中选择对话后端"},
            ensure_ascii=False))
        return
    if be.get("controllable") and backend_status(be) != "running":
        await ws.send_text(json.dumps({
            "type": "error",
            "message": "后端「%s」未运行/未加载，请先在对应管理器加载模型后再聊"
                       % be.get("name", bid),
        }, ensure_ascii=False))
        return
    s = sessions[sid]
    hist = s.hist(conv_id, bid)
    if hist and hist[-1]["role"] == "assistant":
        hist.pop()
    user_msgs = [m for m in hist if m["role"] == "user"]
    if not user_msgs:
        await ws.send_text(json.dumps(
            {"type": "error", "message": "没有可重新回答的消息",
             "conversation_id": conv_id, "backend_id": bid},
            ensure_ascii=False))
        return
    hmax = cfg.get("history_max", 20) * 2
    try:
        if be["type"] == "openai":
            reply = await _stream_to_ws(ws, sid, conv_id, bid, be, hist[-hmax:], want_voice)
        else:
            reply = await _stream_to_ws(
                ws, sid, conv_id, bid, be,
                [{"role": "user", "content": user_msgs[-1]["content"]}], want_voice)
    except Exception as e:
        print("[WS] regenerate 异常 sid=%s: %s" % (sid, e), flush=True)
        return
    if reply is None:
        _save_hist()
        return
    hist.append({"role": "assistant", "content": reply["text"]})
    _save_hist()


async def handle_agent(ws, sid, data):
    task = (data.get("task") or "").strip()
    await ws.send_text(json.dumps({
        "type": "agent_result",
        "status": "not_implemented",
        "task": task,
        "message": "Agent 能力将在二期接入 OpenClaw / QwenPaw",
    }, ensure_ascii=False))


@app.get("/health")
def health():
    return JSONResponse({
        "status": "ok",
        "active_backend": cfg.get("active_backend"),
        "tts_url": cfg.get("tts_url"),
    })


@app.get("/")
def index():
    return {"name": "LocalAI Bridge", "docs": "/docs", "health": "/health"}


if __name__ == "__main__":
    import uvicorn
    _init_hist()
    print("LocalAI Bridge 启动中... 端口 %s" % cfg["port"])
    def _warm_whisper():
        try:
            get_whisper()
            print("Whisper STT 模型已预热")
        except Exception as e:
            print("Whisper 预热失败(不影响服务): %s" % e)
    threading.Thread(target=_warm_whisper, daemon=True).start()
    uvicorn.run(app, host=cfg["host"], port=cfg["port"], log_level="info",
                ws_ping_interval=None, ws_ping_timeout=None)
