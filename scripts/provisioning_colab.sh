#!/bin/bash
# --- AI-Dock & Colab Adaptive Provisioning Script (v1.2) ---

if [ -f "/opt/ai-dock/bin/venv-set.sh" ]; then
    echo "--- [ENV] AI-Dock Environment Detected ---"
    source /opt/ai-dock/bin/venv-set.sh comfyui
    VENV_PYTHON="/opt/environments/python/comfyui/bin/python3"
else
    echo "--- [ENV] Standard/Colab Environment Detected ---"
    VENV_PYTHON="python3"
    if [ ! -d "/opt/ComfyUI" ]; then
        echo "--- [INIT] Cloning ComfyUI Source ---"
        git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI
        $VENV_PYTHON -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
        $VENV_PYTHON -m pip install -r /opt/ComfyUI/requirements.txt
    fi
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
    
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > /opt/manifest.yaml
    fi

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
    
    $VENV_PYTHON - <<EOF
import yaml, os, subprocess

def run(cmd):
    print(f"Executing: {cmd}")
    if cmd.startswith("pip"):
        cmd = f"$VENV_PYTHON -m {cmd}"
    subprocess.run(cmd, shell=True)

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

for node in scene.get('nodes', []):
    name = node.split("/")[-1].replace(".git", "")
    path = f"/opt/ComfyUI/custom_nodes/{name}"
    if not os.path.exists(path):
        run(f"git clone {node} {path}")
        if os.path.exists(f"{path}/requirements.txt"):
            run(f"pip install --no-cache-dir -r {path}/requirements.txt")

hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in scene.get('models', []):
    url = model.get('url')
    name = model.get('name')
    dest_dir = f"/opt/ComfyUI/{model['path']}"
    os.makedirs(dest_dir, exist_ok=True)
    
    if not os.path.exists(f"{dest_dir}/{name}"):
        cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
        run(cmd)
EOF
}

provisioning_start
