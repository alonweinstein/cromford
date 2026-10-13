// Clean: vendor hostnames as DATA, not as calls. A CSP connect-src allowlist
// naming a metered vendor is the opposite of a rogue call site — it is the
// security control. Review round 2 flagged this shape as a false positive.
export const contentSecurityPolicy = {
  "connect-src": [
    "'self'",
    "https://api.deepgram.com",
    "https://api.openai.com",
    "https://api.twilio.com",
  ].join(" "),
};

export default contentSecurityPolicy;
