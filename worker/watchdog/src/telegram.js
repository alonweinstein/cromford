// The watchdog's one way to speak. Direct Bot API call from the worker: no LLM,
// no fleet box, no console relay in the path. Fleet-level alerts land in the
// Fleet topic of the the operator Harness group (message_thread_id from
// TELEGRAM_THREAD_ID; unset = General).
//
// Returns whether Telegram TOOK the message (res.ok). Never throws: a Telegram
// outage must not throw out of the cron that is judging the fleet. A caller
// that records "paged" (K2's progress incidents) records it only on true, so a
// failed send is retried next tick instead of remembered as delivered.
export async function tg(env, text) {
  try {
    const res = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        chat_id: env.TELEGRAM_CHAT_ID,
        text,
        ...(env.TELEGRAM_THREAD_ID ? { message_thread_id: Number(env.TELEGRAM_THREAD_ID) } : {}),
      }),
    });
    return !!(res && res.ok);
  } catch {
    return false;
  }
}
