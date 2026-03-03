# ComfyUI + Ostris AI Toolkit + JupyterLab (CUDA 12.8)

**Полный AI-стек для генерации и обучения LoRA**  
В одном контейнере запущено три сервиса:

- **ComfyUI** — порт 8188 (Flux.2 ready)
- **Ostris AI Toolkit** — порт 8675 (обучение LoRA/DoRA)
- **JupyterLab** — порт 8888

**Особенности:**
- Использует `uv` для быстрой установки зависимостей
- Multi-stage сборка (образ максимально лёгкий)
- Все данные сохраняются в `/workspace`
- Supervisor управляет всеми сервисами одновременно
- Поддержка GPU (NVIDIA)

Идеально подходит для генерации датасетов, обучения персонажей и экспериментов с Flux.2.

**Запуск:**
```bash
docker run -d --gpus all -p 8188:8188 -p 8675:8675 -p 8888:8888 -v $(pwd)/workspace:/workspace gordeyvasilev/comfyui-ostris-jupyter:latest
