#!/bin/bash
# --- AI-Dock 2.0+ Provisioning Script (Production Version v1.1) ---
# Optimized for: ghcr.io/ai-dock/comfyui:latest-cuda

# 环境变量增强：确保 Python 路径绝对正确
VENV_PYTHON="/opt/environments/python/comfyui/bin/python3"

function provisioning_start() {
    echo "--- ComfyUI Commander Boot Sequence ---"
    
    # 0. 核心依赖检查：若无 aria2c 则自动安装 (解决 /bin/sh: 1: aria2c: not found)
    if ! command -v aria2c &> /dev/null; then
        echo "Aria2c not found. Installing for high-speed downloads..."
        apt-get update && apt-get install -y aria2
    fi

    # 1. 激活虚拟环境
    source /opt/ai-dock/bin/venv-set.sh comfyui
    
    # 2. 同步云端资源
    provisioning_sync_github
    
    # 3. 动态加载资源
    provisioning_run_manifest_logic
    
    echo "--- Provisioning Sequence Finished ---"
}

function provisioning_sync_github() {
    echo "--- Step 1: Syncing Logic & Workflows ---"
    
    # 获取 manifest.yaml
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > /opt/manifest.yaml
    fi

    # 智能同步工作流：若已存在则拉取更新，不存在则克隆
    if [ ! -z "$WORKFLOWS_REPO" ]; then
        if [ -d "/opt/workflows/.git" ]; then
            echo "Workflows directory exists, pulling updates..."
            cd /opt/workflows && git pull
        else
            echo "Cloning workflows repository..."
            if [ ! -z "$GH_TOKEN" ]; then
                CLEAN_URL=$(echo $WORKFLOWS_REPO | sed 's/https:\/\///')
                git clone "https://${GH_TOKEN}@${CLEAN_URL}" /opt/workflows
            else
                git clone "$WORKFLOWS_REPO" /opt/workflows
            fi
        fi
    fi
}

function provisioning_run_manifest_logic() {
    echo "--- Step 2: Processing Manifest ---"
    
    $VENV_PYTHON - <<EOF
import yaml, os, subprocess

def run(cmd):
    print(f"Executing: {cmd}")
    if cmd.startswith("pip"):
        cmd = f"$VENV_PYTHON -m {cmd}"
    subprocess.run(cmd, shell=True)

manifest_path = "/opt/manifest.yaml"
if not os.path.exists(manifest_path):
    print("Manifest not found, skipping asset logic.")
    exit(0)

with open(manifest_path, 'r') as f:
    manifest = yaml.safe_load(f)

scene_name = os.environ.get('SCENE', 'default')
scene = manifest.get('scenes', {}).get(scene_name)

if not scene:
    print(f"Scene '{scene_name}' not found.")
    exit(0)

# 自动处理节点插件
for node in scene.get('nodes', []):
    if node.startswith("http"):
        name = node.split("/")[-1].replace(".git", "")
        path = f"/opt/ComfyUI/custom_nodes/{name}"
        if not os.path.exists(path):
            run(f"git clone {node} {path}")
            if os.path.exists(f"{path}/requirements.txt"):
                run(f"pip install --no-cache-dir -r {path}/requirements.txt")

# 自动处理模型下载 (使用已安装的 aria2c)
hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in scene.get('models', []):
    url = model.get('url')
    rel_path = model.get('path')
    name = model.get('name')
    dest_dir = f"/opt/ComfyUI/{rel_path}"
    os.makedirs(dest_dir, exist_ok=True)
    
    if not os.path.exists(f"{dest_dir}/{name}"):
        cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
        run(cmd)
EOF
}

# 终极启动
provisioning_start
