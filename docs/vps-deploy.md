# VPS Deployment: OpenClaw + Ollama

Self-hosted deployment with local LLM inference for vision and reasoning tasks.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Single Docker Container            │
│                                                      │
│  ┌──────────────────┐    ┌──────────────────────┐  │
│  │   OpenClaw       │    │   Ollama Server      │  │
│  │   Gateway        │───▶│   (llava/moondream)  │  │
│  │   (Node.js)      │◀───│   + LLM models       │  │
│  │   Port 18789     │    │   Port 11434         │  │
│  └──────────────────┘    └──────────────────────┘  │
│           ▲                       ▲                 │
│           │                       │                 │
│  ┌────────┴───────────────────────┴──────────┐    │
│  │            Shared volumes                     │    │
│  │  • ~/.openclaw (config, sessions)           │    │
│  │  • /root/.ollama (model files)              │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

## Files

| File                     | Purpose                                |
| ------------------------ | -------------------------------------- |
| `Dockerfile.vps`         | Combined OpenClaw + Ollama container   |
| `docker-compose.vps.yml` | Easy deployment with volume management |
| `vps-config.json`        | OpenClaw config for local Ollama       |

## Quick Start

### Build the image

```bash
docker build -f Dockerfile.vps -t openclaw-vps .
```

### Run with GPU support (NVIDIA)

```bash
docker-compose -f docker-compose.vps.yml up -d
```

### Verify Ollama is running

```bash
curl http://localhost:11434/api/tags
```

### Verify OpenClaw gateway

```bash
curl http://localhost:18789/healthz
```

### Test vision model

```bash
curl -X POST http://localhost:11434/api/generate \
  -d '{"model": "llava", "prompt": "Describe this document", "images": ["<base64>"]}'
```

### Test via OpenClaw

```bash
openclaw --gateway http://your-vps:18789 channels status
```

## Ollama Vision Models

| Model              | Size | Use Case                          |
| ------------------ | ---- | --------------------------------- |
| `llava:latest`     | ~7GB | General vision, document parsing  |
| `moondream:latest` | ~4GB | Fast vision, lightweight          |
| `minicpm-v:latest` | ~6GB | Better OCR/document understanding |

## GPU Memory Requirements

- **Minimum (CPU-only):** 8GB RAM - works but slow
- **Recommended:** 16GB VRAM - can run `llava` + small LLM
- **Optimal:** 24GB+ VRAM - full performance with larger models

## Limitations

1. **Single container = single GPU** - For multi-GPU setups, run Ollama separately
2. **Model downloads** - First run will download models (~10GB); mount `ollama-models` volume to persist
3. **Cold start** - Ollama takes ~10-30s to load a model into memory
4. **VPS CPU** - Without GPU, vision inference will be very slow (~1-2 min per page)

## Existing Code Reuse

| Component       | File                               | Purpose                            |
| --------------- | ---------------------------------- | ---------------------------------- |
| Ollama plugin   | `extensions/ollama/index.ts`       | Already handles Ollama integration |
| Ollama stream   | `src/agents/ollama-stream.ts`      | Native `/api/chat` protocol        |
| Model discovery | `src/agents/pi-model-discovery.ts` | Auto-discovers Ollama models       |
| PDF tool        | `src/agents/tools/pdf-tool.ts`     | Can route to local vision model    |
| Gateway server  | `src/gateway/server.impl.ts`       | Already Docker-ready               |
