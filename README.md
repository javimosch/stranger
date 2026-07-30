# stranger

**Does your published tool work for someone who has none of your context?**

Your test suite builds from source, in the repository, on a machine with the
toolchain installed. None of that describes the person who found your README.
They have a URL, a shell, and no reason to debug you.

`stranger` walks that path instead. It fetches the **published** artifact into an
empty directory with no repository, no toolchain and a throwaway `HOME`, then
checks that it runs and that it is **what the README says it is**.

```sh
./stranger.sh javimosch/grange
./stranger.sh javimosch/vigie --repo-dir ~/ai/vigie
```

```
  ok   the README is reachable (a stranger reads this first)
  ok   the documented download URL resolves (http 200)
  ok   the download is a plausible binary (7512192 bytes)
  ok   the artifact executes here (no toolchain, no repo, empty HOME)
  ok   the README promises static, and the published binary is static
  ok   no glibc floor, as promised
  ok   guide is valid JSON, so an agent can drive it cold
  ok   a mistyped verb exits non-zero (80), so a typo is detectable
{"ok":true,"repo":"javimosch/grange","failures":0,"warnings":0,"notes":""}
```

## Why

A tool of mine had a documented install command that had **never worked**. It
pointed at an asset name no release had published, so `curl` wrote 9 bytes of
`Not Found`, `chmod +x` accepted it, and the tool answered
`Not: command not found`. It shipped that way for its entire life.

Nothing was going to catch it. Release downloads were zero — which reads as "no
adoption" and is indistinguishable from "the install is broken", and **a funnel
with no users is also a funnel with no bug reports**.

Run across eighteen of my own repositories, it then found:

- **two shipped products** whose READMEs promised "one static binary" while
  publishing dynamically linked ones needing `libssl`, `libcrypto`, `libsqlite3`
  and glibc 2.34+ — they could not have started on Debian 11, Ubuntu 20.04,
  RHEL 8, Alpine, or a slim container
- one whose README **contradicted itself** — "one static binary" in the headline,
  "needs libssl3 + libsqlite3" four paragraphs down, and the binary needed more
  than either admitted
- **four** publishing binaries on every release that their READMEs never
  mentioned, so the documented way in was "install the toolchain and build"
- one CLI where a **mistyped verb printed usage to stdout and exited 0**, so an
  agent could not tell a typo from success

Eight of those were live. None had ever been reported.

## What it checks

| | |
|---|---|
| **the documented URL**, verbatim | not one reconstructed from the API — whether what is *written down* works |
| **install scripts** | `curl … install.sh \| bash` is a real install path; it is fetched and matched against a published asset |
| **it executes** | in an empty dir, no toolchain, empty `HOME` — where a dynamic build meets a machine that lacks your libraries |
| **artifact vs claim** | static/no-dependency promises are read out of the README and checked against `ldd` and the glibc floor |
| **the agent contract** | `guide` and `help-json` are valid JSON from a cold artifact ([cli-guide-spec](https://github.com/javimosch/cli-guide-spec)) |
| **typos fail** | a nonsense verb must exit non-zero ([cli-output-spec](https://github.com/javimosch/cli-output-spec)) |
| **no artifact** | fine if the README documents building; a failure if it promises a binary and offers no way to get one |

The checks that matter are the ones comparing the artifact to the **claim**. A
dynamically linked binary is not a bug. A dynamically linked binary under a
paragraph promising no runtime dependencies is.

## What it does not do

It cannot run your tool's actual workflow — it does not know your verbs. It
checks the universal surface: download, execute, linkage, the agent-first
contract, exit codes. For the rest, write a journey test in your own repo.

It also trusts `ldd` and `objdump`, so run it on Linux.

## Honest notes

Three of its own checks were wrong before they were right, each in the way that
matters — **passing when they should have failed**:

- `ldd` reports *"not a dynamic executable"* for a text file and `objdump` finds
  no GLIBC symbols in one, so a 404 error page scored **"static, as promised"**.
  Linkage checks are now gated on the artifact actually running.
- A tool documenting `install.sh` was reported as having undocumented assets.
  Install scripts are a real path and are followed now.
- "Claims static, ships nothing" was reported as a broken promise for a project
  whose README says *"no public instance and none is planned. Clone it, build it,
  own your own"* — where the claim describes the build output and is true. That
  is now a warning, not a failure. **A checker that flags honest projects teaches
  you to ignore it.**

And it was itself fooled by a tool that exits 0 on unknown verbs: it concluded
that tool had a `guide` command, because asking for one succeeded. That is now a
check of its own.

MIT. One bash file, no dependencies beyond `curl`, `python3`, `ldd`, `objdump`.
