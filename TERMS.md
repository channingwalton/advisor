# Advisor — Terms of Use

**Version 1.0 — 5 July 2026**

These terms are an agreement between you and Monoidal Ltd ("we", "us"), a
company registered in England and Wales, and they govern your download and use
of the Advisor app for macOS ("Advisor"). By downloading, installing or using
Advisor you agree to these terms. If you do not agree, do not use Advisor.

## 1. Licence

Advisor is open-source software released under the MIT licence, whose full
text is in the LICENSE file in Advisor's source code. Under it you may use,
copy, modify, merge, publish, distribute, sublicense and sell copies of
Advisor. Nothing in these terms takes away a right the MIT licence gives you.

## 2. Beta software

Advisor is currently a free beta. Beta features may change or be removed, and
beta builds may contain defects.

## 3. AI agents act on your Mac, under your control

Advisor runs AI agents locally on your Mac using your own AI provider account
(Anthropic Claude or OpenAI Codex). Depending on your settings, those agents
can:

- search and fetch content from the web;
- read from and search connectors (MCP servers) you have configured;
- read non-sensitive files in your home folder — agents are blocked from
  credential and key locations such as `~/.ssh`, `~/.aws`, `~/.gnupg` and your
  keychains, and cannot write to or delete anything outside their own working
  state;
- perform connector actions (send / create / update / …) — but only if you
  enable "Allow connector actions" in Preferences, which is off by default.

On the Codex backend those bounds are enforced differently, and some more
coarsely. Advisor runs the Codex CLI inside a macOS sandbox that applies the same
blocked locations and the same write restriction to the CLI and to everything it
starts, including the read-only shell commands the Codex agent can run (the
Claude backend has no shell). Codex cannot tell a connector read from an action,
so with "Allow connector actions" off it gets no connectors at all (those in
your own `~/.codex/config.toml`, those its plugins bring, and ChatGPT apps), and
with it on it gets all of them, actions included. A connector you add to
`~/.codex/config.toml` during a recording may be available to Codex until the
next recording. The Codex agent can also read its own stored provider
credentials in `~/.codex`, which must stay readable for it to sign in. If any of
this matters to you, use the Claude backend, which applies every restriction
in-process and per tool call.

You decide which connectors Advisor can reach and which permissions are
enabled, and you are responsible for those choices and for the consequences of
actions agents take within the permissions you have granted. Advisor's
sandboxing of agents is best-effort, not a guarantee: AI systems can behave
unpredictably, so do not attach connectors or enable actions whose misuse you
are not prepared to accept.

## 4. AI output can be wrong

Cards, answers, summaries, fact-checks and transcripts are produced
automatically. They can be incomplete, out of date or simply wrong — including
fact-check verdicts and quoted sources. Advisor's output is not professional
advice (legal, medical, financial or otherwise). Verify anything important
before relying on it or repeating it.

## 5. Recording and consent

Advisor records and transcribes audio: your microphone and, if enabled, other
applications' audio on your Mac. Laws on recording conversations vary by
country and in some places require the consent of everyone being recorded. You
are solely responsible for using Advisor lawfully — including telling
participants they are being recorded and obtaining consent where required. We
accept no responsibility for recordings you choose to make.

## 6. Your data

Sessions, transcripts and settings are stored locally on your Mac, and
transcription happens on-device. We do not receive or store your recordings or
transcripts. Text is sent to the AI provider you configured, under that
provider's own terms and privacy policy: while Auto cards is on, the live
transcript (including notes you add) is sent as the conversation goes on;
cards and questions also send the session's context and the conversation so
far; questions about a saved session send its transcript; and the contents of
any home-folder files or connector results agents read are sent too. You are
responsible for backing up your data.

## 7. Third-party services

Advisor relies on your accounts with third parties — your AI provider
(Anthropic or OpenAI) and any connectors you attach. Your use of those
services is governed by their terms, and any charges they levy are yours to
pay. We are not responsible for the availability, behaviour or output of
third-party services.

## 8. Acceptable use

Use Advisor only where it is lawful to do so, and do not use it to infringe
the rights of others — including their privacy and intellectual-property
rights.

## 9. No warranty

Advisor is provided **"as is" and "as available"**. To the fullest extent the
law allows, we make no warranties or promises about Advisor — including that
it will be uninterrupted, error-free or fit for any particular purpose. This
does not affect the statutory rights described in section 11.

## 10. Our liability

Nothing in these terms excludes or limits our liability for death or personal
injury caused by our negligence, for fraud, or for anything else that cannot
be excluded under the law of England and Wales.

Subject to that, we are not liable for: indirect or consequential loss; loss
of profits, business, data or goodwill; the content or consequences of AI
output; actions taken by AI agents within the permissions you granted;
recordings you make; or third-party services. Our total liability to you in
connection with Advisor is limited to the amounts you have paid us for it in
the 12 months before the claim arose, or £25 if you have paid nothing.

If you are a consumer, nothing in this section takes away rights the law gives
you that cannot be limited by contract.

## 11. Consumers' statutory rights

If you are a consumer in the UK, digital content must be as described, fit for
purpose and of satisfactory quality, and you may be entitled to a repair,
replacement or refund if it is faulty. These terms do not limit those rights.

## 12. Termination

You can end the agreement at any time by deleting Advisor.

## 13. Changes to these terms

We may update these terms — the version and date appear at the top, and the
current version is always at
[advisor.monoidal.co.uk/terms.html](https://advisor.monoidal.co.uk/terms.html).
Advisor will ask you to accept material changes before continuing.

## 14. Governing law

These terms are governed by the law of England and Wales, and the courts of
England and Wales have jurisdiction — except that if you are a consumer you
keep any protections, and access to your local courts, that your local law
grants you.

## 15. Contact

Questions about these terms: see
[advisor.monoidal.co.uk](https://advisor.monoidal.co.uk).
