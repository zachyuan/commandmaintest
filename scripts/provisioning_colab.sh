#!/bin/bash
# --- AI-Dock & Colab Adaptive Provisioning Script ---

# 1. 环境检测与自适应
if [ -f "/opt/ai-dock/bin/venv-set.sh" ]; then
    echo "--- Detecting AI-Dock Environment ---"
    source /opt/ai-dock/bin/venv-set.sh comfyui
    VENV_PYTHON="/opt/environments/python/comfyui/bin/python3"
else
    echo "--- Detecting Standard Ubuntu/Colab Environment ---"
    VENV_PYTHON="python3"
    # 如果 Colab 缺少 ComfyUI 源码，则手动克隆
    if [ ! -d "/opt/ComfyUI" ]; then
        git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI
        $VENV_PYTHON -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
        $VENV_PYTHON -m pip install -r /opt/ComfyUI/requirements.txt
    fi
    # 确保有 PyYAML
    $VENV_PYTHON -m pip install PyYAML requests
fi

function provisioning_start() {
    echo "--- Starting Provisioning Logic ---"
    provisioning_sync_github
    provisioning_run_manifest_logic
    echo "--- Provisioning Sequence Finished ---"
}

function provisioning_sync_github() {
    # 同步 Manifest
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > /opt/manifest.yaml
    fi

    # 修复 Token 克隆逻辑：确保使用正确格式
    if [ ! -z "$WORKFLOWS_REPO" ]; then
        if [ -d "/opt/workflows/.git" ]; then
            cd /opt/workflows && git pull
        else
            # 这里的 URL 处理更健壮
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
    # 这里的 $VENV_PYTHON 已经被前面的环境检测自动修正了
    $VENV_PYTHON - <<EOF
import yaml, os, subprocess

def run(cmd):
    print(f"Executing: {cmd}")
    if cmd.startswith("pip"):
        cmd = f"$VENV_PYTHON -m {cmd}"
    subprocess.run(cmd, shell=True)

manifest_path = "/opt/manifest.yaml"
if os.path.exists(manifest_path):
    with open(manifest_path, 'r') as f:
        manifest = yaml.safe_load(f)
    
    scene_name = os.environ.get('SCENE', 'default')
    scene = manifest.get('scenes', {}).get(scene_name, {})
    
    # 安装插件
    for node in scene.get('nodes', []):
        name = node.split("/")[-1].replace(".git", "")
        path = f"/opt/ComfyUI/custom_nodes/{name}"
        if not os.path.exists(path):
            run(f"git clone {node} {path}")
            if os.path.exists(f"{path}/requirements.txt"):
                run(f"pip install --no-cache-dir -r {path}/requirements.txt")
    
    # 下载模型
    hf_token = os.environ.get('HF_TOKEN', '')
    header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''
    for model in scene.get('models', []):
        dest_dir = f"/opt/ComfyUI/{model['path']}"
        os.makedirs(dest_dir, exist_ok=True)
        if not os.path.exists(f"{dest_dir}/{model['name']}"):
            run(f'aria2c -x16 -s16 -k1M -o "{model["name"]}" -d "{dest_dir}" {header} "{model["url"]}"')
EOF
}

provisioning_start
