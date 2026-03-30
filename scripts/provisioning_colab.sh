#!/bin/bash
# --- AI-Dock & Colab Adaptive Provisioning Script (v1.2) ---

# 1. 核心环境检测与自适应
if [ -f "/opt/ai-dock/bin/venv-set.sh" ]; then
    echo "--- [ENV] AI-Dock Environment Detected ---"
    source /opt/ai-dock/bin/venv-set.sh comfyui
    VENV_PYTHON="/opt/environments/python/comfyui/bin/python3"
else
    echo "--- [ENV] Standard/Colab Environment Detected ---"
    VENV_PYTHON="python3"
    # 如果在 Colab 等环境，需要手动补齐目录和基础库
    if [ ! -d "/opt/ComfyUI" ]; then
        echo "--- [INIT] Cloning ComfyUI Source ---"
        git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI
        $VENV_PYTHON -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
        $VENV_PYTHON -m pip install -r /opt/ComfyUI/requirements.txt
    fi
    # 确保 Python 业务逻辑运行所需的库
    $VENV_PYTHON -m pip install PyYAML requests
fi

function provisioning_start() {
    echo "--- [START] Provisioning Sequence ---"
    provisioning_sync_github
    provisioning_run_manifest_logic
    echo "--- [END] Provisioning Sequence Finished ---"
}

function provisioning_sync_github() {
    echo "--- [SYNC] Downloading Manifest & Workflows ---"
    
    # 同步 Manifest 配置文件
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > /opt/manifest.yaml
    fi

    # 健壮同步私有工作流仓库 (支持 GH_TOKEN)
    if [ ! -z "$WORKFLOWS_REPO" ]; then
        if [ -d "/opt/workflows/.git" ]; then
            echo "--- [GIT] Pulling latest workflows ---"
            cd /opt/workflows && git pull
        else
            echo "--- [GIT] Cloning private workflows ---"
            REPO_URL_CLEAN=$(echo "$WORKFLOWS_REPO" | sed 's|https://||')
            if [ ! -z "$GH_TOKEN" ]; then
                git clone "https://${GH_TOKEN}@${REPO_URL_CLEAN}" /opt/workflows
            else
                git clone "$WORKFLOWS_REPO" /opt/workflows
            fi
        fi
    fi
}

function provisioning_run_manifest_logic() {
    echo "--- [JSON] Running Dynamic Asset Installer ---"
    
    # 传递给 Python 部分的环境变量检测
    $VENV_PYTHON - <<EOF
import yaml, os, subprocess

def run(cmd):
    print(f"Executing: {cmd}")
    # 强制让内部调用也使用正确的 pip
    if cmd.startswith("pip"):
        cmd = f"$VENV_PYTHON -m {cmd}"
    # subprocess.run doesn't throw by default unless check=True
    result = subprocess.run(cmd, shell=True)
    return result.returncode

manifest_path = "/opt/manifest.yaml"
if not os.path.exists(manifest_path):
    print("Manifest not found, skipping asset loading.")
    exit(0)

with open(manifest_path, 'r') as f:
    manifest = yaml.safe_load(f)

scene_name = os.environ.get('SCENE', 'default')
scene = manifest.get('scenes', {}).get(scene_name, {})

if not scene:
    print(f"Scene '{scene_name}' not defined in manifest.")
    exit(0)

# 1. 自动安装插件节点 (Node Setup)
for node in scene.get('nodes', []):
    try:
        name = node.split("/")[-1].replace(".git", "")
        path = f"/opt/ComfyUI/custom_nodes/{name}"
        if not os.path.exists(path):
            ret = run(f"git clone {node} {path}")
            if ret == 0 and os.path.exists(f"{path}/requirements.txt"):
                run(f"pip install --no-cache-dir -r {path}/requirements.txt")
    except Exception as e:
        print(f"Unexpected error for node {node}: {e}, skipping.")

# 2. 自动下载模型 (Model Setup)
# 整合优先级: 环境变量 > 清单定义
hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in scene.get('models', []):
    try:
        url = model.get('url')
        name = model.get('name')
        dest_dir = f"/opt/ComfyUI/{model['path']}"
        os.makedirs(dest_dir, exist_ok=True)
        
        if not os.path.exists(f"{dest_dir}/{name}"):
            # 使用 aria2c 极速下载 (Colab 和 AI-Dock 均已在最外层脚本安装)
            cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
            ret = run(cmd)
            if ret != 0:
                print(f"⚠️ Failed to download {name} (Return code: {ret}). Continuing...")
    except Exception as e:
        print(f"❌ Unexpected error processing model {model.get('name')}: {e}. Skipping...")

# 3. 同步工作流 (Workflow Sync)
workflow_repo_path = "/opt/workflows"
if os.path.exists(workflow_repo_path):
    dest = "/opt/ComfyUI/user/default/workflows"
    os.makedirs(dest, exist_ok=True)
    # 优先查找 workflows 子目录
    src = f"{workflow_repo_path}/workflows" if os.path.exists(f"{workflow_repo_path}/workflows") else workflow_repo_path
    print(f"--- [SYNC] Syncing workflows from {src} to {dest} ---")
    run(f"cp -v {src}/*.json {dest}/ 2>/dev/null || true")
EOF
}

# 执行主流程
provisioning_start
