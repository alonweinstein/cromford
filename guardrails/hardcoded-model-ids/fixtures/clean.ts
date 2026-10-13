// Clean: the model comes from the per-agent config row at runtime.
import { anthropic } from "./client";
import { resolveModel } from "@/lib/agents/model-selector";

export async function summarize(text: string) {
  return anthropic.messages.create({
    model: await resolveModel("summarizer", "content"),
    max_tokens: 1024,
    messages: [{ role: "user", content: text }],
  });
}
