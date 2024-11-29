"""Utilities for handling bounding boxes and detections."""

from dataclasses import dataclass
from typing import Dict, List, Optional

import numpy as np


@dataclass
class Detections:
    """Container for detection results with bounding boxes, class IDs, and confidence scores."""

    xyxy: np.ndarray
    class_id: Optional[np.ndarray] = None
    confidence: Optional[np.ndarray] = None

    def __len__(self) -> int:
        return len(self.xyxy)


def calculate_box_area(box: List[float]) -> float:
    """Calculate area of a bounding box [x1, y1, x2, y2]."""
    return (box[2] - box[0]) * (box[3] - box[1])


def calculate_intersection_area(box1: List[float], box2: List[float]) -> float:
    """Calculate intersection area between two bounding boxes."""
    x1 = max(box1[0], box2[0])
    y1 = max(box1[1], box2[1])
    x2 = min(box1[2], box2[2])
    y2 = min(box1[3], box2[3])
    return max(0, x2 - x1) * max(0, y2 - y1)


def calculate_iou(box1: List[float], box2: List[float], return_max: bool = False) -> float:
    """Calculate Intersection over Union between two bounding boxes."""
    intersection = calculate_intersection_area(box1, box2)
    union = calculate_box_area(box1) + calculate_box_area(box2) - intersection

    if calculate_box_area(box1) > 0 and calculate_box_area(box2) > 0:
        ratio1 = intersection / calculate_box_area(box1)
        ratio2 = intersection / calculate_box_area(box2)
    else:
        ratio1, ratio2 = 0, 0

    return max(intersection / union, ratio1, ratio2) if return_max else intersection / union


def is_box_inside(box1: List[float], box2: List[float], threshold: float = 0.95) -> bool:
    """Check if box1 is inside box2."""
    intersection = calculate_intersection_area(box1, box2)
    return intersection / calculate_box_area(box1) > threshold


def process_box_with_ocr(box: Dict, ocr_boxes: List[Dict]) -> Optional[Dict]:
    """Process a detection box with OCR boxes to determine type and content."""
    for ocr_box in ocr_boxes:
        if is_box_inside(ocr_box["bbox"], box["bbox"]):
            return {"type": "text", "bbox": box["bbox"], "interactivity": True, "content": ocr_box["content"]}
        elif is_box_inside(box["bbox"], ocr_box["bbox"]):
            return {"type": "icon", "bbox": box["bbox"], "interactivity": True, "content": None}
    return None


def remove_overlapping_boxes(boxes: List[Dict], iou_threshold: float, ocr_boxes: Optional[List] = None) -> List[Dict]:
    """Remove overlapping boxes and process OCR information if available."""
    filtered_boxes = []
    if ocr_boxes:
        filtered_boxes.extend(ocr_boxes)

    # First, sort boxes by area (largest first) to prioritize larger boxes
    sorted_boxes = sorted(boxes, key=lambda x: calculate_box_area(x["bbox"]), reverse=True)
    used_indices = set()

    for i, box1 in enumerate(sorted_boxes):
        if i in used_indices:
            continue

        is_valid = True
        for j, box2 in enumerate(sorted_boxes):
            if i != j and j not in used_indices:
                # Use standard IoU without max ratio
                if calculate_iou(box1["bbox"], box2["bbox"], return_max=False) > iou_threshold:
                    # Mark both boxes as used if they overlap significantly
                    used_indices.add(j)
                    is_valid = False

        if not is_valid:
            continue

        if ocr_boxes:
            processed_box = process_box_with_ocr(box1, ocr_boxes)
            if processed_box:
                filtered_boxes.append(processed_box)
            else:
                filtered_boxes.append({"type": "icon", "bbox": box1["bbox"], "interactivity": True, "content": None})
        else:
            filtered_boxes.append(box1["bbox"])

        used_indices.add(i)

    return filtered_boxes
