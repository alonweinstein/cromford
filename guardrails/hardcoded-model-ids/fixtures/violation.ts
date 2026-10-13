// Seeded violation: the model id is decided at deploy time, in code.
import { anthropic } from "./client";

export async function summarize(text: string) {
  return anthropic.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 1024,
    messages: [{ role: "user", content: text }],
  });
}

export const FALLBACK = "gpt-4o-mini";
