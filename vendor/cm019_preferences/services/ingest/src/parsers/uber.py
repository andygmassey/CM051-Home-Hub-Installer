"""Uber data parser - comprehensive extraction."""

import csv
import io
import logging
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional
from datetime import datetime
from collections import defaultdict
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


class UberParser(BaseParser):
    """
    Parser for Uber data exports.

    Extracts comprehensive data from:
    - Rider/trips_data-0.csv (individual ride records + aggregated patterns)
    - Eats/user_orders-0.csv (individual food orders + aggregated preferences)
    """

    source_name = "uber"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is an Uber data export."""
        name = file_path.name.lower()

        # Check for ZIP file with Uber naming convention
        if file_path.suffix.lower() == '.zip':
            if 'uber' in name:
                return True
            # Check ZIP contents
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    return any('uber data' in n or 'trips_data' in n for n in names)
            except:
                return False

        # Also handle individual CSV files
        if file_path.suffix.lower() == '.csv':
            return 'trips_data' in name or 'user_orders' in name

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Uber data export."""
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        logger.info(f"Parsing Uber data from {file_path}")

        if file_path.suffix.lower() == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.csv':
            name = file_path.name.lower()
            if 'trips_data' in name:
                async for pref in self._parse_trips_csv(file_path, default_compartment):
                    yield pref
            elif 'user_orders' in name:
                async for pref in self._parse_eats_csv(file_path, default_compartment):
                    yield pref

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Uber ZIP archive."""
        with zipfile.ZipFile(file_path, 'r') as zf:
            for name in zf.namelist():
                name_lower = name.lower()

                if 'trips_data' in name_lower and name_lower.endswith('.csv'):
                    content = zf.read(name).decode('utf-8')
                    async for pref in self._parse_trips_content(content, default_compartment):
                        yield pref

                elif 'user_orders' in name_lower and name_lower.endswith('.csv'):
                    content = zf.read(name).decode('utf-8')
                    async for pref in self._parse_eats_content(content, default_compartment):
                        yield pref

    async def _parse_trips_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse trips CSV file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()
        async for pref in self._parse_trips_content(content, default_compartment):
            yield pref

    async def _parse_eats_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Uber Eats CSV file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()
        async for pref in self._parse_eats_content(content, default_compartment):
            yield pref

    def _parse_timestamp(self, ts_str: str) -> Optional[datetime]:
        """Parse various timestamp formats."""
        if not ts_str:
            return None

        formats = [
            "%Y-%m-%dT%H:%M:%S.%fZ",
            "%Y-%m-%dT%H:%M:%SZ",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%d"
        ]

        for fmt in formats:
            try:
                return datetime.strptime(ts_str, fmt)
            except ValueError:
                continue
        return None

    def _get_time_of_day(self, dt: datetime) -> str:
        """Categorize time of day."""
        hour = dt.hour
        if 5 <= hour < 12:
            return "morning"
        elif 12 <= hour < 17:
            return "afternoon"
        elif 17 <= hour < 21:
            return "evening"
        else:
            return "night"

    def _get_day_type(self, dt: datetime) -> str:
        """Return weekday or weekend."""
        return "weekend" if dt.weekday() >= 5 else "weekday"

    async def _parse_trips_content(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Uber rides trips content - extract individual records + aggregates."""
        reader = csv.DictReader(io.StringIO(content))

        # Aggregation tracking
        product_usage = defaultdict(int)
        city_trips = defaultdict(int)
        time_of_day_trips = defaultdict(int)
        day_type_trips = defaultdict(int)
        airport_trips = 0
        scheduled_trips = 0
        surge_trips = 0
        total_distance = 0.0
        total_duration = 0
        total_fare = 0.0
        trip_count = 0

        trips = []

        for row in reader:
            try:
                status = row.get('status', '').lower()
                is_completed = row.get('is_completed', '').lower() == 'true'

                # Skip cancelled/incomplete trips for individual records
                # but still count them for aggregate patterns

                product_type = row.get('product_type_name', row.get('global_product_name', '')).strip()
                global_product = row.get('global_product_name', '').strip()
                city = row.get('city_name', '').strip()

                # Timestamps
                request_ts = row.get('request_timestamp_local', '')
                dropoff_ts = row.get('dropoff_timestamp_local', '')

                # Trip details
                distance_str = row.get('trip_distance_miles', '0')
                duration_str = row.get('trip_duration_seconds', '0')
                fare_str = row.get('fare_amount', '0')
                currency = row.get('currency_code', 'USD')

                # Locations
                pickup_address = row.get('begintrip_address', '').strip()
                dropoff_address = row.get('dropoff_address', '').strip()
                destination = row.get('destination_string', '').strip()

                # Flags
                is_surge = row.get('is_surged', '').lower() == 'true'
                surge_mult = row.get('surge_multiplier', '1.0')
                is_pool = row.get('is_pool_matched', '').lower() == 'true'
                is_scheduled = row.get('is_scheduled_trip', '').lower() == 'true'
                is_airport = row.get('is_airport_trip', '').lower() == 'true'

                # Parse values
                try:
                    distance = float(distance_str) if distance_str else 0.0
                except:
                    distance = 0.0

                try:
                    duration = int(float(duration_str)) if duration_str else 0
                except:
                    duration = 0

                try:
                    fare = float(fare_str) if fare_str else 0.0
                except:
                    fare = 0.0

                # Parse request timestamp for time patterns
                request_dt = self._parse_timestamp(request_ts)

                if status == 'completed' and is_completed:
                    trip_count += 1
                    total_distance += distance
                    total_duration += duration
                    total_fare += fare

                    if product_type:
                        product_usage[product_type] += 1
                    if city:
                        city_trips[city] += 1
                    if request_dt:
                        time_of_day_trips[self._get_time_of_day(request_dt)] += 1
                        day_type_trips[self._get_day_type(request_dt)] += 1
                    if is_airport:
                        airport_trips += 1
                    if is_scheduled:
                        scheduled_trips += 1
                    if is_surge:
                        surge_trips += 1

                    # Store trip for individual record creation
                    trips.append({
                        'city': city,
                        'product_type': product_type,
                        'global_product': global_product,
                        'request_ts': request_ts,
                        'request_dt': request_dt,
                        'dropoff_ts': dropoff_ts,
                        'pickup_address': pickup_address,
                        'dropoff_address': dropoff_address,
                        'destination': destination,
                        'distance': distance,
                        'duration': duration,
                        'fare': fare,
                        'currency': currency,
                        'is_surge': is_surge,
                        'surge_mult': surge_mult,
                        'is_pool': is_pool,
                        'is_scheduled': is_scheduled,
                        'is_airport': is_airport
                    })

            except Exception as e:
                logger.warning(f"Error parsing trip row: {e}")
                continue

        logger.info(f"Processed {trip_count} completed Uber trips")

        # ============================================
        # INDIVIDUAL TRIP RECORDS
        # ============================================
        for trip in trips:
            # Format duration
            duration_mins = trip['duration'] // 60
            if duration_mins >= 60:
                duration_str = f"{duration_mins // 60}h {duration_mins % 60}m"
            else:
                duration_str = f"{duration_mins}m"

            # Create descriptive subject
            if trip['destination']:
                subject = f"Uber trip to {trip['destination']}"
            elif trip['dropoff_address']:
                subject = f"Uber trip to {trip['dropoff_address']}"
            elif trip['city']:
                subject = f"Uber trip in {trip['city']}"
            else:
                subject = f"Uber {trip['product_type']} trip"

            # Format timestamp for display
            ts_display = None
            if trip['request_dt']:
                ts_display = trip['request_dt'].strftime("%Y-%m-%d %H:%M")

            extra = {
                "type": "trip_record",
                "city": trip['city'],
                "product_type": trip['product_type'],
                "global_product": trip['global_product'],
                "distance_miles": round(trip['distance'], 2),
                "duration_seconds": trip['duration'],
                "duration_display": duration_str,
                "fare": round(trip['fare'], 2),
                "currency": trip['currency'],
            }

            if trip['pickup_address']:
                extra["pickup_address"] = trip['pickup_address']
            if trip['dropoff_address']:
                extra["dropoff_address"] = trip['dropoff_address']
            if trip['destination']:
                extra["destination"] = trip['destination']
            if ts_display:
                extra["timestamp"] = ts_display
            if trip['is_surge']:
                extra["surge_multiplier"] = trip['surge_mult']
            if trip['is_pool']:
                extra["is_pool"] = True
            if trip['is_scheduled']:
                extra["is_scheduled"] = True
            if trip['is_airport']:
                extra["is_airport"] = True

            yield ParsedPreference(
                subject=subject,
                preference_type="Experience",
                category="transportation",
                strength=0.25,  # V2: Trip/order
                source=self.source_name,
                compartment_level=default_compartment,
                size="Micro",
                extra=extra
            )

        # ============================================
        # AGGREGATE PREFERENCES - Product Types
        # ============================================
        for product_type, count in sorted(product_usage.items(), key=lambda x: -x[1]):
            if count >= 2:
                strength = min(0.5 + (count * 0.01), 0.9)
                yield ParsedPreference(
                    subject=f"Uber {product_type}",
                    preference_type="Like",
                    category="transportation",
                    strength=strength,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "type": "ride_product_preference",
                        "product_type": product_type,
                        "trip_count": count,
                        "percentage": round(count / trip_count * 100, 1) if trip_count > 0 else 0
                    }
                )

        # ============================================
        # AGGREGATE PREFERENCES - Cities
        # ============================================
        for city, count in sorted(city_trips.items(), key=lambda x: -x[1]):
            if count >= 3:
                strength = min(0.5 + (count * 0.005), 0.85)
                yield ParsedPreference(
                    subject=f"using Uber in {city}",
                    preference_type="Like",
                    category="travel",
                    strength=strength,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "city_travel_pattern",
                        "city": city,
                        "trip_count": count,
                        "percentage": round(count / trip_count * 100, 1) if trip_count > 0 else 0
                    }
                )

        # ============================================
        # AGGREGATE PREFERENCES - Time Patterns
        # ============================================
        if time_of_day_trips:
            most_common_time = max(time_of_day_trips, key=time_of_day_trips.get)
            yield ParsedPreference(
                subject=f"{most_common_time} Uber rides",
                preference_type="Pattern",
                category="transportation",
                strength=0.25,  # V2: Trip/order
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "time_pattern",
                    "time_breakdown": dict(time_of_day_trips),
                    "most_common": most_common_time,
                    "count": time_of_day_trips[most_common_time]
                }
            )

        if day_type_trips:
            weekday_count = day_type_trips.get('weekday', 0)
            weekend_count = day_type_trips.get('weekend', 0)
            if weekday_count > 0 or weekend_count > 0:
                yield ParsedPreference(
                    subject="Uber usage by day type",
                    preference_type="Pattern",
                    category="transportation",
                    strength=0.20,  # V2: Pattern
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "day_type_pattern",
                        "weekday_trips": weekday_count,
                        "weekend_trips": weekend_count,
                        "weekday_percentage": round(weekday_count / trip_count * 100, 1) if trip_count > 0 else 0
                    }
                )

        # ============================================
        # AGGREGATE PREFERENCES - Special Trip Types
        # ============================================
        if airport_trips >= 2:
            yield ParsedPreference(
                subject="Uber airport trips",
                preference_type="Pattern",
                category="transportation",
                strength=0.25,  # V2: Trip/order
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "airport_travel",
                    "trip_count": airport_trips,
                    "percentage": round(airport_trips / trip_count * 100, 1) if trip_count > 0 else 0
                }
            )

        if scheduled_trips >= 2:
            yield ParsedPreference(
                subject="pre-scheduled Uber rides",
                preference_type="Pattern",
                category="transportation",
                strength=0.20,  # V2: Pattern
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "scheduled_rides",
                    "trip_count": scheduled_trips,
                    "percentage": round(scheduled_trips / trip_count * 100, 1) if trip_count > 0 else 0
                }
            )

        # ============================================
        # AGGREGATE - Overall Usage Statistics
        # ============================================
        if trip_count > 0:
            avg_distance = total_distance / trip_count
            avg_duration = total_duration / trip_count // 60  # minutes
            avg_fare = total_fare / trip_count

            yield ParsedPreference(
                subject="Uber ride statistics",
                preference_type="Summary",
                category="transportation",
                strength=0.35,  # V2: Repeat pattern
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "usage_statistics",
                    "total_trips": trip_count,
                    "total_distance_miles": round(total_distance, 1),
                    "total_duration_hours": round(total_duration / 3600, 1),
                    "total_fare": round(total_fare, 2),
                    "avg_distance_miles": round(avg_distance, 2),
                    "avg_duration_minutes": round(avg_duration),
                    "avg_fare": round(avg_fare, 2),
                    "surge_trip_count": surge_trips,
                    "cities_count": len(city_trips),
                    "product_types_count": len(product_usage)
                }
            )

    async def _parse_eats_content(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Uber Eats orders content - individual records + aggregates."""
        reader = csv.DictReader(io.StringIO(content))

        # Aggregate tracking
        restaurant_orders = defaultdict(lambda: {'count': 0, 'city': '', 'items': []})
        food_items = defaultdict(int)
        order_count = 0
        orders = []

        for row in reader:
            try:
                restaurant = row.get('Restaurant_Name', '').strip()
                item_name = row.get('Item_Name', '').strip()
                city = row.get('City_Name', '').strip()
                quantity_str = row.get('Item_quantity', '1')
                customizations = row.get('Customizations', '').strip()
                order_status = row.get('Order_Status', '').strip()
                request_time = row.get('Request_Time_Local', '')
                delivery_time = row.get('Final_Delivery_Time_Local', '')
                item_price_str = row.get('Item_Price', '0')
                order_price_str = row.get('Order_Price', '0')
                currency = row.get('Currency', 'USD')

                try:
                    quantity = int(quantity_str)
                except:
                    quantity = 1

                try:
                    item_price = float(item_price_str)
                except:
                    item_price = 0.0

                try:
                    order_price = float(order_price_str)
                except:
                    order_price = 0.0

                order_count += 1

                # Track restaurant orders
                if restaurant:
                    restaurant_orders[restaurant]['count'] += 1
                    restaurant_orders[restaurant]['city'] = city
                    if item_name:
                        restaurant_orders[restaurant]['items'].append(item_name)

                # Track food items
                if item_name:
                    # Clean up item name (remove quantity indicators)
                    clean_name = item_name.split(' - ')[0].strip()
                    food_items[clean_name] += quantity

                # Store individual order
                orders.append({
                    'restaurant': restaurant,
                    'item_name': item_name,
                    'city': city,
                    'quantity': quantity,
                    'customizations': customizations,
                    'status': order_status,
                    'request_time': request_time,
                    'delivery_time': delivery_time,
                    'item_price': item_price,
                    'order_price': order_price,
                    'currency': currency
                })

            except Exception as e:
                logger.warning(f"Error parsing Uber Eats row: {e}")
                continue

        logger.info(f"Processed {order_count} Uber Eats order items")

        # ============================================
        # INDIVIDUAL ORDER RECORDS
        # ============================================
        for order in orders:
            subject = f"{order['item_name']} from {order['restaurant']}"

            extra = {
                "type": "food_order_record",
                "restaurant": order['restaurant'],
                "item": order['item_name'],
                "city": order['city'],
                "quantity": order['quantity'],
                "status": order['status'],
                "item_price": order['item_price'],
                "currency": order['currency']
            }

            if order['customizations']:
                extra["customizations"] = order['customizations']
            if order['request_time']:
                ts = self._parse_timestamp(order['request_time'])
                if ts:
                    extra["timestamp"] = ts.strftime("%Y-%m-%d %H:%M")

            yield ParsedPreference(
                subject=subject,
                preference_type="Experience",
                category="food",
                strength=0.25,  # V2: Trip/order
                source=self.source_name,
                compartment_level=default_compartment,
                size="Micro",
                extra=extra
            )

        # ============================================
        # AGGREGATE PREFERENCES - Restaurants
        # ============================================
        for restaurant, data in sorted(restaurant_orders.items(), key=lambda x: -x[1]['count']):
            count = data['count']
            if count >= 1:
                strength = min(0.55 + (count * 0.1), 0.9)
                yield ParsedPreference(
                    subject=restaurant,
                    preference_type="Like",
                    category="food",
                    strength=strength,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "restaurant_preference",
                        "city": data['city'],
                        "order_count": count,
                        "sample_items": list(set(data['items']))[:5]
                    }
                )

        # ============================================
        # AGGREGATE PREFERENCES - Food Items
        # ============================================
        for item, count in sorted(food_items.items(), key=lambda x: -x[1]):
            if count >= 2:
                strength = min(0.5 + (count * 0.1), 0.85)
                yield ParsedPreference(
                    subject=item,
                    preference_type="Like",
                    category="food",
                    strength=strength,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Micro",
                    extra={
                        "type": "food_item_preference",
                        "order_count": count
                    }
                )
