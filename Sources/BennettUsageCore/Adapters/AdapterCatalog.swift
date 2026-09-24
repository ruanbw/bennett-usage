/// Single source of truth for the adapters shipped with the app.
public enum AdapterCatalog {
    /// Creates a fresh adapter list in the app's established registration order.
    public static var defaults: [any AgentSourceAdapter] {
        [
            OmpAdapter(),
            PiAdapter(),
            ClaudeAdapter(),
            CodexAdapter(),
            ContinueAdapter(),
            GeminiAdapter(),
            AntigravityAdapter(),
            OpenCodeAdapter(),
            RooCodeAdapter(),
            ClineAdapter(),
            QwenCodeAdapter(),
            // Cloud-billed tools: detection-only (Agent Health) until API adapters land.
            CopilotAdapter(),
            CursorAdapter(),
            TraeAdapter(),
            DshAdapter(),
            GooseAdapter(),
            CrushAdapter()
        ]
    }
}
