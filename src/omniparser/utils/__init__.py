"""Utility modules for OmniParser."""

from .annotations import BoxAnnotator, annotate
from .boxes import Detections, remove_overlapping_boxes
from .colors import Color, ColorPalette

__all__ = ["BoxAnnotator", "annotate", "Detections", "remove_overlapping_boxes", "Color", "ColorPalette"]
