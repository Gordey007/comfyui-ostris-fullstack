#!/usr/bin/env bash
set -e

echo "AI container starting..."

################################
# Python path fallback
################################

PYTHON_BIN="/opt/comfy-env/bin/python"

if [ ! -f "$PYTHON_BIN" ]; then
    echo "WARNING: /opt/comfy-env python not found, using system python"
    PYTHON_BIN=$(which python3 || true)
fi

################################
# GPU memory limiter
################################

if [ -n "$MAX_GPU_MEMORY" ]; then
export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512,garbage_collection_threshold=0.8
fi

################################
# Ensure directories
################################

mkdir -p /workspace/models/checkpoints
mkdir -p /workspace/.cache/torch
mkdir -p /workspace/.triton
mkdir -p /workspace/huggingface

ln -s /app/ComfyUI /workspace/comfyui
ln -s /app/ai-toolkit /workspace/ai-toolkit

################################
# HuggingFace login
################################

if [ -n "$HF_TOKEN" ]; then
echo "Logging into HuggingFace"

if command -v hf >/dev/null 2>&1; then
hf auth login --token "$HF_TOKEN" || true
else
echo "hf CLI not installed, skipping login"
fi

fi

################################
# Automatic model download
################################

if [ -n "$MODEL_URLS" ]; then

IFS=',' read -ra URLS <<< "$MODEL_URLS"

for url in "${URLS[@]}"; do

file=$(basename "$url")
path="/workspace/models/checkpoints/$file"

if [ ! -f "$path" ]; then

echo "Downloading model: $file"

curl -fL "$url" \
--retry 5 \
--retry-delay 10 \
-o "$path"

else

echo "Model already exists: $file"

fi

done

fi

################################
# Preload diffusion weights
################################

if [ -n "$PRELOAD_MODEL" ]; then

echo "Preloading model into GPU memory..."

$PYTHON_BIN - <<PY
import torch
from diffusers import StableDiffusionPipeline

model_path="$PRELOAD_MODEL"

pipe = StableDiffusionPipeline.from_single_file(
    model_path,
    torch_dtype=torch.float16
)

pipe = pipe.to("cuda")

pipe("warmup")

print("Model preloaded")
PY

fi

################################
# Update ComfyUI nodes
################################

if [ -d "/app/ComfyUI/custom_nodes/ComfyUI-Manager" ]; then

echo "Updating ComfyUI nodes..."

$PYTHON_BIN \
/app/ComfyUI/custom_nodes/ComfyUI-Manager/update.py || true

fi

################################
# Prisma database initialization
################################

if [ -d "/app/ai-toolkit/ui/prisma" ]; then

echo "Initializing Prisma database..."

cd /app/ai-toolkit/ui

# generate client
pnpm prisma generate || true

# create tables if they don't exist
pnpm prisma db push || true

fi

################################
# GPU info
################################

echo "GPU info:"
command -v nvidia-smi >/dev/null && nvidia-smi || true

################################
# Start services
################################

echo "Starting services..."

exec supervisord -c /etc/supervisor/inference.conf