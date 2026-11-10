# Spike E1: Photos census (read-only)

Throwaway code. On a simulator it reports what the Photos framework exposes: the access level,
asset counts by type, and which smart albums exist, looking for anything that tracks viewing.
It writes nothing to the library.

## Run

1. Generate the synthetic media once, then commit `sample.mov` and `sample.jpg`:
   `powershell -File Samples/make_samples.ps1` (needs ffmpeg with libx265).
2. Push the repository to a private GitHub repository and add it in Codemagic, choosing the
   project type that uses `codemagic.yaml`.
3. Check for the configuration file, then start the `spike-e1` workflow by hand. It has no
   trigger, so nothing builds on push.
4. Read the log lines that start with `E1:`.

## How it works

`project.yml` is turned into an Xcode project on the CI machine, because one cannot be created
on Windows. The workflow boots a simulator, loads `Samples/` into its photo library, grants the
host app photo access, runs one hosted test, and prints the report. The test writes the same
report to `/tmp/e1_report.txt` as a fallback if the log hides the printed lines. The app also shows
the same report on screen.

## Predict before you run

Commit a guess first: will any smart album look view-based, and how many assets will it count?
"Not sure" does not count.

## Cost

Each run uses build minutes from the free 500 per month. Read the first run's duration before
running again, and read the whole log before re-running after a failure.
