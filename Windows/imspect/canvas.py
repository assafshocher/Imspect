"""Shared-coordinate native Qt comparison canvas.

Image coordinates refer to pixel *edges*: pixel (x, y) has its centre at
(x + .5, y + .5).  Every panel uses the same centre and scale.  Display
resampling is delegated to the scientific engine rather than QPainter's
image interpolation, including fractional zoom and pan.
"""
from __future__ import annotations

from collections import OrderedDict
import math
import uuid

import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QImage, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import QInputDialog, QWidget

from . import engine


def array_to_qimage(array):
    """A detached, display-only 8-bit RGBA image; never modifies samples."""
    rgba = np.ascontiguousarray(
        np.rint(np.clip(np.nan_to_num(array), 0, 1) * 255).astype(np.uint8)
    )
    height, width = rgba.shape[:2]
    return QImage(rgba.data, width, height, rgba.strides[0],
                  QImage.Format.Format_RGBA8888).copy()


class ComparisonCanvas(QWidget):
    selected = Signal(int)
    viewChanged = Signal()
    roiChanged = Signal(object)
    pixelPicked = Signal(object)
    annotationsChanged = Signal()
    cycleRequested = Signal(int)
    modeRequested = Signal()
    toolRequested = Signal(str)

    HEADER = 26
    GAP = 8
    CACHE_BYTES = 128 * 1024 * 1024
    MAX_DERIVED_BYTES = 128 * 1024 * 1024

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("comparisonCanvas")
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMouseTracking(True)
        self.setMinimumSize(180, 180)
        self.items = []
        self.selected_index = 0
        self.partner_index = 1
        self.reference_index = 0
        self.mode = "split"
        self.view_mode = "images"
        self.gain = 1.0
        self.kernel = "cubic"
        self.zoom = 1.0
        self.center = (0.0, 0.0)
        self.roi = None
        self.inspection_point = None
        self.annotations = []
        self.tool = "pan"
        self.draw_color = QColor("#42ddc2")
        self.draw_width = 2.0
        self.font_size = 24.0
        self.shared_annotations = True
        self.wipe_position = 0.5
        self.show_pixel_grid = True
        self._patches = OrderedDict()
        self._patch_bytes = 0
        self._derived = OrderedDict()
        self._derived_bytes = 0
        self._item_signature = ()
        self._drag_start = None
        self._drag_source = None
        self._drag_center = None
        self._drag_index = 0
        self._drag_content = None
        self._dragged = False
        self._drag_wipe = False
        self._draft = None
        self._warm_pending = False
        self._warm_timer = QTimer(self)
        self._warm_timer.setSingleShot(True)
        self._warm_timer.timeout.connect(self._warm_one)
        self._last_error = ""
        self._checker = self._make_checker()
        self.setToolTip("Drag to pan · Ctrl + wheel to zoom · Space to flicker · Tab to change mode")

    @staticmethod
    def _make_checker():
        tile = QPixmap(20, 20)
        tile.fill(QColor("#20262c"))
        painter = QPainter(tile)
        painter.fillRect(0, 0, 10, 10, QColor("#252c32"))
        painter.fillRect(10, 10, 10, 10, QColor("#252c32"))
        painter.end()
        return tile

    def set_images(self, items, selected=0, partner=1, reference=0):
        was_empty = not self.items
        self.items = list(items)
        count = len(self.items)
        self.selected_index = min(max(int(selected), 0), max(count - 1, 0))
        self.partner_index = min(max(int(partner), 0), max(count - 1, 0))
        self.reference_index = min(max(int(reference), 0), max(count - 1, 0))
        signature = tuple((item.id, int(item.revision), id(item.pixels)) for item in self.items)
        if signature != self._item_signature:
            self._item_signature = signature
            self.invalidate()
        if was_empty and self.items:
            height, width = self.items[0].pixels.shape[:2]
            self.center = (width / 2.0, height / 2.0)
        if not self.items:
            self._draft = None
            self._cancel_drag()
        self.update()
        self._schedule_warm()

    def set_mode(self, mode):
        if mode not in ("split", "flicker", "wipe"):
            raise ValueError("Choose split, flicker or wipe.")
        self.mode = mode
        self._cancel_drag()
        self._view_changed()

    def set_tool(self, tool):
        if tool not in ("pan", "inspect", "select", "rectangle", "circle", "dot", "line", "brush", "text"):
            raise ValueError("Unknown canvas tool.")
        self.tool = tool
        self._draft = None
        self._cancel_drag()
        self.setCursor(Qt.CursorShape.OpenHandCursor if tool == "pan" else Qt.CursorShape.CrossCursor)
        self.update()

    def invalidate(self):
        self._patches.clear()
        self._patch_bytes = 0
        self._derived.clear()
        self._derived_bytes = 0
        self._last_error = ""
        self.update()
        self._schedule_warm()

    def _panels(self):
        """(item index, outer rectangle, content rectangle); no selected-size dependence."""
        if not self.items:
            return []
        if self.mode == "split":
            count = len(self.items)
            # Wide windows favour columns while keeping a regular shared-size grid.
            ratio = max(self.width(), 1) / max(self.height(), 1)
            columns = max(1, min(count, int(math.ceil(math.sqrt(count * ratio)))))
            if count == 2:
                columns = 2 if self.width() >= self.height() * .75 else 1
            rows = int(math.ceil(count / columns))
            panel_width = max(1.0, (self.width() - self.GAP * (columns + 1)) / columns)
            panel_height = max(float(self.HEADER + 1), (self.height() - self.GAP * (rows + 1)) / rows)
            result = []
            for index in range(count):
                col, row = index % columns, index // columns
                outer = QRectF(self.GAP + col * (panel_width + self.GAP),
                               self.GAP + row * (panel_height + self.GAP),
                               panel_width, panel_height)
                content = outer.adjusted(1, self.HEADER, -1, -1)
                result.append((index, outer, content))
            return result
        outer = QRectF(self.GAP, self.GAP, max(1, self.width() - 2 * self.GAP),
                       max(self.HEADER + 1, self.height() - 2 * self.GAP))
        return [(self.selected_index, outer, outer.adjusted(1, self.HEADER, -1, -1))]

    def _panel_at(self, position):
        panels = self._panels()
        for index, outer, content in panels:
            if outer.contains(position):
                return index, outer, content
        return None

    def _source_point(self, position, content):
        return QPointF(self.center[0] + (position.x() - content.center().x()) / self.zoom,
                       self.center[1] + (position.y() - content.center().y()) / self.zoom)

    def _canvas_point(self, point, content):
        return QPointF(content.center().x() + (point[0] - self.center[0]) * self.zoom,
                       content.center().y() + (point[1] - self.center[1]) * self.zoom)

    def _image_dimensions(self, index):
        height, width = self.items[index].pixels.shape[:2]
        if self.view_mode == "fft":
            height = 1 << (height - 1).bit_length()
            width = 1 << (width - 1).bit_length()
        return width, height

    def fit(self):
        panels = self._panels()
        if not panels:
            return
        width = max(self._image_dimensions(i)[0] for i in range(len(self.items)))
        height = max(self._image_dimensions(i)[1] for i in range(len(self.items)))
        content = panels[0][2]
        self.center = (width / 2.0, height / 2.0)
        self.zoom = max(1 / 16384.0, min(256.0, .96 * min(content.width() / width, content.height() / height)))
        self._view_changed()

    def zoom_by(self, factor, anchor=None):
        if not math.isfinite(factor) or factor <= 0:
            return
        old_zoom = self.zoom
        new_zoom = max(1 / 16384.0, min(256.0, old_zoom * factor))
        if anchor is not None:
            anchor = QPointF(anchor)
            panel = self._panel_at(anchor)
            if panel and panel[2].contains(anchor):
                before = self._source_point(anchor, panel[2])
                self.zoom = new_zoom
                after = self._source_point(anchor, panel[2])
                self.center = (self.center[0] + before.x() - after.x(),
                               self.center[1] + before.y() - after.y())
        self.zoom = new_zoom
        self._view_changed()

    def one_to_one(self):
        self.zoom = 1.0
        self._view_changed()

    def pan(self, dx, dy):
        if math.isfinite(dx) and math.isfinite(dy):
            self.center = (self.center[0] + dx, self.center[1] + dy)
            self._view_changed()

    def zoom_to_roi(self):
        panels = self._panels()
        if not panels or self.roi is None:
            return
        x, y, width, height = self.roi
        if width <= 0 or height <= 0:
            return
        self.center = (x + width / 2.0, y + height / 2.0)
        content = panels[0][2]
        self.zoom = max(1 / 16384.0, min(256.0, .96 * min(content.width() / width, content.height() / height)))
        self._view_changed()

    def _view_changed(self):
        # Old viewport caches have no use after pan/zoom, and clearing bounds memory
        # during long continuous mouse gestures.
        self._patches.clear()
        self._patch_bytes = 0
        self.update()
        self.viewChanged.emit()
        self._schedule_warm()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._view_changed()

    def _derived_key(self, index):
        item = self.items[index]
        reference = self.items[self.reference_index] if self.items else item
        return (item.id, item.revision, id(item.pixels), reference.id, reference.revision,
                id(reference.pixels), self.view_mode, float(self.gain))

    def _pixels(self, index):
        item = self.items[index]
        if self.view_mode == "images":
            return item.pixels
        key = self._derived_key(index)
        if key in self._derived:
            self._derived.move_to_end(key)
            value = self._derived[key]
            if isinstance(value, Exception):
                raise value
            return value
        try:
            array = engine.derived(item.pixels, self.items[self.reference_index].pixels,
                                   self.view_mode, self.gain)
        except Exception as error:
            self._derived[key] = error
            while len(self._derived) > 16:
                _, removed = self._derived.popitem(last=False)
                if isinstance(removed, np.ndarray):
                    self._derived_bytes -= removed.nbytes
            raise
        self._derived[key] = array
        self._derived_bytes += array.nbytes
        while len(self._derived) > 1 and (self._derived_bytes > self.MAX_DERIVED_BYTES or len(self._derived) > 16):
            _, removed = self._derived.popitem(last=False)
            if isinstance(removed, np.ndarray):
                self._derived_bytes -= removed.nbytes
        return array

    def _patch_key(self, index, content):
        dpr = max(1.0, self.devicePixelRatioF())
        return (self._derived_key(index), round(self.center[0], 9), round(self.center[1], 9),
                round(self.zoom, 12), round(content.width(), 5), round(content.height(), 5),
                self.kernel, round(dpr, 4))

    def _patch(self, index, content):
        key = self._patch_key(index, content)
        if key in self._patches:
            self._patches.move_to_end(key)
            return self._patches[key]
        dpr = max(1.0, self.devicePixelRatioF())
        width = max(1, int(math.ceil(content.width() * dpr)))
        height = max(1, int(math.ceil(content.height() * dpr)))
        origin = (self.center[0] - content.width() / (2 * self.zoom),
                  self.center[1] - content.height() / (2 * self.zoom))
        patch = engine.render_patch(self._pixels(index), origin, self.zoom * dpr,
                                    width, height, self.kernel)
        qimage = array_to_qimage(patch)
        qimage.setDevicePixelRatio(dpr)
        self._patches[key] = qimage
        self._patch_bytes += qimage.sizeInBytes()
        while len(self._patches) > 1 and (self._patch_bytes > self.CACHE_BYTES or len(self._patches) > 24):
            _, removed = self._patches.popitem(last=False)
            self._patch_bytes -= removed.sizeInBytes()
        return qimage

    def _schedule_warm(self):
        if self._warm_pending or not self.items or self.mode != "flicker":
            return
        self._warm_pending = True
        self._warm_timer.start(0)

    def _warm_one(self):
        self._warm_pending = False
        if not self.items or self.mode != "flicker" or not self.isVisible():
            return
        panels = self._panels()
        if not panels:
            return
        content = panels[0][2]
        # At most 16 candidates are warmed. Current and paired images always go
        # first; each event-loop turn computes one image so input remains usable.
        estimated_bytes = max(1, math.ceil(content.width() * self.devicePixelRatioF()) *
                              math.ceil(content.height() * self.devicePixelRatioF()) * 4)
        capacity = max(1, min(16, self.CACHE_BYTES // estimated_bytes))
        indices = list(dict.fromkeys([self.selected_index, self.partner_index] + list(range(len(self.items)))))[:capacity]
        for index in indices:
            if self._patch_key(index, content) not in self._patches:
                try:
                    self._patch(index, content)
                except Exception:
                    return
                self._schedule_warm()
                return

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("#10161c"))
        if not self.items:
            painter.setPen(QColor("#adbac7"))
            painter.setFont(QFont("Segoe UI", 13))
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter,
                             "Drop images here\n\nOpen images · Paste · Demo")
            painter.end()
            return
        for index, outer, content in self._panels():
            painter.save()
            painter.setPen(QPen(QColor("#39c8ae") if index == self.selected_index else QColor("#38444f"), 1.5))
            painter.setBrush(QColor("#182129"))
            painter.drawRoundedRect(outer, 5, 5)
            painter.setClipRect(content)
            painter.drawTiledPixmap(content, self._checker)
            if self.mode == "wipe":
                boundary = content.left() + max(0, min(1, self.wipe_position)) * content.width()
                left_rect = QRectF(content.left(), content.top(), max(0, boundary - content.left()), content.height())
                right_rect = QRectF(boundary, content.top(), max(0, content.right() - boundary), content.height())
                self._paint_image(painter, self.partner_index, content, left_rect)
                self._paint_image(painter, self.selected_index, content, right_rect)
                painter.setClipRect(content)
                painter.setPen(QPen(QColor("#f6f0dd"), 2))
                painter.drawLine(QPointF(boundary, content.top()), QPointF(boundary, content.bottom()))
                painter.setPen(Qt.PenStyle.NoPen)
                painter.setBrush(QColor("#f6f0dd"))
                painter.drawRoundedRect(QRectF(boundary - 5, content.center().y() - 17, 10, 34), 5, 5)
            else:
                self._paint_image(painter, index, content, content)
            painter.restore()
            self._paint_header(painter, index, outer)
        painter.end()
        self._schedule_warm()

    def _paint_header(self, painter, index, outer):
        painter.save()
        painter.setPen(QColor("#e5edf4"))
        painter.setFont(QFont("Segoe UI", 9))
        title = f"{index + 1}  {self.items[index].name}"
        if self.mode == "wipe":
            title = f"{self.partner_index + 1} {self.items[self.partner_index].name}  |  {title}"
        badge = "REF" if index == self.reference_index else ""
        room = max(1, int(outer.width() - 18 - (40 if badge else 0)))
        title = painter.fontMetrics().elidedText(title, Qt.TextElideMode.ElideMiddle, room)
        painter.drawText(QRectF(outer.left() + 8, outer.top(), room, self.HEADER),
                         Qt.AlignmentFlag.AlignVCenter, title)
        if badge:
            painter.setPen(QColor("#59e1c7"))
            painter.drawText(QRectF(outer.right() - 39, outer.top(), 31, self.HEADER),
                             Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignRight, badge)
        painter.restore()

    def _paint_image(self, painter, index, content, clip):
        painter.save()
        painter.setClipRect(clip, Qt.ClipOperation.IntersectClip)
        try:
            painter.drawImage(content.topLeft(), self._patch(index, content))
        except Exception as error:
            self._last_error = str(error)
            painter.setPen(QColor("#eeb78e"))
            painter.drawText(content.adjusted(14, 10, -14, -10),
                             Qt.AlignmentFlag.AlignCenter | Qt.TextFlag.TextWordWrap, str(error))
            painter.restore()
            return
        if self.view_mode != "fft":
            if self.show_pixel_grid and self.zoom >= 12:
                self._paint_grid(painter, index, content)
            painter.save()
            painter.translate(content.center().x() - self.center[0] * self.zoom,
                              content.center().y() - self.center[1] * self.zoom)
            painter.scale(self.zoom, self.zoom)
            self._paint_annotations(painter, self.items[index].id)
            painter.restore()
            self._paint_selection(painter, content)
        painter.restore()

    def _paint_grid(self, painter, index, content):
        width, height = self._image_dimensions(index)
        top_left = self._source_point(content.topLeft(), content)
        bottom_right = self._source_point(content.bottomRight(), content)
        left = max(0, int(math.floor(top_left.x())))
        right = min(width, int(math.ceil(bottom_right.x())))
        top = max(0, int(math.floor(top_left.y())))
        bottom = min(height, int(math.ceil(bottom_right.y())))
        painter.save()
        painter.setPen(QPen(QColor(255, 255, 255, 50), 1))
        for x in range(left, right + 1):
            painter.drawLine(self._canvas_point((x, top), content), self._canvas_point((x, bottom), content))
        for y in range(top, bottom + 1):
            painter.drawLine(self._canvas_point((left, y), content), self._canvas_point((right, y), content))
        painter.restore()

    def _paint_selection(self, painter, content):
        painter.save()
        if self.roi is not None:
            x, y, width, height = self.roi
            start = self._canvas_point((x, y), content)
            end = self._canvas_point((x + width, y + height), content)
            painter.setPen(QPen(QColor("#f8c66f"), 1.5, Qt.PenStyle.DashLine))
            painter.setBrush(QColor(248, 198, 111, 20))
            painter.drawRect(QRectF(start, end).normalized())
        if self.inspection_point is not None:
            x, y = self.inspection_point
            point = self._canvas_point((x + .5, y + .5), content)
            painter.setPen(QPen(QColor("#ffffff"), 1))
            painter.drawLine(point + QPointF(-8, 0), point + QPointF(8, 0))
            painter.drawLine(point + QPointF(0, -8), point + QPointF(0, 8))
            if self.zoom >= 4:
                painter.setBrush(Qt.BrushStyle.NoBrush)
                painter.drawRect(QRectF(self._canvas_point((x, y), content),
                                        self._canvas_point((x + 1, y + 1), content)))
        painter.restore()

    def _paint_annotations(self, painter, item_id):
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        marks = self.annotations + ([self._draft] if self._draft else [])
        for annotation in marks:
            if not isinstance(annotation, dict):
                continue
            if annotation.get("image_id") not in (None, item_id):
                continue
            try:
                self._paint_annotation(painter, annotation)
            except (TypeError, ValueError, KeyError, OverflowError):
                continue
        painter.restore()

    @staticmethod
    def _paint_annotation(painter, annotation):
        kind = annotation["tool"]
        start = QPointF(*annotation["start"])
        end = QPointF(*annotation.get("end", annotation["start"]))
        if any(not math.isfinite(value) or abs(value) > 1e7
               for value in (start.x(), start.y(), end.x(), end.y())):
            return
        color = QColor(annotation.get("color", "#ff42ddc2"))
        width = max(.1, min(4096, float(annotation.get("width", 2))))
        pen = QPen(color, width, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        if kind == "rectangle":
            painter.drawRect(QRectF(start, end).normalized())
        elif kind == "circle":
            painter.drawEllipse(QRectF(start, end).normalized())
        elif kind == "line":
            painter.drawLine(start, end)
        elif kind == "dot":
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(color)
            painter.drawEllipse(start, max(.5, width / 2), max(.5, width / 2))
        elif kind == "brush":
            points = annotation.get("points", [annotation["start"], annotation.get("end", annotation["start"])])
            if not isinstance(points, list) or len(points) > 100000:
                return
            if len(points) <= 1:
                painter.drawPoint(start)
            else:
                path = QPainterPath(QPointF(*points[0]))
                for point in points[1:]:
                    if len(point) != 2 or any(not math.isfinite(float(v)) or abs(float(v)) > 1e7 for v in point):
                        return
                    path.lineTo(QPointF(*point))
                painter.drawPath(path)
        elif kind == "text":
            font = QFont("Segoe UI")
            font.setPixelSize(max(1, min(4096, round(float(annotation.get("font_size", 24))))))
            painter.setFont(font)
            # The placement point is the upper-left corner of the first line.
            metrics = painter.fontMetrics()
            for line_index, line in enumerate(str(annotation.get("text", ""))[:10000].splitlines()):
                painter.drawText(start + QPointF(0, metrics.ascent() + line_index * metrics.lineSpacing()), line)

    def _new_annotation(self, kind, point, index):
        return {"id": str(uuid.uuid4()), "tool": kind,
                "start": [point.x(), point.y()], "end": [point.x(), point.y()],
                "image_id": None if self.shared_annotations else self.items[index].id,
                "width": float(self.draw_width), "color": self.draw_color.name(QColor.NameFormat.HexArgb),
                "font_size": float(self.font_size)}

    def _commit_annotation(self, annotation):
        self.annotations.append(annotation)
        self._draft = None
        self.annotationsChanged.emit()
        self.update()

    def clear_annotations(self):
        self.annotations.clear()
        self._draft = None
        self.annotationsChanged.emit()
        self.update()

    def _delete_annotation(self):
        item_id = self.items[self.selected_index].id if self.items else None
        for index in range(len(self.annotations) - 1, -1, -1):
            if isinstance(self.annotations[index], dict) and self.annotations[index].get("image_id") in (None, item_id):
                self.annotations.pop(index)
                self.annotationsChanged.emit()
                self.update()
                break

    def _inside(self, point, index):
        width, height = self._image_dimensions(index)
        return 0 <= point.x() < width and 0 <= point.y() < height

    def _inspect(self, point, index):
        if self._inside(point, index):
            self.inspection_point = (int(math.floor(point.x())), int(math.floor(point.y())))
            self.pixelPicked.emit(self.inspection_point)
            self.update()

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton or not self.items:
            super().mousePressEvent(event)
            return
        self.setFocus(Qt.FocusReason.MouseFocusReason)
        position = event.position()
        panel = self._panel_at(position)
        if not panel:
            return
        index, outer, content = panel
        if self.mode == "split" and index != self.selected_index:
            self.selected_index = index
            self.selected.emit(index)
        if not content.contains(position):
            self.update()
            return
        self._drag_start = QPointF(position)
        self._drag_content = QRectF(content)
        self._drag_index = index
        self._drag_source = self._source_point(position, content)
        self._drag_center = self.center
        self._dragged = False
        if self.mode == "wipe":
            boundary = content.left() + self.wipe_position * content.width()
            if abs(position.x() - boundary) <= 10:
                self._drag_wipe = True
                self.setCursor(Qt.CursorShape.SplitHCursor)
                return
            if position.x() < boundary:
                self._drag_index = self.partner_index
        if self.tool == "pan":
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
        elif self.view_mode == "fft":
            # A frequency coordinate is not a source-image pixel or annotation.
            self._cancel_drag()
        elif self.tool == "inspect":
            self._inspect(self._drag_source, self._drag_index)
        elif self.tool == "dot" and self._inside(self._drag_source, self._drag_index):
            point = QPointF(math.floor(self._drag_source.x()) + .5, math.floor(self._drag_source.y()) + .5)
            self._commit_annotation(self._new_annotation("dot", point, self._drag_index))
        elif self.tool == "text" and self._inside(self._drag_source, self._drag_index):
            point, item_index = QPointF(self._drag_source), self._drag_index
            self._cancel_drag()
            text, accepted = QInputDialog.getMultiLineText(self, "Add text", "Text:")
            if accepted and text:
                annotation = self._new_annotation("text", point, item_index)
                annotation["text"] = text
                self._commit_annotation(annotation)
        elif self.tool in ("rectangle", "circle", "line", "brush") and self._inside(self._drag_source, self._drag_index):
            self._draft = self._new_annotation(self.tool, self._drag_source, self._drag_index)
            if self.tool == "brush":
                self._draft["points"] = [[self._drag_source.x(), self._drag_source.y()]]
        self.update()
        event.accept()

    def mouseMoveEvent(self, event):
        position = event.position()
        if self._drag_start is None:
            if self.mode == "wipe" and self.items:
                panel = self._panel_at(position)
                if panel and abs(position.x() - (panel[2].left() + self.wipe_position * panel[2].width())) <= 10:
                    self.setCursor(Qt.CursorShape.SplitHCursor)
                else:
                    self.setCursor(Qt.CursorShape.OpenHandCursor if self.tool == "pan" else Qt.CursorShape.CrossCursor)
            return
        difference = position - self._drag_start
        if abs(difference.x()) + abs(difference.y()) > 3:
            self._dragged = True
        if self._drag_wipe:
            self.wipe_position = max(0.0, min(1.0, (position.x() - self._drag_content.left()) / max(1, self._drag_content.width())))
            self.update()
            self.viewChanged.emit()
            return
        point = self._source_point(position, self._drag_content)
        if self.tool == "pan":
            self.center = (self._drag_center[0] - difference.x() / self.zoom,
                           self._drag_center[1] - difference.y() / self.zoom)
            self._view_changed()
        elif self.tool == "inspect":
            self._inspect(point, self._drag_index)
        elif self.tool == "select":
            self._update_roi(point)
        elif self._draft is not None:
            self._draft["end"] = [point.x(), point.y()]
            if self.tool == "brush":
                previous = self._draft["points"][-1]
                if math.hypot(point.x() - previous[0], point.y() - previous[1]) >= .25 / self.zoom:
                    self._draft["points"].append([point.x(), point.y()])
            self.update()
        event.accept()

    def _update_roi(self, point):
        if self.view_mode == "fft":
            return
        width, height = self._image_dimensions(self._drag_index)
        left = min(width, max(0, int(math.floor(min(point.x(), self._drag_source.x())))))
        top = min(height, max(0, int(math.floor(min(point.y(), self._drag_source.y())))))
        right = min(width, max(0, int(math.ceil(max(point.x(), self._drag_source.x())))))
        bottom = min(height, max(0, int(math.ceil(max(point.y(), self._drag_source.y())))))
        self.roi = (left, top, right - left, bottom - top) if right > left and bottom > top else None
        self.update()

    def mouseReleaseEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton or self._drag_start is None:
            super().mouseReleaseEvent(event)
            return
        if self._drag_wipe:
            self._cancel_drag()
            self.update()
            return
        point = self._source_point(event.position(), self._drag_content)
        if self.tool == "select":
            self._update_roi(point)
            self.roiChanged.emit(self.roi)
        elif self._draft is not None:
            self._draft["end"] = [point.x(), point.y()]
            if self._dragged or self.tool == "brush":
                if self.tool == "brush":
                    self._draft["points"].append([point.x(), point.y()])
                self._commit_annotation(self._draft)
            else:
                self._draft = None
        elif self.tool == "pan" and self.mode == "flicker" and not self._dragged:
            self.cycleRequested.emit(0)
        self._cancel_drag()
        self.update()
        event.accept()

    def _cancel_drag(self):
        self._drag_start = None
        self._drag_source = None
        self._drag_center = None
        self._drag_content = None
        self._drag_wipe = False
        self.setCursor(Qt.CursorShape.OpenHandCursor if self.tool == "pan" else Qt.CursorShape.CrossCursor)

    def wheelEvent(self, event):
        modifiers = event.modifiers()
        if modifiers & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier):
            delta = event.angleDelta().y() / 120.0
            if not delta:
                delta = event.pixelDelta().y() / 60.0
            self.zoom_by(1.2 ** max(-12, min(12, delta)), event.position())
        else:
            delta = event.pixelDelta()
            if delta.isNull():
                delta = event.angleDelta() / 4
            self.pan(-delta.x() / self.zoom, -delta.y() / self.zoom)
        event.accept()

    def keyPressEvent(self, event):
        key = event.key()
        mods = event.modifiers()
        if mods & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier):
            # Main-window application shortcuts (paste/copy/undo/open) keep priority.
            super().keyPressEvent(event)
            return
        if key == Qt.Key.Key_Tab:
            self.modeRequested.emit()
        elif Qt.Key.Key_1 <= key <= Qt.Key.Key_9:
            index = key - Qt.Key.Key_1
            if index < len(self.items):
                self.selected_index = index
                self.selected.emit(index)
                self.update()
        elif key == Qt.Key.Key_Space:
            self.cycleRequested.emit(0)
        elif key in (Qt.Key.Key_N, Qt.Key.Key_BracketRight):
            self.cycleRequested.emit(1)
        elif key == Qt.Key.Key_BracketLeft:
            self.cycleRequested.emit(-1)
        elif key in (Qt.Key.Key_Plus, Qt.Key.Key_Equal):
            self.zoom_by(1.25)
        elif key in (Qt.Key.Key_Minus, Qt.Key.Key_Underscore):
            self.zoom_by(1 / 1.25)
        elif key == Qt.Key.Key_0:
            self.one_to_one()
        elif key == Qt.Key.Key_F:
            self.fit()
        elif key in (Qt.Key.Key_Left, Qt.Key.Key_Right, Qt.Key.Key_Up, Qt.Key.Key_Down):
            step = 1.0 if mods & Qt.KeyboardModifier.AltModifier else 32 / self.zoom
            dx = step if key == Qt.Key.Key_Right else -step if key == Qt.Key.Key_Left else 0
            dy = step if key == Qt.Key.Key_Down else -step if key == Qt.Key.Key_Up else 0
            self.pan(dx, dy)
        elif key == Qt.Key.Key_Escape:
            self._draft = None
            self._cancel_drag()
            self.roi = None
            self.roiChanged.emit(None)
            self.update()
        elif key in (Qt.Key.Key_Delete, Qt.Key.Key_Backspace):
            self._delete_annotation()
        else:
            tools = {Qt.Key.Key_P: "pan", Qt.Key.Key_I: "inspect", Qt.Key.Key_S: "select",
                     Qt.Key.Key_R: "rectangle", Qt.Key.Key_C: "circle", Qt.Key.Key_D: "dot",
                     Qt.Key.Key_L: "line", Qt.Key.Key_B: "brush", Qt.Key.Key_T: "text"}
            if key in tools:
                self.set_tool(tools[key])
                self.toolRequested.emit(tools[key])
            else:
                super().keyPressEvent(event)
                return
        event.accept()

    def focusNextPrevChild(self, next):
        # Tab is an intentional comparison-mode shortcut while canvas-focused.
        self.modeRequested.emit()
        return True

    def export_image(self, index, roi=None):
        if not 0 <= index < len(self.items):
            raise ValueError("Select an image to export.")
        pixels = self._pixels(index)
        if self.view_mode == "fft":
            roi = None
        cropped = engine.crop(pixels, roi)
        result = array_to_qimage(cropped)
        if self.view_mode != "fft":
            painter = QPainter(result)
            if roi is not None:
                painter.translate(-roi[0], -roi[1])
            # Unfinished marks are never exported.
            draft, self._draft = self._draft, None
            try:
                self._paint_annotations(painter, self.items[index].id)
            finally:
                self._draft = draft
                painter.end()
        return result
