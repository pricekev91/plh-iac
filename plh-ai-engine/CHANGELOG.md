# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-07

### Added

- Lemonade Server PPA as the primary AI inference backend
- One-command deploy: `deploy-plh-ai-engine.sh` replaces unsloth + llama.cpp pipeline
- No CUDA toolkit install, no llama.cpp build — PPA bundles CUDA runtime
- Config via `lemonade config set` CLI (CUDA backend, models.path)
- GGUF auto-discovery: models in `/srv/ai/models` show up in `lemonade list --downloaded`
- Health check via `/live` endpoint (Lemonade)

### Changed

- **BREAKING**: Port 8080 → 13305 (Lemonade Web UI)
- **BREAKING**: Unsloth Studio → Lemonade Server
- **BREAKING**: Removed all YAML-based platform definitions (no more `platforms/`, `inventory/`, `profiles/` dirs)
- **BREAKING**: Removed `apply.bash` (renamed to `delete-me-apply.bash`)
- Removed `scripts/provision-ai-appliance.bash` (replaced by deploy script)
- Simplified: LXD project + GPU passthrough + PPA install + config
- GPU passthrough via LXD `gpu` device (no more `libcuda.so` copy)

### Removed

- Unsloth Studio stack (`--no-torch` install, custom systemd unit)
- llama.cpp from-source build (CUDA toolkit + cmake + nvcc)
- Host `libcuda.so` copy into container (PPA bundles CUDA runtime)
- CUDA repo/keyring setup inside container
- `switch-model.sh` script (use `lemonade pull` CLI)
- Port proxy configuration for Unsloth (direct LXD proxy on :13305)

## [0.2.3] - 2026-06

### Changed

- Switch llama-direct to Ministral 3B and 32K context (95e7475)

## [0.2.2] - 2026-05

### Changed

- Increase llama-direct context to 90112 (c8928a0)

## [0.2.1] - 2026-05

### Added

- Dedicated llama project scaffold with standalone server provisioning (9573ff0)
- Pin GPU profile to NVIDIA device vendor (fd1101f)
- Enable NVIDIA runtime libs in gpu profile (9512c4b)

### Changed

- Force NVIDIA LocalAI llama.cpp backend installation (b208084)

### Fixed

- Allow GPU device-node validation when nvidia-smi is absent (014ff79)

## [0.2.0] - 2026-04

### Changed

- Run LocalAI on port 8080 directly for prod engine (326f28f)
- Quote GPU name in runtime env for LocalAI startup (fc323fc)
- Enforce RTX 2060M GPU detection for LocalAI startup (e997be4)
- Enforce NVIDIA 2060M runtime for engine (3d4d47c)

### Added

- Refactor: port iac-hlh design to LXD-based iac-plh (def17ff)
- Unify engine runtime and LocalAI on single LXD host (1cb23dd)

### Changed

- Rename repo metadata to iac-plh (4bc92b0)

## [0.1.0] - 2026-04

### Added

- Initial iac-plh scaffolding
- Switch engine backend to Ollama with Open WebUI (aad61e9)
- Add broker-managed five-container architecture (d3cb730)
- Record known-good three-service appliance state (a2214f5)
- Snapshot current AI appliance project state (a26a9dc)
- Finalize prod migration cleanup and project removal (fd4475e)
- Bootstrap scripts for CachyOS/Arc
- apply.bash initial reconciliation runner
- Platform YAML definitions (engine, presentation, orchestrator, agents)
- LXD GPU passthrough profiles (NVIDIA, AMD, Intel)
