#!/usr/bin/env python3
"""
Download OmniParser YOLOv8 UI element detection weights from HuggingFace
and convert them to CoreML format for on-device inference in TipTour.

Output: TipTour/Models/OmniParserYOLO.mlpackage

Usage:
    python3 scripts/convert_omniparser_to_coreml.py
"""

import os
import sys
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
MODELS_DIR = REPO_ROOT / "TipTour" / "Models"
OUTPUT_PATH = MODELS_DIR / "OmniParserYOLO.mlpackage"
WEIGHTS_CACHE = REPO_ROOT / "scripts" / "weights_cache"

HUGGINGFACE_MODEL_ID = "microsoft/OmniParser-v2.0"
WEIGHTS_FILENAME = "icon_detect/model.pt"


def download_weights() -> Path:
    """Download OmniParser icon_detect weights from HuggingFace."""
    from huggingface_hub import hf_hub_download

    WEIGHTS_CACHE.mkdir(parents=True, exist_ok=True)
    local_weights_path = WEIGHTS_CACHE / "omniparser_icon_detect.pt"

    if local_weights_path.exists():
        print(f"[convert] Using cached weights at {local_weights_path}")
        return local_weights_path

    print(f"[convert] Downloading {WEIGHTS_FILENAME} from {HUGGINGFACE_MODEL_ID}...")
    downloaded = hf_hub_download(
        repo_id=HUGGINGFACE_MODEL_ID,
        filename=WEIGHTS_FILENAME,
        local_dir=str(WEIGHTS_CACHE),
    )
    # hf_hub_download puts it in a subdirectory; copy to flat location
    downloaded_path = Path(downloaded)
    if downloaded_path != local_weights_path:
        shutil.copy2(downloaded_path, local_weights_path)

    print(f"[convert] Weights saved to {local_weights_path}")
    return local_weights_path


def convert_to_coreml(weights_path: Path) -> None:
    """Convert YOLOv8 .pt weights to CoreML mlpackage."""
    from ultralytics import YOLO
    import coremltools as ct

    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    if OUTPUT_PATH.exists():
        print(f"[convert] Removing existing {OUTPUT_PATH}")
        shutil.rmtree(OUTPUT_PATH)

    print(f"[convert] Loading YOLOv8 model from {weights_path}...")
    model = YOLO(str(weights_path))

    # Export to CoreML with NMS baked in so Swift only needs to parse
    # the final bounding boxes — no post-processing needed in Swift.
    # imgsz=640 matches OmniParser's training resolution.
    # nms=True bakes non-maximum suppression into the CoreML graph.
    print("[convert] Exporting to CoreML (this may take 2-5 minutes)...")
    export_path = model.export(
        format="coreml",
        imgsz=640,
        nms=True,
        conf=0.25,   # confidence threshold baked in
        iou=0.45,    # IoU threshold for NMS
        half=False,  # float32 for Neural Engine compatibility
    )

    exported = Path(export_path)
    if not exported.exists():
        print(f"[convert] ERROR: export failed, expected {exported}")
        sys.exit(1)

    # ultralytics exports to the same directory as the weights file;
    # move the result to TipTour/Models/
    shutil.move(str(exported), str(OUTPUT_PATH))
    print(f"[convert] CoreML model saved to {OUTPUT_PATH}")

    # Print model metadata for verification
    spec = ct.models.MLModel(str(OUTPUT_PATH))
    print(f"[convert] Model inputs:  {[str(i) for i in spec.get_spec().description.input]}")
    print(f"[convert] Model outputs: {[str(o) for o in spec.get_spec().description.output]}")


def main():
    print("=== OmniParser → CoreML Converter ===\n")

    # Check dependencies
    try:
        import ultralytics
        print(f"[convert] ultralytics {ultralytics.__version__}")
    except ImportError:
        print("[convert] ERROR: ultralytics not installed. Run: pip3 install ultralytics")
        sys.exit(1)

    try:
        import coremltools as ct
        print(f"[convert] coremltools {ct.__version__}")
    except ImportError:
        print("[convert] ERROR: coremltools not installed. Run: pip3 install coremltools")
        sys.exit(1)

    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        print("[convert] ERROR: huggingface_hub not installed. Run: pip3 install huggingface_hub")
        sys.exit(1)

    weights_path = download_weights()
    convert_to_coreml(weights_path)

    print("\n=== Done ===")
    print(f"Add {OUTPUT_PATH.relative_to(REPO_ROOT)} to your Xcode project.")
    print("Drag TipTour/Models/OmniParserYOLO.mlpackage into the Xcode project navigator.")


if __name__ == "__main__":
    main()
