# Checking the Lean proof of the Riemann Hypothesis

On 20 November 2026, Levent Alpöge released a proof of the Riemann Hypothesis written in Lean 4, together with three related results on Dirichlet $L$-functions. This repository records a complete, independent build of that proof on one MacBook Pro.

Lean accepted all 175,187 modules. All five theorems depend only on Lean's three standard axioms ([`record/axioms.txt`](record/axioms.txt)):

```
'riemannHypothesis' depends on axioms: [propext, Classical.choice, Quot.sound]
```

## The statement

`riemannHypothesis` proves `RiemannHypothesis`, which is defined in Mathlib, not in the proof:

```lean
def RiemannHypothesis : Prop :=
  ∀ (s : ℂ) (_ : riemannZeta s = 0) (_ : ¬∃ n : ℕ, s = -2 * (n + 1)) (_ : s ≠ 1), s.re = 1 / 2
```

Every zero of the zeta function other than the trivial zeros $-2, -4, -6, \dots$ has real part $\tfrac12$. The condition $s \neq 1$ excludes the pole.

The proof's own `src/Statements.lean` restates it and states the three results on $L$-functions:

| Theorem | Statement |
|---|---|
| `riemannZeta_eq_zero_re` | the same statement, restated in the project's own file |
| `LFunction_ne_zero_of_half_lt_re` | $L(s,\chi) \neq 0$ for $\mathrm{Re}(s) > \tfrac12$, unless $\chi = 1$ and $s = 1$ |
| `LFunction_eq_zero_re` | if $L(s,\chi) = 0$ and $0 < \mathrm{Re}(s) < 1$, then $\mathrm{Re}(s) = \tfrac12$ |
| `LFunction_eq_zero_re_of_isPrimitive` | the same, for primitive $\chi$ |

## The axioms

- `propext`: two propositions that imply each other are equal.
- `Classical.choice`: the axiom of choice. Lean derives the law of the excluded middle from it.
- `Quot.sound`: related elements become equal in a quotient.

Mathlib uses these throughout. A scan before the build found no `sorry`, `admit`, `axiom`, `native_decide`, `unsafe`, `implemented_by` or `extern` anywhere in the source ([`record/source-scan.txt`](record/source-scan.txt)).

## The build

| | |
|---|---|
| Machine | MacBook Pro, Apple M5 Max, 64 GB |
| System | macOS 27.2.1 |
| Lean | 4.33.1 |
| Mathlib | `0df444a360eaa60ab8c11dca51a86af692955474` |
| Source | `alpo.ge/lean.tar.gz.part01`–`part14`, SHA-256 `9631b4f0…49c7fc` |
| Isolation | sandboxed, no network |
| Duration | 20 Nov 20:35 to 24 Nov 23:06 PST, about 88 hours of building |
| CPU | about 600 CPU-hours |

The archive's hashes ([`record/SHA256SUMS`](record/SHA256SUMS)) match those published by other builders. No source file was changed.

Two limits of macOS shaped the run. Both are described in [`record/NOTES.md`](record/NOTES.md).

- **Opening files set the pace, not computation.** Each module loads about 8,700 Mathlib modules before checking its own contents.
- **The last modules exceeded the default vnode limit.** They import nearly the whole project, and Lean holds a vnode for every file it maps. Raising the limit with `sudo sysctl kern.maxvnodes=600000` resolved it.

## What is trusted

The check trusts Lean's kernel, the toolchain binaries, and Mathlib, which was downloaded prebuilt rather than rebuilt here. It does not include a second check by an independent kernel.

What a reader must check by hand is the statements: that `src/Statements.lean` and the Mathlib definitions it uses say what they claim.

## Reproducing

On a Mac with [elan](https://github.com/leanprover/elan) and 150 GB free:

```bash
sudo sysctl kern.maxvnodes=600000
./verify-rh.sh all
```

The script downloads and hash-checks the source, builds it in a sandbox with no network, and prints the axioms. It can be stopped and resumed at any point; `./verify-rh.sh status` reports progress. Expect the build to take days.

## Contents

```
verify-rh.sh              the script that ran every step
record/
  axioms.txt              the result
  AxiomCheck.lean         the file that produced it
  SHA256SUMS              hashes of the source archive
  source-scan.txt         the scan of the source before the build
  environment.txt         machine, system and toolchain
  olean-sha256.txt.gz     a hash of every compiled module, for comparison
  build-summary.log.gz    every module built, with errors and timings
  progress.tsv            modules checked, every 10 minutes
  module-count            the number of modules in the source
  cache.log, run.log      Mathlib download; run log
  NOTES.md                observations, in the order they were made
```
