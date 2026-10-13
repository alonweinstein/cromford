# The Cromford guide

## What Cromford is

Cromford watches your boards. When a ticket comes in, it reads the whole
thread and decides whether the ticket is ready to build. A ready ticket gets a
written plan, a build on its own branch, and a review by a separate session.
The result is a pull request. Merges go through Cromford's own gates, never
straight from a build.

You run it on your own accounts: GitHub, Cloudflare, Fly or a VM you already
have, and a key for at least one model vendor.

## Read it in this order

1. [Quickstart](quickstart.md)
2. [Deployment guide](SELF-HOST.md)
3. [Connecting a board](connecting-a-board.md)
4. [Onboarding a repo](onboarding-a-repo.md)
5. [Choosing models](choosing-models.md)
6. [Optional services](optional-services.md)
7. [Spending caps](spending-caps.md)
8. [Upgrading](upgrading.md)

`bin/guide-check.py` checks every page on this list: links, anchors, the
settings and paths each page names, and that no link carries a referral code.
