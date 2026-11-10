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

## Run on Appetize

Appetize accepts only a zipped simulator `.app`, which needs a Mac to build, so the
`appetize-build` workflow produces it. It does not need the sample files.

1. Start `appetize-build` by hand and download `Spike-simulator.zip` from the build's artifacts.
2. Upload the zip on the Appetize upload page and start a session on an iPhone.
3. In the session, use **Upload File** to add a few images and videos. On iOS, Appetize processes
   only PNG, JPEG, GIF and MP4 (up to 50 MB each), so a MOV is ignored.
4. In the app, tap **Run census** and allow full photo access. The `grantPermissions=true` query
   parameter on the app URL grants Photos access without the prompt. Tap again after adding media.

## How it works

`project.yml` is turned into an Xcode project on the CI machine, because one cannot be created
on Windows. The workflow boots a simulator, loads `Samples/` into its photo library, grants the
host app photo access, runs one hosted test, and prints the report. The test writes the same
report to `/tmp/e1_report.txt` as a fallback if the log hides the printed lines. The app shows
the same report on screen, which is what you read on Appetize.

## Predict before you run

Commit a guess first: will any smart album look view-based, and how many assets will it count?
"Not sure" does not count.

## Cost

Each run uses build minutes from the free 500 per month. Read the first run's duration before
running again, and read the whole log before re-running after a failure.
