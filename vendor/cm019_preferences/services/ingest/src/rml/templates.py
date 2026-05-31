"""RML mapping templates for common data sources."""

# Base prefixes used in all mappings
RML_PREFIXES = """
@prefix rml: <http://semweb.mmlab.be/ns/rml#> .
@prefix rr: <http://www.w3.org/ns/r2rml#> .
@prefix ql: <http://semweb.mmlab.be/ns/ql#> .
@prefix pwg: <https://pwg.dev/ontology#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix fnml: <http://semweb.mmlab.be/ns/fnml#> .
@prefix fno: <https://w3id.org/function/ontology#> .
@prefix grel: <http://users.ugent.be/~bjdmeest/function/grel.ttl#> .
"""

# CSV preference mapping template
CSV_PREFERENCE_MAPPING = RML_PREFIXES + """
<#PreferenceMapping>
    rml:logicalSource [
        rml:source "{source_file}" ;
        rml:referenceFormulation ql:CSV
    ] ;
    rr:subjectMap [
        rr:template "https://pwg.dev/data/preference/{{id}}" ;
        rr:class pwg:Preference
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:subject ;
        rr:objectMap [ rml:reference "subject" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:preferenceStrength ;
        rr:objectMap [
            rml:reference "strength" ;
            rr:datatype xsd:decimal
        ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:category ;
        rr:objectMap [ rml:reference "category" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:belongsToCompartment ;
        rr:objectMap [
            rr:template "https://pwg.dev/ontology#L{{compartment_level}}" ;
            rr:termType rr:IRI
        ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:dataSource ;
        rr:objectMap [ rr:constant "csv_import" ]
    ] .
"""

# JSON streaming history mapping (Spotify-style)
JSON_STREAMING_MAPPING = RML_PREFIXES + """
<#StreamingHistoryMapping>
    rml:logicalSource [
        rml:source "{source_file}" ;
        rml:referenceFormulation ql:JSONPath ;
        rml:iterator "$[*]"
    ] ;
    rr:subjectMap [
        rr:template "https://pwg.dev/data/listen/{{endTime}}_{{trackName}}" ;
        rr:class pwg:ListeningEvent
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:trackName ;
        rr:objectMap [ rml:reference "trackName" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:artistName ;
        rr:objectMap [ rml:reference "artistName" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:msPlayed ;
        rr:objectMap [
            rml:reference "msPlayed" ;
            rr:datatype xsd:integer
        ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:endTime ;
        rr:objectMap [
            rml:reference "endTime" ;
            rr:datatype xsd:dateTime
        ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:dataSource ;
        rr:objectMap [ rr:constant "spotify" ]
    ] .
"""

# Google Takeout YouTube history mapping
YOUTUBE_HISTORY_MAPPING = RML_PREFIXES + """
<#YouTubeHistoryMapping>
    rml:logicalSource [
        rml:source "{source_file}" ;
        rml:referenceFormulation ql:JSONPath ;
        rml:iterator "$[*]"
    ] ;
    rr:subjectMap [
        rr:template "https://pwg.dev/data/watch/{{time}}" ;
        rr:class pwg:WatchEvent
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:title ;
        rr:objectMap [ rml:reference "title" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:titleUrl ;
        rr:objectMap [ rml:reference "titleUrl" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:watchTime ;
        rr:objectMap [
            rml:reference "time" ;
            rr:datatype xsd:dateTime
        ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:dataSource ;
        rr:objectMap [ rr:constant "google_takeout" ]
    ] .

<#YouTubeChannelMapping>
    rml:logicalSource [
        rml:source "{source_file}" ;
        rml:referenceFormulation ql:JSONPath ;
        rml:iterator "$[*].subtitles[*]"
    ] ;
    rr:subjectMap [
        rr:template "https://pwg.dev/data/channel/{{name}}" ;
        rr:class pwg:YouTubeChannel
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:channelName ;
        rr:objectMap [ rml:reference "name" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:channelUrl ;
        rr:objectMap [ rml:reference "url" ]
    ] .
"""

# Generic preference from liked items
LIKED_ITEMS_MAPPING = RML_PREFIXES + """
<#LikedItemsMapping>
    rml:logicalSource [
        rml:source "{source_file}" ;
        rml:referenceFormulation ql:JSONPath ;
        rml:iterator "$.{items_path}[*]"
    ] ;
    rr:subjectMap [
        rr:template "https://pwg.dev/data/preference/{{name}}" ;
        rr:class pwg:LikePreference
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:subject ;
        rr:objectMap [ rml:reference "name" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:preferenceStrength ;
        rr:objectMap [
            rr:constant "0.8" ;
            rr:datatype xsd:decimal
        ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:category ;
        rr:objectMap [ rr:constant "{category}" ]
    ] ;
    rr:predicateObjectMap [
        rr:predicate pwg:dataSource ;
        rr:objectMap [ rr:constant "{source}" ]
    ] .
"""

# Template dictionary for easy access
RML_TEMPLATES = {
    "csv_preference": CSV_PREFERENCE_MAPPING,
    "streaming_history": JSON_STREAMING_MAPPING,
    "youtube_history": YOUTUBE_HISTORY_MAPPING,
    "liked_items": LIKED_ITEMS_MAPPING,
}


def get_mapping(template_name: str, **kwargs) -> str:
    """
    Get an RML mapping template with placeholders filled.

    Args:
        template_name: Name of the template
        **kwargs: Values to substitute in the template

    Returns:
        RML mapping string with placeholders replaced
    """
    template = RML_TEMPLATES.get(template_name, "")
    if not template:
        raise ValueError(f"Unknown template: {template_name}")

    return template.format(**kwargs)
