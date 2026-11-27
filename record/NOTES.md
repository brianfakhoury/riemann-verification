# Run notes

Raw observations for the write-up, in order. Times are local (PST) on 2026-11-20
unless stated.

## Inputs
- Archive: `https://alpo.ge/lean.tar.gz.part01` … `part14`, 239 MB joined.
  Joined SHA-256 matches the pinned value; per-part hashes are in `SHA256SUMS`
  and all 14 match the list published by Hertaspace/alpoge-rh-lean-verification.
- 175,187 `.lean` files, 1.3 GB unpacked. `lakefile.toml` is declarative; the
  only direct dependency is Mathlib at `0df444a3…` from the official repository.
- Source scan: `source-scan.txt`.

## Build configuration
- `lake build Main`, 12 jobs (`LEAN_NUM_THREADS=12`), utility QoS clamp
  (`taskpolicy -c utility`), `caffeinate -ims`.
- Sandboxed with `sandbox-exec`: no network, writes confined to the work
  folder, no reads of credential or personal folders.
- Started 20:35, restarted 20:40 and 21:01 (see below). Lake resumes, so no
  finished module was rebuilt.

## Finding 1: the build is bound by file opens, not CPU
- A typical early module (`Formalism.ZetaNonvanishing.LandauEq`, 75 lines)
  compiles standalone in 9.8 s; `lean --profile` attributes 8.2 s to import and
  under 1 s to elaboration.
- Each module loads about 8,700 Mathlib modules, three files each (`.olean`,
  `.olean.server`, `.olean.private`), so about 26,000 opens per compile job.
- `sample` of a compile job: about 60% of main-thread samples in `open`.
- Bare `import Mathlib`, jobs in parallel, throughput in imports per minute
  (build paused during the test):

  | jobs | wrapper                 | seconds each | imports/min |
  |-----:|-------------------------|-------------:|------------:|
  |    1 | none                    |          6.0 |          10 |
  |    6 | none                    |         10.2 |          35 |
  |   12 | none                    |         13.2 |          54 |
  |   18 | none                    |         18.7 |          58 |
  |   12 | sandbox                 |         16.0 |          45 |
  |   12 | utility clamp           |         24.7 |          29 |
  |   12 | sandbox + utility clamp |         28.4 |          25 |
  |    6 | sandbox + utility clamp |         16.0 |          22 |

- A fresh C program opening and mapping the same 8,700 `.olean` files takes
  0.7 to 0.9 s alone (about 84 µs per open) and 1.7 s with 12 copies in parallel.
- The machine is managed and runs endpoint-security extensions that inspect
  file opens; one was at about 90% CPU during the build. They were left
  untouched. Likely the reason opens are slow here; not proven.
- Observed build rate in the first 15 minutes: 257 modules, about 17 per minute,
  with total `lean` CPU of only 3 to 5 cores across 12 jobs.

## Finding 2: Lake's setup files would exhaust the disk
- Lake writes `<module>.setup.json` (about 6.4 MB, the full list of import
  artifacts) for every module: about 1.1 TB over the whole project.
- Real outputs after 327 modules: `.olean` mean 591 KB (median 272 KB, max
  29.6 MB), `.ilean` 27 KB, `.c` 9 KB.
- Lake's trace records only the `.olean`, `.ilean` and `.c` outputs. After
  deleting a finished module's setup file, `lake build +Module --no-build`
  still reports "All targets up-to-date".
- `verify-rh.sh tidy` removes setup files of modules whose trace exists; a loop
  runs it every two minutes. This is the only departure from a plain
  `lake build`.

## Housekeeping
- An accidental `lake --help` outside the project made elan install Lean
  4.36.0; it was uninstalled. Only v4.33.1 was used.
- Spotlight indexed the new source tree during the first minutes (mds at 300 to
  400% CPU), then went quiet.

## Change at 21:08: utility clamp removed
- With the owner's agreement the QoS clamp was dropped (12 jobs and the
  sandbox stay). Build log lines `=== build started … qos=none ===` mark it.
- First 15 minutes afterwards: 466 modules, about 31 per minute (up from 17),
  total `lean` CPU of 7 to 8 cores, zero errors.

## CPU accounting (added 2026-11-23 10:10)
- Not measured exactly before this point. From `build.log`: 136,215 modules
  built, 718 job-hours of per-module wall time (mean 19 s). Observed `lean` CPU
  was 7 to 8 cores across 12 jobs, so roughly 0.6 CPU per job.
- From the next resume on, the build runs under `/usr/bin/time -l`, which
  prints exact user and system CPU (all descendants) to `build.log` each time
  the build stops. That gives an exact figure for the remaining modules and a
  measured CPU-per-job-second ratio to apply to the earlier part.

## Incident 2026-11-24 05:32: system file table overflow
- For about 10 seconds the system-wide open-file table was full
  ("Too many open files in system" / "file table overflow", ENFILE;
  `kern.maxfiles` = 491,520). 11 modules failed to open Mathlib `.olean`
  files, 4 failed to start, and 10 dependents failed with "bad import".
  All 25 were in `…ThetaParseval.ThetaKernels` / `HalfIndexLattices`.
  None was an elaboration or kernel error. Cause not identified;
  `kern.num_files` was 67,082 when checked at 10:58.
- Lake carried on with independent modules. At 11:00 the build was restarted
  (`=== build started 2026-11-24T19:00:06Z ===`); all retried modules built
  without error. No source was changed.
- Paused 2026-11-24 11:21 at the owner's request, 173,698 / 175,187 modules.

## Finding 3: the last modules exceed macOS's system open-file limit
- The final modules import almost the whole project (`TopMainZj` lists
  166,292 import artifacts; `Main` imports everything). One `lean` process
  then needs more open files than the system table allows
  (`kern.maxfiles` = 491,520, about 78,000 already used by other apps).
- 20:01 (12 jobs): 36 failures; 20:55 (6 jobs): 1 failure; 21:05 (1 job):
  `TopMainZj` still fails with "Too many open files in system". Every failure
  is ENFILE or a knock-on "bad import". 8 modules remain.
- Correction (21:40): the open-file table is not the limit. A probe rerun of
  `TopMainZj` peaked at 78,293 `kern.num_files` while still failing. The
  module opens about 175,000 files (`importArts`), and Lean memory-maps each
  `.olean`, which pins a vnode after the file is closed. `kern.maxvnodes` is
  263,168 and was fully allocated (about 91,000 in use elsewhere), so the
  kernel returns ENFILE ("Too many open files in system") when it cannot get
  a vnode.
- Fix needs the owner to raise `kern.maxvnodes` (temporary, reset at reboot).
- 22:50: owner ran `sudo sysctl kern.maxvnodes=600000` (resets at reboot).
  Build resumed at 22:51 with 2 jobs and finished cleanly at 23:06.

## Result (2026-11-24 23:08)
- `lake build Main` exited 0. `axioms.txt`: all five theorems depend only on
  `propext`, `Classical.choice`, `Quot.sound`. Verdict: PASS.
- `olean-sha256.txt.gz`: 175,187 compiled modules hashed.
