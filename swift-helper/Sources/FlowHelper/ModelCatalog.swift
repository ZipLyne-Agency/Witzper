// Curated catalog of swappable Witzper models, grouped by role.
// The dashboard's Settings tab uses these to drive its picker UI.

import Foundation

enum ModelRole {
    case cleanup
    case asr
    case command
}

struct ModelOption: Identifiable, Hashable {
    let id: String         // hugging face repo id, e.g. "mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit"
    let label: String      // short display name
    let role: ModelRole
    let approxRamGB: Double
    let approxLatencyMs: Int
    let qualityStars: Int  // 1..5
    let blurb: String
}

enum ModelCatalog {
    // Cleanup LLMs (the per-utterance hot path)
    static let cleanup: [ModelOption] = [
        ModelOption(
            id: "juanquivilla/sotto-cleanup-lfm25-350m-mlx-4bit",
            label: "Sotto Cleanup 350M",
            role: .cleanup,
            approxRamGB: 0.2,
            approxLatencyMs: 30,
            qualityStars: 4,
            blurb: "Purpose-built for transcript cleanup. 200 MB. Insanely fast. Can't do anything else."
        ),
        ModelOption(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            label: "Llama 3.2 1B",
            role: .cleanup,
            approxRamGB: 0.7,
            approxLatencyMs: 40,
            qualityStars: 3,
            blurb: "Tiny + fast. Needs strict guardrails. Good for low-RAM Macs."
        ),
        ModelOption(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            label: "Llama 3.2 3B",
            role: .cleanup,
            approxRamGB: 2.0,
            approxLatencyMs: 70,
            qualityStars: 3,
            blurb: "What getonit.ai ships. Solid baseline."
        ),
        ModelOption(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            label: "Qwen3 4B",
            role: .cleanup,
            approxRamGB: 2.5,
            approxLatencyMs: 80,
            qualityStars: 4,
            blurb: "Best small-model quality on Apple Silicon. Excellent default for 16 GB Macs."
        ),
        ModelOption(
            id: "mlx-community/Qwen3-8B-Instruct-2507-4bit",
            label: "Qwen3 8B",
            role: .cleanup,
            approxRamGB: 5.0,
            approxLatencyMs: 120,
            qualityStars: 4,
            blurb: "Smarter than 4B. Headroom for tougher transcripts."
        ),
        ModelOption(
            id: "mlx-community/Qwen3-14B-Instruct-2507-8bit",
            label: "Qwen3 14B",
            role: .cleanup,
            approxRamGB: 15.0,
            approxLatencyMs: 180,
            qualityStars: 5,
            blurb: "Sweet spot for 32–64 GB Macs. Near-30B quality at half the RAM."
        ),
        ModelOption(
            id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit",
            label: "Qwen3 30B-A3B (default)",
            role: .cleanup,
            approxRamGB: 32.0,
            approxLatencyMs: 250,
            qualityStars: 5,
            blurb: "30B MoE, 3B active. Witzper's default. Needs ≥32 GB RAM."
        ),
    ]

    // Speech-to-text engines
    static let asr: [ModelOption] = [
        ModelOption(
            id: "mlx-community/parakeet-tdt-0.6b-v3",
            label: "Parakeet TDT 0.6B v3 (default)",
            role: .asr,
            approxRamGB: 1.0,
            approxLatencyMs: 80,
            qualityStars: 5,
            blurb: "10× faster than Whisper Large v3. Lower WER on English. 25 langs."
        ),
        ModelOption(
            id: "mlx-community/whisper-large-v3-turbo",
            label: "Whisper Large v3 Turbo",
            role: .asr,
            approxRamGB: 3.0,
            approxLatencyMs: 200,
            qualityStars: 4,
            blurb: "Fastest Whisper. 100+ languages. Use if you dictate outside Parakeet's 25 langs."
        ),
        ModelOption(
            id: "mlx-community/whisper-large-v3-mlx",
            label: "Whisper Large v3 (full)",
            role: .asr,
            approxRamGB: 6.0,
            approxLatencyMs: 500,
            qualityStars: 4,
            blurb: "Highest-quality Whisper. Slow, but best multilingual coverage."
        ),
        ModelOption(
            id: "mlx-community/whisper-medium-mlx",
            label: "Whisper Medium",
            role: .asr,
            approxRamGB: 1.5,
            approxLatencyMs: 250,
            qualityStars: 3,
            blurb: "English-focused. Smaller, faster than large."
        ),
    ]

    // Command Mode (heavy, lazy-loaded, separate hotkey)
    static let command: [ModelOption] = [
        ModelOption(
            id: "mlx-community/Qwen3-14B-Instruct-2507-4bit",
            label: "Qwen3 14B (4-bit) — light",
            role: .command,
            approxRamGB: 8.0,
            approxLatencyMs: 1500,
            qualityStars: 4,
            blurb: "Light Command Mode for 32 GB Macs. 'Rewrite this email' quality."
        ),
        ModelOption(
            id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit",
            label: "Qwen3 30B-A3B (shared — default)",
            role: .command,
            approxRamGB: 32.0,
            approxLatencyMs: 800,
            qualityStars: 5,
            blurb: "Reuses the cleanup model. Zero extra RAM if it's already loaded."
        ),
    ]
}
