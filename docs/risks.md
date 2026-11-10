# Risks and experiments

Status as of 2026-11-06.

## The five riskiest assumptions

| # | Assumption | Why it is risky | Test |
|---|---|---|---|
| 1 | The phone's encoder saves a meaningful share at invisible quality | Footage is already high-bitrate HEVC and resolution and frame rate must stay, so savings come from bitrate alone. Hardware encoders usually trail x265 (Hypothesis). | Experiment 0, then 0b, then device |
| 2 | A swap actually frees space | Create plus delete needs a confirmation (Reported). Originals may sit in Recently Deleted. Staging needs space when the phone is full. | Spikes E4 and E5, then device |
| 3 | The replacement is faithful | Date, location, albums, Live Photo pairing, HDR and spatial video must survive, and iCloud Photos propagates both changes. | Fidelity matrix. Unsupported types become `NOT_ELIGIBLE`. |
| 4 | Validation is cheap and trustworthy | VMAF at 4K60 on-device is heavy, a cheap proxy may mis-pass, and a false pass destroys trust. | Calibrate a sampled-SSIM proxy against VMAF in the lab. Fail closed. |
| 5 | Execution fits iOS | Background tasks are idle-only and interruptible (Verified), plus thermal limits and long encodes. | Device benchmark. One item at a time with resumable state. |

## Experiment ladder

Each step is a gate for shipping. The owner chose to build v1 before Experiment 0 (2026-11-06), so
the gates decide whether the app goes out, not whether it is built.

| Step | Question | Tooling | Status |
|---|---|---|---|
| Experiment 0 | How much smaller at mean VMAF 95 with x265 (the ceiling)? | [lab/](../lab/README.md) | Tool built and tested; awaiting clips |
| Experiment 0b | How far below the ceiling is a phone-class hardware encoder? | ffmpeg `hevc_videotoolbox` on a Codemagic Mac mini | Not started |
| E1 | What does Photos expose, and is anything view-based? | [spikes/ios-e1/](../spikes/ios-e1/README.md) | Written, not run |
| E4 | Delete prompt, Recently Deleted and space reclaim | Simulator on Codemagic | Not started |
| E5 | Is create plus delete atomic in one change block? | Simulator on Codemagic | Not started |
| App v1 | Does scan, prepare, approve and replace work end to end on a simulator? | `app-e2e` workflow on Codemagic | Written, never run |
| Device | Real encoder speed, battery and fidelity | Paid Apple Developer Program and an iPhone | Not started |

The bar for Experiment 0 is registered in `lab/src/everkeep_lab/config.py`: at least 30% saved at
mean VMAF 95 on 3 of 4 clips. Photos follow only if video clears it.
