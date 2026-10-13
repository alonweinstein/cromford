// agents/summarize.js — summarise one ticket thread for the board.
import { resolveModel } from "../lib/model-config.js";
import { withHumanVoice } from "../lib/voice.js";

export async function summarize(client, thread) {
  const model = await resolveModel("summarize");
  const res = await client.messages.create({
    model,
    max_tokens: 800,
    messages: [{ role: "user", content: withHumanVoice(thread) }],
  });
  return res.content[0].text;
}
