#!/bin/bash
# --- AI-Dock 2.0+ Provisioning Script for ComfyUI Commander ---
# Optimized for: ghcr.io/ai-dock/comfyui:latest-cuda-12.1-runtime

# This script is sourced by the AI-Dock base image.
# It uses built-in helpers like `provisioning_download` and `provisioning_get_nodes`.

function provisioning_start() {
    echo "--- ComfyUI Commander Boot Sequence ---"
    
    # 1. Environment: Switch to the ComfyUI venv
    source /opt/ai-dock/bin/venv-set.sh comfyui
    
    # 2. Sync Manifest and Workflows from GitHub
    provisioning_sync_github
    
    # 3. Dynamic Node and Model Setup via Python Manifest Parser
    provisioning_run_manifest_logic
    
    echo "--- Provisioning Sequence Finished ---"
}

function provisioning_sync_github() {
    # If MANIFEST_URL is provided, download it
    if [ ! -z "$MANIFEST_URL" ]; then
        curl -sL "$MANIFEST_URL" > /opt/manifest.yaml
    fi

    # Clone workflows if WORKFLOWS_REPO is provided
    if [ ! -z "$WORKFLOWS_REPO" ]; then
        git clone "$WORKFLOWS_REPO" /opt/workflows
    fi
}

function provisioning_run_manifest_logic() {
    # We call a Python snippet to handle the complex Scene logic
    # AI-Dock v2.0+ includes PyYAML in the main python env.
    python3 - <<EOF
import yaml, os, subprocess

def run(cmd):
    print(f"Executing: {cmd}")
    subprocess.run(cmd, shell=True)

manifest_path = "/opt/manifest.yaml"
if not os.path.exists(manifest_path):
    print("Manifest not found.")
    exit(0)

with open(manifest_path, 'r') as f:
    manifest = yaml.safe_load(f)

scene_name = os.environ.get('SCENE', 'default')
scene = manifest.get('scenes', {}).get(scene_name)

if not scene:
    print(f"Scene {scene_name} not found.")
    exit(0)

# Nodes: Git Clone into custom_nodes
for node in scene.get('nodes', []):
    if node.startswith("http"):
        name = node.split("/")[-1].replace(".git", "")
        # Standard AI-Dock path
        path = f"/opt/ComfyUI/custom_nodes/{name}"
        if not os.path.exists(path):
            run(f"git clone {node} {path}")
            if os.path.exists(f"{path}/requirements.txt"):
                # Use the current venv's pip
                run(f"pip install -r {path}/requirements.txt")

# Models: Use aria2c for maximum speed (AI-Dock has it pre-installed)
hf_token = manifest.get('global', {}).get('hf_token', os.environ.get('HF_TOKEN', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in scene.get('models', []):
    url = model.get('url')
    # Rel path within ComfyUI, e.g., models/checkpoints
    rel_path = model.get('path')
    name = model.get('name')
    dest_dir = f"/opt/ComfyUI/{rel_path}"
    os.makedirs(dest_dir, exist_ok=True)
    
    if not os.path.exists(f"{dest_dir}/{name}"):
        # Multi-threaded download
        cmd = f'aria2c -x16 -s16 -k1M -o "{name}" -d "{dest_dir}" {header} "{url}"'
        run(cmd)
EOF
}

# --- Execution Entry Point ---
provisioning_start
