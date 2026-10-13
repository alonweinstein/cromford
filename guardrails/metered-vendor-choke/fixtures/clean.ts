// Clean: the call site never talks to the vendor. It goes through the shared
// metered client, which checks the ledger BEFORE spending and writes a terminal
// row on every non-success path.
import { meteredTranscribe } from "@/lib/metered/transcribe";

export async function transcribe(recording: { id: string; url: string }) {
  const result = await meteredTranscribe({
    fingerprint: recording.id,
    url: recording.url,
  });
  if (result.status === "ok") {
    await db.transcript.create({
      data: { recordingId: recording.id, json: result.json },
    });
  }
  return result;
}

declare const db: any;
