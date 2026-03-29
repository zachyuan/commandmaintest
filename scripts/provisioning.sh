#!/bin/bash
# --- AI-Dock 2.0+ Provisioning Script (Final Production Version) ---
# Optimized for: ghcr.io/ai-dock/comfyui:latest-cuda

# 定义虚拟环境 Python 绝对路径，确保环境一致性
VENV_PYTHON="/opt/environments/python/comfyui/bin/python3"

function provisioning_start() {
    echo "--- ComfyUI Commander Boot Sequence ---"
    
    # 1. 强制激活 ComfyUI 专用虚拟环境
    source /opt/ai-dock/bin/venv-set.sh comfyui
    
    # 2. 同步 GitHub 上的 Manifest 和私有工作流
    provisioning_sync_github
    
    # 3. 执行 Manifest 核心逻辑 (下载模型与更新节点)
    provisioning_run_manifest_logic
    
    echo "--- Provisioning Sequence Finished ---"
}

function provisioning_sync_github() {
    echo "--- Step 1: Syncing Logic & Workflows ---"
    
    # 下载 Manifest
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > /opt/manifest.yaml
    fi

    # 安全拉取私有工作流仓库
    if [ ! -z "$WORKFLOWS_REPO" ]; then
        if [ ! -z "$GH_TOKEN" ]; then
            # 使用 Token 授权拉取
            CLEAN_URL=$(echo $WORKFLOWS_REPO | sed 's/https:\/\///')
            git clone "https://${GH_TOKEN}@${CLEAN_URL}" /opt/workflows
        else
            # 公开拉取
            git clone "$WORKFLOWS_REPO" /opt/workflows
        fi
    fi
}

function provisioning_run_manifest_logic() {
    echo "--- Step 2: Processing Manifest ---"
    
    # 使用绝对路径 Python 确保 PyYAML 等库可见
    $VENV_PYTHON - <<EOF
import yaml, os, subprocess

def run(cmd):
    print(f"Executing: {cmd}")
    # 确保 pip 命令也使用虚拟环境的版本
    if cmd.startswith("pip"):
        cmd = f"$VENV_PYTHON -m {cmd}"
    subprocess.run(cmd, shell=True)

manifest_path = "/opt/manifest.yaml"
if not os.path.exists(manifest_path):
    print("Manifest not found, skipping dynamic asset download.")
    exit(0)

with open(manifest_path, 'r') as f:
    manifest = yaml.safe_load(f)

scene_name = os.environ.get('SCENE', 'default')
scene = manifest.get('scenes', {}).get(scene_name)

if not scene:
    print(f"Scene '{scene_name}' not found in manifest.")
    exit(0)

# --- 自动安装插件节点 ---
for node in scene.get('nodes', []):
    if node.startswith("http"):
        name = node.split("/")[-1].replace(".git", "")
        # 对齐 AI-Dock 标准路径
        path = f"/opt/ComfyUI/custom_nodes/{name}"
        if not os.path.exists(path):
            run(f"git clone {node} {path}")
            if os.path.exists(f"{path}/requirements.txt"):
                run(f"pip install --no-cache-dir -r {path}/requirements.txt")

# --- 极速并行下载模型 ---
hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in scene.get('models', []):
    url = model.get('url')
    rel_path = model.get('path')
    name = model.get('name')
    dest_dir = f"/opt/ComfyUI/{rel_path}"
    os.makedirs(dest_dir, exist_ok=True)
    
    if not os.path.exists(f"{dest_dir}/{name}"):
        # 使用 aria2c 16 线程火力全开
        cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
        run(cmd)
EOF
}

# 启动脚本
provisioning_start
