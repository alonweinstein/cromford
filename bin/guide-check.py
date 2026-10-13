#!/usr/bin/env python3
"""bin/guide-check.py — the install guide's own checks.

The guide is docs/guide.md plus every page it links, in that order. This reads
the page list from docs/guide.md, so the index is the only list, and checks:

  1. links     every relative link resolves to a file under the root, every
               #anchor resolves to a heading (GitHub slug rules), and every
               external link is https://. GUIDE_CHECK_ONLINE=1 also fetches
               each external link (HEAD, then GET) and fails on 4xx/5xx.
  2. referral  no affiliate or referral link anywhere in the guide.
  3. shape     each service section of optional-services.md has the six
               fields, there are seven of them, and the page ends with the
               "At a glance" table.
  4. settings  every backticked UPPER_SNAKE name is in
               env-templates/selfhost.conf.example, or in a file the page
               links or names by path.
  5. paths     every bin/, env-templates/, catalog/, docs/ or tests/ path a
               page names exists under the root, or under
               bin/share/overlay/, which the public copy puts at the root.
  6. refs      no internal tracker ids (#123, ABC-123) on a guide page.

Python 3, stdlib only: the public copy ships this without bin/share/.

usage: bin/guide-check.py [--root DIR]
exit:  0 clean, 1 one or more failures (each printed as "file: reason")
"""
import os
import re
import sys
import urllib.error
import urllib.request

FIELDS = ["What it is.", "What it adds.", "When you want it.",
          "How to sign up.", "How to switch it on.", "Free tier."]
SERVICES = 7
TABLE_HEADER = ["Service", "What it's for", "Required?", "Setting"]
PROGRAMS_NOTE = "Programs change; check the vendor's page."
REFERRAL = re.compile(
    r"[?&]((ref|via|aff|affiliate|referral|referrer)(_[a-z]+)?|utm_[a-z]+)="
    r"|[?&]referral\b", re.I)
REFERRAL_HOSTS = ("dub.sh", "partners.dub.co", "refer.", "rewardful")
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
URL = re.compile(r"https?://[^\s)\"'`]+")
CODE_SPAN = re.compile(r"`([^`]+)`")
SETTING = re.compile(r"^([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)(?:=\S*)?$")
PATH = re.compile(r"(?<![\w./-])((?:bin|env-templates|catalog|docs|tests)/[\w./-]+)")
TICKET = re.compile(r"(?:^|[\s(])(#\d+)\b|\b([A-Z]{2,}-\d+)\b")
NOT_TICKETS = {"UTF", "SHA", "ISO", "RFC", "CVE"}
OVERLAY = os.path.join("bin", "share", "overlay")


def split_code(text):
    """(prose lines, code lines): fenced blocks go to code, never to prose."""
    prose, code, fenced = [], [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        (code if fenced else prose).append(line)
    return prose, code


def slugs(text):
    """GitHub heading anchors: lowercase, punctuation dropped, spaces to -."""
    seen, out = {}, set()
    for line in split_code(text)[0]:
        m = re.match(r"#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", m.group(1)).replace("`", "")
        s = re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-")
        n = seen.get(s, 0)
        seen[s] = n + 1
        out.add(s if n == 0 else f"{s}-{n}")
    return out


def found(root, path):
    """The file a page's path names, or None. The public copy also carries
    bin/share/overlay/<path> at <path>, so a path the overlay supplies counts."""
    for p in (os.path.join(root, path), os.path.join(root, OVERLAY, path)):
        if os.path.exists(p):
            return p
    return None


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def online(url):
    for method in ("HEAD", "GET"):
        req = urllib.request.Request(url, method=method,
                                     headers={"User-Agent": "guide-check/1"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return None if r.status < 400 else f"HTTP {r.status}"
        except urllib.error.HTTPError as e:
            err = f"HTTP {e.code}"
        except Exception as e:  # DNS, TLS, timeout: all a dead link
            err = type(e).__name__
    return err


def check_page(root, rel, text, fails):
    here = os.path.dirname(os.path.join(root, rel))
    prose, code = split_code(text)
    prose_text = "\n".join(CODE_SPAN.sub("``", l) for l in prose)
    linked = []
    for target in LINK.findall(prose_text):
        if target.startswith("http://"):
            fails.append(f"{rel}: link {target} is not https://")
        elif target.startswith("https://") or target.startswith("mailto:"):
            continue
        else:
            path, _, anchor = target.partition("#")
            dest = os.path.normpath(os.path.join(here, path)) if path else os.path.join(root, rel)
            if not os.path.isfile(dest) or not dest.startswith(os.path.abspath(root) + os.sep):
                fails.append(f"{rel}: link {target} does not resolve to a file")
                continue
            linked.append(dest)
            if anchor and dest.endswith(".md") and anchor not in slugs(read(dest)):
                fails.append(f"{rel}: link {target} names no heading #{anchor}")
    for url in sorted(set(URL.findall(text))):
        url = url.rstrip(".,;:>")
        host = url.split("/")[2].lower() if url.count("/") >= 2 else ""
        if REFERRAL.search(url) or any(host == h or host.startswith(h) or h in host
                                      for h in REFERRAL_HOSTS):
            fails.append(f"{rel}: referral link {url}")
        elif ("<" not in url and url.startswith("https://")
              and os.environ.get("GUIDE_CHECK_ONLINE") == "1"):
            err = online(url)
            if err:
                fails.append(f"{rel}: link {url} answered {err}")
    paths = sorted(set(p.rstrip(".,:;") for p in PATH.findall(text)))
    named = [found(root, p) for p in paths if "*" not in p]
    template = os.path.join(root, "env-templates", "selfhost.conf.example")
    known = "\n".join(read(p) for p in [template] + linked + named
                      if p and os.path.isfile(p))
    for span in CODE_SPAN.findall("\n".join(prose)):
        m = SETTING.match(span.strip())
        if m and not re.search(r"\b%s\b" % m.group(1), known):
            fails.append(f"{rel}: setting {m.group(1)} is not in "
                         "env-templates/selfhost.conf.example or a linked file")
    for path in paths:
        if "*" not in path and not found(root, path):
            fails.append(f"{rel}: path {path} does not exist")
    for ref in TICKET.findall("\n".join(prose)):
        ref = ref[0] or ref[1]
        if ref.split("-")[0] not in NOT_TICKETS:
            fails.append(f"{rel}: internal ticket ref {ref}")


def check_services(rel, text, fails):
    prose = split_code(text)[0]
    sections, cur = [], None
    for line in prose:
        if line.startswith("## "):
            cur = [line[3:].strip(), []]
            sections.append(cur)
        elif cur:
            cur[1].append(line)
    services = [s for s in sections if s[0].lower() != "at a glance"]
    if len(services) != SERVICES:
        fails.append(f"{rel}: {len(services)} service sections, expected {SERVICES}")
    for name, body in services:
        body = "\n".join(body)
        for field in FIELDS:
            if f"**{field}**" not in body:
                fails.append(f"{rel}: section {name} has no **{field}** field")
        if PROGRAMS_NOTE not in body:
            fails.append(f"{rel}: section {name} has no \"{PROGRAMS_NOTE}\" line")
    rows = [l for l in prose if l.strip()]
    table = []
    for line in reversed(rows):
        if not line.lstrip().startswith("|"):
            break
        table.insert(0, line)
    header = [c.strip() for c in table[0].strip().strip("|").split("|")] if table else []
    if header != TABLE_HEADER:
        fails.append(f"{rel}: does not end with the table "
                     f"\"{' | '.join(TABLE_HEADER)}\"")


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if argv[:1] == ["--root"] and len(argv) == 2:
        root = os.path.abspath(argv[1])
    elif argv:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 1
    index = os.path.join(root, "docs", "guide.md")
    if not os.path.isfile(index):
        print("docs/guide.md: missing, so there is no page list to check")
        return 1
    pages = ["docs/guide.md"]
    for target in LINK.findall(CODE_SPAN.sub("``", "\n".join(split_code(read(index))[0]))):
        path = target.partition("#")[0]
        if path.endswith(".md") and not target.startswith("https://"):
            rel = os.path.relpath(os.path.normpath(os.path.join(root, "docs", path)), root)
            if rel not in pages:
                pages.append(rel)
    fails = []
    for rel in pages:
        if not os.path.isfile(os.path.join(root, rel)):
            continue  # the index's own link check names it
        text = read(os.path.join(root, rel))
        check_page(root, rel, text, fails)
        if os.path.basename(rel) == "optional-services.md":
            check_services(rel, text, fails)
    for f in fails:
        print(f)
    print(f"guide-check: {len(pages)} pages, {len(fails)} failures")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
