# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## Bootstrap

- Add automated NVIDIA driver installation detection
- Add AMD GPU driver bootstrap (amdgpu + VFIO)
- Add LXD subid/subgid range auto-configuration for CachyOS

## Deploy Script

- Add optional `--pull-model <name>` flag to auto-download a model after deploy
- Add `--dry-run` mode that prints what would happen
- Add pre-flight GPU check (nvidia-smi, CUDA compute capability)
- Add post-deploy model verification (load a test prompt)
- Add container recreation guard (ask before nuke)

## Model Management

- Add model version pinning (avoid auto-updates breaking compat)
- Add model size/quantization recommendations for RTX 2060M
- Add GGUF-to-FLM conversion tooling if Lemonade adds FLM support

## Observability

- Add GPU utilization monitoring (nvidia-smi polling)
- Add inference performance benchmarking
- Add Lemonade server log tailing (`journalctl -u lemonade-server -f`)
- Add service uptime logging

## Documentation

- Add runbook for common failure scenarios (GPU passthrough, LXD connectivity)
- Add disaster recovery procedure for host + LXD state
- Add Lemonade model management quick reference

## Hardware Migration

- Add AMD GPU migration path (gfx1150/890M) — use ROCm backend in Lemonade
- Add ROCm compatibility testing for AMD GPUs
- Add Intel GPU path (Vulkan backend in Lemonade)
