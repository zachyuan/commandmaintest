#!/bin/bash
# --- AI-Dock & Colab Adaptive Provisioning Script (v1.2) ---

# --- Standardized Provisioning Script (v1.3) ---

# 环境变量：使用 ComfyUI 目录下的本地虚拟环境
export COMFYUI_DIR="/opt/ComfyUI"
export VENV_DIR="$COMFYUI_DIR/venv"
export VENV_PYTHON="$VENV_DIR/bin/python3"

# 0. uv 工具启动
if ! command -v uv &> /dev/null; then
    echo "--- [INIT] Installing uv package manager ---"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

echo "--- [ENV] Initializing Standard Environment ---"

# 1. 基础目录与源码初始化 (必须先拉取源码)
if [ ! -d "$COMFYUI_DIR" ]; then
    echo "--- [INIT] Cloning ComfyUI Source ---"
    git clone https://github.com/comfyanonymous/ComfyUI "$COMFYUI_DIR"
fi

# 2. 虚拟环境初始化 (通过 uv 自动管理 Python 3.13)
if [ ! -f "$VENV_PYTHON" ]; then
    echo "--- [INIT] Creating Python 3.13 venv via uv ---"
    uv venv "$VENV_DIR" --python 3.13
    
    echo "--- [INIT] Installing Core Dependencies (PyTorch) via uv ---"
    uv pip install --upgrade pip
    uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 --python "$VENV_PYTHON"
    
    echo "--- [INIT] Installing Business Logic Dependencies ---"
    uv pip install PyYAML requests --python "$VENV_PYTHON"
fi

# 3. 核心依赖校验 (每次运行，使用 uv 加速)
uv pip install --no-cache-dir -r "$COMFYUI_DIR/requirements.txt" --python "$VENV_PYTHON"

function provisioning_start() {
    echo "--- [START] Provisioning Sequence ---"
    # provisioning_install_manager
    provisioning_sync_github
    provisioning_run_manifest_logic
    echo "--- [END] Provisioning Sequence Finished ---"
}

function provisioning_install_manager() {
    if [ ! -d "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager" ]; then
        echo "--- [INIT] Installing ComfyUI-Manager ---"
        git clone https://github.com/ltdrdata/ComfyUI-Manager "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"
    fi
    # 强制每次运行都校验核心插件依赖 (Ensure requirements always installed)
    uv pip install --no-cache-dir -r "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager/requirements.txt" --python "$VENV_PYTHON"
}

function provisioning_sync_github() {
    echo "--- [SYNC] Downloading Manifest & Workflows ---"
    
    # 同步 Manifest 配置文件
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > "$COMFYUI_DIR/manifest.yaml"
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
    
    # 使用引号保护的 EOF 阻止 Shell 盲目展开，内部使用 sys.executable 确保 100% 环境对齐
    $VENV_PYTHON - <<'EOF'
import yaml, os, subprocess, sys

def run(cmd):
    print(f"Executing: {cmd}")
    # 强制让内部调用也使用 100% 一致的 Python 解释器 & 使用 uv 加速
    if cmd.startswith("pip"):
        # 使用 uv pip install --python <sys.executable>
        cmd = f"uv pip {cmd.replace('pip ', '')} --python \"{sys.executable}\""
    result = subprocess.run(cmd, shell=True)
    return result.returncode

manifest_path = os.path.join(os.environ['COMFYUI_DIR'], "manifest.yaml")
if not os.path.exists(manifest_path):
    print("Manifest not found, skipping asset loading.")
    exit(0)

with open(manifest_path, 'r') as f:
    manifest = yaml.safe_load(f)

scene_name = os.environ.get('SCENE', 'default')
scene = manifest.get('scenes', {}).get(scene_name, {})

# 1. 资源合并 (Asset Merging)
global_nodes = manifest.get('global', {}).get('nodes', [])
global_models = manifest.get('global', {}).get('models', [])
scene_nodes = scene.get('nodes', []) if scene else []
scene_models = scene.get('models', []) if scene else []

all_nodes = (global_nodes or []) + (scene_nodes or [])
all_models = (global_models or []) + (scene_models or [])

# 2. 自动安装插件节点 (Node Setup)
for node in all_nodes:
    try:
        url, version = "", "main"
        if isinstance(node, str): url = node
        elif isinstance(node, dict):
            url = node.get('url')
            version = node.get('version', 'main')
            
        if url and url.startswith("http"):
            name = url.split("/")[-1].replace(".git", "")
            path = os.path.join(os.environ['COMFYUI_DIR'], "custom_nodes", name)
            if not os.path.exists(path):
                run(f"git clone -b {version} {url} {path}")
            
            # 无论是否已克隆，都强制校验依赖 (Ensure deps are checked every time)
            if os.path.exists(f"{path}/requirements.txt"):
                run(f"pip install --no-cache-dir -r {path}/requirements.txt")
    except Exception as e:
        print(f"Unexpected error for node {node}: {e}, skipping.")

# 3. 自动下载模型 (Model Setup)
hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in all_models:
    try:
        url, name = model.get('url'), model.get('name')
        dest_dir = os.path.join(os.environ['COMFYUI_DIR'], model['path'])
        os.makedirs(dest_dir, exist_ok=True)
        if not os.path.exists(f"{dest_dir}/{name}"):
            cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
            run(cmd)
    except Exception as e:
        print(f"❌ Error processing model {model.get('name', 'unknown')}: {e}")

# 4. 同步工作流 (Workflow Sync)
workflow_repo_path = "/opt/workflows"
if os.path.exists(workflow_repo_path):
    dest = os.path.join(os.environ['COMFYUI_DIR'], "user/default/workflows")
    os.makedirs(dest, exist_ok=True)
    src = f"{workflow_repo_path}/workflows" if os.path.exists(f"{workflow_repo_path}/workflows") else workflow_repo_path
    print(f"--- [SYNC] Syncing workflows from {src} to {dest} ---")
    run(f"cp -v {src}/*.json {dest}/ 2>/dev/null || true")

# 5. 最终路径审计 (Final Path Audit)
print("\n--- [AUDIT] Custom Nodes Contents ---")
custom_nodes_path = os.path.join(os.environ['COMFYUI_DIR'], "custom_nodes")
if os.path.exists(custom_nodes_path):
    print(os.listdir(custom_nodes_path))
else:
    print(f"WARNING: {custom_nodes_path} NOT FOUND")
EOF

    # 最终汇总
    echo "--- [AUDIT] System Check Finished ---"
}

# 执行主流程
provisioning_start
