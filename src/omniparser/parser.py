"""Image processing and element detection."""
import base64
import io
import logging
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import torch
from ocrmac import ocrmac
from PIL import Image
from torchvision.ops import box_convert
from ultralytics import YOLO

from .utils.annotations import BoxAnnotator
from .utils.boxes import Detections, remove_overlapping_boxes
from .utils.colors import ColorPalette

logger = logging.getLogger(__name__)


class OmniParser:
    def __init__(self, weights_path: str = "weights/omniparser/icon_detect/best.pt"):
        self.model_path = Path(weights_path)
        if not self.model_path.exists():
            raise FileNotFoundError(f"YOLO weights not found at {self.model_path}")

        logger.info("Loading YOLO model...")
        self.model = YOLO(self.model_path)

    def detect_text(
        self,
        image: Image.Image,
        output_format: str = 'xyxy'
    ) -> Tuple[List[str], List[Tuple[float, float, float, float]]]:
        """Detect text in an image using OCR."""
        if image.mode != 'RGB':
            image = image.convert('RGB')

        ocr = ocrmac.OCR(image)
        ocr_results = ocr.recognize()

        img_width, img_height = image.size
        texts = []
        boxes = []

        for text, _, bbox in ocr_results:
            texts.append(text)
            x_rel, y_rel, w_rel, h_rel = bbox

            x = int(x_rel * img_width)
            y = int((1 - y_rel - h_rel) * img_height)
            w = int(w_rel * img_width)
            h = int(h_rel * img_height)

            if output_format == 'xywh':
                boxes.append((x, y, w, h))
            else:
                boxes.append((x, y, x + w, y + h))

        return texts, boxes

    def detect_objects(
        self,
        image: Image.Image,
        confidence_threshold: float = 0.3,
        iou_threshold: float = 0.7,
        image_size: int = 2048
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """Detect objects in an image using YOLO."""
        result = self.model.predict(
            source=image,
            conf=confidence_threshold,
            iou=iou_threshold,
            imgsz=image_size,
            verbose=False
        )[0]

        return result.boxes.xyxy, result.boxes.conf

    def process_image(
        self,
        image: Image.Image,
        confidence_threshold: float = 0.3,
        iou_threshold: float = 0.7,
        normalize_coordinates: bool = False,
        image_size: int = 2048
    ) -> Tuple[str, Dict, List[str]]:
        """Process an image to detect both text and objects."""
        if image.mode != 'RGB':
            image = image.convert('RGB')

        # Configure visualization parameters based on image size
        scale_factor = image.size[0] / 3200
        text_scale = 0.8 * scale_factor
        text_thickness = max(int(2 * scale_factor), 1)
        text_padding = max(int(3 * scale_factor), 1)
        box_thickness = max(int(3 * scale_factor), 1)

        # Detect text and objects
        try:
            texts, text_boxes = self.detect_text(image, output_format='xyxy')
        except Exception as e:
            logger.error("OCR detection failed: %s", str(e))
            texts, text_boxes = [], []

        object_boxes, confidence_scores = self.detect_objects(
            image,
            confidence_threshold,
            iou_threshold,
            image_size
        )

        # Normalize coordinates
        width, height = image.size
        image_array = np.asarray(image)

        if text_boxes:
            text_boxes = torch.tensor(text_boxes) / torch.tensor([width, height, width, height])
            text_elements = [
                {'type': 'text', 'bbox': box.tolist(), 'interactivity': False, 'content': text}
                for box, text in zip(text_boxes, texts, strict=False)
            ]
        else:
            text_elements = []

        object_boxes = object_boxes / torch.tensor([width, height, width, height]).to(object_boxes.device)
        object_elements = [
            {'type': 'icon', 'bbox': box.tolist(), 'interactivity': True, 'content': None}
            for box in object_boxes
        ]

        # Process and filter detections
        filtered_elements = remove_overlapping_boxes(
            boxes=object_elements,
            iou_threshold=iou_threshold,
            ocr_boxes=text_elements
        )

        # Sort elements (text first, then icons)
        sorted_elements = sorted(filtered_elements, key=lambda x: x['content'] is None)
        icon_start_idx = next(
            (i for i, elem in enumerate(sorted_elements) if elem['content'] is None),
            len(sorted_elements)
        )

        # Prepare boxes for visualization
        if not sorted_elements:
            logger.warning("No elements detected in image")
            element_boxes = torch.zeros((0, 4))
            box_labels = []
        else:
            element_boxes = torch.tensor([elem['bbox'] for elem in sorted_elements])
            if len(element_boxes) > 0:
                # Convert to absolute coordinates for visualization
                element_boxes = element_boxes * torch.tensor([width, height, width, height])
            box_labels = [f"id: {i}" for i in range(len(element_boxes))]

        interactive_count = len(sorted_elements[icon_start_idx:])
        logger.info("Detected %d interactive elements", interactive_count)

        # Generate content descriptions
        content_descriptions = [
            f"{'Text' if elem['type'] == 'text' else 'Icon'} Box ID {i}: {elem['content'] or ''}"
            for i, elem in enumerate(sorted_elements)
        ]

        # Create detections and annotate
        detections = Detections(xyxy=element_boxes.numpy())
        annotator = BoxAnnotator(
            color=ColorPalette.DEFAULT,
            text_scale=text_scale,
            text_thickness=text_thickness,
            text_padding=text_padding,
            thickness=box_thickness
        )

        annotated_image = annotator.annotate(
            scene=image_array,
            detections=detections,
            labels=box_labels,
            image_size=(width, height)
        )

        # Convert coordinates to xywh format for return
        xywh = box_convert(element_boxes, in_fmt="xyxy", out_fmt="xywh").numpy()
        label_coords = {str(i): box.tolist() for i, box in enumerate(xywh)}

        # Normalize coordinates if requested
        if normalize_coordinates:
            label_coords = {
                k: [v[0]/width, v[1]/height, v[2]/width, v[3]/height]
                for k, v in label_coords.items()
            }

        # Encode the annotated image
        output_image = Image.fromarray(annotated_image)
        buffer = io.BytesIO()
        output_image.save(buffer, format="PNG")
        encoded_image = base64.b64encode(buffer.getvalue()).decode('ascii')

        return encoded_image, label_coords, content_descriptions


# Initialize global parser instance
parser = OmniParser()
process_image = parser.process_image
