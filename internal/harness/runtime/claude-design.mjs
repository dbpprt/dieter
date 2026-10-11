// Claude Design belongs to the daemon host's Claude account. It now lives in
// Claude artifacts (designs, slides and documents); the standalone
// claude.ai/design site closes on 2026-12-14. Dieter enables these native
// Claude Code tools only after the operator allowed Claude Design on this
// machine; otherwise every one of them is denied before the turn starts.
export const CLAUDE_ARTIFACT_TOOLS = Object.freeze(["Artifact", "ArtifactComments", "ArtifactData", "ArtifactCheck"]);
export const CLAUDE_DESIGN_TOOLS = Object.freeze(["DesignSync", "ClaudeDesign", ...CLAUDE_ARTIFACT_TOOLS]);

function enabled(request, adapter) {
  return adapter === "claude-code" && request.claudeDesignEnabled === true;
}

export function claudeDesignInactiveTools(request, adapter) {
  return adapter === "claude-code" && !enabled(request, adapter) ? [...CLAUDE_DESIGN_TOOLS] : undefined;
}

// Claude Code offers its artifact tools to agent sessions only when asked to.
export function claudeDesignEnvironment(request, adapter) {
  return enabled(request, adapter) ? { CLAUDE_CODE_ARTIFACT: "1" } : {};
}

export function claudeDesignInstructions(request, adapter) {
  if (!enabled(request, adapter)) return "";
  return [
    "Claude Design is connected on this machine. It lives in Claude artifacts: create and update designs, slide decks and documents with the Artifact tool (types design, slides, document), and publish them to the user's Claude account.",
    "Use it only when the user asks for visual design work. Never change who can see an artifact or project, invite people, or delete anything unless the user explicitly asks; report the resulting link.",
    request.contentPresentationEnabled
      ? "After you publish or update an artifact, call present_content with its https://claude.ai/code/artifact/<id> or https://claude.ai/artifact/<id> link so the user can open it."
      : "",
  ]
    .filter(Boolean)
    .join(" ");
}
