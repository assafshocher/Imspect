# Imspect 0.2.1

- Anchor the sidebar, comparison canvas, and inspector to the full window width, including after Play/Pause, mode changes, and full-screen-sized window changes.
- Use fill distributions for the structural stacks instead of gravity-area packing.
- Show the running version next to Imspect in the header, making outdated copies easier to identify.
- Add 588 layout checks across 42 transitions and five window sizes; reproduce the former 515-point canvas collapse through AppKit's ambiguous-layout solver.
- Preserve outer application bundle identity during updates so launch aliases do not follow a retained outdated backup.

# Imspect 0.2.0

- Editing preserves the selected image and inspector scroll position; playback pauses before editing.
- Delete/Backspace removes the selected image when the sidebar has focus.
- Every zoom uses the chosen interpolation kernel on a bounded visible patch; changing kernels updates the preview without changing stored pixels.
- Live RGB channel sliders replace channel-removal commands: off / original / maximum, with noncumulative per-image baselines and undo.
- Freehand brush and text annotations support color, stroke width, and text size.
- Playback can alternate a pair or cycle the entire image set in order.
- Reference terminology and a visible REF sidebar badge replace GT labels.
- A cached RGB histogram follows image selection and crops, with an optional reference overlay.
- Workspace version 2 preserves the new controls and loads older version 1 workspaces.
- The compressed DMG was mounted and its bundled application verified.
