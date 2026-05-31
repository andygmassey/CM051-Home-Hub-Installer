"""Ingest service main entry point."""

import asyncio
import logging
import signal
from typing import Optional
from pathlib import Path

from .config import settings
from .pipeline import pipeline
from .kafka_consumer import IngestConsumer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class IngestService:
    """
    Main ingest service that processes data from various sources.

    Modes:
    - Kafka consumer: Listens for ingest requests on Kafka topic
    - File watcher: Watches a directory for new files
    - One-shot: Processes a single file/directory and exits
    """

    def __init__(self):
        """Initialize the service."""
        self.consumer: Optional[IngestConsumer] = None
        self.running = False

    async def start(self, mode: str = "kafka"):
        """
        Start the ingest service.

        Args:
            mode: Operation mode - "kafka", "watch", or "oneshot"
        """
        logger.info(f"Starting ingest service in {mode} mode")

        # Initialize pipeline
        if not await pipeline.initialize():
            logger.error("Failed to initialize pipeline")
            return

        self.running = True

        if mode == "kafka":
            await self._run_kafka_mode()
        elif mode == "watch":
            await self._run_watch_mode()
        else:
            logger.error(f"Unknown mode: {mode}")

    async def _run_kafka_mode(self):
        """Run as Kafka consumer."""
        self.consumer = IngestConsumer()

        try:
            await self.consumer.start()

            while self.running:
                await asyncio.sleep(1)

        except asyncio.CancelledError:
            logger.info("Kafka mode cancelled")
        finally:
            if self.consumer:
                await self.consumer.stop()

    async def _run_watch_mode(self):
        """Watch directory for new files."""
        watch_dir = Path(settings.data_dir)
        watch_dir.mkdir(parents=True, exist_ok=True)

        logger.info(f"Watching directory: {watch_dir}")
        processed_files = set()

        try:
            while self.running:
                # Check for new files
                for file_path in watch_dir.glob("*"):
                    if file_path.is_file() and file_path not in processed_files:
                        logger.info(f"New file detected: {file_path}")

                        # Extract user_id from filename if present (format: user_id_filename.ext)
                        parts = file_path.stem.split("_", 1)
                        user_id = parts[0] if len(parts) > 1 else "default"

                        try:
                            result = await pipeline.ingest_file(file_path, user_id)
                            logger.info(f"Processed {file_path}: {result['preferences_created']} preferences")
                        except Exception as e:
                            logger.error(f"Failed to process {file_path}: {e}")

                        processed_files.add(file_path)

                await asyncio.sleep(5)  # Check every 5 seconds

        except asyncio.CancelledError:
            logger.info("Watch mode cancelled")

    async def stop(self):
        """Stop the service."""
        logger.info("Stopping ingest service")
        self.running = False

        if self.consumer:
            await self.consumer.stop()

    async def ingest_once(
        self,
        path: str,
        user_id: str,
        compartment_level: Optional[int] = None
    ):
        """
        One-shot ingestion of a file or directory.

        Args:
            path: Path to file or directory
            user_id: User ID
            compartment_level: Default compartment level
        """
        if not await pipeline.initialize():
            logger.error("Failed to initialize pipeline")
            return

        target = Path(path)

        if target.is_file():
            result = await pipeline.ingest_file(
                target,
                user_id,
                compartment_level=compartment_level
            )
            logger.info(f"Ingested file: {result}")
        elif target.is_dir():
            result = await pipeline.ingest_directory(
                target,
                user_id,
                compartment_level=compartment_level
            )
            logger.info(f"Ingested directory: {result}")
        else:
            logger.error(f"Path not found: {path}")


# Create service instance
service = IngestService()


def handle_shutdown(signum, frame):
    """Handle shutdown signals."""
    logger.info(f"Received signal {signum}")
    asyncio.create_task(service.stop())


async def main():
    """Main entry point."""
    import sys

    # Setup signal handlers
    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)

    # Parse command line args
    mode = "kafka"
    if len(sys.argv) > 1:
        if sys.argv[1] == "--watch":
            mode = "watch"
        elif sys.argv[1] == "--file" and len(sys.argv) > 3:
            # One-shot mode: --file <path> <user_id>
            await service.ingest_once(sys.argv[2], sys.argv[3])
            return
        elif sys.argv[1] == "--help":
            print("Usage: python -m src.main [--kafka|--watch|--file <path> <user_id>]")
            return

    await service.start(mode)


if __name__ == "__main__":
    asyncio.run(main())
