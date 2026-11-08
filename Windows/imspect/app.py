"""Desktop workspace for the Windows edition. All image processing stays local."""
from __future__ import annotations

import csv
import json
import math
import os
from pathlib import Path
import sys
import time
import traceback

import numpy as np
from PySide6.QtCore import Qt, QTimer, Signal, QObject, QRunnable, QThreadPool, QSettings, QUrl
from PySide6.QtGui import QAction, QColor, QImage, QPainter, QPen, QPixmap, QIcon, QDesktopServices, QKeySequence
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QComboBox, QSlider, QCheckBox, QDoubleSpinBox, QSpinBox,
    QLineEdit, QListWidget, QListWidgetItem, QSplitter, QScrollArea, QGroupBox,
    QFileDialog, QMessageBox, QColorDialog, QSizePolicy, QAbstractItemView)

from . import __version__, engine
from .model import ImageItem, save_workspace, load_workspace
from .canvas import ComparisonCanvas


def resource_path(name):
    base = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parents[1]))
    return base / name


def array_qimage(a):
    b = np.ascontiguousarray(np.rint(np.clip(a, 0, 1) * 255), dtype=np.uint8)
    return QImage(b.data, b.shape[1], b.shape[0], b.strides[0], QImage.Format.Format_RGBA8888).copy()


def qimage_array(image):
    image = image.convertToFormat(QImage.Format.Format_RGBA8888)
    raw = np.frombuffer(image.constBits(), dtype=np.uint8).reshape(image.height(), image.bytesPerLine())
    return raw[:, :image.width()*4].reshape(image.height(), image.width(), 4).astype(np.float32) / 255


class JobSignals(QObject):
    finished = Signal(object, object)


class Job(QRunnable):
    def __init__(self, fn):
        super().__init__()
        self.fn = fn
        self.signals = JobSignals()

    def run(self):
        try:
            self.signals.finished.emit(self.fn(), None)
        except Exception as e:
            self.signals.finished.emit(None, str(e))


class ImageList(QListWidget):
    removeRequested = Signal()

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key.Key_Delete, Qt.Key.Key_Backspace):
            self.removeRequested.emit()
            event.accept()
        else:
            super().keyPressEvent(event)


class Histogram(QWidget):
    def __init__(self):
        super().__init__()
        self.values = self.reference = None
        self.setMinimumHeight(128)
        self.setToolTip('Probability per 256-bin RGB histogram; dashed lines show the reference.')

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor('#151b21'))
        rect = self.rect().adjusted(12, 20, -12, -22)
        p.setPen(QColor('#637184'))
        p.drawRect(rect)
        if self.values is None:
            p.drawText(rect, Qt.AlignmentFlag.AlignCenter, 'Open an image to see its histogram')
            return
        maximum = max(float(np.max(self.values)), float(np.max(self.reference)) if self.reference is not None else 0, 1e-6)
        colors = ['#ff737d', '#76de9c', '#7ab6ff']
        from PySide6.QtGui import QPainterPath
        for data, dashed in [(self.reference, True), (self.values, False)]:
            if data is None:
                continue
            for channel, color in enumerate(colors):
                pen = QPen(QColor(color), 1.2)
                if dashed:
                    pen.setStyle(Qt.PenStyle.DashLine)
                    pen.setColor(QColor(color).darker(150))
                p.setPen(pen)
                path = QPainterPath()
                for x, v in enumerate(data[channel]):
                    px = rect.left() + x / 255 * rect.width()
                    py = rect.bottom() - float(v) / maximum * rect.height()
                    path.moveTo(px, py) if x == 0 else path.lineTo(px, py)
                p.drawPath(path)
        p.setPen(QColor('#9daab9'))
        p.drawText(12, 14, f'Peak {100*maximum:.2f}% per bin')
        p.drawText(12, self.height()-5, '0')
        p.drawText(self.width()-34, self.height()-5, '255')


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f'Imspect {__version__} · Windows preview')
        self.setWindowIcon(QIcon(str(resource_path('assets/imspect.png'))))
        self.resize(1480, 900)
        self.setMinimumSize(1050, 680)
        self.setAcceptDrops(True)
        self.items = []
        self.selected = 0
        self.partner = 1
        self.reference = 0
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(2)
        self.jobs = []
        self.metric_key = None
        self.metric_generation = 0
        self.metric_results = []
        self.hist_cache = {}
        self.edit_busy = False
        self.dirty = False
        self._syncing = False
        self._last_tick = time.monotonic()
        self._switch_elapsed = 0.0
        self._wipe_direction = 1
        self._build_ui()
        self._build_menus()
        self.timer = QTimer(self)
        self.timer.setInterval(16)
        self.timer.timeout.connect(self._tick)
        self.metric_timer = QTimer(self)
        self.metric_timer.setSingleShot(True)
        self.metric_timer.setInterval(100)
        self.metric_timer.timeout.connect(self._calculate_metrics)
        self._refresh()

    def _button(self, text, fn, layout=None):
        b = QPushButton(text)
        b.clicked.connect(fn)
        if layout is not None:
            layout.addWidget(b)
        return b

    def _row(self, layout):
        row = QHBoxLayout()
        row.setSpacing(6)
        layout.addLayout(row)
        return row

    def _group(self, title, layout):
        group = QGroupBox(title)
        content = QVBoxLayout(group)
        content.setSpacing(7)
        layout.addWidget(group)
        return content

    def _combo(self, entries, fn, layout):
        combo = QComboBox()
        for text, data in entries:
            combo.addItem(text, data)
        combo.currentIndexChanged.connect(lambda _: fn(combo.currentData()))
        layout.addWidget(combo)
        return combo

    def _build_ui(self):
        root = QWidget()
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)
        outer.setContentsMargins(14, 10, 14, 10)
        head = self._row(outer)
        logo = QLabel()
        logo.setPixmap(QPixmap(str(resource_path('assets/imspect.png'))).scaled(40, 40, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
        head.addWidget(logo)
        title = QLabel(f'<b style="font-size:22px">Imspect</b><br><span style="color:#72d6c7">EVERY PIXEL. UNDER INSPECTION.</span>')
        head.addWidget(title)
        head.addStretch()
        for text, fn in [('Demo', self.load_demo), ('Open images…', self.open_images), ('Paste', self.paste_image), ('Copy', self.copy_image), ('Export…', self.export_image)]:
            self._button(text, fn, head)
        split = QSplitter(Qt.Orientation.Horizontal)
        outer.addWidget(split, 1)
        left = QWidget()
        ll = QVBoxLayout(left)
        ll.setContentsMargins(0, 6, 10, 0)
        ll.addWidget(QLabel('<b>COMPARISON SET</b>'))
        self.list = ImageList()
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.list.setIconSize(__import__('PySide6.QtCore', fromlist=['QSize']).QSize(52, 52))
        self.list.currentRowChanged.connect(self.select_image)
        self.list.removeRequested.connect(self.remove_image)
        ll.addWidget(self.list, 1)
        r = self._row(ll)
        self._button('+ Add', self.open_images, r)
        self._button('− Remove', self.remove_image, r)
        self._button('Set selected as reference', self.set_reference, ll)
        self._button('Duplicate selected', self.duplicate_image, ll)
        self._button('Save workspace…', self.save_session, ll)
        self._button('Open workspace…', self.open_session, ll)
        left.setMinimumWidth(180)
        split.addWidget(left)
        center = QWidget()
        cl = QVBoxLayout(center)
        cl.setContentsMargins(0, 0, 0, 0)
        r = self._row(cl)
        self.mode_combo = self._combo([('Split', 'split'), ('Flicker', 'flicker'), ('Wipe', 'wipe')], self.change_mode, r)
        self._button('−', lambda: self.canvas.zoom_by(1/1.25), r)
        self.zoom_label = QLabel('100%')
        self.zoom_label.setMinimumWidth(48)
        r.addWidget(self.zoom_label)
        self._button('+', lambda: self.canvas.zoom_by(1.25), r)
        self._button('Fit', lambda: self.canvas.fit(), r)
        self._button('1:1', lambda: self.canvas.one_to_one(), r)
        self.kernel_combo = self._combo([(x.title(), x) for x in ['nearest', 'linear', 'cubic', 'lanczos2', 'lanczos3']], self.change_kernel, r)
        self.kernel_combo.setCurrentIndex(2)
        r = self._row(cl)
        self.tool_combo = self._combo([(x.title(), x) for x in ['pan', 'inspect', 'select', 'rectangle', 'circle', 'dot', 'line', 'brush', 'text']], self.change_tool, r)
        self._button('Clear region', self.clear_roi, r)
        self._button('Next ›', lambda: self.cycle(1), r)
        self.play_button = self._button('▶ Play', self.toggle_play, r)
        self.speed = QSlider(Qt.Orientation.Horizontal)
        self.speed.setRange(1, 200)
        self.speed.setValue(20)
        self.speed.setMaximumWidth(120)
        self.speed.valueChanged.connect(self._speed_changed)
        r.addWidget(self.speed)
        self.speed_label = QLabel('2.0/s')
        self.speed_label.setMinimumWidth(52)
        r.addWidget(self.speed_label)
        self.canvas = ComparisonCanvas()
        self.canvas.selected.connect(self.select_image)
        self.canvas.cycleRequested.connect(self.cycle)
        self.canvas.modeRequested.connect(lambda: self.mode_combo.setCurrentIndex((self.mode_combo.currentIndex()+1)%3))
        self.canvas.toolRequested.connect(lambda name: self.tool_combo.setCurrentIndex(self.tool_combo.findData(name)))
        self.canvas.viewChanged.connect(self._view_changed)
        self.canvas.roiChanged.connect(self._roi_changed)
        self.canvas.pixelPicked.connect(self._pixel_picked)
        self.canvas.annotationsChanged.connect(self._annotation_changed)
        cl.addWidget(self.canvas, 1)
        hint = QLabel('SPACE pair   1–9 image   ARROWS pan   CTRL+SCROLL zoom   TAB mode   F11 full screen')
        hint.setStyleSheet('color:#8d9bad;font-size:10px')
        cl.addWidget(hint)
        split.addWidget(center)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setMinimumWidth(290)
        inspector = QWidget()
        il = QVBoxLayout(inspector)
        il.setContentsMargins(10, 4, 4, 4)
        v = self._group('VIEW & PLAYBACK', il)
        self.view_combo = self._combo([('Images', 'images'), ('Absolute RGB difference', 'difference'), ('MSE heatmap', 'mse'), ('SSIM error map', 'ssim'), ('Centered FFT2', 'fft')], self.change_view, v)
        v.addWidget(QLabel('Difference / heatmap gain'))
        self.gain_spin = QDoubleSpinBox()
        self.gain_spin.setRange(.1, 1000)
        self.gain_spin.setValue(1)
        self.gain_spin.valueChanged.connect(self.change_gain)
        v.addWidget(self.gain_spin)
        self.play_all = QCheckBox('Play all images in order')
        v.addWidget(self.play_all)
        v.addWidget(QLabel('Comparison partner / left wipe image'))
        self.partner_combo = QComboBox()
        self.partner_combo.currentIndexChanged.connect(self.change_partner)
        v.addWidget(self.partner_combo)
        v = self._group('REGION & PIXELS', il)
        self.roi_label = QLabel('Full image · coordinates from top left')
        self.roi_label.setWordWrap(True)
        v.addWidget(self.roi_label)
        r = self._row(v)
        self._button('Zoom to region', self.zoom_to_roi, r)
        self._button('Crop copy', self.copy_image, r)
        self.pixel_label = QLabel('Choose Inspect and click a pixel.')
        self.pixel_label.setWordWrap(True)
        self.pixel_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(self.pixel_label)
        v = self._group('RGB HISTOGRAM', il)
        self.histogram = Histogram()
        v.addWidget(self.histogram)
        self.hist_overlay = QCheckBox('Overlay reference')
        self.hist_overlay.setChecked(True)
        self.hist_overlay.toggled.connect(self.update_histogram)
        v.addWidget(self.hist_overlay)
        v = self._group('METRICS · VS REFERENCE', il)
        note = QLabel('Encoded sRGB · range 0–1 · opaque inputs\nSSIM: 11×11 Gaussian, σ 1.5, valid\nNo automatic alignment or resizing')
        note.setStyleSheet('color:#9aa8b7;font-size:11px')
        v.addWidget(note)
        self.metric_label = QLabel('Open two aligned images to compare.')
        self.metric_label.setWordWrap(True)
        self.metric_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(self.metric_label)
        self._button('Export metric report…', self.export_metrics, v)
        self._button('Research models…', self.research_dialog, v)
        v = self._group('ANNOTATIONS', il)
        self.annotations_all = QCheckBox('Annotations on all images')
        self.annotations_all.setChecked(True)
        self.annotations_all.toggled.connect(lambda b: setattr(self.canvas, 'shared_annotations', b))
        v.addWidget(self.annotations_all)
        r = self._row(v)
        self.color_button = self._button('Color…', self.choose_color, r)
        r.addWidget(QLabel('Width'))
        self.width_spin = QDoubleSpinBox()
        self.width_spin.setRange(.5, 200)
        self.width_spin.setValue(3)
        self.width_spin.valueChanged.connect(lambda x: setattr(self.canvas, 'draw_width', x))
        self.canvas.draw_width = self.width_spin.value()
        r.addWidget(self.width_spin)
        r = self._row(v)
        r.addWidget(QLabel('Text size (source pixels)'))
        self.font_spin = QSpinBox()
        self.font_spin.setRange(4, 500)
        self.font_spin.setValue(24)
        self.font_spin.valueChanged.connect(lambda x: setattr(self.canvas, 'font_size', x))
        r.addWidget(self.font_spin)
        self._button('Clear annotations', self.canvas.clear_annotations, v)
        v = self._group('EDIT IMAGES', il)
        self.edits_all = QCheckBox('Apply edits to all images (including ref)')
        v.addWidget(self.edits_all)
        self.edit_combo = self._combo([('Grayscale', 'grayscale'), ('Gaussian noise', 'noise'), ('Gaussian blur', 'gaussian'), ('Sharpen', 'sharpen'), ('Bilateral filter', 'bilateral'), ('Match histogram to reference', 'match_histogram'), ('Clip RGB to 0–1', 'clip'), ('Composite onto white', 'white'), ('Composite onto black', 'black')], self.edit_type_changed, v)
        self.amount_label = QLabel('Amount / σ')
        v.addWidget(self.amount_label)
        self.amount_spin = QDoubleSpinBox()
        self.amount_spin.setRange(.001, 255)
        self.amount_spin.setDecimals(3)
        self.amount_spin.setValue(1)
        v.addWidget(self.amount_spin)
        r = self._row(v)
        r.addWidget(QLabel('Noise seed'))
        self.seed_spin = QSpinBox()
        self.seed_spin.setRange(0, 2147483647)
        self.seed_spin.setValue(42)
        r.addWidget(self.seed_spin)
        r = self._row(v)
        self.apply_button = self._button('Apply edit', self.apply_edit, r)
        self._button('Undo', self.undo_edit, r)
        self._button('Restore', self.restore_image, r)
        v.addWidget(QLabel('RGB · left = 0 · center = original · right = 1'))
        self.channels = []
        self._channel_gesture = None
        for color in ['Red', 'Green', 'Blue']:
            r = self._row(v)
            lab = QLabel(color)
            lab.setMinimumWidth(38)
            r.addWidget(lab)
            slider = QSlider(Qt.Orientation.Horizontal)
            slider.setRange(-100, 100)
            slider.setValue(0)
            slider.sliderPressed.connect(self._channel_started)
            slider.sliderReleased.connect(self._channel_finished)
            slider.valueChanged.connect(self.adjust_channels)
            r.addWidget(slider)
            self.channels.append(slider)
        self._button('Reset RGB', self.reset_channels, v)
        v.addWidget(QLabel('Resize stored image · uses selected kernel'))
        r = self._row(v)
        self.resize_width = QSpinBox()
        self.resize_height = QSpinBox()
        for s in [self.resize_width, self.resize_height]:
            s.setRange(1, 16384)
            s.setValue(512)
        r.addWidget(self.resize_width)
        r.addWidget(QLabel('×'))
        r.addWidget(self.resize_height)
        self.resize_button = self._button('Resize', self.resize_images, v)
        self.edit_status = QLabel('Original image · edits are undoable')
        self.edit_status.setWordWrap(True)
        v.addWidget(self.edit_status)
        il.addStretch()
        scroll.setWidget(inspector)
        split.addWidget(scroll)
        split.setSizes([220, 900, 330])
        split.setStretchFactor(0, 0)
        split.setStretchFactor(1, 1)
        split.setStretchFactor(2, 0)
        self.statusBar().showMessage('Local processing · Float32 encoded sRGB · Windows preview 0.3.0')

    def _build_menus(self):
        def action(menu, title, shortcut, fn):
            a = QAction(title, self)
            if shortcut:
                a.setShortcut(shortcut)
            a.triggered.connect(fn)
            menu.addAction(a)
            return a
        file = self.menuBar().addMenu('&File')
        action(file, 'Open images…', QKeySequence.StandardKey.Open, self.open_images)
        action(file, 'Paste image', QKeySequence.StandardKey.Paste, self.paste_image)
        action(file, 'Copy image / region', QKeySequence.StandardKey.Copy, self.copy_image)
        action(file, 'Export image…', 'Ctrl+E', self.export_image)
        file.addSeparator()
        action(file, 'Save workspace…', QKeySequence.StandardKey.Save, self.save_session)
        action(file, 'Open workspace…', 'Ctrl+Shift+O', self.open_session)
        action(file, 'Quit', QKeySequence.StandardKey.Quit, self.close)
        edit = self.menuBar().addMenu('&Edit')
        action(edit, 'Undo pixel edit', QKeySequence.StandardKey.Undo, self.undo_edit)
        action(edit, 'Duplicate selected', 'Ctrl+D', self.duplicate_image)
        action(edit, 'Restore original', None, self.restore_image)
        view = self.menuBar().addMenu('&View')
        action(view, 'Full screen', 'F11', self.toggle_full_screen)
        action(view, 'Fit', None, self.canvas.fit)
        action(view, '100%', None, self.canvas.one_to_one)
        help_menu = self.menuBar().addMenu('&Help')
        action(help_menu, 'User guide', None, lambda: QDesktopServices.openUrl(QUrl('https://github.com/assafshocher/Imspect/blob/main/Windows/README.md')))
        action(help_menu, 'About Imspect', None, lambda: QMessageBox.about(self, 'Imspect', f'Imspect {__version__} · Windows preview\nLocal image comparison for computer vision.\nQt/PySide6 desktop edition.\nPixel metrics exclude annotations and display zoom.'))

    def notify_error(self, message):
        self.statusBar().showMessage(str(message), 12000)
        if not getattr(self, 'testing', False):
            QMessageBox.warning(self, 'Imspect', str(message))

    def _submit(self, fn, callback):
        job = Job(fn)
        self.jobs.append(job)
        def finished(result, error):
            try:
                callback(result, error)
            finally:
                if job in self.jobs:
                    self.jobs.remove(job)
        job.signals.finished.connect(finished)
        self.pool.start(job)

    def _refresh(self, rebuild=True):
        self._syncing = True
        n = len(self.items)
        self.selected = max(0, min(self.selected, n-1))
        self.reference = max(0, min(self.reference, n-1))
        self.partner = max(0, min(self.partner, n-1))
        if n > 1 and self.partner == self.selected:
            self.partner = (self.selected+1) % n
        if rebuild:
            self.list.blockSignals(True)
            self.list.clear()
            self.partner_combo.blockSignals(True)
            self.partner_combo.clear()
            for i, item in enumerate(self.items):
                h, w = item.pixels.shape[:2]
                suffix = '  ◆ REF' if i == self.reference else ''
                row = QListWidgetItem(f'{i+1}  {item.name}\n{w} × {h}{suffix}')
                thumb = array_qimage(item.pixels[::max(1, h//80), ::max(1, w//80)])
                row.setIcon(QIcon(QPixmap.fromImage(thumb)))
                self.list.addItem(row)
                self.partner_combo.addItem(f'{i+1} · {item.name}')
            self.list.setCurrentRow(self.selected if n else -1)
            self.list.blockSignals(False)
            self.partner_combo.setCurrentIndex(self.partner if n else -1)
            self.partner_combo.blockSignals(False)
        else:
            self.list.blockSignals(True)
            self.list.setCurrentRow(self.selected if n else -1)
            self.list.blockSignals(False)
            self.partner_combo.blockSignals(True)
            self.partner_combo.setCurrentIndex(self.partner if n else -1)
            self.partner_combo.blockSignals(False)
        self.canvas.set_images(self.items, selected=self.selected, partner=self.partner, reference=self.reference)
        if n:
            item = self.items[self.selected]
            for slider, value in zip(self.channels, item.channel_values):
                slider.blockSignals(True)
                slider.setValue(round(float(value)*100))
                slider.blockSignals(False)
            self.resize_width.setValue(item.pixels.shape[1])
            self.resize_height.setValue(item.pixels.shape[0])
            self.edit_status.setText(item.history[-1] if item.history else 'Original image · edits are undoable')
        self._syncing = False
        self._view_changed()
        self.update_histogram()
        self.schedule_metrics()
        if self.canvas.inspection_point is not None:
            self._pixel_picked(self.canvas.inspection_point)

    def add_arrays(self, arrays, fit=None):
        was_empty = not self.items
        for name, data in arrays:
            self.items.append(ImageItem.from_array(name, data))
        self.dirty = True
        self._refresh()
        if was_empty if fit is None else fit:
            self.canvas.fit()

    def load_paths(self, paths):
        arrays = []
        errors = []
        for path in paths:
            try:
                arrays.append((Path(path).stem, engine.load_image(path)))
            except Exception as e:
                errors.append(f'{Path(path).name}: {e}')
        if arrays:
            self.add_arrays(arrays)
        if errors:
            self.notify_error('\n'.join(errors))

    def open_images(self):
        paths, _ = QFileDialog.getOpenFileNames(self, 'Open comparison images', '', 'Images (*.png *.jpg *.jpeg *.tif *.tiff *.bmp *.webp);;All files (*)')
        if paths:
            self.load_paths(paths)

    def paste_image(self):
        image = QApplication.clipboard().image()
        if image.isNull():
            self.notify_error('The clipboard does not contain an image.')
        else:
            self.add_arrays([(f'Pasted image {len(self.items)+1}', qimage_array(image))])

    def load_demo(self):
        if self.items and not getattr(self, 'testing', False):
            result = QMessageBox.question(self, 'Load demo', 'Replace the comparison set with demo images? Save your workspace first if needed.')
            if result != QMessageBox.StandardButton.Yes:
                return
        self.stop_play()
        self.items = []
        self.canvas.roi = None
        self.canvas.annotations = []
        self.add_arrays(engine.demo_images(), fit=True)

    def select_image(self, index):
        if self._syncing or not 0 <= index < len(self.items):
            return
        if index == self.partner:
            self.partner = self.selected
        self.selected = index
        self._refresh(False)

    def remove_image(self):
        if not self.items or self.edit_busy:
            return
        self.stop_play()
        removed = self.items.pop(self.selected)
        self.canvas.annotations = [a for a in self.canvas.annotations if a.get('image_id') != removed.id]
        if self.reference > self.selected:
            self.reference -= 1
        elif self.reference == self.selected:
            self.reference = 0
        if self.partner > self.selected:
            self.partner -= 1
        self.dirty = True
        self._refresh()

    def duplicate_image(self):
        if self.items:
            item = self.items[self.selected]
            self.items.append(ImageItem.from_array(item.name+' copy', item.pixels.copy()))
            self.selected = len(self.items)-1
            self.dirty = True
            self._refresh()

    def set_reference(self):
        if self.items:
            self.reference = self.selected
            self.dirty = True
            self._refresh()

    def change_partner(self, index):
        if not self._syncing and 0 <= index < len(self.items):
            self.partner = index
            if index == self.selected and len(self.items)>1:
                self.selected = (index+1)%len(self.items)
            self._refresh(False)

    def change_mode(self, mode):
        if hasattr(self, 'canvas'):
            self.canvas.set_mode(mode)
            self._speed_changed()

    def change_kernel(self, kernel):
        if hasattr(self, 'canvas'):
            self.canvas.kernel = kernel
            self.canvas.invalidate()

    def change_tool(self, tool):
        if hasattr(self, 'canvas'):
            self.canvas.set_tool(tool)
            self.canvas.setFocus()

    def change_view(self, mode):
        self.canvas.view_mode = mode
        self.canvas.invalidate()
        self.schedule_metrics()
        if mode == 'fft':
            self.pixel_label.setText('Frequency view · pixel inspection and annotations are spatial-only.')
        self.update_histogram()

    def change_gain(self, gain):
        self.canvas.gain = gain
        self.canvas.invalidate()

    def cycle(self, direction=1):
        if len(self.items) < 2:
            return
        if direction == 0:
            self.selected, self.partner = self.partner, self.selected
        else:
            index = (self.selected+direction) % len(self.items)
            if index == self.partner:
                self.partner = self.selected
            self.selected = index
        self._refresh(False)

    def toggle_play(self):
        if self.timer.isActive():
            self.stop_play()
        elif len(self.items) >= 2:
            if self.canvas.mode == 'split':
                self.mode_combo.setCurrentIndex(1)
            self._last_tick = time.monotonic()
            self._switch_elapsed = 0
            self.timer.start()
            self.play_button.setText('■ Stop')
            self.canvas.setFocus()

    def stop_play(self):
        if hasattr(self, 'timer'):
            self.timer.stop()
        if hasattr(self, 'play_button'):
            self.play_button.setText('▶ Play')

    def _tick(self):
        now = time.monotonic()
        dt = min(.25, now-self._last_tick)
        self._last_tick = now
        speed = self.speed.value()/10
        if self.canvas.mode == 'wipe':
            self.canvas.wipe_position += self._wipe_direction * dt * speed / 4
            if self.canvas.wipe_position >= 1 or self.canvas.wipe_position <= 0:
                self.canvas.wipe_position = max(0, min(1, self.canvas.wipe_position))
                self._wipe_direction *= -1
                if self.play_all.isChecked() and len(self.items)>2:
                    index = (self.selected+1)%len(self.items)
                    if index == self.partner:
                        index = (index+1)%len(self.items)
                    self.selected = index
                    self._refresh(False)
            self.canvas.update()
        else:
            self._switch_elapsed += dt
            if self._switch_elapsed >= 1/speed:
                self._switch_elapsed %= 1/speed
                self.cycle(1 if self.play_all.isChecked() else 0)

    def _speed_changed(self, *args):
        if hasattr(self, 'speed_label'):
            value = self.speed.value()/10
            self.speed_label.setText(f'{4/value:.1f}s/sweep' if hasattr(self, 'canvas') and self.canvas.mode == 'wipe' else f'{value:.1f}/s')

    def _view_changed(self):
        self.zoom_label.setText(f'{self.canvas.zoom*100:.0f}%')

    def _roi_changed(self, roi):
        self.dirty = True
        self.roi_label.setText('Full image · coordinates from top left' if roi is None else f'x {roi[0]} · y {roi[1]} · {roi[2]} × {roi[3]} pixels')
        self.update_histogram()
        self.schedule_metrics()

    def clear_roi(self):
        self.canvas.roi = None
        self.canvas.update()
        self._roi_changed(None)

    def zoom_to_roi(self):
        self.canvas.zoom_to_roi()

    def _pixel_picked(self, point):
        if point is None:
            return
        x,y = map(int, point)
        lines = [f'Pixel ({x}, {y}) · RGB 0–255 / alpha 0–1']
        for i,item in enumerate(self.items):
            if 0<=x<item.pixels.shape[1] and 0<=y<item.pixels.shape[0]:
                v=item.pixels[y,x]
                lines.append(f'{i+1} · {item.name}: {v[0]*255:.2f}, {v[1]*255:.2f}, {v[2]*255:.2f} / {v[3]:.3f}')
            else:
                lines.append(f'{i+1} · {item.name}: outside image')
        self.pixel_label.setText('\n'.join(lines))

    def _annotation_changed(self):
        self.dirty = True

    def choose_color(self):
        color = QColorDialog.getColor(self.canvas.draw_color, self, 'Annotation color')
        if color.isValid():
            self.canvas.draw_color = color
            self.color_button.setStyleSheet(f'border-bottom:3px solid {color.name()}')

    def schedule_metrics(self):
        self.metric_timer.start()

    def _metrics_key(self):
        return (tuple((x.id,x.revision) for x in self.items), self.reference, self.canvas.roi, self.canvas.view_mode=='fft')

    def _calculate_metrics(self):
        key = self._metrics_key()
        if key == self.metric_key:
            return
        self.metric_key = key
        self.metric_generation += 1
        self.metric_results = []
        generation = self.metric_generation
        if not self.items:
            self.metric_results=[]
            self.metric_label.setText('Open two aligned images to compare.')
            return
        if self.canvas.view_mode == 'fft':
            self.metric_label.setText('Metrics are spatial. Switch View to Images to measure source pixels.')
            return
        snapshots = [(item.id,item.name,item.pixels) for item in self.items]
        ref = self.items[self.reference].pixels
        reference_id = self.items[self.reference].id
        roi = self.canvas.roi
        self.metric_label.setText('Calculating…')
        def calculate():
            result=[]
            for ident,name,pixels in snapshots:
                if ident==reference_id:
                    result.append({'id':ident,'name':name,'reference':True})
                else:
                    try:
                        result.append(dict(id=ident,name=name,**engine.metrics(ref,pixels,roi)))
                    except Exception as e:
                        result.append({'id':ident,'name':name,'error':str(e)})
            return result
        def done(result,error):
            if generation != self.metric_generation or key != self._metrics_key():
                return
            if error:
                self.metric_label.setText(error)
                return
            self.metric_results=result
            lines=[]
            for i,r in enumerate(result):
                lines.append(f'<b>{i+1} · {self._html(r["name"])}</b>')
                if r.get('reference'):
                    lines.append('Reference')
                elif 'error' in r:
                    lines.append(self._html(r['error']))
                else:
                    def val(k,fmt):
                        v=r.get(k)
                        return '—' if v is None else ('∞' if math.isinf(v) else format(v,fmt))
                    lines.append(f'PSNR {val("psnr",".2f")} dB · SSIM {val("ssim",".5f")}<br>MSE {val("mse",".7f")}<br>Hist W₁ {val("histogram",".5f")} · ΔE76 {val("delta_e",".3f")}')
                lines.append('')
            self.metric_label.setText('<br>'.join(lines))
        self._submit(calculate,done)

    @staticmethod
    def _html(text):
        import html
        return html.escape(str(text))

    def update_histogram(self, *args):
        if not self.items:
            self.histogram.values=self.histogram.reference=None
            self.histogram.update()
            return
        roi = None if self.canvas.view_mode=='fft' else self.canvas.roi
        def get(index):
            item=self.items[index]
            key=(item.id,item.revision,roi)
            if key not in self.hist_cache:
                if len(self.hist_cache)>100:
                    self.hist_cache.clear()
                self.hist_cache[key]=engine.histogram(item.pixels,roi)
            return self.hist_cache[key]
        try:
            self.histogram.values=get(self.selected)
            self.histogram.reference=get(self.reference) if self.hist_overlay.isChecked() else None
        except Exception:
            self.histogram.values=self.histogram.reference=None
        self.histogram.update()

    def targets(self):
        return list(self.items) if self.edits_all.isChecked() else ([self.items[self.selected]] if self.items else [])

    def edit_type_changed(self, operation):
        if not hasattr(self,'amount_spin'):
            return
        defaults={'noise':10,'gaussian':1,'sharpen':1,'bilateral':.1}
        self.amount_spin.setValue(defaults.get(operation,1))
        self.amount_label.setText({'noise':'Noise σ (0–255)', 'gaussian':'Blur σ (source pixels)', 'bilateral':'Range σ (0–1), spatial σ = 2', 'sharpen':'Sharpen strength'}.get(operation,'Amount (unused for this edit)'))

    def _run_edit(self, fn, description):
        if self.edit_busy or not self.items:
            return
        self.stop_play()
        targets=[(item.id,item.revision,item.pixels) for item in self.targets()]
        self.edit_busy=True
        self.apply_button.setEnabled(False)
        self.resize_button.setEnabled(False)
        for slider in self.channels:
            slider.setEnabled(False)
        self.edit_status.setText('Processing…')
        def work():
            return [(ident,revision,fn(pixels)) for ident,revision,pixels in targets]
        def done(result,error):
            self.edit_busy=False
            self.apply_button.setEnabled(True)
            self.resize_button.setEnabled(True)
            for slider in self.channels:
                slider.setEnabled(True)
            if error:
                self.notify_error(error)
            else:
                by_id={item.id:item for item in self.items}
                if any(ident not in by_id or by_id[ident].revision!=rev for ident,rev,_ in result):
                    self.notify_error('Images changed during the edit. The stale result was discarded.')
                else:
                    for ident,rev,pixels in result:
                        by_id[ident].apply(pixels,description)
                    self.dirty=True
                    self.canvas.invalidate()
            self._refresh()
        self._submit(work,done)

    def apply_edit(self):
        if not self.items:
            return
        operation=self.edit_combo.currentData()
        amount=self.amount_spin.value()/255 if operation=='noise' else self.amount_spin.value()
        seed=self.seed_spin.value()
        reference=self.items[self.reference].pixels.copy()
        self._run_edit(lambda a:engine.apply_edit(a,operation,amount=amount,seed=seed,reference=reference), f'{self.edit_combo.currentText()} · amount {self.amount_spin.value():g} · seed {seed}')

    def resize_images(self):
        w,h=self.resize_width.value(),self.resize_height.value()
        kernel=self.canvas.kernel
        self._run_edit(lambda a:engine.resize(a,w,h,kernel=kernel),f'Resize {w}×{h} · {kernel}')

    def undo_edit(self):
        if self.edit_busy:
            return
        self.stop_play()
        for item in self.targets():
            item.undo()
        self.dirty=True
        self.canvas.invalidate()
        self._refresh()

    def restore_image(self):
        if self.edit_busy:
            return
        self.stop_play()
        for item in self.targets():
            item.restore()
        self.dirty=True
        self.canvas.invalidate()
        self._refresh()

    def _channel_started(self):
        self.stop_play()
        self._channel_gesture=True

    def _channel_finished(self):
        if self._channel_gesture:
            values=[s.value()/100 for s in self.channels]
            for item in self.targets():
                item.set_channels(values,commit=True)
            self._refresh(False)
        self._channel_gesture=None

    def adjust_channels(self, *args):
        if self._syncing or self.edit_busy or not self.items:
            return
        self.stop_play()
        values=[s.value()/100 for s in self.channels]
        commit=self._channel_gesture is None
        for item in self.targets():
            item.set_channels(values,commit=commit)
        self.dirty=True
        self.canvas.invalidate()
        self._refresh(False)

    def reset_channels(self):
        if self.edit_busy:
            return
        for item in self.targets():
            item.set_channels([0,0,0])
        self.dirty=True
        self.canvas.invalidate()
        self._refresh()

    def copy_image(self):
        if not self.items:
            return
        try:
            QApplication.clipboard().setImage(self.canvas.export_image(self.selected,self.canvas.roi))
            self.statusBar().showMessage('Copied image / region with annotations to the clipboard.',5000)
        except Exception as e:
            self.notify_error(e)

    def export_image(self):
        if not self.items:
            return
        path,_=QFileDialog.getSaveFileName(self,'Export selected image',self.items[self.selected].name+'.png','PNG image (*.png)')
        if not path:
            return
        try:
            item=self.items[self.selected]
            applicable=[a for a in self.canvas.annotations if a.get('image_id') in (None,item.id)]
            if applicable and self.canvas.view_mode != 'fft':
                result=self.canvas.export_image(self.selected,self.canvas.roi)
                if not result.save(path,'PNG'):
                    raise ValueError('Could not write the image.')
                self.statusBar().showMessage('Saved annotated 8-bit sRGB PNG.',7000)
            else:
                pixels=self.canvas._pixels(self.selected)
                roi=None if self.canvas.view_mode=='fft' else self.canvas.roi
                engine.save_png(engine.crop(pixels,roi),path)
                self.statusBar().showMessage('Saved 16-bit sRGB PNG; stored pixels were not changed.',7000)
        except Exception as e:
            self.notify_error(e)

    def export_metrics(self):
        if not self.items or self.metric_key!=self._metrics_key() or not self.metric_results:
            self.notify_error('Wait for the current metrics to finish, then export.')
            return
        path,_=QFileDialog.getSaveFileName(self,'Export metric report','Imspect-metrics.csv','CSV report (*.csv)')
        if path:
            try:
                with open(path,'w',newline='',encoding='utf-8-sig') as f:
                    writer=csv.writer(f)
                    writer.writerow(['Imspect',__version__,'encoded sRGB','range 1','SSIM11x11Gaussian sigma1.5 valid','histogram RGB W1/255','DeltaE CIE76 D65'])
                    writer.writerow(['reference',self.items[self.reference].name,'ROI',str(self.canvas.roi or 'full image')])
                    writer.writerow(['image','MSE','PSNR','SSIM','histogram_W1','deltaE76','pixels','status','edits'])
                    by_id={i.id:i for i in self.items}
                    for r in self.metric_results:
                        writer.writerow([r['name']]+[r.get(k,'') for k in ['mse','psnr','ssim','histogram','delta_e','pixels']]+[r.get('error','reference' if r.get('reference') else 'ok'),'; '.join(by_id[r['id']].history)])
            except Exception as e:
                self.notify_error(e)

    def session_state(self):
        return {'selected':self.selected,'partner':self.partner,'reference':self.reference,'mode':self.canvas.mode,'view_mode':self.canvas.view_mode,
                'kernel':self.canvas.kernel,'zoom':self.canvas.zoom,'center':list(self.canvas.center),'roi':self.canvas.roi,
                'gain':self.canvas.gain,'wipe_position':self.canvas.wipe_position,'play_all':self.play_all.isChecked(),
                'draw_color':self.canvas.draw_color.name(QColor.NameFormat.HexArgb),'draw_width':self.canvas.draw_width,'font_size':self.canvas.font_size,
                'shared_annotations':self.canvas.shared_annotations}

    def save_session(self, path=None):
        if not self.items:
            return
        if not isinstance(path,(str,Path)):
            path,_=QFileDialog.getSaveFileName(self,'Save Windows workspace','Comparison.imspectw','Imspect Windows workspace (*.imspectw)')
        if path:
            try:
                save_workspace(path,self.items,self.session_state(),self.canvas.annotations)
                self.dirty=False
                self.statusBar().showMessage('Workspace saved with originals, edits and annotations.',5000)
            except Exception as e:
                self.notify_error(e)

    def open_session(self, path=None):
        if self.edit_busy:
            return
        if not isinstance(path,(str,Path)):
            path,_=QFileDialog.getOpenFileName(self,'Open Windows workspace','','Imspect Windows workspace (*.imspectw)')
        if not path:
            return
        try:
            items,state,annotations=load_workspace(path)
            self.stop_play()
            self.items=items
            self.selected=int(state.get('selected',0))
            self.partner=int(state.get('partner',1))
            self.reference=int(state.get('reference',0))
            self._refresh()
            self.canvas.annotations=annotations
            for combo,key,default in [(self.mode_combo,'mode','split'),(self.view_combo,'view_mode','images'),(self.kernel_combo,'kernel','cubic')]:
                index=combo.findData(state.get(key,default))
                combo.setCurrentIndex(max(0,index))
            self.canvas.zoom=float(state.get('zoom',1))
            self.canvas.center=tuple(state.get('center',(0,0)))
            roi=state.get('roi')
            self.canvas.roi=tuple(roi) if roi else None
            self.canvas.wipe_position=float(state.get('wipe_position',.5))
            self.gain_spin.setValue(float(state.get('gain',1)))
            self.play_all.setChecked(bool(state.get('play_all',False)))
            self.canvas.draw_color=QColor(state.get('draw_color','#ffffcc55'))
            self.width_spin.setValue(float(state.get('draw_width',3)))
            self.font_spin.setValue(int(state.get('font_size',24)))
            self.annotations_all.setChecked(bool(state.get('shared_annotations',True)))
            self._roi_changed(self.canvas.roi)
            self.canvas.invalidate()
            self._view_changed()
            self.dirty=False
        except Exception as e:
            self.notify_error(e)

    def research_dialog(self):
        from .research import ResearchDialog
        if not self.items:
            return
        dialog=ResearchDialog(self.items[self.selected],self.items[self.reference],self.canvas.roi,self)
        dialog.exec()
        if dialog.map_result is not None:
            self.add_arrays([(dialog.map_name,dialog.map_result)])

    def toggle_full_screen(self):
        self.showNormal() if self.isFullScreen() else self.showFullScreen()

    def dragEnterEvent(self,event):
        if event.mimeData().hasUrls() or event.mimeData().hasImage():
            event.acceptProposedAction()

    def dropEvent(self,event):
        if event.mimeData().hasUrls():
            paths=[u.toLocalFile() for u in event.mimeData().urls() if u.isLocalFile()]
            if len(paths)==1 and paths[0].lower().endswith('.imspectw'):
                self.open_session(paths[0])
            else:
                self.load_paths(paths)
        elif event.mimeData().hasImage():
            image=QImage(event.mimeData().imageData())
            if not image.isNull():
                self.add_arrays([('Dropped image',qimage_array(image))])
        event.acceptProposedAction()

    def closeEvent(self,event):
        if getattr(self,'testing',False):
            self.stop_play()
            self.pool.waitForDone(30000)
            event.accept()
            return
        if self.edit_busy or self.jobs:
            self.notify_error('An operation is still finishing. Please wait a moment before closing.')
            event.ignore()
            return
        if self.dirty:
            answer=QMessageBox.question(self,'Save workspace?','Save this comparison before closing?',QMessageBox.StandardButton.Save|QMessageBox.StandardButton.Discard|QMessageBox.StandardButton.Cancel)
            if answer==QMessageBox.StandardButton.Cancel:
                event.ignore();return
            if answer==QMessageBox.StandardButton.Save:
                self.save_session()
                if self.dirty:
                    event.ignore();return
        self.stop_play()
        event.accept()


def apply_style(app):
    app.setStyle('Fusion')
    app.setStyleSheet('''
        QMainWindow,QDialog,QWidget {background:#20262e;color:#e6edf4;font-size:12px;}
        QMenuBar,QMenu {background:#252e39;} QMenu::item:selected {background:#32615d;}
        QPushButton {background:#35404e;border:1px solid #46515f;border-radius:4px;padding:5px 8px;}
        QPushButton:hover {background:#415263;} QPushButton:pressed {background:#217b70;}
        QPushButton:disabled {color:#708090;}
        QComboBox,QSpinBox,QDoubleSpinBox,QLineEdit {background:#151c24;border:1px solid #46515f;border-radius:3px;padding:4px;}
        QGroupBox {border:0;border-top:1px solid #3b4550;margin-top:15px;padding-top:12px;font-weight:bold;color:#80dacb;}
        QGroupBox::title {subcontrol-origin:margin;left:0;padding:0 3px;}
        QListWidget {background:#19212a;border:0;} QListWidget::item {padding:9px 3px;border-radius:4px;}
        QListWidget::item:selected {background:#205d66;} QScrollArea {border:0;}
        QSlider::groove:horizontal {height:5px;background:#3e4c5d;border-radius:2px;}
        QSlider::handle:horizontal {width:15px;background:#6bcdbd;margin:-5px 0;border-radius:7px;}
        QSplitter::handle {background:#303a46;width:4px;}
        QStatusBar {color:#9eafbf;} QToolTip {background:#eaf2f8;color:#14202b;padding:5px;}
    ''')
