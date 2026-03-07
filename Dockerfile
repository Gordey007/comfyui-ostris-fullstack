# syntax=docker/dockerfile:1.7

############################################
# BUILDER
############################################
FROM nvidia/cuda:12.8.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

ENV PNPM_HOME=/root/.local/share/pnpm
ENV PATH="$PNPM_HOME:$PATH"

ENV UV_LINK_MODE=copy
ENV UV_HTTP_TIMEOUT=10800
ENV UV_HTTP_RETRIES=5
ENV UV_CONCURRENT_DOWNLOADS=32

ENV HF_HUB_ENABLE_HF_TRANSFER=1
ENV HF_HUB_DISABLE_TELEMETRY=1

ENV TORCHINDUCTOR_CACHE_DIR=/root/.cache/torch
ENV TRITON_CACHE_DIR=/root/.triton
ENV PNPM_STORE=/root/.cache/pnpm

RUN echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

RUN mkdir -p /root/.cache/torch /root/.triton /root/.cache/pnpm

############################################
# BASE PACKAGES
############################################

RUN apt-get update && apt-get install -y \
curl gnupg supervisor git nano \
 ca-certificates gnupg \
build-essential \
python3 python3-dev python3-pip python3-venv \
pkg-config make g++ \
libsqlite3-dev \
&& rm -rf /var/lib/apt/lists/*

############################################
# NODE 22 + PNPM 9
############################################

RUN mkdir -p /etc/apt/keyrings && \
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
| gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
> /etc/apt/sources.list.d/nodesource.list && \
apt-get update && apt-get install -y nodejs && \
corepack enable && corepack prepare pnpm@9 --activate

############################################
# UV
############################################

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

############################################
# PYTHON ENVS
############################################

RUN python3 -m venv /opt/comfy-env
RUN python3 -m venv /opt/ostris-env

############################################
# PYTORCH
############################################

RUN --mount=type=cache,target=/root/.cache/uv \
uv pip install \
torch torchvision torchaudio \
--extra-index-url https://download.pytorch.org/whl/cu128 \
--python /opt/comfy-env/bin/python

############################################
# JUPYTER + HF
############################################

RUN uv pip install jupyterlab "huggingface_hub[cli]" \
--python /opt/comfy-env/bin/python

############################################
# COMFYUI
############################################

WORKDIR /build

RUN git config --global http.version HTTP/1.1 && \
git config --global http.postBuffer 1048576000 && \
git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git

WORKDIR /build/ComfyUI

RUN --mount=type=cache,target=/root/.cache/uv \
uv pip install -r requirements.txt \
--python /opt/comfy-env/bin/python

RUN --mount=type=cache,target=/root/.cache/uv \
uv pip install -r manager_requirements.txt \
--python /opt/comfy-env/bin/python

############################################
# OSTRIS
############################################

WORKDIR /build

RUN git config --global http.version HTTP/1.1 && \
git config --global http.postBuffer 1048576000 && \
for i in 1 2 3; do \
git clone --depth 1 https://github.com/ostris/ai-toolkit.git && break || sleep 5; \
done

WORKDIR /build/ai-toolkit/ui

ENV DATABASE_URL="file:/tmp/build.db"
ENV NEXT_PRIVATE_SKIP_ENV_VALIDATION=1
ENV CI=true

RUN --mount=type=cache,target=/root/.cache/pnpm \
pnpm install --no-frozen-lockfile

############################################
# PRISMA
############################################

RUN npx prisma generate

############################################
# BUILD NATIVE MODULES (sqlite3)
############################################

RUN pnpm rebuild sqlite3 sharp prisma @prisma/client

############################################
# NEXT BUILD
############################################

RUN pnpm build

############################################
# OSTRIS PYTHON
############################################

WORKDIR /build/ai-toolkit

RUN --mount=type=cache,target=/root/.cache/uv \
uv pip install -r requirements.txt \
--python /opt/ostris-env/bin/python

############################################
# PRECOMPILE TORCH KERNELS
############################################

RUN /opt/comfy-env/bin/python - <<'PY'
import torch
device="cuda" if torch.cuda.is_available() else "cpu"
q=torch.randn(1,8,64,64,device=device)
k=torch.randn(1,8,64,64,device=device)
v=torch.randn(1,8,64,64,device=device)
torch.nn.functional.scaled_dot_product_attention(q,k,v)
print("Torch kernels compiled")
PY

############################################
# RUNTIME
############################################

FROM nvidia/cuda:12.8.1-runtime-ubuntu22.04

ENV PYTHONUNBUFFERED=1

ENV HF_HOME=/workspace/huggingface
ENV TORCH_HOME=/workspace/.cache/torch
ENV XDG_CACHE_HOME=/workspace/.cache

ENV TRITON_CACHE_DIR=/workspace/.triton
ENV TORCHINDUCTOR_CACHE_DIR=/workspace/.cache/torch

ENV HF_HUB_ENABLE_HF_TRANSFER=1
ENV HF_HUB_DISABLE_TELEMETRY=1

ENV COMFYUI_DISABLE_SEARCH=1
ENV COMFYUI_DISABLE_AUTOLOAD=1
ENV COMFYUI_CACHE_MODELS=1
ENV COMFYUI_LAZY_LOAD=1

ENV CUDA_MODULE_LOADING=LAZY

ENV PATH="/opt/comfy-env/bin:/opt/ostris-env/bin:$PATH"

############################################
# RUNTIME PACKAGES
############################################

RUN apt-get update && apt-get install -y \
curl gnupg supervisor git \
libgl1 libglib2.0-0 \
ca-certificates && \
mkdir -p /etc/apt/keyrings && \
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
| gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
> /etc/apt/sources.list.d/nodesource.list && \
apt-get update && apt-get install -y nodejs && \
corepack enable && corepack prepare pnpm@9 --activate && \
rm -rf /var/lib/apt/lists/*

WORKDIR /app

############################################
# COPY BUILDER OUTPUT
############################################

COPY --from=builder /build/ComfyUI /app/ComfyUI
COPY --from=builder /build/ai-toolkit /app/ai-toolkit
COPY --from=builder /opt/comfy-env /opt/comfy-env
COPY --from=builder /opt/ostris-env /opt/ostris-env
COPY --from=builder /root/.cache/torch /workspace/.cache/torch
COPY --from=builder /root/.triton /workspace/.triton

COPY docker/entrypoint.sh /entrypoint.sh

RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

############################################
# WORKSPACE
############################################

RUN mkdir -p \
/workspace/models/checkpoints \
/workspace/output \
/workspace/dataset \
/workspace/.cache/torch \
/workspace/.triton \
/workspace/huggingface

############################################
# SUPERVISOR
############################################

COPY supervisor/inference.conf /etc/supervisor/inference.conf

ENTRYPOINT ["/entrypoint.sh"]

WORKDIR /workspace

EXPOSE 8188 8675 8888