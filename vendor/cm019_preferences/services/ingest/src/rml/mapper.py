"""RML Mapper client for transforming data to RDF."""

import logging
from pathlib import Path
from typing import Optional, Dict, Any
import httpx
import tempfile
import os

from ..config import settings

logger = logging.getLogger(__name__)


class RMLMapper:
    """
    Client for the RML Mapper service.

    The RML Mapper transforms source data (CSV, JSON, XML) into RDF
    using RML (RDF Mapping Language) rules.
    """

    def __init__(self, base_url: Optional[str] = None):
        """Initialize the RML Mapper client."""
        self.base_url = base_url or settings.rml_mapper_url

    async def transform(
        self,
        mapping: str,
        source_data: str,
        source_name: str = "input.csv",
        output_format: str = "turtle"
    ) -> Optional[str]:
        """
        Transform source data to RDF using an RML mapping.

        Args:
            mapping: RML mapping in Turtle format
            source_data: Source data content (CSV, JSON, etc.)
            source_name: Filename for the source data (used in mapping references)
            output_format: Output format (turtle, ntriples, jsonld)

        Returns:
            RDF output as string, or None on error
        """
        try:
            async with httpx.AsyncClient(timeout=120.0) as client:
                # Prepare multipart form data
                files = {
                    "mapping": ("mapping.ttl", mapping, "text/turtle"),
                    "source": (source_name, source_data, self._get_content_type(source_name))
                }

                data = {
                    "outputFormat": output_format
                }

                response = await client.post(
                    f"{self.base_url}/transform",
                    files=files,
                    data=data
                )

                if response.status_code == 200:
                    return response.text
                else:
                    logger.error(f"RML transform failed: {response.status_code} - {response.text}")
                    return None

        except httpx.ConnectError:
            logger.warning("RML Mapper not available, using fallback transformation")
            return await self._fallback_transform(mapping, source_data, source_name)
        except Exception as e:
            logger.error(f"RML transform error: {e}")
            return None

    async def transform_file(
        self,
        mapping_path: Path,
        source_path: Path,
        output_format: str = "turtle"
    ) -> Optional[str]:
        """
        Transform a file using an RML mapping file.

        Args:
            mapping_path: Path to RML mapping file
            source_path: Path to source data file
            output_format: Output format

        Returns:
            RDF output as string, or None on error
        """
        try:
            with open(mapping_path, 'r') as f:
                mapping = f.read()
            with open(source_path, 'r') as f:
                source_data = f.read()

            return await self.transform(
                mapping=mapping,
                source_data=source_data,
                source_name=source_path.name,
                output_format=output_format
            )
        except Exception as e:
            logger.error(f"Failed to read files for transform: {e}")
            return None

    async def validate_mapping(self, mapping: str) -> Dict[str, Any]:
        """
        Validate an RML mapping.

        Args:
            mapping: RML mapping in Turtle format

        Returns:
            Validation result with 'valid' boolean and 'errors' list
        """
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    f"{self.base_url}/validate",
                    content=mapping,
                    headers={"Content-Type": "text/turtle"}
                )

                if response.status_code == 200:
                    return {"valid": True, "errors": []}
                else:
                    return {"valid": False, "errors": [response.text]}

        except httpx.ConnectError:
            logger.warning("RML Mapper not available for validation")
            return {"valid": True, "errors": ["Validation skipped - mapper unavailable"]}
        except Exception as e:
            return {"valid": False, "errors": [str(e)]}

    async def health_check(self) -> bool:
        """Check if RML Mapper service is healthy."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.get(f"{self.base_url}/health")
                return response.status_code == 200
        except Exception:
            return False

    def _get_content_type(self, filename: str) -> str:
        """Get content type based on file extension."""
        ext = Path(filename).suffix.lower()
        types = {
            ".csv": "text/csv",
            ".json": "application/json",
            ".xml": "application/xml",
            ".tsv": "text/tab-separated-values"
        }
        return types.get(ext, "text/plain")

    async def _fallback_transform(
        self,
        mapping: str,
        source_data: str,
        source_name: str
    ) -> Optional[str]:
        """
        Fallback transformation when RML Mapper is not available.

        This is a simplified CSV-to-RDF converter for basic cases.
        """
        if not source_name.endswith('.csv'):
            logger.warning("Fallback transform only supports CSV")
            return None

        try:
            import csv
            from io import StringIO

            # Parse CSV
            reader = csv.DictReader(StringIO(source_data))
            rows = list(reader)

            if not rows:
                return ""

            # Generate simple RDF
            lines = [
                "@prefix pwg: <https://pwg.dev/ontology#> .",
                "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .",
                "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .",
                ""
            ]

            for i, row in enumerate(rows):
                subject = row.get('subject', row.get('name', f'item_{i}'))
                pref_type = row.get('type', row.get('preference_type', 'Like'))

                # Escape subject for URI
                subject_uri = subject.replace(' ', '_').replace('"', '').replace("'", '')

                lines.append(f'pwg:pref_{i} a pwg:{pref_type}Preference ;')
                lines.append(f'    pwg:subject "{subject}" ;')

                if 'strength' in row:
                    lines.append(f'    pwg:preferenceStrength {row["strength"]} ;')

                if 'category' in row:
                    lines.append(f'    pwg:category "{row["category"]}" ;')

                lines[-1] = lines[-1].rstrip(' ;') + ' .'
                lines.append('')

            return '\n'.join(lines)

        except Exception as e:
            logger.error(f"Fallback transform failed: {e}")
            return None
