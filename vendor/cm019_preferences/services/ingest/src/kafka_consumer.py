"""Kafka consumer for ingest requests."""

import json
import logging
import asyncio
from typing import Optional, Dict, Any
from pathlib import Path
from datetime import datetime

try:
    from aiokafka import AIOKafkaConsumer, AIOKafkaProducer
    KAFKA_AVAILABLE = True
except ImportError:
    KAFKA_AVAILABLE = False

from .config import settings
from .pipeline import pipeline

logger = logging.getLogger(__name__)


class IngestConsumer:
    """
    Kafka consumer for processing ingest requests.

    Message format:
    {
        "request_id": "uuid",
        "user_id": "user123",
        "file_path": "/data/ingest/file.csv",
        "source_type": "csv",  # optional hint
        "compartment_level": 2,  # optional
        "category": "music",  # optional
        "callback_topic": "pwg.ingest.results"  # optional
    }
    """

    def __init__(self):
        """Initialize the consumer."""
        self.consumer: Optional[Any] = None
        self.producer: Optional[Any] = None
        self.running = False

    async def start(self):
        """Start consuming messages."""
        if not KAFKA_AVAILABLE:
            logger.warning("aiokafka not installed, running in polling mode")
            return

        try:
            # Create consumer
            self.consumer = AIOKafkaConsumer(
                settings.kafka_ingest_topic,
                bootstrap_servers=settings.kafka_bootstrap_servers,
                group_id=settings.kafka_consumer_group,
                auto_offset_reset="earliest",
                enable_auto_commit=True,
                value_deserializer=lambda m: json.loads(m.decode("utf-8"))
            )

            # Create producer for results
            self.producer = AIOKafkaProducer(
                bootstrap_servers=settings.kafka_bootstrap_servers,
                value_serializer=lambda v: json.dumps(v).encode("utf-8")
            )

            await self.consumer.start()
            await self.producer.start()

            logger.info(f"Connected to Kafka, consuming from {settings.kafka_ingest_topic}")
            self.running = True

            # Start consuming
            await self._consume_loop()

        except Exception as e:
            logger.error(f"Failed to start Kafka consumer: {e}")

    async def _consume_loop(self):
        """Main consume loop."""
        try:
            async for message in self.consumer:
                if not self.running:
                    break

                try:
                    await self._process_message(message.value)
                except Exception as e:
                    logger.error(f"Failed to process message: {e}")

        except asyncio.CancelledError:
            pass

    async def _process_message(self, msg: Dict[str, Any]):
        """Process a single ingest request message."""
        request_id = msg.get("request_id", "unknown")
        user_id = msg.get("user_id")
        file_path = msg.get("file_path")

        if not user_id or not file_path:
            logger.error(f"Invalid message, missing user_id or file_path: {msg}")
            return

        logger.info(f"Processing ingest request {request_id} for user {user_id}")

        # Process the file
        path = Path(file_path)
        if not path.exists():
            result = {
                "request_id": request_id,
                "status": "error",
                "error": f"File not found: {file_path}",
                "timestamp": datetime.utcnow().isoformat()
            }
        else:
            try:
                ingest_result = await pipeline.ingest_file(
                    path,
                    user_id,
                    compartment_level=msg.get("compartment_level"),
                    category=msg.get("category")
                )

                result = {
                    "request_id": request_id,
                    "status": "success",
                    "preferences_created": ingest_result["preferences_created"],
                    "triples_inserted": ingest_result["triples_inserted"],
                    "vectors_inserted": ingest_result["vectors_inserted"],
                    "duration_seconds": ingest_result["duration_seconds"],
                    "errors": ingest_result["errors"],
                    "timestamp": datetime.utcnow().isoformat()
                }

            except Exception as e:
                result = {
                    "request_id": request_id,
                    "status": "error",
                    "error": str(e),
                    "timestamp": datetime.utcnow().isoformat()
                }

        # Send result if callback topic specified
        callback_topic = msg.get("callback_topic")
        if callback_topic and self.producer:
            await self._send_result(callback_topic, result)

        # Also send to events topic
        await self._emit_event("ingest.completed", result)

    async def _send_result(self, topic: str, result: Dict[str, Any]):
        """Send result to callback topic."""
        if self.producer:
            try:
                await self.producer.send_and_wait(topic, result)
                logger.debug(f"Sent result to {topic}")
            except Exception as e:
                logger.error(f"Failed to send result: {e}")

    async def _emit_event(self, event_type: str, data: Dict[str, Any]):
        """Emit event to events topic."""
        if self.producer:
            event = {
                "type": event_type,
                "data": data,
                "timestamp": datetime.utcnow().isoformat()
            }
            try:
                await self.producer.send_and_wait(settings.kafka_events_topic, event)
            except Exception as e:
                logger.error(f"Failed to emit event: {e}")

    async def stop(self):
        """Stop the consumer."""
        self.running = False

        if self.consumer:
            await self.consumer.stop()
        if self.producer:
            await self.producer.stop()

        logger.info("Kafka consumer stopped")
