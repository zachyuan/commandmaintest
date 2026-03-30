#!/bin/bash
# --- AI-Dock 2.0+ Provisioning Script (Production Version v1.1) ---
# Optimized for: ghcr.io/ai-dock/comfyui:latest-cuda

VENV_PYTHON="/opt/environments/python/comfyui/bin/python3"

function provisioning_start() {
    echo "--- ComfyUI Commander Boot Sequence ---"
    
    if ! command -v aria2c &> /dev/null; then
        echo "Aria2c not found. Installing for high-speed downloads..."
        # apt-get update && apt-get install -y aria2
        apt-get install -y aria2
    fi

    source /opt/ai-dock/bin/venv-set.sh comfyui
    
    provisioning_sync_github
    
    provisioning_run_manifest_logic
    
    echo "--- Provisioning Sequence Finished ---"
}

function provisioning_sync_github() {
    echo "--- Step 1: Syncing Logic & Workflows ---"
    
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > /opt/manifest.yaml
    fi

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
    # subprocess.run doesn't throw by default unless check=True
    # We explicitly check returncode if we want to log errors
    result = subprocess.run(cmd, shell=True)
    return result.returncode

manifest_path = "/opt/manifest.yaml"
if not os.path.exists(manifest_path):
    print("Manifest not found, skipping asset logic.")
    exit(0)

with open(manifest_path, 'r') as f:
    manifest = yaml.safe_load(f)

scene_name = os.environ.get('SCENE', 'default')
scene = manifest.get('scenes', {}).get(scene_name)

if not scene and scene_name != 'default':
    print(f"Scene '{scene_name}' not found.")
    exit(0)

# 1. 资源合并 (Asset Merging)
# 获取全局共享资源
global_nodes = manifest.get('global', {}).get('nodes', [])
global_models = manifest.get('global', {}).get('models', [])

# 获取场景特定资源
scene_nodes = scene.get('nodes', []) if scene else []
scene_models = scene.get('models', []) if scene else []

# 合并列表
all_nodes = global_nodes + scene_nodes
all_models = global_models + scene_models

# 2. 自动处理节点插件 (Node Setup)
for node in all_nodes:
    try:
        url = ""
        version = "main"
        if isinstance(node, str):
            url = node
        elif isinstance(node, dict):
            url = node.get('url')
            version = node.get('version', 'main')
            
        if url and url.startswith("http"):
            name = url.split("/")[-1].replace(".git", "")
            path = f"/opt/ComfyUI/custom_nodes/{name}"
            if not os.path.exists(path):
                # 使用 -b 指定分支或标签
                ret = run(f"git clone -b {version} {url} {path}")
                if ret == 0 and os.path.exists(f"{path}/requirements.txt"):
                    run(f"pip install --no-cache-dir -r {path}/requirements.txt")
    except Exception as e:
        print(f"Unexpected error for node {node}: {e}, skipping.")

hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in all_models:
    try:
        url = model.get('url')
        rel_path = model.get('path')
        name = model.get('name')
        dest_dir = f"/opt/ComfyUI/{rel_path}"
        os.makedirs(dest_dir, exist_ok=True)
        
        if not os.path.exists(f"{dest_dir}/{name}"):
            cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
            ret = run(cmd)
            if ret != 0:
                 print(f"⚠️ Failed to download {name} (Return code: {ret}). Continuing...")
    except Exception as e:
        print(f"❌ Unexpected error processing model {model.get('name', 'unknown')}: {e}. Skipping...")

# 3. 同步工作流 (Workflow Sync)
# 将 cloned 的 workflows 拷贝到 ComfyUI 内部目录，解决 UI 中工作流为空的问题
workflow_repo_path = "/opt/workflows"
if os.path.exists(workflow_repo_path):
    dest = "/opt/ComfyUI/user/default/workflows"
    os.makedirs(dest, exist_ok=True)
    # 尝试查找 workflows 子目录，若无则使用仓库根目录
    src = f"{workflow_repo_path}/workflows" if os.path.exists(f"{workflow_repo_path}/workflows") else workflow_repo_path
    print(f"--- [SYNC] Syncing workflows from {src} to {dest} ---")
    # 使用 cp 命令批量拷贝
    run(f"cp -v {src}/*.json {dest}/ 2>/dev/null || true")
EOF
}

provisioning_start
