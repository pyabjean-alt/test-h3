# Muse Character Sheet H3 — RunPod template

This packages the "Muse Character Sheet H3" ComfyUI workflow (MiniMax H3 +
RefMod identity injection) into a RunPod pod template, following the same
pattern as the existing MiniMax H3 template you pasted (`download_minimax_h3`,
`minimax_quant`, `civitai_token`, `CIVITAI_LORAS`, `CIVITAI_CHECKPOINTS`,
`LLM_KEY`, `HF_TOKEN`) plus a `provisioning.sh` that layers on the extra
custom nodes and assets this specific workflow needs.

No custom Docker build is required — this reuses the
[ai-dock/comfyui](https://github.com/ai-dock/comfyui) base image, which is
the same style of base most "one-click" ComfyUI RunPod templates (hearmeman's
included) are built on: ComfyUI + JupyterLab + FileBrowser + SSH, plus a
`PROVISIONING_SCRIPT` hook that runs a script of your choice on first boot.

## 1. Host `provisioning.sh` somewhere fetchable

Push it to a public GitHub repo (or a Gist) and grab the **raw** URL, e.g.
`https://raw.githubusercontent.com/<you>/<repo>/main/provisioning.sh`.
RunPod pulls this file at container start — you don't bake it into an image,
so updates just mean editing the file and restarting the pod.

## 2. Create the Template (console.runpod.io → Templates → New Template)

| Field | Value |
|---|---|
| Template name | `muse-character-sheet-h3` |
| Container image | `ghcr.io/ai-dock/comfyui:latest-cuda` |
| Container disk | 40 GB (image + custom nodes) |
| Volume disk | 100 GB+ on `/workspace` (models are large — MiniMax H3's diffusion model alone runs 15–20 GB depending on quant) |
| Expose HTTP ports | `8188` (ComfyUI), `8888` (JupyterLab), `8080` (FileBrowser) |
| Expose TCP ports | `22` (SSH) |

## 3. Environment variables

**Carried over from the existing MiniMax H3 template:**

| Variable | Default | Notes |
|---|---|---|
| `download_minimax_h3` | `true` | leave on — it's what fetches the H3 base weights |
| `minimax_quant` | `int8` | `int8`, `fp8`, `nvfp4`, or `false` for full bf16 (needs a lot more disk) |
| `civitai_token` | empty | your CivitAI API token, needed to pull licensed/gated LoRAs |
| `CIVITAI_LORAS` | empty | comma-separated CivitAI **model-version** IDs — put `MysticXXX_MMH3-V1` and `h3-realism-people-t2v-i2v-r2v`'s version IDs here |
| `CIVITAI_CHECKPOINTS` | empty | same idea, for checkpoints |
| `LLM_KEY` | empty | only needed if you use an Auto-Prompt workflow variant |
| `HF_TOKEN` | empty | needed for gated Hugging Face repos (MiniMax H3 is Comfy-Org-hosted, usually ungated, but set it anyway to avoid rate limits) |

**New, specific to this workflow's extra nodes:**

| Variable | Default | Notes |
|---|---|---|
| `PROVISIONING_SCRIPT` | — | raw URL from step 1 |
| `use_refmod` | `true` | installs `ComfyUI-MiniMaxH3Mod` (the RefMod loader node used in your graph) |
| `use_two_stage_sampling` | `false` | installs `ComfyUI-H3-Multishot`, only if you turn on two-stage sampling in the node |
| `REFMOD_URLS` | empty | comma-separated direct or Google Drive links to your own RefMod files (e.g. `isabella_Rae1_mod`) — since these are your trained assets, not something a public registry hosts |

## 4. What `provisioning.sh` does on boot

1. Installs `av` (PyAV) and `psutil` — both are undeclared dependencies the
   node pack checks for at generation time, per the README's warning that
   ComfyUI's "Install Missing Custom Nodes" won't catch them.
2. Clones the custom node repos: `Muse-CharacterSheet-H3`,
   `Muse-MiniMax-H3-Unified-Loader`, `ComfyUI-KJNodes`,
   `ComfyUI-VideoHelperSuite`, `was-node-suite-comfyui`, `ComfyUI-iTools`,
   plus `ComfyUI-H3-Multishot` / `ComfyUI-MiniMaxH3Mod` if their toggles are on.
3. Copies the example `H3 Character Sheet.json` workflow from the
   `Muse-CharacterSheet-H3` repo into ComfyUI's default workflows folder.
4. Downloads the MiniMax H3 base models (DiT, text encoder, VAEs, turbo LoRA)
   for the chosen `minimax_quant`.
5. Pulls any CivitAI LoRAs/checkpoints you listed.
6. Pulls your own RefMod file(s) from `REFMOD_URLS`.

## Things worth checking before a real deploy

- **`comfyui_memory_cleanup`** (the `RAMCleanup`/`VRAMCleanup` nodes) doesn't
  have one fixed, stable public git URL across mirrors — the script tries to
  install it through ComfyUI-Manager's CLI. If that fails on your image,
  install it by name from the Manager UI once and it'll persist on the
  volume for future boots.
- **Exact MiniMax H3 filenames drift** as Comfy-Org and Kijai update their
  repos (this is also why the quant-specific filename in the script is a
  best guess assembled from your workflow's own loader widget values).
  Before a fresh deploy, check the file listings at
  `huggingface.co/Comfy-Org/MiniMax-H3` and `huggingface.co/Kijai/MiniMax-H3_comfy`
  and override with `MINIMAX_DIT_FILE` / `MINIMAX_CLIP_FILE` /
  `MINIMAX_VAE_FILE` / `MINIMAX_AUDIO_VAE_FILE` / `MINIMAX_TURBO_LORA_FILE`
  env vars if a name has changed.
- **Licensing**: MiniMax H3 ships under MiniMax's own community license,
  which as of its latest revision treats the US, EU, UK and South Korea as
  "Excluded Territories" requiring a separate license — worth a quick check
  of the current license text if your RunPod region or your own use falls
  in one of those.
- The `isabella_Rae1_mod` RefMod and the two H3 LoRAs are your own trained/
  chosen assets — nothing here fabricates a download link for them; they
  flow through `REFMOD_URLS` and `CIVITAI_LORAS` respectively, which you fill
  in with your own sources (Drive links / CivitAI version IDs).
