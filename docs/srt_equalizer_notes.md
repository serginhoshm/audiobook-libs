# SRT Equalizer Notes

## Purpose

[`srt_equalizer`](https://github.com/peterk/srt_equalizer) is a small Python utility for reflowing subtitle lines into shorter, more readable chunks.
It is especially useful when Whisper produces long or awkward subtitle segments that are valid, but not ideal for downstream text-to-speech.

The library is MIT licensed and already includes heuristics for:

- splitting long lines into shorter fragments
- keeping punctuation attached to the preceding fragment when possible
- handling quoted text more safely than a naive word split
- preserving subtitle timing while redistributing the time across the new fragments

## Why It Fits This Project

The current audiobook pipeline already has a clear handoff:

- Whisper generates the source `.srt`
- translation generates `.srtpt`
- Piper reads the subtitle text and synthesizes audio

That makes this library a good candidate for a pre-Piper normalization step.
It does not fix recognition errors in Whisper, but it can improve sentence chunking before synthesis, which may reduce unnatural breaks and isolated word fragments in the TTS output.

## Proposed Integration Later

If we decide to integrate it into the main pipeline later, the safest place is between translation and Piper synthesis.

Suggested shape:

1. Keep the original translated SRT unchanged.
2. Generate an intermediate equalized SRT for TTS only.
3. Default to the `punctuation` method, with a conservative character limit.
4. Make the feature optional so it can be enabled only for problematic inputs.

Suggested configuration knobs:

- `enabled`: turn the equalization step on or off
- `method`: `punctuation`, `halving`, or `greedy`
- `target_chars`: line length threshold, default around 42
- `apply_to`: translated subtitles only, by default

## Current Test Workflow

For now we will test this as an external workflow, not as a pipeline integration.

The workflow script will:

- accept one input SRT/SRTPT file
- produce a sibling output file with ` (improved)` inserted before the extension
- leave the original file untouched
- call `srt_equalizer.equalize_srt_file(...)` under the hood

Example:

```text
input:  ABelaAdormecida.srtpt
output: ABelaAdormecida (improved).srtpt
```

## Setup Expectation

The script assumes `srt_equalizer` is available in the active Python environment.
That can be done either by installing the package from PyPI or by pointing the workflow to a local clone via `PYTHONPATH`.

## Practical Recommendation

Use the script on a small sample set first and compare:

- original translated SRT
- equalized SRT
- resulting Piper audio

If the equalized version yields smoother phrasing without fragmenting meaning, then it becomes a good candidate for an optional pipeline step.