# Third-party software in the Windows build

Imspect's Windows application is packaged with an embedded Python runtime and dynamically linked Qt libraries. The `licenses` directory inside `_internal` contains the license and notice files collected from the exact installed distributions used to build the package. Because the PySide6 6.8.3 wheels omit full license texts, the build also collects the matching QtBase, QtSvg, QtImageFormats, and PySide source notices from official, checksum-pinned 6.8.3 source archives. `licenses/Qt-upstream/source-manifest.json` records their sources and hashes. Distribution metadata is retained for runtime version reporting. The build evidence records all resolved package versions.

| Component | Published build version | Upstream and license information |
|---|---|---|
| Python | 3.11.x | [Python](https://www.python.org/), PSF license and included third-party notices |
| PySide6 / Shiboken6 / Qt | 6.8.3 | [Qt for Python](https://doc.qt.io/qtforpython-6.8/licenses.html); applicable LGPLv3 and upstream third-party notices |
| NumPy | 2.0.2 | [NumPy](https://numpy.org/), BSD-3-Clause and bundled numerical-library notices |
| SciPy | 1.13.1 | [SciPy](https://scipy.org/), BSD-3-Clause and bundled numerical-library notices |
| Pillow | 11.3.0 | [Pillow](https://python-pillow.org/), HPND/PIL license and bundled image-library notices |
| PyPNG | 0.20220715.0 | [PyPNG](https://github.com/drj11/pypng), MIT |
| ResizeRight | Vendored revision recorded upstream | [ResizeRight](https://github.com/assafshocher/ResizeRight), MIT; source and license included in `Research/vendor/resize_right` |

The PyInstaller build uses its [bootloader exception](https://pyinstaller.org/en/stable/license.html). Inno Setup creates the installer under its [distribution license](https://jrsoftware.org/files/is/license.txt). Build-tool notices may also be included in the collected license directory; their presence does not mean those tools are runtime dependencies.

Qt/PySide6 are unmodified and remain separate replaceable libraries in `_internal`. To use a compatible modified Qt/PySide6 build, keep the same Python ABI and Qt/PySide6 version, replace the corresponding library files in a copy of the portable distribution, and run that copy. Imspect does not impose restrictions on reverse engineering for debugging modifications to these libraries. Its source and packaging instructions are available in this repository.

Corresponding upstream source is available from the versioned projects:

- [Qt 6.8.3 source archives](https://download.qt.io/archive/qt/6.8/6.8.3/single/)
- [PySide/Shiboken 6.8.3 source](https://code.qt.io/cgit/pyside/pyside-setup.git/tree/?h=v6.8.3)
- [Python source releases](https://www.python.org/downloads/source/)
- [NumPy 2.0.2](https://github.com/numpy/numpy/tree/v2.0.2)
- [SciPy 1.13.1](https://github.com/scipy/scipy/tree/v1.13.1)
- [Pillow 11.3.0](https://github.com/python-pillow/Pillow/tree/11.3.0)

Optional PyTorch, torchvision, LPIPS, and IQA-PyTorch packages and model weights are installed separately, are not included in this binary, and have their own licenses and model-use conditions. See the research documentation for their sources.

This notice preserves third-party terms. It does not introduce a license for Imspect's own source code.
