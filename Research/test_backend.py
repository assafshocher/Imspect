"""Protocol/validation tests need only stdlib; numerical tests use NumPy/Pillow.

These tests deliberately do not download or initialize model weights.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import backend

HAS_ARRAYS = importlib.util.find_spec("numpy") is not None and importlib.util.find_spec("PIL") is not None


class ProtocolTests(unittest.TestCase):
    def assert_error(self, request, code):
        with self.assertRaises(backend.RequestError) as context:
            backend.validate(request)
        self.assertEqual(context.exception.code, code)

    def test_capabilities_no_models_imported(self):
        already_imported = "torch" in sys.modules
        result = backend.execute({"operation": "capabilities"})
        self.assertTrue(result["ok"])
        self.assertFalse(result["models_verified"])
        self.assertEqual("torch" in sys.modules, already_imported)

    def test_invalid_operation(self):
        self.assert_error({"operation": "invented"}, "invalid_operation")

    def test_invalid_protocol(self):
        self.assert_error({"operation": "capabilities", "protocol": 99}, "unsupported_protocol")

    def test_non_object(self):
        self.assert_error([], "invalid_request")

    def test_relative_path(self):
        self.assert_error({"operation": "niqe", "image": "relative.png"}, "invalid_request")

    def test_download_opt_in(self):
        with tempfile.NamedTemporaryFile() as file:
            self.assert_error({"operation": "musiq", "image": file.name}, "model_downloads_not_enabled")

    def test_roi_rejects_fractional_and_bool_coordinates(self):
        with tempfile.NamedTemporaryFile() as file:
            for roi in ([0.5, 0, 10, 10], [True, 0, 10, 10], [-1, 0, 10, 10]):
                self.assert_error({"operation": "niqe", "image": file.name, "roi": roi}, "invalid_roi")

    def test_resize_bounds(self):
        with tempfile.NamedTemporaryFile() as file:
            output = str(Path(file.name).with_suffix(".png"))
            self.assert_error({"operation": "resize", "image": file.name, "output": output, "width": 0, "height": 4}, "invalid_size")

    def test_cli_bad_json_always_writes_response(self):
        with tempfile.TemporaryDirectory() as directory:
            request, response = Path(directory)/"request.json", Path(directory)/"response.json"
            request.write_text("{")
            result = subprocess.run([sys.executable, str(Path(backend.__file__)), "--request", str(request), "--response", str(response)], capture_output=True)
            self.assertEqual(result.returncode, 1)
            data = json.loads(response.read_text())
            self.assertFalse(data["ok"])
            self.assertEqual(data["error"]["code"], "file_or_json_error")


@unittest.skipUnless(HAS_ARRAYS, "NumPy and Pillow not installed")
class NumericalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, array):
        from PIL import Image
        import numpy as np
        path = self.directory/name
        Image.fromarray(np.array(array, dtype=np.uint8)).save(path)
        return path

    def test_roi_coordinates_top_left(self):
        import numpy as np
        array = np.zeros((4, 4, 3), dtype=np.uint8)
        array[1, 2] = [20, 40, 60]
        path = self.write("image.png", array)
        cropped, metadata = backend.load_image(path, [2, 1, 1, 1])
        np.testing.assert_allclose(cropped[0, 0], [20/255, 40/255, 60/255], rtol=1e-6)
        self.assertEqual(metadata["original_size"], [4, 4])

    def test_roi_outside_rejected(self):
        path = self.write("image.png", [[[0, 0, 0]]])
        with self.assertRaises(backend.RequestError) as error:
            backend.load_image(path, [0, 0, 2, 2])
        self.assertEqual(error.exception.code, "roi_out_of_bounds")

    def test_alpha_rejected_for_metrics(self):
        path = self.write("image.png", [[[20, 40, 60, 128]]])
        with self.assertRaises(backend.RequestError) as error:
            backend.load_image(path)
        self.assertEqual(error.exception.code, "transparent_image")

    def test_original_resize_right_identity(self):
        import numpy as np
        array = np.arange(6*8*3, dtype=np.uint8).reshape(6, 8, 3)
        path = self.write("image.png", array)
        output, raw = self.directory/"output.png", self.directory/"output.npy"
        result = backend.execute({"operation": "resize", "image": str(path), "output": str(output), "float_output": str(raw), "width": 8, "height": 6, "kernel": "cubic"})
        self.assertTrue(result["ok"])
        np.testing.assert_allclose(np.load(raw)[..., :3], array/255.0, atol=1e-7)
        self.assertEqual(result["metadata"]["engine"], "original vendored ResizeRight")

    def test_resize_constant_symmetric(self):
        import numpy as np
        path = self.write("image.png", np.full((9, 11, 3), 100, np.uint8))
        for kernel in ("cubic", "linear", "lanczos2", "lanczos3", "box"):
            raw = self.directory/(kernel+".npy")
            backend.execute({"operation": "resize", "image": str(path), "output": str(self.directory/(kernel+".png")), "float_output": str(raw), "width": 5, "height": 4, "kernel": kernel})
            np.testing.assert_allclose(np.load(raw)[..., :3], 100/255, atol=1e-7)

    def test_fft_constant_dc_center(self):
        import numpy as np
        path = self.write("image.png", np.full((8, 8, 3), 255, np.uint8))
        output = self.directory/"fft.png"
        result = backend.execute({"operation": "fft", "image": str(path), "output": str(output)})
        spectrum = np.load(result["metadata"]["raw_complex_spectrum"])
        self.assertEqual(np.unravel_index(np.abs(spectrum).argmax(), spectrum.shape), (4, 4))
        self.assertAlmostEqual(float(abs(spectrum[4, 4])), 64)

    def test_heatmap_fixed_scale_and_raw_preserved(self):
        import numpy as np
        values = np.array([[0, .5, 1, 2]], dtype=np.float32)
        result = backend.save_heatmap(values, self.directory/"map.png", 1)
        np.testing.assert_array_equal(np.load(result["raw_path"]), values)
        self.assertEqual(result["range"], [0, 1])


if __name__ == "__main__":
    unittest.main()
