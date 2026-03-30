#!/bin/bash
# --- AI-Dock 2.0+ Provisioning Script (Hardened Version v1.2) ---
# Optimized for: ghcr.io/ai-dock/comfyui:latest-cuda

# 环境变量增强：确保 Python 路径绝对正确
VENV_PYTHON="/opt/environments/python/comfyui/bin/python3"

function provisioning_start() {
    echo "--- ComfyUI Commander Boot Sequence ---"
    
    # 0. 核心插件安装：ComfyUI-Manager
    # provisioning_install_manager

    # 1. 核心依赖检查：若无 aria2c 则自动安装 (解决 /bin/sh: 1: aria2c: not found)
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

function provisioning_install_manager() {
    if [ ! -d "/opt/ComfyUI/custom_nodes/ComfyUI-Manager" ]; then
        echo "--- [INIT] Installing ComfyUI-Manager ---"
        git clone https://github.com/ltdrdata/ComfyUI-Manager /opt/ComfyUI/custom_nodes/ComfyUI-Manager
    fi
    # 强制每次运行都校验核心插件依赖 (Ensure requirements always installed)
    $VENV_PYTHON -m pip install --no-cache-dir -r /opt/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt
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
    
    # 使用引号保护的 EOF 阻止 Shell 展开，强制使用 sys.executable 确保 100% 环境一致
    $VENV_PYTHON - <<'EOF'
import yaml, os, subprocess, sys

def run(cmd):
    print(f"Executing: {cmd}")
    if cmd.startswith("pip"):
        # 使用当前运行脚本的 Python 解释器 (sys.executable)
        cmd = f"\"{sys.executable}\" -m {cmd}"
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

# 1. 资源合并 (Asset Merging)
global_nodes = manifest.get('global', {}).get('nodes', [])
global_models = manifest.get('global', {}).get('models', [])
scene_nodes = scene.get('nodes', []) if scene else []
scene_models = scene.get('models', []) if scene else []

all_nodes = (global_nodes or []) + (scene_nodes or [])
all_models = (global_models or []) + (scene_models or [])

# 2. 自动处理节点插件 (Node Setup)
for node in all_nodes:
    try:
        url, version = "", "main"
        if isinstance(node, str): url = node
        elif isinstance(node, dict):
            url = node.get('url')
            version = node.get('version', 'main')
            
        if url and url.startswith("http"):
            name = url.split("/")[-1].replace(".git", "")
            path = f"/opt/ComfyUI/custom_nodes/{name}"
            if not os.path.exists(path):
                run(f"git clone -b {version} {url} {path}")
            
            # 无论是否已克隆，都强制校验依赖 (Ensure deps are checked every time)
            if os.path.exists(f"{path}/requirements.txt"):
                run(f"pip install --no-cache-dir -r {path}/requirements.txt")
    except Exception as e:
        print(f"Unexpected error for node {node}: {e}")

# 3. 自动下载模型 (Model Setup)
hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in all_models:
    try:
        url, name = model.get('url'), model.get('name')
        dest_dir = f"/opt/ComfyUI/{model['path']}"
        os.makedirs(dest_dir, exist_ok=True)
        if not os.path.exists(f"{dest_dir}/{name}"):
            cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
            run(cmd)
    except Exception as e:
        print(f"❌ Error processing model {model.get('name', 'unknown')}: {e}")

# 4. 同步工作流 (Workflow Sync)
workflow_repo_path = "/opt/workflows"
if os.path.exists(workflow_repo_path):
    dest = "/opt/ComfyUI/user/default/workflows"
    os.makedirs(dest, exist_ok=True)
    src = f"{workflow_repo_path}/workflows" if os.path.exists(f"{workflow_repo_path}/workflows") else workflow_repo_path
    print(f"--- [SYNC] Syncing workflows from {src} to {dest} ---")
    run(f"cp -v {src}/*.json {dest}/ 2>/dev/null || true")

# 5. 最终路径审计 (Final Path Audit)
print("\n--- [AUDIT] Custom Nodes Contents ---")
if os.path.exists("/opt/ComfyUI/custom_nodes"):
    print(os.listdir("/opt/ComfyUI/custom_nodes"))
else:
    print("WARNING: /opt/ComfyUI/custom_nodes NOT FOUND")
EOF
}

# 执行主流程
provisioning_start
