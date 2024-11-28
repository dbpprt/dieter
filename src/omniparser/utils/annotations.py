"""Image annotation utilities for drawing boxes and labels."""
from dataclasses import dataclass
from typing import List, Optional, Tuple

import cv2
import numpy as np
import torch
from torchvision.ops import box_convert

from .boxes import Detections
from .colors import Color, ColorPalette


@dataclass
class LabelPosition:
    """Container for label position and background coordinates."""
    text_x: int
    text_y: int
    bg_x1: int
    bg_y1: int
    bg_x2: int
    bg_y2: int


def find_label_position(
    box: Tuple[int, int, int, int],
    text_size: Tuple[int, int],
    padding: int,
    detections: Detections,
    image_size: Tuple[int, int]
) -> LabelPosition:
    """Find optimal position for label that avoids overlaps."""
    x1, y1, x2, y2 = box
    text_width, text_height = text_size
    positions = [
        # Top left
        LabelPosition(
            x1 + padding,
            y1 - padding,
            x1,
            y1 - 2 * padding - text_height,
            x1 + 2 * padding + text_width,
            y1
        ),
        # Outer left
        LabelPosition(
            x1 - padding - text_width,
            y1 + padding + text_height,
            x1 - 2 * padding - text_width,
            y1,
            x1,
            y1 + 2 * padding + text_height
        ),
        # Outer right
        LabelPosition(
            x2 + padding,
            y1 + padding + text_height,
            x2,
            y1,
            x2 + 2 * padding + text_width,
            y1 + 2 * padding + text_height
        ),
        # Top right
        LabelPosition(
            x2 - padding - text_width,
            y1 - padding,
            x2 - 2 * padding - text_width,
            y1 - 2 * padding - text_height,
            x2,
            y1
        )
    ]

    def is_valid_position(pos: LabelPosition) -> bool:
        if (pos.bg_x1 < 0 or pos.bg_x2 > image_size[0] or
            pos.bg_y1 < 0 or pos.bg_y2 > image_size[1]):
            return False

        label_box = [pos.bg_x1, pos.bg_y1, pos.bg_x2, pos.bg_y2]
        for det_box in detections.xyxy:
            intersection = max(0, min(label_box[2], det_box[2]) - max(label_box[0], det_box[0])) * \
                         max(0, min(label_box[3], det_box[3]) - max(label_box[1], det_box[1]))
            if intersection > 0:
                return False
        return True

    for pos in positions:
        if is_valid_position(pos):
            return pos

    return positions[0]  # Default to top left if no valid position found


class BoxAnnotator:
    """Draws bounding boxes and labels on images."""
    def __init__(
        self,
        color: Color | ColorPalette = ColorPalette.DEFAULT,
        thickness: int = 3,
        text_scale: float = 0.5,
        text_thickness: int = 2,
        text_padding: int = 10,
        avoid_overlap: bool = True
    ):
        self.color = color
        self.thickness = thickness
        self.text_scale = text_scale
        self.text_thickness = text_thickness
        self.text_padding = text_padding
        self.avoid_overlap = avoid_overlap
        self.font = cv2.FONT_HERSHEY_SIMPLEX

    def _get_color(self, idx: int) -> Color:
        """Get color for given index."""
        return (self.color.by_idx(idx) if isinstance(self.color, ColorPalette)
                else self.color)

    def _get_text_color(self, box_color: Tuple[int, int, int]) -> Tuple[int, int, int]:
        """Determine text color based on background color luminance."""
        luminance = 0.299 * box_color[0] + 0.587 * box_color[1] + 0.114 * box_color[2]
        return (0, 0, 0) if luminance > 160 else (255, 255, 255)

    def draw_box(self, image: np.ndarray, box: np.ndarray, color: Color) -> None:
        """Draw bounding box on image."""
        cv2.rectangle(
            img=image,
            pt1=(int(box[0]), int(box[1])),
            pt2=(int(box[2]), int(box[3])),
            color=color.as_bgr(),
            thickness=self.thickness
        )

    def draw_label(
        self,
        image: np.ndarray,
        text: str,
        position: LabelPosition,
        color: Color
    ) -> None:
        """Draw label with background on image."""
        cv2.rectangle(
            img=image,
            pt1=(position.bg_x1, position.bg_y1),
            pt2=(position.bg_x2, position.bg_y2),
            color=color.as_bgr(),
            thickness=cv2.FILLED
        )

        cv2.putText(
            img=image,
            text=text,
            org=(position.text_x, position.text_y),
            fontFace=self.font,
            fontScale=self.text_scale,
            color=self._get_text_color(color.as_rgb()),
            thickness=self.text_thickness,
            lineType=cv2.LINE_AA
        )

    def annotate(
        self,
        scene: np.ndarray,
        detections: Detections,
        labels: Optional[List[str]] = None,
        skip_label: bool = False,
        image_size: Optional[Tuple[int, int]] = None
    ) -> np.ndarray:
        """Annotate scene with bounding boxes and labels."""
        annotated = scene.copy()
        if image_size is None:
            image_size = (scene.shape[1], scene.shape[0])

        for i in range(len(detections)):
            box = detections.xyxy[i].astype(int)
            class_id = detections.class_id[i] if detections.class_id is not None else i
            color = self._get_color(class_id)

            self.draw_box(annotated, box, color)

            if not skip_label:
                text = (str(class_id) if labels is None or len(detections) != len(labels)
                       else labels[i])

                text_size = cv2.getTextSize(
                    text=text,
                    fontFace=self.font,
                    fontScale=self.text_scale,
                    thickness=self.text_thickness
                )[0]

                position = (find_label_position(box, text_size, self.text_padding,
                                             detections, image_size)
                          if self.avoid_overlap else
                          LabelPosition(
                              box[0] + self.text_padding,
                              box[1] - self.text_padding,
                              box[0],
                              box[1] - 2 * self.text_padding - text_size[1],
                              box[0] + 2 * self.text_padding + text_size[0],
                              box[1]
                          ))

                self.draw_label(annotated, text, position, color)

        return annotated


def annotate(
    image_source: np.ndarray,
    boxes: torch.Tensor,
    logits: torch.Tensor,
    phrases: List[str],
    text_scale: float,
    text_padding: int = 5,
    text_thickness: int = 2,
    thickness: int = 3
) -> Tuple[np.ndarray, dict]:
    """Annotate an image with bounding boxes and labels."""
    h, w = image_source.shape[:2]
    boxes = boxes * torch.Tensor([w, h, w, h])
    xyxy = box_convert(boxes=boxes, in_fmt="cxcywh", out_fmt="xyxy").numpy()
    xywh = box_convert(boxes=boxes, in_fmt="cxcywh", out_fmt="xywh").numpy()

    detections = Detections(xyxy=xyxy)
    annotator = BoxAnnotator(
        text_scale=text_scale,
        text_padding=text_padding,
        text_thickness=text_thickness,
        thickness=thickness
    )

    annotated_frame = annotator.annotate(
        scene=image_source,
        detections=detections,
        labels=phrases,
        image_size=(w, h)
    )

    return annotated_frame, {str(i): box for i, box in enumerate(xywh)}
