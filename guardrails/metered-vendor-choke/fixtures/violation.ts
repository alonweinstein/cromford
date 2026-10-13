// Seeded violation: a per-minute-billed vendor called straight from a cron
// lane, with the ledger write AFTER the response — the money is already gone.
export async function transcribe(recording: { id: string; url: string }) {
  const res = await fetch("https://api.deepgram.com/v1/listen?model=nova-3", {
    method: "POST",
    headers: { Authorization: `Token ${process.env.DEEPGRAM_KEY}` },
    body: JSON.stringify({ url: recording.url }),
  });
  const json = await res.json();
  if (json?.results) {
    await db.transcript.create({ data: { recordingId: recording.id, json } });
  }
  return json;
}

declare const db: any;
