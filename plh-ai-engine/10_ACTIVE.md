# TODO

Active items in progress. These are the current focus areas.

## Active

- [x] Migrated from Unsloth + llama.cpp to Lemonade Server (PPA)
- [x] Simplified deploy: single script, no YAML, no build from source
- [x] CUDA backend config via /etc/lemonade/config.json
- [ ] Test deploy on actual CachyOS + LXD host
- [ ] Verify CUDA backend works with RTX 2060M (sm_75)
- [ ] Add model download to deploy script (optional auto-pull)
- [ ] Add model verification after deploy

## This Week

- [ ] Run `./deploy-plh-ai-engine.sh` on the laptop host
- [ ] Verify Lemonade Web UI loads at http://127.0.0.1:13305
- [ ] Pull a model and test a chat completion
- [ ] Verify API endpoint responds to OpenAI-compatible requests
