# Imspect 0.3.1 for Windows / 0.2.2 for Mac

- Use the revised sharp/blurred magnifying-glass icon throughout both apps: application icon, header, and About window. The longer handle remains on the blurred right side.
- Use transparent tile corners for clean display in the Dock, taskbar, and app headers.
- Remove the Windows preview label from the application, installer, current documentation, and release.

# Imspect 0.3.0 — Windows preview

- Add a standalone Qt desktop edition for Windows 10/11 x64, with a per-user installer and portable ZIP. The core app includes its runtime; Python installation is not required.
- Include split, flicker and wipe, pair/all-image playback, synchronized pan and zoom, matched crops, pixel inspection, reference metrics, RGB histograms, difference/SSIM/MSE maps, and centered FFT.
- Include brush, text and geometric annotations, linked or individual edits, channel controls, seeded noise, bilateral filtering, histogram matching, ResizeRight-compatible resizing, clipboard import/export, undo, full screen, and self-contained Windows workspaces.
- Preserve source coordinates for cropped LPIPS maps; clear cached results when opening workspaces or starting research operations.
- Validate 95 Windows scientific/interface tests and 16 research-worker tests. Run 43 walkthrough checks against both the portable and installed executables on a Windows build machine, and verify installation and uninstall.
- Keep Mac 0.2.1 available separately. Windows `.imspectw` workspaces are separate from Mac `.imspect` workspaces. Optional research-model packages and weights are not bundled. This is an unsigned preview with automated Windows validation, not exhaustive physical-hardware testing.

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
