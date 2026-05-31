"""Spoonacular API client for recipe and ingredient analysis.

Enriches recipe preferences with cuisine type, dish type, ingredients,
dietary labels, and cooking methods.

Spoonacular API: https://spoonacular.com/food-api
- API key required (free tier: 150 requests/day)
- Rate limit: 1.5 req/sec
"""

import logging
import re
from typing import Any, Dict, List, Optional

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
    RecipeIngredient,
    RecipeNutrition,
    RecipeMetadata,
)

logger = logging.getLogger(__name__)


def extract_recipe_id(text: str) -> Optional[int]:
    """
    Extract Spoonacular recipe ID from URL or text.

    Args:
        text: Text that may contain a recipe ID

    Returns:
        Extracted recipe ID or None
    """
    if not text:
        return None

    text = text.strip()

    # Bare numeric ID
    if text.isdigit():
        return int(text)

    # Spoonacular URL patterns
    # https://spoonacular.com/recipes/recipe-name-123456
    url_match = re.search(r'spoonacular\.com/recipes/[^/]+-(\d+)', text, re.IGNORECASE)
    if url_match:
        return int(url_match.group(1))

    # recipe: prefix
    prefix_match = re.match(r'^recipe[:\s]*(\d+)$', text, re.IGNORECASE)
    if prefix_match:
        return int(prefix_match.group(1))

    return None


# Common cuisine mappings
CUISINE_MAPPINGS = {
    "african": "African",
    "american": "American",
    "british": "British",
    "cajun": "Cajun",
    "caribbean": "Caribbean",
    "chinese": "Chinese",
    "eastern european": "Eastern European",
    "european": "European",
    "french": "French",
    "german": "German",
    "greek": "Greek",
    "indian": "Indian",
    "irish": "Irish",
    "italian": "Italian",
    "japanese": "Japanese",
    "jewish": "Jewish",
    "korean": "Korean",
    "latin american": "Latin American",
    "mediterranean": "Mediterranean",
    "mexican": "Mexican",
    "middle eastern": "Middle Eastern",
    "nordic": "Nordic",
    "southern": "Southern",
    "spanish": "Spanish",
    "thai": "Thai",
    "vietnamese": "Vietnamese",
}

# Common dish type mappings
DISH_TYPE_MAPPINGS = {
    "main course": "Main Course",
    "side dish": "Side Dish",
    "dessert": "Dessert",
    "appetizer": "Appetizer",
    "salad": "Salad",
    "bread": "Bread",
    "breakfast": "Breakfast",
    "soup": "Soup",
    "beverage": "Beverage",
    "sauce": "Sauce",
    "marinade": "Marinade",
    "fingerfood": "Finger Food",
    "snack": "Snack",
    "drink": "Drink",
}


class SpoonacularClient(BaseClient[RecipeMetadata]):
    """
    Client for Spoonacular Recipe API.

    API Documentation: https://spoonacular.com/food-api/docs

    Features:
    - Search recipes by query
    - Get recipe details including ingredients, nutrition
    - Extract cuisine, dish type, dietary labels
    - Analyze recipe URLs

    Rate limits:
    - Free tier: 150 requests/day, 1 point per request
    - ~1 req/sec recommended
    """

    BASE_URL = "https://api.spoonacular.com"
    CACHE_PREFIX = "spoonacular"

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None
    ):
        """
        Initialize Spoonacular client.

        Args:
            api_key: Spoonacular API key (SPOONACULAR_API_KEY env var)
            cache: Optional shared cache
        """
        super().__init__(
            rate_limit=settings.spoonacular_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.spoonacular_api_key
        if not self.api_key:
            logger.warning(
                "Spoonacular API key not configured. Set SPOONACULAR_API_KEY environment variable."
            )

    def _get_headers(self) -> Dict[str, str]:
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }

    async def _get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        use_cache: bool = True,
        cache_key: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        """Override to add API key as query parameter."""
        if params is None:
            params = {}
        if self.api_key:
            params["apiKey"] = self.api_key
        return await super()._get(endpoint, params, use_cache, cache_key)

    async def search_recipes(
        self,
        query: str,
        cuisine: Optional[str] = None,
        diet: Optional[str] = None,
        type_: Optional[str] = None,
        number: int = 10
    ) -> List[RecipeMetadata]:
        """
        Search for recipes.

        Args:
            query: Search query
            cuisine: Filter by cuisine (e.g., "italian")
            diet: Filter by diet (e.g., "vegetarian", "vegan")
            type_: Filter by dish type (e.g., "main course", "dessert")
            number: Maximum results

        Returns:
            List of matching recipes
        """
        if not self.api_key:
            logger.error("Cannot search: Spoonacular API key not configured")
            return []

        params = {
            "query": query,
            "number": min(number, 100),
            "addRecipeInformation": True,
            "fillIngredients": True,
        }

        if cuisine:
            params["cuisine"] = cuisine
        if diet:
            params["diet"] = diet
        if type_:
            params["type"] = type_

        cache_key = f"search:{query}:{cuisine}:{diet}:{type_}:{number}"
        result = await self._get("/recipes/complexSearch", params=params, cache_key=cache_key)

        if not result or "results" not in result:
            return []

        return [self._parse_recipe(item) for item in result["results"]]

    async def get_recipe(self, recipe_id: int) -> Optional[RecipeMetadata]:
        """
        Get detailed recipe information.

        Args:
            recipe_id: Spoonacular recipe ID

        Returns:
            RecipeMetadata or None
        """
        if not self.api_key:
            logger.error("Cannot fetch recipe: Spoonacular API key not configured")
            return None

        params = {
            "includeNutrition": True,
        }

        result = await self._get(
            f"/recipes/{recipe_id}/information",
            params=params,
            cache_key=f"recipe:{recipe_id}"
        )

        if not result:
            logger.debug(f"Recipe not found: {recipe_id}")
            return None

        return self._parse_recipe(result)

    async def analyze_recipe_url(self, url: str) -> Optional[RecipeMetadata]:
        """
        Analyze a recipe from a URL.

        Args:
            url: Recipe URL to analyze

        Returns:
            RecipeMetadata or None
        """
        if not self.api_key:
            logger.error("Cannot analyze URL: Spoonacular API key not configured")
            return None

        params = {
            "url": url,
            "forceExtraction": True,
            "analyze": True,
        }

        result = await self._get(
            "/recipes/extract",
            params=params,
            cache_key=f"extract:{url}"
        )

        if not result:
            return None

        return self._parse_recipe(result)

    def _parse_recipe(self, item: Dict[str, Any]) -> RecipeMetadata:
        """Parse a recipe from API response."""
        # Parse ingredients
        ingredients = []
        for ing in item.get("extendedIngredients", []):
            ingredients.append(RecipeIngredient(
                id=ing.get("id"),
                name=ing.get("name", ""),
                original=ing.get("original", ""),
                amount=ing.get("amount", 0),
                unit=ing.get("unit", ""),
                aisle=ing.get("aisle", ""),
            ))

        # Get ingredient names as simple list
        ingredient_names = [ing.name for ing in ingredients if ing.name]

        # Parse nutrition
        nutrition = None
        nutrition_data = item.get("nutrition", {})
        if nutrition_data:
            nutrients = nutrition_data.get("nutrients", [])
            for n in nutrients:
                if n.get("name") == "Calories":
                    if nutrition is None:
                        nutrition = RecipeNutrition()
                    nutrition.calories = n.get("amount")
            # Try summary format
            if "caloricBreakdown" in nutrition_data:
                if nutrition is None:
                    nutrition = RecipeNutrition()

        return RecipeMetadata(
            recipe_id=item.get("id", 0),
            title=item.get("title", ""),
            summary=item.get("summary", ""),
            instructions=item.get("instructions", ""),
            source_url=item.get("sourceUrl", ""),
            source_name=item.get("sourceName", ""),
            image_url=item.get("image", ""),
            cuisines=item.get("cuisines", []),
            dish_types=item.get("dishTypes", []),
            diets=item.get("diets", []),
            occasions=item.get("occasions", []),
            ingredients=ingredients,
            ingredient_names=ingredient_names,
            ready_in_minutes=item.get("readyInMinutes", 0),
            servings=item.get("servings", 0),
            cooking_minutes=item.get("cookingMinutes") or 0,
            preparation_minutes=item.get("preparationMinutes") or 0,
            health_score=item.get("healthScore"),
            spoonacular_score=item.get("spoonacularScore"),
            price_per_serving=item.get("pricePerServing"),
            vegetarian=item.get("vegetarian", False),
            vegan=item.get("vegan", False),
            gluten_free=item.get("glutenFree", False),
            dairy_free=item.get("dairyFree", False),
            very_healthy=item.get("veryHealthy", False),
            cheap=item.get("cheap", False),
            sustainable=item.get("sustainable", False),
            nutrition=nutrition,
        )

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        normalized = topic.lower().strip()

        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    async def enrich_recipe(
        self,
        preference_id: str,
        recipe_id_or_title: str,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich a recipe preference with Spoonacular data.

        Args:
            preference_id: PWG preference ID
            recipe_id_or_title: Recipe ID, URL, or title
            min_confidence: Minimum confidence threshold

        Returns:
            EnrichmentResult with topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=recipe_id_or_title,
            source=EnrichmentSource.SPOONACULAR,
        )

        if not self.api_key:
            result.error = "Spoonacular API key not configured"
            return result

        try:
            # Check if input is a recipe ID
            extracted_id = extract_recipe_id(recipe_id_or_title)

            if extracted_id:
                # Direct ID lookup
                metadata = await self.get_recipe(extracted_id)

                if metadata:
                    result.confidence = 0.95
                    result.match_type = MatchType.DIRECT_ID
                    result.exact_match = True
                else:
                    result.error = f"Recipe not found: {extracted_id}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

            elif recipe_id_or_title.startswith("http"):
                # URL extraction
                metadata = await self.analyze_recipe_url(recipe_id_or_title)

                if metadata:
                    result.confidence = 0.85
                    result.match_type = MatchType.DIRECT_ID
                    result.exact_match = True
                else:
                    result.error = f"Could not extract recipe from URL: {recipe_id_or_title}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result
            else:
                # Search by title
                recipes = await self.search_recipes(recipe_id_or_title, number=5)

                if not recipes:
                    result.error = f"No recipes found for: {recipe_id_or_title}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                # Take first result
                metadata = recipes[0]

                # Calculate confidence based on title similarity
                from .validation import title_similarity
                similarity = title_similarity(recipe_id_or_title, metadata.title)

                if similarity >= 0.9:
                    result.confidence = 0.85
                    result.match_type = MatchType.EXACT_TITLE
                    result.exact_match = True
                elif similarity >= 0.7:
                    result.confidence = similarity * 0.8
                    result.match_type = MatchType.FUZZY_TITLE
                else:
                    result.confidence = similarity * 0.6
                    result.match_type = MatchType.BEST_GUESS

                if result.confidence < min_confidence:
                    result.error = f"Low confidence match ({result.confidence:.2f}): {metadata.title}"
                    return result

            # Store metadata
            result.matched_title = metadata.title
            result.recipe_metadata = metadata

            # Add cuisines as topics
            for cuisine in metadata.cuisines:
                mapped = CUISINE_MAPPINGS.get(cuisine.lower(), cuisine)
                result.topics.append(TopicResult(
                    name=mapped,
                    normalized=self._normalize_topic(mapped),
                    confidence=0.9,
                    source_field="cuisines"
                ))

            # Add dish types as topics
            for dish_type in metadata.dish_types:
                mapped = DISH_TYPE_MAPPINGS.get(dish_type.lower(), dish_type)
                result.topics.append(TopicResult(
                    name=mapped,
                    normalized=self._normalize_topic(mapped),
                    confidence=0.9,
                    source_field="dishTypes"
                ))

            # Add dietary labels as topics
            for label in metadata.dietary_labels:
                result.topics.append(TopicResult(
                    name=label,
                    normalized=self._normalize_topic(label),
                    confidence=0.95,
                    source_field="dietary_labels"
                ))

            # Add diets as topics
            for diet in metadata.diets:
                result.topics.append(TopicResult(
                    name=diet.title(),
                    normalized=self._normalize_topic(diet),
                    confidence=0.9,
                    source_field="diets"
                ))

            # Add difficulty as topic
            result.topics.append(TopicResult(
                name=f"Difficulty: {metadata.difficulty}",
                normalized=f"difficulty_{metadata.difficulty.lower()}",
                confidence=0.8,
                source_field="difficulty"
            ))

            # Add cooking time as topic
            if metadata.ready_in_minutes:
                time_label = f"{metadata.ready_in_minutes} minutes"
                result.topics.append(TopicResult(
                    name=f"Time: {time_label}",
                    normalized=f"cooking_time_{metadata.ready_in_minutes}",
                    confidence=0.9,
                    source_field="readyInMinutes"
                ))

            # Add key ingredients as entities
            for ingredient in metadata.ingredient_names[:8]:
                result.entities.append(EntityResult(
                    name=ingredient,
                    entity_type="ingredient",
                ))

            # Add source as entity
            if metadata.source_name:
                result.entities.append(EntityResult(
                    name=metadata.source_name,
                    entity_type="recipe_source",
                ))

            logger.info(
                f"Enriched recipe '{metadata.title}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities, "
                f"cuisines: {metadata.cuisines}"
            )

        except Exception as e:
            logger.error(f"Error enriching recipe '{recipe_id_or_title}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[RecipeMetadata]:
        """Search for a recipe by query."""
        recipes = await self.search_recipes(query, number=1)
        return recipes[0] if recipes else None

    async def get_details(self, item_id: str) -> Optional[RecipeMetadata]:
        """Get recipe details by ID."""
        recipe_id = extract_recipe_id(item_id)
        if recipe_id:
            return await self.get_recipe(recipe_id)
        return None
