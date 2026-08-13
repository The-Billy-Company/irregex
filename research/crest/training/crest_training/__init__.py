"""Corpus-independent CREST training evidence; never a production configuration source."""

from .proposal import build_proposal, build_validation_report

__all__ = ["build_proposal", "build_validation_report"]
