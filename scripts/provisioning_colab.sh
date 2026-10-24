#!/bin/bash
# ==============================================================================
# ComfyUI Colab Provisioning & Auto-Deploy Script
# Optimized for Google Colab / Linux Cloud Environments
# ==============================================================================

set -e

echo "=== [ENV] Initializing ComfyUI Provisioning for Google Colab ==="
export VENV_PYTHON="python3"

# 1. 平台自适应路径配置 (优先使用大容量 /content 分区)
PLATFORM=${PLATFORM:-"colab"}
if [ "$PLATFORM" = "runpod" ]; then
    DEFAULT_COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"
    DEFAULT_MANIFEST_PATH="/workspace/manifest.yaml"
    DEFAULT_WORKFLOWS_PATH="/workspace/workflows"
elif [ "$PLATFORM" = "vast" ]; then
    DEFAULT_COMFYUI_PATH="/workspace/ComfyUI"
    DEFAULT_MANIFEST_PATH="/workspace/manifest.yaml"
    DEFAULT_WORKFLOWS_PATH="/workspace/workflows"
elif [ "$PLATFORM" = "colab" ]; then
    DEFAULT_COMFYUI_PATH="/content/ComfyUI"
    DEFAULT_MANIFEST_PATH="/content/manifest.yaml"
    DEFAULT_WORKFLOWS_PATH="/content/workflows"
else
    DEFAULT_COMFYUI_PATH="/content/ComfyUI"
    DEFAULT_MANIFEST_PATH="/content/manifest.yaml"
    DEFAULT_WORKFLOWS_PATH="/content/workflows"
fi

export COMFYUI_PATH=${COMFYUI_PATH:-"$DEFAULT_COMFYUI_PATH"}
export MANIFEST_PATH=${MANIFEST_PATH:-"$DEFAULT_MANIFEST_PATH"}
export WORKFLOWS_PATH=${WORKFLOWS_PATH:-"$DEFAULT_WORKFLOWS_PATH"}

echo "  -> ComfyUI 目标路径: $COMFYUI_PATH"
echo "  -> Manifest 配置路径: $MANIFEST_PATH"

# 2. 补齐系统依赖 (aria2 用于高速多线程下载)
if ! command -v aria2c &> /dev/null; then
    echo "--- [INIT] 安装多线程极速下载器 aria2 ---"
    apt-get update -qq && apt-get install -y -qq aria2
fi

# 3. 校验 PyTorch 与 CUDA 加速环境 (Colab 已预装，仅在缺失时补齐)
if ! $VENV_PYTHON -c "import torch; assert torch.cuda.is_available()" &> /dev/null; then
    echo "--- [INIT] 未检测到可用 CUDA PyTorch，开始安装 ---"
    $VENV_PYTHON -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
else
    TORCH_INFO=$($VENV_PYTHON -c 'import torch; print(f"{torch.__version__} | GPU: {torch.cuda.get_device_name(0)}")')
    echo "--- [ENV] CUDA PyTorch 就绪: $TORCH_INFO ---"
fi

# 4. 克隆或更新 ComfyUI 核心仓库
if [ ! -d "$COMFYUI_PATH" ]; then
    echo "--- [INIT] 克隆 ComfyUI 官方仓库到 $COMFYUI_PATH ---"
    git clone https://github.com/comfyanonymous/ComfyUI "$COMFYUI_PATH"
fi

# 5. 校验核心依赖与脚本所需依赖
echo "--- [INIT] 校验 ComfyUI 核心 Python 依赖 ---"
$VENV_PYTHON -m pip install --no-cache-dir -r "$COMFYUI_PATH/requirements.txt"
$VENV_PYTHON -m pip install -q PyYAML requests

# ------------------------------------------------------------------------------
# 业务函数定义
# ------------------------------------------------------------------------------

function provisioning_install_manager() {
    if [ ! -d "$COMFYUI_PATH/custom_nodes/ComfyUI-Manager" ]; then
        echo "--- [INIT] 安装 ComfyUI-Manager 节点管理器 ---"
        git clone https://github.com/ltdrdata/ComfyUI-Manager "$COMFYUI_PATH/custom_nodes/ComfyUI-Manager"
    fi
    if [ -f "$COMFYUI_PATH/custom_nodes/ComfyUI-Manager/requirements.txt" ]; then
        $VENV_PYTHON -m pip install --no-cache-dir -q -r "$COMFYUI_PATH/custom_nodes/ComfyUI-Manager/requirements.txt"
    fi
}

function provisioning_sync_github() {
    echo "--- [SYNC] 同步 Manifest 配置文件与私有工作流仓库 ---"
    
    # 同步 Manifest
    if [ ! -z "$MANIFEST_URL" ]; then
        echo "  -> 从远程下载 Manifest: $MANIFEST_URL"
        mkdir -p "$(dirname "$MANIFEST_PATH")"
        curl -sL "$MANIFEST_URL" > "$MANIFEST_PATH"
    elif [ ! -f "$MANIFEST_PATH" ]; then
        # 兼容自动搜寻可能的挂载或上传路径
        for candidate in "/opt/manifest.yaml" "/content/config/manifest.yaml" "./config/manifest.yaml" "./manifest.yaml"; do
            if [ -f "$candidate" ]; then
                echo "  -> 发现本地候选 Manifest: $candidate，复制到 $MANIFEST_PATH"
                mkdir -p "$(dirname "$MANIFEST_PATH")"
                cp "$candidate" "$MANIFEST_PATH"
                break
            fi
        done
    fi

    # 同步私有工作流仓库 (支持 GH_TOKEN)
    if [ ! -z "$WORKFLOWS_REPO" ]; then
        mkdir -p "$(dirname "$WORKFLOWS_PATH")"
        if [ -d "$WORKFLOWS_PATH/.git" ]; then
            echo "  -> 拉取最新工作流: $WORKFLOWS_PATH"
            cd "$WORKFLOWS_PATH" && git pull
        else
            echo "  -> 克隆工作流仓库: $WORKFLOWS_REPO"
            REPO_URL_CLEAN=$(echo "$WORKFLOWS_REPO" | sed 's|https://||')
            if [ ! -z "$GH_TOKEN" ]; then
                git clone "https://${GH_TOKEN}@${REPO_URL_CLEAN}" "$WORKFLOWS_PATH"
            else
                git clone "$WORKFLOWS_REPO" "$WORKFLOWS_PATH"
            fi
        fi
    fi
}

function provisioning_run_manifest_logic() {
    echo "--- [ASSETS] 执行动态资产与节点装载逻辑 ---"
    
    $VENV_PYTHON - <<'EOF'
import os
import sys
import yaml
import subprocess

def run_cmd(cmd):
    print(f"Executing: {cmd}")
    if cmd.startswith("pip"):
        venv_python = os.environ.get('VENV_PYTHON', sys.executable)
        cmd = f"\"{venv_python}\" -m {cmd}"
    result = subprocess.run(cmd, shell=True)
    return result.returncode

manifest_path = os.environ.get('MANIFEST_PATH', '/content/manifest.yaml')
comfyui_path = os.environ.get('COMFYUI_PATH', '/content/ComfyUI')
workflow_repo_path = os.environ.get('WORKFLOWS_PATH', '/content/workflows')

if not os.path.exists(manifest_path):
    # 尝试后备路径
    for fb in ["/opt/manifest.yaml", "config/manifest.yaml", "manifest.yaml"]:
        if os.path.exists(fb):
            manifest_path = fb
            break

if not os.path.exists(manifest_path):
    print(f"⚠️ [WARN] 未找到 Manifest 配置文件 ({manifest_path})，跳过自动化节点与模型拉取。")
    sys.exit(0)

print(f"📖 [MANIFEST] 正在加载配置文件: {manifest_path}")
with open(manifest_path, 'r', encoding='utf-8') as f:
    manifest = yaml.safe_load(f) or {}

scene_name = os.environ.get('SCENE', 'default')
available_scenes = list(manifest.get('scenes', {}).keys()) if manifest.get('scenes') else []
scene = manifest.get('scenes', {}).get(scene_name, {})

if scene_name not in manifest.get('scenes', {}):
    if scene_name != 'default':
        print(f"⚠️ [WARN] 指定的场景 '{scene_name}' 不存在于 manifest.yaml 中！")
    print(f"ℹ️ [INFO] 当前可用 scenes 列表: {available_scenes}")
    print("ℹ️ [INFO] 本次仅加载 global 全局节点与模型。若需加载特定场景，请设置环境变量: export SCENE=<scene_name>")
else:
    print(f"🎯 [SCENE] 成功匹配场景 Profile: '{scene_name}'")

# 1. 资产合并
global_nodes = manifest.get('global', {}).get('nodes', []) or []
global_models = manifest.get('global', {}).get('models', []) or []
global_pips = manifest.get('global', {}).get('pips', []) or []

scene_nodes = scene.get('nodes', []) or []
scene_models = scene.get('models', []) or []
scene_pips = scene.get('pips', []) or []

all_nodes = global_nodes + scene_nodes
all_models = global_models + scene_models
all_pips = global_pips + scene_pips

# 2. 自动安装插件节点 (Custom Nodes)
print(f"\n--- [NODES] 开始安装自定义插件节点 (共 {len(all_nodes)} 个) ---")
for node in all_nodes:
    try:
        url, version = "", "main"
        if isinstance(node, str):
            url = node
        elif isinstance(node, dict):
            url = node.get('url', '')
            version = node.get('version', 'main')

        if url and url.startswith("http"):
            name = url.split("/")[-1].replace(".git", "")
            path = f"{comfyui_path}/custom_nodes/{name}"
            if not os.path.exists(path):
                print(f"  [+] 克隆插件: {name} (分支/版本: {version})")
                run_cmd(f"git clone -b {version} {url} {path}")
            else:
                print(f"  [*] 插件已存在，跳过克隆: {name}")

            # 校验并安装节点独立依赖
            req_file = f"{path}/requirements.txt"
            if os.path.exists(req_file):
                run_cmd(f"pip install --no-cache-dir -r {req_file}")
    except Exception as e:
        print(f"❌ 安装节点 {node} 出现异常: {e}")

# 3. 自动下载模型 (Models Download via aria2c)
print(f"\n--- [MODELS] 开始下载模型权重文件 (共 {len(all_models)} 个) ---")
hf_token = os.environ.get('HF_TOKEN', manifest.get('global', {}).get('hf_token', ''))
header = f'--header="Authorization: Bearer {hf_token}"' if hf_token else ''

for model in all_models:
    try:
        url = model.get('url')
        name = model.get('name')
        rel_path = model.get('path', 'models/checkpoints')
        if not url or not name:
            continue

        dest_dir = f"{comfyui_path}/{rel_path}"
        dest_file = f"{dest_dir}/{name}"
        os.makedirs(dest_dir, exist_ok=True)

        if not os.path.exists(dest_file):
            print(f"  [↓] 正在通过 aria2c 下载: {name} -> {rel_path}")
            cmd = f'aria2c -c -x16 -s16 -k1M --summary-interval=10 --allow-overwrite=true -o "{name}" -d "{dest_dir}" {header} "{url}"'
            run_cmd(cmd)
        else:
            print(f"  [*] 模型已存在，跳过下载: {name}")
    except Exception as e:
        print(f"❌ 下载模型 {model.get('name', 'unknown')} 出现异常: {e}")

# 4. 自动安装 Python 第三方包
if all_pips:
    print(f"\n--- [PIPS] 安装场景指定 Python 库: {all_pips} ---")
    for package in all_pips:
        try:
            run_cmd(f"pip install {package}")
        except Exception as e:
            print(f"❌ 安装 Python 包 {package} 出现异常: {e}")

# 5. 同步工作流 (Workflow Sync)
if os.path.exists(workflow_repo_path):
    dest = f"{comfyui_path}/user/default/workflows"
    os.makedirs(dest, exist_ok=True)
    src = f"{workflow_repo_path}/workflows" if os.path.exists(f"{workflow_repo_path}/workflows") else workflow_repo_path
    print(f"\n--- [SYNC] 同步工作流从 {src} 到 {dest} ---")
    run_cmd(f"cp -v {src}/*.json {dest}/ 2>/dev/null || true")

    if os.path.exists(f"{src}/subgraphs"):
        sub_dest = f"{dest}/subgraphs"
        os.makedirs(sub_dest, exist_ok=True)
        run_cmd(f"cp -v {src}/subgraphs/*.json {sub_dest}/ 2>/dev/null || true")

# 6. 最终路径审计
print("\n--- [AUDIT] 已安装 Custom Nodes 列表 ---")
nodes_dir = f"{comfyui_path}/custom_nodes"
if os.path.exists(nodes_dir):
    installed_nodes = os.listdir(nodes_dir)
    print(f"总计 {len(installed_nodes)} 个节点插件: {installed_nodes}")
else:
    print(f"⚠️ 未找到 custom_nodes 目录")
EOF
    echo "--- [END] Provisioning 装机流程执行完成 ---"
}

function provisioning_start_server() {
    echo "=== [SERVICE] 启动 ComfyUI 与 Cloudflare 穿透服务 ==="
    
    # 1. 确保安装 cloudflared
    # if ! command -v cloudflared &> /dev/null; then
    #     echo "--- [INIT] 下载 Cloudflared 客户端 ---"
    #     curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    #     chmod +x /usr/local/bin/cloudflared
    # fi

    # 2. 后台启动 ComfyUI
    echo "--- [BOOT] 正在后台启动 ComfyUI (端口 8188) ---"
    nohup $VENV_PYTHON "$COMFYUI_PATH/main.py" --listen 0.0.0.0 --port 8188 --preview-method auto > /content/comfyui.log 2>&1 &
    COMFY_PID=$!
    echo "ComfyUI 已启动，PID: $COMFY_PID (日志记录在 /content/comfyui.log)"
    
    sleep 4

    # 3. 启动 Cloudflare Tunnel 穿透
    # echo "--- [TUNNEL] 正在通过 Cloudflare Tunnel 建立公网 HTTPS 隧道 ---"
    # rm -f /content/tunnel.log
    # nohup cloudflared tunnel --url http://127.0.0.1:8188 > /content/tunnel.log 2>&1 &
    
    # echo "等待公网 URL 生成..."
    # TUNNEL_URL=""
    # for i in {1..30}; do
    #     sleep 1
    #     TUNNEL_URL=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /content/tunnel.log | head -n 1 || true)
    #     if [ ! -z "$TUNNEL_URL" ]; then
    #         break
    #     fi
    # done

    # echo "================================================================="
    # if [ ! -z "$TUNNEL_URL" ]; then
    #     echo "🎉 ComfyUI 远程公网服务已就绪！"
    #     echo "👉 访问与 API 端点 URL: $TUNNEL_URL"
    #     echo "💡 本地调用测试: curl $TUNNEL_URL/system_stats"
    # else
    #     echo "⚠️ 未能自动提取到 Tunnel URL，请手动查看日志: cat /content/tunnel.log"
    # fi
    echo "================================================================="
    echo "🎉 ComfyUI 远程服务已在后台就绪 (端口 8188)！"
    echo "👉 你的固定 ngrok 访问地址: https://delicate-unpainted-activate.ngrok-free.dev"
    echo "💡 本地测试: curl https://delicate-unpainted-activate.ngrok-free.dev/system_stats"
    echo "================================================================="


    # 4. 进入心跳保活阻塞循环（保持 Cell 处于运行状态，防止 Colab 判定为空闲而断连）
    $VENV_PYTHON - <<'EOF'
import time
from datetime import datetime

print("\n--- [HEARTBEAT] ComfyUI 已在后台稳定运行，开始进入保活心跳监听... ---")
try:
    while True:
        # 每隔 60 秒打印一次心跳时间戳，证明该 Cell 活跃中
        time.sleep(60)
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{now}] 💓 Heartbeat: ComfyUI running & tunnel alive...")
except KeyboardInterrupt:
    print("\n[STOP] 手动停止服务保活监听。")
EOF
}

# ------------------------------------------------------------------------------
# 主入口调度
# ------------------------------------------------------------------------------
function provisioning_main() {
    START_FLAG=false

    # 参数解析（支持 --scene <name>、-s <name>、--start 等任意顺序参数）
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start)
                START_FLAG=true
                shift
                ;;
            --scene|-s)
                export SCENE="$2"
                shift 2
                ;;
            --manifest|-m)
                export MANIFEST_PATH="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    echo "--- [CONFIG] 当前生效 SCENE: ${SCENE:-'(未指定，仅加载全局)'} ---"
    provisioning_install_manager
    provisioning_sync_github
    provisioning_run_manifest_logic

    # 如果传入参数 --start 或环境变量 START_SERVER=true，则自动启动 ComfyUI 服务与隧道
    if [ "$START_FLAG" = "true" ] || [ "$START_SERVER" = "true" ]; then
        provisioning_start_server
    fi
}

provisioning_main "$@"
